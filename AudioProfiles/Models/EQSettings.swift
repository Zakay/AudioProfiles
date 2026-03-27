import Foundation

// MARK: - EQ Filter Type

/// Filter shape for an EQ band — maps to kAUNBandEQFilterType constants
enum EQFilterType: Int, Codable, Equatable, CaseIterable {
    case parametric = 0   // Bell/peak
    case lowShelf   = 7
    case highShelf  = 8

    var label: String {
        switch self {
        case .parametric: return "PK"
        case .lowShelf:   return "LS"
        case .highShelf:  return "HS"
        }
    }
}

// MARK: - EQ Band

/// A single parametric EQ band
struct EQBand: Codable, Equatable {
    /// Center frequency in Hz (e.g. 32, 64, 125 … 16000)
    /// Draggable horizontally in the graph — defaults to standard positions.
    var frequency: Float
    /// Gain in dB — range -12 … +12
    var gain: Float
    /// Bandwidth in octaves (used for parametric filter)
    var bandwidth: Float
    /// Filter type — parametric (bell), low shelf, or high shelf
    var filterType: EQFilterType

    /// True when this band has no audible effect
    var isFlat: Bool { abs(gain) < 0.01 }

    static func at(_ frequency: Float) -> EQBand {
        EQBand(frequency: frequency, gain: 0, bandwidth: 1.0, filterType: .parametric)
    }

    /// Convert Q factor to bandwidth in octaves: BW = (2/ln2) * asinh(1/(2Q))
    static func qToBandwidth(_ q: Float) -> Float {
        guard q > 0 else { return 1.0 }
        let bw = Float((2.0 / log(2.0)) * asinh(1.0 / (2.0 * Double(q))))
        return bw.clamped(to: EQSettings.bandwidthRange)
    }
}

// MARK: - EQ Settings

/// Full EQ configuration for one output device.
/// Stored globally via EQStore, keyed by device UID.
struct EQSettings: Codable, Equatable {

    // MARK: Constants

    /// The ten standard frequencies for the 10-band EQ
    static let standardFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    static let gainRange: ClosedRange<Float>      = -12 ... 12
    static let preampRange: ClosedRange<Float>    = -12 ... 12
    static let bandwidthRange: ClosedRange<Float> = 0.1 ... 5.0

    // MARK: Properties

    /// Master gain applied before all bands (dB)
    var preamp: Float
    /// 10 bands at standard frequencies
    var bands: [EQBand]

    // MARK: Derived

    /// True when all gains are at 0 dB — no processing needed
    var isFlat: Bool {
        abs(preamp) < 0.01 && bands.allSatisfy(\.isFlat)
    }

    // MARK: Factory

    /// All gains at 0 dB with standard filter types (low shelf, 8x parametric, high shelf)
    static var flat: EQSettings {
        var bands = standardFrequencies.map { EQBand.at($0) }
        bands[0].filterType = .lowShelf
        bands[9].filterType = .highShelf
        return EQSettings(preamp: 0, bands: bands)
    }

    // MARK: Helpers

    /// Return a copy with the given band's gain updated
    func withBand(at index: Int, gain: Float) -> EQSettings {
        guard index >= 0 && index < bands.count else { return self }
        var copy = self
        copy.bands[index].gain = gain.clamped(to: EQSettings.gainRange)
        return copy
    }

    /// Return a copy with the given band's bandwidth updated
    func withBand(at index: Int, bandwidth: Float) -> EQSettings {
        guard index >= 0 && index < bands.count else { return self }
        var copy = self
        copy.bands[index].bandwidth = bandwidth.clamped(to: EQSettings.bandwidthRange)
        return copy
    }

    /// Frequency range for bands
    static let frequencyRange: ClosedRange<Float> = 20 ... 20_000

    /// Return a copy with the given band's frequency updated, clamped between neighbors
    func withBand(at index: Int, frequency: Float) -> EQSettings {
        guard index >= 0 && index < bands.count else { return self }
        let minFreq: Float = index > 0 ? bands[index - 1].frequency * 1.05 : EQSettings.frequencyRange.lowerBound
        let maxFreq: Float = index < bands.count - 1 ? bands[index + 1].frequency * 0.95 : EQSettings.frequencyRange.upperBound
        var copy = self
        copy.bands[index].frequency = frequency.clamped(to: minFreq ... maxFreq)
        return copy
    }

    func withPreamp(_ value: Float) -> EQSettings {
        var copy = self
        copy.preamp = value.clamped(to: EQSettings.preampRange)
        return copy
    }

    func reset() -> EQSettings { .flat }
}

// MARK: - Float clamping helper

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
