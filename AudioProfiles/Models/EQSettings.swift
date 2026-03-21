import Foundation

// MARK: - EQ Band

/// A single parametric EQ band
struct EQBand: Codable, Equatable {
    /// Center frequency in Hz (e.g. 32, 64, 125 … 16000)
    let frequency: Float
    /// Gain in dB — range -12 … +12
    var gain: Float
    /// Bandwidth in octaves (used for parametric filter)
    var bandwidth: Float

    /// True when this band has no audible effect
    var isFlat: Bool { abs(gain) < 0.01 }

    static func at(_ frequency: Float) -> EQBand {
        EQBand(frequency: frequency, gain: 0, bandwidth: 1.0)
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

    /// All gains at 0 dB
    static var flat: EQSettings {
        EQSettings(
            preamp: 0,
            bands: standardFrequencies.map { EQBand.at($0) }
        )
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

    func withPreamp(_ value: Float) -> EQSettings {
        var copy = self
        copy.preamp = value.clamped(to: EQSettings.preampRange)
        return copy
    }

    func reset() -> EQSettings { .flat }
}

// MARK: - Float clamping helper

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
