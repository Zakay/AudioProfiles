import SwiftUI

/// Main menu bar popover — current status, global controls, quick profile switch, and actions.
///
/// Sub-components live in their own files:
/// - EQQuickAccessRow.swift
/// - ContentModesRow.swift
struct ProfileMenuView: View {
    @Environment(\.dismiss) private var dismissPopover
    @ObservedObject var viewModel: StatusBarViewModel
    @StateObject private var profileManager = ProfileManager.shared
    @ObservedObject private var installService = EQInstallationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusHeader

            Divider()

            masterProcessingRow
            autoSwitchRow
            EQQuickAccessRow()
            ContentModesRow()

            if hasUserProfiles {
                Divider()
                profileSwitcher
            }

            Divider()

            Button("Configure…") {
                dismissPopover()
                WindowManager.shared.openConfigurationWindow()
            }
            .buttonStyle(MenuRowButtonStyle())

            Button("About") { openAboutWindow() }
                .buttonStyle(MenuRowButtonStyle())

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(MenuRowButtonStyle())
        }
        .padding(12)
        .frame(minWidth: 250)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: currentProfileIcon)
                    .foregroundColor(isSystemDefaultActive ? .secondary
                                     : (profileManager.activeMode == .public ? .blue : .purple))
                    .frame(width: 20)
                Text(profileManager.activeProfile?.name ?? viewModel.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if activeProfileHasModes { modeToggle }
            }

            if let output = profileManager.activeOutputDeviceName {
                deviceRow(icon: "speaker.wave.2", name: output)
            }
            if let input = profileManager.activeInputDeviceName {
                deviceRow(icon: "mic", name: input)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    /// Public/Private switch — only meaningful when the active profile is configured with
    /// different device priorities for the two modes.
    private var modeToggle: some View {
        Button(action: { ProfileManager.shared.toggleMode() }) {
            HStack(spacing: 4) {
                Image(systemName: profileManager.activeMode.iconName).font(.caption2)
                Text(profileManager.activeMode.displayName).font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((profileManager.activeMode == .public ? Color.blue : Color.purple).opacity(0.18))
            .foregroundColor(profileManager.activeMode == .public ? .blue : .purple)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Switch to \(profileManager.activeMode == .public ? ProfileMode.private.displayName : ProfileMode.public.displayName) mode")
    }

    private func deviceRow(icon: String, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 20)
            Text(name).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }

    // MARK: - Master Processing Toggle

    /// Master switch: when off, the app is passive — audio goes straight to the hardware output
    /// (no EQ, no content modes) and profile auto-switching is paused. Shown only when the driver
    /// is installed.
    @ViewBuilder
    private var masterProcessingRow: some View {
        if installService.isInstalled {
            let on = !profileManager.isProcessingBypassed
            Button {
                profileManager.setProcessingBypassed(on)
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: on ? "waveform" : "waveform.slash")
                        .foregroundColor(on ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)
                    Text("Audio Processing")
                    Spacer()
                    AccentSwitch(isOn: on)
                }
            }
            .buttonStyle(MenuRowButtonStyle())
            .help("Turn off to bypass the app: audio goes to the hardware output and auto-switching pauses")
        }
    }

    // MARK: - Auto-Switch Row

    private var autoSwitchRow: some View {
        Button {
            if profileManager.isAutoSwitchingDisabled {
                profileManager.enableAutoSwitching()
            } else {
                profileManager.disableAutoSwitching()
            }
        } label: {
            HStack {
                Image(systemName: "bolt")
                    .foregroundColor(profileManager.isAutoSwitchingDisabled ? .secondary : .accentColor)
                    .frame(width: 16, height: 16)
                    .frame(width: 24)
                Text("Auto-switch Profiles")
                Spacer()
                Text(profileManager.isAutoSwitchingDisabled ? "Off" : "On")
                    .font(.caption)
                    .foregroundColor(profileManager.isAutoSwitchingDisabled ? .secondary : .green)
            }
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - Profile Switcher (manual)

    @ViewBuilder
    private var profileSwitcher: some View {
        ForEach(profileManager.profiles) { profile in
            Button(action: { ProfileManager.shared.activateProfile(with: profile.id, isManual: true) }) {
                HStack {
                    Image(systemName: profile.iconName).frame(width: 16, height: 16).frame(width: 24)
                    Text(profile.name).lineLimit(1)
                    Spacer()
                    if profileManager.activeProfile?.id == profile.id {
                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                    }
                }
            }
            .buttonStyle(MenuRowButtonStyle())
        }
    }

    // MARK: - Helpers

    private var currentProfileIcon: String {
        profileManager.activeProfile?.iconName ?? "speaker.wave.2.fill"
    }

    private var isSystemDefaultActive: Bool {
        profileManager.activeProfile?.isSystemDefault ?? false
    }

    private var hasUserProfiles: Bool {
        profileManager.profiles.contains { !$0.isSystemDefault }
    }

    /// True when the active profile has different device priorities for Public vs Private,
    /// so switching mode actually changes something.
    private var activeProfileHasModes: Bool {
        guard let p = profileManager.activeProfile, !p.isSystemDefault else { return false }
        return p.publicOutputPriority != p.privateOutputPriority
            || p.publicInputPriority != p.privateInputPriority
    }

    private func openAboutWindow() {
        dismissPopover()
        WindowManager.shared.openAboutWindow()
    }
}
