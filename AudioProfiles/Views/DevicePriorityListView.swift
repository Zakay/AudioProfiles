import SwiftUI

struct DevicePriorityListView: View {
    @Binding var deviceList: [String]
    let title: String
    let isInput: Bool
    
    // Use new consolidated service instead of direct dependencies
    private let deviceFilterService = DeviceFilterService()
    @ObservedObject private var deviceHistoryService = AudioDeviceHistoryService.shared

    var body: some View {
        List {
            // Priority devices section
            if !deviceList.isEmpty {
                Section {
                    ForEach(Array(deviceList.enumerated()), id: \.element) { index, deviceId in
                        // Use reusable device row component
                        if let device = deviceFilterService.getDevice(by: deviceId) {
                            let isConnected = deviceFilterService.isDeviceConnected(deviceId)
                            
                            DeviceRowView.priorityRow(
                                device: device,
                                isConnected: isConnected,
                                onRemove: {
                                    if let removeIndex = deviceList.firstIndex(of: deviceId) {
                                        deviceList.remove(at: removeIndex)
                                    }
                                }
                            )
                        } else {
                            // Fallback for devices not in history (keep custom since it's special case)
                            HStack(spacing: 12) {
                                DeviceDisplayUtils.connectionStatusIndicator(isConnected: false)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(deviceId)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    
                                    Text("Device not found")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    if let removeIndex = deviceList.firstIndex(of: deviceId) {
                                        deviceList.remove(at: removeIndex)
                                    }
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .help("Remove from priority list")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onMove(perform: moveItems)
                } header: {
                    Text("Priority Order")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                        .padding(.bottom, 4)
                }
            }

            // Available devices section - use consolidated filtering service
            let deviceSections = deviceFilterService.getDevicesForPriorityList(isInput: isInput, excludingIDs: deviceList)
            
            if !deviceSections.current.isEmpty {
                Section {
                    ForEach(deviceSections.current, id: \.id) { device in
                        DeviceRowView.availableRow(
                            device: device,
                            isConnected: true,
                            onAdd: {
                                deviceList.append(device.id)
                            }
                        )
                    }
                } header: {
                    Text("Currently Connected")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                        .padding(.bottom, 4)
                }
            }
            
            if !deviceSections.previous.isEmpty {
                Section {
                    ForEach(deviceSections.previous, id: \.id) { device in
                        DeviceRowView.historicalRow(
                            device: device,
                            isConnected: false,
                            onTrash: {
                                deviceHistoryService.removeDeviceFromHistory(device.id)
                            },
                            onAdd: {
                                deviceList.append(device.id)
                            }
                        )
                    }
                } header: {
                    Text("Previously Seen (Last 30 Days)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                        .padding(.bottom, 4)
                }
            }
            
            // Show message if no devices available
            if deviceSections.current.isEmpty && deviceSections.previous.isEmpty {
                Section {
                    Text("No \(isInput ? "input" : "output") devices available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } header: {
                    Text("Available Devices")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                        .padding(.bottom, 4)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 180, maxHeight: 300)
    }
    
    private func moveItems(from indices: IndexSet, to newOffset: Int) {
        // Validate bounds first
        guard !deviceList.isEmpty,
              newOffset >= 0,
              newOffset <= deviceList.count,
              indices.allSatisfy({ $0 >= 0 && $0 < deviceList.count }) else {
            return
        }
        
        // Convert IndexSet to sorted array of indices
        let sortedIndices = indices.sorted()
        
        // Ensure we're not trying to move invalid indices
        guard let firstIndex = sortedIndices.first,
              let lastIndex = sortedIndices.last,
              firstIndex >= 0,
              lastIndex < deviceList.count else {
            return
        }
        
        // Perform safe manual move operation
        withAnimation(.easeInOut(duration: 0.2)) {
            // Extract items to move
            let itemsToMove = sortedIndices.map { deviceList[$0] }
            
            // Remove items from back to front to maintain indices
            for index in sortedIndices.reversed() {
                deviceList.remove(at: index)
            }
            
            // Calculate correct insertion point after removals
            let adjustedOffset = sortedIndices.reduce(newOffset) { offset, removedIndex in
                return removedIndex < newOffset ? offset - 1 : offset
            }
            
            // Ensure the insertion point is still valid
            let safeOffset = min(max(adjustedOffset, 0), deviceList.count)
            
            // Insert items at the new position
            for (i, item) in itemsToMove.enumerated() {
                let insertionIndex = min(safeOffset + i, deviceList.count)
                deviceList.insert(item, at: insertionIndex)
            }
        }
    }
}
