import Foundation

/// Protocol for profile storage — load and save the profile list.
///
/// Abstracting this allows ProfileManager tests to inject an in-memory mock
/// instead of reading/writing UserDefaults.
protocol ProfilePersistenceServiceProtocol {
    /// Load all persisted profiles. Returns [] if none found or on decode error.
    func loadProfiles() -> [Profile]
    /// Persist the full profiles array. Returns true on success.
    @discardableResult func saveProfiles(_ profiles: [Profile]) -> Bool
}
