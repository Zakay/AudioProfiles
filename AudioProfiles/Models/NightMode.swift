import Foundation

/// Night mode configuration — reduces bass and compresses dynamic range
/// for quiet listening. Stacks on top of content mode overlays.
struct NightModeConfig: Codable, Equatable {
    /// Whether night mode is enabled (auto-activates during quiet hours when on)
    var isEnabled: Bool = false
    /// Quiet hours start (24h format)
    var startHour: Int = 22
    var startMinute: Int = 0
    /// Quiet hours end (24h format)
    var endHour: Int = 7
    var endMinute: Int = 0
    /// EQ overlay for night mode
    var overlay: EQSettings

    /// Default night mode: reduce bass to avoid disturbing, boost mids for clarity at low volume
    static var `default`: NightModeConfig {
        var bands = EQSettings.flat.bands
        bands[0].gain = -4.0   // 32 Hz  — cut deep bass
        bands[1].gain = -3.0   // 64 Hz  — cut bass
        bands[2].gain = -1.5   // 125 Hz — reduce low-mids
        bands[5].gain = +1.0   // 1 kHz  — boost clarity
        bands[6].gain = +1.5   // 2 kHz  — boost clarity
        bands[7].gain = +1.0   // 4 kHz  — boost presence
        return NightModeConfig(overlay: EQSettings(preamp: 0, bands: bands))
    }

    /// Check if current time falls within quiet hours
    func isInQuietHours(now: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute
        let startMinutes = startHour * 60 + self.startMinute
        let endMinutes = endHour * 60 + self.endMinute

        if startMinutes <= endMinutes {
            // Same day range (e.g., 08:00 - 22:00)
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            // Crosses midnight (e.g., 22:00 - 07:00)
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }
    }
}
