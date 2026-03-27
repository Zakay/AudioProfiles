import Foundation
import Combine

/// Persistence and state for Sound Modes feature.
/// Stores content mode overlays, night mode config, and tracks the active mode.
/// Master toggle controls whether the feature is active at all.
@MainActor
final class SoundModesStore: ObservableObject {

    static let shared = SoundModesStore()

    // MARK: - Published State

    /// Master toggle — when false, the entire feature is dormant
    @Published var isEnabled: Bool = false {
        didSet { saveBool(isEnabled, forKey: enabledKey) }
    }

    /// Per-mode overlay settings (device-independent)
    @Published var overlays: [ContentModeType: ContentModeOverlay] = [:] {
        didSet { saveOverlays() }
    }

    /// Night mode schedule and overlay
    @Published var nightMode: NightModeConfig = .default {
        didSet { saveNightMode() }
    }

    /// User-pinned mode override (nil = auto-detection)
    @Published var manualOverride: ContentModeType? = nil {
        didSet { saveOverride() }
    }

    /// Currently active content mode (set by detection service or manual override)
    @Published private(set) var activeContentMode: ContentModeType = .none

    /// Bundle ID or display name of the detected source app
    @Published private(set) var activeSourceApp: String?

    /// Whether night mode is currently active (set by NightModeScheduler)
    @Published private(set) var isNightModeActive: Bool = false

    // MARK: - UserDefaults Keys

    private let enabledKey  = "com.audioprofiles.soundmodes.enabled.v1"
    private let overlaysKey = "com.audioprofiles.soundmodes.overlays.v1"
    private let nightKey    = "com.audioprofiles.soundmodes.nightmode.v1"
    private let overrideKey = "com.audioprofiles.soundmodes.override.v1"

    // MARK: - Init

    private init() { load() }

    // MARK: - Public API

    /// Called by detection service to update the active mode
    func setActiveMode(_ mode: ContentModeType, sourceApp: String?) {
        activeContentMode = mode
        activeSourceApp = sourceApp
    }

    /// Called by NightModeScheduler
    func setNightModeActive(_ active: Bool) {
        isNightModeActive = active
    }

    /// Get the overlay EQ for a specific content mode
    func overlay(for mode: ContentModeType) -> EQSettings {
        let overlay = overlays[mode] ?? ContentModeOverlay.defaultOverlay(for: mode)
        return overlay.isEnabled ? overlay.settings : .flat
    }

    /// Get the currently active composite Layer 2 overlay (content + night if applicable)
    func activeOverlay() -> EQSettings {
        guard isEnabled else { return .flat }

        let contentOverlay = overlay(for: activeContentMode)

        if isNightModeActive {
            return EQSettings.combine(base: contentOverlay, overlay: nightMode.overlay)
        }

        return contentOverlay
    }

    // MARK: - Persistence

    private func load() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)

        if let data = UserDefaults.standard.data(forKey: overlaysKey),
           let decoded = try? JSONDecoder().decode([ContentModeType: ContentModeOverlay].self, from: data) {
            overlays = decoded
        } else {
            // Seed with defaults on first run
            seedDefaults()
        }

        if let data = UserDefaults.standard.data(forKey: nightKey),
           let decoded = try? JSONDecoder().decode(NightModeConfig.self, from: data) {
            nightMode = decoded
        }

        if let raw = UserDefaults.standard.string(forKey: overrideKey),
           let mode = ContentModeType(rawValue: raw) {
            manualOverride = mode
        }
    }

    private func seedDefaults() {
        for mode in ContentModeType.allCases {
            overlays[mode] = ContentModeOverlay.defaultOverlay(for: mode)
        }
    }

    private func saveOverlays() {
        guard let data = try? JSONEncoder().encode(overlays) else { return }
        UserDefaults.standard.set(data, forKey: overlaysKey)
    }

    private func saveNightMode() {
        guard let data = try? JSONEncoder().encode(nightMode) else { return }
        UserDefaults.standard.set(data, forKey: nightKey)
    }

    private func saveOverride() {
        if let mode = manualOverride {
            UserDefaults.standard.set(mode.rawValue, forKey: overrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKey)
        }
    }

    private func saveBool(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
