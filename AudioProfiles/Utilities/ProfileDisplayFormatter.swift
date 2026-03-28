import Foundation

/// Utility for formatting Profile data for display purposes
@MainActor
class ProfileDisplayFormatter {

    private let deviceHistoryService: AudioDeviceHistoryService

    init(deviceHistoryService: AudioDeviceHistoryService = AudioDeviceHistoryService.shared) {
        self.deviceHistoryService = deviceHistoryService
    }

    /// Get summary of trigger rules for display
    func triggerDevicesDisplay(for profile: Profile) -> String {
        if profile.triggerRules.isEmpty {
            return "No Triggers"
        }

        var parts: [String] = []

        for rule in profile.triggerRules {
            switch rule {
            case .specificDevice(let id):
                if !id.isEmpty, let device = deviceHistoryService.getDevice(by: id) {
                    parts.append(device.name)
                }
            case .transportType(let type):
                parts.append("Any \(type)")
            }
        }

        if parts.isEmpty {
            return "No Valid Triggers"
        }

        if parts.count == 1 {
            return parts[0]
        } else {
            return "\(parts.count) Triggers"
        }
    }
}
