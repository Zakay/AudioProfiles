import SwiftUI

/// Main menu bar popover — profile list, mode toggle, status indicators, quick actions.
///
/// Sub-components live in their own files:
/// - AudioStatusIndicators.swift
/// - EQQuickAccessRow.swift
/// - ContentModesRow.swift
struct ProfileMenuView: View {
    @Environment(\.dismiss) private var dismissPopover
    @ObservedObject var viewModel: StatusBarViewModel
    @StateObject private var profileManager = ProfileManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileHeader
            currentDevicesSection
            triggerEventRow
            AudioStatusIndicators()

            Divider()

            profileList
            autoSwitchRow

            EQQuickAccessRow()
            ContentModesRow()

            Divider()

            Button("Configure") {
                dismissPopover()
                WindowManager.shared.openConfigurationWindow()
            }
            .buttonStyle(MenuRowButtonStyle())

            Divider()

            Button("About") { openAboutWindow() }
                .buttonStyle(MenuRowButtonStyle())

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(MenuRowButtonStyle())
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    // MARK: - Header

    private var profileHeader: some View {
        HStack {
            Image(systemName: currentProfileIcon)
                .foregroundColor(isSystemDefaultActive ? .primary : (profileManager.activeMode == .public ? .blue : .purple))
                .frame(width: 20, height: 20)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(viewModel.title).font(.headline)
            }

            Spacer()

            if !isSystemDefaultActive {
                Button(action: { ProfileManager.shared.toggleMode() }) {
                    HStack(spacing: 4) {
                        Image(systemName: profileManager.activeMode.iconName).font(.caption)
                        Text(profileManager.activeMode.displayName).font(.caption).fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(profileManager.activeMode == .public ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                    .foregroundColor(profileManager.activeMode == .public ? .blue : .purple)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Switch to \(profileManager.activeMode == .public ? ProfileMode.private.displayName : ProfileMode.public.displayName) mode")
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Current Devices

    private var currentDevicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let outputDevice = profileManager.activeOutputDeviceName {
                deviceRow(icon: "speaker.wave.2", name: outputDevice)
            }
            if let inputDevice = profileManager.activeInputDeviceName {
                deviceRow(icon: "mic", name: inputDevice)
            }
        }
        .padding(.horizontal, 12)
    }

    private func deviceRow(icon: String, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 16, height: 16)
                .frame(width: 24)
            Text(name).font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Trigger Event Row

    @ViewBuilder
    private var triggerEventRow: some View {
        if let event = profileManager.lastTriggerEvent {
            HStack(spacing: 4) {
                Image(systemName: event.wasAutomatic ? "bolt.fill" : "hand.tap.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("\(event.timeAgo) · \(event.triggerDeviceName)")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Profile List

    @ViewBuilder
    private var profileList: some View {
        if profileManager.profiles.isEmpty {
            Text("No profiles configured")
                .foregroundColor(.secondary)
                .font(.caption)
        } else {
            ForEach(profileManager.profiles) { profile in
                Button(action: { ProfileManager.shared.activateProfile(with: profile.id, isManual: true) }) {
                    HStack {
                        Image(systemName: profile.iconName).frame(width: 16, height: 16).frame(width: 24)
                        Text(profile.name)
                        Spacer()
                        if profileManager.activeProfile?.id == profile.id {
                            Image(systemName: "checkmark").foregroundColor(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
            }
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
                Text("Profiles")
                Spacer()
                Text(profileManager.isAutoSwitchingDisabled ? "Off" : "On")
                    .font(.caption)
                    .foregroundColor(profileManager.isAutoSwitchingDisabled ? .secondary : .green)
            }
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - Helpers

    private var currentProfileIcon: String {
        profileManager.activeProfile?.iconName ?? "speaker.wave.2.fill"
    }

    private var isSystemDefaultActive: Bool {
        profileManager.activeProfile?.isSystemDefault ?? false
    }

    private func openAboutWindow() {
        dismissPopover()
        WindowManager.shared.openAboutWindow()
    }
}
