import Foundation
import CoreAudio
import AudioToolbox
import Combine

// MARK: - EQEngineService

/// The core audio processing pipeline using manual AUHAL units.
///
/// Architecture:
///   1. Shared memory: the driver writes audio via WriteMix into an mmap'd file.
///      The app reads from this file directly — no Core Audio input API needed,
///      so no TCC microphone permission is required.
///   2. Output AUHAL: pinned to the real hardware device, drives the render chain.
///      Its render callback pulls from EQ AudioUnit, which reads from shared memory.
///   3. N-band EQ AudioUnit: processes audio between shared memory and output.
///
/// Data flow:
///   Apps → WriteMix (virtual device) → SharedAudioBuffer (in driver) →
///   SharedAudioReader (mmap, no TCC) →
///   EQ render callback → NBandEQ → Output AUHAL render callback → Real hardware
///
/// Threading: start/stop called on main thread; IO callbacks on real-time audio threads.
///
/// State machine: Uses Core Audio property listeners (not Thread.sleep or semaphores)
/// to wait for device appearance and sample rate changes.
@MainActor
final class EQEngineService: ObservableObject {

    static let shared = EQEngineService()

    // MARK: - Pipeline State Machine

    enum PipelineState {
        case idle
        case preparingDevice       // Waiting for virtual device to appear in HAL device list
        case preparingSampleRate   // Waiting for virtual device sample rate to match real device
        case starting              // Creating AUs, wiring render chain, starting IO
        case running               // Pipeline active, audio flowing
        case stopping              // Teardown in progress
    }

    struct PipelineRequest {
        let realDeviceUID: String
        let settings: EQSettings
        let virtualDeviceName: String
        let generation: Int32
    }

    // MARK: - Published state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var targetDeviceUID: String?

    // MARK: - State machine properties

    private(set) var pipelineState: PipelineState = .idle
    private var currentRequest: PipelineRequest?
    private var activeListenerBlock: AudioObjectPropertyListenerBlock?
    private var activeSafetyTimer: Timer?
    private var activeListenerObjectID: AudioObjectID = 0
    private var activeListenerAddress: AudioObjectPropertyAddress?

    // MARK: - Private audio state

    private var eqAU:     AudioUnit?
    private var outputAU: AudioUnit?

    /// Cross-process shared memory reader — reads audio from the driver without TCC
    private var sharedReader: SharedAudioReader?

    /// Prevent reference objects from being deallocated while render callbacks use them
    private var eqRenderRef: EQRenderRef?

    /// Track current real/virtual device IDs for volume restore on switch
    private var virtualDeviceID: AudioObjectID?
    private var realDeviceID: AudioObjectID?

    /// Cancellable async teardown work — prevents a pending stopSafe from
    /// overwriting the default output device after a new start().
    private var pendingTeardownWork: DispatchWorkItem?

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
                // Don't call AudioOutputUnitStop/Dispose — AUs are dead
                self.outputAU = nil
                self.eqAU     = nil
                // Keep eqRenderRef alive —
                // an IO thread may still be mid-callback with a pointer to it.
                self.targetDeviceUID = nil
                self.isRunning = false
                self.pipelineState = .idle
                EQDriverService.shared.hide()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public: cancelPendingTeardown

    /// Cancel any pending async teardown work item.
    /// Called from evaluateAndApply() before computing new state.
    func cancelPendingTeardown() {
        pendingTeardownWork?.cancel()
        pendingTeardownWork = nil
    }

    // MARK: - Start EQ pipeline (state machine)

