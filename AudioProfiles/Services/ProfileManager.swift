import Foundation
import Combine

// AutoSwitchingDisableDuration removed — auto-switching is now a simple on/off toggle.

/// Central coordinating service that orchestrates all profile operations
///
/// **Responsibility**: Acts as a Facade for the profile system, providing a single entry point for UI and other services
/// **Architecture Role**: Service Facade & Coordinator
/// **Usage Pattern**: Singleton (`.shared`)
/// **Key Dependencies**: AudioPipelineService, DeviceFilterService, ProfilePersistenceService, ProfileValidationService, NotificationService
@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    // Core services for real specialized responsibilities
    private let pipelineService = AudioPipelineService()
    private let deviceFilterService = DeviceFilterService()
    private let persistenceService: ProfilePersistenceServiceProtocol = ProfilePersistenceService()
    private let validationService = ProfileValidationService()
    private let notificationService = NotificationService()

    private var cancellables = Set<AnyCancellable>()

    /// Stores and services that need to trigger re-evaluation send to this subject
    /// instead of calling `evaluateAndApply()` directly. This reverses the dependency
    /// arrow: stores no longer import ProfileManager; ProfileManager observes them.
    ///
    /// A 0ms debounce coalesces multiple rapid sends (e.g. night mode toggle + overlay
    /// change) into a single evaluation — matching the existing reentrancy guard behavior.
    let pipelineInvalidationSubject = PassthroughSubject<Void, Never>()

    // MARK: - Published Properties

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfile: Profile?
    @Published private(set) var activeMode: ProfileMode = .public
    @Published private(set) var activeOutputDeviceName: String?
    @Published private(set) var activeOutputDeviceUID: String?
    @Published private(set) var activeInputDeviceName: String?

    struct LastTriggerEvent {
        let profileName: String
        let profileID: UUID
        let triggerDeviceName: String
        let timestamp: Date
        let wasAutomatic: Bool

        var timeAgo: String {
            let interval = Date().timeIntervalSince(timestamp)
            if interval < 60 { return "Just now" }
            if interval < 3600 { return "\(Int(interval / 60))m ago" }
            if interval < 86400 { return "\(Int(interval / 3600))h ago" }
            return "\(Int(interval / 86400))d ago"
        }
    }

    @Published private(set) var lastTriggerEvent: LastTriggerEvent?
    @Published var isProcessingBypassed: Bool = false

    func setProcessingBypassed(_ bypassed: Bool) {
        isProcessingBypassed = bypassed
        UserDefaults.standard.set(bypassed, forKey: "com.audioprofiles.processingBypassed")
        evaluateAndApply()
    }
    @Published private(set) var isAutoSwitchingDisabled: Bool = false

    // Timestamp-based manual override tracking — persisted so force-quit doesn't lose it
    private var lastManualSwitchTimestamp: Date? {
        didSet { UserDefaults.standard.set(lastManualSwitchTimestamp?.timeIntervalSince1970, forKey: "lastManualSwitchTimestamp") }
    }


    // MARK: - evaluateAndApply state

    private var isEvaluating = false
    private var needsReevaluation = false

    // MARK: - Pipeline fingerprint

    private struct PipelineFingerprint: Equatable {
        let profileID: UUID?
        let mode: ProfileMode
        let outputDeviceUID: String?
        let inputDeviceUID: String?
        let effectiveEQ: EQSettings
        let needsVirtualDriver: Bool
    }

    private var lastFingerprint: PipelineFingerprint?

    private init() {
        initialize()
    }

    // MARK: - Initialization

    private func initialize() {
        // Subscribe to pipeline invalidation signals from stores.
        // Debounce(0) coalesces multiple sends within the same run loop turn.
        pipelineInvalidationSubject
            .debounce(for: .milliseconds(0), scheduler: RunLoop.main)
            .sink { [weak self] in self?.evaluateAndApply() }
            .store(in: &cancellables)

        // Restore persisted manual switch timestamp (survives force-quit)
        if let ts = UserDefaults.standard.object(forKey: "lastManualSwitchTimestamp") as? Double {
            lastManualSwitchTimestamp = Date(timeIntervalSince1970: ts)
        }

        // Restore persisted processing bypass state
        isProcessingBypassed = UserDefaults.standard.bool(forKey: "com.audioprofiles.processingBypassed")

        // Load profiles from UserDefaults (no Core Audio calls — safe during init)
        loadProfiles()

        // Set System Default immediately so UI has state before trigger detection runs.
        if !profiles.isEmpty {
            if let systemDefault = profiles.first(where: { $0.isSystemDefault }) {
                setActiveProfileWithoutApplying(systemDefault, restoredMode: getSavedMode(for: systemDefault.id))
            } else {
                let first = profiles.first!
                setActiveProfileWithoutApplying(first, restoredMode: getSavedMode(for: first.id))
            }
        }

        // Early orphan recovery: if the app crashed with our virtual device as
        // system default, switch back immediately so the user has audio.
        // This runs before trigger detection to minimize silent-output time.
        DispatchQueue.main.async {
            AudioPipelineService().recoverOrphanIfNeeded()
        }

        // Defer trigger detection to after init completes — ProfileTriggerService
        // accesses ProfileManager.shared, which deadlocks if called during init.
        // We subscribe to AudioDeviceMonitor's first device emission rather than
        // querying Core Audio directly — this avoids hanging on main thread if
        // coreaudiod is restarting, and avoids deadlocking with background queries.
        DispatchQueue.main.async { [self] in
            // Subscribe to the first device list from AudioDeviceMonitor to initialize
            AudioDeviceMonitor.shared.deviceChangesSubject
                .first()
                .sink { [weak self] devices in
                    guard let self = self else { return }
                    AudioDeviceHistoryService.shared.updateDeviceHistory(with: devices)

                    // Run trigger detection to pick the right profile based on connected devices
                    ProfileTriggerService.shared.triggerAutoDetection()

                    // If no profile was activated by triggers, fall back to System Default
                    if self.activeProfile == nil && !self.profiles.isEmpty {
                        if let systemDefault = self.profiles.first(where: { $0.isSystemDefault }) {
                            AppLogger.info("No trigger matched — activating System Default profile")
                            self.activateProfile(with: systemDefault.id)
                        } else {
                            self.activateProfile(with: self.profiles.first!.id)
                        }
                    }
                }
                .store(in: &self.cancellables)
        }

        // Set up cleanup timer for expired devices
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.periodicCleanup()
        }

        // After coreaudiod restarts, all devices reset — run the full trigger flow
        AudioDeviceMonitor.shared.serviceRestartedSubject
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in
                AppLogger.info("coreaudiod restarted — running full trigger detection flow")
                ProfileTriggerService.shared.triggerAutoDetection()
            }
            .store(in: &cancellables)
    }

    // MARK: - Set active profile without applying (for init)

    private func setActiveProfileWithoutApplying(_ profile: Profile, restoredMode: ProfileMode? = nil) {
        activeProfile = profile
        let targetMode = restoredMode ?? profile.preferredMode
        if activeMode != targetMode {
            activeMode = targetMode
        }
        // Set initial device names so UI shows something before evaluateAndApply runs
        let controlService = AudioDeviceControlService()
        activeOutputDeviceName = controlService.getDefaultOutputDevice()?.name
        activeInputDeviceName = controlService.getDefaultInputDevice()?.name
    }

    /// Call this after ProfileManager initialization is complete to start auto-detection
    func startTriggerDetection() {
        ProfileTriggerService.shared.triggerAutoDetection()
    }

    // MARK: - evaluateAndApply

    /// Single entry point for all state re-evaluation.
    /// Computes the desired audio pipeline state from current profile, EQ, sound modes,
    /// and calls AudioPipelineService to realize it.
    func evaluateAndApply() {
        assert(Thread.isMainThread)
        guard !isEvaluating else {
            needsReevaluation = true
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        var iterations = 0
        repeat {
            needsReevaluation = false
            performEvaluation()
            iterations += 1
            if iterations > 3 {
                AppLogger.warning("evaluateAndApply: exceeded 3 iterations — breaking loop")
                break
            }
        } while needsReevaluation
    }

    private func performEvaluation() {
        // 1. Cancel any pending teardown
        EQEngineService.shared.cancelPendingTeardown()

        // 2. Guard activeProfile exists
        guard let profile = activeProfile else { return }

        // 3. Get current devices
        let devices = AudioDeviceFactory.getCurrentDevices()

        // 4. Resolve output device from priority list (with virtual device look-through)
        let outputList = profile.priorityList(isOutput: true, mode: activeMode)
        var resolvedOutputDevice: AudioDevice?
        var resolvedOutputUID: String?

        for deviceID in outputList {
            if let device = devices.first(where: { $0.id == deviceID && $0.isOutput }) {
                // Check if this is our virtual device — if so, look through to the real device
                if EQDriverService.shared.isOurVirtualDevice(device.id) {
                    if EQEngineService.shared.isRunning, let realUID = EQEngineService.shared.targetDeviceUID {
                        resolvedOutputUID = realUID
                        resolvedOutputDevice = devices.first { $0.id == realUID && $0.isOutput }
                    }
                } else {
                    resolvedOutputDevice = device
                    resolvedOutputUID = device.id
                }
                break
            }
        }

        // If no output from priority list, use current system default (with look-through)
        if resolvedOutputDevice == nil {
            var currentDevice = pipelineService.getDefaultOutputDevice()
            if let dev = currentDevice, EQDriverService.shared.isOurVirtualDevice(dev.id) {
                if EQEngineService.shared.isRunning, let realUID = EQEngineService.shared.targetDeviceUID {
                    currentDevice = devices.first { $0.id == realUID && $0.isOutput }
                } else {
                    // Orphan — will be cleaned up by pipeline service
                    EQDriverService.shared.hide()
                    currentDevice = pipelineService.getDefaultOutputDevice()
                }
            }
            resolvedOutputDevice = currentDevice
            resolvedOutputUID = currentDevice?.id
        }

        // 5. Resolve input device from priority list
        let inputList = profile.priorityList(isOutput: false, mode: activeMode)
        var resolvedInputDevice: AudioDevice?
        var resolvedInputUID: String?

        for deviceID in inputList {
            if let device = devices.first(where: { $0.id == deviceID && $0.isInput }) {
                resolvedInputDevice = device
                resolvedInputUID = device.id
                break
            }
        }

        // If no input from priority, get current default
        if resolvedInputDevice == nil {
            resolvedInputDevice = pipelineService.getDefaultInputDevice()
            resolvedInputUID = resolvedInputDevice?.id
        }

        // 6. Compute effective EQ
        guard let outputUID = resolvedOutputUID else { return }

        let baseEQ = EQStore.shared.settings(for: outputUID)
        let overlay = SoundModesStore.shared.activeOverlay()
        var effectiveEQ = EQSettings.combine(base: baseEQ, overlay: overlay)

        // 6b. Bypass check — flatten EQ when global bypass or per-device bypass is active
        if isProcessingBypassed {
            effectiveEQ = .flat
        }

        // 7. Determine if virtual driver is needed
        let needsVirtualDriver = !effectiveEQ.isFlat && EQInstallationService.shared.isInstalled

        // 8. Fingerprint check — skip if unchanged
        let fingerprint = PipelineFingerprint(
            profileID: profile.id,
            mode: activeMode,
            outputDeviceUID: resolvedOutputUID,
            inputDeviceUID: resolvedInputUID,
            effectiveEQ: effectiveEQ,
            needsVirtualDriver: needsVirtualDriver
        )

        if fingerprint == lastFingerprint {
            return
        }
        lastFingerprint = fingerprint

        // 9. Build virtual device name
        let virtualDeviceName = resolvedOutputDevice.map { "\($0.name) EQ" }

        // 10. Apply via pipeline service
        pipelineService.apply(
            outputDevice: resolvedOutputDevice,
            inputDevice: resolvedInputDevice,
            effectiveEQ: effectiveEQ,
            needsVirtualDriver: needsVirtualDriver,
            virtualDeviceName: virtualDeviceName,
            outputDeviceUID: resolvedOutputUID
        )

        // 11. Update published state for UI
        activeOutputDeviceName = resolvedOutputDevice?.name
        activeOutputDeviceUID = resolvedOutputUID
        activeInputDeviceName = resolvedInputDevice?.name
    }

    // MARK: - Auto-Switching Disable Management

    func disableAutoSwitching() {
        isAutoSwitchingDisabled = true
        clearManualOverride()
        AppLogger.info("Auto-switching disabled")
    }

    func enableAutoSwitching() {
        isAutoSwitchingDisabled = false
        ProfileTriggerService.shared.triggerAutoDetection()
        AppLogger.info("Auto-switching re-enabled")
    }

    // Kept for backward compatibility — callers that used duration-based disable
    func disableAutoSwitching(for duration: Any) {
        disableAutoSwitching()
    }

    // updateRemainingTimeDisplay and getRemainingDisableTime removed —
    // auto-switching is now a simple on/off toggle with no timed duration.

    /// Check if a trigger should be applied based on device connection timestamps
    /// Returns true if the trigger device was connected after the last manual switch
    func shouldApplyTrigger(forDeviceIDs triggerDeviceIDs: [String]) -> Bool {
        // Always allow triggers if no manual switch has occurred
        guard let lastManualSwitch = lastManualSwitchTimestamp else {
            return true
        }

        // Check if any trigger device was connected after the manual switch
        let deviceHistoryService = AudioDeviceHistoryService.shared

        for deviceID in triggerDeviceIDs {
            if let deviceEntry = deviceHistoryService.deviceHistory[deviceID],
               deviceEntry.isCurrentlyActive,
               deviceEntry.lastSeen > lastManualSwitch {
                // This trigger device was connected after manual switch - allow trigger
                AppLogger.info("Trigger device '\(deviceEntry.device.name)' connected after manual switch - allowing auto-switch")
                return true
            }
        }

        // All trigger devices were connected before the manual switch - block trigger
        AppLogger.info("All trigger devices were connected before manual switch - blocking auto-switch")
        return false
    }

    // MARK: - Profile Management API

    /// Called by ProfileTriggerService when a trigger matches a profile.
    func activateProfileFromTrigger(id: UUID, triggerDeviceName: String? = nil) {
        // Only activate profile if auto-switching is not disabled
        guard !isAutoSwitchingDisabled else {
            AppLogger.info("Ignoring trigger event - auto-switching is disabled")
            return
        }

        // Record trigger event for diagnostics before activation
        if let profile = getProfile(by: id) {
            lastTriggerEvent = LastTriggerEvent(
                profileName: profile.name,
                profileID: profile.id,
                triggerDeviceName: triggerDeviceName ?? "Auto",
                timestamp: Date(),
                wasAutomatic: true
            )
        }

        activateProfile(with: id)
    }

    func activateProfile(with id: UUID, isManual: Bool = false) {
        guard let profile = getProfile(by: id) else { return }

        // Skip redundant activation — avoids tearing down and rebuilding the EQ
        // pipeline when the trigger service re-fires for an already-active profile.
        let restoredMode = getSavedMode(for: id)
        let targetMode = restoredMode ?? profile.preferredMode
        if !isManual,
           activeProfile?.id == id,
           activeMode == targetMode {
            return
        }

        activeProfile = profile

        // Use restored mode if provided (persisted from last session), otherwise profile's preferred mode
        if activeMode != targetMode {
            activeMode = targetMode
            AppLogger.info("Switched to \(targetMode.rawValue) mode for profile '\(profile.name)'"
                + (restoredMode != nil ? " (restored)" : " (preferred)"))
        }

        AppLogger.info("Activated profile: \(profile.name)")

        // Handle manual vs automatic selection differently
        if isManual {
            // Record manual selection timestamp
            lastManualSwitchTimestamp = Date()
            AppLogger.info("Manual profile selection: '\(profile.name)' - timestamp recorded")
            notificationService.notifyManualSwitch(profileName: profile.name)

            // Record manual trigger event for diagnostics
            lastTriggerEvent = LastTriggerEvent(
                profileName: profile.name,
                profileID: profile.id,
                triggerDeviceName: "Manual",
                timestamp: Date(),
                wasAutomatic: false
            )
        } else {
            // Automatic selection - clear manual override
            lastManualSwitchTimestamp = nil
        }

        // Save mode for this profile so it persists across restarts
        saveMode(activeMode, for: id)

        // Invalidate fingerprint to force re-evaluation
        lastFingerprint = nil
        evaluateAndApply()
    }

    func toggleMode() {
        activeMode = (activeMode == .public) ? .private : .public
        if let profileID = activeProfile?.id {
            saveMode(activeMode, for: profileID)
        }
        // Invalidate fingerprint to force re-evaluation
        lastFingerprint = nil
        evaluateAndApply()
        AppLogger.info("Switched to \(activeMode.rawValue) mode")
    }

    func createNewProfileInstance() -> Profile {
        return Profile(
            id: UUID(),
            name: "New Profile",
            iconName: "speaker.wave.2.fill",
            triggerDeviceIDs: [],
            publicOutputPriority: [],
            publicInputPriority: [],
            privateOutputPriority: [],
            privateInputPriority: [],
            preferredMode: .public
        )
    }

    func upsert(_ profile: Profile, triggerAutoDetection: Bool = true) {
        let oldProfile = getProfile(by: profile.id)

        // Update profiles array
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }

        // Ensure proper ordering (System Default first)
        profiles = ensureSystemDefaultFirst(profiles)
        saveProfiles()

        // Refresh the active profile if we just edited it.
        if activeProfile?.id == profile.id {
            activeProfile = profile
            let preserveMode = oldProfile?.preferredMode == profile.preferredMode
            if !preserveMode {
                activeMode = profile.preferredMode
            }
            // Invalidate fingerprint and re-evaluate
            lastFingerprint = nil
            evaluateAndApply()
        }

        // Auto-trigger detection after configuration changes
        if triggerAutoDetection {
            ProfileTriggerService.shared.triggerAutoDetection()
        }
    }

    func remove(profileID: UUID) {
        // If this is the active profile, deactivate it
        if activeProfile?.id == profileID {
            activeProfile = nil
        }
        profiles.removeAll { $0.id == profileID }
        saveProfiles()

        // Auto-trigger detection after profile removal
        ProfileTriggerService.shared.triggerAutoDetection()
    }

    func deleteProfiles(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
        saveProfiles()
    }

    func save() {
        saveProfiles()
    }

    private func periodicCleanup() {
        // Clean up profiles referencing devices that expired from history (30+ days)
        let (cleanedProfiles, hasChanges) = validationService.performPeriodicCleanup(on: profiles)

        if hasChanges {
            profiles = cleanedProfiles
            saveProfiles()
        }
    }

    func getProfile(by id: UUID) -> Profile? {
        return profiles.first(where: { $0.id == id })
    }

    func getAllProfiles() -> [Profile] {
        return ensureSystemDefaultFirst(profiles)
    }

    /// Move profile to a new position (System Default always stays first)
    func moveProfile(from sourceIndex: Int, to destinationIndex: Int) {
        // Ensure we don't move System Default or move anything to position 0
        let systemDefaultProfile = profiles.first { $0.isSystemDefault }
        let userProfiles = profiles.filter { !$0.isSystemDefault }

        // Adjust indices for user profiles only (excluding System Default)
        let adjustedSourceIndex = systemDefaultProfile != nil ? sourceIndex - 1 : sourceIndex
        let adjustedDestinationIndex = systemDefaultProfile != nil ? destinationIndex - 1 : destinationIndex

        // Validate indices
        guard adjustedSourceIndex >= 0 && adjustedSourceIndex < userProfiles.count &&
              adjustedDestinationIndex >= 0 && adjustedDestinationIndex < userProfiles.count &&
              adjustedSourceIndex != adjustedDestinationIndex else {
            return
        }

        // Perform the move on user profiles
        var reorderedUserProfiles = userProfiles
        let movedProfile = reorderedUserProfiles.remove(at: adjustedSourceIndex)
        reorderedUserProfiles.insert(movedProfile, at: adjustedDestinationIndex)

        // Rebuild profiles array with System Default first
        if let systemDefault = systemDefaultProfile {
            profiles = [systemDefault] + reorderedUserProfiles
        } else {
            profiles = reorderedUserProfiles
        }

        saveProfiles()
        AppLogger.info("Moved profile to new position")
    }

    /// Ensure System Default profile is always first in the array
    private func ensureSystemDefaultFirst(_ profileList: [Profile]) -> [Profile] {
        let systemDefault = profileList.first { $0.isSystemDefault }
        let userProfiles = profileList.filter { !$0.isSystemDefault }

        if let systemDefault = systemDefault {
            return [systemDefault] + userProfiles
        } else {
            return userProfiles
        }
    }

    // MARK: - Private Implementation

    private func loadProfiles() {
        let loadedProfiles = persistenceService.loadProfiles()

        // Clean up references to devices that may have expired while app was not running
        let (cleanedProfiles, hasChanges) = validationService.validateAndCleanProfiles(
            loadedProfiles,
            context: "on profile load"
        )

        var finalProfiles = cleanedProfiles

        // Ensure we always have a System Default profile
        let hasSystemDefault = finalProfiles.contains { $0.isSystemDefault }
        if !hasSystemDefault {
            AppLogger.info("No System Default profile found, creating one")
            let systemDefaultProfile = Profile(
                id: UUID(),
                name: "System Default",
                iconName: "speaker.wave.2.fill",
                triggerDeviceIDs: [],
                publicOutputPriority: [],
                publicInputPriority: [],
                privateOutputPriority: [],
                privateInputPriority: [],
                preferredMode: .public,
                isSystemDefault: true
            )
            finalProfiles.append(systemDefaultProfile)
        }

        profiles = finalProfiles

        // Ensure proper ordering (System Default first)
        profiles = ensureSystemDefaultFirst(profiles)

        // Save if we made changes or added System Default
        if hasChanges || !hasSystemDefault {
            saveProfiles()
        }

        AppLogger.info("Loaded \(profiles.count) profiles")
    }

    private func saveProfiles() {
        _ = persistenceService.saveProfiles(profiles)
    }

    // MARK: - Per-Profile Mode Persistence

    private func getSavedMode(for profileID: UUID) -> ProfileMode? {
        guard let raw = UserDefaults.standard.string(forKey: "ProfileMode_\(profileID.uuidString)") else {
            return nil
        }
        return ProfileMode(rawValue: raw)
    }

    private func saveMode(_ mode: ProfileMode, for profileID: UUID) {
        UserDefaults.standard.set(mode.rawValue, forKey: "ProfileMode_\(profileID.uuidString)")
    }

    /// Clear manual override timestamp
    private func clearManualOverride() {
        lastManualSwitchTimestamp = nil
    }
}
