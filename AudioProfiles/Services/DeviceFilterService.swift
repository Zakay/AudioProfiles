import Foundation

/// Centralizes device filtering and querying logic to eliminate duplication across views
///
/// **Responsibility**: Provides simplified, high-level methods for querying audio devices
/// **Architecture Role**: Service (Querying & Filtering)
/// **Usage**: Instantiated by other services; not a singleton
/// **Key Dependencies**: AudioDeviceHistoryService, AudioDeviceFactory
class DeviceFilterService {
    
    // MARK: - Dependencies
    private let deviceHistoryService = AudioDeviceHistoryService.shared
    
    // MARK: - Core Device Retrieval
    
    /// Get all currently connected devices
    func getConnectedDevices(sorted: Bool = false) -> [AudioDevice] {
        return AudioDeviceFactory.getCurrentDevices(sorted: sorted)
    }
    
    /// Get devices seen previously but not currently connected
    func getPreviousDevices(excluding currentDevices: [AudioDevice]? = nil) -> [AudioDevice] {
        let current = currentDevices ?? getConnectedDevices()
        return deviceHistoryService.getPreviouslySeenDevices(excluding: current)
    }
    
    /// Get all known devices (current + historical)
    func getAllKnownDevices() -> [AudioDevice] {
        let currentDevices = getConnectedDevices()
        let historicalDevices = getPreviousDevices(excluding: currentDevices)
        return (currentDevices + historicalDevices).sorted { $0.name < $1.name }
    }
    
    // MARK: - Type Filtering
    
    /// Filter devices by input/output type
    func filterByType(_ devices: [AudioDevice], isInput: Bool) -> [AudioDevice] {
        return devices.filter { isInput ? $0.isInput : $0.isOutput }
    }
    
    /// Get connected devices of specific type
    func getConnectedDevices(isInput: Bool, sorted: Bool = false) -> [AudioDevice] {
        return filterByType(getConnectedDevices(sorted: sorted), isInput: isInput)
    }
    
    /// Get previous devices of specific type  
    func getPreviousDevices(isInput: Bool, excluding currentDevices: [AudioDevice]? = nil) -> [AudioDevice] {
        return filterByType(getPreviousDevices(excluding: currentDevices), isInput: isInput)
    }
    
    // MARK: - Selection Filtering
    
    /// Exclude devices that are already selected
    func excludeSelected(_ devices: [AudioDevice], selectedIDs: [String]) -> [AudioDevice] {
        return devices.filter { !selectedIDs.contains($0.id) }
    }
    
    /// Get available devices of specific type, excluding already selected ones
    func getAvailableDevices(isInput: Bool, excludingIDs selectedIDs: [String], includeHistorical: Bool = true) -> [AudioDevice] {
        var availableDevices = getConnectedDevices(isInput: isInput)
        
        if includeHistorical {
            let historicalDevices = getPreviousDevices(isInput: isInput)
            // Avoid duplicates by checking if device ID already exists in current devices
            let uniqueHistorical = historicalDevices.filter { historical in
                !availableDevices.contains { current in current.id == historical.id }
            }
            availableDevices.append(contentsOf: uniqueHistorical)
        }
        
        return excludeSelected(availableDevices, selectedIDs: selectedIDs)
    }
    
    // MARK: - Device Status & Lookup
    
    /// Check if a device is currently connected
    func isDeviceConnected(_ deviceID: String) -> Bool {
        return getConnectedDevices().contains { $0.id == deviceID }
    }
    
    /// Get device by ID from current devices or history
    func getDevice(by deviceID: String) -> AudioDevice? {
        // First try current devices
        if let device = getConnectedDevices().first(where: { $0.id == deviceID }) {
            return device
        }
        
        // Then try device history
        return deviceHistoryService.getDevice(by: deviceID)
    }
    
    /// Get devices by IDs, maintaining order and filtering out missing ones
    func getDevices(by deviceIDs: [String]) -> [AudioDevice] {
        return deviceIDs.compactMap { getDevice(by: $0) }
    }
    
    // MARK: - Combined Filtering Operations
    
    /// Get devices for device priority list UI - separates current vs previous with proper filtering
    func getDevicesForPriorityList(isInput: Bool, excludingIDs selectedIDs: [String]) -> (current: [AudioDevice], previous: [AudioDevice]) {
        let currentDevices = excludeSelected(
            getConnectedDevices(isInput: isInput),
            selectedIDs: selectedIDs
        )
        
        let previousDevices = getPreviousDevices(isInput: isInput)
            .filter { previousDevice in
                // Exclude selected devices and avoid duplicates with current devices
                !selectedIDs.contains(previousDevice.id) &&
                !currentDevices.contains { currentDevice in currentDevice.id == previousDevice.id }
            }
        
        return (current: currentDevices, previous: previousDevices)
    }
    
    /// Get devices for trigger selection UI - separates current vs previous
    func getDevicesForTriggerSelection(excludingIDs selectedIDs: [String]) -> (current: [AudioDevice], previous: [AudioDevice]) {
        let currentDevices = excludeSelected(getConnectedDevices(sorted: true), selectedIDs: selectedIDs)
        
        let previousDevices = getPreviousDevices()
            .filter { previousDevice in
                // Exclude selected devices and avoid duplicates with current devices  
                !selectedIDs.contains(previousDevice.id) &&
                !currentDevices.contains { currentDevice in currentDevice.id == previousDevice.id }
            }
        
        return (current: currentDevices, previous: previousDevices)
    }
} 