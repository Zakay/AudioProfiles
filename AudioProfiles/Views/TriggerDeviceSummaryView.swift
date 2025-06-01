import SwiftUI

struct TriggerDeviceSummaryView: View {
    @Binding var selectedDeviceIDs: [String]
    @State private var showingSelectionSheet = false
    
    // Use new consolidated service
    private let deviceFilterService = DeviceFilterService()
    
    var body: some View {
        Button(action: {
            showingSelectionSheet = true
        }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryText)
                        .font(.body)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .sheet(isPresented: $showingSelectionSheet) {
            TriggerDeviceSelectionView(selectedDeviceIDs: $selectedDeviceIDs)
        }
    }
    
    private var summaryText: String {
        if selectedDeviceIDs.isEmpty {
            return "None"
        }
        
        // Get device names, filtering out unknown devices
        let deviceNames = selectedDeviceIDs.compactMap { deviceId in
            deviceFilterService.getDevice(by: deviceId)?.name
        }
        
        // Handle case where some device IDs couldn't be resolved
        if deviceNames.isEmpty {
            return "\(selectedDeviceIDs.count) device\(selectedDeviceIDs.count == 1 ? "" : "s") selected"
        }
        
        // Use consolidated device name formatting utility
        return DeviceDisplayUtils.formatDeviceNames(deviceNames)
    }
} 