import Foundation
import Combine

/// Handles the direct application of profile settings to the system
///
/// **Responsibility**: Sets default system audio devices based on profile priorities and mode
/// **Architecture Role**: Service (Low-Level System Interaction)
/// **Usage**: Instantiated by ProfileManager; not a singleton
/// **Key Dependencies**: AudioDeviceControlService
class ProfileActivationService: ObservableObject {
    @Published private(set) var activeProfile: Profile?
    @Published private(set) var activeMode: ProfileMode = .public
    
    // Direct service dependencies - no facade needed
    private let deviceControlService = AudioDeviceControlService()
    
    func activateProfile(_ profile: Profile) {
        activeProfile = profile
        
        // Switch to profile's preferred mode
        if activeMode != profile.preferredMode {
            activeMode = profile.preferredMode
            AppLogger.info("Switched to \(profile.preferredMode.rawValue) mode (preferred by profile '\(profile.name)')")
        }
        
        applyProfile(profile)
        AppLogger.info("Activated profile: \(profile.name)")
    }
    
    func deactivateProfile() {
        activeProfile = nil
    }
    
    func toggleMode() {
        activeMode = (activeMode == .public) ? .private : .public
        if let profile = activeProfile {
            applyProfile(profile)
        }
        AppLogger.info("Switched to \(activeMode.rawValue) mode")
    }

    /// Refresh the currently active profile when its configuration changes.
    /// - Parameters:
    ///   - profile: Updated profile definition.
    ///   - preserveMode: Whether to keep the current mode instead of forcing the preferred mode.
    func refreshActiveProfile(with profile: Profile, preserveMode: Bool = true) {
        let targetMode = preserveMode ? activeMode : profile.preferredMode

        if activeMode != targetMode {
            activeMode = targetMode
        }

        activeProfile = profile
        applyProfile(profile)
        AppLogger.info("Refreshed active profile: \(profile.name) (preserveMode: \(preserveMode))")
    }
    
    private func applyProfile(_ profile: Profile) {
        // Get current devices directly from factory
        let devices = AudioDeviceFactory.getCurrentDevices()
        let outputList = (activeMode == .public) ? profile.publicOutputPriority : profile.privateOutputPriority
        let inputList = (activeMode == .public) ? profile.publicInputPriority : profile.privateInputPriority

        // Apply output device using direct service call
        for deviceID in outputList {
            if let device = findDevice(by: deviceID, in: devices, isOutput: true) {
                if deviceControlService.setDefaultOutputDevice(device) {
                    AppLogger.info("Set output device: \(device.name)")
                    break
                } else {
                    AppLogger.error("Failed to set output device: \(device.name)")
                }
            }
        }
        
        // Apply input device using direct service call
        for deviceID in inputList {
            if let device = findDevice(by: deviceID, in: devices, isInput: true) {
                if deviceControlService.setDefaultInputDevice(device) {
                    AppLogger.info("Set input device: \(device.name)")
                    break
                } else {
                    AppLogger.error("Failed to set input device: \(device.name)")
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func findDevice(by deviceID: String, in devices: [AudioDevice], isOutput: Bool = false, isInput: Bool = false) -> AudioDevice? {
        return devices.first { device in
            device.id == deviceID && 
            (!isOutput || device.isOutput) && 
            (!isInput || device.isInput)
        }
    }
} 
