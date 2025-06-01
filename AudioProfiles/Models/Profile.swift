import Foundation

struct Profile: Codable, Identifiable {
    let id: UUID
    var name: String
    var iconName: String
    var triggerDeviceIDs: [String]
    var publicOutputPriority: [String]
    var publicInputPriority: [String]
    var privateOutputPriority: [String]
    var privateInputPriority: [String]
    var hotkey: Hotkey?
    var preferredMode: ProfileMode
    
    // Custom initializer to provide default preferredMode for backward compatibility
    init(id: UUID, name: String, iconName: String, triggerDeviceIDs: [String], 
         publicOutputPriority: [String], publicInputPriority: [String],
         privateOutputPriority: [String], privateInputPriority: [String], 
         hotkey: Hotkey?, preferredMode: ProfileMode = .public) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.triggerDeviceIDs = triggerDeviceIDs
        self.publicOutputPriority = publicOutputPriority
        self.publicInputPriority = publicInputPriority
        self.privateOutputPriority = privateOutputPriority
        self.privateInputPriority = privateInputPriority
        self.hotkey = hotkey
        self.preferredMode = preferredMode
    }
    
    // Custom decoding to handle legacy profiles without preferredMode
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconName = try container.decode(String.self, forKey: .iconName)
        triggerDeviceIDs = try container.decode([String].self, forKey: .triggerDeviceIDs)
        publicOutputPriority = try container.decode([String].self, forKey: .publicOutputPriority)
        publicInputPriority = try container.decode([String].self, forKey: .publicInputPriority)
        privateOutputPriority = try container.decode([String].self, forKey: .privateOutputPriority)
        privateInputPriority = try container.decode([String].self, forKey: .privateInputPriority)
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        preferredMode = try container.decodeIfPresent(ProfileMode.self, forKey: .preferredMode) ?? .public
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, iconName, triggerDeviceIDs
        case publicOutputPriority, publicInputPriority
        case privateOutputPriority, privateInputPriority
        case hotkey, preferredMode
    }
    
    /// Check if this is the system default profile
    var isSystemDefault: Bool {
        return name == "System Default"
    }
}
