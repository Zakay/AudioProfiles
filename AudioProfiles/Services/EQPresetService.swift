import Foundation

/// Loads and searches the bundled headphone EQ preset database.
@MainActor
final class EQPresetService: ObservableObject {

    static let shared = EQPresetService()

    private(set) var headphones: [EQPresetHeadphone] = []
    private(set) var brands: [String] = []
    private var brandIndex: [String: [EQPresetHeadphone]] = [:]

    private init() { load() }

    // MARK: - Loading

    private func load() {
        guard let url = Bundle.main.url(forResource: "headphone_eq_database", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let db = try? JSONDecoder().decode(EQPresetDatabase.self, from: data)
        else {
            AppLogger.error("EQPresetService: failed to load preset database")
            return
        }
        headphones = db.headphones
        brands = Array(Set(headphones.map(\.brand))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        for hp in headphones {
            brandIndex[hp.brand.lowercased(), default: []].append(hp)
        }
        AppLogger.info("EQPresetService: loaded \(headphones.count) headphones, \(brands.count) brands")
    }

    // MARK: - Search

    /// Search headphones by substring (case-insensitive).
    /// Returns up to `limit` results.
    func search(query: String, limit: Int = 30) -> [EQPresetHeadphone] {
        let q = query.lowercased()
        if q.isEmpty { return [] }
        return headphones
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .prefix(limit)
            .map { $0 }
    }

    /// Get headphones matching a brand name (case-insensitive).
    func headphones(forBrand brand: String, limit: Int = 30) -> [EQPresetHeadphone] {
        let key = brand.lowercased()
        return Array((brandIndex[key] ?? []).prefix(limit))
    }

    /// Try to extract a brand from a device name by matching known brands.
    func detectBrand(fromDeviceName name: String) -> String? {
        let lower = name.lowercased()
        // Try exact brand prefix match (longest first to prefer "Audio-Technica" over "Audio")
        for brand in brands.sorted(by: { $0.count > $1.count }) {
            if lower.hasPrefix(brand.lowercased()) {
                return brand
            }
        }
        // Try substring match
        for brand in brands.sorted(by: { $0.count > $1.count }) {
            if brand.count >= 3 && lower.contains(brand.lowercased()) {
                return brand
            }
        }
        return nil
    }

    /// Get prefilled suggestions based on device name (brand match).
    func suggestions(forDeviceName deviceName: String, limit: Int = 30) -> [EQPresetHeadphone] {
        guard let brand = detectBrand(fromDeviceName: deviceName) else { return [] }
        return headphones(forBrand: brand, limit: limit)
    }

    /// Look up a specific headphone by name.
    func headphone(named name: String) -> EQPresetHeadphone? {
        headphones.first { $0.name == name }
    }

    /// Convert a preset to EQSettings. Prefers PEQ data (per-filter Q/type/freq) over basic 10-band.
    func toEQSettings(headphone: EQPresetHeadphone, target: String) -> EQSettings? {
        // Prefer PEQ data when available — it has per-filter Q, type, and exact frequency
        if let peq = headphone.peq?[target] {
            return peqToSettings(peq)
        }
        // Fall back to basic 10-band gains
        guard let gains = headphone.eq[target], gains.count == 10 else { return nil }
        let frequencies = headphone.eqBandsHz ?? EQSettings.standardFrequencies
        var settings = EQSettings.flat
        for i in 0..<10 {
            settings.bands[i].gain = gains[i].clamped(to: EQSettings.gainRange)
            if i < frequencies.count {
                settings.bands[i].frequency = frequencies[i]
            }
        }
        settings.preamp = 0
        return settings
    }

    /// Convert PEQ data to 10-band EQSettings with proper Q→bandwidth, filter types, frequencies
    private func peqToSettings(_ peq: EQPresetPEQ) -> EQSettings {
        let parsed = peq.parsedFilters  // already sorted by frequency
        var settings = EQSettings.flat
        settings.preamp = peq.preamp.clamped(to: EQSettings.preampRange)

        if parsed.isEmpty { return settings }

        if parsed.count <= 10 {
            // Map each PEQ filter to the nearest default band position
            var assigned = Set<Int>()
            for filter in parsed {
                // Find the closest unassigned band by frequency (log distance)
                let bestIdx = (0..<10)
                    .filter { !assigned.contains($0) }
                    .min { a, b in
                        abs(log2(settings.bands[a].frequency / filter.frequency)) <
                        abs(log2(settings.bands[b].frequency / filter.frequency))
                    }
                guard let idx = bestIdx else { continue }
                assigned.insert(idx)
                settings.bands[idx].frequency = filter.frequency
                settings.bands[idx].gain = filter.gain.clamped(to: EQSettings.gainRange)
                settings.bands[idx].bandwidth = EQBand.qToBandwidth(filter.q)
                settings.bands[idx].filterType = filter.type
            }
        } else {
            // More than 10 filters — keep shelves + highest-gain peaks
            var shelves: [EQPresetPEQ.ParsedFilter] = []
            var peaks: [EQPresetPEQ.ParsedFilter] = []
            for f in parsed {
                if f.type == .lowShelf || f.type == .highShelf { shelves.append(f) }
                else { peaks.append(f) }
            }
            // Keep best LS and HS (highest absolute gain)
            let bestLS = shelves.filter { $0.type == .lowShelf }.max { abs($0.gain) < abs($1.gain) }
            let bestHS = shelves.filter { $0.type == .highShelf }.max { abs($0.gain) < abs($1.gain) }
            var kept: [EQPresetPEQ.ParsedFilter] = []
            if let ls = bestLS { kept.append(ls) }
            if let hs = bestHS { kept.append(hs) }
            // Fill remaining slots with highest-impact peaks
            let slotsForPeaks = 10 - kept.count
            let topPeaks = peaks.sorted { abs($0.gain) > abs($1.gain) }.prefix(slotsForPeaks)
            kept.append(contentsOf: topPeaks)
            kept.sort { $0.frequency < $1.frequency }

            for (i, filter) in kept.prefix(10).enumerated() {
                settings.bands[i].frequency = filter.frequency
                settings.bands[i].gain = filter.gain.clamped(to: EQSettings.gainRange)
                settings.bands[i].bandwidth = EQBand.qToBandwidth(filter.q)
                settings.bands[i].filterType = filter.type
            }
        }
        return settings
    }
}

// MARK: - Float clamping

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