    func startPipeline(
        realDeviceUID: String,
        settings: EQSettings,
        virtualDeviceName: String
    ) {
        // Cancel any pending async teardown that would overwrite our new default output
        cancelPendingTeardown()

        stopEngineOnly()

        // Increment generation so stale callbacks from previous pipeline are ignored
        gGeneration.pointee &+= 1
        let gen = gGeneration.pointee

        AppLogger.error("[EQ-DIAG] EQEngineService.startPipeline() called: '\(virtualDeviceName)' → real=\(realDeviceUID) gen=\(gen)")

        let request = PipelineRequest(
            realDeviceUID: realDeviceUID,
            settings: settings,
            virtualDeviceName: virtualDeviceName,
            generation: gen
        )
        currentRequest = request

        // 1. Find the virtual device
        guard let _ = EQDriverService.shared.findAudioDevice() else {
            AppLogger.error("EQEngineService: virtual device not found — is the driver installed?")
            pipelineState = .idle
            return
        }

        // 2. Register kAudioHardwarePropertyDevices listener BEFORE show() — the notification
        //    fires synchronously during show(), so the listener must be active first.
        pipelineState = .preparingDevice

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let capturedGen = gen
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard capturedGen == gGeneration.pointee else {
                    self.removeActiveListener()
                    return
                }
                self.handleDeviceAppeared()
            }
        }

        activeListenerBlock = listenerBlock
        activeListenerObjectID = AudioObjectID(kAudioObjectSystemObject)
        activeListenerAddress = devicesAddr

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.global(qos: .userInitiated),
            listenerBlock
        )

        // Safety timer: if listener doesn't fire within 2s, proceed anyway
        activeSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard capturedGen == gGeneration.pointee else { return }
                AppLogger.warning("EQEngineService: safety timer fired for preparingDevice — proceeding anyway")
                self.handleDeviceAppeared()
            }
        }

        // 3. Show the virtual device — the listener above will catch the notification
        EQDriverService.shared.show(name: virtualDeviceName)

        // 4. If the device was already visible (isShown was already true), the driver
        //    won't fire a notification. Check immediately and proceed if we can resolve it.
        if let virtualDevice = EQDriverService.shared.findAudioDevice(),
           translateUID(virtualDevice.id) != nil {
            removeActiveListener()
            invalidateSafetyTimer()
            handleDeviceAppeared()
        }
    }

    // MARK: - State machine: device appeared

    private func handleDeviceAppeared() {
        // Guard: only process if we're actually waiting for the device
        guard pipelineState == .preparingDevice else { return }
        guard let request = currentRequest, request.generation == gGeneration.pointee else {
            removeActiveListener()
            invalidateSafetyTimer()
            return
        }

        removeActiveListener()
        invalidateSafetyTimer()

        // Resolve device IDs
        guard let virtualDevice = EQDriverService.shared.findAudioDevice(),
              let virtualObjectID = translateUID(virtualDevice.id) else {
            AppLogger.error("EQEngineService: can't resolve virtual device UID")
            pipelineState = .idle
            return
        }
        guard let realObjectID = translateUID(request.realDeviceUID) else {
            AppLogger.error("EQEngineService: can't resolve real device UID '\(request.realDeviceUID)'")
            stopSafe(switchTo: request.realDeviceUID)
            pipelineState = .idle
            return
        }

        AppLogger.error("[EQ-DIAG] virtualObjID=\(virtualObjectID) realObjID=\(realObjectID)")

        // Match sample rate — register listener BEFORE setting rate (notification fires synchronously)
        let realRate = getDeviceSampleRate(realObjectID) ?? 48000
        let currentVirtualRate = getDeviceSampleRate(virtualObjectID) ?? realRate

        if abs(realRate - currentVirtualRate) > 1.0 {
            // Rates differ — register listener first, then set rate
            pipelineState = .preparingSampleRate
            registerSampleRateListener(virtualObjectID: virtualObjectID, request: request)
            resetVirtualDeviceRate(virtualObjectID, to: realRate)
        } else {
            // Rates match — proceed directly to start (no wait needed)
            finishStart(request: request, virtualObjectID: virtualObjectID, realObjectID: realObjectID)
        }
    }

    // MARK: - State machine: sample rate listener

    private func registerSampleRateListener(virtualObjectID: AudioObjectID, request: PipelineRequest) {
        var sampleRateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let capturedGen = request.generation
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard capturedGen == gGeneration.pointee else {
                    self.removeActiveListener()
                    return
                }
                self.handleSampleRateReady(virtualObjectID: virtualObjectID)
            }
        }

        activeListenerBlock = listenerBlock
        activeListenerObjectID = virtualObjectID
        activeListenerAddress = sampleRateAddr

        AudioObjectAddPropertyListenerBlock(
            virtualObjectID,
            &sampleRateAddr,
            DispatchQueue.global(qos: .userInitiated),
            listenerBlock
        )

        // Safety timer
        activeSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard capturedGen == gGeneration.pointee else { return }
                AppLogger.warning("EQEngineService: safety timer fired for preparingSampleRate — proceeding anyway")
                self.handleSampleRateReady(virtualObjectID: virtualObjectID)
            }
        }
    }

    // MARK: - State machine: sample rate ready

    private func handleSampleRateReady(virtualObjectID: AudioObjectID) {
        guard pipelineState == .preparingSampleRate else { return }
        guard let request = currentRequest, request.generation == gGeneration.pointee else {
            removeActiveListener()
            invalidateSafetyTimer()
            return
        }

        removeActiveListener()
        invalidateSafetyTimer()

        guard let realObjectID = translateUID(request.realDeviceUID) else {
            AppLogger.error("EQEngineService: can't resolve real device UID during sample rate ready")
            pipelineState = .idle
            return
        }

        finishStart(request: request, virtualObjectID: virtualObjectID, realObjectID: realObjectID)
    }

    // MARK: - State machine: finish start (synchronous AU creation)

    private func finishStart(request: PipelineRequest, virtualObjectID: AudioObjectID, realObjectID: AudioObjectID) {
        pipelineState = .starting

        let virtualRate = getDeviceSampleRate(virtualObjectID) ?? 48000
        let channels: UInt32 = 2
        let eqFormat = makeNonInterleavedFormat(sampleRate: virtualRate, channels: channels)
        let outputFormat = makeNonInterleavedFormat(sampleRate: virtualRate, channels: channels)
        AppLogger.error("[EQ-DIAG] formats: virtualRate=\(virtualRate) ch=\(channels)")

        do {
            // Open shared memory reader (reads from driver's mmap'd file — no TCC!)
            guard let reader = SharedAudioReader() else {
                throw AUError("Open shared memory reader", -1)
            }
            self.sharedReader = reader

            // Create audio units (EQ+output=non-interleaved)
            let eq     = try createEQUnit(settings: request.settings, format: eqFormat)
            let output = try createOutputAUHAL(device: realObjectID, format: outputFormat)

            // Wire output render chain: output ← EQ ← shared memory
            let eqRef = EQRenderRef(eqUnit: eq, reader: reader, generation: request.generation)
            self.eqRenderRef = eqRef

            var outputCallbackStruct = AURenderCallbackStruct(
                inputProc: outputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(eqRef).toOpaque()
            )
            var status = AudioUnitSetProperty(output, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &outputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set output render callback", status) }

            // Set EQ render callback to read from shared memory
            var eqInputCallbackStruct = AURenderCallbackStruct(
                inputProc: eqInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(eqRef).toOpaque()
            )
            status = AudioUnitSetProperty(eq, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &eqInputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set EQ input render callback", status) }

            // Initialize all units
            status = AudioUnitInitialize(eq)
            guard status == noErr else { throw AUError("Initialize EQ", status) }

            status = AudioUnitInitialize(output)
            guard status == noErr else { throw AUError("Initialize output AUHAL", status) }

            // Clear the render-stopped flag before starting IO
            OSAtomicCompareAndSwap32(1, 0, gRenderStopped)

            // Start output AUHAL (drives the output render chain)
            status = AudioOutputUnitStart(output)
            guard status == noErr else { throw AUError("Start output AUHAL", status) }

            self.eqAU     = eq
            self.outputAU = output

        } catch {
            AppLogger.error("EQEngineService: pipeline setup failed: \(error)")
            stopEngineOnly()
            stopSafe(switchTo: request.realDeviceUID)
            pipelineState = .idle
            return
        }

        AppLogger.error("[EQ-DIAG] audio units started, setting virtual device as default output")

        // Set virtual device as system default output
        guard let virtualDevice = EQDriverService.shared.findAudioDevice() else {
            AppLogger.error("EQEngineService: virtual device lost after AU setup")
            stopEngineOnly()
            stopSafe(switchTo: request.realDeviceUID)
            pipelineState = .idle
            return
        }
        let controlService = AudioDeviceControlService()
        let setOK = controlService.setDefaultOutputDevice(virtualDevice)
        AppLogger.error("[EQ-DIAG] setDefaultOutputDevice(\(virtualDevice.name)) → \(setOK)")

        if !setOK {
            AppLogger.error("EQEngineService: failed to set virtual device as default — aborting")
            stopEngineOnly()
            stopSafe(switchTo: request.realDeviceUID)
            pipelineState = .idle
            return
        }

        if let currentDefault = controlService.getDefaultOutputDevice() {
            AppLogger.info("EQEngineService: verified default output = '\(currentDefault.name)'")
        }

        self.targetDeviceUID = request.realDeviceUID
        self.virtualDeviceID = virtualObjectID
        self.realDeviceID = realObjectID
        self.isRunning = true
        self.pipelineState = .running

        // Sync volume: copy current real device volume to virtual, then listen for changes
        syncVolumeForEQ(virtualID: virtualObjectID, realID: realObjectID)

        AppLogger.error("[EQ-DIAG] pipeline running")
    }

    // MARK: - Cancel (from any state)

    func cancel() {
        // Increment generation to make all in-flight callbacks stale
        gGeneration.pointee &+= 1

        // Clean up active listener and timer
        removeActiveListener()
        invalidateSafetyTimer()

        // If AUs exist, stop them
        if eqAU != nil || outputAU != nil {
            stopEngineOnly()
        }

        currentRequest = nil
        pipelineState = .idle
    }

    // MARK: - Switch device (hot-swap without tearing down virtual device)

    /// Hot-swap the real output device while keeping the virtual device as system default.
    /// Apps never see a device change — only the real hardware endpoint changes.
    /// Use this when EQ is already running and we just need to route to a different device.
    func switchDevice(
        realDeviceUID: String,
        settings: EQSettings,
        virtualDeviceName: String
    ) {
        guard isRunning else {
            // Not running — fall back to full start
            startPipeline(realDeviceUID: realDeviceUID, settings: settings, virtualDeviceName: virtualDeviceName)
            return
        }

        // Cancel any pending async teardown
        cancelPendingTeardown()

        AppLogger.info("EQEngineService: switching device → '\(virtualDeviceName)' real=\(realDeviceUID)")

        // 1. Increment generation — stale callbacks from old pipeline bail out immediately
        gGeneration.pointee &+= 1
        let gen = gGeneration.pointee

        // 2. Restore old real device volume from virtual device before switching away
        if let vID = virtualDeviceID, let rID = realDeviceID {
            let currentVirtualVol = getDeviceVolume(vID)
            setDeviceVolume(rID, volume: currentVirtualVol)
            AppLogger.info("EQEngineService: restored old real device volume to \(String(format: "%.0f%%", currentVirtualVol * 100))")
        }

        // 3. Stop old output AUHAL + EQ (but do NOT hide virtual device or change system default)
        let alreadyPoisoned = gRenderStopped.pointee != 0
        OSAtomicCompareAndSwap32(0, 1, gRenderStopped)
        if !alreadyPoisoned {
            if let au = outputAU { AudioOutputUnitStop(au); AudioComponentInstanceDispose(au) }
            if let au = eqAU     { AudioComponentInstanceDispose(au) }
        }
        outputAU = nil
        eqAU = nil

        // 4. Reuse existing virtual device IDs (they don't change during a switch)
        guard let virtualDevice = EQDriverService.shared.findAudioDevice(),
              let virtualObjectID = translateUID(virtualDevice.id) else {
            AppLogger.error("EQEngineService: virtual device lost during switch")
            stopSafe(switchTo: realDeviceUID)
            return
        }
        guard let realObjectID = translateUID(realDeviceUID) else {
            AppLogger.error("EQEngineService: can't resolve real device UID '\(realDeviceUID)'")
            stopSafe(switchTo: realDeviceUID)
            return
        }

        // 5. Rename virtual device only if name actually changed
        if virtualDevice.name != virtualDeviceName {
            EQDriverService.shared.show(name: virtualDeviceName)
        }

        // 6. Match sample rates — only change if they differ
        let realRate = getDeviceSampleRate(realObjectID) ?? 48000
        let currentVirtualRate = getDeviceSampleRate(virtualObjectID) ?? 48000
        if abs(realRate - currentVirtualRate) > 1.0 {
            // Register listener BEFORE setting rate (notification fires synchronously)
            let request = PipelineRequest(
                realDeviceUID: realDeviceUID,
                settings: settings,
                virtualDeviceName: virtualDeviceName,
                generation: gen
            )
            currentRequest = request
            pipelineState = .preparingSampleRate
            registerSampleRateListener(virtualObjectID: virtualObjectID, request: request)
            resetVirtualDeviceRate(virtualObjectID, to: realRate)
            return
        }

        // Rates already match — proceed directly
        let request = PipelineRequest(
            realDeviceUID: realDeviceUID,
            settings: settings,
            virtualDeviceName: virtualDeviceName,
            generation: gen
        )
        currentRequest = request
        finishSwitchDevice(request: request, virtualObjectID: virtualObjectID, realObjectID: realObjectID, gen: gen)
    }

    private func finishSwitchDevice(request: PipelineRequest, virtualObjectID: AudioObjectID, realObjectID: AudioObjectID, gen: Int32) {
        let virtualRate = getDeviceSampleRate(virtualObjectID) ?? 48000
        let channels: UInt32 = 2
        let format = makeNonInterleavedFormat(sampleRate: virtualRate, channels: channels)

        do {
            // Fresh shared memory reader
            guard let reader = SharedAudioReader() else {
                throw AUError("Open shared memory reader", -1)
            }
            self.sharedReader = reader

            // Create new audio units
            let eq     = try createEQUnit(settings: request.settings, format: format)
            let output = try createOutputAUHAL(device: realObjectID, format: format)

            // Wire render chain
            let eqRef = EQRenderRef(eqUnit: eq, reader: reader, generation: gen)
            self.eqRenderRef = eqRef

            var outputCB = AURenderCallbackStruct(
                inputProc: outputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(eqRef).toOpaque()
            )
            var status = AudioUnitSetProperty(output, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &outputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set output render callback", status) }

            var eqCB = AURenderCallbackStruct(
                inputProc: eqInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(eqRef).toOpaque()
            )
            status = AudioUnitSetProperty(eq, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &eqCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AUError("Set EQ input render callback", status) }

            // Initialize + start
            status = AudioUnitInitialize(eq)
            guard status == noErr else { throw AUError("Initialize EQ", status) }
            status = AudioUnitInitialize(output)
            guard status == noErr else { throw AUError("Initialize output AUHAL", status) }

            OSAtomicCompareAndSwap32(1, 0, gRenderStopped)

            status = AudioOutputUnitStart(output)
            guard status == noErr else { throw AUError("Start output AUHAL", status) }

            self.eqAU     = eq
            self.outputAU = output

        } catch {
            AppLogger.error("EQEngineService: switch failed: \(error) — falling back to full restart")
            stopEngineOnly()
            startPipeline(realDeviceUID: request.realDeviceUID, settings: request.settings, virtualDeviceName: request.virtualDeviceName)
            return
        }

        // Update state (no setDefaultOutputDevice — virtual device is already default)
        self.targetDeviceUID = request.realDeviceUID
        self.virtualDeviceID = virtualObjectID
        self.realDeviceID = realObjectID
        self.pipelineState = .running

        // Volume: read real device's current volume, apply to virtual, then sync
        syncVolumeForEQ(virtualID: virtualObjectID, realID: realObjectID)

        AppLogger.info("EQEngineService: switch complete")
    }

    // MARK: - Stop

    func stopSafe(switchTo realDeviceUID: String) {
        pipelineState = .stopping
        teardown(switchTo: realDeviceUID, synchronous: false)
    }

    func stopSafe() {
        guard isRunning, let uid = targetDeviceUID else {
            EQDriverService.shared.hide()
            return
        }
        pipelineState = .stopping
        teardown(switchTo: uid, synchronous: false)
    }

    /// Call from applicationWillTerminate only — bypasses state machine entirely.
    /// Same as stopSafe but blocks until the device switch completes,
    /// since the process exits immediately after return.
    func stopForTermination() {
        // Bypass state machine — direct synchronous teardown
        // Clean up any pending listeners/timers
        removeActiveListener()
        invalidateSafetyTimer()

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
        virtualDeviceID = nil
        realDeviceID = nil
        isRunning = false
        pipelineState = .idle

        // Two-step pattern: create var first, then assign closure that captures it.
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [self] in
            guard !work.isCancelled else { return }
            let devices = AudioDeviceFactory.getCurrentDevices()
            guard !work.isCancelled else { return }
            if let realDevice = devices.first(where: { $0.id == realDeviceUID && $0.isOutput }) {
                guard !work.isCancelled else { return }
                let ok = AudioDeviceControlService().setDefaultOutputDevice(realDevice)
                AppLogger.info("EQEngineService: restored default output to '\(realDevice.name)' → \(ok)")
                guard !work.isCancelled else { return }
                if let vol = restoreVolume, let realID = translateUID(realDeviceUID) {
                    setDeviceVolume(realID, volume: vol)
                    AppLogger.info("EQEngineService: restored volume to \(String(format: "%.0f%%", vol * 100))")
                }
            }
        }

        // Core Audio calls can hang if coreaudiod is restarting — use a background
        // queue for normal stop. At termination we must block (process exits after return).
        if synchronous {
            work.perform()
        } else {
            pendingTeardownWork = work
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    // MARK: - Live EQ update

    func updateSettings(_ settings: EQSettings) {
        guard let eq = eqAU else { return }
        configureEQBands(eq, settings: settings)

        // Bypass the entire EQ unit when all settings are flat — avoids the
        // slight gain that NBandEQ introduces even with all bands at 0 dB.
        var bypass: UInt32 = settings.isFlat ? 1 : 0
        AudioUnitSetProperty(eq, kAudioUnitProperty_BypassEffect,
                             kAudioUnitScope_Global, 0,
                             &bypass, UInt32(MemoryLayout<UInt32>.size))
    }

    // MARK: - Private: Listener / Timer management

    private func removeActiveListener() {
        guard let block = activeListenerBlock, var addr = activeListenerAddress else { return }
        AudioObjectRemovePropertyListenerBlock(activeListenerObjectID, &addr, DispatchQueue.global(qos: .userInitiated), block)
        activeListenerBlock = nil
        activeListenerAddress = nil
        activeListenerObjectID = 0
    }

    private func invalidateSafetyTimer() {
        activeSafetyTimer?.invalidate()
        activeSafetyTimer = nil
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
            if let au = eqAU     { AudioComponentInstanceDispose(au) }
        }
        outputAU = nil
        eqAU     = nil

        // Do NOT nil eqRenderRef or sharedReader here.
        // An IO thread may still be mid-callback holding a raw pointer to them.
        // The generation counter ensures stale callbacks return immediately.
        // They will be replaced when the next start() creates new ones,
        // and the old ones will be deallocated naturally by ARC at that point.
    }

    // MARK: - Private: Volume Sync

    /// Set up volume for EQ mode: copy real device volume to virtual device,
    /// then max out the real device. The driver applies volume scaling in its
    /// WriteMix path (ioGain = volumeScalar), so the audio in shared memory
    /// is already volume-adjusted — no listener needed.
    private func syncVolumeForEQ(virtualID: AudioObjectID, realID: AudioObjectID) {
        let realVolume = getDeviceVolume(realID)
        setDeviceVolume(virtualID, volume: realVolume)
        setDeviceVolume(realID, volume: 1.0)

        AppLogger.info("EQEngineService: volume synced (virtual=\(String(format: "%.0f%%", realVolume * 100)), real=100%)")
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

        // Bypass entire EQ unit if settings are flat — avoids slight gain from processing
        var bypass: UInt32 = settings.isFlat ? 1 : 0
        AudioUnitSetProperty(unit, kAudioUnitProperty_BypassEffect,
                             kAudioUnitScope_Global, 0,
                             &bypass, UInt32(MemoryLayout<UInt32>.size))

        AppLogger.error("[EQ-DIAG] EQ unit created with \(numBands) bands, bypass=\(bypass)")
        return unit
    }

    // MARK: - Private: Configure EQ

    private func configureEQBands(_ unit: AudioUnit, settings: EQSettings) {
        AudioUnitSetParameter(unit, kAUNBandEQParam_GlobalGain,
                               kAudioUnitScope_Global, 0, settings.preamp, 0)

        for (i, band) in settings.bands.enumerated() {
            AudioUnitSetParameter(unit, kAUNBandEQParam_FilterType + UInt32(i),
                                   kAudioUnitScope_Global, 0, Float32(band.filterType.rawValue), 0)
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

/// Called by the output AUHAL when it needs audio to play.
/// Renders through the EQ unit (which itself pulls from shared memory via eqInputRenderCallback).
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
/// Reads from the driver's shared memory region (no TCC microphone permission needed).
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

    ref.reader.read(into: ioData, frameCount: inNumberFrames)
    return noErr
}

// MARK: - Reference types for C callbacks

/// Atomic flag shared between all render callbacks. When set to 1,
/// callbacks return immediately without touching any AU or buffer state.
/// This prevents crashes when stopEngineOnly() frees resources while
/// an IO thread is mid-callback.
private let gRenderStopped = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

/// Generation counter — incremented on every start(). Callbacks check this to detect stale refs.
private let gGeneration = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

private final class EQRenderRef {
    let eqUnit: AudioUnit
    let reader: SharedAudioReader
    let generation: Int32
    init(eqUnit: AudioUnit, reader: SharedAudioReader, generation: Int32) {
        self.eqUnit = eqUnit
        self.reader = reader
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
