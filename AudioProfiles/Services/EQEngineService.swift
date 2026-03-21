import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

// MARK: - EQEngineService

/// The core audio processing pipeline using manual AUHAL units.
///
/// Architecture:
///   1. Input AUHAL: pinned to the virtual device, captures audio via input callback
///      into a thread-safe CaptureBuffer.
///   2. Output AUHAL: pinned to the real hardware device, drives the render chain.
///      Its render callback pulls from EQ AudioUnit, which reads from CaptureBuffer.
///   3. N-band EQ AudioUnit: processes audio between capture and output.
///
/// Data flow:
///   Apps → WriteMix (virtual device) → RingBuffer → ReadInput →
///   Input AUHAL (capture callback) → CaptureBuffer →
///   EQ render callback → NBandEQ → Output AUHAL render callback → Real hardware
///
/// Threading: start/stop called on main thread; IO callbacks on real-time audio threads.
@MainActor
final class EQEngineService: ObservableObject {

    static let shared = EQEngineService()

    // MARK: - Published state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var targetDeviceUID: String?

    // MARK: - Private audio state

    private var inputAU:  AudioUnit?
    private var eqAU:     AudioUnit?
    private var outputAU: AudioUnit?

    /// Shared capture buffer between input AUHAL callback and EQ render callback
    private var captureBuffer: CaptureBuffer?

    /// Prevent reference objects from being deallocated while render callbacks use them
    private var eqRenderRef:    EQRenderRef?
    private var inputCaptureRef: InputCaptureRef?

    /// Volume sync: mirrors virtual device volume to real device
    private var virtualDeviceID: AudioObjectID?
    private var realDeviceID: AudioObjectID?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    private init() {
        gRenderStopped.initialize(to: 0)
        gGeneration.initialize(to: 0)

        // Register a DIRECT Core Audio property listener for coreaudiod restart.
        // This fires on the audio thread IMMEDIATELY — no async main-thread hop —
        // so gRenderStopped is set before any IO callback can touch dead AUs.
        var restartAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &restartAddr,
            nil  // fires on internal CA thread
        ) { _, _ in
            // Immediately poison all render callbacks — runs on audio thread
            OSAtomicCompareAndSwap32(0, 1, gRenderStopped)
        }

