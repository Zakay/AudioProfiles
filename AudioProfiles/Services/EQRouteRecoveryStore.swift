import Foundation

/// Persists the physical endpoint represented by the virtual driver. The value
/// survives an app crash and lets startup restore volume/mute to the correct
/// hardware instead of guessing from the current Core Audio default.
enum EQRouteRecoveryStore {
    private static let representedDeviceKey = "com.audioprofiles.eq.representedDeviceUID"

    static var representedDeviceUID: String? {
        UserDefaults.standard.string(forKey: representedDeviceKey)
    }

    static func save(_ uid: String) {
        UserDefaults.standard.set(uid, forKey: representedDeviceKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: representedDeviceKey)
    }
}
