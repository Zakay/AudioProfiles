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
        // Content
        VStack(spacing: 16) {
            // Profiles List Section
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    List {
                        ForEach(profileManager.profiles, id: \.id) { profile in
                            HStack(spacing: 12) {
                                // Profile Icon
                                Image(systemName: profile.iconName)
                                    .font(.title2)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.1))
                                    )
                                
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
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(Color.gray.opacity(0.2))
                                                    .foregroundColor(.white)
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
                                    HStack(spacing: 12) {
                                        // Output device info
                                        HStack(spacing: 4) {
                                            Image(systemName: "speaker.wave.2")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            
                                            Text(deviceDisplayText(for: profile, isOutput: true))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        // Input device info
                                        HStack(spacing: 4) {
                                            Image(systemName: "mic")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            
                                            Text(deviceDisplayText(for: profile, isOutput: false))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        
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
                            .padding(.vertical, 6)
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
                    .frame(minHeight: 200, idealHeight: 300)
                    
                    // Add Profile Button - only show when there are multiple profiles
                    if profileManager.profiles.count > 1 {
                        HStack {
                            Button {
                                showAddProfileSheet = true
                            } label: {
                                Label("Add Profile", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                        }
                        .padding()
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            
            // App Settings Section
            VStack(spacing: 15) {
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
            .cornerRadius(8)
        }
        .padding()
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
    
    /// Get device name for display without prefix (since icons provide the context)
    private func deviceDisplayText(for profile: Profile, isOutput: Bool) -> String {
        let deviceHistoryService = AudioDeviceHistoryService.shared
        
        if isOutput {
            let validDeviceId: String? = profile.publicOutputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } 
                             ?? profile.privateOutputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil }
            
            if let id = validDeviceId, let device = deviceHistoryService.getDevice(by: id) {
                return device.name
            }
            return "Default"
        } else {
            let validDeviceId: String? = profile.publicInputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil } 
                             ?? profile.privateInputPriority.first { !$0.isEmpty && deviceHistoryService.getDevice(by: $0) != nil }
            
            if let id = validDeviceId, let device = deviceHistoryService.getDevice(by: id) {
                return device.name
            }
            return "Default"
        }
    }
} 
