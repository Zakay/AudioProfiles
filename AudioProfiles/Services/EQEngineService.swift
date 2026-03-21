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

    // Diagnostic counters
    private var diagTimer: Timer?
    private static let stats = UnsafeMutablePointer<RenderStats>.allocate(capacity: 1)

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    private init() {
        Self.stats.initialize(to: RenderStats())

        // When coreaudiod restarts, all Audio Unit references become invalid.
        // Tear down immediately to avoid hangs from calling into dead hardware.
        AudioDeviceMonitor.shared.serviceRestartedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self, self.isRunning else { return }
                AppLogger.info("EQEngineService: coreaudiod restarted — tearing down pipeline")
                // nil out units without calling AudioOutputUnitStop/Dispose (they're invalid)
                self.diagTimer?.invalidate()
                self.diagTimer = nil
                self.outputAU = nil
                self.inputAU  = nil
                self.eqAU     = nil
                self.eqRenderRef     = nil
                self.inputCaptureRef = nil
                self.captureBuffer   = nil
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

        AppLogger.error("[EQ-DIAG] EQEngineService.start() called: '\(virtualDeviceName)' → real=\(realDeviceUID)")

        // 1. Find and show the virtual device
        guard let virtualDevice = EQDriverService.shared.findAudioDevice() else {
            AppLogger.error("EQEngineService: virtual device not found — is the driver installed?")
            return
        }
        EQDriverService.shared.show(name: virtualDeviceName)
        Thread.sleep(forTimeInterval: 0.5)  // Let HAL propagate visibility change

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

        // 3. Reset virtual device to its default 44100 Hz rate.
        // The working standalone test used 44100 throughout. matchSampleRate to 48000
        // broke the HAL's input IO cycle (ReadInput never fires at non-default rates).
        // The output AUHAL handles rate conversion to the real device automatically.
        resetVirtualDeviceRate(virtualObjectID, to: 44100)
        Thread.sleep(forTimeInterval: 0.1)  // Let HAL digest the rate change
        let virtualRate = getDeviceSampleRate(virtualObjectID) ?? 44100
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
            let inputCapRef = InputCaptureRef(unit: input, buffer: capBuf, stats: Self.stats)
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
            let eqRef = EQRenderRef(eqUnit: eq, buffer: capBuf, stats: Self.stats)
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

            // 11. Start input AUHAL first (begins capturing from virtual device)
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
        self.isRunning = true

        // Start diagnostic timer
        Self.stats.pointee = RenderStats()
        diagTimer?.invalidate()
        diagTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard self?.isRunning == true else { return }
            let s = Self.stats.pointee
            let capPeak = Float32(bitPattern: s.capturePeak)
            let eqInPeak = Float32(bitPattern: s.eqInputPeak)
            let outPeak = Float32(bitPattern: s.outputPeak)
            AppLogger.error("[EQ-DIAG] render stats: capture=\(s.captureCount) captureErr=\(s.captureErrors) lastCapErr=\(s.lastCaptureError) output=\(s.outputCount) outputErr=\(s.outputErrors) lastOutErr=\(s.lastOutputError) eqInput=\(s.eqInputCount) | peaks: cap=\(capPeak) eqIn=\(eqInPeak) out=\(outPeak)")
            // Reset peaks for next interval
            Self.stats.pointee.capturePeak = 0
            Self.stats.pointee.eqInputPeak = 0
            Self.stats.pointee.outputPeak = 0
        }

        AppLogger.error("[EQ-DIAG] pipeline running ✓")
    }

    // MARK: - Stop

    func stopSafe(switchTo realDeviceUID: String) {
        AppLogger.info("EQEngineService: stopping, switching back to \(realDeviceUID)")

        let devices = AudioDeviceFactory.getCurrentDevices()
        if let realDevice = devices.first(where: { $0.id == realDeviceUID && $0.isOutput }) {
            let controlService = AudioDeviceControlService()
            let ok = controlService.setDefaultOutputDevice(realDevice)
            AppLogger.info("EQEngineService: restored default output to '\(realDevice.name)' → \(ok)")
        }

        stopEngineOnly()
        EQDriverService.shared.hide()

        targetDeviceUID = nil
        isRunning = false
    }

    func stopSafe() {
        guard isRunning, let uid = targetDeviceUID else {
            EQDriverService.shared.hide()
            return
        }
        stopSafe(switchTo: uid)
    }

    // MARK: - Live EQ update

    func updateSettings(_ settings: EQSettings) {
        guard let eq = eqAU else { return }
        configureEQBands(eq, settings: settings)
        AppLogger.info("EQEngineService: EQ settings updated")
    }

    // MARK: - Private: stop engine

    private func stopEngineOnly() {
        diagTimer?.invalidate()
        diagTimer = nil
        if let au = outputAU { AudioOutputUnitStop(au); AudioComponentInstanceDispose(au) }
        if let au = inputAU  { AudioOutputUnitStop(au); AudioComponentInstanceDispose(au) }
        if let au = eqAU     { AudioComponentInstanceDispose(au) }
        outputAU = nil
        inputAU  = nil
        eqAU     = nil
        eqRenderRef     = nil
        inputCaptureRef = nil
        captureBuffer   = nil
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
    let ref = Unmanaged<InputCaptureRef>.fromOpaque(inRefCon).takeUnretainedValue()

    // Prepare interleaved buffer list for the captured data
    let bufferList = ref.buffer.prepareForCapture(frameCount: inNumberFrames)

    // Pull captured audio from the input AUHAL's element 1
    let status = AudioUnitRender(ref.unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferList)

    if status == noErr {
        // Track peak level of captured audio
        let ablPtr = UnsafeMutableAudioBufferListPointer(bufferList)
        var peak: Float32 = 0
        for buf in ablPtr {
            if let data = buf.mData?.assumingMemoryBound(to: Float32.self) {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
                for i in 0..<count {
                    let v = abs(data[i])
                    if v > peak { peak = v }
                }
            }
        }
        // Update peak using atomic CAS
        let newBits = peak.bitPattern
        var old = ref.stats.pointee.capturePeak
        while newBits > old {
            if OSAtomicCompareAndSwap32(Int32(bitPattern: old), Int32(bitPattern: newBits), UnsafeMutableRawPointer(&ref.stats.pointee.capturePeak).assumingMemoryBound(to: Int32.self)) { break }
            old = ref.stats.pointee.capturePeak
        }
        ref.buffer.commitCapture(frameCount: inNumberFrames)
    } else {
        ref.stats.pointee.lastCaptureError = Int64(status)
        OSAtomicIncrement64(&ref.stats.pointee.captureErrors)
    }
    OSAtomicIncrement64(&ref.stats.pointee.captureCount)

    return noErr  // Always return noErr — don't propagate errors to the AUHAL
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
    let ref = Unmanaged<EQRenderRef>.fromOpaque(inRefCon).takeUnretainedValue()

    let status = AudioUnitRender(ref.eqUnit, ioActionFlags, inTimeStamp, 0, inNumberFrames, ioData!)
    if status == noErr {
        // Track peak level of EQ output
        let ablPtr = UnsafeMutableAudioBufferListPointer(ioData!)
        var peak: Float32 = 0
        for buf in ablPtr {
            if let data = buf.mData?.assumingMemoryBound(to: Float32.self) {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
                for i in 0..<count {
                    let v = abs(data[i])
                    if v > peak { peak = v }
                }
            }
        }
        let newBits = peak.bitPattern
        var old = ref.stats.pointee.outputPeak
        while newBits > old {
            if OSAtomicCompareAndSwap32(Int32(bitPattern: old), Int32(bitPattern: newBits), UnsafeMutableRawPointer(&ref.stats.pointee.outputPeak).assumingMemoryBound(to: Int32.self)) { break }
            old = ref.stats.pointee.outputPeak
        }
    } else {
        ref.stats.pointee.lastOutputError = Int64(status)
        OSAtomicIncrement64(&ref.stats.pointee.outputErrors)
    }
    OSAtomicIncrement64(&ref.stats.pointee.outputCount)
    return status
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
    let ref = Unmanaged<EQRenderRef>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData = ioData else { return kAudioUnitErr_InvalidParameter }

    ref.buffer.read(into: ioData, frameCount: inNumberFrames)
    // Track peak level of data fed to EQ
    let ablPtr = UnsafeMutableAudioBufferListPointer(ioData)
    var peak: Float32 = 0
    for buf in ablPtr {
        if let data = buf.mData?.assumingMemoryBound(to: Float32.self) {
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            for i in 0..<count {
                let v = abs(data[i])
                if v > peak { peak = v }
            }
        }
    }
    let newBits = peak.bitPattern
    var old = ref.stats.pointee.eqInputPeak
    while newBits > old {
        if OSAtomicCompareAndSwap32(Int32(bitPattern: old), Int32(bitPattern: newBits), UnsafeMutableRawPointer(&ref.stats.pointee.eqInputPeak).assumingMemoryBound(to: Int32.self)) { break }
        old = ref.stats.pointee.eqInputPeak
    }
    OSAtomicIncrement64(&ref.stats.pointee.eqInputCount)
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

    init(channels: Int, maxFrames: Int) {
        self.channels = channels
        self.maxFrames = maxFrames

        // Ring holds ~23ms of audio at 44100 Hz stereo (1024 frames).
        // Small ring = low latency. Overflows drop oldest data.
        capacity = 1024 * channels
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)

        // Temp buffer for capture callback
        let capSize = maxFrames * channels
        captureBuffer = .allocate(capacity: capSize)
        captureBuffer.initialize(repeating: 0, count: capSize)

        captureABL = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ).bindMemory(to: AudioBufferList.self, capacity: 1)
    }

    deinit {
        ring.deallocate()
        captureBuffer.deallocate()
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

        // Copy from ring into a temp contiguous buffer for deinterleaving
        // (ring may wrap around)
        let avail = capacity - rp
        let tempCount = elementsToRead
        let temp = UnsafeMutablePointer<Float>.allocate(capacity: tempCount)
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
        temp.deallocate()
    }
}

