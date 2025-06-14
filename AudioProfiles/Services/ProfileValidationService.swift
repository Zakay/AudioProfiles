import Foundation

/// Handles profile validation and cleanup operations
class ProfileValidationService {
    
    private let deviceFilterService = DeviceFilterService()
    
    /// Clean up invalid device references from a single profile
    /// - Parameter profile: Profile to clean up
    /// - Returns: Cleaned profile
    func cleanupInvalidDevices(in profile: Profile) -> Profile {
        var updatedProfile = profile
        
        // Only remove a device reference if the device is completely unknown (not currently connected *and* not present in device history).
        // This allows profiles to safely reference temporarily disconnected devices without losing their configuration.
        func isDeviceKnown(_ deviceID: String) -> Bool {
            // Device is known if it is currently connected OR exists in history
            return deviceFilterService.isDeviceConnected(deviceID) || deviceFilterService.getDevice(by: deviceID) != nil
        }

        updatedProfile.triggerDeviceIDs = profile.triggerDeviceIDs.filter { isDeviceKnown($0) }
        updatedProfile.publicOutputPriority = profile.publicOutputPriority.filter { isDeviceKnown($0) }
        updatedProfile.publicInputPriority = profile.publicInputPriority.filter { isDeviceKnown($0) }
        updatedProfile.privateOutputPriority = profile.privateOutputPriority.filter { isDeviceKnown($0) }
        updatedProfile.privateInputPriority = profile.privateInputPriority.filter { isDeviceKnown($0) }
        
        return updatedProfile
    }
    
    /// Clean up invalid device references from an array of profiles
    /// - Parameter profiles: Array of profiles to clean up
    /// - Returns: Array of cleaned profiles
    func cleanupInvalidDevices(in profiles: [Profile]) -> [Profile] {
        return profiles.map { cleanupInvalidDevices(in: $0) }
    }
    
    /// Check if two profile arrays are equal (comparing device references)
    /// - Parameters:
    ///   - profiles1: First array of profiles
    ///   - profiles2: Second array of profiles
    /// - Returns: True if arrays are equal, false otherwise
    func profilesEqual(_ profiles1: [Profile], _ profiles2: [Profile]) -> Bool {
        guard profiles1.count == profiles2.count else { return false }
        
        for (profile1, profile2) in zip(profiles1, profiles2) {
            if profile1.id != profile2.id ||
               profile1.triggerDeviceIDs != profile2.triggerDeviceIDs ||
               profile1.publicOutputPriority != profile2.publicOutputPriority ||
               profile1.privateOutputPriority != profile2.privateOutputPriority ||
               profile1.publicInputPriority != profile2.publicInputPriority ||
               profile1.privateInputPriority != profile2.privateInputPriority {
                return false
            }
        }
        
        return true
    }
    
    /// Perform periodic cleanup and return updated profiles if changes were made
    /// - Parameter profiles: Current profiles array
    /// - Returns: Tuple containing cleaned profiles and boolean indicating if changes were made
    func performPeriodicCleanup(on profiles: [Profile]) -> (cleanedProfiles: [Profile], hasChanges: Bool) {
        let cleanedProfiles = cleanupInvalidDevices(in: profiles)
        let hasChanges = !profilesEqual(cleanedProfiles, profiles)
        
        if hasChanges {
            AppLogger.info("🧹 Periodic cleanup: removed invalid device references")
        }
        
        return (cleanedProfiles, hasChanges)
    }
    
    /// Validate and clean profiles with logging if changes were made
    /// - Parameters:
    ///   - profiles: Current profiles array
    ///   - context: Context string for logging (e.g., "on profile load", "before returning")
    /// - Returns: Tuple containing cleaned profiles and boolean indicating if changes were made
    func validateAndCleanProfiles(_ profiles: [Profile], context: String) -> (cleanedProfiles: [Profile], hasChanges: Bool) {
        let cleanedProfiles = cleanupInvalidDevices(in: profiles)
        let hasChanges = !profilesEqual(cleanedProfiles, profiles)
        
        if hasChanges {
            AppLogger.info("🧹 Cleaned up invalid device references \(context)")
        }
        
        return (cleanedProfiles, hasChanges)
    }
} 