import Foundation

/// Content-aware audio modes detected automatically from mic state, Now Playing, or Foundation Models.
/// `.none` is the default fallback when no content is detected — no overlay applied.
/// All other modes have editable overlays that stack on top of device correction EQ.
enum ContentModeType: String, Codable, CaseIterable, Equatable {
    case none
    case music
    case voice
    case movie
    case podcast
    case gaming

    var displayName: String {
        switch self {
        case .none:    return "None"
        case .music:   return "Music"
        case .voice:   return "Voice"
        case .movie:   return "Movie"
        case .podcast: return "Podcast"
        case .gaming:  return "Gaming"
        }
    }

    var iconName: String {
        switch self {
        case .none:    return "waveform"
        case .music:   return "music.note"
        case .voice:   return "mic.fill"
        case .movie:   return "film"
        case .podcast: return "headphones"
        case .gaming:  return "gamecontroller.fill"
        }
    }

    var description: String {
        switch self {
        case .none:    return "No overlay — device correction only"
        case .music:   return "Optimized for music listening"
        case .voice:   return "Boost speech clarity for calls"
        case .movie:   return "Cinematic feel with dialogue clarity"
        case .podcast: return "Speech presence and clarity"
        case .gaming:  return "Spatial and immersive"
        }
    }
}
