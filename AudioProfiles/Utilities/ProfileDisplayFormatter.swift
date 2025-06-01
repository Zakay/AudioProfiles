import Foundation

/// Utility for formatting Profile data for display purposes
/// Removes presentation logic from the Profile model
class ProfileDisplayFormatter {
    
    // Injected device service for resolving device information
    private let deviceHistoryService: AudioDeviceHistoryService
    
    /// Initialize with device history service (defaults to shared instance)
    init(deviceHistoryService: AudioDeviceHistoryService = AudioDeviceHistoryService.shared) {
        self.deviceHistoryService = deviceHistoryService
    }
    
    /// Get formatted output device name for display
    func outputDeviceName(for profile: Profile) -> String {
        let validDeviceId: String? = profile.publicOutputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } 
                         ?? profile.privateOutputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil }
        
        if let id = validDeviceId, let device = deviceHistoryService.getDevice(by: id) {
            return "Output: \(device.name)"
        }
        return "Output: Default"
    }
    
    /// Get formatted input device name for display
    func inputDeviceName(for profile: Profile) -> String {
        let validDeviceId: String? = profile.publicInputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } 
                         ?? profile.privateInputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil }
        
        if let id = validDeviceId, let device = deviceHistoryService.getDevice(by: id) {
            return "Input: \(device.name)"
        }
        return "Input: Default"
    }
    
    /// Get summary of trigger devices for display
    func triggerDevicesDisplay(for profile: Profile) -> String {
        if profile.triggerDeviceIDs.isEmpty {
            return "No Triggers"
        }
        
        let validTriggerNames: [String] = profile.triggerDeviceIDs.compactMap { deviceId in
            guard !deviceId.isEmpty,
                  let device = deviceHistoryService.getDevice(by: deviceId) else { return nil }
            return device.name
        }
        
        if validTriggerNames.isEmpty {
            return "No Valid Triggers"
        }
        
        if validTriggerNames.count == 1 {
            return validTriggerNames[0]
        } else {
            return "\(validTriggerNames.count) Triggers"
        }
    }
    
    /// Get formatted hotkey description
    func hotkeyDisplay(for profile: Profile) -> String {
        if let hotkey = profile.hotkey {
            return "Hotkey: \(hotkey.description)"
        }
        return ""
    }
    
    /// Get combined secondary info line for UI display
    func secondaryInfoLine(for profile: Profile) -> String {
        var parts: [String] = []
        
        // Check if any valid devices are configured (non-empty IDs AND devices actually exist)
        let hasValidOutputDevice: Bool = (profile.publicOutputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } != nil) || 
                                  (profile.privateOutputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } != nil)
        let hasValidInputDevice: Bool = (profile.publicInputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } != nil) || 
                                 (profile.privateInputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } != nil)
        
        if hasValidOutputDevice || hasValidInputDevice {
            // Show individual device info when valid devices are configured
            if hasValidOutputDevice {
                parts.append(outputDeviceName(for: profile))
            }
            if hasValidInputDevice {
                parts.append(inputDeviceName(for: profile))
            }
        } else {
            // Show unified message when no valid devices are configured
            parts.append("No prioritized devices set")
        }
        
        // Add hotkey info if present
        if profile.hotkey != nil {
            parts.append(hotkeyDisplay(for: profile))
        }
        
        return parts.joined(separator: " • ")
    }
} 