import Foundation
import Combine
import CoreAudio
import AppKit

/// Detects the current content mode based on system signals — no app-specific logic.
///
/// Detection priority:
/// 1. Manual override (user pinned a mode)
/// 2. Mic active on any non-self process → Voice
/// 3. Now Playing metadata: media type + duration heuristics → Music/Movie/Podcast
/// 4. Nothing detected → .none (no overlay)
///
/// All detection is event-driven (zero polling):
/// - Mic: kAudioDevicePropertyDeviceIsRunningSomewhere listener
/// - Default input change: kAudioHardwarePropertyDefaultInputDevice listener
/// - Now Playing: MediaRemote framework notifications
@MainActor
final class ContentModeDetectionService: ObservableObject {

    static let shared = ContentModeDetectionService()

    @Published private(set) var detectedMode: ContentModeType = .none
    @Published private(set) var sourceApp: String?

    // MARK: - Mic listener state
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var micListenerDeviceID: AudioObjectID = 0

    // MARK: - Default input device listener state
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Now Playing state
    private var nowPlayingInfo: [String: Any] = [:]
    private var nowPlayingAppName: String?

    // MARK: - Mic safety re-evaluation
    // The mic listener fires on the default-input device's IsRunningSomewhere transitions,
    // but the voice decision is process-level (kAudioProcessPropertyIsRunningInput). Meeting
    // apps (Teams/Zoom) often keep the mic stream open after a call ends, so the device
    // event can fire while a process still claims input (→ stays Voice), and the later
    // release may emit no further event → Voice would stay stuck. While mic-driven Voice is
    // active, poll detect() at a low frequency so a lagging release still deactivates.
    private var detectionSafetyTimer: Timer?
    private let detectionSafetyInterval: TimeInterval = 3.0
    private static let micSource = "Microphone active"

    // MARK: - Music output detection
    // Now Playing (MediaRemote) is restricted on macOS 15.4+ and returns nothing to
    // unentitled apps, so Music can't be classified from metadata anymore. Instead we
    // detect when a known music app is actively OUTPUTTING audio via Core Audio process
    // objects (kAudioProcessPropertyIsRunningOutput) — the output twin of the mic check.
    // Extend this set to map more apps to Music mode.
    private static let musicAppBundleIDs: Set<String> = [
        "com.spotify.client",   // Spotify
        "com.apple.Music",      // Apple Music
    ]

    private init() {
        AppLogger.info("ContentModeDetectionService: init called, isEnabled=\(SoundModesStore.shared.isEnabled)")
    }

    // MARK: - Detection Control

    func startDetection() {
        stopDetection()
        registerNowPlayingNotifications()
        registerDefaultInputListener()
        registerMicListener()
        registerDefaultOutputListener()
        registerOutputListener()
        detect()
    }

    func stopDetection() {
        unregisterMicListener()
        unregisterDefaultInputListener()
        unregisterOutputListener()
        unregisterDefaultOutputListener()
        unregisterNowPlayingNotifications()
        detectionSafetyTimer?.invalidate()
        detectionSafetyTimer = nil
        applyMode(.none, source: nil)
    }

    // MARK: - Core Detection Logic

    func detect() {
        guard SoundModesStore.shared.isEnabled else {
            AppLogger.info("ContentModeDetection: skipping — not enabled")
            return
        }

        // Priority 0: Manual override — user explicitly selected a mode
        if let manual = SoundModesStore.shared.manualOverride {
            applyMode(manual, source: "Manual")
            return
        }

        // Priority 1: Mic active → Voice (kept above music so meetings win over background audio)
        if isMicActiveForNonSelfProcess() {
            applyMode(.voice, source: Self.micSource)
            return
        }

        // Priority 2: A known music app is actively outputting audio → Music
        if let app = musicAppOutputting() {
            applyMode(.music, source: app)
            return
        }

        // Priority 3: Now Playing metadata (best-effort — empty on macOS 15.4+ for unentitled apps)
        if let (mode, source) = detectFromMediaMetadata() {
            applyMode(mode, source: source)
            return
        }

        // Priority 4: Nothing detected → .none
        applyMode(.none, source: nil)
    }

