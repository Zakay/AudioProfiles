import Foundation

/// A trigger rule can match either a specific device or a device transport class.
enum TriggerRule: Codable, Equatable, Hashable {
    case specificDevice(id: String)
    case transportType(type: String)  // "Bluetooth", "USB", "Built-In", "Other", etc.

    var displayName: String {
        switch self {
        case .specificDevice(let id): return id  // caller resolves to device name
        case .transportType(let type): return "Any \(type)"
        }
    }

    /// Derive legacy triggerDeviceIDs from a list of trigger rules (only specificDevice entries)
    static func deriveDeviceIDs(from rules: [TriggerRule]) -> [String] {
        rules.compactMap {
            if case .specificDevice(let id) = $0 { return id }
            return nil
        }
    }
}

struct Profile: Codable, Identifiable {
    let id: UUID
    var name: String
    var iconName: String
    var triggerDeviceIDs: [String]
    var triggerRules: [TriggerRule]
    var publicOutputPriority: [String]
    var publicInputPriority: [String]
    var privateOutputPriority: [String]
    var privateInputPriority: [String]
    /// Legacy field kept for Codable backward compatibility — not used at runtime.
    var hotkey: Hotkey?
    var preferredMode: ProfileMode
    var isSystemDefault: Bool

    // Custom initializer to provide default preferredMode for backward compatibility
    init(id: UUID, name: String, iconName: String, triggerDeviceIDs: [String],
         triggerRules: [TriggerRule]? = nil,
         publicOutputPriority: [String], publicInputPriority: [String],
         privateOutputPriority: [String], privateInputPriority: [String],
         hotkey: Hotkey? = nil, preferredMode: ProfileMode = .public,
         isSystemDefault: Bool = false) {
        self.id = id
        self.name = name
        self.iconName = iconName
        // If triggerRules provided, use them; otherwise migrate from triggerDeviceIDs
        self.triggerRules = triggerRules ?? triggerDeviceIDs.map { .specificDevice(id: $0) }
        // Always derive triggerDeviceIDs from triggerRules for backward compat
        self.triggerDeviceIDs = TriggerRule.deriveDeviceIDs(from: self.triggerRules)
        self.publicOutputPriority = publicOutputPriority
        self.publicInputPriority = publicInputPriority
        self.privateOutputPriority = privateOutputPriority
        self.privateInputPriority = privateInputPriority
        self.hotkey = nil  // Hotkey feature removed — always nil
        self.preferredMode = preferredMode
        self.isSystemDefault = isSystemDefault
    }

    // Custom decoding to handle legacy profiles without triggerRules or preferredMode
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconName = try container.decode(String.self, forKey: .iconName)

        // Try to decode triggerRules first; fall back to migrating from triggerDeviceIDs
        if let rules = try container.decodeIfPresent([TriggerRule].self, forKey: .triggerRules) {
            triggerRules = rules
            triggerDeviceIDs = TriggerRule.deriveDeviceIDs(from: rules)
        } else {
            let legacyIDs = try container.decode([String].self, forKey: .triggerDeviceIDs)
            triggerRules = legacyIDs.map { .specificDevice(id: $0) }
            triggerDeviceIDs = legacyIDs
        }

        publicOutputPriority = try container.decode([String].self, forKey: .publicOutputPriority)
        publicInputPriority = try container.decode([String].self, forKey: .publicInputPriority)
        privateOutputPriority = try container.decode([String].self, forKey: .privateOutputPriority)
        privateInputPriority = try container.decode([String].self, forKey: .privateInputPriority)
        // Legacy hotkey field — decode to avoid errors on old data, but discard
        _ = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        hotkey = nil
        preferredMode = try container.decodeIfPresent(ProfileMode.self, forKey: .preferredMode) ?? .public
        isSystemDefault = try container.decodeIfPresent(Bool.self, forKey: .isSystemDefault) ?? (name == "System Default")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(iconName, forKey: .iconName)
        try container.encode(triggerRules, forKey: .triggerRules)
        // Also encode triggerDeviceIDs for backward compatibility with older app versions
        try container.encode(TriggerRule.deriveDeviceIDs(from: triggerRules), forKey: .triggerDeviceIDs)
        try container.encode(publicOutputPriority, forKey: .publicOutputPriority)
        try container.encode(publicInputPriority, forKey: .publicInputPriority)
        try container.encode(privateOutputPriority, forKey: .privateOutputPriority)
        try container.encode(privateInputPriority, forKey: .privateInputPriority)
        // hotkey field no longer written — feature removed
        try container.encode(preferredMode, forKey: .preferredMode)
        try container.encode(isSystemDefault, forKey: .isSystemDefault)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconName, triggerDeviceIDs, triggerRules
        case publicOutputPriority, publicInputPriority
        case privateOutputPriority, privateInputPriority
        case hotkey  // kept for legacy decode only
        case preferredMode, isSystemDefault
    }

    /// Single accessor for the device priority list given a direction and mode.
    /// All code that needs "which priority list?" should go through this.
    func priorityList(isOutput: Bool, mode: ProfileMode) -> [String] {
        switch (isOutput, mode) {
        case (true,  .public):  return publicOutputPriority
        case (true,  .private): return privateOutputPriority
        case (false, .public):  return publicInputPriority
        case (false, .private): return privateInputPriority
        }
    }
}
