import SwiftUI

// MARK: - EQTabView

struct EQTabView: View {

    @ObservedObject private var historyService  = AudioDeviceHistoryService.shared
    @ObservedObject private var eqStore         = EQStore.shared
    @ObservedObject private var installService  = EQInstallationService.shared
    @State private var expandedDeviceID: String? = nil
    @State private var showingInstallSheet = false

    // MARK: - Device lists

    private var connectedOutputDevices: [AudioDevice] {
        AudioDeviceFactory.getCurrentDevices()
            .filter(\.isOutput)
            .sorted { $0.name < $1.name }
    }

    private var disconnectedOutputDevices: [AudioDevice] {
        let connectedIDs = Set(connectedOutputDevices.map(\.id))
        return historyService.deviceHistory.values
            .map(\.device)
            .filter { $0.isOutput && !connectedIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Install / repair / update banners
            switch installService.installState {
            case .notInstalled:
                installBanner
            case .notLoaded:
                // If a newer (correctly-signed) driver is bundled, offer update instead of
                // plain restart — the update copies the new binary which is what actually fixes it.
                if let update = installService.availableUpdate {
                    updateBanner(update, subtitle: "Updating will install the new version and restart the audio engine.")
                } else {
                    repairBanner
                }
            case .installing:
                installingBanner
            default:
                // Driver is installed and loaded — show update banner if a newer version is bundled
                if let update = installService.availableUpdate {
                    updateBanner(update, subtitle: "A newer driver is bundled with this version of the app.")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !connectedOutputDevices.isEmpty {
                        deviceSection("Connected", devices: connectedOutputDevices, isConnected: true)
                    }

                    if !disconnectedOutputDevices.isEmpty {
                        deviceSection("Previously Connected", devices: disconnectedOutputDevices, isConnected: false)
                    }

                    if connectedOutputDevices.isEmpty && disconnectedOutputDevices.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .padding(.top, 12)
        .sheet(isPresented: $showingInstallSheet) {
            EQDriverInstallSheet(isPresented: $showingInstallSheet)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func deviceSection(_ title: String, devices: [AudioDevice], isConnected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section label — matches DevicePriorityListView style
            HStack(spacing: 6) {
                DeviceDisplayUtils.connectionStatusIndicator(isConnected: isConnected, size: 7)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.3)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(devices) { device in
                    deviceRow(device, isConnected: isConnected)

                    if device.id != devices.last?.id {
                        Divider().padding(.leading, 28)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Device row (collapsed + expanded)

    @ViewBuilder
    private func deviceRow(_ device: AudioDevice, isConnected: Bool) -> some View {
        let isExpanded      = expandedDeviceID == device.id
        let hasEQ           = eqStore.activeEQ(for: device.id) != nil
        let driverInstalled = installService.isInstalled

        VStack(spacing: 0) {
            // ── Row header ──────────────────────────────────────────────────
            HStack(spacing: 12) {
                DeviceDisplayUtils.deviceRowContent(for: device, isConnected: isConnected)

                Spacer()

                if hasEQ {
                    Text("EQ On")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }

                // Chevron only when driver is installed
                if driverInstalled {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedDeviceID = isExpanded ? nil : device.id
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard driverInstalled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedDeviceID = isExpanded ? nil : device.id
                }
            }

            // ── Expanded EQ editor ──────────────────────────────────────────
            if isExpanded && driverInstalled {
                Divider()
                EQEditorView(deviceUID: device.id, deviceName: device.name)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Banners

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
        .padding(.horizontal)
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
        .padding(.horizontal)
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
        .padding(.horizontal)
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
        .padding(.horizontal)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No output devices found")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
