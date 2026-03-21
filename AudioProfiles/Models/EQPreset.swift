import Foundation

// MARK: - Database JSON structure

struct EQPresetDatabase: Codable {
    let metadata: EQPresetMetadata
    let headphones: [EQPresetHeadphone]
}

struct EQPresetMetadata: Codable {
    let totalHeadphones: Int
    let frHz: [Float]
    let eqBandsHz: [Float]
    let targets: [String]

    enum CodingKeys: String, CodingKey {
        case totalHeadphones = "total_headphones"
        case frHz = "fr_hz"
        case eqBandsHz = "eq_bands_hz"
        case targets
    }
}

struct EQPresetHeadphone: Codable, Identifiable {
    let name: String
    let brand: String
    let model: String
    let category: String
    let source: String
    let frHz: [Float]?
    let frDb: [Float]?
    let eq: [String: [Float]]

    var id: String { name }

    /// Available target curve names for this headphone
    var targets: [String] { Array(eq.keys).sorted() }

    /// Frequency response data points (Hz, dB) for graph overlay
    var frequencyResponse: [(hz: Float, db: Float)]? {
        guard let hz = frHz, let db = frDb, hz.count == db.count else { return nil }
        return zip(hz, db).map { (hz: $0, db: $1) }
    }

    enum CodingKeys: String, CodingKey {
        case name, brand, model, category, source, eq
        case frHz = "fr_hz"
        case frDb = "fr_db"
    }
}

// MARK: - EQ Mode (Custom vs Preset)

enum EQMode: Codable, Equatable {
    case custom
    case preset(headphoneName: String, target: String)

    var isPreset: Bool {
        if case .preset = self { return true }
        return false
    }

    var presetHeadphoneName: String? {
        if case .preset(let name, _) = self { return name }
        return nil
    }

    var presetTarget: String? {
        if case .preset(_, let target) = self { return target }
        return nil
    }
}
