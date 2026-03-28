import SwiftUI

struct TriggerDeviceSelectionView: View {
    @Binding var triggerRules: [TriggerRule]
    @Environment(\.dismiss) var dismiss

    private let deviceFilterService = DeviceFilterService()
    @ObservedObject private var deviceHistoryService = AudioDeviceHistoryService.shared

    /// Derived binding: specific device IDs currently selected
    private var selectedDeviceIDs: [String] {
        TriggerRule.deriveDeviceIDs(from: triggerRules)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Text("Select Trigger Devices")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 16) {
                    // Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select devices that will automatically activate this profile when connected.")
                            .font(.body)
                            .foregroundColor(.secondary)

                        Text("• Only connected devices can trigger profile activation")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("• Multiple devices can be selected for one profile")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    // Selected devices
                    let selectedDevices = deviceFilterService.getDevices(by: selectedDeviceIDs)

                    if !selectedDevices.isEmpty {
                        DeviceSelectionSection(
                            title: "Selected Trigger Devices",
                            devices: selectedDevices,
                            selectedDeviceIDs: Binding(
                                get: { selectedDeviceIDs },
                                set: { updateDeviceIDs($0) }
                            ),
                            showRemoveButtons: true,
                            isSelectedSection: true
                        )
                    }

                    // Currently connected
                    let deviceSections = deviceFilterService.getDevicesForTriggerSelection(excludingIDs: selectedDeviceIDs)

                    if !deviceSections.current.isEmpty {
                        DeviceSelectionSection(
                            title: "Currently Connected",
                            devices: deviceSections.current,
                            selectedDeviceIDs: Binding(
                                get: { selectedDeviceIDs },
                                set: { updateDeviceIDs($0) }
                            ),
                            showRemoveButtons: false,
                            isSelectedSection: false
                        )
                    }

                    // Previously seen
                    if !deviceSections.previous.isEmpty {
                        DeviceSelectionSection(
                            title: "Previously Seen (Last 30 Days)",
                            devices: deviceSections.previous,
                            selectedDeviceIDs: Binding(
                                get: { selectedDeviceIDs },
                                set: { updateDeviceIDs($0) }
                            ),
                            showRemoveButtons: true,
                            isSelectedSection: false
                        )
                    }

                    // Empty state
                    if deviceSections.current.isEmpty && deviceSections.previous.isEmpty && selectedDevices.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "speaker.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)

                            Text("No audio devices found")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("Connect an audio device to set it as a trigger")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 40)
                    }
                }
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 500, height: 600)
    }

    /// Rebuild triggerRules from specific device IDs only
    private func updateDeviceIDs(_ newIDs: [String]) {
        triggerRules = newIDs.map { TriggerRule.specificDevice(id: $0) }
    }
}
