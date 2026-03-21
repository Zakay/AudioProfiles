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

    /// Debounce work item — coalesces rapid device notifications into one query.
    private var debounceWork: DispatchWorkItem?
    /// How long to wait after the last notification before querying Core Audio.
    private let debounceInterval: TimeInterval = 0.5
    /// True while coreaudiod is restarting — suppresses device queries until stable.
    private var isRestarting = false

    private init() {
        setupServiceRestartMonitoring()
        setupDeviceMonitoring()

        // Query current devices on background queue to avoid blocking main thread
        // if coreaudiod is slow/restarting. Publishes the initial device list through
        // the same deviceChangesSubject so subscribers get it automatically.
        audioQueue.async { [weak self] in
            let currentDevices = AudioDeviceFactory.getCurrentDevices()
            guard let self = self else { return }
            self.lastKnownDeviceIDs = Set(currentDevices.map { $0.id })
            AppLogger.info("AudioDeviceMonitor initialized with \(currentDevices.count) devices")
            DispatchQueue.main.async {
                self.deviceChangesSubject.send(currentDevices)
            }
        }
    }

    private func setupDeviceMonitoring() {
        // Listener fires on audioQueue — Core Audio queries won't block main
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            audioQueue
        ) { [weak self] _, _ in
            self?.scheduleDeviceQuery()
        }
    }

    private func setupServiceRestartMonitoring() {
        // Restart listener also on audioQueue so it isn't blocked by a hanging device query
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &restartAddress,
            audioQueue
        ) { [weak self] _, _ in
            guard let self = self else { return }
            AppLogger.info("coreaudiod service restarted — suppressing queries for stabilization")
            self.isRestarting = true
            self.debounceWork?.cancel()
            self.lastKnownDeviceIDs = []

            DispatchQueue.main.async {
                self.serviceRestartedSubject.send()
            }

            // After coreaudiod restart, wait for the system to stabilize before querying.
            // Devices register one by one; querying too early gets partial/hanging results.
            let stabilizeWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.isRestarting = false
                AppLogger.info("coreaudiod stabilization period ended — querying devices")
                self.handleDeviceListChange()
            }
            self.audioQueue.asyncAfter(deadline: .now() + 2.0, execute: stabilizeWork)
        }
    }

    /// Debounce rapid device notifications into a single query.
    private func scheduleDeviceQuery() {
        debounceWork?.cancel()
        // During restart, don't schedule — the stabilization timer handles it.
        guard !isRestarting else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.handleDeviceListChange()
        }
        debounceWork = work
        audioQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
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
