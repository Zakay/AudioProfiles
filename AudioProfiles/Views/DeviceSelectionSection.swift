import SwiftUI

struct DeviceSelectionSection: View {
    let title: String
    let devices: [AudioDevice]
    @Binding var selectedDeviceIDs: [String]
    let showRemoveButtons: Bool
    let isSelectedSection: Bool
    
    // Use new consolidated service
    private let deviceFilterService = DeviceFilterService()
    @ObservedObject private var deviceHistoryService = AudioDeviceHistoryService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            if devices.isEmpty {
                Text(isSelectedSection ? "No devices selected" : "No devices available")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(devices) { device in
                        deviceRow(for: device)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func deviceRow(for device: AudioDevice) -> some View {
        let isConnected = deviceFilterService.isDeviceConnected(device.id)
        
        DeviceRowView.selectionRow(
            device: device,
            isConnected: isConnected,
            isSelectedSection: isSelectedSection,
            showRemoveButtons: showRemoveButtons,
            onToggle: {
                toggleDeviceSelection(device.id)
            },
            onTrash: showRemoveButtons ? {
                deviceHistoryService.removeDeviceFromHistory(device.id)
            } : nil
        )
    }
    
    private func toggleDeviceSelection(_ deviceID: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedDeviceIDs.contains(deviceID) {
                selectedDeviceIDs.removeAll { $0 == deviceID }
            } else {
                selectedDeviceIDs.append(deviceID)
            }
        }
    }
} 