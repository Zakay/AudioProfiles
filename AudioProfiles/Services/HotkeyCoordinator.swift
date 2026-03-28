import Foundation

/// Stub — hotkey feature has been removed.
@MainActor
class HotkeyCoordinator {
    static let shared = HotkeyCoordinator()
    func setupHotkeys() {}
    func refreshHotkeys() {}
    func registerHotkey(for profile: Profile) {}
    func handleHotkeyChanges(oldHotkey: Hotkey?, newHotkey: Hotkey?) {}
}
