import SwiftUI
import ServiceManagement

/// The Home tab — a live overview of what the app is doing right now, the master processing
/// switch, and app settings. The other tabs (Profiles, EQ, Content Modes) configure the
/// individual features; this tab shows their combined current state and the global on/off.
struct HomeTabView: View {

    @ObservedObject private var profileManager = ProfileManager.shared
    @ObservedObject private var engine = EQEngineService.shared
    @ObservedObject private var soundModes = SoundModesStore.shared
    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var installService = EQInstallationService.shared

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showAutoSwitchNotifications") private var showNotifications = true

    var body: some View {
        VStack(spacing: 16) {
            masterCard
            statusCard
            settingsCard
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
    }

    // MARK: - Master Processing

    private var processingOn: Bool { !profileManager.isProcessingBypassed }

    @ViewBuilder
    private var masterCard: some View {
        if installService.isInstalled {
            Button {
                profileManager.setProcessingBypassed(processingOn)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: processingOn ? "waveform" : "waveform.slash")
                        .font(.title2)
                        .foregroundColor(processingOn ? .accentColor : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio Processing")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(processingOn
                             ? "On · EQ and sound modes are active"
                             : "Off · audio goes straight to the hardware output")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    AccentSwitch(isOn: processingOn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle").foregroundColor(.secondary)
                Text("Install the audio component (EQ tab) to enable processing.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    // MARK: - Status

    private var activeOutputUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    private var contentModeText: String {
        guard soundModes.isEnabled else { return "Disabled" }
        guard soundModes.activeContentMode != .none else { return "None" }
        if let src = soundModes.activeSourceApp {
            return "\(soundModes.activeContentMode.displayName) · \(src)"
        }
        return soundModes.activeContentMode.displayName
    }

    private var eqText: String {
        guard let uid = activeOutputUID else { return "—" }
        if profileManager.isProcessingBypassed { return "Bypassed" }
        if eqStore.isBypassed(for: uid) { return "Bypassed (device)" }
        let settings = eqStore.settings(for: uid)
        if settings.isFlat { return "Off" }
        switch eqStore.mode(for: uid) {
        case .custom: return "Custom"
        case .preset(let name, _): return name
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Now")
                .font(.headline)

            statusRow("Profile",
                      value: profileManager.activeProfile?.name ?? "—",
                      systemImage: profileManager.activeProfile?.iconName ?? "person.2")
            statusRow("Mode",
                      value: profileManager.activeMode == .public ? "Public" : "Private",
                      systemImage: profileManager.activeMode == .public ? "speaker.wave.2" : "headphones")
            statusRow("Output",
                      value: profileManager.activeOutputDeviceName ?? "—",
                      systemImage: "hifispeaker")
            statusRow("Input",
                      value: profileManager.activeInputDeviceName ?? "—",
                      systemImage: "mic")
            statusRow("EQ", value: eqText, systemImage: "slider.vertical.3")
            statusRow("Content Mode", value: contentModeText, systemImage: "waveform")
            statusRow("Routing",
                      value: engine.isRunning ? "Through AudioProfiles" : "Direct to hardware",
                      systemImage: engine.isRunning ? "arrow.triangle.branch" : "arrow.right")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func statusRow(_ label: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
                .frame(width: 18)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    // MARK: - Settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)

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

            Toggle("Show notification when profile switches", isOn: $showNotifications)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
