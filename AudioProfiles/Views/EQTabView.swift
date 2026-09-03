import SwiftUI

/// EQ configuration tab — device picker, install/update banners, and the EQ editor.
///
/// Device list and selection logic live in EQTabViewModel.
/// Install sheet UI lives in EQDriverInstallSheet.swift.
struct EQTabView: View {

    @ObservedObject private var eqStore        = EQStore.shared
    @ObservedObject private var installService = EQInstallationService.shared
    @ObservedObject private var profileManager = ProfileManager.shared
    @StateObject   private var vm              = EQTabViewModel()
    @State         private var showingInstallSheet = false

    private var isBypassed: Bool {
        guard let id = vm.selectedDeviceID else { return false }
        return EQStore.shared.isBypassed(for: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            bannerSection

            if installService.isInstalled {
                toolbarRow

                if let device = vm.selectedDevice {
                    EQEditorView(deviceUID: device.id, deviceName: device.name)
                        .id(device.id)
                } else {
                    noDeviceSelected
                }
            } else {
                noDriverState
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .onAppear { vm.refreshDevices() }
        .sheet(isPresented: $showingInstallSheet) {
            EQDriverInstallSheet(isPresented: $showingInstallSheet)
        }
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Headline + master toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Per-device audio correction")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !profileManager.isProcessingBypassed },
                    set: { enabled in profileManager.setProcessingBypassed(!enabled) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Master EQ toggle. Disables all audio processing when off.")
            }

            // Device picker + EQ active badge + reset
            HStack {
                Picker("Device", selection: $vm.selectedDeviceID) {
                    ForEach(vm.outputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .labelsHidden()

                Spacer()

                if let id = vm.selectedDeviceID, eqStore.activeEQ(for: id) != nil {
                    Text(isBypassed ? "Bypassed" : "EQ Active")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((isBypassed ? Color.orange : Color.blue).opacity(0.15))
                        .foregroundColor(isBypassed ? .orange : .blue)
                        .clipShape(Capsule())
                }

                Button {
                    guard let id = vm.selectedDeviceID else { return }
                    eqStore.toggleBypass(for: id)
                } label: {
                    Text("Bypass").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isBypassed ? .orange : nil)
                .disabled(vm.selectedDeviceID == nil || profileManager.isProcessingBypassed)
                .help("Bypass EQ for this device only, keeping your settings. Disabled while the master toggle is off.")

                Button {
                    guard let id = vm.selectedDeviceID else { return }
                    eqStore.setSettings(.flat, for: id)
                    eqStore.setMode(.custom, for: id)
                    if EQEngineService.shared.isRunning,
                       EQEngineService.shared.targetDeviceUID == id {
                        EQEngineService.shared.stopSafe(switchTo: id)
                    }
                } label: {
                    Text("Reset").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.selectedDeviceID == nil || eqStore.settings(for: vm.selectedDeviceID ?? "").isFlat)
            }
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var bannerSection: some View {
        switch installService.installState {
        case .notInstalled:
            installBanner
        case .notLoaded:
            if let update = installService.availableUpdate {
                updateBanner(update, subtitle: "Updating will install the new version and restart the audio engine.")
            } else {
                repairBanner
            }
        case .installing:
            installingBanner
        default:
            if let update = installService.availableUpdate {
                updateBanner(update, subtitle: "A newer driver is bundled with this version of the app.")
            }
        }
    }

    private var installBanner: some View {
        bannerRow(
            icon: "waveform.path.ecg.rectangle", iconColor: .blue,
            title: "EQ requires a one-time setup",
            subtitle: "Install the audio component to enable EQ on any device.",
            bgColor: .blue
        ) {
            Button("Install…") { showingInstallSheet = true }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private var repairBanner: some View {
        bannerRow(
            icon: "exclamationmark.triangle.fill", iconColor: .orange,
            title: "Audio driver not active",
            subtitle: "Driver is installed but coreaudiod hasn't loaded it yet.",
            bgColor: .orange
        ) {
            Button("Restart Audio Engine") { installService.repair { _ in } }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private var installingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Setting up audio driver…").font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func updateBanner(_ info: DriverVersionInfo, subtitle: String = "") -> some View {
        bannerRow(
            icon: "arrow.down.circle.fill", iconColor: .blue,
            title: "Driver update available (v\(info.installedVersion) → v\(info.bundledVersion))",
            subtitle: subtitle.isEmpty ? "A newer driver is bundled with this version of the app." : subtitle,
            bgColor: .blue
        ) {
            Button("Update…") { installService.update { _ in } }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    /// Shared banner layout — icon + text + action button.
    private func bannerRow<Action: View>(
        icon: String, iconColor: Color,
        title: String, subtitle: String, bgColor: Color,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(iconColor).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            action()
        }
        .padding(12)
        .background(bgColor.opacity(0.07))
        .cornerRadius(10)
        .padding(.top, 4)
    }

    // MARK: - Empty States

    private var noDeviceSelected: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.slash").font(.system(size: 32)).foregroundColor(.secondary)
            Text("No output devices found").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noDriverState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 32)).foregroundColor(.secondary)
            Text("Install the audio component to get started").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
