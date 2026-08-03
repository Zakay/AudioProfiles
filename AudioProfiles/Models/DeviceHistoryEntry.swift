import Foundation

struct DeviceHistoryEntry: Codable {
    let device: AudioDevice
    let lastSeen: Date
    /// Timestamp of the most recent disconnected → connected transition.
    /// Unlike `lastSeen` (refreshed on every device scan), this only advances when the
    /// device actually (re)connects — so manual-override logic can tell a genuinely new
    /// connection apart from an unrelated device event. See `ProfileManager.shouldApplyTrigger`.
    let connectedAt: Date
    let isCurrentlyActive: Bool

    init(device: AudioDevice, lastSeen: Date, connectedAt: Date, isCurrentlyActive: Bool) {
        self.device = device
        self.lastSeen = lastSeen
        self.connectedAt = connectedAt
        self.isCurrentlyActive = isCurrentlyActive
    }

    // Backward-compatible decoding: entries persisted before `connectedAt` existed
    // fall back to `lastSeen` (the best available approximation of connection time).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(AudioDevice.self, forKey: .device)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        connectedAt = try container.decodeIfPresent(Date.self, forKey: .connectedAt) ?? lastSeen
        isCurrentlyActive = try container.decode(Bool.self, forKey: .isCurrentlyActive)
    }
}
