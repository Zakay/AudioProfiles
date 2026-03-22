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

/// PEQ preset: preamp + array of filters with per-filter type, freq, gain, Q
struct EQPresetPEQ: Codable {
    let preamp: Float
    let filters: [[PEQFilterValue]]

    /// Each filter is [type, freq, gain, Q] encoded as mixed-type JSON array
    enum PEQFilterValue: Codable {
        case string(String)
        case number(Float)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { self = .string(s) }
            else if let n = try? container.decode(Float.self) { self = .number(n) }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string or number") }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .number(let n): try container.encode(n)
            }
        }

        var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
        var floatValue: Float? { if case .number(let n) = self { return n } else { return nil } }
    }

    /// Parse a raw filter array into a typed struct
    struct ParsedFilter {
        let type: EQFilterType
        let frequency: Float
        let gain: Float
        let q: Float
    }

    /// Parse all filters into typed structs, sorted by frequency
    var parsedFilters: [ParsedFilter] {
        filters.compactMap { values -> ParsedFilter? in
            guard values.count >= 4,
                  let typeStr = values[0].stringValue,
                  let freq = values[1].floatValue,
                  let gain = values[2].floatValue,
                  let q = values[3].floatValue else { return nil }
            let filterType: EQFilterType
            switch typeStr {
            case "LS": filterType = .lowShelf
            case "HS": filterType = .highShelf
            default:   filterType = .parametric
            }
            return ParsedFilter(type: filterType, frequency: freq, gain: gain, q: q)
        }.sorted { $0.frequency < $1.frequency }
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
    let eqBandsHz: [Float]?
    let eq: [String: [Float]]
    let peq: [String: EQPresetPEQ]?

    var id: String { name }

    /// Available target curve names — includes PEQ-only targets
    var targets: [String] {
        var names = Set(eq.keys)
        if let peq = peq { names.formUnion(peq.keys) }
        return names.sorted()
    }

    /// Whether a given target has PEQ data (preferred over basic EQ)
    func hasPEQ(for target: String) -> Bool {
        peq?[target] != nil
    }

    /// Frequency response data points (Hz, dB) for graph overlay
    var frequencyResponse: [(hz: Float, db: Float)]? {
        guard let hz = frHz, let db = frDb, hz.count == db.count else { return nil }
        return zip(hz, db).map { (hz: $0, db: $1) }
    }

    enum CodingKeys: String, CodingKey {
        case name, brand, model, category, source, eq, peq
        case frHz = "fr_hz"
        case frDb = "fr_db"
        case eqBandsHz = "eq_bands_hz"
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