// MARK: - Reference types for C callbacks

private final class InputCaptureRef {
    let unit: AudioUnit
    let buffer: CaptureBuffer
    let stats: UnsafeMutablePointer<RenderStats>
    init(unit: AudioUnit, buffer: CaptureBuffer, stats: UnsafeMutablePointer<RenderStats>) {
        self.unit = unit
        self.buffer = buffer
        self.stats = stats
    }
}

private final class EQRenderRef {
    let eqUnit: AudioUnit
    let buffer: CaptureBuffer
    let stats: UnsafeMutablePointer<RenderStats>
    init(eqUnit: AudioUnit, buffer: CaptureBuffer, stats: UnsafeMutablePointer<RenderStats>) {
        self.eqUnit = eqUnit
        self.buffer = buffer
        self.stats = stats
    }
}

// MARK: - Diagnostic stats

private struct RenderStats {
    var captureCount: Int64 = 0
    var captureErrors: Int64 = 0
    var lastCaptureError: Int64 = 0
    var outputCount: Int64 = 0
    var outputErrors: Int64 = 0
    var lastOutputError: Int64 = 0
    var eqInputCount: Int64 = 0
    // Peak levels (atomic float via bitPattern)
    var capturePeak: UInt32 = 0   // Float32 bitPattern of max abs sample from capture
    var eqInputPeak: UInt32 = 0   // Float32 bitPattern of max abs sample fed to EQ
    var outputPeak: UInt32 = 0    // Float32 bitPattern of max abs sample from EQ output
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