        // Combine handler for main-thread cleanup (UI state, nil AUs, etc.)
        AudioDeviceMonitor.shared.serviceRestartedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self, self.isRunning else { return }
                AppLogger.info("EQEngineService: coreaudiod restarted — tearing down pipeline")
                // gRenderStopped already set by the direct listener above
                // no-op: diagTimer removed
                // Don't call AudioOutputUnitStop/Dispose — AUs are dead
                self.outputAU = nil
                self.inputAU  = nil
                self.eqAU     = nil
                // Keep eqRenderRef, inputCaptureRef, captureBuffer alive —
                // an IO thread may still be mid-callback with a pointer to them.
                self.targetDeviceUID = nil
                self.isRunning = false
                EQDriverService.shared.hide()
            }
            .store(in: &cancellables)
    }

    // MARK: - Start EQ pipeline

    func start(
        realDeviceUID: String,
        settings: EQSettings,
        virtualDeviceName: String
    ) {
        stopEngineOnly()

        // Increment generation so stale callbacks from previous pipeline are ignored
        gGeneration.pointee &+= 1
        let gen = gGeneration.pointee

        AppLogger.error("[EQ-DIAG] EQEngineService.start() called: '\(virtualDeviceName)' → real=\(realDeviceUID) gen=\(gen)")

        // 1. Find and show the virtual device
        guard let virtualDevice = EQDriverService.shared.findAudioDevice() else {
            AppLogger.error("EQEngineService: virtual device not found — is the driver installed?")
            return
        }
        EQDriverService.shared.show(name: virtualDeviceName)
        // Brief pause for HAL to propagate visibility — 50ms is enough
        Thread.sleep(forTimeInterval: 0.05)

        // 2. Resolve AudioObjectIDs
        guard let virtualObjectID = translateUID(virtualDevice.id) else {
            AppLogger.error("EQEngineService: can't resolve virtual device UID '\(virtualDevice.id)'")
            stopSafe(switchTo: realDeviceUID)
            return
        }
        guard let realObjectID = translateUID(realDeviceUID) else {
            AppLogger.error("EQEngineService: can't resolve real device UID '\(realDeviceUID)'")
            stopSafe(switchTo: realDeviceUID)
            return
        }

        AppLogger.error("[EQ-DIAG] virtualObjID=\(virtualObjectID) realObjID=\(realObjectID)")

        // 3. Match virtual device sample rate to the real device rate.
        // This avoids automatic sample rate conversion in the output AUHAL
        // which adds significant latency and CPU overhead.
        let realRate = getDeviceSampleRate(realObjectID) ?? 48000
        resetVirtualDeviceRate(virtualObjectID, to: realRate)
        Thread.sleep(forTimeInterval: 0.02)  // Brief pause for HAL to digest rate change
        let virtualRate = getDeviceSampleRate(virtualObjectID) ?? realRate
        let channels: UInt32 = 2
        let inputFormat = makeInterleavedFormat(sampleRate: virtualRate, channels: channels)
        let eqFormat = makeNonInterleavedFormat(sampleRate: virtualRate, channels: channels)
        let outputFormat = makeNonInterleavedFormat(sampleRate: virtualRate, channels: channels)
        AppLogger.error("[EQ-DIAG] formats: virtualRate=\(virtualRate) ch=\(channels)")

        do {
            // 5. Create capture buffer (interleaved capture → deinterleaved read)
            let capBuf = CaptureBuffer(channels: Int(channels), maxFrames: 4096)
            self.captureBuffer = capBuf

            // 6. Create audio units (input=interleaved, EQ+output=non-interleaved)
            let input  = try createInputAUHAL(device: virtualObjectID, format: inputFormat)
            let eq     = try createEQUnit(settings: settings, format: eqFormat)
            let output = try createOutputAUHAL(device: realObjectID, format: outputFormat)

            // 7. Set up input capture callback (fires when input AUHAL has data)
            let inputCapRef = InputCaptureRef(unit: input, buffer: capBuf, generation: gen)
            self.inputCaptureRef = inputCapRef

            var inputCallbackStruct = AURenderCallbackStruct(
                inputProc: inputCaptureCallback,
                inputProcRefCon: Unmanaged.passUnretained(inputCapRef).toOpaque()
            )
            var status = AudioUnitSetProperty(input, kAudioOutputUnitProperty_SetInputCallback,
                                               kAudioUnitScope_Global, 0,
                                               &inputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set input capture callback", status) }

            // 8. Wire output render chain: output ← EQ ← captureBuffer
            let eqRef = EQRenderRef(eqUnit: eq, buffer: capBuf, generation: gen)
            self.eqRenderRef = eqRef

            var outputCallbackStruct = AURenderCallbackStruct(
                inputProc: outputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(eqRef).toOpaque()
            )
            status = AudioUnitSetProperty(output, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &outputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set output render callback", status) }

            // 9. Set EQ render callback to read from captureBuffer
            var eqInputCallbackStruct = AURenderCallbackStruct(
                inputProc: eqInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(eqRef).toOpaque()
            )
            status = AudioUnitSetProperty(eq, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &eqInputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set EQ input render callback", status) }

            // 10. Initialize all units
            status = AudioUnitInitialize(input)
            guard status == noErr else { throw AUError("Initialize input AUHAL", status) }

            status = AudioUnitInitialize(eq)
            guard status == noErr else { throw AUError("Initialize EQ", status) }

            status = AudioUnitInitialize(output)
            guard status == noErr else { throw AUError("Initialize output AUHAL", status) }

            // 11. Clear the render-stopped flag before starting IO
            OSAtomicCompareAndSwap32(1, 0, gRenderStopped)

            // Start input AUHAL first (begins capturing from virtual device)
            status = AudioOutputUnitStart(input)
            guard status == noErr else { throw AUError("Start input AUHAL", status) }

            // 12. Start output AUHAL (drives the output render chain)
            status = AudioOutputUnitStart(output)
            guard status == noErr else { throw AUError("Start output AUHAL", status) }

            self.inputAU  = input
            self.eqAU     = eq
            self.outputAU = output

        } catch {
            AppLogger.error("EQEngineService: pipeline setup failed: \(error)")
            stopEngineOnly()
            stopSafe(switchTo: realDeviceUID)
            return
        }

        AppLogger.error("[EQ-DIAG] audio units started, setting virtual device as default output")

        // 13. Set virtual device as system default output
        let controlService = AudioDeviceControlService()
        let setOK = controlService.setDefaultOutputDevice(virtualDevice)
        AppLogger.error("[EQ-DIAG] setDefaultOutputDevice(\(virtualDevice.name)) → \(setOK)")

        if !setOK {
            AppLogger.error("EQEngineService: failed to set virtual device as default — aborting")
            stopEngineOnly()
            stopSafe(switchTo: realDeviceUID)
            return
        }

        if let currentDefault = controlService.getDefaultOutputDevice() {
            AppLogger.info("EQEngineService: verified default output = '\(currentDefault.name)'")
        }

        self.targetDeviceUID = realDeviceUID
        self.virtualDeviceID = virtualObjectID
        self.realDeviceID = realObjectID
        self.isRunning = true

        // Sync volume: copy current real device volume to virtual, then listen for changes
        startVolumeSync(virtualID: virtualObjectID, realID: realObjectID)

        AppLogger.error("[EQ-DIAG] pipeline running ✓")
    }

    // MARK: - Stop

    func stopSafe(switchTo realDeviceUID: String) {
        teardown(switchTo: realDeviceUID, synchronous: false)
    }

    func stopSafe() {
        guard isRunning, let uid = targetDeviceUID else {
            EQDriverService.shared.hide()
            return
        }
        teardown(switchTo: uid, synchronous: false)
    }

    /// Call from applicationWillTerminate only — same as stopSafe but blocks until
    /// the device switch completes, since the process exits immediately after return.
    func stopForTermination() {
        guard isRunning, let uid = targetDeviceUID else {
            EQDriverService.shared.hide()
            return
        }
        teardown(switchTo: uid, synchronous: true)
    }

    // MARK: - Private: shared teardown

    private func teardown(switchTo realDeviceUID: String, synchronous: Bool) {
        AppLogger.info("EQEngineService: stopping, switching back to \(realDeviceUID)")

        // Capture volume before teardown so we can restore it on the real device.
        let restoreVolume = virtualDeviceID.flatMap { getDeviceVolume($0) }

        stopEngineOnly()
        EQDriverService.shared.hide()
        targetDeviceUID = nil
        isRunning = false

        let work = { [self] in
            let devices = AudioDeviceFactory.getCurrentDevices()
            if let realDevice = devices.first(where: { $0.id == realDeviceUID && $0.isOutput }) {
                let ok = AudioDeviceControlService().setDefaultOutputDevice(realDevice)
                AppLogger.info("EQEngineService: restored default output to '\(realDevice.name)' → \(ok)")
                if let vol = restoreVolume, let realID = translateUID(realDeviceUID) {
                    setDeviceVolume(realID, volume: vol)
                    AppLogger.info("EQEngineService: restored volume to \(String(format: "%.0f%%", vol * 100))")
                }
            }
        }

        // Core Audio calls can hang if coreaudiod is restarting — use a background
        // queue for normal stop. At termination we must block (process exits after return).
        if synchronous {
            work()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    // MARK: - Live EQ update

    func updateSettings(_ settings: EQSettings) {
        guard let eq = eqAU else { return }
        configureEQBands(eq, settings: settings)
        AppLogger.info("EQEngineService: EQ settings updated")
    }

    // MARK: - Private: stop engine

    private func stopEngineOnly() {
        // Check if AUs are already dead (coreaudiod restart set the flag
        // from the audio thread before this main-thread code runs).
        let alreadyPoisoned = gRenderStopped.pointee != 0

        // Signal render callbacks to bail out immediately — must happen
        // BEFORE we stop/dispose AUs, because an IO thread may be
        // mid-callback right now.
        OSAtomicCompareAndSwap32(0, 1, gRenderStopped)

        if alreadyPoisoned {
            // AUs are dead (coreaudiod restarted) — calling Stop/Dispose
            // on them would crash. Just nil the references.
            AppLogger.info("EQEngineService: stopEngineOnly — AUs invalidated by coreaudiod restart, skipping dispose")
        } else {
            // Normal shutdown — stop IO first (drains audio threads),
            // then dispose.
            if let au = outputAU { AudioOutputUnitStop(au); AudioComponentInstanceDispose(au) }
            if let au = inputAU  { AudioOutputUnitStop(au); AudioComponentInstanceDispose(au) }
            if let au = eqAU     { AudioComponentInstanceDispose(au) }
        }
        outputAU = nil
        inputAU  = nil
        eqAU     = nil

        // Do NOT nil eqRenderRef, inputCaptureRef, or captureBuffer here.
        // An IO thread may still be mid-callback holding a raw pointer to them.
        // The generation counter ensures stale callbacks return immediately.
        // They will be replaced when the next start() creates new ones,
        // and the old ones will be deallocated naturally by ARC at that point.

        stopVolumeSync()
    }

    // MARK: - Private: Volume Sync

    /// Start mirroring volume changes from the virtual device to the real device.
    /// When the user adjusts system volume (which targets the virtual device),
    /// we copy that volume to the real device so audio output level matches.
    private func startVolumeSync(virtualID: AudioObjectID, realID: AudioObjectID) {
        stopVolumeSync()

        // Set real device to max so the virtual device's volume has full range
        setDeviceVolume(realID, volume: 1.0)

        // Listen for volume changes on the virtual device
        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let vol = self.getDeviceVolume(virtualID)
            self.setDeviceVolume(realID, volume: vol)
        }
        self.volumeListenerBlock = listener

        let status = AudioObjectAddPropertyListenerBlock(virtualID, &volumeAddr, DispatchQueue.main, listener)
        if status != noErr {
            AppLogger.error("EQEngineService: failed to add volume listener: \(status)")
        } else {
            AppLogger.info("EQEngineService: volume sync active")
        }
    }

    private func stopVolumeSync() {
        guard let vID = virtualDeviceID, let listener = volumeListenerBlock else { return }

        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(vID, &volumeAddr, DispatchQueue.main, listener)
        self.volumeListenerBlock = nil
        self.virtualDeviceID = nil
        self.realDeviceID = nil
    }

    private func getDeviceVolume(_ deviceID: AudioObjectID) -> Float32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        return volume
    }

    private func setDeviceVolume(_ deviceID: AudioObjectID, volume: Float32) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = volume
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                    UInt32(MemoryLayout<Float32>.size), &vol)
    }

    // MARK: - Private: Create Audio Units

    private func createInputAUHAL(device: AudioObjectID, format: AudioStreamBasicDescription) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AUError("Find HALOutput component", -1)
        }
        var au: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &au)
        guard status == noErr, let unit = au else { throw AUError("Create input AUHAL", status) }

        // Enable input on element 1
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1,
                                       &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUError("Enable input IO", status) }

        // Disable output on element 0
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0,
                                       &disableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUError("Disable output IO on input unit", status) }

        // Set device
        var dev = device
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw AUError("Set input device", status) }

        // Set the output format of element 1 (what the capture callback reads)
        var fmt = format
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw AUError("Set input AUHAL output format", status) }

        AppLogger.error("[EQ-DIAG] input AUHAL created, device=\(device)")
        return unit
    }

    private func createOutputAUHAL(device: AudioObjectID, format: AudioStreamBasicDescription) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AUError("Find HALOutput component", -1)
        }
        var au: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &au)
        guard status == noErr, let unit = au else { throw AUError("Create output AUHAL", status) }

        var dev = device
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw AUError("Set output device", status) }

        // Set the input format of element 0 (what we feed to it)
        var fmt = format
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw AUError("Set output AUHAL input format", status) }

        AppLogger.error("[EQ-DIAG] output AUHAL created, device=\(device)")
        return unit
    }

    private func createEQUnit(settings: EQSettings, format: AudioStreamBasicDescription) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AUError("Find NBandEQ component", -1)
        }
        var au: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &au)
        guard status == noErr, let unit = au else { throw AUError("Create NBandEQ", status) }

        var fmt = format
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw AUError("Set EQ input format", status) }

        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw AUError("Set EQ output format", status) }

        var numBands = UInt32(EQSettings.standardFrequencies.count)
        status = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                                       kAudioUnitScope_Global, 0,
                                       &numBands, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUError("Set EQ band count", status) }

        configureEQBands(unit, settings: settings)

        AppLogger.error("[EQ-DIAG] EQ unit created with \(numBands) bands")
        return unit
    }

    // MARK: - Private: Configure EQ

    private func configureEQBands(_ unit: AudioUnit, settings: EQSettings) {
        AudioUnitSetParameter(unit, kAUNBandEQParam_GlobalGain,
                               kAudioUnitScope_Global, 0, settings.preamp, 0)

        for (i, band) in settings.bands.enumerated() {
            let filterType: Float32
            if i == 0 {
                filterType = 7  // kAUNBandEQFilterType_LowShelf
            } else if i == settings.bands.count - 1 {
                filterType = 8  // kAUNBandEQFilterType_HighShelf
            } else {
                filterType = 0  // kAUNBandEQFilterType_Parametric
            }
            AudioUnitSetParameter(unit, kAUNBandEQParam_FilterType + UInt32(i),
                                   kAudioUnitScope_Global, 0, filterType, 0)
            AudioUnitSetParameter(unit, kAUNBandEQParam_Frequency + UInt32(i),
                                   kAudioUnitScope_Global, 0, band.frequency, 0)
            AudioUnitSetParameter(unit, kAUNBandEQParam_Gain + UInt32(i),
                                   kAudioUnitScope_Global, 0, band.gain, 0)
            AudioUnitSetParameter(unit, kAUNBandEQParam_Bandwidth + UInt32(i),
                                   kAudioUnitScope_Global, 0, band.bandwidth, 0)
            AudioUnitSetParameter(unit, kAUNBandEQParam_BypassBand + UInt32(i),
                                   kAudioUnitScope_Global, 0, band.isFlat ? 1 : 0, 0)
        }
    }

    // MARK: - Private: Format helpers

    private func makeInterleavedFormat(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerFrame = channels * 4
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func makeNonInterleavedFormat(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func getDeviceSampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private func resetVirtualDeviceRate(_ deviceID: AudioObjectID, to rate: Float64) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newRate = rate
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                                 UInt32(MemoryLayout<Float64>.size), &newRate)
        AppLogger.error("[EQ-DIAG] resetVirtualDeviceRate to \(rate) Hz → status=\(status)")
    }

    // MARK: - Private: UID translation

    private func translateUID(_ uid: String) -> AudioObjectID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioPlugInPropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID: CFString = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propAddr,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

}

