import Foundation
import Combine

/// Duration options for disabling auto-switching
enum AutoSwitchingDisableDuration {
    case hours(Int)
    case untilEndOfDay
    case forever
    
    var displayName: String {
        switch self {
        case .hours(let count):
            return "\(count)h"
        case .untilEndOfDay:
            return "End of Day"
        case .forever:
            return "Forever"
        }
    }
}

/// Coordinating service that orchestrates profile operations 
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    
    // Core services for real specialized responsibilities
    private let activationService = ProfileActivationService()
    private let deviceService = ProfileDeviceService()
    private let persistenceService = ProfilePersistenceService()
    private let validationService = ProfileValidationService()
    private let notificationService = ProfileSwitchNotificationService.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Published Properties
    
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfile: Profile?
    @Published private(set) var activeMode: ProfileMode = .public
    @Published private(set) var isAutoSwitchingDisabled: Bool = false
    @Published private(set) var autoSwitchingDisabledUntil: Date?
    @Published private(set) var remainingDisableTime: String?
    
    // Timestamp-based manual override tracking
    private var lastManualSwitchTimestamp: Date?
    
    // Auto-switching disable timer
    private var autoSwitchingTimer: Timer?
    private var displayUpdateTimer: Timer?

    private init() {
        setupServiceBindings()
        initialize()
    }
    
    // MARK: - Initialization
    
    private func setupServiceBindings() {
        // Forward published properties from activation service
        activationService.$activeProfile
            .assign(to: \.activeProfile, on: self)
            .store(in: &cancellables)
            
        activationService.$activeMode
            .assign(to: \.activeMode, on: self)
            .store(in: &cancellables)
    }
    
    private func initialize() {
        loadProfiles()
        
        // Initialize device history with current devices
        let currentDevices = AudioDeviceFactory.getCurrentDevices()
        AudioDeviceHistoryService.shared.updateDeviceHistory(with: currentDevices)
        
        // Set up cleanup timer for expired devices
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.periodicCleanup()
        }
        
        // Auto-activate appropriate profile
        if activeProfile == nil && !profiles.isEmpty {
            // Try to restore last used profile, otherwise use System Default
            if let lastUsedProfileID = getLastUsedProfileID(),
               let lastUsedProfile = getProfile(by: lastUsedProfileID) {
                AppLogger.info("Restoring last used profile: \(lastUsedProfile.name)")
                activateProfile(with: lastUsedProfile.id)
            } else if let systemDefault = profiles.first(where: { $0.name == "System Default" }) {
                AppLogger.info("Activating System Default profile")
                activateProfile(with: systemDefault.id)
            } else {
                // Fallback to first profile when no System Default exists
                activateProfile(with: profiles.first!.id)
            }
        }
        
        // Subscribe to trigger events
        ProfileTriggerService.shared.triggerSubject
            .sink { [weak self] profileID in
                // Only activate profile if auto-switching is not disabled
                guard let self = self, !self.isAutoSwitchingDisabled else {
                    AppLogger.info("Ignoring trigger event - auto-switching is disabled")
                    return
                }
                self.activateProfile(with: profileID)
            }
            .store(in: &cancellables)
    }
    
    /// Call this after ProfileManager initialization is complete to start auto-detection
    func startTriggerDetection() {
        ProfileTriggerService.shared.triggerAutoDetection()
    }
    
    // MARK: - Auto-Switching Disable Management
    
    func disableAutoSwitching(for duration: AutoSwitchingDisableDuration) {
        let endDate: Date?
        
        switch duration {
        case .forever:
            endDate = nil
        case .untilEndOfDay:
            let calendar = Calendar.current
            let today = Date()
            endDate = calendar.dateInterval(of: .day, for: today)?.end
        case .hours(let hours):
            endDate = Date().addingTimeInterval(TimeInterval(hours * 3600))
        }
        
        isAutoSwitchingDisabled = true
        autoSwitchingDisabledUntil = endDate
        
        // Clear manual override - intentional disable takes precedence
        clearManualOverride()
        
        // Clear existing timers
        autoSwitchingTimer?.invalidate()
        displayUpdateTimer?.invalidate()
        autoSwitchingTimer = nil
        displayUpdateTimer = nil
        
        // Set up timer for re-enabling if not disabled forever
        if let endDate = endDate {
            let timeInterval = endDate.timeIntervalSinceNow
            if timeInterval > 0 {
                // Timer to re-enable auto-switching
                autoSwitchingTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
                    self?.enableAutoSwitching()
                }
                
                // Timer to update display every minute
                displayUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.updateRemainingTimeDisplay()
                }
                
                // Initial update
                updateRemainingTimeDisplay()
            }
        } else {
            remainingDisableTime = nil
        }
        
        AppLogger.info("Auto-switching disabled until: \(endDate?.description ?? "forever")")
    }
    
    func enableAutoSwitching() {
        isAutoSwitchingDisabled = false
        autoSwitchingDisabledUntil = nil
        remainingDisableTime = nil
        
        // Clear timers
        autoSwitchingTimer?.invalidate()
        displayUpdateTimer?.invalidate()
        autoSwitchingTimer = nil
        displayUpdateTimer = nil
        
        // Trigger auto-detection now that it's re-enabled
        ProfileTriggerService.shared.triggerAutoDetection()
        
        AppLogger.info("Auto-switching re-enabled")
    }
    
    private func updateRemainingTimeDisplay() {
        guard isAutoSwitchingDisabled, let endDate = autoSwitchingDisabledUntil else {
            remainingDisableTime = nil
            return
        }
        
        let timeInterval = endDate.timeIntervalSinceNow
        if timeInterval <= 0 {
            // Time expired, enable auto-switching
            enableAutoSwitching()
            return
        }
        
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval.truncatingRemainder(dividingBy: 3600)) / 60
        
        if hours > 0 {
            remainingDisableTime = "\(hours)h \(minutes)m"
        } else {
            remainingDisableTime = "\(minutes)m"
        }
    }
    
    func getRemainingDisableTime() -> String? {
        return remainingDisableTime
    }
    
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

    func activateProfile(with id: UUID, isManual: Bool = false) {
        guard let profile = getProfile(by: id) else { return }
        
        activationService.activateProfile(profile)
        
        // Handle manual vs automatic selection differently
        if isManual {
            // Record manual selection timestamp
            lastManualSwitchTimestamp = Date()
            AppLogger.info("Manual profile selection: '\(profile.name)' - timestamp recorded")
            notificationService.notifyManualSwitch(profileName: profile.name)
        } else {
            // Automatic selection - clear manual override
            lastManualSwitchTimestamp = nil
        }
        
        // Save as last used profile (unless it's System Default)
        if !profile.isSystemDefault {
            saveLastUsedProfileID(id)
        }
    }

    func toggleMode() {
        activationService.toggleMode()
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
            hotkey: nil,
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
        
        // Handle hotkey changes using HotkeyCoordinator
        HotkeyCoordinator.shared.handleHotkeyChanges(
            oldHotkey: oldProfile?.hotkey, 
            newHotkey: profile.hotkey
        )
        
        // Auto-trigger detection after configuration changes
        if triggerAutoDetection {
            ProfileTriggerService.shared.triggerAutoDetection()
        }
    }
    
    func remove(profileID: UUID) {
        // Get the profile before removal to check for hotkey cleanup
        let profileToRemove = getProfile(by: profileID)
        
        // If this is the active profile, deactivate it
        if activeProfile?.id == profileID {
            activationService.deactivateProfile()
        }
        profiles.removeAll { $0.id == profileID }
        saveProfiles()
        
        // Clean up hotkey if the removed profile had one
        if profileToRemove?.hotkey != nil {
            HotkeyCoordinator.shared.refreshHotkeys()
        }
        
        // Auto-trigger detection after profile removal
        ProfileTriggerService.shared.triggerAutoDetection()
    }
    
    func deleteProfiles(at offsets: IndexSet) {
        // Check if any profiles being deleted have hotkeys
        let profilesToDelete = offsets.map { profiles[$0] }
        let hasHotkeys = profilesToDelete.contains { $0.hotkey != nil }
        
        profiles.remove(atOffsets: offsets)
        saveProfiles()
        
        // Refresh hotkeys if any deleted profiles had hotkeys
        if hasHotkeys {
            HotkeyCoordinator.shared.refreshHotkeys()
        }
    }
    
    func save() {
        saveProfiles()
        HotkeyCoordinator.shared.refreshHotkeys()
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
        let hasSystemDefault = finalProfiles.contains { $0.name == "System Default" }
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
                hotkey: nil,
                preferredMode: .public
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
    
    private func getLastUsedProfileID() -> UUID? {
        guard let uuidString = UserDefaults.standard.string(forKey: "LastUsedProfileID") else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }
    
    private func saveLastUsedProfileID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "LastUsedProfileID")
    }
    
    /// Clear manual override timestamp
    private func clearManualOverride() {
        lastManualSwitchTimestamp = nil
    }
}
