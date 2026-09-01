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
        VStack(alignment: .leading, spacing: 16) {
            header
            eqPreview
            statusPills
            settingsSection
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
    }

    // MARK: - Header (matches the other tabs' style)

    private var processingOn: Bool { !profileManager.isProcessingBypassed }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Home")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(processingOn
                     ? "Profiles, EQ & content modes active"
                     : "Off — audio untouched, no auto-switching")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if installService.isInstalled {
                Toggle("", isOn: Binding(
                    get: { processingOn },
                    set: { on in profileManager.setProcessingBypassed(!on) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Turn off to bypass the app and send audio straight to the hardware output")
            }
        }
    }

    // MARK: - EQ preview (non-interactive, always visible)

    private var activeOutputUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    private var activeOverlay: EQSettings? {
        (soundModes.isEnabled && !profileManager.isProcessingBypassed) ? soundModes.activeOverlay() : nil
    }

    private var curveIsFlat: Bool {
        guard let uid = activeOutputUID else { return true }
        let baseFlat = eqStore.settings(for: uid).isFlat || profileManager.isProcessingBypassed
        let overlayFlat = activeOverlay?.isFlat ?? true
        return baseFlat && overlayFlat
    }

    @ViewBuilder
    private var eqPreview: some View {
        if installService.isInstalled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(profileManager.activeOutputDeviceName ?? "Output")
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Text(curveIsFlat ? "No EQ on this device — add one in the EQ tab" : "Editing in EQ tab")
                        .font(.caption2).foregroundColor(.secondary)
                }

                // Read-only mirror of the EQ tab graph for the active output: shows the base EQ
                // plus any active content-mode overlay, and the same built-in live L/R level
                // meter (visible while audio is routed). Reads the same EQStore / SoundModes
                // state as the EQ tab (single source of truth), so it stays correct as modes are
                // enabled/disabled. No height override — the graph has its own intrinsic height.
                if let uid = activeOutputUID {
                    InteractiveEQGraphView(
                        settings: eqStore.settings(for: uid),
                        selectedBand: .constant(nil),
                        frequencyResponse: nil,
                        contentOverlay: activeOverlay,
                        onChange: { _ in }
                    )
                    .allowsHitTesting(false)
                    .opacity(profileManager.isProcessingBypassed ? 0.4 : 1)
                } else {
                    Text("Waiting for an audio output…")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
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

    private var settingsSection: some View {
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

            if installService.isInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Always-on processing", isOn: Binding(
                        get: { profileManager.alwaysOnProcessing },
                        set: { profileManager.setAlwaysOnProcessing($0) }
                    ))
                    Text("Keeps the audio driver engaged so content-mode changes are seamless (no device switch, no glitch). Turn off to stay on the hardware output until EQ or a mode is active.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
