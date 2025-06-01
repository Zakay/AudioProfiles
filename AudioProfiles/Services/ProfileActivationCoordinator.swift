import Foundation
import Combine

/// Coordinates profile activation decisions - applies best matching profile or falls back to default
class ProfileActivationCoordinator {
    
    /// Apply the best matching profile or handle fallback scenarios
    /// - Parameters:
    ///   - matchResult: Result from trigger matching (nil if no matches)
    ///   - currentActiveProfile: Currently active profile
    ///   - isManualTrigger: Whether this was manually triggered
    ///   - profiles: Available profiles for fallback
    ///   - triggerSubject: Subject to send profile activation events
    func applyProfileOrFallback(
        matchResult: TriggerMatchingService.MatchResult?,
        currentActiveProfile: Profile?,
        isManualTrigger: Bool,
        profiles: [Profile],
        triggerSubject: PassthroughSubject<UUID, Never>
    ) {
        
        if let match = matchResult {
            // Apply the best matching profile
            applyMatchingProfile(
                match: match,
                currentActiveProfile: currentActiveProfile,
                isManualTrigger: isManualTrigger,
                triggerSubject: triggerSubject
            )
        } else {
            // No matches found - handle fallback
            handleNoMatchesFallback(
                currentActiveProfile: currentActiveProfile,
                profiles: profiles,
                triggerSubject: triggerSubject
            )
        }
    }
    
    private func applyMatchingProfile(
        match: TriggerMatchingService.MatchResult,
        currentActiveProfile: Profile?,
        isManualTrigger: Bool,
        triggerSubject: PassthroughSubject<UUID, Never>
    ) {
        // For manual triggers (like profile saves), always re-apply even if same profile
        // because profile settings (like preferred mode) may have changed
        if currentActiveProfile?.id == match.profile.id && !isManualTrigger {
            // Profile already active, no change needed
        } else {
            if currentActiveProfile?.id == match.profile.id {
                AppLogger.info("🔄 Re-applying profile '\(match.profile.name)' (manual trigger - settings may have changed)")
            } else {
                AppLogger.info("🎯 Auto-detected profile: '\(match.profile.name)' (matched \(match.matchCount) trigger device(s), primary: \(match.primaryTriggerDevice))")
            }
            triggerSubject.send(match.profile.id)
        }
    }
    
    private func handleNoMatchesFallback(
        currentActiveProfile: Profile?,
        profiles: [Profile],
        triggerSubject: PassthroughSubject<UUID, Never>
    ) {
        // Try to fall back to last used profile first
        if let lastUsedProfileID = getLastUsedProfileID(),
           let lastUsedProfile = profiles.first(where: { $0.id == lastUsedProfileID }),
           !lastUsedProfile.isSystemDefault {
            if currentActiveProfile?.id != lastUsedProfile.id {
                AppLogger.info("🔄 No triggers matched - falling back to last used profile: \(lastUsedProfile.name)")
                triggerSubject.send(lastUsedProfile.id)
            }
            return
        }
        
        // Fall back to System Default profile if no last used profile
        if let systemDefaultProfile = profiles.first(where: { $0.name == "System Default" }) {
            if currentActiveProfile?.id != systemDefaultProfile.id {
                AppLogger.info("🔄 No triggers matched - falling back to System Default profile")
                triggerSubject.send(systemDefaultProfile.id)
            }
        } else {
            AppLogger.warning("⚠️ No System Default profile found to fall back to")
        }
    }
    
    private func getLastUsedProfileID() -> UUID? {
        guard let uuidString = UserDefaults.standard.string(forKey: "LastUsedProfileID") else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }
} 