    private func applyMode(_ mode: ContentModeType, source: String?) {
        guard detectedMode != mode || sourceApp != source else { return }
        detectedMode = mode
        sourceApp = source
        SoundModesStore.shared.setActiveMode(mode, sourceApp: source)
        // Persistent diagnostics (NSLog survives in the unified log, unlike Logger.info)
        // so content-mode transitions can be inspected after the fact.
        NSLog("[CONTENT-DIAG] content mode → \(mode) (source: \(source ?? "none"))")
        if mode != .none {
            AppLogger.info("Content mode: \(mode.displayName) (source: \(source ?? "none"))")
        }
        updateDetectionSafetyTimer()
        ProfileManager.shared.pipelineInvalidationSubject.send()
    }

    /// Runs a low-frequency re-`detect()` only while an auto-detected live-signal mode is
    /// active (Voice from mic, or Music from audio output). Those signals can stop without
    /// emitting a Core Audio event (an app holding the stream open past use), so the poll
    /// ensures deactivation. Idle in every other state — no polling when nothing is detected
    /// or when the user has pinned a manual override.
    private func updateDetectionSafetyTimer() {
        let isAuto = SoundModesStore.shared.manualOverride == nil
        let shouldRun = isAuto && (detectedMode == .voice || detectedMode == .music)
        if shouldRun {
            guard detectionSafetyTimer == nil else { return }
            detectionSafetyTimer = Timer.scheduledTimer(withTimeInterval: detectionSafetyInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.detect() }
            }
        } else {
            detectionSafetyTimer?.invalidate()
            detectionSafetyTimer = nil
        }
    }

    // MARK: - Mic Detection (event-driven via Core Audio listener)

    private func isMicActiveForNonSelfProcess() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier

        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x70727323), // 'prs#' kAudioHardwarePropertyProcessObjectList
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &dataSize
        ) == noErr else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &dataSize, &processIDs
        ) == noErr else { return false }

        for processObj in processIDs {
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(0x70697269), // 'piri' kAudioProcessPropertyIsRunningInput
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunningInput: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(processObj, &inputAddr, 0, nil, &size, &isRunningInput)
            guard status == noErr, isRunningInput != 0 else { continue }

            var pidAddr = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(0x70706964), // 'ppid' kAudioProcessPropertyPID
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(processObj, &pidAddr, 0, nil, &pidSize, &pid)
            if pidStatus == noErr && pid == myPID { continue }

            return true
        }

        return false
    }

    // MARK: - Music Output Detection (event-driven via Core Audio process objects)

    /// If a known music app (see `musicAppBundleIDs`) is actively outputting audio, returns
    /// its display name; otherwise nil. This is the output twin of the mic-input check and
    /// needs no special permission. Our own process is excluded.
    private func musicAppOutputting() -> String? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        for processObj in audioProcessObjects() {
            // 'piro' kAudioProcessPropertyIsRunningOutput
            guard processU32(processObj, 0x7069726F) != 0 else { continue }
            let pid = processPID(processObj)
            if pid == myPID { continue }
            // 'pbid' kAudioProcessPropertyBundleID
            guard let bundleID = processString(processObj, 0x70626964),
                  Self.musicAppBundleIDs.contains(bundleID) else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            return name ?? bundleID
        }
        return nil
    }

    // MARK: - Core Audio process-object helpers

    private func audioProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x70727323), // 'prs#' kAudioHardwarePropertyProcessObjectList
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    private func processU32(_ obj: AudioObjectID, _ selector: UInt32) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private func processPID(_ obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(0x70706964), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain) // 'ppid'
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr ? pid : 0
    }

    private func processString(_ obj: AudioObjectID, _ selector: UInt32) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutableBytes(of: &cf) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? (cf as String?) : nil
    }

    // MARK: - Output "is running" listener (event-driven music start/stop trigger)

    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputListenerDeviceID: AudioObjectID = 0

    /// Listen to the default OUTPUT device's "is running somewhere" property so detection
    /// re-runs whenever audio output starts or stops (music start/stop trigger).
    private func registerOutputListener() {
        guard outputListenerBlock == nil else { return }

        var defaultOutputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputDeviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, 0, nil, &size, &outputDeviceID)
        guard outputDeviceID != kAudioObjectUnknown else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.detect() }
        }
        outputListenerBlock = block
        if AudioObjectAddPropertyListenerBlock(outputDeviceID, &addr, DispatchQueue.main, block) == noErr {
            outputListenerDeviceID = outputDeviceID
        } else {
            outputListenerBlock = nil
        }
    }

    private func unregisterOutputListener() {
        guard let block = outputListenerBlock, outputListenerDeviceID != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(outputListenerDeviceID, &addr, DispatchQueue.main, block)
        outputListenerBlock = nil
        outputListenerDeviceID = 0
    }

    // MARK: - Default Output Device Change Listener

    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    /// Re-register the output listener when the default output device changes.
    private func registerDefaultOutputListener() {
        guard defaultOutputListenerBlock == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.unregisterOutputListener()
                self.registerOutputListener()
                self.detect()
            }
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func unregisterDefaultOutputListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        defaultOutputListenerBlock = nil
    }

    /// Listen to the default input device's "is running" property.
    /// Fires whenever ANY process starts or stops using the mic.
    private func registerMicListener() {
        guard micListenerBlock == nil else { return }

        var defaultInputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputDeviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddr, 0, nil, &size, &inputDeviceID
        )

        guard inputDeviceID != kAudioObjectUnknown else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Store the block so we can use the SAME reference for removal
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.detect()
            }
        }
        micListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(inputDeviceID, &addr, DispatchQueue.main, block)

        if status == noErr {
            micListenerDeviceID = inputDeviceID
        } else {
            micListenerBlock = nil
        }
    }

    private func unregisterMicListener() {
        guard let block = micListenerBlock, micListenerDeviceID != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &addr, DispatchQueue.main, block)
        micListenerBlock = nil
        micListenerDeviceID = 0
    }

    // MARK: - Default Input Device Change Listener

    /// Re-register mic listener when the default input device changes.
    private func registerDefaultInputListener() {
        guard defaultInputListenerBlock == nil else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Re-register mic listener on the new default input device
                self.unregisterMicListener()
                self.registerMicListener()
                self.detect()
            }
        }
        defaultInputListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
    }

    private func unregisterDefaultInputListener() {
        guard let block = defaultInputListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        defaultInputListenerBlock = nil
    }

    // MARK: - Now Playing Detection (MediaRemote — metadata only, no app-specific rules)

    private var mediaRemoteBundle: CFBundle?

    private func registerNowPlayingNotifications() {
        // Load MediaRemote once and keep reference
        guard let bundle = CFBundleCreate(kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else {
            AppLogger.error("ContentModeDetection: Cannot load MediaRemote.framework")
            return
        }
        mediaRemoteBundle = bundle

        typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
        guard let registerPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) else {
            AppLogger.error("ContentModeDetection: Cannot find MRMediaRemoteRegisterForNowPlayingNotifications")
            return
        }
        let register = unsafeBitCast(registerPtr, to: RegisterFn.self)
        register(DispatchQueue.main)
        AppLogger.info("ContentModeDetection: registered for Now Playing notifications")

        // Listen for ALL MediaRemote notification variants
        let notificationNames = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification",
        ]
        for name in notificationNames {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(nowPlayingChanged),
                name: NSNotification.Name(name),
                object: nil
            )
        }

        // Also observe with DistributedNotificationCenter (some versions use this)
        let distCenter = DistributedNotificationCenter.default()
        for name in notificationNames {
            distCenter.addObserver(
                self,
                selector: #selector(nowPlayingChanged),
                name: NSNotification.Name(name),
                object: nil
            )
        }

        fetchNowPlayingInfo()
    }

    private func unregisterNowPlayingNotifications() {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        nowPlayingInfo = [:]
        nowPlayingAppName = nil
        mediaRemoteBundle = nil
    }

    @objc private func nowPlayingChanged() {
        fetchNowPlayingInfo()
    }

    private func fetchNowPlayingInfo() {
        guard let bundle = mediaRemoteBundle else { return }

        // Try 1: MRMediaRemoteGetNowPlayingInfo (returns metadata dict)
        typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            let getInfo = unsafeBitCast(ptr, to: GetInfoFn.self)
            getInfo(DispatchQueue.main) { [weak self] info in
                Task { @MainActor [weak self] in
                    if !info.isEmpty {
                        self?.handleNowPlayingInfo(info)
                        return
                    }
                }
            }
        }

        // Try 2: MRMediaRemoteGetNowPlayingApplicationIsPlaying (returns bool)
        typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            let _ = unsafeBitCast(ptr, to: IsPlayingFn.self)
            // We don't use this result directly — it's available for future use
        }

        // Try 3: MRMediaRemoteGetNowPlayingApplicationPID (returns pid_t)
        typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString) {
            let _ = unsafeBitCast(ptr, to: GetPIDFn.self)
            // We don't use this result directly — it's available for future use
        }
    }

    private func handleNowPlayingInfo(_ info: [String: Any]) {
        nowPlayingInfo = info
        nowPlayingAppName = info["kMRMediaRemoteNowPlayingInfoApplicationDisplayName"] as? String
        detect()
    }

    /// Classify content mode from Now Playing metadata — no app-specific bundle ID rules.
    /// Uses: media type, duration, genre, and playback state.
    private func detectFromMediaMetadata() -> (ContentModeType, String)? {
        guard !nowPlayingInfo.isEmpty else { return nil }

        let appName = nowPlayingAppName ?? "Unknown"

        // Check if anything is actually playing
        let isPlaying = (nowPlayingInfo["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
        guard isPlaying > 0 else { return nil }

        // MediaRemote media type: 1 = music, 2 = video, 3 = podcast/spoken
        if let mediaType = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoMediaType"] as? Int {
            switch mediaType {
            case 1:  return (.music, appName)
            case 2:  return (.movie, appName)
            case 3:  return (.voice, appName)  // Podcast → Voice (speech clarity)
            default: break
            }
        }

        // Fallback: use duration heuristic
        // Short content (<10min) with title → likely music
        // Long content (>30min) → likely movie or podcast
        if let duration = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoDuration"] as? Double {
            if duration > 0 && duration < 600 {
                return (.music, appName)
            } else if duration >= 1800 {
                // Long content — could be movie or podcast
                // If there's an artist field, it's more likely a podcast
                let hasArtist = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoArtist"] as? String != nil
                let hasAlbum = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoAlbum"] as? String != nil
                if hasArtist && !hasAlbum {
                    return (.voice, appName)  // Podcast-like → Voice (speech clarity)
                }
                return (.movie, appName)
            }
        }

        // Has title + artist + album → music
        let hasTitle = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoTitle"] as? String != nil
        let hasArtist = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoArtist"] as? String != nil
        let hasAlbum = nowPlayingInfo["kMRMediaRemoteNowPlayingInfoAlbum"] as? String != nil
        if hasTitle && hasArtist && hasAlbum {
            return (.music, appName)
        }
        if hasTitle && hasArtist {
            return (.music, appName)
        }

        // Something is playing but we can't classify it — return nil (defaults to .none)
        return nil
    }
}
