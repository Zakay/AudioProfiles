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
                    .foregroundColor(isSystemDefaultActive ? .primary : (profileManager.activeMode == .public ? .blue : .purple))
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
                            Image(systemName: profileManager.activeMode.iconName)
                                .font(.caption)
                            Text(profileManager.activeMode.displayName)
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
                    .help("Switch to \(profileManager.activeMode == .public ? ProfileMode.private.displayName : ProfileMode.public.displayName) mode")
                }
            }
            .padding(.horizontal, 12)

            // Current devices section
            VStack(alignment: .leading, spacing: 4) {
                if let outputDevice = currentOutputDevice {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(width: 16, height: 16)
                            .frame(width: 24)
                        Text(outputDevice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let inputDevice = currentInputDevice {
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(width: 16, height: 16)
                            .frame(width: 24)
                        Text(inputDevice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)

            // Auto-Switch Diagnostics (F8)
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

            // Audio processing status indicators
            AudioStatusIndicators()

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
            
            // Profiles auto-switch toggle
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

            // Quick EQ access
            EQQuickAccessRow()

            // Content Modes toggle
            ContentModesRow()

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

struct ContentModesRow: View {
    @StateObject private var store = SoundModesStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Main toggle
            Button {
                store.setEnabled(!store.isEnabled)
            } label: {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundColor(store.isEnabled ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)

                    Text("Content Modes")
                    Spacer()

                    Text(store.isEnabled ? "On" : "Off")
                        .font(.caption)
                        .foregroundColor(store.isEnabled ? .green : .secondary)
                }
            }
            .buttonStyle(MenuRowButtonStyle())

            // Expanded mode list when enabled
            if store.isEnabled {
                VStack(spacing: 0) {
                    // Auto option
                    Button {
                        store.setManualOverride(nil)
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(store.manualOverride == nil ? .accentColor : .secondary)
                                .frame(width: 14, height: 14)
                                .frame(width: 20)
                            Text("Auto")
                                .font(.caption)
                            Spacer()
                            if store.manualOverride == nil {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.leading, 28)
                    }
                    .buttonStyle(MenuRowButtonStyle())

                    // Content modes
                    ForEach(ContentModeType.allCases.filter { $0 != .none }, id: \.self) { mode in
                        Button {
                            store.setManualOverride(mode)
                        } label: {
                            HStack {
                                Image(systemName: mode.iconName)
                                    .foregroundColor(mode == store.activeContentMode ? .accentColor : .secondary)
                                    .frame(width: 14, height: 14)
                                    .frame(width: 20)
                                Text(mode.displayName)
                                    .font(.caption)
                                Spacer()
                                if store.manualOverride == mode {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.leading, 28)
                        }
                        .buttonStyle(MenuRowButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Audio Status Indicators

struct AudioStatusIndicators: View {
    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var soundModes = SoundModesStore.shared
    @ObservedObject private var engine = EQEngineService.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    private var outputUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    private var hasDeviceEQ: Bool {
        guard let uid = outputUID else { return false }
        let settings = eqStore.settings(for: uid)
        return !settings.isFlat && !profileManager.isProcessingBypassed
    }

    private var hasContentMode: Bool {
        soundModes.isEnabled && soundModes.activeContentMode != .none
    }

    private var hasNightMode: Bool {
        soundModes.nightMode.isEnabled && soundModes.isNightModeActive
    }

    var body: some View {
        let items = buildItems()
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 6, height: 6)
                        Text(item.label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
    }

    private struct StatusItem {
        let label: String
        let color: Color
    }

    private func buildItems() -> [StatusItem] {
        var result: [StatusItem] = []
        if hasDeviceEQ { result.append(StatusItem(label: "EQ", color: .blue)) }
        if hasContentMode { result.append(StatusItem(label: soundModes.activeContentMode.displayName, color: .blue)) }
        if hasNightMode { result.append(StatusItem(label: "Night", color: .indigo)) }
        if engine.isRunning { result.append(StatusItem(label: "Processing", color: .green)) }
        return result
    }
}

// MARK: - EQ Quick Access Row

struct EQQuickAccessRow: View {
    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var engine = EQEngineService.shared
    @ObservedObject private var installService = EQInstallationService.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    private var activeUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    private var presetLabel: String {
        guard let uid = activeUID else { return "No device" }
        let settings = eqStore.settings(for: uid)
        if settings.isFlat { return "Off" }
        let mode = eqStore.mode(for: uid)
        switch mode {
        case .custom: return "Custom"
        case .preset(let headphoneName, _): return headphoneName
        }
    }

    private var isBypassed: Bool {
        profileManager.isProcessingBypassed
    }

    private var hasEQ: Bool {
        guard let uid = activeUID else { return false }
        return !eqStore.settings(for: uid).isFlat
    }

    var body: some View {
        if installService.isInstalled {
            Button {
                profileManager.setProcessingBypassed(!profileManager.isProcessingBypassed)
            } label: {
                HStack {
                    Image(systemName: "slider.vertical.3")
                        .foregroundColor(hasEQ && !isBypassed ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)

                    Text("EQ")
                    Spacer()

                    if isBypassed {
                        Text("Off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if hasEQ {
                        Text(presetLabel)
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("No EQ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(MenuRowButtonStyle())
        }
    }
}