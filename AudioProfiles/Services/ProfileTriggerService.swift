import Foundation
import Combine

/// Handles device-based profile triggering - detects device changes and coordinates profile switching
/// 
/// **Responsibility**: Complete device trigger workflow from detection to profile application
/// **Architecture Role**: Service & Coordinator
/// **Usage**: Public API via shared singleton
/// **Dependencies**: AudioDeviceMonitor, ProfileManager, AudioDeviceHistoryService, NotificationService
@MainActor
class ProfileTriggerService {
    static let shared = ProfileTriggerService()
    // triggerSubject removed — direct calls to ProfileManager.shared.activateProfileFromTrigger()
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
    private let notificationService = NotificationService()
    private let deviceHistoryService = AudioDeviceHistoryService.shared
    private let deviceFilterService = DeviceFilterService()
    
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
    
    /// Find the best matching profile based on trigger rules and currently connected devices.
    /// Supports both specificDevice and transportType rules.
    /// Tie-breaking: when match counts are equal, profiles with more specific (non-class) matches win.
    /// - Parameters:
    ///   - profiles: Available profiles to check
    ///   - currentDeviceIDs: Set of currently connected device IDs
    ///   - currentDevices: Full device list (needed for transport type matching)
    /// - Returns: Best matching profile with match details, or nil if no matches
    private func findBestMatch(from profiles: [Profile], currentDeviceIDs: Set<String>, currentDevices: [AudioDevice] = []) -> MatchResult? {
        // Matching + tie-break logic lives in AudioCore (shared with tests).
        guard let match = AudioCore.findBestTriggerMatch(
            profiles: profiles,
            currentDeviceIDs: currentDeviceIDs,
            currentDevices: currentDevices
        ), let profile = profiles.first(where: { $0.id == match.profileID }) else {
            return nil
        }
        return MatchResult(
            profile: profile,
            matchCount: match.matchCount,
            primaryTriggerDevice: match.primaryTriggerDevice
        )
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
        if currentActiveProfile?.id == match.profile.id && !isManualTrigger {
            // Same profile stays active, but the connected device set changed.
            // Re-run evaluateAndApply so the priority list is re-walked with the
            // new device list — a higher-priority device may have appeared or
            // the current one may have disappeared.  The fingerprint will dedup
            // if the resolved state is actually unchanged.
            AppLogger.info("Same profile '\(match.profile.name)' still active — re-evaluating device priorities")
            ProfileManager.shared.evaluateAndApply()
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
            let triggerName = deviceHistoryService.getDevice(by: match.primaryTriggerDevice)?.name ?? match.primaryTriggerDevice
            ProfileManager.shared.activateProfileFromTrigger(id: match.profile.id, triggerDeviceName: triggerName)
        }
    }
    
    private func handleNoMatchesFallback(
        currentActiveProfile: Profile?,
        profiles: [Profile]
    ) {
        // Always fall back to System Default profile when no triggers match
        // This provides predictable, clear behavior
        if let systemDefaultProfile = profiles.first(where: { $0.isSystemDefault }) {
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
                
                ProfileManager.shared.activateProfileFromTrigger(id: systemDefaultProfile.id)
            }
        } else {
            AppLogger.warning("⚠️ No System Default profile found to fall back to")
        }
    }
    
    // MARK: - Main Evaluation Logic
    
    private func evaluateTriggers(devices: [AudioDevice], isManualTrigger: Bool) {
        // Skip automatic triggers if intentionally disabled
        if !isManualTrigger {
            // Master switch off — the app is passive: no processing and no auto-switching.
            if ProfileManager.shared.isProcessingBypassed {
                AppLogger.info("Ignoring device change - app is disabled via the master switch")
                return
            }
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
        
        // 2. Find the best matching profile based on trigger rules
        let matchResult = findBestMatch(
            from: profiles,
            currentDeviceIDs: analysisResult.currentDeviceIDs,
            currentDevices: devices
        )
        
        // 2.5. Check if this specific trigger should be applied based on timestamps (for automatic triggers)
        if !isManualTrigger, let match = matchResult {
            // Include both legacy triggerDeviceIDs and the primary matched device
            // (which may come from a class-based rule and not be in triggerDeviceIDs)
            var deviceIDsToCheck = match.profile.triggerDeviceIDs
            if !deviceIDsToCheck.contains(match.primaryTriggerDevice) {
                deviceIDsToCheck.append(match.primaryTriggerDevice)
            }
            if !ProfileManager.shared.shouldApplyTrigger(forDeviceIDs: deviceIDsToCheck) {
                return // Manual override is blocking this trigger
            }
        }

        // 2.6. No-match manual-override protection.
        // If no trigger matched and the user has an active manual selection, an
        // unrelated device event must not clobber it by falling back to System Default.
        if !isManualTrigger, matchResult == nil, ProfileManager.shared.hasActiveManualOverride {
            AppLogger.info("No trigger matched but a manual override is active — keeping current profile")
            return
        }

        // 3. Apply the best matching profile or handle fallback
        applyProfileOrFallback(
            matchResult: matchResult,
            currentActiveProfile: currentActiveProfile,
            isManualTrigger: isManualTrigger,
            profiles: profiles
        )
    }
    
    func isDeviceKnown(_ id: String) -> Bool {
        deviceFilterService.isDeviceConnected(id) ||
        deviceFilterService.getDevice(by: id) != nil   // seen in history
    }
} 