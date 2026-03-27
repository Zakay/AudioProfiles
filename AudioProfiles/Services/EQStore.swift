import Foundation
import Combine

/// Global per-device EQ settings store.
/// Keyed by device UID; profiles read from here — EQ is device-centric, not per-profile.
@MainActor
final class EQStore: ObservableObject {

    static let shared = EQStore()

    @Published private(set) var settings: [String: EQSettings] = [:]
    @Published private(set) var modes: [String: EQMode] = [:]

    private let defaultsKey = "com.audioprofiles.eqsettings.v1"
    private let modesKey = "com.audioprofiles.eqmodes.v1"

    private init() { load() }

    // MARK: - Public API

    /// Returns the stored EQ for a device, or `.flat` if none.
    func settings(for deviceUID: String) -> EQSettings {
        settings[deviceUID] ?? .flat
    }

    /// Returns non-flat EQ settings for a device, or `nil` when flat / absent.
    /// Used by ProfileActivationService to decide whether to engage the pipeline.
    func activeEQ(for deviceUID: String) -> EQSettings? {
        let eq = settings[deviceUID] ?? .flat
        return eq.isFlat ? nil : eq
    }

    /// Persist updated settings for a device.
    func setSettings(_ eq: EQSettings, for deviceUID: String) {
        if eq.isFlat {
            settings.removeValue(forKey: deviceUID)
        } else {
            settings[deviceUID] = eq
        }
        save()
    }

    /// Get the EQ mode for a device (defaults to .custom).
    func mode(for deviceUID: String) -> EQMode {
        modes[deviceUID] ?? .custom
    }

    /// Set the EQ mode for a device.
    func setMode(_ mode: EQMode, for deviceUID: String) {
        modes[deviceUID] = mode
        saveModes()
    }

    /// Returns the effective EQ for a device: base correction + content mode overlay.
    /// This is the single integration point for the two-layer EQ system.
    func effectiveSettings(for deviceUID: String) -> EQSettings {
        let base = settings(for: deviceUID)
        let overlay = SoundModesStore.shared.activeOverlay()
        return EQSettings.combine(base: base, overlay: overlay)
    }

    /// Whether EQ processing is needed for a device (considering sound modes).
    /// Returns true if the device has non-flat correction OR sound modes are active.
    func needsEQ(for deviceUID: String) -> Bool {
        let hasDeviceEQ = activeEQ(for: deviceUID) != nil
        let hasSoundModes = SoundModesStore.shared.isEnabled && !SoundModesStore.shared.activeOverlay().isFlat
        return hasDeviceEQ || hasSoundModes
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: EQSettings].self, from: data) {
            settings = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modesKey),
           let decoded = try? JSONDecoder().decode([String: EQMode].self, from: data) {
            modes = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func saveModes() {
        guard let data = try? JSONEncoder().encode(modes) else { return }
        UserDefaults.standard.set(data, forKey: modesKey)
    }
}
