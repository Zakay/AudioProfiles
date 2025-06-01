import Foundation

/// Handles profile trigger matching logic
class TriggerMatchingService {
    
    /// Result of trigger matching analysis
    struct MatchResult {
        let profile: Profile
        let matchCount: Int
        let primaryTriggerDevice: String
    }
    
    /// Find the best matching profile based on currently connected devices
    /// - Parameters:
    ///   - profiles: Available profiles to check
    ///   - currentDeviceIDs: Set of currently connected device IDs
    /// - Returns: Best matching profile with match details, or nil if no matches
    func findBestMatch(from profiles: [Profile], currentDeviceIDs: Set<String>) -> MatchResult? {
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
    
    /// Log detailed information about why no profiles matched
    /// - Parameters:
    ///   - profiles: All available profiles  
    ///   - currentDeviceIDs: Currently connected device IDs
    func logNoMatchDetails(profiles: [Profile], currentDeviceIDs: Set<String>) {
        // This method intentionally left empty as debug logging has been removed
    }
} 