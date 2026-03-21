import Foundation

/// Utility for formatting Profile data for display purposes
class ProfileDisplayFormatter {

    private let deviceHistoryService: AudioDeviceHistoryService

    init(deviceHistoryService: AudioDeviceHistoryService = AudioDeviceHistoryService.shared) {
        self.deviceHistoryService = deviceHistoryService
    }

    /// Get summary of trigger devices for display
    func triggerDevicesDisplay(for profile: Profile) -> String {
        if profile.triggerDeviceIDs.isEmpty {
            return "No Triggers"
        }

        let validTriggerNames: [String] = profile.triggerDeviceIDs.compactMap { deviceId in
            guard !deviceId.isEmpty,
                  let device = deviceHistoryService.getDevice(by: deviceId) else { return nil }
            return device.name
        }

        if validTriggerNames.isEmpty {
            return "No Valid Triggers"
        }

        if validTriggerNames.count == 1 {
            return validTriggerNames[0]
        } else {
            return "\(validTriggerNames.count) Triggers"
        }
    }
}
