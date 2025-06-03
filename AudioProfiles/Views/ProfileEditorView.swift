import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var vm: ProfileEditorViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showingDeleteConfirmation = false
    @State private var selectedMode: ProfileMode = .public
    
    private let availableIcons = [
        "speaker.wave.2.fill", "house.fill", "building.2.fill", "laptopcomputer", 
        "headphones", "microphone.fill", "music.note", "gear",
        "person.fill", "gamecontroller.fill", "tv.fill", "phone.fill"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                        }
                
                Spacer()
                
                Text(vm.profile.isSystemDefault ? "System Default Profile" : (vm.isNewProfile ? "Add Profile" : "Edit Profile"))
                    .font(.headline)
                
                Spacer()
                
                HStack(spacing: 8) {
                    if !vm.isNewProfile && !vm.profile.isSystemDefault {
                        Button("Delete", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                        .foregroundColor(.red)
                    }
                    
                    if !vm.profile.isSystemDefault {
                        Button("Save") {
                            vm.save()
                            dismiss()
                        }
                        .disabled(!vm.isValidForSave)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Content
            if vm.profile.isSystemDefault {
                // Read-only view for system default profile
                VStack(spacing: 20) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                    
                    Text("System Default Profile")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("This is the built-in system default profile that provides fallback audio settings when no other profiles match your current setup.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    Text("This profile cannot be edited or deleted.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                // Normal editing view for other profiles
                VStack(spacing: 18) {
                    // General Settings Section
                    GeneralSettingsSection(
                        profile: $vm.profile,
                        availableIcons: availableIcons,
                        iconDisplayName: iconDisplayName,
                        validationMessage: vm.validationMessage
                    )
                    
                    // Device Priorities Section
                    DevicePrioritiesComponents(
                        profile: $vm.profile,
                        selectedMode: $selectedMode
                    )
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(width: 600, height: 700)
        .onAppear {
            selectedMode = vm.profile.preferredMode
        }
        .alert("Delete Profile", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                vm.delete()
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete '\(vm.profile.name)'? This action cannot be undone.")
        }
    }
    
    private func iconDisplayName(for iconName: String) -> String {
        switch iconName {
        case "speaker.wave.2.fill": return "Speaker"
        case "house.fill": return "Home"
        case "building.2.fill": return "Office"
        case "laptopcomputer": return "Laptop"
        case "headphones": return "Headphones"
        case "microphone.fill": return "Microphone"
        case "music.note": return "Music"
        case "gear": return "Settings"
        case "person.fill": return "Person"
        case "gamecontroller.fill": return "Gaming"
        case "tv.fill": return "TV"
        case "phone.fill": return "Phone"
        default: return iconName
        }
    }
}

// MARK: - General Settings Section Component
struct GeneralSettingsSection: View {
    @Binding var profile: Profile
    let availableIcons: [String]
    let iconDisplayName: (String) -> String
    let validationMessage: String?
    
    @FocusState private var isNameFieldFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General Settings")
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 12) {
                // Name
                HStack {
                    Text("Name:")
                        .frame(width: 80, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Profile Name", text: $profile.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFieldFocused)
                        
                        // Validation message
                        if let validationMessage = validationMessage {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                
                // Icon Selection
                HStack {
                    Text("Icon:")
                        .frame(width: 80, alignment: .leading)
                    
                    Menu {
                        ForEach(availableIcons, id: \.self) { iconName in
                            Button(action: { profile.iconName = iconName }) {
                                HStack {
                                    Image(systemName: iconName)
                                    Text(iconDisplayName(iconName))
                                    if profile.iconName == iconName {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: profile.iconName)
                                .frame(width: 20)
                            Text(iconDisplayName(profile.iconName))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Trigger Devices (Compact Summary)
                HStack {
                    Text("Triggers:")
                        .frame(width: 80, alignment: .leading)
                    TriggerDeviceSummaryView(selectedDeviceIDs: $profile.triggerDeviceIDs)
                }
                
                // Preferred Mode Selection - Clean and Simple
            HStack {
                    Text("Mode:")
                        .frame(width: 80, alignment: .leading)
                    
                    Picker("", selection: $profile.preferredMode) {
                        Text("Public").tag(ProfileMode.public)
                        Text("Private").tag(ProfileMode.private)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    
                Spacer()
                }
                
                // Hotkey Configuration
                HStack {
                    Text("Hotkey:")
                        .frame(width: 80, alignment: .leading)
                    HotkeyConfigView(hotkey: $profile.hotkey)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onTapGesture {
                // Clear focus when tapping outside the text field
                isNameFieldFocused = false
            }
        }
        .onAppear {
            // Ensure no field is focused when the view appears
            // Small delay to override SwiftUI's automatic focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isNameFieldFocused = false
            }
        }
    }
}
