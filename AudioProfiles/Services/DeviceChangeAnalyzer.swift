import Foundation

/// Analyzes device changes and determines if trigger evaluation should proceed
class DeviceChangeAnalyzer {
    
    /// Result of device change analysis
    struct AnalysisResult {
        let currentDeviceIDs: Set<String>
        let shouldProceed: Bool
        let reason: String
    }
    
    /// Analyze device changes and determine if trigger evaluation should proceed
    /// - Parameters:
    ///   - devices: Currently connected devices
    ///   - lastEvaluatedDevices: Previously evaluated device IDs
    ///   - isManualTrigger: Whether this is a manual trigger (always proceeds)
    /// - Returns: Analysis result with recommendation
    func analyzeDeviceChanges(
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
    
    /// Log device analysis summary
    /// - Parameters:
    ///   - profiles: Available profiles
    ///   - currentActiveProfile: Currently active profile
    func logAnalysisSummary(profiles: [Profile], currentActiveProfile: Profile?) {
        // This method intentionally left empty as debug logging has been removed
    }
} 