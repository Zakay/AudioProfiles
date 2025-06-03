import Foundation
import Combine

/// Manages device history tracking, persistence, and cleanup
class AudioDeviceHistoryService: ObservableObject {
    
    static let shared = AudioDeviceHistoryService()
    
    @Published private(set) var deviceHistory: [String: DeviceHistoryEntry] = [:]
    
    // 30 days in seconds
    private let deviceExpirationInterval: TimeInterval = 30 * 24 * 60 * 60
    
    private init() {
        loadDeviceHistory()
        pruneDeviceHistory()
    }
    
    /// Update device history with current devices
    /// - Parameter devices: Currently active devices
    func updateDeviceHistory(with devices: [AudioDevice]) {
        // Perform the complete update logic directly
        deviceHistory = performCompleteUpdate(deviceHistory, with: devices)
        
        // Clean up expired devices
        pruneDeviceHistory()
        
        // Save updated history
        saveDeviceHistory()
    }
    
    /// Get devices that were previously seen but are not currently active
    /// Only includes devices seen within the last 30 days
    /// - Parameter currentDevices: Currently active devices to filter out
    /// - Returns: Array of previously seen devices
    func getPreviouslySeenDevices(excluding currentDevices: [AudioDevice]) -> [AudioDevice] {
        let currentDeviceIDs = Set(currentDevices.map { $0.id })
        let cutoffDate = Date().addingTimeInterval(-deviceExpirationInterval)
        
        let previousDevices = deviceHistory.values
            .filter { entry in
                let isCurrentlyActive = entry.isCurrentlyActive
                let isInCurrentDevices = currentDeviceIDs.contains(entry.device.id)
                let isWithinTimeframe = entry.lastSeen >= cutoffDate
                
                return !isCurrentlyActive && !isInCurrentDevices && isWithinTimeframe
            }
            .map { $0.device }
            .sorted { $0.name < $1.name }
        
        return previousDevices
    }
    
    /// Get device from history by ID
    /// - Parameter deviceID: Device identifier
    /// - Returns: Device if found in history
    func getDevice(by deviceID: String) -> AudioDevice? {
        return deviceHistory[deviceID]?.device
    }
    
    /// Manually remove a device from history and all profiles
    /// If the device is detected again, it will be tracked again
    /// - Parameter deviceID: Device identifier to remove
    func removeDeviceFromHistory(_ deviceID: String) {
        guard let deviceEntry = deviceHistory[deviceID] else {
            return
        }
        
        let deviceName = deviceEntry.device.name
        
        // Remove from history first
        deviceHistory.removeValue(forKey: deviceID)
        saveDeviceHistory()
        
        // Immediately remove from all profiles to make behavior predictable
        let profileManager = ProfileManager.shared
        var profilesChanged = false
        
        for profile in profileManager.profiles {
            let originalProfile = profile
            var updatedProfile = profile
            
            // Remove from all device lists
            updatedProfile.triggerDeviceIDs.removeAll { $0 == deviceID }
            updatedProfile.publicOutputPriority.removeAll { $0 == deviceID }
            updatedProfile.publicInputPriority.removeAll { $0 == deviceID }
            updatedProfile.privateOutputPriority.removeAll { $0 == deviceID }
            updatedProfile.privateInputPriority.removeAll { $0 == deviceID }
            
            // Update profile if changes were made
            if updatedProfile.triggerDeviceIDs != originalProfile.triggerDeviceIDs ||
               updatedProfile.publicOutputPriority != originalProfile.publicOutputPriority ||
               updatedProfile.publicInputPriority != originalProfile.publicInputPriority ||
               updatedProfile.privateOutputPriority != originalProfile.privateOutputPriority ||
               updatedProfile.privateInputPriority != originalProfile.privateInputPriority {
                profileManager.upsert(updatedProfile, triggerAutoDetection: false)
                profilesChanged = true
            }
        }
        
        if profilesChanged {
            AppLogger.info("🗑️ Removed device '\(deviceName)' from history and all profiles")
        } else {
            AppLogger.info("🗑️ Removed device '\(deviceName)' from history")
        }
    }
    
    /// Clean up device history by removing devices older than 30 days
    /// With proper device UIDs, this is the only cleanup needed
    func pruneDeviceHistory() {
        let cutoffDate = Date().addingTimeInterval(-deviceExpirationInterval)
        var shouldSave = false
        
        // Remove devices older than 30 days
        for (deviceUID, entry) in deviceHistory {
            if entry.lastSeen < cutoffDate {
                deviceHistory.removeValue(forKey: deviceUID)
                shouldSave = true
            }
        }
        
        if shouldSave {
            saveDeviceHistory()
            AppLogger.info("🧹 Cleaned up expired devices from history")
        }
    }
    
    // MARK: - Private Methods
    
    /// Update existing device entries to mark inactive devices
    /// - Parameters:
    ///   - deviceHistory: Current device history to update
    ///   - currentDeviceIDs: Set of currently active device IDs
    ///   - timestamp: Current timestamp to use for updates
    /// - Returns: Updated device history with status changes
    private func updateExistingEntries(
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
    private func addOrUpdateDevices(
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
    private func performCompleteUpdate(
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
    
    private func loadDeviceHistory() {
        guard let data = UserDefaults.standard.data(forKey: "AudioDeviceHistory"),
              let history = try? JSONDecoder().decode([String: DeviceHistoryEntry].self, from: data) else {
            return
        }
        deviceHistory = history
        
        // Clean up expired devices on load
        pruneDeviceHistory()
    }
    
    private func saveDeviceHistory() {
        do {
            let data = try JSONEncoder().encode(deviceHistory)
            UserDefaults.standard.set(data, forKey: "AudioDeviceHistory")
        } catch {
            AppLogger.error("Failed to save device history: \(error)")
        }
    }
} 