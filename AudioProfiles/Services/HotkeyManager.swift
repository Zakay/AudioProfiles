import Carbon

class HotkeyManager {
    static let shared = HotkeyManager()
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var handlers: [UInt32: ()->Void] = [:]

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let handler = HotkeyManager.shared.handlers[hkID.id] {
                handler()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(hotkey: Hotkey, handler: @escaping ()->Void) {
        var ref: EventHotKeyRef?
        let id = UInt32(hotkeyRefs.count + 1)
        let hkID = EventHotKeyID(signature: OSType(fourCharCode: "HTKY"), id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hkID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &ref
        )
        if status == noErr, let r = ref {
            hotkeyRefs.append(r)
            handlers[id] = handler
        }
    }

    func unregisterAll() {
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        hotkeyRefs.removeAll()
        handlers.removeAll()
    }
}

// Helper to create OSType from string
extension OSType {
    init(fourCharCode: String) {
        self = fourCharCode.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
