import SwiftUI

struct ProfileMenuView: View {
    @Environment(\.dismiss) private var dismissPopover
    @ObservedObject var viewModel: StatusBarViewModel
    @StateObject private var profileManager = ProfileManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current profile header with conditional mode toggle
            HStack {
                // Profile icon - white for System Default, mode color for others
                Image(systemName: currentProfileIcon)
                    .foregroundColor(isSystemDefaultActive ? .white : (profileManager.activeMode == .public ? .blue : .purple))
                    .frame(width: 20, height: 20)
                    .frame(width: 24) // Container for alignment
                
                VStack(alignment: .leading) {
                    Text(viewModel.title)
                        .font(.headline)
                }
                
                Spacer()
                
                // Inline mode toggle - only show for non-System Default profiles
                if !isSystemDefaultActive {
                    Button(action: { ProfileManager.shared.toggleMode() }) {
                        HStack(spacing: 4) {
                            Image(systemName: profileManager.activeMode == .public ? "speaker.wave.2" : "headphones")
                                .font(.caption)
                            Text(profileManager.activeMode == .public ? "Public" : "Private")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(profileManager.activeMode == .public ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                        .foregroundColor(profileManager.activeMode == .public ? .blue : .purple)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Switch to \(profileManager.activeMode == .public ? "Private" : "Public") mode")
                }
            }
            .padding(.leading, 4)
            
            // Current devices section
            VStack(alignment: .leading, spacing: 4) {
                if let outputDevice = currentOutputDevice {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(width: 16, height: 16)
                            .frame(width: 24) // Container for alignment
                        Text(outputDevice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 4)
                }
                if let inputDevice = currentInputDevice {
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(width: 16, height: 16)
                            .frame(width: 24) // Container for alignment
                        Text(inputDevice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }
            
            Divider()

            // Profile list (removed mode toggle section)
            if profileManager.profiles.isEmpty {
                Text("No profiles configured")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(profileManager.profiles) { profile in
                    Button(action: { ProfileManager.shared.activateProfile(with: profile.id, isManual: true) }) {
                        HStack {
                            // Profile icon - consistent container
                            Image(systemName: profile.iconName)
                                .frame(width: 16, height: 16)
                                .frame(width: 24) // Container for alignment
                            
                            Text(profile.name)
                            Spacer()
                            if profileManager.activeProfile?.id == profile.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(MenuRowButtonStyle())
                }
            }
            
            Divider()
            
            // Auto Profiles toggle
            Button {
                if profileManager.isAutoSwitchingDisabled {
                    profileManager.enableAutoSwitching()
                } else {
                    dismissPopover()
                    WindowManager.shared.openAutoSwitchingDialog()
                }
            } label: {
                HStack {
                    Image(systemName: "bolt")
                        .foregroundColor(profileManager.isAutoSwitchingDisabled ? .secondary : .accentColor)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)

                    Text("Auto Profiles")
                    Spacer()
                    Text(profileManager.isAutoSwitchingDisabled ? "Off" : "On")
                        .font(.caption)
                        .foregroundColor(profileManager.isAutoSwitchingDisabled ? .secondary : .green)
                }
            }
            .buttonStyle(MenuRowButtonStyle())

            // Auto Content Mode toggle
            AutoContentModeRow()

            Divider()

            // Settings button
            Button("Configure") {
                dismissPopover()
                WindowManager.shared.openConfigurationWindow()
            }
            .buttonStyle(MenuRowButtonStyle())
            
            Divider()
            
            // About button
            Button("About") {
                openAboutWindow()
            }
            .buttonStyle(MenuRowButtonStyle())
            
            Divider()
            
            // Quit button
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(MenuRowButtonStyle())
        }
        .padding(12)
        .frame(minWidth: 220)
    }
    
    private var currentProfileIcon: String {
        guard let activeProfile = profileManager.activeProfile else {
            return "speaker.wave.2.fill"
        }
        return activeProfile.iconName
    }
    
    private var isSystemDefaultActive: Bool {
        guard let activeProfile = profileManager.activeProfile else {
            return false
        }
        return activeProfile.isSystemDefault
    }
    
    private var modeIcon: String {
        profileManager.activeMode == .public ? "speaker.wave.2.fill" : "headphones"
    }
    
    private var currentOutputDevice: String? {
        profileManager.activeOutputDeviceName
    }

    private var currentInputDevice: String? {
        profileManager.activeInputDeviceName
    }
    
    private func openAboutWindow() {
        dismissPopover()
        WindowManager.shared.openAboutWindow()
    }
}

// MARK: - Auto Content Mode Row

struct AutoContentModeRow: View {
    @StateObject private var store = SoundModesStore.shared

    var body: some View {
        HStack(spacing: 0) {
            // Main toggle button
            Button {
                store.isEnabled.toggle()
            } label: {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundColor(store.isEnabled ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)

                    Text("Auto Content Mode")
                    Spacer()

                    Text(store.isEnabled ? "On" : "Off")
                        .font(.caption)
                        .foregroundColor(store.isEnabled ? .green : .secondary)
                }
            }
            .buttonStyle(MenuRowButtonStyle())

            // Mode selector — only when enabled
            if store.isEnabled {
                Menu {
                    Button {
                        store.manualOverride = nil
                    } label: {
                        HStack {
                            Text("Auto")
                            if store.manualOverride == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(ContentModeType.allCases.filter { $0 != .none }, id: \.self) { mode in
                        Button {
                            store.manualOverride = mode
                        } label: {
                            HStack {
                                Label(mode.displayName, systemImage: mode.iconName)
                                if store.manualOverride == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        let displayed = store.manualOverride ?? store.activeContentMode
                        if displayed != .none {
                            Image(systemName: displayed.iconName)
                                .font(.caption2)
                        }
                        Text(store.manualOverride?.displayName ?? "Auto")
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}