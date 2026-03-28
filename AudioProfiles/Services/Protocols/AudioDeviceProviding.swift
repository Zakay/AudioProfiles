import Foundation

/// Protocol for querying the current list of Core Audio devices.
///
/// Abstracting this allows ProfileManager and pipeline tests to inject a mock
/// device list instead of requiring a live Core Audio session.
protocol AudioDeviceProviding {
    /// Returns all currently connected audio devices.
    func getCurrentDevices() -> [AudioDevice]
}
