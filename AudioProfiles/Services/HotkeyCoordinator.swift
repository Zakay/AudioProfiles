import Foundation

/// Coordinates hotkey registration and management between ProfileManager and HotkeyManager
class HotkeyCoordinator {
    /// Shared singleton instance
    static let shared = HotkeyCoordinator()
    
    /// Setup initial hotkeys for all profiles
    func setupHotkeys() {
        // Register hotkeys for all profiles
        let profiles = ProfileManager.shared.profiles
        for profile in profiles {
            if let hotkey = profile.hotkey {
                HotkeyManager.shared.register(hotkey: hotkey) {
                    ProfileManager.shared.activateProfile(with: profile.id, isManual: true)
                }
            }
        }
        AppLogger.info("Registered hotkeys for \(profiles.filter { $0.hotkey != nil }.count) profiles")
    }
    
    /// Refresh all hotkey registrations
    func refreshHotkeys() {
        HotkeyManager.shared.unregisterAll()
        setupHotkeys()
    }
    
    /// Register hotkey for a specific profile
    func registerHotkey(for profile: Profile) {
        guard let hotkey = profile.hotkey else { return }
        
        HotkeyManager.shared.register(hotkey: hotkey) {
            ProfileManager.shared.activateProfile(with: profile.id, isManual: true)
        }
        AppLogger.info("Registered hotkey \(hotkey.description) for profile '\(profile.name)'")
    }
    
    /// Check for hotkey conflicts across all profiles
    func checkForConflicts(excluding profileID: UUID? = nil) -> [HotkeyConflict] {
        let profiles = ProfileManager.shared.profiles
        var conflicts: [HotkeyConflict] = []
        
        for i in 0..<profiles.count {
            guard let hotkey1 = profiles[i].hotkey else { continue }
            guard profileID == nil || profiles[i].id != profileID else { continue }
            
            for j in (i+1)..<profiles.count {
                guard let hotkey2 = profiles[j].hotkey else { continue }
                guard profileID == nil || profiles[j].id != profileID else { continue }
                
                if hotkey1.conflicts(with: hotkey2) {
                    conflicts.append(HotkeyConflict(
                        profile1: profiles[i],
                        profile2: profiles[j],
                        hotkey: hotkey1
                    ))
                }
            }
        }
        
        return conflicts
    }
    
    /// Handle hotkey changes for a profile (moved from ProfileManager)
    /// - Parameters:
    ///   - oldHotkey: Previous hotkey (if any)
    ///   - newHotkey: New hotkey (if any)
    func handleHotkeyChanges(oldHotkey: Hotkey?, newHotkey: Hotkey?) {
        // If hotkeys are the same, no need to change anything
        if hotkeyUnchanged(oldHotkey: oldHotkey, newHotkey: newHotkey) {
            return
        }
        
        // Refresh all hotkeys - this handles both deregistration and registration
        refreshHotkeys()
    }
    
    /// Check if hotkey is unchanged
    /// - Parameters:
    ///   - oldHotkey: Previous hotkey
    ///   - newHotkey: New hotkey
    /// - Returns: True if hotkeys are the same
    private func hotkeyUnchanged(oldHotkey: Hotkey?, newHotkey: Hotkey?) -> Bool {
        return oldHotkey?.keyCode == newHotkey?.keyCode && 
               oldHotkey?.modifiers == newHotkey?.modifiers
    }
}

/// Represents a hotkey conflict between two profiles
struct HotkeyConflict {
    let profile1: Profile
    let profile2: Profile
    let hotkey: Hotkey
    
    var description: String {
        return "Hotkey \(hotkey.description) is used by both '\(profile1.name)' and '\(profile2.name)'"
    }
} 