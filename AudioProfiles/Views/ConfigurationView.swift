import SwiftUI
import ServiceManagement

/// Top-level settings window — a TabView wrapper that delegates each tab to its own view.
/// Sheet and alert state lives here because it spans multiple tabs (e.g. Add Profile
/// from the profiles list, delete confirmation).
struct ConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var profileManager = ProfileManager.shared

    @State private var showAddProfileSheet = false
    @State private var profileToEdit: Profile? = nil
    @State private var profileToDelete: Profile? = nil

    var body: some View {
        TabView {
            HomeTabView()
                .tabItem { Label("Home", systemImage: "house") }

            ProfilesTabView(
                profileManager: profileManager,
                showAddProfileSheet: $showAddProfileSheet,
                profileToEdit: $profileToEdit,
                profileToDelete: $profileToDelete
            )
            .tabItem { Label("Profiles", systemImage: "person.2") }

            EQTabView()
                .tabItem { Label("EQ", systemImage: "slider.vertical.3") }

            SoundModesTabView()
                .tabItem { Label("Content Modes", systemImage: "waveform") }
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showAddProfileSheet) {
            let newProfile = ProfileManager.shared.createNewProfileInstance()
            ProfileEditorView(vm: ProfileEditorViewModel(profile: newProfile))
        }
        .sheet(item: $profileToEdit) { profile in
            ProfileEditorView(vm: ProfileEditorViewModel(profile: profile))
        }
        .alert("Delete Profile", isPresented: Binding<Bool>(
            get: { profileToDelete != nil },
            set: { _ in profileToDelete = nil }
        )) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    if profileToEdit?.id == profile.id { profileToEdit = nil }
                    ProfileManager.shared.remove(profileID: profile.id)
                }
                profileToDelete = nil
            }
        } message: {
            if let profile = profileToDelete {
                Text("Are you sure you want to delete '\(profile.name)'? This action cannot be undone.")
            }
        }
    }
}
