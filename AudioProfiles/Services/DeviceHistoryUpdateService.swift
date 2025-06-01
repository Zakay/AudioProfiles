import Foundation

/// Handles device history entry updates and additions
class DeviceHistoryUpdateService {
    
    /// Update existing device entries to mark inactive devices
    /// - Parameters:
    ///   - deviceHistory: Current device history to update
    ///   - currentDeviceIDs: Set of currently active device IDs
    ///   - timestamp: Current timestamp to use for updates
    /// - Returns: Updated device history with status changes
    func updateExistingEntries(
        _ deviceHistory: [String: DeviceHistoryEntry],
        currentDeviceIDs: Set<String>,
        timestamp: Date
    ) -> [String: DeviceHistoryEntry] {
        
        var updatedHistory = deviceHistory
        
        // Update existing entries - mark as inactive if not currently present
        for (deviceID, entry) in deviceHistory {
            let isCurrentlyActive = currentDeviceIDs.contains(deviceID)
            updatedHistory[deviceID] = DeviceHistoryEntry(
                device: entry.device,
                lastSeen: isCurrentlyActive ? timestamp : entry.lastSeen,
                isCurrentlyActive: isCurrentlyActive
            )
        }
        
        return updatedHistory
    }
    
    /// Add new devices to history or update existing ones with current data
    /// - Parameters:
    ///   - deviceHistory: Current device history to update
    ///   - devices: Currently active devices to add/update
    ///   - timestamp: Current timestamp to use for new entries
    /// - Returns: Updated device history with new/updated devices
    func addOrUpdateDevices(
        _ deviceHistory: [String: DeviceHistoryEntry],
        devices: [AudioDevice],
        timestamp: Date
    ) -> [String: DeviceHistoryEntry] {
        
        var updatedHistory = deviceHistory
        
        // Add new devices to history
        for device in devices {
            if updatedHistory[device.id] == nil {
                // Completely new device
                updatedHistory[device.id] = DeviceHistoryEntry(
                    device: device,
                    lastSeen: timestamp,
                    isCurrentlyActive: true
                )
            } else {
                // Update existing device to ensure it's marked as active and has latest device info
                updatedHistory[device.id] = DeviceHistoryEntry(
                    device: device, // Use the current device data (might have updated properties)
                    lastSeen: timestamp,
                    isCurrentlyActive: true
                )
            }
        }
        
        return updatedHistory
    }
    
    /// Complete update process for device history
    /// - Parameters:
    ///   - deviceHistory: Current device history
    ///   - devices: Currently active devices
    ///   - timestamp: Current timestamp
    /// - Returns: Fully updated device history
    func performCompleteUpdate(
        _ deviceHistory: [String: DeviceHistoryEntry],
        with devices: [AudioDevice],
        timestamp: Date = Date()
    ) -> [String: DeviceHistoryEntry] {
        
        let currentDeviceIDs = Set(devices.map { $0.id })
        
        // Step 1: Update existing entries
        let historyWithUpdatedStatus = updateExistingEntries(
            deviceHistory,
            currentDeviceIDs: currentDeviceIDs,
            timestamp: timestamp
        )
        
        // Step 2: Add or update devices
        let finalHistory = addOrUpdateDevices(
            historyWithUpdatedStatus,
            devices: devices,
            timestamp: timestamp
        )
        
        return finalHistory
    }
} 