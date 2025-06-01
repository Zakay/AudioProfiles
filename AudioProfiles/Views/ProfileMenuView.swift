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
                    Button(action: { ProfileManager.shared.activateProfile(with: profile.id) }) {
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
            
            // Auto-switching controls
            if profileManager.isAutoSwitchingDisabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "bolt.slash")
                            .foregroundColor(.orange)
                            .frame(width: 16, height: 16)
                            .frame(width: 24) // Container for alignment
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-switching disabled")
                                .font(.caption)
                                .foregroundColor(.orange)
                            
                            if let remainingTime = profileManager.remainingDisableTime {
                                Text("Re-enables in \(remainingTime)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Disabled forever")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.leading, 4)
                    
                    Button("Enable Auto-switching") {
                        profileManager.enableAutoSwitching()
                    }
                    .buttonStyle(MenuRowButtonStyle())
                }
            } else {
                Button {
                    dismissPopover()
                    WindowManager.shared.openAutoSwitchingDialog()
                } label: {
                    HStack {
                        Image(systemName: "bolt")
                            .foregroundColor(.green)
                            .frame(width: 16, height: 16)
                            .frame(width: 24) // Container for alignment
                        
                        Text("Auto-switching")
                        Spacer()
                        Text("Enabled")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
            }
            
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
        AudioDeviceControlService().getDefaultOutputDevice()?.name
    }
    
    private var currentInputDevice: String? {
        AudioDeviceControlService().getDefaultInputDevice()?.name
    }
    
    private func openAboutWindow() {
        dismissPopover()
        WindowManager.shared.openAboutWindow()
    }
} 