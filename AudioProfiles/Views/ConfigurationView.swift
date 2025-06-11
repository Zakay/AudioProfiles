import SwiftUI
import ServiceManagement

struct ConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var profileManager = ProfileManager.shared
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var showAddProfileSheet = false
    @State private var profileToEdit: Profile? = nil
    @State private var profileToDelete: Profile? = nil
    
    // Profile display formatter instance
    private let formatter = ProfileDisplayFormatter()
    
    var body: some View {
        VStack(spacing: 16) {
            // Profiles List Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Audio Profiles")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        showAddProfileSheet = true
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                List {
                    ForEach(profileManager.profiles, id: \.id) { profile in
                        HStack(spacing: 12) {
                            // Profile Icon - improved styling like demo
                            Image(systemName: profile.iconName)
                                .font(.title2)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.1))
                                )
                                .foregroundColor(.accentColor)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.name)
                                        .font(.headline)
                                    
                                    // Only show pills for non-system default profiles
                                    if !profile.isSystemDefault {
                                        // Hotkey badge
                                        if let hotkey = profile.hotkey {
                                            Text(hotkey.description)
                                                .font(.caption2)
                                                .fontWeight(.medium)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.gray.opacity(0.2))
                                                .foregroundColor(.primary)
                                                .cornerRadius(6)
                                        }
                                        
                                        // Preferred mode badge
                                        HStack(spacing: 4) {
                                            Image(systemName: profile.preferredMode == .public ? "speaker.wave.2" : "headphones")
                                                .font(.caption2)
                                            Text(profile.preferredMode == .public ? "Public" : "Private")
                                                .font(.caption2)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(profile.preferredMode == .public ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                                        .foregroundColor(profile.preferredMode == .public ? .blue : .purple)
                                        .cornerRadius(6)
                                        
                                        // Trigger status badge with device name
                                        if profile.triggerDeviceIDs.isEmpty {
                                            HStack(spacing: 4) {
                                                Image(systemName: "bolt.slash")
                                                    .font(.caption2)
                                                Text("No Triggers")
                                                    .font(.caption2)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundColor(.orange)
                                            .cornerRadius(6)
                                        } else {
                                            HStack(spacing: 4) {
                                                Image(systemName: "bolt")
                                                    .font(.caption2)
                                                Text(formatter.triggerDevicesDisplay(for: profile))
                                                    .font(.caption2)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(6)
                                        }
                                    }
                                    
                                    Spacer()
                                }
                                
                                // Device configuration row with icons
                                HStack(spacing: 16) {
                                    // Output device info
                                    deviceInfoView(profile: profile, isOutput: true)

                                    // Input device info
                                    deviceInfoView(profile: profile, isOutput: false)

                                    Spacer()
                                }
                            }
                            
                            Spacer()
                            
                            // Show Add Profile button for System Default when it's the only profile
                            if profile.isSystemDefault && profileManager.profiles.count == 1 {
                                Button {
                                    showAddProfileSheet = true
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .help("Add your first profile")
                            }
                            // Only show Edit button for non-system default profiles
                            else if !profile.isSystemDefault {
                                Button {
                                    profileToEdit = profile
                                } label: {
                                    Text("Edit")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            // Only show delete option for non-system default profiles
                            if !profile.isSystemDefault {
                                Button("Delete Profile", role: .destructive) {
                                    profileToDelete = profile
                                }
                            }
                        }
                    }
                    .onMove { sourceIndices, destinationIndex in
                        // Prevent moving System Default or moving anything to position 0
                        let systemDefaultExists = profileManager.profiles.first?.isSystemDefault == true
                        
                        // Don't allow moving if trying to move System Default
                        if let sourceIndex = sourceIndices.first,
                           sourceIndex == 0 && systemDefaultExists {
                            return
                        }
                        
                        // Don't allow moving to position 0 if System Default exists
                        if destinationIndex == 0 && systemDefaultExists {
                            return
                        }
                        
                        if let sourceIndex = sourceIndices.first {
                            profileManager.moveProfile(from: sourceIndex, to: destinationIndex)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: 345)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            // Settings Section
            VStack(spacing: 12) {
                HStack {
                    Text("Settings")
                        .font(.headline)
                    Spacer()
                }
                
                HStack {
                    if #available(macOS 13.0, *) {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { newValue in
                                launchAtLogin = newValue
                                setLaunchAtLogin(enabled: newValue)
                            }
                        ))
                    } else {
                        Text("Launch at Login requires macOS 13.0+")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .frame(width: 530, height: 530)
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
            Button("Cancel", role: .cancel) { 
                profileToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    // Close edit sheet if this profile is being edited
                    if profileToEdit?.id == profile.id {
                        profileToEdit = nil
                    }
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
    
    @available(macOS 13.0, *)
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Device info helpers with coloured icons

    /// Resolve highest-priority device names for public and private modes.
    private func topDeviceNames(profile: Profile, isOutput: Bool) -> (publicName: String?, privateName: String?) {
        let history = AudioDeviceHistoryService.shared

        func firstName(in ids: [String]) -> String? {
            for id in ids {
                if let name = history.getDevice(by: id)?.name {
                    return name
                }
            }
            return nil
        }

        let pubIDs  = isOutput ? profile.publicOutputPriority  : profile.publicInputPriority
        let privIDs = isOutput ? profile.privateOutputPriority : profile.privateInputPriority

        return (firstName(in: pubIDs), firstName(in: privIDs))
    }

    /// Compact display that colors the icon blue (public) or purple (private) when the two modes differ.
    /// If both modes share the same device (or only one is set) we show a single gray icon row.
    @ViewBuilder
    private func deviceInfoView(profile: Profile, isOutput: Bool) -> some View {
        let symbolName = isOutput ? "speaker.wave.2" : "mic"
        let (publicName, privateName) = topDeviceNames(profile: profile, isOutput: isOutput)

        if publicName == nil && privateName == nil {
            // No priorities – show default
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Default")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if publicName == privateName {
            // Same device (or only one specified) – single row, neutral icon
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(publicName ?? privateName!)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            // Different devices – show two rows with coloured icons
            VStack(alignment: .leading, spacing: 2) {
                if let pub = publicName {
                    HStack(spacing: 4) {
                        Image(systemName: symbolName)
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(pub)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let priv = privateName {
                    HStack(spacing: 4) {
                        Image(systemName: symbolName)
                            .font(.caption)
                            .foregroundColor(.purple)
                        Text(priv)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
} 
