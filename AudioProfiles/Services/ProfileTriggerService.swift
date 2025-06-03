import Foundation
import Combine

/// Handles device-based profile triggering - detects device changes and coordinates profile switching
/// 
/// **Responsibility**: Complete device trigger workflow from detection to profile application
/// **Architecture Role**: Service  
/// **Usage**: Public API via shared singleton
/// **Dependencies**: AudioDeviceMonitor, ProfileManager, AudioDeviceHistoryService, NotificationService
class ProfileTriggerService {
    static let shared = ProfileTriggerService()
    let triggerSubject = PassthroughSubject<UUID, Never>()
    private var lastEvaluatedDevices: Set<String> = []
    
    // MARK: - Analysis Result
    
    /// Result of device change analysis
    private struct AnalysisResult {
        let currentDeviceIDs: Set<String>
        let shouldProceed: Bool
        let reason: String
    }
    
    // MARK: - Match Result
    
    /// Result of trigger matching analysis
    struct MatchResult {
        let profile: Profile
        let matchCount: Int
        let primaryTriggerDevice: String
    }
    
    // Service dependencies
    private let deviceMonitor: AudioDeviceMonitor
    private let notificationService = ProfileSwitchNotificationService.shared
    private let deviceHistoryService = AudioDeviceHistoryService.shared
    
    private var cancellables = Set<AnyCancellable>()

    private init(deviceMonitor: AudioDeviceMonitor = AudioDeviceMonitor.shared) {
        self.deviceMonitor = deviceMonitor
        setupRealTimeDeviceMonitoring()
    }
    
    /// Set up real-time device change monitoring
    private func setupRealTimeDeviceMonitoring() {
        deviceMonitor.deviceChangesSubject
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main) // Debounce rapid changes
            .sink { [weak self] devices in
                self?.handleAutomaticDeviceChange(devices: devices)
            }
            .store(in: &cancellables)
            
