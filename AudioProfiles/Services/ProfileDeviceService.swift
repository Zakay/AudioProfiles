import Foundation
import Combine

/// Handles device-related operations specific to profiles
class ProfileDeviceService: ObservableObject {
    
    // Use consolidated filtering service
    private let deviceFilterService = DeviceFilterService()
    private let deviceHistoryService = AudioDeviceHistoryService.shared
    
    /// Get all known devices for UI display (combined current + historical)
    func getAllKnownDevices() -> [AudioDevice] {
        return deviceFilterService.getAllKnownDevices()
    }
    
    /// Validate that a device ID represents a valid, existing device
    func isValidDevice(_ deviceId: String) -> Bool {
        return !deviceId.isEmpty && deviceFilterService.getDevice(by: deviceId) != nil
    }
    
    /// Get device by ID for display purposes
    func getDevice(by id: String) -> AudioDevice? {
        return deviceFilterService.getDevice(by: id)
    }
    
    /// Get formatted device name for UI
    func getDeviceName(by id: String) -> String {
        return deviceFilterService.getDevice(by: id)?.name ?? "Unknown Device"
    }
    
    /// Filter devices by type (input/output)
    func getInputDevices() -> [AudioDevice] {
        return deviceFilterService.filterByType(getAllKnownDevices(), isInput: true)
    }
    
    func getOutputDevices() -> [AudioDevice] {
        return deviceFilterService.filterByType(getAllKnownDevices(), isInput: false)
    }
    
    /// Clean up invalid device references in profile
    func cleanupInvalidDevices(in profile: Profile) -> Profile {
        var updatedProfile = profile
        
        // Filter out invalid device IDs from all lists
        updatedProfile.triggerDeviceIDs = profile.triggerDeviceIDs.filter { isValidDevice($0) }
        updatedProfile.publicOutputPriority = profile.publicOutputPriority.filter { isValidDevice($0) }
        updatedProfile.publicInputPriority = profile.publicInputPriority.filter { isValidDevice($0) }
        updatedProfile.privateOutputPriority = profile.privateOutputPriority.filter { isValidDevice($0) }
        updatedProfile.privateInputPriority = profile.privateInputPriority.filter { isValidDevice($0) }
        
        return updatedProfile
    }
} 