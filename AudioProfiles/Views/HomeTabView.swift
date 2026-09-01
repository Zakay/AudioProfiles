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
        VStack(spacing: 14) {
            masterCard
            eqPreviewCard
            statusPills
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

    // MARK: - EQ preview

    private var activeOutputUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    @ViewBuilder
    private var eqPreviewCard: some View {
        if installService.isInstalled, let uid = activeOutputUID {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(profileManager.activeOutputDeviceName ?? "Output")
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Text("Edit in EQ tab")
                        .font(.caption2).foregroundColor(.secondary)
                }
                // Read-only preview of the current curve for the active output, including any
                // active content-mode overlay. Editing happens in the EQ tab.
                InteractiveEQGraphView(
                    settings: eqStore.settings(for: uid),
                    selectedBand: .constant(nil),
                    frequencyResponse: nil,
                    contentOverlay: (soundModes.isEnabled && !profileManager.isProcessingBypassed)
                        ? soundModes.activeOverlay() : nil,
                    onChange: { _ in }
                )
                .frame(height: 150)
                .allowsHitTesting(false)
                .opacity(profileManager.isProcessingBypassed ? 0.4 : 1)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    // MARK: - Status pills

    private struct Pill: Identifiable {
        let id = UUID()
        let text: String
        let systemImage: String
        let color: Color
    }

    private var pills: [Pill] {
        var result: [Pill] = []
        if let profile = profileManager.activeProfile {
            result.append(Pill(text: profile.name, systemImage: profile.iconName, color: .accentColor))
        }
        let isPublic = profileManager.activeMode == .public
        result.append(Pill(text: isPublic ? "Public" : "Private",
                           systemImage: isPublic ? "speaker.wave.2" : "headphones",
                           color: isPublic ? .blue : .purple))

        if soundModes.isEnabled, soundModes.activeContentMode != .none {
            result.append(Pill(text: soundModes.activeContentMode.displayName,
                               systemImage: "waveform", color: .green))
        }
        if soundModes.nightMode.isEnabled, soundModes.isNightModeActive {
            result.append(Pill(text: "Night", systemImage: "moon.fill", color: .indigo))
        }
        result.append(engine.isRunning
                      ? Pill(text: "Routed", systemImage: "arrow.triangle.branch", color: .green)
                      : Pill(text: "Direct", systemImage: "arrow.right", color: .secondary))
        return result
    }

    private var statusPills: some View {
        HStack(spacing: 6) {
            ForEach(pills) { pill in
                HStack(spacing: 4) {
                    Image(systemName: pill.systemImage).font(.caption2)
                    Text(pill.text).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pill.color.opacity(0.15))
                .foregroundColor(pill.color == .secondary ? .secondary : pill.color)
                .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
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
