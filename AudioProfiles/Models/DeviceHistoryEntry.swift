import Foundation

struct DeviceHistoryEntry: Codable {
    let device: AudioDevice
    let lastSeen: Date
    let isCurrentlyActive: Bool
} 