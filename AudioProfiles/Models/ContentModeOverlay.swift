import Foundation

/// EQ overlay settings for a content mode.
/// Device-independent — the same Voice overlay applies on any output device.
struct ContentModeOverlay: Codable, Equatable {
    var mode: ContentModeType
    var settings: EQSettings
    var isEnabled: Bool

    // MARK: - Default overlays

    /// Voice: boost speech presence (2-4kHz), cut low rumble
    static func defaultVoice() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = -2.0   // 32 Hz  — cut room rumble
        bands[1].gain = -1.5   // 64 Hz  — cut room rumble
        bands[2].gain = -1.0   // 125 Hz — reduce muddiness
        bands[6].gain = +2.5   // 2 kHz  — speech clarity
        bands[7].gain = +2.0   // 4 kHz  — speech presence
        bands[8].gain = +1.0   // 8 kHz  — air/sibilance
        return ContentModeOverlay(mode: .voice, settings: EQSettings(preamp: 0, bands: bands), isEnabled: true)
    }

    /// Movie: cinematic bass + dialogue clarity
    static func defaultMovie() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = +2.0   // 32 Hz  — sub bass rumble
        bands[1].gain = +1.5   // 64 Hz  — low-end warmth
        bands[6].gain = +1.5   // 2 kHz  — dialogue clarity
        bands[7].gain = +1.0   // 4 kHz  — dialogue presence
        return ContentModeOverlay(mode: .movie, settings: EQSettings(preamp: -1.0, bands: bands), isEnabled: true)
    }

    /// Podcast: speech clarity, less aggressive than voice
    static func defaultPodcast() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = -1.5   // 32 Hz  — cut rumble
        bands[1].gain = -1.0   // 64 Hz  — reduce bass
        bands[5].gain = +1.0   // 1 kHz  — warmth
        bands[6].gain = +2.0   // 2 kHz  — clarity
        bands[7].gain = +1.5   // 4 kHz  — presence
        return ContentModeOverlay(mode: .podcast, settings: EQSettings(preamp: 0, bands: bands), isEnabled: true)
    }

    /// Gaming: spatial/immersive feel
    static func defaultGaming() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = +1.5   // 32 Hz  — sub bass impact
        bands[1].gain = +1.0   // 64 Hz  — explosions
        bands[5].gain = -0.5   // 1 kHz  — slight scoop for width
        bands[7].gain = +1.5   // 4 kHz  — footsteps/detail
        bands[8].gain = +1.0   // 8 kHz  — spatial cues
        return ContentModeOverlay(mode: .gaming, settings: EQSettings(preamp: -0.5, bands: bands), isEnabled: true)
    }

    /// Music: no overlay (passthrough)
    static func defaultMusic() -> ContentModeOverlay {
        ContentModeOverlay(mode: .music, settings: .flat, isEnabled: true)
    }

    /// None: passthrough — no overlay at all
    static func defaultNone() -> ContentModeOverlay {
        ContentModeOverlay(mode: .none, settings: .flat, isEnabled: true)
    }

    /// Returns the default overlay for a given mode
    static func defaultOverlay(for mode: ContentModeType) -> ContentModeOverlay {
        switch mode {
        case .none:    return defaultNone()
        case .music:   return defaultMusic()
        case .voice:   return defaultVoice()
        case .movie:   return defaultMovie()
        case .podcast: return defaultPodcast()
        case .gaming:  return defaultGaming()
        }
    }
}
