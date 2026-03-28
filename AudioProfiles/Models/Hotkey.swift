import Foundation

/// Minimal stub kept for backward-compatible Codable decoding of legacy profiles.
/// The hotkey feature has been removed — this struct is never used at runtime.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}
