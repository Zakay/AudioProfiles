import SwiftUI

// MARK: - EQTabView

struct EQTabView: View {

    @ObservedObject private var eqStore        = EQStore.shared
    @ObservedObject private var installService = EQInstallationService.shared
    @State private var selectedDeviceID: String? = nil
    @State private var showingInstallSheet = false
    /// Cached device list — never query Core Audio synchronously on the main thread.
    /// Updated from AudioDeviceMonitor (which queries on a background queue).
    @State private var outputDevices: [AudioDevice] = []

    private var selectedDevice: AudioDevice? {
        outputDevices.first { $0.id == selectedDeviceID }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Install / repair / update banners
            bannerSection

            if installService.isInstalled {
                // Headline + device picker + reset
                toolbarRow

                // EQ editor for selected device
                if let device = selectedDevice {
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
        .onAppear { refreshDevices() }
        .onReceive(AudioDeviceMonitor.shared.deviceChangesSubject) { devices in
            let filtered = devices.filter(\.isOutput).sorted { $0.name < $1.name }
            outputDevices = filtered
            // Resolve default device off main thread, then auto-select
            DispatchQueue.global(qos: .userInitiated).async {
                let defaultUID = AudioDeviceControlService().getDefaultOutputDevice()?.id
                DispatchQueue.main.async {
                    autoSelectDevice(defaultDeviceUID: defaultUID)
                }
            }
        }
        .onReceive(AudioDeviceMonitor.shared.serviceRestartedSubject) {
            // coreaudiod restarted — clear stale device list, wait for fresh device notification
            outputDevices = []
            selectedDeviceID = nil
        }
        .sheet(isPresented: $showingInstallSheet) {
            EQDriverInstallSheet(isPresented: $showingInstallSheet)
        }
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Headline row
            HStack {
                Text("Equalizer")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()

                // EQ active indicator
                if let id = selectedDeviceID, eqStore.activeEQ(for: id) != nil {
                    Text("EQ Active")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }

                // Reset to flat
                Button {
                    guard let id = selectedDeviceID else { return }
                    eqStore.setSettings(.flat, for: id)
                    eqStore.setMode(.custom, for: id)
                    if EQEngineService.shared.isRunning,
                       EQEngineService.shared.targetDeviceUID == id {
                        EQEngineService.shared.stopSafe(switchTo: id)
                    }
                } label: {
                    Text("Reset")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedDeviceID == nil || eqStore.settings(for: selectedDeviceID ?? "").isFlat)
            }

            // Device picker
            Picker("Device", selection: $selectedDeviceID) {
                ForEach(outputDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Device management

    /// Initial load — runs on a background queue to avoid blocking main thread.
    private func refreshDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = AudioDeviceFactory.getCurrentDevices()
                .filter(\.isOutput)
                .sorted { $0.name < $1.name }
            let defaultUID = AudioDeviceControlService().getDefaultOutputDevice()?.id
            DispatchQueue.main.async {
                outputDevices = devices
                autoSelectDevice(defaultDeviceUID: defaultUID)
            }
        }
    }

    /// Pick the best device. `defaultDeviceUID` is resolved off the main thread.
    private func autoSelectDevice(defaultDeviceUID: String? = nil) {
        guard !outputDevices.isEmpty else { return }
        // When EQ is running, the system default output is the virtual device.
        // Use the EQ engine's target UID to find the real device behind it.
        if EQEngineService.shared.isRunning,
           let targetUID = EQEngineService.shared.targetDeviceUID,
           outputDevices.contains(where: { $0.id == targetUID }) {
            selectedDeviceID = targetUID
            return
        }
        // Use the system default output if available
        if let uid = defaultDeviceUID, outputDevices.contains(where: { $0.id == uid }) {
            selectedDeviceID = uid
            return
        }
        // Fall back to first available device
        selectedDeviceID = outputDevices.first?.id
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
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .foregroundColor(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("EQ requires a one-time setup")
                    .font(.subheadline).fontWeight(.medium)
                Text("Install the audio component to enable EQ on any device.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Install…") { showingInstallSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.blue.opacity(0.07))
        .cornerRadius(10)
        .padding(.top, 4)
    }

    private var repairBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio driver not active")
                    .font(.subheadline).fontWeight(.medium)
                Text("Driver is installed but coreaudiod hasn't loaded it yet.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Restart Audio Engine") {
                installService.repair { _ in }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
        .cornerRadius(10)
        .padding(.top, 4)
    }

    private var installingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Setting up audio driver…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func updateBanner(_ info: DriverVersionInfo, subtitle: String = "") -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Driver update available (v\(info.installedVersion) → v\(info.bundledVersion))")
                    .font(.subheadline).fontWeight(.medium)
                Text(subtitle.isEmpty ? "A newer driver is bundled with this version of the app." : subtitle)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Update…") {
                installService.update { _ in }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.blue.opacity(0.07))
        .cornerRadius(10)
        .padding(.top, 4)
    }

    // MARK: - Empty states

    private var noDeviceSelected: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No output devices found")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noDriverState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Install the audio component to get started")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
