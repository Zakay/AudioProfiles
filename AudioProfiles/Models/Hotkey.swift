import Foundation
import Carbon

struct Hotkey: Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Human-readable description of the hotkey
    var description: String {
        var parts: [String] = []
        
        // Add modifier symbols
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        
        // Add key character
        let char = Self.character(for: keyCode)
        parts.append(char)
        
        return parts.joined()
    }
    
    /// Check if this hotkey conflicts with another hotkey
    func conflicts(with other: Hotkey) -> Bool {
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
    
    /// Check if this hotkey is valid (has at least one modifier and a key)
    var isValid: Bool {
        return modifiers != 0 && keyCode != 0
    }
    
    /// Get individual modifier key symbols for visual display
    var modifierKeys: [String] {
        var keys: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        if modifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if modifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        return keys
    }
    
    /// Get the main key character for visual display
    var mainKey: String {
        return Self.character(for: keyCode)
    }
    
    // MARK: - Private Implementation
    
    /// Get character representation for a key code
    private static func character(for keyCode: UInt32) -> String {
        // First check if it's a special key that needs symbols
        if let specialChar = specialKeyMappings[keyCode] {
            return specialChar
        }
        
        // For regular keys, use the actual character from keyboard layout
        return actualCharacter(for: keyCode) ?? "Key\(keyCode)"
    }
    
    /// Get the actual character for a key code using macOS keyboard layout services
    private static func actualCharacter(for keyCode: UInt32) -> String? {
        let inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        
        let error = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0, // No modifiers for the base character
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        
        guard error == noErr && length > 0 else {
            return nil
        }
        
        let string = String(utf16CodeUnits: chars, count: length)
        return string.uppercased() // Display in uppercase for consistency
    }
    
    /// Map only keys that need special symbols or are ambiguous
    private static let specialKeyMappings: [UInt32: String] = [
        // Special action keys
        36: "↩︎",     // Return
        48: "⇥",     // Tab  
        49: "Space", // Space
        51: "⌫",     // Delete
        53: "⎋",     // Escape
        117: "⌦",    // Forward Delete
        
        // Navigation keys
        121: "⇞",    // Page Up
        116: "⇟",    // Page Down
        115: "↖︎",    // Home
        119: "↘︎",    // End
        123: "←",    // Left Arrow
        124: "→",    // Right Arrow
        125: "↓",    // Down Arrow
        126: "↑",    // Up Arrow
        
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20"
    ]
} 