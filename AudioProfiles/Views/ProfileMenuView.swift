import SwiftUI

/// Consistent leading icon for every menu row: same glyph size, same 24pt column, so all row
/// labels line up and icons look uniform. Shared by the rows and the FeatureToggleRow struct.
private func menuRowIcon(_ name: String, color: Color = .secondary) -> some View {
    Image(systemName: name)
        .font(.system(size: 14))
        .foregroundColor(color)
        .frame(width: 22, alignment: .center)
        .padding(.trailing, 8)   // gap between icon and label
}

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

            menuActionRow(icon: "gearshape", title: "Configure…") {
                dismissPopover()
                WindowManager.shared.openConfigurationWindow()
            }
            menuActionRow(icon: "info.circle", title: "About") { openAboutWindow() }
            menuActionRow(icon: "xmark.circle", title: "Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        // Fixed width so the popover doesn't resize (and reflow/re-wrap every other row) as
        // toggles flip and rows show/hide. Long names truncate instead of widening the menu.
        .frame(width: 280)
    }

    // MARK: - Status Header (graphical)

    private var profileColor: Color {
        isSystemDefaultActive ? .secondary
            : (profileManager.activeMode == .public ? .blue : .purple)
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: currentProfileIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(profileColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(profileColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profileManager.activeProfile?.name ?? viewModel.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if activeProfileHasModes { modeToggle }
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let output = profileManager.activeOutputDeviceName {
                        statusDeviceRow(icon: "speaker.wave.2", name: output)
                    }
                    if let input = profileManager.activeInputDeviceName {
                        statusDeviceRow(icon: "mic", name: input)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func statusDeviceRow(icon: String, name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)
            Text(name).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
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

    // MARK: - Action rows

    private func menuActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                menuRowIcon(icon)
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - Profile Switcher (manual)

    /// All profiles are manually selectable. The list is constant (it only changes when profiles
    /// are added/removed/edited, never in response to a toggle), so flipping any switch never
    /// reflows the menu — that reflow was what made the auto-switch row appear to "flip".
    private var manuallySelectableProfiles: [Profile] {
        profileManager.profiles
    }

    @ViewBuilder
    private var profileSwitcher: some View {
        ForEach(manuallySelectableProfiles) { profile in
            Button(action: { ProfileManager.shared.activateProfile(with: profile.id, isManual: true) }) {
                HStack(spacing: 0) {
                    menuRowIcon(profile.iconName)
                    Text(profile.name).lineLimit(1)
                    Spacer()
                    if profileManager.activeProfile?.id == profile.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.accentColor)
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
                menuRowIcon(icon)
                Text(title)
                Spacer()
                AccentSwitch(isOn: isOn)
            }
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}
