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
    @Published private(set) var activeOutputDeviceName: String?
    @Published private(set) var activeInputDeviceName: String?

    // Direct service dependencies - no facade needed
    private let deviceControlService = AudioDeviceControlService()
    
    func activateProfile(_ profile: Profile, restoredMode: ProfileMode? = nil) {
        activeProfile = profile

        // Use restored mode if provided (persisted from last session), otherwise profile's preferred mode
        let targetMode = restoredMode ?? profile.preferredMode
        if activeMode != targetMode {
            activeMode = targetMode
            AppLogger.info("Switched to \(targetMode.rawValue) mode for profile '\(profile.name)'"
                + (restoredMode != nil ? " (restored)" : " (preferred)"))
        }

        applyProfile(profile)
        AppLogger.info("Activated profile: \(profile.name)")
    }

    /// Set the active profile and mode without applying device changes.
    /// Use during init when Core Audio calls must be avoided on the main thread.
    func setActiveProfileWithoutApplying(_ profile: Profile, restoredMode: ProfileMode? = nil) {
        activeProfile = profile
        let targetMode = restoredMode ?? profile.preferredMode
        if activeMode != targetMode {
            activeMode = targetMode
        }
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
        let outputList = profile.priorityList(isOutput: true, mode: activeMode)
        let inputList = profile.priorityList(isOutput: false, mode: activeMode)

        // Resolve output device from priority list
        var resolvedOutputDevice: AudioDevice?
        for deviceID in outputList {
            if let device = findDevice(by: deviceID, in: devices, isOutput: true) {
                resolvedOutputDevice = device
                break
            }
        }

        // Apply output device with minimal disruption:
        // - EQ running → EQ device:     switchDevice() (hot-swap, no system default change)
        // - EQ running → non-EQ device: switchDevice() with flat EQ (keeps virtual device active)
        // - EQ stopped → EQ device:     full start()
        // - EQ stopped → non-EQ device: just set system default directly
        var didSetOutput = false
        if let device = resolvedOutputDevice {
            let deviceID = device.id
            let deviceName = device.name
            let controlService = deviceControlService

            // EQ checks and operations must run on @MainActor
            Task { @MainActor in
                let eqSettings = EQStore.shared.activeEQ(for: deviceID)
                let hasEQ = eqSettings != nil && EQInstallationService.shared.isInstalled
                let eqRunning = EQEngineService.shared.isRunning
                if eqRunning {
                    // Hot-swap to new device (keeps virtual device as system default)
                    let settings = eqSettings ?? EQSettings.flat
                    EQEngineService.shared.switchDevice(
                        realDeviceUID: deviceID,
                        settings: settings,
                        virtualDeviceName: "\(deviceName) EQ"
                    )
                } else if hasEQ {
                    // Full start
                    AppLogger.info("Starting EQ for '\(deviceName)'")
                    EQEngineService.shared.start(
                        realDeviceUID: deviceID,
                        settings: eqSettings!,
                        virtualDeviceName: "\(deviceName) EQ"
                    )
                } else {
                    // No EQ — direct device switch
                    if controlService.setDefaultOutputDevice(device) {
                        AppLogger.info("Set output device: \(deviceName)")
                    } else {
                        AppLogger.error("Failed to set output device: \(deviceName)")
                    }
                    // Stop EQ if it was running for a different device
                    if EQEngineService.shared.isRunning {
                        AppLogger.info("Stopping EQ: device changed to '\(deviceName)' (no EQ)")
                        EQEngineService.shared.stopSafe(switchTo: deviceID)
                    }
                }
            }
            activeOutputDeviceName = device.name
            didSetOutput = true
        }

        // Apply input device using direct service call
        var didSetInput = false
        for deviceID in inputList {
            if let device = findDevice(by: deviceID, in: devices, isInput: true) {
                if deviceControlService.setDefaultInputDevice(device) {
                    AppLogger.info("Set input device: \(device.name)")
                    activeInputDeviceName = device.name
                    didSetInput = true
                    break
                } else {
                    AppLogger.error("Failed to set input device: \(device.name)")
                }
            }
        }

        // Fall back to current system defaults for display when profile has no priorities
        if !didSetOutput {
            activeOutputDeviceName = deviceControlService.getDefaultOutputDevice()?.name
        }
        if !didSetInput {
            activeInputDeviceName = deviceControlService.getDefaultInputDevice()?.name
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
