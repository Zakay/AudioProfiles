import Foundation
import Combine

class ProfileTriggerDetector {
    static let shared = ProfileTriggerDetector()
    let triggerSubject = PassthroughSubject<UUID, Never>()
    private var lastEvaluatedDevices: Set<String> = []
    
    // Service dependencies
    private let deviceAnalyzer = DeviceChangeAnalyzer()
    private let triggerMatcher = TriggerMatchingService()
    private let activationCoordinator = ProfileActivationCoordinator()

    private init() {
        // Removed automatic device change detection
        // Profile trigger detection is now triggered manually or by timer if needed
    }
    
    /// Manually trigger auto-detection based on currently connected devices
    /// This should be called at app startup and can be called from the UI
    /// Always runs full evaluation regardless of device list changes
    func triggerAutoDetection() {
        let currentDevices = AudioDeviceFactory.getCurrentDevices()
        AppLogger.info("🔄 Manual auto-detection triggered with \(currentDevices.count) devices")
        evaluateTriggers(devices: currentDevices, isManualTrigger: true)
    }

    private func evaluateTriggers(devices: [AudioDevice], isManualTrigger: Bool) {
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
