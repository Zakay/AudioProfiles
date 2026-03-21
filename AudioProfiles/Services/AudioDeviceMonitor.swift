import Foundation
import CoreAudio
import Combine

/// Service responsible for monitoring Core Audio device changes
/// Follows single responsibility principle - only detects and publishes device changes
class AudioDeviceMonitor: ObservableObject {
    static let shared = AudioDeviceMonitor()

    /// Published when device list changes (connect/disconnect events)
    let deviceChangesSubject = PassthroughSubject<[AudioDevice], Never>()

    /// Published when coreaudiod restarts — subscribers should tear down hardware-bound state
    let serviceRestartedSubject = PassthroughSubject<Void, Never>()

    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var restartAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Background queue for Core Audio callbacks and queries.
    /// Keeps the main thread free even if Core Audio calls block during coreaudiod restart.
    private let audioQueue = DispatchQueue(label: "com.audioprofiles.devicemonitor", qos: .userInitiated)

    private var lastKnownDeviceIDs: Set<String> = []

    private init() {
        setupServiceRestartMonitoring()
        setupDeviceMonitoring()

        // Initialize with current devices
        let currentDevices = AudioDeviceFactory.getCurrentDevices()
        lastKnownDeviceIDs = Set(currentDevices.map { $0.id })

        AppLogger.info("AudioDeviceMonitor initialized with \(currentDevices.count) devices")
    }

    private func setupDeviceMonitoring() {
        // Listener fires on audioQueue — Core Audio queries won't block main
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            audioQueue
        ) { [weak self] _, _ in
            self?.handleDeviceListChange()
        }
    }

    private func setupServiceRestartMonitoring() {
        // Restart listener also on audioQueue so it isn't blocked by a hanging device query
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &restartAddress,
            audioQueue
        ) { [weak self] _, _ in
            AppLogger.info("coreaudiod service restarted — notifying subscribers")
            self?.lastKnownDeviceIDs = []
            DispatchQueue.main.async {
                self?.serviceRestartedSubject.send()
            }
        }
    }

    private func handleDeviceListChange() {
        // This runs on audioQueue — safe to call Core Audio APIs that might block briefly
        let newDevices = AudioDeviceFactory.getCurrentDevices()
        let newDeviceIDs = Set(newDevices.map { $0.id })

        // Log device changes for debugging
        let addedDevices = newDeviceIDs.subtracting(lastKnownDeviceIDs)
        let removedDevices = lastKnownDeviceIDs.subtracting(newDeviceIDs)

        if !addedDevices.isEmpty {
            let addedNames = addedDevices.compactMap { id in
                newDevices.first { $0.id == id }?.name
            }
            AppLogger.info("Audio devices connected: \(addedNames.joined(separator: ", "))")
        }

        if !removedDevices.isEmpty {
            // Just log the IDs — history service is main-thread only
            AppLogger.info("Audio devices disconnected: \(removedDevices.joined(separator: ", "))")
        }

        // Update tracking and notify subscribers on main thread
        lastKnownDeviceIDs = newDeviceIDs
        DispatchQueue.main.async { [weak self] in
            self?.deviceChangesSubject.send(newDevices)
        }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            audioQueue
        ) { _, _ in }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &restartAddress,
            audioQueue
        ) { _, _ in }
    }
}
