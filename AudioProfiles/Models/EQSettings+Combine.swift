import Foundation

extension EQSettings {

    /// Combine a device correction (base) with a content mode overlay.
    /// Gains are additive per-band, clamped to the valid range.
    /// Bandwidth and filter type come from the base (device correction).
    /// Preamps are summed and clamped.
    static func combine(base: EQSettings, overlay: EQSettings) -> EQSettings {
        guard !overlay.isFlat else { return base }
        guard !base.isFlat else {
            // No device correction — overlay IS the final result
            // but keep the base's filter types (low shelf / high shelf at edges)
            var result = overlay
            for i in 0..<min(result.bands.count, base.bands.count) {
                result.bands[i].filterType = base.bands[i].filterType
                result.bands[i].bandwidth = base.bands[i].bandwidth
                result.bands[i].frequency = base.bands[i].frequency
            }
            return result
        }

        var combined = base
        combined.preamp = (base.preamp + overlay.preamp).clamped(to: EQSettings.preampRange)

        let count = min(base.bands.count, overlay.bands.count)
        for i in 0..<count {
            combined.bands[i].gain = (base.bands[i].gain + overlay.bands[i].gain)
                .clamped(to: EQSettings.gainRange)
            // Frequency, bandwidth, filterType stay from base
        }

        return combined
    }
}