// MARK: - C function callbacks (no captures allowed)

/// Called by the input AUHAL when it has captured audio from the virtual device.
/// We call AudioUnitRender on element 1 to pull the captured data, then store it
/// in the CaptureBuffer for the output side to read.
private func inputCaptureCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    if gRenderStopped.pointee != 0 { return noErr }
    let ref = Unmanaged<InputCaptureRef>.fromOpaque(inRefCon).takeUnretainedValue()
    if ref.generation != gGeneration.pointee { return noErr }

    // Prepare interleaved buffer list for the captured data
    let bufferList = ref.buffer.prepareForCapture(frameCount: inNumberFrames)

    // Pull captured audio from the input AUHAL's element 1
    let status = AudioUnitRender(ref.unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferList)

    if status == noErr {
        ref.buffer.commitCapture(frameCount: inNumberFrames)
    }
    return noErr
}

/// Called by the output AUHAL when it needs audio to play.
/// Renders through the EQ unit (which itself pulls from captureBuffer via eqInputRenderCallback).
private func outputRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // Bail out if engine is being torn down — refs may be invalid
    if gRenderStopped.pointee != 0 {
        // Fill silence
        if let ioData = ioData {
            let ablPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for buf in ablPtr {
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }
        }
        return noErr
    }
    let ref = Unmanaged<EQRenderRef>.fromOpaque(inRefCon).takeUnretainedValue()
    if ref.generation != gGeneration.pointee {
        if let ioData = ioData {
            let ablPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for buf in ablPtr { if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) } }
        }
        return noErr
    }

    return AudioUnitRender(ref.eqUnit, ioActionFlags, inTimeStamp, 0, inNumberFrames, ioData!)
}

