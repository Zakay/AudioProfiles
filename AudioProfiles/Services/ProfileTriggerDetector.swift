import Foundation
import Combine

class ProfileTriggerDetector {
    static let shared = ProfileTriggerDetector()
    let triggerSubject = PassthroughSubject<UUID, Never>()
    private var lastEvaluatedDevices: Set<String> = []
    
    // Service dependencies - dependency injection for clean architecture
    private let deviceMonitor: AudioDeviceMonitor
    private let deviceAnalyzer = DeviceChangeAnalyzer()
    private let triggerMatcher = TriggerMatchingService()
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
        let analysisResult = deviceAnalyzer.analyzeDeviceChanges(
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
        
        // Log analysis summary
        deviceAnalyzer.logAnalysisSummary(profiles: profiles, currentActiveProfile: currentActiveProfile)
        
        // 2. Find the best matching profile based on trigger devices
        let matchResult = triggerMatcher.findBestMatch(
            from: profiles,
            currentDeviceIDs: analysisResult.currentDeviceIDs
        )
        
        // 2.5. Check if this specific trigger should be applied based on timestamps (for automatic triggers)
        if !isManualTrigger, let match = matchResult {
            if !ProfileManager.shared.shouldApplyTrigger(forDeviceIDs: match.profile.triggerDeviceIDs) {
                return // Manual override is blocking this trigger
            }
        }
        
        // Log details if no match found
        if matchResult == nil {
            triggerMatcher.logNoMatchDetails(profiles: profiles, currentDeviceIDs: analysisResult.currentDeviceIDs)
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
