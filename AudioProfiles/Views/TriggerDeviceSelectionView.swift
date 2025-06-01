import SwiftUI

struct TriggerDeviceSelectionView: View {
    @Binding var selectedDeviceIDs: [String]
    @Environment(\.dismiss) var dismiss
    
    // Use new consolidated service instead of manual state management
    private let deviceFilterService = DeviceFilterService()
    @ObservedObject private var deviceHistoryService = AudioDeviceHistoryService.shared

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
            
            // Content with scroll view
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
                    
                    // Selected devices (use service to get devices by IDs)
                    let selectedDevices = deviceFilterService.getDevices(by: selectedDeviceIDs)
                    
                    if !selectedDevices.isEmpty {
                        DeviceSelectionSection(
                            title: "Selected Trigger Devices",
                            devices: selectedDevices,
                            selectedDeviceIDs: $selectedDeviceIDs,
                            showRemoveButtons: true,
                            isSelectedSection: true
                        )
                    }
                    
                    // Use consolidated filtering service
                    let deviceSections = deviceFilterService.getDevicesForTriggerSelection(excludingIDs: selectedDeviceIDs)
                    
                    // Currently connected devices (excluding selected ones)
                    if !deviceSections.current.isEmpty {
                        DeviceSelectionSection(
                            title: "Currently Connected",
                            devices: deviceSections.current,
                            selectedDeviceIDs: $selectedDeviceIDs,
                            showRemoveButtons: false,
                            isSelectedSection: false
                        )
                    }
                    
                    // Previously seen devices (excluding selected ones and duplicates)
                    if !deviceSections.previous.isEmpty {
                        DeviceSelectionSection(
                            title: "Previously Seen (Last 30 Days)",
                            devices: deviceSections.previous,
                            selectedDeviceIDs: $selectedDeviceIDs,
                            showRemoveButtons: true,
                            isSelectedSection: false
                        )
                    }
                    
                    // Show message if no devices available
                    if deviceSections.current.isEmpty && deviceSections.previous.isEmpty {
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
} 