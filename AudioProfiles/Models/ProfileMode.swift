import Foundation

enum ProfileMode: String, Codable {
    case `public`
    case `private`

    var displayName: String {
        switch self {
        case .public: return "Speakers"
        case .private: return "Headphones"
        }
    }

    var iconName: String {
        switch self {
        case .public: return "speaker.wave.2"
        case .private: return "headphones"
        }
    }
}