/// Called by the EQ AudioUnit when it needs input data.
/// Copies from the CaptureBuffer into the provided AudioBufferList.
private func eqInputRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    if gRenderStopped.pointee != 0 {
        if let ioData = ioData {
            let ablPtr = UnsafeMutableAudioBufferListPointer(ioData)
            for buf in ablPtr {
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }
        }
        return noErr
    }
    let ref = Unmanaged<EQRenderRef>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData = ioData else { return kAudioUnitErr_InvalidParameter }
    if ref.generation != gGeneration.pointee {
        let ablPtr = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in ablPtr { if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) } }
        return noErr
    }

    ref.buffer.read(into: ioData, frameCount: inNumberFrames)
    return noErr
}

// MARK: - CaptureBuffer

/// Thread-safe ring buffer for passing audio between the input capture callback
/// and the output render callback. Captures interleaved stereo Float32 (matching the
/// virtual device driver format), reads as deinterleaved for the EQ unit.
/// Uses a lock-based ring buffer so multiple captures accumulate between output reads.
private final class CaptureBuffer {
    let channels: Int
    let maxFrames: Int
    private let capacity: Int          // total Float32 samples in ring
    private var ring: UnsafeMutablePointer<Float>
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var lock = os_unfair_lock()

    // Pre-allocated interleaved AudioBufferList for capture
    private var captureABL: UnsafeMutablePointer<AudioBufferList>
    private var captureBuffer: UnsafeMutablePointer<Float>
    // Pre-allocated temp buffer for deinterleaving in read() — avoids malloc on RT thread
    private var readTemp: UnsafeMutablePointer<Float>

