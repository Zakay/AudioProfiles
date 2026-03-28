import Foundation

/// Protocol for the system default audio device control service.
///
/// Abstracting this allows AudioPipelineService and tests to inject a mock
/// instead of requiring a live Core Audio session.
protocol AudioDeviceControlServiceProtocol {
    /// Returns the current system default output device, or nil if unavailable.
    func getDefaultOutputDevice() -> AudioDevice?
    /// Returns the current system default input device, or nil if unavailable.
    func getDefaultInputDevice() -> AudioDevice?
    /// Sets the system default output device. Returns true on success.
    @discardableResult func setDefaultOutputDevice(_ device: AudioDevice) -> Bool
    /// Sets the system default input device. Returns true on success.
    @discardableResult func setDefaultInputDevice(_ device: AudioDevice) -> Bool
}
