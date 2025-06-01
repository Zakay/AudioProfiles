import Combine

class ProfileEditorViewModel: ObservableObject {
    @Published var profile: Profile
    
    private let originalProfile: Profile?

    init(profile: Profile) {
        self.profile = profile
        // Check if this is a new profile by seeing if it exists in ProfileManager
        self.originalProfile = ProfileManager.shared.profiles.first { $0.id == profile.id }
    }
    
    var isNewProfile: Bool {
        return originalProfile == nil
    }
    
    var isValidForSave: Bool {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if name is empty
        guard !trimmedName.isEmpty else { return false }
        
        // Check if name conflicts with existing profiles (excluding self)
        let existingProfiles = ProfileManager.shared.profiles.filter { $0.id != profile.id }
        let nameExists = existingProfiles.contains { $0.name == trimmedName }
        
        return !nameExists
    }
    
    var validationMessage: String? {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedName.isEmpty {
            return "Profile name cannot be empty"
        }
        
        // Check if name conflicts with existing profiles (excluding self)
        let existingProfiles = ProfileManager.shared.profiles.filter { $0.id != profile.id }
        if existingProfiles.contains(where: { $0.name == trimmedName }) {
            return "A profile with this name already exists"
        }
        
        return nil
    }

    func save() {
        guard isValidForSave else { return }
        
        // Delegate the add/update and persistence to the manager
        ProfileManager.shared.upsert(profile)
        
        AppLogger.info("Profile '\(profile.name)' \(isNewProfile ? "created" : "updated")")
    }
    
    func delete() {
        guard !isNewProfile else { return }
        
        ProfileManager.shared.remove(profileID: profile.id)
        AppLogger.info("Profile '\(profile.name)' deleted")
    }
}
