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

    /// Convert a preset's EQ values to our EQSettings format.
    func toEQSettings(headphone: EQPresetHeadphone, target: String) -> EQSettings? {
        guard let gains = headphone.eq[target], gains.count == 10 else { return nil }
        var settings = EQSettings.flat
        for i in 0..<10 {
            settings.bands[i].gain = gains[i].clamped(to: EQSettings.gainRange)
        }
        // Preset applies band gains only, preamp stays at 0
        settings.preamp = 0
        return settings
    }
}

// MARK: - Float clamping

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