        AppLogger.info("Real-time device monitoring enabled")
    }
    
    /// Handle automatic device changes (plug/unplug events)
    private func handleAutomaticDeviceChange(devices: [AudioDevice]) {
        AppLogger.debug("Real-time device change detected, evaluating triggers...")
        evaluateTriggers(devices: devices, isManualTrigger: false)
    }
    
    /// Manually trigger auto-detection based on currently connected devices
    /// This should be called at app startup and can be called from the UI
    /// Always runs full evaluation regardless of device list changes
    func triggerAutoDetection() {
        let currentDevices = AudioDeviceFactory.getCurrentDevices()
        AppLogger.info("Manual auto-detection triggered with \(currentDevices.count) devices")
        evaluateTriggers(devices: currentDevices, isManualTrigger: true)
    }
    
    // MARK: - Device Analysis
    
    /// Analyze device changes and determine if trigger evaluation should proceed
    /// - Parameters:
    ///   - devices: Currently connected devices
    ///   - lastEvaluatedDevices: Previously evaluated device IDs
    ///   - isManualTrigger: Whether this is a manual trigger (always proceeds)
    /// - Returns: Analysis result with recommendation
    private func analyzeDeviceChanges(
        devices: [AudioDevice],
        lastEvaluatedDevices: Set<String>,
        isManualTrigger: Bool
    ) -> AnalysisResult {
        
        // Update device history with current devices first
        deviceHistoryService.updateDeviceHistory(with: devices)
        
        let currentDeviceIDs = Set(devices.map { $0.id })
        
        // Check if device list actually changed to avoid unnecessary processing
        // Skip this check for manual triggers - user wants to force re-evaluation
        if !isManualTrigger && currentDeviceIDs == lastEvaluatedDevices {
            return AnalysisResult(
                currentDeviceIDs: currentDeviceIDs,
                shouldProceed: false,
                reason: "Device list unchanged"
            )
        }
        
        let reason = isManualTrigger ? "Manual trigger requested" : "Device list changed"
        return AnalysisResult(
            currentDeviceIDs: currentDeviceIDs,
            shouldProceed: true,
            reason: reason
        )
    }
    
    /// Find the best matching profile based on currently connected devices
    /// - Parameters:
    ///   - profiles: Available profiles to check
    ///   - currentDeviceIDs: Set of currently connected device IDs
    /// - Returns: Best matching profile with match details, or nil if no matches
    private func findBestMatch(from profiles: [Profile], currentDeviceIDs: Set<String>) -> MatchResult? {
        var bestMatch: MatchResult? = nil
        
        for profile in profiles {
            guard !profile.triggerDeviceIDs.isEmpty else { continue }
            
            let matchingDevices = profile.triggerDeviceIDs.filter { triggerID in
                currentDeviceIDs.contains(triggerID)
            }
            
            if !matchingDevices.isEmpty {
                // Prefer profile with more matching devices, or if tied, prefer the first one found
                if bestMatch == nil || matchingDevices.count > bestMatch!.matchCount {
                    bestMatch = MatchResult(
                        profile: profile,
                        matchCount: matchingDevices.count,
                        primaryTriggerDevice: matchingDevices.first!
                    )
                }
            }
        }
        
        return bestMatch
    }
    
    // MARK: - Profile Coordination
    
    /// Apply the best matching profile or handle fallback scenarios
    /// - Parameters:
    ///   - matchResult: Result from trigger matching (nil if no matches)
    ///   - currentActiveProfile: Currently active profile
    ///   - isManualTrigger: Whether this was manually triggered
    ///   - profiles: Available profiles for fallback
    private func applyProfileOrFallback(
        matchResult: MatchResult?,
        currentActiveProfile: Profile?,
        isManualTrigger: Bool,
        profiles: [Profile]
    ) {
        
        if let match = matchResult {
            // Apply the best matching profile
            applyMatchingProfile(
                match: match,
                currentActiveProfile: currentActiveProfile,
                isManualTrigger: isManualTrigger
            )
        } else {
            // No matches found - handle fallback
            handleNoMatchesFallback(
                currentActiveProfile: currentActiveProfile,
                profiles: profiles
            )
        }
    }
    
    private func applyMatchingProfile(
        match: MatchResult,
        currentActiveProfile: Profile?,
        isManualTrigger: Bool
    ) {
        // For manual triggers (like profile saves), always re-apply even if same profile
        // because profile settings (like preferred mode) may have changed
        if currentActiveProfile?.id == match.profile.id && !isManualTrigger {
            // Profile already active, no change needed
        } else {
            if currentActiveProfile?.id == match.profile.id {
                AppLogger.info("Re-applying profile '\(match.profile.name)' (manual trigger - settings may have changed)")
            } else {
                AppLogger.info("Auto-detected profile: '\(match.profile.name)' (matched \(match.matchCount) trigger device(s), primary: \(match.primaryTriggerDevice))")
                
                // Show notification for triggered switch (only for new activations)
                if !isManualTrigger {
                    notificationService.notifyTriggeredSwitch(
                        profileName: match.profile.name,
                        triggerDevice: match.primaryTriggerDevice,
                        matchCount: match.matchCount
                    )
                }
            }
            triggerSubject.send(match.profile.id)
        }
    }
    
    private func handleNoMatchesFallback(
        currentActiveProfile: Profile?,
        profiles: [Profile]
    ) {
        // Always fall back to System Default profile when no triggers match
        // This provides predictable, clear behavior
        if let systemDefaultProfile = profiles.first(where: { $0.name == "System Default" }) {
            if currentActiveProfile?.id != systemDefaultProfile.id {
                AppLogger.info("No triggers matched - falling back to System Default profile")
                
                // Show notification for fallback
                // Try to determine what device was lost by checking what the current profile was triggered by
                let lostDevice = currentActiveProfile?.triggerDeviceIDs.first.flatMap { deviceID in
                    deviceHistoryService.getDevice(by: deviceID)?.name
                }
                
                notificationService.notifyFallbackSwitch(
                    profileName: systemDefaultProfile.name,
                    lostTriggerDevice: lostDevice
                )
                
                triggerSubject.send(systemDefaultProfile.id)
            }
        } else {
            AppLogger.warning("⚠️ No System Default profile found to fall back to")
        }
    }
    
    // MARK: - Main Evaluation Logic
    
    private func evaluateTriggers(devices: [AudioDevice], isManualTrigger: Bool) {
        // Skip automatic triggers if intentionally disabled
        if !isManualTrigger {
            // Check for intentional auto-switching disable (user chose to disable)
            if ProfileManager.shared.isAutoSwitchingDisabled {
                AppLogger.info("Ignoring device change - auto-switching is intentionally disabled")
                return
            }
        }
        
        // 1. Analyze device changes and determine if we should proceed
        let analysisResult = analyzeDeviceChanges(
            devices: devices,
            lastEvaluatedDevices: lastEvaluatedDevices,
            isManualTrigger: isManualTrigger
        )
        
        guard analysisResult.shouldProceed else {
            return // Early exit if no changes detected
        }
        
        // Update our tracked device list
        lastEvaluatedDevices = analysisResult.currentDeviceIDs
        
        // Get current state
        let profiles = ProfileManager.shared.profiles
        let currentActiveProfile = ProfileManager.shared.activeProfile
        
        // 2. Find the best matching profile based on trigger devices
        let matchResult = findBestMatch(
            from: profiles,
            currentDeviceIDs: analysisResult.currentDeviceIDs
        )
        
        // 2.5. Check if this specific trigger should be applied based on timestamps (for automatic triggers)
        if !isManualTrigger, let match = matchResult {
            if !ProfileManager.shared.shouldApplyTrigger(forDeviceIDs: match.profile.triggerDeviceIDs) {
                return // Manual override is blocking this trigger
            }
        }
        
        // 3. Apply the best matching profile or handle fallback
        applyProfileOrFallback(
            matchResult: matchResult,
            currentActiveProfile: currentActiveProfile,
            isManualTrigger: isManualTrigger,
            profiles: profiles
        )
    }
} 