    init(channels: Int, maxFrames: Int) {
        self.channels = channels
        self.maxFrames = maxFrames

        // Ring holds ~42ms of audio at 48000 Hz stereo (2048 frames).
        // Enough headroom for jitter between capture and output callbacks.
        // Overflows drop oldest data (bounded latency).
        capacity = 2048 * channels
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)

        // Temp buffer for capture callback
        let capSize = maxFrames * channels
        captureBuffer = .allocate(capacity: capSize)
        captureBuffer.initialize(repeating: 0, count: capSize)

        // Temp buffer for read/deinterleave (same max size as ring capacity)
        readTemp = .allocate(capacity: capacity)
        readTemp.initialize(repeating: 0, count: capacity)

        captureABL = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ).bindMemory(to: AudioBufferList.self, capacity: 1)
    }

    deinit {
        ring.deallocate()
        captureBuffer.deallocate()
        readTemp.deallocate()
        captureABL.deallocate()
    }

    /// Returns an interleaved ABL for the input AUHAL capture callback to fill.
    func prepareForCapture(frameCount: UInt32) -> UnsafeMutablePointer<AudioBufferList> {
        let ablPtr = captureABL
        ablPtr.pointee.mNumberBuffers = 1
        let bufs = UnsafeMutableAudioBufferListPointer(ablPtr)
        bufs[0].mNumberChannels = UInt32(channels)
        bufs[0].mDataByteSize = frameCount * UInt32(channels) * 4
        bufs[0].mData = UnsafeMutableRawPointer(captureBuffer)
        return ablPtr
    }

    /// After capture is done, copy interleaved data into the ring buffer.
    /// If the ring would overflow, advance readPos to drop oldest data (bounded latency).
    func commitCapture(frameCount fc: UInt32) {
        let elementCount = Int(fc) * channels
        os_unfair_lock_lock(&lock)

        // Check how much free space
        let filled = (writePos - readPos + capacity) % capacity
        let free = capacity - 1 - filled  // -1 to distinguish full from empty
        if elementCount > free {
            // Drop oldest data by advancing readPos
            let drop = elementCount - free
            readPos = (readPos + drop) % capacity
        }

        let avail = capacity - writePos
        if elementCount <= avail {
            ring.advanced(by: writePos).update(from: captureBuffer, count: elementCount)
        } else {
            ring.advanced(by: writePos).update(from: captureBuffer, count: avail)
            ring.update(from: captureBuffer.advanced(by: avail), count: elementCount - avail)
        }
        writePos = (writePos + elementCount) % capacity
        os_unfair_lock_unlock(&lock)
    }

    /// Read captured interleaved data into a non-interleaved ABL (for the EQ unit).
    /// Deinterleaves on the fly: ring[frame*ch + c] → dst_c[frame]
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablBufs = UnsafeMutableAudioBufferListPointer(abl)
        let elementCount = Int(frameCount) * channels

        os_unfair_lock_lock(&lock)
        let filled = (writePos - readPos + capacity) % capacity
        let elementsToRead = min(filled, elementCount)
        let framesToRead = elementsToRead / channels
        let rp = readPos

        // Advance read position
        readPos = (readPos + elementsToRead) % capacity

        // Copy from ring into pre-allocated temp buffer for deinterleaving
        // (ring may wrap around)
        let avail = capacity - rp
        let temp = readTemp
        if elementsToRead <= avail {
            temp.update(from: ring.advanced(by: rp), count: elementsToRead)
        } else {
            temp.update(from: ring.advanced(by: rp), count: avail)
            temp.advanced(by: avail).update(from: ring, count: elementsToRead - avail)
        }
        os_unfair_lock_unlock(&lock)

        // Deinterleave into the non-interleaved ABL
        for ch in 0..<min(channels, Int(ablBufs.count)) {
            guard let dst = ablBufs[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<framesToRead {
                dst[f] = temp[f * channels + ch]
            }
            // Zero-fill remaining
            if framesToRead < Int(frameCount) {
                memset(dst.advanced(by: framesToRead), 0, (Int(frameCount) - framesToRead) * MemoryLayout<Float>.size)
            }
            ablBufs[ch].mDataByteSize = frameCount * 4
        }
    }
}

// MARK: - Reference types for C callbacks

/// Atomic flag shared between all render callbacks. When set to 1,
/// callbacks return immediately without touching any AU or buffer state.
/// This prevents crashes when stopEngineOnly() frees resources while
/// an IO thread is mid-callback.
private let gRenderStopped = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

/// Generation counter — incremented on every start(). Callbacks check this to detect stale refs.
private let gGeneration = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

private final class InputCaptureRef {
    let unit: AudioUnit
    let buffer: CaptureBuffer
    let generation: Int32
    init(unit: AudioUnit, buffer: CaptureBuffer, generation: Int32) {
        self.unit = unit
        self.buffer = buffer
        self.generation = generation
    }
}

private final class EQRenderRef {
    let eqUnit: AudioUnit
    let buffer: CaptureBuffer
    let generation: Int32
    init(eqUnit: AudioUnit, buffer: CaptureBuffer, generation: Int32) {
        self.eqUnit = eqUnit
        self.buffer = buffer
        self.generation = generation
    }
}

// MARK: - Helper: AUError

private struct AUError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus
    init(_ operation: String, _ status: OSStatus) {
        self.operation = operation
        self.status = status
    }
    var description: String { "\(operation) failed with status \(status)" }
}
