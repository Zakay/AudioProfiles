import Foundation
import Combine

/// Global per-device EQ settings store.
/// Keyed by device UID; profiles read from here — EQ is device-centric, not per-profile.
@MainActor
final class EQStore: ObservableObject {

    static let shared = EQStore()

    @Published private(set) var settings: [String: EQSettings] = [:]

    private let defaultsKey = "com.audioprofiles.eqsettings.v1"

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

    // MARK: - Persistence

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([String: EQSettings].self, from: data)
        else { return }
        settings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
