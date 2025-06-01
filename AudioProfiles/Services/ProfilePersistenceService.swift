import Foundation

/// Handles profile persistence operations (saving/loading from UserDefaults)
class ProfilePersistenceService {
    
    private let userDefaultsKey = "AudioProfiles"
    
    /// Load profiles from UserDefaults
    /// - Returns: Array of loaded profiles, or empty array if none found
    func loadProfiles() -> [Profile] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let loadedProfiles = try? JSONDecoder().decode([Profile].self, from: data) else {
            AppLogger.info("No stored profiles found in UserDefaults")
            return []
        }
        
        AppLogger.info("Loaded \(loadedProfiles.count) profiles from UserDefaults")
        return loadedProfiles
    }
    
    /// Save profiles to UserDefaults
    /// - Parameter profiles: Array of profiles to save
    /// - Returns: Success status
    func saveProfiles(_ profiles: [Profile]) -> Bool {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            return true
        } catch {
            AppLogger.error("Failed to save profiles: \(error)")
            return false
        }
    }
    
    /// Check if any profiles exist in UserDefaults
    /// - Returns: True if profiles exist, false otherwise
    func hasStoredProfiles() -> Bool {
        return UserDefaults.standard.data(forKey: userDefaultsKey) != nil
    }
    
    /// Clear all stored profiles from UserDefaults
    func clearAllProfiles() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        AppLogger.info("Cleared all profiles from UserDefaults")
    }
} 