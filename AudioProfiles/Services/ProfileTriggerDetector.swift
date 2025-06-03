import Foundation
import Combine

class ProfileTriggerDetector {
    static let shared = ProfileTriggerDetector()
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
    
    // Service dependencies - dependency injection for clean architecture
    private let deviceMonitor: AudioDeviceMonitor
    private let activationCoordinator = ProfileActivationCoordinator()
    
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
        AudioDeviceHistoryService.shared.updateDeviceHistory(with: devices)
        
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
        activationCoordinator.applyProfileOrFallback(
            matchResult: matchResult,
            currentActiveProfile: currentActiveProfile,
            isManualTrigger: isManualTrigger,
            profiles: profiles,
            triggerSubject: triggerSubject
        )
    }
}
