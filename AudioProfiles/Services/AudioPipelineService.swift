import Foundation

/// Stateless apply logic for the audio pipeline.
/// Receives the computed desired state from `ProfileManager.evaluateAndApply()`
/// and executes Core Audio calls to realize it.
///
/// **Responsibility**: Orchestrate EQ engine start/stop/switch/update and device switching
/// **Architecture Role**: Service (Low-Level System Interaction)
/// **Usage**: Instantiated by ProfileManager; not a singleton
@MainActor
final class AudioPipelineService {

    private let deviceControlService: AudioDeviceControlServiceProtocol = AudioDeviceControlService()

    // MARK: - Apply Pipeline

    /// Execute the desired audio state. Called from `ProfileManager.evaluateAndApply()`.
    ///
    /// - Parameters:
    ///   - outputDevice: Resolved output AudioDevice (nil = no change / keep current)
    ///   - inputDevice: Resolved input AudioDevice (nil = no change / keep current)
    ///   - effectiveEQ: Combined L1+L2+L3 EQ settings
    ///   - needsVirtualDriver: Whether the virtual driver should be active
    ///   - virtualDeviceName: Display name for the virtual device (e.g. "AirPods Pro EQ")
    ///   - outputDeviceUID: UID of the real output device (for EQ engine calls)
    func apply(
        outputDevice: AudioDevice?,
        inputDevice: AudioDevice?,
        effectiveEQ: EQSettings,
        needsVirtualDriver: Bool,
        virtualDeviceName: String?,
        outputDeviceUID: String?
    ) {
        // 1. Orphan recovery: if the virtual device is system default but EQ isn't running
        recoverOrphanedVirtualDevice(intendedOutputDevice: outputDevice)

        // 2. Handle EQ pipeline state transitions
        let eqRunning = EQEngineService.shared.isRunning
        let currentTargetUID = EQEngineService.shared.targetDeviceUID

        if needsVirtualDriver, let deviceUID = outputDeviceUID, let vName = virtualDeviceName {
            if eqRunning, currentTargetUID == deviceUID {
                // Same device, EQ running → hot-update settings
                EQEngineService.shared.updateSettings(effectiveEQ)
                AppLogger.info("AudioPipelineService: updated EQ settings for '\(vName)'")
            } else if eqRunning {
                // Different device, EQ running → switch device
                EQEngineService.shared.switchDevice(
                    realDeviceUID: deviceUID,
                    settings: effectiveEQ,
                    virtualDeviceName: vName
                )
                AppLogger.info("AudioPipelineService: switched EQ device to '\(vName)'")
            } else {
                // EQ not running → full start
                AppLogger.info("AudioPipelineService: starting EQ for '\(vName)'")
                EQEngineService.shared.startPipeline(
                    realDeviceUID: deviceUID,
                    settings: effectiveEQ,
                    virtualDeviceName: vName
                )
            }
        } else if eqRunning, let deviceUID = outputDeviceUID {
            // EQ running but no longer needed → stop
            AppLogger.info("AudioPipelineService: stopping EQ — no longer needed")
            EQEngineService.shared.stopSafe(switchTo: deviceUID)
        } else if eqRunning {
            // EQ running, no output device resolved → stop gracefully
            AppLogger.info("AudioPipelineService: stopping EQ — no output device")
            EQEngineService.shared.stopSafe()
        } else if !needsVirtualDriver, let device = outputDevice {
            // No EQ needed → set device directly
            if deviceControlService.setDefaultOutputDevice(device) {
                AppLogger.info("AudioPipelineService: set output device: \(device.name)")
            } else {
                AppLogger.error("AudioPipelineService: failed to set output device: \(device.name)")
            }
        }

        // 3. Apply input device
        if let device = inputDevice {
            if deviceControlService.setDefaultInputDevice(device) {
                AppLogger.info("AudioPipelineService: set input device: \(device.name)")
            } else {
                AppLogger.error("AudioPipelineService: failed to set input device: \(device.name)")
            }
        }
    }

    // MARK: - Orphan Recovery

    /// If the virtual device is the system default but EQ engine isn't running,
    /// clean up by switching to the intended real device and hiding the virtual device.
    private func recoverOrphanedVirtualDevice(intendedOutputDevice: AudioDevice?) {
        guard !EQEngineService.shared.isRunning,
              let _ = EQDriverService.shared.findAudioDevice() else { return }

        let currentDefault = deviceControlService.getDefaultOutputDevice()
        guard let current = currentDefault, EQDriverService.shared.isOurVirtualDevice(current.id) else { return }

        AppLogger.info("AudioPipelineService: orphan recovery — virtual device is system default but EQ not running")

        if let realDevice = intendedOutputDevice {
            _ = deviceControlService.setDefaultOutputDevice(realDevice)
        }
        EQDriverService.shared.hide()
    }

    /// Public entry point for early orphan recovery at app startup.
    /// Called from ProfileManager.initialize() before trigger detection runs,
    /// so the user gets audio back ASAP after a crash.
    func recoverOrphanIfNeeded() {
        recoverOrphanedVirtualDevice(intendedOutputDevice: nil)
    }

    // MARK: - Direct Device Setting (for setActiveProfileWithoutApplying path)

    func getDefaultOutputDevice() -> AudioDevice? {
        deviceControlService.getDefaultOutputDevice()
    }

    func getDefaultInputDevice() -> AudioDevice? {
        deviceControlService.getDefaultInputDevice()
    }
}
