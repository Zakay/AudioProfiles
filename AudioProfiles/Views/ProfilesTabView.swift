import SwiftUI
import ServiceManagement

/// The Profiles tab content — profile list, auto-switch toggle, and settings.
/// Extracted from ConfigurationView to keep each tab in its own file.
struct ProfilesTabView: View {

    @ObservedObject var profileManager: ProfileManager
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showAutoSwitchNotifications") private var showNotifications = true

    /// Passed from ConfigurationView so sheets/alerts live at the right level.
    @Binding var showAddProfileSheet: Bool
    @Binding var profileToEdit: Profile?
    @Binding var profileToDelete: Profile?

    private let formatter = ProfileDisplayFormatter()

    var body: some View {
        VStack(spacing: 16) {
            profileListSection
            settingsSection
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
    }

    // MARK: - Profile List Section

    private var profileListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            listHeader
            profileList
        }
    }

    private var listHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Profiles")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Auto-switch based on connected devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !profileManager.isAutoSwitchingDisabled },
                set: { enabled in
                    if enabled {
                        profileManager.enableAutoSwitching()
                    } else {
                        profileManager.disableAutoSwitching()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help("Auto-switch profiles when devices connect/disconnect")
        }
    }

    private var profileList: some View {
        List {
            ForEach(profileManager.profiles, id: \.id) { profile in
                ProfileListRow(
                    profile: profile,
                    formatter: formatter,
                    onEdit: { profileToEdit = profile },
                    onAdd: { showAddProfileSheet = true }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .contextMenu {
                    if !profile.isSystemDefault {
                        Button("Delete Profile", role: .destructive) {
                            profileToDelete = profile
                        }
                    }
                }
            }
            .onMove { sourceIndices, destinationIndex in
                let systemDefaultExists = profileManager.profiles.first?.isSystemDefault == true
                if let sourceIndex = sourceIndices.first,
                   sourceIndex == 0 && systemDefaultExists { return }
                if destinationIndex == 0 && systemDefaultExists { return }
                if let sourceIndex = sourceIndices.first {
                    profileManager.moveProfile(from: sourceIndex, to: destinationIndex)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(CGFloat(profileManager.profiles.count) * 80, 400))
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Settings").font(.headline)
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

            HStack {
                Toggle("Show notification when profile switches", isOn: $showNotifications)
                Spacer()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    @available(macOS 13.0, *)
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            AppLogger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
    }
}

// MARK: - Profile List Row

/// One row in the profiles list — icon, name/badges, device info, action button.
private struct ProfileListRow: View {
    let profile: Profile
    let formatter: ProfileDisplayFormatter
    let onEdit: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            profileIcon
            profileInfo
            Spacer()
            actionButton
        }
        .padding(.vertical, 8)
    }

    private var profileIcon: some View {
        Image(systemName: profile.iconName)
            .font(.title2)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
            .foregroundColor(.accentColor)
    }

    private var profileInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.name).font(.headline)
                if !profile.isSystemDefault { profileBadges }
                Spacer()
            }
            deviceInfoRow
        }
    }

    @ViewBuilder
    private var profileBadges: some View {
        // Mode badge
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

        // Trigger badge
        if profile.triggerRules.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "bolt.slash").font(.caption2)
                Text("No Triggers").font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(0.2)).foregroundColor(.orange)
            .cornerRadius(6)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "bolt").font(.caption2)
                Text(formatter.triggerDevicesDisplay(for: profile)).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.green.opacity(0.2)).foregroundColor(.green)
            .cornerRadius(6)
        }
    }

    private var deviceInfoRow: some View {
        HStack(spacing: 16) {
            ProfileDeviceInfoView(profile: profile, isOutput: true, formatter: formatter)
            ProfileDeviceInfoView(profile: profile, isOutput: false, formatter: formatter)
            Spacer()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if profile.isSystemDefault {
            Button { onAdd() } label: { Label("Add Profile", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        } else {
            Button { onEdit() } label: { Text("Edit") }
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Device Info View

/// Shows the top-priority device names for a profile's output or input priorities.
/// Uses colored icons when public and private modes differ.
private struct ProfileDeviceInfoView: View {
    let profile: Profile
    let isOutput: Bool
    let formatter: ProfileDisplayFormatter

    var body: some View {
        let symbol = isOutput ? "speaker.wave.2" : "mic"
        let (publicName, privateName) = formatter.topDeviceNames(profile: profile, isOutput: isOutput)

        if publicName == nil && privateName == nil {
            deviceRow(symbol: symbol, name: "Default", color: .secondary)
        } else if publicName == privateName {
            deviceRow(symbol: symbol, name: publicName ?? privateName!, color: .secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let pub = publicName  { deviceRow(symbol: symbol, name: pub,  color: .blue) }
                if let prv = privateName { deviceRow(symbol: symbol, name: prv, color: .purple) }
            }
        }
    }

    private func deviceRow(symbol: String, name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption).foregroundColor(color)
            Text(name).font(.caption).foregroundColor(.secondary)
        }
    }
}
