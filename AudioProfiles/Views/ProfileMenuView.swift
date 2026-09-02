import SwiftUI

/// Main menu bar popover — current status, a uniform set of feature toggles, quick profile
/// switch, and actions.
struct ProfileMenuView: View {
    @Environment(\.dismiss) private var dismissPopover
    @ObservedObject var viewModel: StatusBarViewModel
    @StateObject private var profileManager = ProfileManager.shared
    @ObservedObject private var installService = EQInstallationService.shared
    @ObservedObject private var soundModes = SoundModesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusHeader

            Divider()

            if installService.isInstalled {
                featureToggle(icon: "power", title: "Enabled",
                              isOn: !profileManager.isProcessingBypassed) {
                    profileManager.setProcessingBypassed(!profileManager.isProcessingBypassed)
                }
                featureToggle(icon: "infinity", title: "Always-on processing",
                              isOn: profileManager.alwaysOnProcessing, subordinate: true) {
                    profileManager.setAlwaysOnProcessing(!profileManager.alwaysOnProcessing)
                }
            }

            featureToggle(icon: "bolt", title: "Auto-switch Profiles",
                          isOn: !profileManager.isAutoSwitchingDisabled, subordinate: true) {
                if profileManager.isAutoSwitchingDisabled {
                    profileManager.enableAutoSwitching()
                } else {
                    profileManager.disableAutoSwitching()
                }
            }

            if installService.isInstalled {
                featureToggle(icon: "slider.vertical.3", title: "EQ",
                              isOn: profileManager.isEQEnabled, subordinate: true) {
                    profileManager.setEQEnabled(!profileManager.isEQEnabled)
                }
                featureToggle(icon: "waveform", title: "Content Modes",
                              isOn: soundModes.isEnabled, subordinate: true) {
                    soundModes.setEnabled(!soundModes.isEnabled)
                }
            }

            if manuallySelectableProfiles.count > 1 {
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
        // Fixed width so the popover doesn't resize (and reflow/re-wrap every other row) as
        // toggles flip and rows show/hide. Long names truncate instead of widening the menu.
        .frame(width: 280)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Image(systemName: currentProfileIcon)
                    .foregroundColor(isSystemDefaultActive ? .secondary
                                     : (profileManager.activeMode == .public ? .blue : .purple))
                    .frame(width: 24)
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
        // Match MenuRowButtonStyle's horizontal content inset (12) so the header icons/text
        // line up with the toggle rows below.
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    /// Public/Private switch — only shown when the active profile has different device
    /// priorities for the two modes (so switching actually changes something).
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
        HStack(spacing: 0) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 16, height: 16)
                .frame(width: 24)
            Text(name).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }

    // MARK: - Uniform feature toggle

    private func featureToggle(icon: String, title: String, isOn: Bool,
                               subordinate: Bool = false, action: @escaping () -> Void) -> some View {
        FeatureToggleRow(
            icon: icon,
            title: title,
            isOn: isOn,
            dimmed: subordinate && profileManager.isProcessingBypassed,
            action: action
        )
        // Pin identity so a state change updates the row in place rather than SwiftUI
        // removing+inserting it (which looked like the row being replaced).
        .id("toggle-\(title)")
    }

    // MARK: - Profile Switcher (manual)

    /// Profiles worth offering for manual selection. With auto-switching on, only trigger-less
    /// profiles (which have no automatic activation path) plus System Default are manual; trigger
    /// profiles are managed by device detection. With auto-switching off, nothing auto-activates,
    /// so every profile is manually selectable.
    private var manuallySelectableProfiles: [Profile] {
        if profileManager.isAutoSwitchingDisabled {
            return profileManager.profiles
        }
        return profileManager.profiles.filter { $0.triggerRules.isEmpty }
    }

    @ViewBuilder
    private var profileSwitcher: some View {
        ForEach(manuallySelectableProfiles) { profile in
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

/// One feature row with the shared AccentSwitch. A dedicated View (not a helper function) so
/// SwiftUI has unambiguous per-row identity and updates it in place, instead of treating a
/// state change as a remove+insert (which looked like the row being replaced). `dimmed` rows
/// are subordinate to the master switch and have no effect while it's off.
private struct FeatureToggleRow: View {
    let icon: String
    let title: String
    let isOn: Bool
    let dimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .frame(width: 24)
                Text(title)
                Spacer()
                AccentSwitch(isOn: isOn)
            }
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}
