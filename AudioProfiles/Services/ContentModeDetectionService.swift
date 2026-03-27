import Foundation
import Combine
import CoreAudio
import AppKit

/// Detects the current content mode based on system signals — no app-specific logic.
///
/// Detection priority:
/// 1. Mic active on any non-self process → Voice
/// 2. Now Playing metadata: media type + duration heuristics → Music/Movie/Podcast
/// 3. Nothing detected → None
///
/// All detection is event-driven (zero polling):
/// - Mic: kAudioDevicePropertyDeviceIsRunningSomewhere listener
/// - Now Playing: MediaRemote framework notifications
@MainActor
final class ContentModeDetectionService: ObservableObject {

    static let shared = ContentModeDetectionService()

    @Published private(set) var detectedMode: ContentModeType = .none
    @Published private(set) var sourceApp: String?

    private var cancellables = Set<AnyCancellable>()
    private var micListenerInstalled = false
    private var micListenerDeviceID: AudioObjectID = 0

    // MARK: - Now Playing state
    private var nowPlayingInfo: [String: Any] = [:]
    private var nowPlayingAppName: String?

    private init() {
        AppLogger.info("ContentModeDetectionService: init called, isEnabled=\(SoundModesStore.shared.isEnabled)")
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Start/stop detection when master toggle changes
        SoundModesStore.shared.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.startDetection()
                } else {
                    self?.stopDetection()
                }
            }
            .store(in: &cancellables)

        // Re-detect when manual override changes.
        // receive(on:) ensures the property is updated before detect() reads it.
        SoundModesStore.shared.$manualOverride
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.detect()
            }
            .store(in: &cancellables)
    }

    // MARK: - Detection Control

    private func startDetection() {
        stopDetection()
        registerNowPlayingNotifications()
        registerMicListener()
        detect()
    }

    private func stopDetection() {
        unregisterMicListener()
        unregisterNowPlayingNotifications()
        applyMode(.none, source: nil)
    }

    // MARK: - Core Detection Logic

    private func detect() {
        guard SoundModesStore.shared.isEnabled else {
            AppLogger.info("ContentModeDetection: skipping — not enabled")
            return
        }

        // Priority 0: Manual override — user explicitly selected a mode
        if let manual = SoundModesStore.shared.manualOverride {
            applyMode(manual, source: "Manual")
            return
        }

        // Priority 1: Mic active → Voice
        if isMicActiveForNonSelfProcess() {
            applyMode(.voice, source: "Microphone active")
            return
        }

        // Priority 2: Now Playing metadata
        if let (mode, source) = detectFromMediaMetadata() {
            applyMode(mode, source: source)
            return
        }

        // Priority 3: Nothing detected
        applyMode(.none, source: nil)
    }

    private func applyMode(_ mode: ContentModeType, source: String?) {
        guard detectedMode != mode || sourceApp != source else { return }
        detectedMode = mode
        sourceApp = source
        SoundModesStore.shared.setActiveMode(mode, sourceApp: source)
        if mode != .none {
            AppLogger.info("Content mode: \(mode.displayName) (source: \(source ?? "none"))")
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

    /// Listen to the default input device's "is running" property.
    /// Fires whenever ANY process starts or stops using the mic.
    private func registerMicListener() {
        guard !micListenerInstalled else { return }

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

        let status = AudioObjectAddPropertyListenerBlock(inputDeviceID, &addr, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.detect()
            }
        }

        if status == noErr {
            micListenerInstalled = true
            micListenerDeviceID = inputDeviceID
        }
    }

    private func unregisterMicListener() {
        guard micListenerInstalled, micListenerDeviceID != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &addr, DispatchQueue.main) { _, _ in }
        micListenerInstalled = false
        micListenerDeviceID = 0
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
        NSLog("[AudioProfiles] ContentModeDetection: registered for Now Playing notifications")
        // Debug: write to file to confirm this code runs
        try? "MediaRemote registered at \(Date())\n".write(toFile: "/tmp/audioprofiles-debug.log", atomically: true, encoding: .utf8)

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
        let msg = "[\(Date())] nowPlayingChanged notification fired\n"
        if let fh = FileHandle(forWritingAtPath: "/tmp/audioprofiles-debug.log") {
            fh.seekToEndOfFile()
            fh.write(msg.data(using: .utf8)!)
            fh.closeFile()
        }
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
                    self?.debugLog("GetNowPlayingInfo: keys=\(info.keys.sorted()) count=\(info.count)")
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
            let isPlaying = unsafeBitCast(ptr, to: IsPlayingFn.self)
            isPlaying(DispatchQueue.main) { [weak self] playing in
                Task { @MainActor [weak self] in
                    self?.debugLog("IsPlaying: \(playing)")
                }
            }
        }

        // Try 3: MRMediaRemoteGetNowPlayingApplicationPID (returns pid_t)
        typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString) {
            let getPID = unsafeBitCast(ptr, to: GetPIDFn.self)
            getPID(DispatchQueue.main) { [weak self] pid in
                Task { @MainActor [weak self] in
                    if pid > 0 {
                        let app = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
                        let name = app?.localizedName ?? "pid:\(pid)"
                        let bundleID = app?.bundleIdentifier ?? "?"
                        self?.debugLog("GetPID: pid=\(pid) app=\(name) bundle=\(bundleID)")
                    } else {
                        self?.debugLog("GetPID: no active player (pid=\(pid))")
                    }
                }
            }
        }
    }

    private func handleNowPlayingInfo(_ info: [String: Any]) {
        let appName = info["kMRMediaRemoteNowPlayingInfoApplicationDisplayName"] as? String ?? "?"
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "?"
        let mediaType = info["kMRMediaRemoteNowPlayingInfoMediaType"] as? Int ?? -1
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? -1
        debugLog("NowPlaying: app=\(appName) title=\(title) type=\(mediaType) rate=\(rate)")
        nowPlayingInfo = info
        nowPlayingAppName = info["kMRMediaRemoteNowPlayingInfoApplicationDisplayName"] as? String
        detect()
    }

    private func debugLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: "/tmp/audioprofiles-debug.log") {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        }
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
            case 3:  return (.podcast, appName)
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
                    return (.podcast, appName)
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

        // Something is playing but we can't classify it
        return (.music, appName)
    }
}
