import SwiftUI

struct DevicePriorityView: View {
    @Binding var deviceList: [String]
    let isOutput: Bool
    @Environment(\.dismiss) var dismiss
    @State private var currentDevices: [AudioDevice] = []
    @State private var historicalDevices: [AudioDevice] = []
    
    // Observe shared singleton for automatic UI updates
    @ObservedObject private var deviceHistoryService = AudioDeviceHistoryService.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Spacer()
                
                Text("\(isOutput ? "Output" : "Input") Device Priority")
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
                        Text("Drag to reorder device priority. The first available device will be used.")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        Text("• Higher devices in the list have priority")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Remove devices you don't want to use")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    // Current priority list
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Priority Order")
                            .font(.headline)
                        
                        if deviceList.isEmpty {
                            Text("No devices selected. Add devices from below.")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 16)
                        } else {
                            let selectedDevices = deviceList.compactMap { deviceId in
                                currentDevices.first { $0.id == deviceId } ??
                                historicalDevices.first { $0.id == deviceId }
                            }
                            
                            List {
                                ForEach(Array(selectedDevices.enumerated()), id: \.element.id) { index, device in
                                    HStack(spacing: 12) {
                                        // Priority number
                                        Text("\(index + 1)")
                                            .font(.caption)
                                            .foregroundColor(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Color.accentColor)
                                            .clipShape(Circle())
                                        
                                        // Device info with icon
                                        HStack(spacing: 8) {
                                            Image(systemName: DeviceDisplayUtils.deviceIcon(for: device))
                                                .foregroundColor(.accentColor)
                                                .frame(width: 20)
                                            
                                            DeviceDisplayUtils.deviceInfoView(for: device, isConnected: true)
                                        }
                                        
                                        Spacer()
                                        
                                        // Remove button
                                        Button(action: {
                                            removeDevice(device.id)
                                        }) {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                    }
                                    .padding(.vertical, 4)
                                }
                                .onMove(perform: moveDevices)
                                .onDelete(perform: deleteDevices)
                            }
                            .frame(height: min(CGFloat(selectedDevices.count * 50), 300))
                            .scrollContentBackground(.hidden)
                        }
                    }
                    
                    // Available devices to add
                    let availableDevices = filterDevices()
                    if !availableDevices.isEmpty {
                        DeviceSelectionSection(
                            title: "Available Devices",
                            devices: availableDevices,
                            selectedDeviceIDs: $deviceList,
                            showRemoveButtons: false,
                            isSelectedSection: false
                        )
                    }
                }
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 600, height: 700)
        .onAppear {
            loadDevices()
        }
    }
    
    private func loadDevices() {
        currentDevices = AudioDeviceFactory.getCurrentDevices()
        historicalDevices = deviceHistoryService.getPreviouslySeenDevices(excluding: currentDevices)
    }
    
    private func filterDevices() -> [AudioDevice] {
        let filteredType = isOutput ? 
            currentDevices.filter { $0.isOutput } :
            currentDevices.filter { $0.isInput }
        
        return filteredType.filter { !deviceList.contains($0.id) }
    }
    
    private func removeDevice(_ deviceId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            deviceList.removeAll { $0 == deviceId }
        }
    }
    
    private func moveDevices(from source: IndexSet, to destination: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            deviceList.move(fromOffsets: source, toOffset: destination)
        }
    }
    
    private func deleteDevices(at offsets: IndexSet) {
        withAnimation(.easeInOut(duration: 0.2)) {
            deviceList.remove(atOffsets: offsets)
        }
    }
} 