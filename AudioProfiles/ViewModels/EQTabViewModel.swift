import Foundation
import Combine

/// ViewModel for EQTabView.
///
/// Owns device list state and selection logic — extracted from EQTabView so
/// the view only handles layout. Subscribes to AudioDeviceMonitor events
/// and keeps the device list current without blocking the main thread.
@MainActor
final class EQTabViewModel: ObservableObject {

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedDeviceID: String? = nil

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Observe device changes from the monitor (queries Core Audio on background queue)
        AudioDeviceMonitor.shared.deviceChangesSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self else { return }
                self.outputDevices = devices.filter(\.isOutput).sorted { $0.name < $1.name }
                // Resolve the system default off the main thread
                DispatchQueue.global(qos: .userInitiated).async {
                    let defaultUID = AudioDeviceControlService().getDefaultOutputDevice()?.id
                    Task { @MainActor [weak self] in self?.autoSelectDevice(defaultDeviceUID: defaultUID) }
                }
            }
            .store(in: &cancellables)

        // coreaudiod restart — clear stale list
        AudioDeviceMonitor.shared.serviceRestartedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.outputDevices = []
                self?.selectedDeviceID = nil
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    var selectedDevice: AudioDevice? {
        outputDevices.first { $0.id == selectedDeviceID }
    }

    /// Load the initial device list. Called from `EQTabView.onAppear`.
    func refreshDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = AudioDeviceFactory.getCurrentDevices()
                .filter(\.isOutput)
                .sorted { $0.name < $1.name }
            let defaultUID = AudioDeviceControlService().getDefaultOutputDevice()?.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.outputDevices = devices
                self.autoSelectDevice(defaultDeviceUID: defaultUID)
            }
        }
    }

    // MARK: - Private

    /// Pick the best device to show in the EQ editor.
    /// Prefers the real device behind the running EQ pipeline, then the system
    /// default output, then the first available device.
    private func autoSelectDevice(defaultDeviceUID: String? = nil) {
        guard !outputDevices.isEmpty else { return }

        // EQ running — use its real target device (the virtual device is the system default)
        if EQEngineService.shared.isRunning,
           let targetUID = EQEngineService.shared.targetDeviceUID,
           outputDevices.contains(where: { $0.id == targetUID }) {
            selectedDeviceID = targetUID
            return
        }

        // System default output
        if let uid = defaultDeviceUID, outputDevices.contains(where: { $0.id == uid }) {
            selectedDeviceID = uid
            return
        }

        // First available
        selectedDeviceID = outputDevices.first?.id
    }
}
