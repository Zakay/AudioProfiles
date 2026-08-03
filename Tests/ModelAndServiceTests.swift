#!/usr/bin/env swift
//
// ModelAndServiceTests.swift
//
// Comprehensive unit tests for all models and pure-logic services.
// Covers everything NOT tested by PipelineTests.swift and SharedAudioTests.swift:
//
//   1. NightModeConfig — quiet hours logic, midnight crossing, edge cases
//   2. ContentModeType — enum properties, allCases
//   3. ContentModeOverlay — default factory methods, enabled/disabled states
//   4. (Removed — Hotkey feature removed)
//   5. EQSettings — band mutation helpers, preamp, reset, frequency clamping
//   6. EQPresetPEQ — filter parsing, type mapping, sort order
//   7. Profile — Codable round-trip, legacy decode, isSystemDefault, priorityList
//   8. AudioDevice — Codable round-trip, identity
//   9. DeviceHistoryEntry — structure, date tracking
//  10. DeviceFilterService logic — type filtering, exclusion, availability
//  11. ProfileValidationService logic — cleanup, equality check, periodic cleanup
//  12. AudioDeviceHistoryService logic — update, prune, previously-seen
//  13. SoundModesStore logic — overlay computation, night mode stacking
//  14. AudioPipelineService — state transition decision table
//  15. EQ band Q-to-bandwidth conversion
//
// Run: swift Tests/ModelAndServiceTests.swift

import Foundation

// ============================================================================
// MARK: - Lightweight model mirrors (no Core Audio dependency)
// ============================================================================

enum EQFilterType: Int, Equatable {
    case parametric = 0
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

struct EQBand: Equatable {
    var frequency: Float
    var gain: Float
    var bandwidth: Float
    var filterType: EQFilterType

    var isFlat: Bool { abs(gain) < 0.01 }

    static func at(_ frequency: Float) -> EQBand {
        EQBand(frequency: frequency, gain: 0, bandwidth: 1.0, filterType: .parametric)
    }

    static func qToBandwidth(_ q: Float) -> Float {
        guard q > 0 else { return 1.0 }
        let bw = Float((2.0 / log(2.0)) * asinh(1.0 / (2.0 * Double(q))))
        return clamp(bw, 0.1...5.0)
    }
}

struct EQSettings: Equatable {
    static let standardFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let gainRange: ClosedRange<Float>      = -12 ... 12
    static let preampRange: ClosedRange<Float>    = -12 ... 12
    static let bandwidthRange: ClosedRange<Float> = 0.1 ... 5.0
    static let frequencyRange: ClosedRange<Float> = 20 ... 20_000

    var preamp: Float
    var bands: [EQBand]

    var isFlat: Bool {
        abs(preamp) < 0.01 && bands.allSatisfy(\.isFlat)
    }

    static var flat: EQSettings {
        var bands = standardFrequencies.map { EQBand.at($0) }
        bands[0].filterType = .lowShelf
        bands[9].filterType = .highShelf
        return EQSettings(preamp: 0, bands: bands)
    }

    func withBand(at index: Int, gain: Float) -> EQSettings {
        guard index >= 0 && index < bands.count else { return self }
        var copy = self
        copy.bands[index].gain = clamp(gain, EQSettings.gainRange)
        return copy
    }

    func withBand(at index: Int, bandwidth: Float) -> EQSettings {
        guard index >= 0 && index < bands.count else { return self }
        var copy = self
        copy.bands[index].bandwidth = clamp(bandwidth, EQSettings.bandwidthRange)
        return copy
    }

    func withBand(at index: Int, frequency: Float) -> EQSettings {
        guard index >= 0 && index < bands.count else { return self }
        let minFreq: Float = index > 0 ? bands[index - 1].frequency * 1.05 : EQSettings.frequencyRange.lowerBound
        let maxFreq: Float = index < bands.count - 1 ? bands[index + 1].frequency * 0.95 : EQSettings.frequencyRange.upperBound
        var copy = self
        copy.bands[index].frequency = clamp(frequency, minFreq...maxFreq)
        return copy
    }

    func withPreamp(_ value: Float) -> EQSettings {
        var copy = self
        copy.preamp = clamp(value, EQSettings.preampRange)
        return copy
    }

    func reset() -> EQSettings { .flat }

    static func combine(base: EQSettings, overlay: EQSettings) -> EQSettings {
        guard !overlay.isFlat else { return base }
        guard !base.isFlat else {
            var result = overlay
            for i in 0..<min(result.bands.count, base.bands.count) {
                result.bands[i].filterType = base.bands[i].filterType
                result.bands[i].bandwidth = base.bands[i].bandwidth
                result.bands[i].frequency = base.bands[i].frequency
            }
            return result
        }
        var combined = base
        combined.preamp = clamp(base.preamp + overlay.preamp, EQSettings.preampRange)
        let count = min(base.bands.count, overlay.bands.count)
        for i in 0..<count {
            combined.bands[i].gain = clamp(base.bands[i].gain + overlay.bands[i].gain, EQSettings.gainRange)
        }
        return combined
    }
}

enum ProfileMode: String, Equatable {
    case `public`
    case `private`
}

struct AudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let transportType: String
    let isInput: Bool
    let isOutput: Bool
}

struct Profile: Identifiable {
    let id: UUID
    var name: String
    var iconName: String
    var triggerDeviceIDs: [String]
    var publicOutputPriority: [String]
    var publicInputPriority: [String]
    var privateOutputPriority: [String]
    var privateInputPriority: [String]
    var preferredMode: ProfileMode
    var isSystemDefault: Bool = false

    func priorityList(isOutput: Bool, mode: ProfileMode) -> [String] {
        switch (isOutput, mode) {
        case (true,  .public):  return publicOutputPriority
        case (true,  .private): return privateOutputPriority
        case (false, .public):  return publicInputPriority
        case (false, .private): return privateInputPriority
        }
    }
}

enum ContentModeType: String, CaseIterable, Equatable {
    case none, music, voice, movie, gaming

    var displayName: String {
        switch self {
        case .none:    return "None"
        case .music:   return "Music"
        case .voice:   return "Voice"
        case .movie:   return "Movie"
        case .gaming:  return "Gaming"
        }
    }

    var iconName: String {
        switch self {
        case .none:    return "waveform"
        case .music:   return "music.note"
        case .voice:   return "mic.fill"
        case .movie:   return "film"
        case .gaming:  return "gamecontroller.fill"
        }
    }
}

struct ContentModeOverlay: Equatable {
    var mode: ContentModeType
    var settings: EQSettings
    var isEnabled: Bool

    static func defaultVoice() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = -2.0; bands[1].gain = -1.5; bands[2].gain = -1.0
        bands[6].gain = +2.5; bands[7].gain = +2.0; bands[8].gain = +1.0
        return ContentModeOverlay(mode: .voice, settings: EQSettings(preamp: 0, bands: bands), isEnabled: true)
    }
    static func defaultMovie() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = +2.0; bands[1].gain = +1.5
        bands[6].gain = +1.5; bands[7].gain = +1.0
        return ContentModeOverlay(mode: .movie, settings: EQSettings(preamp: -1.0, bands: bands), isEnabled: true)
    }
    static func defaultGaming() -> ContentModeOverlay {
        var bands = EQSettings.flat.bands
        bands[0].gain = +1.5; bands[1].gain = +1.0; bands[5].gain = -0.5
        bands[7].gain = +1.5; bands[8].gain = +1.0
        return ContentModeOverlay(mode: .gaming, settings: EQSettings(preamp: -0.5, bands: bands), isEnabled: true)
    }
    static func defaultMusic() -> ContentModeOverlay {
        ContentModeOverlay(mode: .music, settings: .flat, isEnabled: true)
    }
    static func defaultNone() -> ContentModeOverlay {
        ContentModeOverlay(mode: .none, settings: .flat, isEnabled: true)
    }
    static func defaultOverlay(for mode: ContentModeType) -> ContentModeOverlay {
        switch mode {
        case .none:    return defaultNone()
        case .music:   return defaultMusic()
        case .voice:   return defaultVoice()
        case .movie:   return defaultMovie()
        case .gaming:  return defaultGaming()
        }
    }
}

struct NightModeConfig: Equatable {
    var isEnabled: Bool = false
    var startHour: Int = 22
    var startMinute: Int = 0
    var endHour: Int = 7
    var endMinute: Int = 0
    var overlay: EQSettings

    static var `default`: NightModeConfig {
        var bands = EQSettings.flat.bands
        bands[0].gain = -4.0; bands[1].gain = -3.0; bands[2].gain = -1.5
        bands[5].gain = +1.0; bands[6].gain = +1.5; bands[7].gain = +1.0
        return NightModeConfig(overlay: EQSettings(preamp: 0, bands: bands))
    }

    func isInQuietHours(now: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute
        let startMinutes = startHour * 60 + self.startMinute
        let endMinutes = endHour * 60 + self.endMinute

        // start == end means "always on" (24h night mode)
        if startMinutes == endMinutes { return true }

        if startMinutes < endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }
    }
}

struct DeviceHistoryEntry {
    let device: AudioDevice
    var connectedAt: Date
    var lastSeen: Date
    var isCurrentlyActive: Bool
}


// ============================================================================
// MARK: - DeviceFilterService logic (extracted for testing)
// ============================================================================

func filterByType(_ devices: [AudioDevice], isInput: Bool) -> [AudioDevice] {
    devices.filter { isInput ? $0.isInput : $0.isOutput }
}

func excludeSelected(_ devices: [AudioDevice], selectedIDs: [String]) -> [AudioDevice] {
    devices.filter { !selectedIDs.contains($0.id) }
}

func getAvailableDevices(
    connected: [AudioDevice],
    historical: [AudioDevice],
    isInput: Bool,
    excludingIDs selectedIDs: [String],
    includeHistorical: Bool = true
) -> [AudioDevice] {
    var available = filterByType(connected, isInput: isInput)
    if includeHistorical {
        let hist = filterByType(historical, isInput: isInput)
        let unique = hist.filter { h in !available.contains { c in c.id == h.id } }
        available.append(contentsOf: unique)
    }
    return excludeSelected(available, selectedIDs: selectedIDs)
}

// ============================================================================
// MARK: - ProfileValidationService logic (extracted for testing)
// ============================================================================

func cleanupInvalidDevices(in profile: Profile, knownDeviceIDs: Set<String>) -> Profile {
    var p = profile
    p.triggerDeviceIDs = profile.triggerDeviceIDs.filter { knownDeviceIDs.contains($0) }
    p.publicOutputPriority = profile.publicOutputPriority.filter { knownDeviceIDs.contains($0) }
    p.publicInputPriority = profile.publicInputPriority.filter { knownDeviceIDs.contains($0) }
    p.privateOutputPriority = profile.privateOutputPriority.filter { knownDeviceIDs.contains($0) }
    p.privateInputPriority = profile.privateInputPriority.filter { knownDeviceIDs.contains($0) }
    return p
}

func profilesEqual(_ p1: [Profile], _ p2: [Profile]) -> Bool {
    guard p1.count == p2.count else { return false }
    for (a, b) in zip(p1, p2) {
        if a.id != b.id ||
           a.triggerDeviceIDs != b.triggerDeviceIDs ||
           a.publicOutputPriority != b.publicOutputPriority ||
           a.privateOutputPriority != b.privateOutputPriority ||
           a.publicInputPriority != b.publicInputPriority ||
           a.privateInputPriority != b.privateInputPriority { return false }
    }
    return true
}

// ============================================================================
// MARK: - AudioDeviceHistoryService logic (extracted for testing)
// ============================================================================

func performHistoryUpdate(
    _ currentHistory: [String: DeviceHistoryEntry],
    with devices: [AudioDevice],
    now: Date = Date()
) -> [String: DeviceHistoryEntry] {
    var updated = currentHistory
    let currentIDs = Set(devices.map { $0.id })

    for device in devices {
        // connectedAt advances only on a disconnected → connected transition
        // (new device, or one that was previously inactive); otherwise it is
        // preserved so unrelated device events don't refresh it.
        let existing = updated[device.id]
        let wasActive = existing?.isCurrentlyActive ?? false
        let connectedAt = wasActive ? (existing?.connectedAt ?? now) : now
        updated[device.id] = DeviceHistoryEntry(
            device: device,
            connectedAt: connectedAt,
            lastSeen: now,
            isCurrentlyActive: true
        )
    }
    for (id, var entry) in updated {
        if !currentIDs.contains(id) && entry.isCurrentlyActive {
            entry.isCurrentlyActive = false
            updated[id] = entry
        }
    }
    return updated
}

func pruneHistory(
    _ history: [String: DeviceHistoryEntry],
    olderThan cutoff: Date,
    profileReferencedIDs: Set<String> = []
) -> [String: DeviceHistoryEntry] {
    history.filter { id, entry in
        entry.lastSeen >= cutoff || profileReferencedIDs.contains(id)
    }
}

func getPreviouslySeen(
    history: [String: DeviceHistoryEntry],
    excluding currentDevices: [AudioDevice],
    cutoff: Date
) -> [AudioDevice] {
    let currentIDs = Set(currentDevices.map { $0.id })
    return history.values
        .filter { !$0.isCurrentlyActive && !currentIDs.contains($0.device.id) && $0.lastSeen >= cutoff }
        .map { $0.device }
        .sorted { $0.name < $1.name }
}

// ============================================================================
// MARK: - SoundModesStore logic — activeOverlay computation
// ============================================================================

func computeActiveOverlay(
    isEnabled: Bool,
    activeContentMode: ContentModeType,
    overlays: [ContentModeType: ContentModeOverlay],
    isNightModeActive: Bool,
    nightMode: NightModeConfig
) -> EQSettings {
    let contentEQ: EQSettings
    if isEnabled {
        let overlay = overlays[activeContentMode]
        if let o = overlay, o.isEnabled {
            contentEQ = o.settings
        } else {
            contentEQ = .flat
        }
    } else {
        contentEQ = .flat
    }
    if nightMode.isEnabled && isNightModeActive {
        return EQSettings.combine(base: contentEQ, overlay: nightMode.overlay)
    }
    return contentEQ
}

// ============================================================================
// MARK: - AudioPipelineService decision table
// ============================================================================

enum PipelineAction: Equatable {
    case hotUpdate(EQSettings)
    case switchDevice(realUID: String, settings: EQSettings, virtualName: String)
    case startPipeline(realUID: String, settings: EQSettings, virtualName: String)
    case stopEQ(switchTo: String)
    case directSetDevice(String)
    case noOp
}

func decidePipelineAction(
    eqRunning: Bool,
    eqTargetUID: String?,
    needsVirtualDriver: Bool,
    outputDeviceUID: String?,
    effectiveEQ: EQSettings,
    virtualDeviceName: String?
) -> PipelineAction {
    guard let outputUID = outputDeviceUID else { return .noOp }
    let vName = virtualDeviceName ?? "\(outputUID) EQ"

    if needsVirtualDriver {
        if eqRunning {
            if eqTargetUID == outputUID {
                return .hotUpdate(effectiveEQ)
            } else {
                return .switchDevice(realUID: outputUID, settings: effectiveEQ, virtualName: vName)
            }
        } else {
            return .startPipeline(realUID: outputUID, settings: effectiveEQ, virtualName: vName)
        }
    } else {
        if eqRunning {
            return .stopEQ(switchTo: outputUID)
        } else {
            return .directSetDevice(outputUID)
        }
    }
}

// ============================================================================
// MARK: - Test infrastructure
// ============================================================================

func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
    max(range.lowerBound, min(range.upperBound, value))
}

var totalTests = 0
var passedTests = 0
var failedTests = 0

func section(_ name: String) {
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("  \(name)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    totalTests += 1
    if condition { passedTests += 1; print("  ✅ \(message)") }
    else { failedTests += 1; print("  ❌ FAIL: \(message) (line \(line))") }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
    totalTests += 1
    if a == b { passedTests += 1; print("  ✅ \(message)") }
    else { failedTests += 1; print("  ❌ FAIL: \(message) — got '\(a)', expected '\(b)' (line \(line))") }
}

func checkApprox(_ a: Float, _ b: Float, tol: Float = 0.01, _ message: String, line: Int = #line) {
    totalTests += 1
    if abs(a - b) <= tol { passedTests += 1; print("  ✅ \(message)") }
    else { failedTests += 1; print("  ❌ FAIL: \(message) — got \(a), expected ≈\(b) (line \(line))") }
}

// Helper to make a Date at a specific hour:minute today
func makeTime(hour: Int, minute: Int) -> Date {
    var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    c.hour = hour; c.minute = minute; c.second = 0
    return Calendar.current.date(from: c)!
}

// ============================================================================
// MARK: - Fixtures
// ============================================================================

let speakers = AudioDevice(id: "speakers-uid", name: "Studio Monitors", transportType: "Built-In", isInput: false, isOutput: true)
let headphones = AudioDevice(id: "beyerdynamic-uid", name: "Beyerdynamic DT 990", transportType: "USB", isInput: false, isOutput: true)
let bluetooth = AudioDevice(id: "airpods-uid", name: "AirPods Max", transportType: "Bluetooth", isInput: true, isOutput: true)
let builtinOutput = AudioDevice(id: "builtin-output-uid", name: "MacBook Pro Speakers", transportType: "Built-In", isInput: false, isOutput: true)
let builtinInput = AudioDevice(id: "builtin-input-uid", name: "MacBook Pro Microphone", transportType: "Built-In", isInput: true, isOutput: false)
let usbMic = AudioDevice(id: "usb-mic-uid", name: "Blue Yeti", transportType: "USB", isInput: true, isOutput: false)

// ============================================================================
// MARK: - 1. NightModeConfig — Quiet Hours Logic
// ============================================================================

section("NightModeConfig — Quiet Hours")

do {
    // Disabled → always false regardless of time
    var config = NightModeConfig.default
    config.isEnabled = false
    check(!config.isInQuietHours(now: makeTime(hour: 23, minute: 0)), "Disabled → false at 23:00")
    check(!config.isInQuietHours(now: makeTime(hour: 3, minute: 0)), "Disabled → false at 03:00")
    check(!config.isInQuietHours(now: makeTime(hour: 12, minute: 0)), "Disabled → false at 12:00")
}

do {
    // Default: 22:00 - 07:00 (crosses midnight)
    var config = NightModeConfig.default
    config.isEnabled = true
    check(config.isInQuietHours(now: makeTime(hour: 22, minute: 0)), "22:00 → in quiet hours (start)")
    check(config.isInQuietHours(now: makeTime(hour: 23, minute: 30)), "23:30 → in quiet hours")
    check(config.isInQuietHours(now: makeTime(hour: 0, minute: 0)), "00:00 → in quiet hours (midnight)")
    check(config.isInQuietHours(now: makeTime(hour: 3, minute: 15)), "03:15 → in quiet hours")
    check(config.isInQuietHours(now: makeTime(hour: 6, minute: 59)), "06:59 → in quiet hours (just before end)")
    check(!config.isInQuietHours(now: makeTime(hour: 7, minute: 0)), "07:00 → NOT in quiet hours (end)")
    check(!config.isInQuietHours(now: makeTime(hour: 12, minute: 0)), "12:00 → NOT in quiet hours")
    check(!config.isInQuietHours(now: makeTime(hour: 21, minute: 59)), "21:59 → NOT in quiet hours (just before start)")
}

do {
    // Same-day range: 08:00 - 18:00
    var config = NightModeConfig(
        isEnabled: true, startHour: 8, startMinute: 0,
        endHour: 18, endMinute: 0, overlay: .flat
    )
    check(config.isInQuietHours(now: makeTime(hour: 8, minute: 0)), "08:00 → in range (start)")
    check(config.isInQuietHours(now: makeTime(hour: 12, minute: 0)), "12:00 → in range")
    check(config.isInQuietHours(now: makeTime(hour: 17, minute: 59)), "17:59 → in range (just before end)")
    check(!config.isInQuietHours(now: makeTime(hour: 18, minute: 0)), "18:00 → NOT in range (end)")
    check(!config.isInQuietHours(now: makeTime(hour: 7, minute: 59)), "07:59 → NOT in range")
    check(!config.isInQuietHours(now: makeTime(hour: 22, minute: 0)), "22:00 → NOT in range")
}

do {
    // Edge: start == end → always-on (24h night mode)
    var config = NightModeConfig(
        isEnabled: true, startHour: 10, startMinute: 0,
        endHour: 10, endMinute: 0, overlay: .flat
    )
    check(config.isInQuietHours(now: makeTime(hour: 10, minute: 0)), "Start == end → always-on (24h)")
    check(config.isInQuietHours(now: makeTime(hour: 9, minute: 59)), "Start == end → always-on (24h)")
}

do {
    // Minute precision: 22:30 - 06:45
    var config = NightModeConfig(
        isEnabled: true, startHour: 22, startMinute: 30,
        endHour: 6, endMinute: 45, overlay: .flat
    )
    check(!config.isInQuietHours(now: makeTime(hour: 22, minute: 29)), "22:29 → NOT in range")
    check(config.isInQuietHours(now: makeTime(hour: 22, minute: 30)), "22:30 → in range (start)")
    check(config.isInQuietHours(now: makeTime(hour: 6, minute: 44)), "06:44 → in range")
    check(!config.isInQuietHours(now: makeTime(hour: 6, minute: 45)), "06:45 → NOT in range (end)")
}

// ============================================================================
// MARK: - 2. ContentModeType — Enum Properties
// ============================================================================

section("ContentModeType — Enum Properties")

do {
    checkEqual(ContentModeType.allCases.count, 5, "5 content mode types")
    checkEqual(ContentModeType.none.displayName, "None", "None displayName")
    checkEqual(ContentModeType.music.displayName, "Music", "Music displayName")
    checkEqual(ContentModeType.voice.displayName, "Voice", "Voice displayName")
    checkEqual(ContentModeType.movie.displayName, "Movie", "Movie displayName")
    checkEqual(ContentModeType.gaming.displayName, "Gaming", "Gaming displayName")
}

do {
    checkEqual(ContentModeType.none.iconName, "waveform", "None icon")
    checkEqual(ContentModeType.music.iconName, "music.note", "Music icon")
    checkEqual(ContentModeType.voice.iconName, "mic.fill", "Voice icon")
    checkEqual(ContentModeType.movie.iconName, "film", "Movie icon")
    checkEqual(ContentModeType.gaming.iconName, "gamecontroller.fill", "Gaming icon")
}

do {
    // Raw values match expected strings
    checkEqual(ContentModeType.none.rawValue, "none", "None raw")
    checkEqual(ContentModeType.music.rawValue, "music", "Music raw")
    checkEqual(ContentModeType.voice.rawValue, "voice", "Voice raw")
}

// ============================================================================
// MARK: - 3. ContentModeOverlay — Default Factories
// ============================================================================

section("ContentModeOverlay — Default Factories")

do {
    let voice = ContentModeOverlay.defaultVoice()
    checkEqual(voice.mode, .voice, "Voice overlay mode")
    check(voice.isEnabled, "Voice overlay enabled by default")
    check(!voice.settings.isFlat, "Voice overlay is NOT flat")
    check(voice.settings.bands[0].gain < 0, "Voice cuts low bass")
    check(voice.settings.bands[6].gain > 0, "Voice boosts 2kHz")
    check(voice.settings.bands[7].gain > 0, "Voice boosts 4kHz")
}

do {
    let movie = ContentModeOverlay.defaultMovie()
    checkEqual(movie.mode, .movie, "Movie overlay mode")
    check(!movie.settings.isFlat, "Movie overlay is NOT flat")
    check(movie.settings.bands[0].gain > 0, "Movie boosts sub bass")
    check(movie.settings.preamp < 0, "Movie has negative preamp (safety headroom)")
}

do {
    let gaming = ContentModeOverlay.defaultGaming()
    checkEqual(gaming.mode, .gaming, "Gaming overlay mode")
    check(gaming.settings.bands[0].gain > 0, "Gaming boosts sub bass")
    check(gaming.settings.bands[7].gain > 0, "Gaming boosts 4kHz (footsteps)")
    checkApprox(gaming.settings.preamp, -0.5, "Gaming preamp = -0.5")
}

do {
    let music = ContentModeOverlay.defaultMusic()
    check(music.settings.isFlat, "Music overlay is flat (no EQ)")
    check(music.isEnabled, "Music overlay enabled")
}

do {
    let none = ContentModeOverlay.defaultNone()
    check(none.settings.isFlat, "None overlay is flat")
}

do {
    // defaultOverlay(for:) dispatches correctly
    let v = ContentModeOverlay.defaultOverlay(for: .voice)
    checkEqual(v.mode, .voice, "defaultOverlay(.voice) returns voice")
    let m = ContentModeOverlay.defaultOverlay(for: .movie)
    checkEqual(m.mode, .movie, "defaultOverlay(.movie) returns movie")
    let g = ContentModeOverlay.defaultOverlay(for: .gaming)
    checkEqual(g.mode, .gaming, "defaultOverlay(.gaming) returns gaming")
    let mu = ContentModeOverlay.defaultOverlay(for: .music)
    checkEqual(mu.mode, .music, "defaultOverlay(.music) returns music")
    let n = ContentModeOverlay.defaultOverlay(for: .none)
    checkEqual(n.mode, .none, "defaultOverlay(.none) returns none")
}

do {
    // Disabled overlay
    var voice = ContentModeOverlay.defaultVoice()
    voice.isEnabled = false
    check(!voice.isEnabled, "Disabled overlay has isEnabled = false")
}

// ============================================================================
// MARK: - 4. (Removed — Hotkey feature removed)
// ============================================================================

// ============================================================================
// MARK: - 6. EQSettings — Band Mutation Helpers
// ============================================================================

section("EQSettings — Band Mutation Helpers")

do {
    let eq = EQSettings.flat.withBand(at: 3, gain: 5.0)
    checkEqual(eq.bands[3].gain, 5.0, "withBand gain sets correctly")
    check(eq.bands[0].isFlat, "Other bands unaffected")
}

do {
    let eq = EQSettings.flat.withBand(at: 0, gain: 20.0)
    checkEqual(eq.bands[0].gain, 12.0, "Gain clamped to +12")
}

do {
    let eq = EQSettings.flat.withBand(at: 5, gain: -20.0)
    checkEqual(eq.bands[5].gain, -12.0, "Gain clamped to -12")
}

do {
    let eq = EQSettings.flat.withBand(at: -1, gain: 5.0)
    check(eq == .flat, "Negative index → unchanged")
}

do {
    let eq = EQSettings.flat.withBand(at: 99, gain: 5.0)
    check(eq == .flat, "Out-of-range index → unchanged")
}

do {
    let eq = EQSettings.flat.withBand(at: 5, bandwidth: 2.5)
    checkApprox(eq.bands[5].bandwidth, 2.5, "withBand bandwidth sets correctly")
}

do {
    let eq = EQSettings.flat.withBand(at: 5, bandwidth: 0.01)
    checkApprox(eq.bands[5].bandwidth, 0.1, "Bandwidth clamped to min 0.1")
}

do {
    let eq = EQSettings.flat.withBand(at: 5, bandwidth: 10.0)
    checkApprox(eq.bands[5].bandwidth, 5.0, "Bandwidth clamped to max 5.0")
}

do {
    let eq = EQSettings.flat.withPreamp(5.0)
    checkEqual(eq.preamp, 5.0, "withPreamp sets correctly")
}

do {
    let eq = EQSettings.flat.withPreamp(20.0)
    checkEqual(eq.preamp, 12.0, "Preamp clamped to +12")
}

do {
    let eq = EQSettings.flat.withPreamp(-20.0)
    checkEqual(eq.preamp, -12.0, "Preamp clamped to -12")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    eq.preamp = -3.0
    let reset = eq.reset()
    check(reset.isFlat, "reset() returns flat")
}

do {
    // Frequency clamping between neighbors
    let eq = EQSettings.flat
    // Band 5 is 1000 Hz, neighbors are 500 Hz (4) and 2000 Hz (6)
    let moved = eq.withBand(at: 5, frequency: 800.0)
    checkApprox(moved.bands[5].frequency, 800.0, "Frequency set within bounds")
}

do {
    // Frequency clamped: can't go below neighbor * 1.05
    let eq = EQSettings.flat
    // Band 5 = 1000 Hz, Band 4 = 500 Hz → min = 500 * 1.05 = 525
    let moved = eq.withBand(at: 5, frequency: 100.0)
    checkApprox(moved.bands[5].frequency, 525.0, "Frequency clamped above lower neighbor")
}

do {
    // Frequency clamped: can't go above next neighbor * 0.95
    let eq = EQSettings.flat
    // Band 5 = 1000 Hz, Band 6 = 2000 Hz → max = 2000 * 0.95 = 1900
    let moved = eq.withBand(at: 5, frequency: 5000.0)
    checkApprox(moved.bands[5].frequency, 1900.0, "Frequency clamped below upper neighbor")
}

do {
    // First band: can go down to 20 Hz
    let eq = EQSettings.flat
    let moved = eq.withBand(at: 0, frequency: 20.0)
    checkApprox(moved.bands[0].frequency, 20.0, "First band min = frequencyRange.lowerBound")
}

do {
    // Last band: can go up to 20000 Hz
    let eq = EQSettings.flat
    let moved = eq.withBand(at: 9, frequency: 20000.0)
    checkApprox(moved.bands[9].frequency, 20000.0, "Last band max = frequencyRange.upperBound")
}

// ============================================================================
// MARK: - 7. EQ Q-to-Bandwidth Conversion
// ============================================================================

section("EQ Band — Q to Bandwidth Conversion")

do {
    // Q=0 → fallback to 1.0
    let bw = EQBand.qToBandwidth(0)
    checkApprox(bw, 1.0, "Q=0 → bandwidth 1.0 (fallback)")
}

do {
    // Q<0 → fallback to 1.0
    let bw = EQBand.qToBandwidth(-5)
    checkApprox(bw, 1.0, "Q<0 → bandwidth 1.0 (fallback)")
}

do {
    // Q=1.0 → ~1.39 octaves
    let bw = EQBand.qToBandwidth(1.0)
    check(bw > 1.3 && bw < 1.5, "Q=1.0 → ~1.39 octaves")
}

do {
    // Q=0.7071 → ~1.9-2.1 octaves (Butterworth-style)
    let bw = EQBand.qToBandwidth(0.7071)
    check(bw > 1.8 && bw < 2.2, "Q≈0.707 → ~2.0 octaves (got \(bw))")
}

do {
    // Very high Q → very narrow bandwidth, clamped to min
    let bw = EQBand.qToBandwidth(100.0)
    checkApprox(bw, 0.1, tol: 0.05, "Very high Q → clamped to 0.1")
}

do {
    // Very low Q → very wide bandwidth, clamped to max
    let bw = EQBand.qToBandwidth(0.05)
    checkApprox(bw, 5.0, "Very low Q → clamped to 5.0")
}

// ============================================================================
// MARK: - 8. EQFilterType — Labels
// ============================================================================

section("EQFilterType — Labels")

do {
    checkEqual(EQFilterType.parametric.label, "PK", "Parametric label")
    checkEqual(EQFilterType.lowShelf.label, "LS", "Low shelf label")
    checkEqual(EQFilterType.highShelf.label, "HS", "High shelf label")
}

do {
    checkEqual(EQFilterType.parametric.rawValue, 0, "Parametric raw = 0")
    checkEqual(EQFilterType.lowShelf.rawValue, 7, "LowShelf raw = 7")
    checkEqual(EQFilterType.highShelf.rawValue, 8, "HighShelf raw = 8")
}

// ============================================================================
// MARK: - 9. NightModeConfig — Default Values
// ============================================================================

section("NightModeConfig — Default Overlay")

do {
    let config = NightModeConfig.default
    checkEqual(config.isEnabled, false, "Default: disabled")
    checkEqual(config.startHour, 22, "Default start: 22")
    checkEqual(config.endHour, 7, "Default end: 7")
    check(!config.overlay.isFlat, "Default night overlay is NOT flat")
    check(config.overlay.bands[0].gain < 0, "Night cuts 32Hz bass")
    check(config.overlay.bands[1].gain < 0, "Night cuts 64Hz bass")
    check(config.overlay.bands[5].gain > 0, "Night boosts 1kHz clarity")
    check(config.overlay.bands[6].gain > 0, "Night boosts 2kHz clarity")
}

// ============================================================================
// MARK: - 10. DeviceFilterService — Type Filtering
// ============================================================================

section("DeviceFilterService — Type Filtering")

do {
    let all = [speakers, headphones, bluetooth, builtinOutput, builtinInput, usbMic]
    let outputs = filterByType(all, isInput: false)
    checkEqual(outputs.count, 4, "4 output devices (speakers, headphones, bt, builtin)")
    check(outputs.allSatisfy(\.isOutput), "All filtered devices are outputs")
}

do {
    let all = [speakers, headphones, bluetooth, builtinOutput, builtinInput, usbMic]
    let inputs = filterByType(all, isInput: true)
    checkEqual(inputs.count, 3, "3 input devices (bt, builtin mic, usb mic)")
    check(inputs.allSatisfy(\.isInput), "All filtered devices are inputs")
}

do {
    let excluded = excludeSelected(
        [speakers, headphones, builtinOutput],
        selectedIDs: ["speakers-uid"]
    )
    checkEqual(excluded.count, 2, "Excluded speakers → 2 remaining")
    check(!excluded.contains(where: { $0.id == "speakers-uid" }), "Speakers excluded")
}

do {
    let excluded = excludeSelected(
        [speakers, headphones],
        selectedIDs: []
    )
    checkEqual(excluded.count, 2, "Empty exclusion → all remain")
}

do {
    let excluded = excludeSelected(
        [speakers, headphones],
        selectedIDs: ["speakers-uid", "beyerdynamic-uid"]
    )
    checkEqual(excluded.count, 0, "All excluded → empty")
}

// ============================================================================
// MARK: - 11. DeviceFilterService — Available Devices
// ============================================================================

section("DeviceFilterService — Available Devices")

do {
    let available = getAvailableDevices(
        connected: [speakers, headphones, builtinOutput],
        historical: [bluetooth],  // AirPods previously seen
        isInput: false,
        excludingIDs: ["speakers-uid"],
        includeHistorical: true
    )
    check(!available.contains(where: { $0.id == "speakers-uid" }), "Speakers excluded")
    check(available.contains(where: { $0.id == "beyerdynamic-uid" }), "Headphones available")
    check(available.contains(where: { $0.id == "airpods-uid" }), "Historical AirPods included")
}

do {
    let available = getAvailableDevices(
        connected: [speakers, headphones],
        historical: [bluetooth],
        isInput: false,
        excludingIDs: [],
        includeHistorical: false
    )
    checkEqual(available.count, 2, "Without historical → only connected")
    check(!available.contains(where: { $0.id == "airpods-uid" }), "AirPods NOT included")
}

do {
    // Historical device also in connected → no duplicate
    let available = getAvailableDevices(
        connected: [speakers, headphones],
        historical: [speakers],  // Same as connected
        isInput: false,
        excludingIDs: [],
        includeHistorical: true
    )
    checkEqual(available.count, 2, "No duplicate when historical == connected")
}

// ============================================================================
// MARK: - 12. ProfileValidationService — Cleanup
// ============================================================================

section("ProfileValidationService — Cleanup")

do {
    let profile = Profile(
        id: UUID(), name: "Test",
        iconName: "speaker", triggerDeviceIDs: ["known-uid", "unknown-uid"],
        publicOutputPriority: ["known-uid", "gone-uid"],
        publicInputPriority: ["known-uid"],
        privateOutputPriority: ["unknown-uid"],
        privateInputPriority: [],
        preferredMode: .public
    )
    let known: Set<String> = ["known-uid"]
    let cleaned = cleanupInvalidDevices(in: profile, knownDeviceIDs: known)

    checkEqual(cleaned.triggerDeviceIDs, ["known-uid"], "Removed unknown trigger")
    checkEqual(cleaned.publicOutputPriority, ["known-uid"], "Removed unknown output")
    checkEqual(cleaned.publicInputPriority, ["known-uid"], "Kept known input")
    checkEqual(cleaned.privateOutputPriority, [], "Removed all unknown private output")
    checkEqual(cleaned.privateInputPriority, [], "Empty stays empty")
}

do {
    let profile = Profile(
        id: UUID(), name: "All Known",
        iconName: "speaker", triggerDeviceIDs: ["a", "b"],
        publicOutputPriority: ["a", "b"],
        publicInputPriority: ["a"],
        privateOutputPriority: ["b"],
        privateInputPriority: ["a"],
        preferredMode: .public
    )
    let known: Set<String> = ["a", "b"]
    let cleaned = cleanupInvalidDevices(in: profile, knownDeviceIDs: known)
    checkEqual(cleaned.triggerDeviceIDs, ["a", "b"], "All known → nothing removed")
    checkEqual(cleaned.publicOutputPriority, ["a", "b"], "All known → nothing removed")
}

// ============================================================================
// MARK: - 13. ProfileValidationService — profilesEqual
// ============================================================================

section("ProfileValidationService — profilesEqual")

do {
    let id = UUID()
    let p = Profile(id: id, name: "A", iconName: "x", triggerDeviceIDs: ["a"],
                    publicOutputPriority: ["a"], publicInputPriority: [],
                    privateOutputPriority: [], privateInputPriority: [],
                    preferredMode: .public)
    check(profilesEqual([p], [p]), "Same profile → equal")
}

do {
    let id = UUID()
    let p1 = Profile(id: id, name: "A", iconName: "x", triggerDeviceIDs: ["a"],
                     publicOutputPriority: ["a"], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let p2 = Profile(id: id, name: "A", iconName: "x", triggerDeviceIDs: ["a", "b"],
                     publicOutputPriority: ["a"], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    check(!profilesEqual([p1], [p2]), "Different triggers → not equal")
}

do {
    check(!profilesEqual([], [Profile(id: UUID(), name: "A", iconName: "x",
                                      triggerDeviceIDs: [], publicOutputPriority: [],
                                      publicInputPriority: [], privateOutputPriority: [],
                                      privateInputPriority: [], preferredMode: .public)]),
          "Different count → not equal")
}

do {
    check(profilesEqual([], []), "Both empty → equal")
}

// ============================================================================
// MARK: - 14. AudioDeviceHistoryService — Update Logic
// ============================================================================

section("AudioDeviceHistoryService — Update Logic")

do {
    let now = Date()
    let devices = [speakers, headphones]
    let history = performHistoryUpdate([:], with: devices, now: now)

    checkEqual(history.count, 2, "Two entries after first update")
    check(history["speakers-uid"]!.isCurrentlyActive, "Speakers active")
    check(history["beyerdynamic-uid"]!.isCurrentlyActive, "Headphones active")
}

do {
    let now = Date()
    let t1 = now.addingTimeInterval(-3600)  // 1 hour ago

    // First update: speakers + headphones
    var history = performHistoryUpdate([:], with: [speakers, headphones], now: t1)

    // Second update: only speakers (headphones disconnected)
    history = performHistoryUpdate(history, with: [speakers], now: now)

    check(history["speakers-uid"]!.isCurrentlyActive, "Speakers still active")
    check(!history["beyerdynamic-uid"]!.isCurrentlyActive, "Headphones marked inactive")
    checkEqual(history["beyerdynamic-uid"]!.lastSeen, t1, "Headphones lastSeen = first update time")
    checkEqual(history["speakers-uid"]!.lastSeen, now, "Speakers lastSeen = now")
}

do {
    // connectedAt preserved across updates
    let t1 = Date().addingTimeInterval(-7200)
    let t2 = Date()

    var history = performHistoryUpdate([:], with: [speakers], now: t1)
    history = performHistoryUpdate(history, with: [speakers], now: t2)

    checkEqual(history["speakers-uid"]!.connectedAt, t1, "connectedAt preserved from first update")
    checkEqual(history["speakers-uid"]!.lastSeen, t2, "lastSeen updated")
}

// ============================================================================
// MARK: - 15. AudioDeviceHistoryService — Pruning
// ============================================================================

section("AudioDeviceHistoryService — Pruning")

do {
    let now = Date()
    let old = now.addingTimeInterval(-31 * 24 * 3600)  // 31 days ago
    let recent = now.addingTimeInterval(-1 * 24 * 3600)  // 1 day ago

    let history: [String: DeviceHistoryEntry] = [
        "old-uid": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
        "recent-uid": DeviceHistoryEntry(device: headphones, connectedAt: recent, lastSeen: recent, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let pruned = pruneHistory(history, olderThan: cutoff)

    checkEqual(pruned.count, 1, "Old device pruned, recent kept")
    check(pruned["recent-uid"] != nil, "Recent device survived pruning")
    check(pruned["old-uid"] == nil, "Old device removed")
}

do {
    // Empty history → stays empty
    let pruned = pruneHistory([:], olderThan: Date())
    checkEqual(pruned.count, 0, "Empty history → empty after prune")
}

// Regression: pruneHistory must work without profile data (no singleton dependency).
// The real bug: AudioDeviceHistoryService.pruneDeviceHistory() accessed
// ProfileManager.shared during its own init, causing a dispatch_once deadlock.
// The fix: pruneHistory takes profileReferencedIDs as an explicit parameter.
// This test verifies pruning works correctly with an EMPTY referenced set
// (the state during init, before profiles are loaded).
do {
    let now = Date()
    let old = now.addingTimeInterval(-31 * 24 * 3600)
    let history: [String: DeviceHistoryEntry] = [
        "old-uid": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    // With empty profileReferencedIDs (simulates init-time state), old device IS pruned
    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: [])
    checkEqual(pruned.count, 0, "Pruning with empty profileReferencedIDs (init-time) removes expired device")

    // With profileReferencedIDs containing the device, it survives
    let prunedProtected = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: ["old-uid"])
    checkEqual(prunedProtected.count, 1, "Pruning with profileReferencedIDs protects the device")
}

// Verify the pure function signature enforces no singleton dependency
// (profileReferencedIDs is a parameter, not fetched from ProfileManager.shared)
do {
    let now = Date()
    let recent = now.addingTimeInterval(-3600)
    let old = now.addingTimeInterval(-31 * 24 * 3600)
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let history: [String: DeviceHistoryEntry] = [
        "protected-uid": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
        "unprotected-uid": DeviceHistoryEntry(device: headphones, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
        "recent-uid": DeviceHistoryEntry(device: builtinOutput, connectedAt: recent, lastSeen: recent, isCurrentlyActive: false),
    ]
    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: ["protected-uid"])
    checkEqual(pruned.count, 2, "Protected + recent survive, unprotected pruned")
    check(pruned["protected-uid"] != nil, "Profile-referenced device survives even when expired")
    check(pruned["recent-uid"] != nil, "Recent device survives")
    check(pruned["unprotected-uid"] == nil, "Unreferenced expired device pruned")
}

// ============================================================================
// MARK: - 16. AudioDeviceHistoryService — Previously Seen
// ============================================================================

section("AudioDeviceHistoryService — Previously Seen Devices")

do {
    let now = Date()
    let recent = now.addingTimeInterval(-3600)
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "speakers-uid": DeviceHistoryEntry(device: speakers, connectedAt: recent, lastSeen: recent, isCurrentlyActive: true),
        "beyerdynamic-uid": DeviceHistoryEntry(device: headphones, connectedAt: recent, lastSeen: recent, isCurrentlyActive: false),
    ]

    let previous = getPreviouslySeen(history: history, excluding: [speakers], cutoff: cutoff)
    checkEqual(previous.count, 1, "One previously seen device")
    checkEqual(previous.first?.id, "beyerdynamic-uid", "Headphones are previously seen")
}

do {
    let now = Date()
    let old = now.addingTimeInterval(-31 * 24 * 3600)
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "old-uid": DeviceHistoryEntry(device: headphones, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
    ]

    let previous = getPreviouslySeen(history: history, excluding: [], cutoff: cutoff)
    checkEqual(previous.count, 0, "Expired device not returned")
}

do {
    // Currently active devices excluded even if not in current list
    let now = Date()
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "speakers-uid": DeviceHistoryEntry(device: speakers, connectedAt: now, lastSeen: now, isCurrentlyActive: true),
    ]

    let previous = getPreviouslySeen(history: history, excluding: [], cutoff: cutoff)
    checkEqual(previous.count, 0, "Active device not returned as 'previously seen'")
}

// ============================================================================
// MARK: - 17. SoundModesStore — activeOverlay Computation
// ============================================================================

section("SoundModesStore — activeOverlay Computation")

do {
    // Disabled → flat
    let result = computeActiveOverlay(
        isEnabled: false,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay.defaultVoice()],
        isNightModeActive: true,
        nightMode: .default
    )
    check(result.isFlat, "Sound modes disabled → flat overlay")
}

do {
    // Enabled, voice mode → voice overlay
    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay.defaultVoice()],
        isNightModeActive: false,
        nightMode: .default
    )
    check(!result.isFlat, "Voice mode enabled → non-flat overlay")
    check(result.bands[6].gain > 0, "Voice boosts 2kHz")
}

do {
    // Enabled, music mode (flat) → flat
    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .music,
        overlays: [.music: ContentModeOverlay.defaultMusic()],
        isNightModeActive: false,
        nightMode: .default
    )
    check(result.isFlat, "Music mode → flat (no overlay)")
}

do {
    // Voice + night mode → combined
    var enabledNight = NightModeConfig.default
    enabledNight.isEnabled = true

    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay.defaultVoice()],
        isNightModeActive: true,
        nightMode: enabledNight
    )
    check(!result.isFlat, "Voice + night → non-flat")
    // Night cuts bass further on top of voice bass cut
    check(result.bands[0].gain < 0, "Combined cuts bass")
    check(result.bands[6].gain > 0, "Combined still boosts 2kHz")
}

do {
    // Night mode active but content overlay disabled → only night overlay
    var disabledVoice = ContentModeOverlay.defaultVoice()
    disabledVoice.isEnabled = false

    var enabledNight = NightModeConfig.default
    enabledNight.isEnabled = true

    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: disabledVoice],
        isNightModeActive: true,
        nightMode: enabledNight
    )
    // Content overlay disabled → contentEQ is flat
    // Night overlay stacks on flat → just night overlay
    check(!result.isFlat, "Night mode alone → non-flat")
    checkApprox(result.bands[0].gain, -4.0, "Night bass cut at 32Hz = -4dB (from default)")
}

do {
    // Missing overlay for mode → flat content, night stacks if active
    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .gaming,
        overlays: [:],  // No overlays configured
        isNightModeActive: false,
        nightMode: .default
    )
    check(result.isFlat, "No overlay configured → flat")
}

// ============================================================================
// MARK: - 18. AudioPipelineService — Decision Table
// ============================================================================

section("AudioPipelineService — Decision Table")

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0

    // EQ running, same device → hot update
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: true, outputDeviceUID: "speakers-uid",
        effectiveEQ: eq, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .hotUpdate(eq), "Running + same device → hot update")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0

    // EQ running, different device → switch
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: true, outputDeviceUID: "beyerdynamic-uid",
        effectiveEQ: eq, virtualDeviceName: "Headphones EQ"
    )
    checkEqual(action, .switchDevice(realUID: "beyerdynamic-uid", settings: eq, virtualName: "Headphones EQ"),
               "Running + different device → switch")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0

    // EQ not running, needs virtual driver → start
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: true, outputDeviceUID: "speakers-uid",
        effectiveEQ: eq, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .startPipeline(realUID: "speakers-uid", settings: eq, virtualName: "Speakers EQ"),
               "Not running + needs driver → start")
}

do {
    // EQ running, no longer needs virtual driver → stop
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: false, outputDeviceUID: "speakers-uid",
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .stopEQ(switchTo: "speakers-uid"), "Running + flat EQ → stop")
}

do {
    // EQ not running, doesn't need virtual driver → direct set
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: false, outputDeviceUID: "speakers-uid",
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .directSetDevice("speakers-uid"), "Not running + flat → direct set")
}

do {
    // No output device → no-op
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: false, outputDeviceUID: nil,
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .noOp, "No output device → no-op")
}

// ============================================================================
// MARK: - 19. EQSettings.flat — Structure Validation
// ============================================================================

section("EQSettings.flat — Structure Validation")

do {
    let flat = EQSettings.flat
    checkEqual(flat.bands.count, 10, "10 bands")
    checkEqual(flat.bands[0].filterType, .lowShelf, "Band 0 = low shelf")
    for i in 1..<9 {
        checkEqual(flat.bands[i].filterType, .parametric, "Band \(i) = parametric")
    }
    checkEqual(flat.bands[9].filterType, .highShelf, "Band 9 = high shelf")

    // Verify standard frequencies
    let expected: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    for (i, freq) in expected.enumerated() {
        checkApprox(flat.bands[i].frequency, freq, "Band \(i) frequency = \(freq)")
    }

    // All bandwidths default to 1.0
    for i in 0..<10 {
        checkApprox(flat.bands[i].bandwidth, 1.0, "Band \(i) bandwidth = 1.0")
    }
}

// ============================================================================
// MARK: - 20. Profile — isSystemDefault
// ============================================================================

section("Profile — isSystemDefault Detection")

do {
    let sd = Profile(id: UUID(), name: "System Default", iconName: "gear",
                     triggerDeviceIDs: [], publicOutputPriority: [],
                     publicInputPriority: [], privateOutputPriority: [],
                     privateInputPriority: [], preferredMode: .public,
                     isSystemDefault: true)
    check(sd.isSystemDefault, "System Default → true")
}

do {
    let p = Profile(id: UUID(), name: "Home Studio", iconName: "house",
                    triggerDeviceIDs: [], publicOutputPriority: [],
                    publicInputPriority: [], privateOutputPriority: [],
                    privateInputPriority: [], preferredMode: .public)
    check(!p.isSystemDefault, "Home Studio → false")
}

do {
    // Stored flag defaults to false
    let p = Profile(id: UUID(), name: "system default", iconName: "gear",
                    triggerDeviceIDs: [], publicOutputPriority: [],
                    publicInputPriority: [], privateOutputPriority: [],
                    privateInputPriority: [], preferredMode: .public)
    check(!p.isSystemDefault, "Stored flag defaults to false")
}

// ============================================================================
// MARK: - 21. Full Three-Layer EQ Computation
// ============================================================================

section("Full Three-Layer EQ Computation")

do {
    // L1: device correction
    var deviceEQ = EQSettings.flat
    deviceEQ.bands[3].gain = 4.0  // 250Hz +4dB
    deviceEQ.preamp = -2.0

    // L2 content: voice mode
    let voiceOverlay = ContentModeOverlay.defaultVoice()

    // L2 night: default night mode
    let nightConfig = NightModeConfig.default

    // Combine L2: content + night
    let l2 = EQSettings.combine(base: voiceOverlay.settings, overlay: nightConfig.overlay)

    // Final: L1 + L2
    let final = EQSettings.combine(base: deviceEQ, overlay: l2)

    check(!final.isFlat, "Three-layer EQ is not flat")
    // L1 preamp (-2) + L2 preamp (0) = -2
    checkApprox(final.preamp, -2.0, "Preamp: device -2 + overlay 0 = -2")

    // Band 3 (250Hz): device +4, voice 0, night 0 = +4
    checkApprox(final.bands[3].gain, 4.0, "Band 3: device correction only (voice/night don't touch 250Hz)")

    // Band 0 (32Hz): device 0, voice -2, night -4 → combined L2 = -6, final = 0 + (-6) = -6
    checkApprox(final.bands[0].gain, -6.0, "Band 0: voice(-2) + night(-4) = -6")

    // Band 6 (2kHz): device 0, voice +2.5, night +1.5 → combined L2 = +4, final = 0 + 4 = +4
    checkApprox(final.bands[6].gain, 4.0, "Band 6: voice(+2.5) + night(+1.5) = +4")
}

do {
    // All layers flat → flat
    let l2 = EQSettings.combine(base: .flat, overlay: .flat)
    let final = EQSettings.combine(base: .flat, overlay: l2)
    check(final.isFlat, "All flat layers → flat result")
}

do {
    // Only night mode active (no content overlay, no device EQ)
    var nightConfig = NightModeConfig.default
    nightConfig.isEnabled = true
    let l2 = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .music,  // Music = flat overlay
        overlays: [.music: ContentModeOverlay.defaultMusic()],
        isNightModeActive: true,
        nightMode: nightConfig
    )
    // L2 = flat content + night overlay = night overlay
    let final = EQSettings.combine(base: .flat, overlay: l2)
    checkApprox(final.bands[0].gain, -4.0, "Only night: bass cut at 32Hz")
    checkApprox(final.bands[6].gain, 1.5, "Only night: clarity boost at 2kHz")
}

// ============================================================================
// MARK: - 22. AudioDevice — Identity & Flags
// ============================================================================

section("AudioDevice — Identity & Flags")

do {
    check(speakers.isOutput, "Speakers is output")
    check(!speakers.isInput, "Speakers is NOT input")
    check(bluetooth.isInput, "AirPods is input")
    check(bluetooth.isOutput, "AirPods is output")
    check(usbMic.isInput, "USB mic is input")
    check(!usbMic.isOutput, "USB mic is NOT output")
}

do {
    let d1 = AudioDevice(id: "same-uid", name: "Device A", transportType: "USB", isInput: false, isOutput: true)
    let d2 = AudioDevice(id: "same-uid", name: "Device A", transportType: "USB", isInput: false, isOutput: true)
    check(d1 == d2, "Same properties → equal")
}

do {
    let d1 = AudioDevice(id: "uid-1", name: "Device", transportType: "USB", isInput: false, isOutput: true)
    let d2 = AudioDevice(id: "uid-2", name: "Device", transportType: "USB", isInput: false, isOutput: true)
    check(d1 != d2, "Different IDs → not equal")
}

// ============================================================================
// MARK: - Pruning Protection — Profile-Referenced Devices
// ============================================================================

section("Device Pruning — Profile-Referenced Devices Protected")

do {
    // Device is >30 days old but referenced in a profile → must survive pruning
    let now = Date()
    let old = now.addingTimeInterval(-60 * 24 * 3600)  // 60 days ago

    let history: [String: DeviceHistoryEntry] = [
        "conference-speakers-uid": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let profileRefs: Set<String> = ["conference-speakers-uid"]  // Referenced by a profile

    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: profileRefs)
    checkEqual(pruned.count, 1, "Profile-referenced device survives pruning despite being >30 days old")
    check(pruned["conference-speakers-uid"] != nil, "Conference speakers preserved")
}

do {
    // Device is >30 days old and NOT referenced by any profile → gets pruned
    let now = Date()
    let old = now.addingTimeInterval(-60 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "orphan-device-uid": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let profileRefs: Set<String> = []  // Not referenced

    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: profileRefs)
    checkEqual(pruned.count, 0, "Unreferenced old device gets pruned normally")
}

do {
    // Mix: some profile-referenced, some not, some recent
    let now = Date()
    let old = now.addingTimeInterval(-60 * 24 * 3600)
    let recent = now.addingTimeInterval(-1 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "old-referenced": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
        "old-unreferenced": DeviceHistoryEntry(device: headphones, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
        "recent-unreferenced": DeviceHistoryEntry(device: bluetooth, connectedAt: recent, lastSeen: recent, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let profileRefs: Set<String> = ["old-referenced"]

    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: profileRefs)
    checkEqual(pruned.count, 2, "Old-referenced + recent survive; old-unreferenced pruned")
    check(pruned["old-referenced"] != nil, "Old but referenced → kept")
    check(pruned["old-unreferenced"] == nil, "Old and unreferenced → pruned")
    check(pruned["recent-unreferenced"] != nil, "Recent → kept regardless")
}

do {
    // Device referenced in trigger list → protected
    let now = Date()
    let old = now.addingTimeInterval(-90 * 24 * 3600)  // 90 days old

    let history: [String: DeviceHistoryEntry] = [
        "trigger-device": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let profileRefs: Set<String> = ["trigger-device"]

    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: profileRefs)
    checkEqual(pruned.count, 1, "Trigger device protected even at 90 days old")
}

do {
    // Device referenced across multiple profiles → still just needs to be in the set once
    let now = Date()
    let old = now.addingTimeInterval(-45 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "shared-device": DeviceHistoryEntry(device: speakers, connectedAt: old, lastSeen: old, isCurrentlyActive: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    // Simulates being in 3 profiles' priority lists
    let profileRefs: Set<String> = ["shared-device", "other-device"]

    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: profileRefs)
    check(pruned["shared-device"] != nil, "Device referenced by multiple profiles → protected")
}

// ============================================================================
// MARK: - ProfileValidationService — Cleanup Preserves Profile Refs
// ============================================================================

section("ProfileValidationService — Cleanup vs History Interaction")

do {
    // Simulate: device is in profile priority list but NOT in history
    // cleanupInvalidDevices should remove it
    let profile = Profile(
        id: UUID(), name: "Test", iconName: "gear",
        triggerDeviceIDs: ["known-uid", "unknown-uid"],
        publicOutputPriority: ["known-uid", "unknown-uid", "also-unknown"],
        publicInputPriority: [],
        privateOutputPriority: ["unknown-uid"],
        privateInputPriority: [],
        preferredMode: .public
    )

    // Mock: only "known-uid" exists in history
    let knownDevices: Set<String> = ["known-uid"]

    func cleanProfile(_ p: Profile, knownIDs: Set<String>) -> Profile {
        var cleaned = p
        cleaned.triggerDeviceIDs = p.triggerDeviceIDs.filter { knownIDs.contains($0) }
        cleaned.publicOutputPriority = p.publicOutputPriority.filter { knownIDs.contains($0) }
        cleaned.publicInputPriority = p.publicInputPriority.filter { knownIDs.contains($0) }
        cleaned.privateOutputPriority = p.privateOutputPriority.filter { knownIDs.contains($0) }
        cleaned.privateInputPriority = p.privateInputPriority.filter { knownIDs.contains($0) }
        return cleaned
    }

    let cleaned = cleanProfile(profile, knownIDs: knownDevices)
    checkEqual(cleaned.triggerDeviceIDs, ["known-uid"], "Unknown device removed from triggers")
    checkEqual(cleaned.publicOutputPriority, ["known-uid"], "Unknown devices removed from output priority")
    checkEqual(cleaned.privateOutputPriority.count, 0, "All unknown → empty private output")
}

do {
    // All devices known → no changes
    let profile = Profile(
        id: UUID(), name: "Clean", iconName: "gear",
        triggerDeviceIDs: ["a", "b"],
        publicOutputPriority: ["a", "b", "c"],
        publicInputPriority: ["d"],
        privateOutputPriority: ["b", "c"],
        privateInputPriority: ["d"],
        preferredMode: .public
    )
    let knownIDs: Set<String> = ["a", "b", "c", "d"]

    func cleanProfile(_ p: Profile, knownIDs: Set<String>) -> Profile {
        var cleaned = p
        cleaned.triggerDeviceIDs = p.triggerDeviceIDs.filter { knownIDs.contains($0) }
        cleaned.publicOutputPriority = p.publicOutputPriority.filter { knownIDs.contains($0) }
        cleaned.publicInputPriority = p.publicInputPriority.filter { knownIDs.contains($0) }
        cleaned.privateOutputPriority = p.privateOutputPriority.filter { knownIDs.contains($0) }
        cleaned.privateInputPriority = p.privateInputPriority.filter { knownIDs.contains($0) }
        return cleaned
    }

    let cleaned = cleanProfile(profile, knownIDs: knownIDs)
    checkEqual(cleaned.triggerDeviceIDs, profile.triggerDeviceIDs, "All known → triggers unchanged")
    checkEqual(cleaned.publicOutputPriority, profile.publicOutputPriority, "All known → output unchanged")
}

// ============================================================================
// MARK: - NightModeConfig — Edge Cases
// ============================================================================

section("NightModeConfig — Additional Edge Cases")

do {
    // start == end → always-on (24h night mode)
    let cfg = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 22, endMinute: 0, overlay: .flat)
    // Create a date at 22:00
    var cal = Calendar.current
    cal.timeZone = .current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 22; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "start == end → always-on (24h night mode)")
}

do {
    // Midnight crossing: 23:00-07:00, current = 02:00
    let cfg = NightModeConfig(isEnabled: true, startHour: 23, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    var cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 2; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "2am within 23:00-07:00 (midnight crossing)")
}

do {
    // Midnight crossing: 23:00-07:00, current = 08:00
    let cfg = NightModeConfig(isEnabled: true, startHour: 23, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    var cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 8; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(!cfg.isInQuietHours(now: testDate), "8am outside 23:00-07:00")
}

do {
    // Same-day range: 09:00-17:00, current = 12:00
    let cfg = NightModeConfig(isEnabled: true, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, overlay: .flat)
    var cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 12; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "12:00 within 09:00-17:00")
}

do {
    // Exact start time → active
    let cfg = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    var cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 22; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "Exact start time → active")
}

do {
    // Exact end time → NOT active (end is exclusive)
    let cfg = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    var cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 7; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(!cfg.isInQuietHours(now: testDate), "Exact end time → not active (exclusive)")
}

// ============================================================================
// MARK: - EQSettings — Edge Cases and Negative Tests
// ============================================================================

section("EQSettings — Edge Cases")

do {
    // Combine with itself → doubled gains (within clamp)
    var eq = EQSettings.flat
    eq.bands[0].gain = 5.0
    eq.bands[3].gain = -4.0
    eq.preamp = 2.0

    let doubled = EQSettings.combine(base: eq, overlay: eq)
    checkEqual(doubled.bands[0].gain, 10.0, "Self-combine: 5+5=10")
    checkEqual(doubled.bands[3].gain, -8.0, "Self-combine: -4+-4=-8")
    checkEqual(doubled.preamp, 4.0, "Self-combine preamp: 2+2=4")
}

do {
    // Gain at exact boundary
    var eq = EQSettings.flat
    eq.bands[0].gain = 12.0  // Already at max
    let overlay = EQSettings.flat

    let result = EQSettings.combine(base: eq, overlay: overlay)
    checkEqual(result.bands[0].gain, 12.0, "At-max gain with flat overlay stays at max")
}

do {
    // All bands negative → still valid, all negative
    var base = EQSettings.flat
    for i in 0..<base.bands.count {
        base.bands[i].gain = -6.0
    }
    base.preamp = -6.0

    check(!base.isFlat, "All-negative EQ is not flat")

    var overlay = EQSettings.flat
    overlay.bands[0].gain = 6.0  // Cancel out one band

    let result = EQSettings.combine(base: base, overlay: overlay)
    checkEqual(result.bands[0].gain, 0.0, "-6+6=0")
    checkEqual(result.bands[1].gain, -6.0, "Other bands unchanged")
}

// ============================================================================
// MARK: - Profile — Priority List Access for All Mode Combinations
// ============================================================================

section("Profile — Priority List Accessor Completeness")

do {
    let p = Profile(
        id: UUID(), name: "Test", iconName: "gear",
        triggerDeviceIDs: ["t1"],
        publicOutputPriority: ["pub-out"],
        publicInputPriority: ["pub-in"],
        privateOutputPriority: ["priv-out"],
        privateInputPriority: ["priv-in"],
        preferredMode: .public
    )

    checkEqual(p.priorityList(isOutput: true, mode: ProfileMode.public), ["pub-out"], "public+output")
    checkEqual(p.priorityList(isOutput: false, mode: ProfileMode.public), ["pub-in"], "public+input")
    checkEqual(p.priorityList(isOutput: true, mode: ProfileMode.private), ["priv-out"], "private+output")
    checkEqual(p.priorityList(isOutput: false, mode: ProfileMode.private), ["priv-in"], "private+input")
}

do {
    // Empty lists → empty arrays
    let p = Profile(
        id: UUID(), name: "Empty", iconName: "gear",
        triggerDeviceIDs: [],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    check(p.priorityList(isOutput: true, mode: ProfileMode.public).isEmpty, "Empty public output → []")
    check(p.priorityList(isOutput: false, mode: ProfileMode.private).isEmpty, "Empty private input → []")
}

// ============================================================================
// MARK: - SoundModesStore — Layer Combination Edge Cases
// ============================================================================

section("SoundModesStore — Layer Combination Edge Cases")

do {
    // Content Modes disabled + night mode enabled + in quiet hours → night overlay applied
    var nightEQ = EQSettings.flat
    nightEQ.bands[5].gain = 5.0
    let night = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: nightEQ)

    let result = computeActiveOverlay(
        isEnabled: false,
        activeContentMode: .music,
        overlays: [.music: ContentModeOverlay(mode: .music, settings: nightEQ, isEnabled: true)],
        isNightModeActive: true,
        nightMode: night
    )
    check(!result.isFlat, "Content Modes disabled + night mode on → night overlay applied")
    checkEqual(result.bands[5].gain, 5.0, "Night overlay gain preserved when Content Modes off")
}

do {
    // Content mode enabled but overlay is disabled → flat for that mode
    let settings = EQSettings.flat
    var modified = settings
    modified.bands[3].gain = 4.0

    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay(mode: .voice, settings: modified, isEnabled: false)],
        isNightModeActive: false,
        nightMode: NightModeConfig(isEnabled: false, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    )
    check(result.isFlat, "Overlay disabled for active mode → flat")
}

do {
    // Night mode active with content overlay → combined
    var contentEQ = EQSettings.flat
    contentEQ.bands[5].gain = 3.0  // Content: +3dB at 1kHz

    var nightEQ = EQSettings.flat
    nightEQ.bands[0].gain = -4.0   // Night: -4dB bass

    let night = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: nightEQ)

    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay(mode: .voice, settings: contentEQ, isEnabled: true)],
        isNightModeActive: true,
        nightMode: night
    )
    checkEqual(result.bands[5].gain, 3.0, "Content overlay preserved in combined L2")
    checkEqual(result.bands[0].gain, -4.0, "Night overlay applied in combined L2")
}

// ============================================================================
// MARK: - Night Mode Independence from Content Modes
// ============================================================================

section("Night Mode Independence from Content Modes")

do {
    // Content Modes OFF + Night Mode ON + in quiet hours → night overlay applied
    var nightEQ = EQSettings.flat
    nightEQ.bands[0].gain = -4.0
    nightEQ.bands[1].gain = -3.0
    let night = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: nightEQ)

    let result = computeActiveOverlay(
        isEnabled: false,
        activeContentMode: .none,
        overlays: [:],
        isNightModeActive: true,
        nightMode: night
    )
    check(!result.isFlat, "Content Modes OFF + Night Mode ON → non-flat")
    checkEqual(result.bands[0].gain, -4.0, "Night bass cut applied without Content Modes")
    checkEqual(result.bands[1].gain, -3.0, "Night bass cut band 2 applied without Content Modes")
}

do {
    // Content Modes OFF + Night Mode OFF → flat
    let night = NightModeConfig(isEnabled: false, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: NightModeConfig.default.overlay)

    let result = computeActiveOverlay(
        isEnabled: false,
        activeContentMode: .none,
        overlays: [:],
        isNightModeActive: false,
        nightMode: night
    )
    check(result.isFlat, "Content Modes OFF + Night Mode OFF → flat")
}

do {
    // Content Modes ON + Night Mode ON → both stacked
    var contentEQ = EQSettings.flat
    contentEQ.bands[6].gain = 2.0   // Content: +2dB at 2kHz

    var nightEQ = EQSettings.flat
    nightEQ.bands[0].gain = -4.0    // Night: -4dB bass

    let night = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: nightEQ)

    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay(mode: .voice, settings: contentEQ, isEnabled: true)],
        isNightModeActive: true,
        nightMode: night
    )
    checkEqual(result.bands[6].gain, 2.0, "Content Modes ON + Night ON → content overlay preserved")
    checkEqual(result.bands[0].gain, -4.0, "Content Modes ON + Night ON → night overlay stacked")
}

do {
    // Content Modes ON + Night Mode OFF → content overlay only
    var contentEQ = EQSettings.flat
    contentEQ.bands[6].gain = 2.0

    let night = NightModeConfig(isEnabled: false, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: NightModeConfig.default.overlay)

    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .voice,
        overlays: [.voice: ContentModeOverlay(mode: .voice, settings: contentEQ, isEnabled: true)],
        isNightModeActive: false,
        nightMode: night
    )
    checkEqual(result.bands[6].gain, 2.0, "Content Modes ON + Night OFF → content overlay applied")
    checkEqual(result.bands[0].gain, 0.0, "Content Modes ON + Night OFF → no night bass cut")
}

do {
    // Content Modes OFF + Night Mode enabled but NOT in quiet hours → flat
    let night = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: NightModeConfig.default.overlay)

    let result = computeActiveOverlay(
        isEnabled: false,
        activeContentMode: .none,
        overlays: [:],
        isNightModeActive: false,  // Not currently in quiet hours
        nightMode: night
    )
    check(result.isFlat, "Content Modes OFF + Night enabled but not in quiet hours → flat")
}

// ============================================================================
// MARK: - AudioPipelineService — Decision Table Extended
// ============================================================================

section("AudioPipelineService — Decision Table Extended")

do {
    // EQ running on same device, flat EQ → should stop (not just hot-update)
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: false, outputDeviceUID: "speakers-uid",
        effectiveEQ: .flat, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .stopEQ(switchTo: "speakers-uid"), "Running EQ + now flat → stop pipeline")
}

do {
    // EQ not running, flat EQ → direct device set
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: false, outputDeviceUID: "speakers-uid",
        effectiveEQ: .flat, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .directSetDevice("speakers-uid"), "No EQ + flat → direct device set")
}

do {
    // EQ not running, non-flat EQ → start pipeline
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: true, outputDeviceUID: "speakers-uid",
        effectiveEQ: eq, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .startPipeline(realUID: "speakers-uid", settings: eq, virtualName: "Speakers EQ"), "No EQ + non-flat → start pipeline")
}

do {
    // EQ running on same device, non-flat EQ → hot-update
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: true, outputDeviceUID: "speakers-uid",
        effectiveEQ: eq, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .hotUpdate(eq), "Same device + non-flat EQ → hot-update")
}

do {
    // EQ running on different device, non-flat EQ → switch
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: true, outputDeviceUID: "beyerdynamic-uid",
        effectiveEQ: eq, virtualDeviceName: "Beyerdynamic EQ"
    )
    checkEqual(action, .switchDevice(realUID: "beyerdynamic-uid", settings: eq, virtualName: "Beyerdynamic EQ"), "Different device + non-flat EQ → switch")
}

// ============================================================================
// MARK: - Helper: Driver Volume Curve (mirrors DriverState.swift:116-140)
// ============================================================================

/// Mirrors DriverState.ioGain — the gain applied in the IO path.
/// BUG 7 FIX: was cubic (scalar³), now squared (scalar²) to match comment and macOS behavior.
func computeIOGain(volumeScalar: Float32, isMuted: Bool) -> Float32 {
    if isMuted || volumeScalar <= 0 { return 0.0 }
    return volumeScalar * volumeScalar  // squared — matches macOS hardware volume curve
}

/// Mirrors DriverState.volumeDB getter — quadratic scalar-to-dB conversion.
func volumeScalarToDB(_ scalar: Float32, minDB: Float32 = -96.0, maxDB: Float32 = 0.0) -> Float32 {
    if scalar <= 0 { return minDB }
    return minDB + (scalar * scalar) * (maxDB - minDB)
}

/// Mirrors DriverState.volumeDB setter — inverse quadratic dB-to-scalar conversion.
func volumeDBToScalar(_ dB: Float32, minDB: Float32 = -96.0, maxDB: Float32 = 0.0) -> Float32 {
    let clamped = min(max(dB, minDB), maxDB)
    if clamped <= minDB { return 0 }
    let normalized = (clamped - minDB) / (maxDB - minDB)
    return sqrtf(normalized)
}

// ============================================================================
// MARK: - Helper: EQ State Machine (mirrors EQEngineService state transitions)
// ============================================================================

enum PipelineState: String, Equatable {
    case idle, preparingDevice, preparingSampleRate, starting, running, stopping
}

enum PipelineEvent: Equatable {
    case startRequested(generation: Int)
    case deviceAppeared(generation: Int)
    case sampleRateReady(generation: Int)
    case auSetupComplete
    case stopRequested
    case cancelRequested
    case switchRequested(generation: Int)
    case safetyTimerFired(generation: Int)
}

struct StateMachineResult: Equatable {
    let newState: PipelineState
    let shouldProceed: Bool  // true = state changed, false = event ignored
}

/// Pure function modeling EQEngineService state transitions.
/// Each transition checks: (1) current state guard (2) generation match.
func stateMachineTransition(
    currentState: PipelineState,
    event: PipelineEvent,
    currentGeneration: Int
) -> StateMachineResult {
    switch event {
    case .startRequested(let gen):
        // Start always goes to preparingDevice (increments generation internally)
        return StateMachineResult(newState: .preparingDevice, shouldProceed: true)

    case .deviceAppeared(let gen):
        guard currentState == .preparingDevice else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        guard gen == currentGeneration else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        return StateMachineResult(newState: .preparingSampleRate, shouldProceed: true)

    case .sampleRateReady(let gen):
        guard currentState == .preparingSampleRate else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        guard gen == currentGeneration else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        return StateMachineResult(newState: .starting, shouldProceed: true)

    case .auSetupComplete:
        guard currentState == .starting else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        return StateMachineResult(newState: .running, shouldProceed: true)

    case .stopRequested:
        guard currentState == .running else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        return StateMachineResult(newState: .stopping, shouldProceed: true)

    case .cancelRequested:
        return StateMachineResult(newState: .idle, shouldProceed: true)

    case .switchRequested(let gen):
        if currentState == .running {
            return StateMachineResult(newState: .preparingSampleRate, shouldProceed: true)
        } else if currentState == .preparingSampleRate {
            // Rapid switch while waiting for rate — reset with new gen
            guard gen == currentGeneration else {
                return StateMachineResult(newState: currentState, shouldProceed: false)
            }
            return StateMachineResult(newState: .preparingSampleRate, shouldProceed: true)
        } else {
            // Not running — fall back to full start
            return StateMachineResult(newState: .preparingDevice, shouldProceed: true)
        }

    case .safetyTimerFired(let gen):
        guard gen == currentGeneration else {
            return StateMachineResult(newState: currentState, shouldProceed: false)
        }
        if currentState == .preparingDevice {
            return StateMachineResult(newState: .preparingSampleRate, shouldProceed: true)
        } else if currentState == .preparingSampleRate {
            return StateMachineResult(newState: .starting, shouldProceed: true)
        }
        return StateMachineResult(newState: currentState, shouldProceed: false)
    }
}

// ============================================================================
// MARK: - Helper: Manual Override Timestamp (mirrors ProfileManager.shouldApplyTrigger)
// ============================================================================

struct TriggerDeviceEntry {
    let deviceID: String
    let isCurrentlyActive: Bool
    let connectedAt: Date
}

/// Pure function mirroring ProfileManager.shouldApplyTrigger().
/// Compares `connectedAt` (not `lastSeen`) so an unrelated device event that merely
/// refreshes lastSeen cannot resurrect an old trigger and override a manual selection.
func shouldApplyTriggerPure(
    lastManualSwitch: Date?,
    triggerEntries: [TriggerDeviceEntry]
) -> Bool {
    guard let lastManualSwitch = lastManualSwitch else {
        return true  // No manual switch → always allow
    }
    for entry in triggerEntries {
        if entry.isCurrentlyActive && entry.connectedAt > lastManualSwitch {
            return true  // Device connected after manual switch → allow
        }
    }
    return false  // All trigger devices predate manual switch → block
}

// ============================================================================
// MARK: - Helper: updateSettings guard (mirrors EQEngineService.updateSettings)
// ============================================================================

func updateSettingsPure(eqAUExists: Bool, isRunning: Bool, settings: EQSettings) -> (applied: Bool, bypassed: Bool) {
    guard eqAUExists else { return (applied: false, bypassed: false) }
    return (applied: true, bypassed: settings.isFlat)
}

// ============================================================================
// MARK: - Helper: EQ Bypass Gain Jump
// ============================================================================

/// Computes the maximum gain discontinuity when toggling EQ bypass.
func eqBypassGainJump(bands: [EQBand], preamp: Float32) -> Float32 {
    let maxBandGain = bands.map { abs($0.gain) }.max() ?? 0
    return maxBandGain + abs(preamp)
}

// ============================================================================
// MARK: - Helper: Sample Rate Fallback
// ============================================================================

func resolveSampleRate(queryResult: Float64?, fallback: Float64 = 48000) -> Float64 {
    return queryResult ?? fallback
}

// ============================================================================
// MARK: - Helper: Channel Count
// ============================================================================

func resolveChannelCount(deviceChannels: UInt32?) -> UInt32 {
    return 2  // Hardcoded — Bug 12
}

// ============================================================================
// MARK: - Test: Driver Volume Curve — Cubic vs Quadratic (Bugs 7, 8)
// ============================================================================

section("Driver Volume Curve — Cubic vs Quadratic (Bugs 7, 8)")

// Positive: ioGain at full volume
do {
    let gain = computeIOGain(volumeScalar: 1.0, isMuted: false)
    checkApprox(gain, 1.0, tol: 0.001, "ioGain at scalar=1.0 → 1.0 (unity)")
}

// Positive: ioGain at zero volume
do {
    let gain = computeIOGain(volumeScalar: 0.0, isMuted: false)
    checkApprox(gain, 0.0, tol: 0.001, "ioGain at scalar=0.0 → 0.0")
}

// Positive: ioGain when muted
do {
    let gain = computeIOGain(volumeScalar: 0.75, isMuted: true)
    checkApprox(gain, 0.0, tol: 0.001, "ioGain when muted → 0.0 regardless of scalar")
}

// Regression (Bug 7): ioGain at 0.5 is 0.25 (squared), NOT 0.125 (cubic)
do {
    let gain = computeIOGain(volumeScalar: 0.5, isMuted: false)
    checkApprox(gain, 0.25, tol: 0.001, "ioGain at scalar=0.5 → 0.25 (squared, not 0.125 cubic)")
    check(abs(gain - 0.125) > 0.01, "ioGain at 0.5 is NOT 0.125 (that would be cubic)")
}

// Regression (Bug 7): ioGain at 0.8 is 0.64 (squared), NOT 0.512 (cubic)
do {
    let gain = computeIOGain(volumeScalar: 0.8, isMuted: false)
    checkApprox(gain, 0.64, tol: 0.001, "ioGain at scalar=0.8 → 0.64 (squared)")
    check(abs(gain - 0.512) > 0.01, "ioGain at 0.8 is NOT 0.512 (that would be cubic)")
}

// Positive: volumeDB at full volume
do {
    let dB = volumeScalarToDB(1.0)
    checkApprox(dB, 0.0, tol: 0.01, "volumeDB at scalar=1.0 → 0.0 dB (max)")
}

// Positive: volumeDB at zero volume
do {
    let dB = volumeScalarToDB(0.0)
    checkApprox(dB, -96.0, tol: 0.01, "volumeDB at scalar=0.0 → -96.0 dB (min)")
}

// Positive: volumeDB uses quadratic curve (scalar²)
do {
    let dB = volumeScalarToDB(0.5)
    // Expected: -96 + (0.25) * 96 = -96 + 24 = -72
    checkApprox(dB, -72.0, tol: 0.01, "volumeDB at scalar=0.5 → -72.0 dB (quadratic)")
}

// Positive: volumeDB round-trip consistency
do {
    let original: Float32 = 0.7
    let dB = volumeScalarToDB(original)
    let roundTrip = volumeDBToScalar(dB)
    checkApprox(roundTrip, original, tol: 0.001, "volumeDB round-trip: 0.7 → dB → 0.7")
}

// Regression (Bug 7): ioGain curve and volumeDB curve are both quadratic after fix
do {
    let scalar: Float32 = 0.5
    let ioGain = computeIOGain(volumeScalar: scalar, isMuted: false)
    // ioGain = scalar² = 0.25
    // volumeDB = -96 + scalar² * 96 = -72.0 dB → scalar = sqrt((-72+96)/96) = 0.5
    // Both use scalar² — they are consistent
    checkApprox(ioGain, scalar * scalar, tol: 0.001, "ioGain uses squared curve (consistent with volumeDB)")
}

// Regression (Bug 8): Volume sync — virtual scalar maps correctly to ioGain
do {
    // When EQ engine copies real device volume to virtual device,
    // the driver applies ioGain = scalar². So if real device is at 0.5,
    // virtual should also be 0.5 → ioGain = 0.25 → correct.
    let realScalar: Float32 = 0.5
    let virtualScalar = realScalar  // syncVolumeForEQ copies directly
    let virtualGain = computeIOGain(volumeScalar: virtualScalar, isMuted: false)
    checkApprox(virtualGain, 0.25, tol: 0.001, "Volume sync: virtual scalar 0.5 → ioGain 0.25")
}

// Negative: negative scalar
do {
    let gain = computeIOGain(volumeScalar: -0.5, isMuted: false)
    checkApprox(gain, 0.0, tol: 0.001, "ioGain with negative scalar → 0.0")
}

// Negative: volumeDBToScalar below minDB
do {
    let scalar = volumeDBToScalar(-200.0)
    checkApprox(scalar, 0.0, tol: 0.001, "volumeDBToScalar below minDB → 0.0")
}

// Negative: volumeDBToScalar above maxDB
do {
    let scalar = volumeDBToScalar(10.0)
    checkApprox(scalar, 1.0, tol: 0.001, "volumeDBToScalar above maxDB → clamped to 1.0")
}

// Positive: ioGain at 0.1 (quiet volume)
do {
    let gain = computeIOGain(volumeScalar: 0.1, isMuted: false)
    checkApprox(gain, 0.01, tol: 0.001, "ioGain at scalar=0.1 → 0.01 (squared)")
}

// ============================================================================
// MARK: - Test: EQ State Machine Transitions (Bugs 1, 2)
// ============================================================================

section("EQ State Machine Transitions (Bugs 1, 2)")

// Positive: Normal startup flow
do {
    var r = stateMachineTransition(currentState: .idle, event: .startRequested(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .preparingDevice, "idle + startRequested → preparingDevice")
    check(r.shouldProceed, "idle + startRequested → should proceed")

    r = stateMachineTransition(currentState: .preparingDevice, event: .deviceAppeared(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .preparingSampleRate, "preparingDevice + deviceAppeared → preparingSampleRate")

    r = stateMachineTransition(currentState: .preparingSampleRate, event: .sampleRateReady(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .starting, "preparingSampleRate + sampleRateReady → starting")

    r = stateMachineTransition(currentState: .starting, event: .auSetupComplete, currentGeneration: 1)
    checkEqual(r.newState, .running, "starting + auSetupComplete → running")
}

// Positive: Normal stop
do {
    let r = stateMachineTransition(currentState: .running, event: .stopRequested, currentGeneration: 1)
    checkEqual(r.newState, .stopping, "running + stopRequested → stopping")
}

// Positive: Cancel from any state
do {
    for state in [PipelineState.idle, .preparingDevice, .preparingSampleRate, .starting, .running, .stopping] {
        let r = stateMachineTransition(currentState: state, event: .cancelRequested, currentGeneration: 1)
        checkEqual(r.newState, .idle, "cancel from \(state.rawValue) → idle")
    }
}

// Regression (Bug 1): Stale callback with generation mismatch — ignored
do {
    let r = stateMachineTransition(currentState: .preparingDevice, event: .deviceAppeared(generation: 1), currentGeneration: 2)
    checkEqual(r.newState, .preparingDevice, "stale deviceAppeared (gen 1 vs current 2) → ignored")
    check(!r.shouldProceed, "stale callback should not proceed")
}

// Regression (Bug 1): Stale sampleRateReady — ignored
do {
    let r = stateMachineTransition(currentState: .preparingSampleRate, event: .sampleRateReady(generation: 1), currentGeneration: 2)
    checkEqual(r.newState, .preparingSampleRate, "stale sampleRateReady → ignored")
    check(!r.shouldProceed, "stale sampleRateReady should not proceed")
}

// Regression (Bug 2): Rapid switch while in preparingSampleRate — resets with new gen
do {
    let r = stateMachineTransition(currentState: .preparingSampleRate, event: .switchRequested(generation: 2), currentGeneration: 2)
    checkEqual(r.newState, .preparingSampleRate, "preparingSampleRate + switch(matching gen) → stays in preparingSampleRate")
    check(r.shouldProceed, "switch with matching gen should proceed (new request)")
}

// Regression (Bug 2): Safety timer fires with stale generation — no-op
do {
    let r = stateMachineTransition(currentState: .preparingSampleRate, event: .safetyTimerFired(generation: 1), currentGeneration: 2)
    check(!r.shouldProceed, "stale safety timer should not proceed")
}

// Positive: Safety timer advances preparingDevice
do {
    let r = stateMachineTransition(currentState: .preparingDevice, event: .safetyTimerFired(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .preparingSampleRate, "preparingDevice + safety timer → preparingSampleRate")
}

// Positive: Safety timer advances preparingSampleRate
do {
    let r = stateMachineTransition(currentState: .preparingSampleRate, event: .safetyTimerFired(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .starting, "preparingSampleRate + safety timer → starting")
}

// Positive: switchRequested from running
do {
    let r = stateMachineTransition(currentState: .running, event: .switchRequested(generation: 2), currentGeneration: 2)
    checkEqual(r.newState, .preparingSampleRate, "running + switchRequested → preparingSampleRate")
}

// Positive: switchRequested from idle — falls back to full start
do {
    let r = stateMachineTransition(currentState: .idle, event: .switchRequested(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .preparingDevice, "idle + switchRequested → preparingDevice (full start)")
}

// Negative: stopRequested when not running — ignored
do {
    let r = stateMachineTransition(currentState: .idle, event: .stopRequested, currentGeneration: 1)
    checkEqual(r.newState, .idle, "idle + stopRequested → stays idle")
    check(!r.shouldProceed, "stop from idle should not proceed")
}

// Negative: deviceAppeared when not in preparingDevice — ignored
do {
    let r = stateMachineTransition(currentState: .running, event: .deviceAppeared(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .running, "running + deviceAppeared → ignored")
    check(!r.shouldProceed, "deviceAppeared in wrong state should not proceed")
}

// Regression (Bug 1): Rapid start(gen=1), start(gen=2), callback(gen=1) → ignored
do {
    // Simulate: first start with gen 1
    var r = stateMachineTransition(currentState: .idle, event: .startRequested(generation: 1), currentGeneration: 1)
    checkEqual(r.newState, .preparingDevice, "first start → preparingDevice")

    // Second start bumps generation to 2
    r = stateMachineTransition(currentState: .preparingDevice, event: .startRequested(generation: 2), currentGeneration: 2)
    checkEqual(r.newState, .preparingDevice, "second start → preparingDevice (new gen)")

    // Old callback from gen=1 arrives — should be ignored
    r = stateMachineTransition(currentState: .preparingDevice, event: .deviceAppeared(generation: 1), currentGeneration: 2)
    check(!r.shouldProceed, "callback from gen=1 ignored when current gen=2")
}

// ============================================================================
// MARK: - Test: Manual Override Timestamp Logic (Bug 3)
// ============================================================================

section("Manual Override Timestamp Logic (Bug 3)")

// Positive: No manual switch → always allow
do {
    let entries = [TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: true, connectedAt: Date())]
    let result = shouldApplyTriggerPure(lastManualSwitch: nil, triggerEntries: entries)
    check(result, "No manual switch timestamp → allow trigger")
}

// Positive: Device connected after manual switch → allow
do {
    let manualSwitch = Date().addingTimeInterval(-60)  // 1 minute ago
    let entries = [TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: true, connectedAt: Date())]
    let result = shouldApplyTriggerPure(lastManualSwitch: manualSwitch, triggerEntries: entries)
    check(result, "Device connected after manual switch → allow")
}

// Positive: Device connected before manual switch → block
do {
    let entries = [TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: true, connectedAt: Date().addingTimeInterval(-120))]
    let manualSwitch = Date().addingTimeInterval(-60)
    let result = shouldApplyTriggerPure(lastManualSwitch: manualSwitch, triggerEntries: entries)
    check(!result, "Device connected before manual switch → block")
}

// Positive: Multiple devices, one connected after → allow (any-match)
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let entries = [
        TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: true, connectedAt: Date().addingTimeInterval(-120)),
        TriggerDeviceEntry(deviceID: "headphones-uid", isCurrentlyActive: true, connectedAt: Date())
    ]
    let result = shouldApplyTriggerPure(lastManualSwitch: manualSwitch, triggerEntries: entries)
    check(result, "One device connected after manual switch → allow (any-match)")
}

// Positive: All devices connected before → block
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let entries = [
        TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: true, connectedAt: Date().addingTimeInterval(-120)),
        TriggerDeviceEntry(deviceID: "headphones-uid", isCurrentlyActive: true, connectedAt: Date().addingTimeInterval(-120))
    ]
    let result = shouldApplyTriggerPure(lastManualSwitch: manualSwitch, triggerEntries: entries)
    check(!result, "All devices connected before manual switch → block")
}

// Regression (Bug 3): nil timestamp after force-quit → allows all
do {
    let entries = [TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: true, connectedAt: Date().addingTimeInterval(-3600))]
    let result = shouldApplyTriggerPure(lastManualSwitch: nil, triggerEntries: entries)
    check(result, "Force-quit (nil timestamp) → allows all triggers")
}

// Negative: Device in history but not currently active → block
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let entries = [TriggerDeviceEntry(deviceID: "speakers-uid", isCurrentlyActive: false, connectedAt: Date())]
    let result = shouldApplyTriggerPure(lastManualSwitch: manualSwitch, triggerEntries: entries)
    check(!result, "Device not currently active → block even if connectedAt is after manual switch")
}

// Negative: Empty trigger entries → block
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let result = shouldApplyTriggerPure(lastManualSwitch: manualSwitch, triggerEntries: [])
    check(!result, "Empty trigger entries → block")
}

// ============================================================================
// MARK: - Regression: Manual override survives unrelated device events (Bug #2)
// ============================================================================

section("Manual override survives unrelated device events (Bug #2)")

// The core bug: history refreshed lastSeen for EVERY connected device on any event,
// so plugging in an unrelated device made an old trigger look "connected after" the
// manual switch. connectedAt (advanced only on reconnect) fixes this.
do {
    let t0 = Date().addingTimeInterval(-300)   // trigger device connected 5 min ago
    let t1 = Date().addingTimeInterval(-120)   // user manually switched 2 min ago
    let t2 = Date().addingTimeInterval(-30)    // unrelated device plugged in 30s ago

    // Trigger device connected before the manual switch and stays connected throughout.
    var history = performHistoryUpdate([:], with: [speakers], now: t0)
    // An unrelated device is plugged in after the manual switch.
    history = performHistoryUpdate(history, with: [speakers, headphones], now: t2)

    // The unrelated event refreshes the trigger device's lastSeen, but NOT connectedAt.
    checkEqual(history["speakers-uid"]!.lastSeen, t2, "Unrelated event refreshes lastSeen")
    checkEqual(history["speakers-uid"]!.connectedAt, t0, "connectedAt unchanged by unrelated event")

    let entry = history["speakers-uid"]!
    let triggerEntries = [TriggerDeviceEntry(
        deviceID: "speakers-uid",
        isCurrentlyActive: entry.isCurrentlyActive,
        connectedAt: entry.connectedAt
    )]
    let result = shouldApplyTriggerPure(lastManualSwitch: t1, triggerEntries: triggerEntries)
    check(!result, "Trigger predating manual switch stays blocked despite unrelated plug-in (Bug #2)")
}

// Counter-case: the trigger device itself reconnects after the manual switch → allow.
do {
    let t0 = Date().addingTimeInterval(-300)
    let t1 = Date().addingTimeInterval(-120)
    let t2 = Date().addingTimeInterval(-30)

    var history = performHistoryUpdate([:], with: [speakers], now: t0)   // first connect
    history = performHistoryUpdate(history, with: [], now: t1)           // disconnect
    history = performHistoryUpdate(history, with: [speakers], now: t2)   // reconnect after manual switch

    checkEqual(history["speakers-uid"]!.connectedAt, t2, "Reconnect advances connectedAt")

    let entry = history["speakers-uid"]!
    let triggerEntries = [TriggerDeviceEntry(
        deviceID: "speakers-uid",
        isCurrentlyActive: entry.isCurrentlyActive,
        connectedAt: entry.connectedAt
    )]
    let result = shouldApplyTriggerPure(lastManualSwitch: t1, triggerEntries: triggerEntries)
    check(result, "Trigger reconnected after manual switch → allow (deliberate re-plug)")
}

// ============================================================================
// MARK: - Regression: No-match fallback respects manual override (Bug #6)
// ============================================================================

section("No-match fallback respects manual override (Bug #6)")

// Mirrors ProfileTriggerService.evaluateTriggers: an automatic device event that
// matches no trigger must not fall back to System Default while a manual override
// is active. Manual re-evaluation still falls back (matches the match-path convention).
func shouldFallBackToSystemDefault(isManualTrigger: Bool, hasMatch: Bool, hasActiveManualOverride: Bool) -> Bool {
    if hasMatch { return false }
    if !isManualTrigger && hasActiveManualOverride { return false }
    return true
}

do {
    let r = shouldFallBackToSystemDefault(isManualTrigger: false, hasMatch: false, hasActiveManualOverride: true)
    check(!r, "Automatic no-match with active manual override → keep manual profile (Bug #6)")
}
do {
    let r = shouldFallBackToSystemDefault(isManualTrigger: false, hasMatch: false, hasActiveManualOverride: false)
    check(r, "Automatic no-match without override → fall back to System Default")
}
do {
    let r = shouldFallBackToSystemDefault(isManualTrigger: true, hasMatch: false, hasActiveManualOverride: true)
    check(r, "Manual re-evaluation with no match still falls back (explicit request)")
}
do {
    let r = shouldFallBackToSystemDefault(isManualTrigger: false, hasMatch: true, hasActiveManualOverride: true)
    check(!r, "A match is handled by the apply path, not the fallback")
}

// ============================================================================
// MARK: - Test: updateSettings on Dead AU (Bug 4)
// ============================================================================

section("updateSettings on Dead AU (Bug 4)")

// Positive: Valid AU + non-flat → applied, not bypassed
do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let result = updateSettingsPure(eqAUExists: true, isRunning: true, settings: eq)
    check(result.applied, "Valid AU + non-flat → applied")
    check(!result.bypassed, "Non-flat EQ → not bypassed")
}

// Positive: Valid AU + flat → applied and bypassed
do {
    let result = updateSettingsPure(eqAUExists: true, isRunning: true, settings: .flat)
    check(result.applied, "Valid AU + flat → applied")
    check(result.bypassed, "Flat EQ → bypassed")
}

// Regression (Bug 4): nil AU → not applied (silent failure)
do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let result = updateSettingsPure(eqAUExists: false, isRunning: true, settings: eq)
    check(!result.applied, "nil AU → not applied (silent failure)")
}

// Negative: AU exists but not running → still applied (guard only checks AU existence)
do {
    let result = updateSettingsPure(eqAUExists: true, isRunning: false, settings: .flat)
    check(result.applied, "AU exists even if not running → applied (matches production behavior)")
}

// ============================================================================
// MARK: - Test: NightMode start==end Semantics (Bug 17)
// ============================================================================

section("NightMode start==end Semantics (Bug 17)")

// Regression (Bug 17): start==end at 10:00 → never active
do {
    var config = NightModeConfig.default
    config.isEnabled = true
    config.startHour = 10; config.startMinute = 0
    config.endHour = 10; config.endMinute = 0
    // Test at 10:00 — start==end means always-on (24h)
    let at10 = makeTime(hour: 10, minute: 0)
    check(config.isInQuietHours(now: at10), "start==end at 10:00, checked at 10:00 → ACTIVE (always-on 24h)")
    // Test at 15:00
    let at15 = makeTime(hour: 15, minute: 0)
    check(config.isInQuietHours(now: at15), "start==end at 10:00, checked at 15:00 → ACTIVE (always-on 24h)")
    // Test at 03:00
    let at3 = makeTime(hour: 3, minute: 0)
    check(config.isInQuietHours(now: at3), "start==end at 10:00, checked at 03:00 → ACTIVE (always-on 24h)")
}

// Regression (Bug 17 fix): start==end at 00:00 → always active (24h)
do {
    var config = NightModeConfig.default
    config.isEnabled = true
    config.startHour = 0; config.startMinute = 0
    config.endHour = 0; config.endMinute = 0
    let atMidnight = makeTime(hour: 0, minute: 0)
    check(config.isInQuietHours(now: atMidnight), "start==end at 00:00 → ACTIVE (always-on 24h)")
}

// Regression (Bug 17 fix): start==end at 23:59 → always active
do {
    var config = NightModeConfig.default
    config.isEnabled = true
    config.startHour = 23; config.startMinute = 59
    config.endHour = 23; config.endMinute = 59
    let at2359 = makeTime(hour: 23, minute: 59)
    check(config.isInQuietHours(now: at2359), "start==end at 23:59 → ACTIVE (always-on 24h)")
}

// Positive: Minimal range 10:00-10:01 → active for 1 minute
do {
    var config = NightModeConfig.default
    config.isEnabled = true
    config.startHour = 10; config.startMinute = 0
    config.endHour = 10; config.endMinute = 1
    let at1000 = makeTime(hour: 10, minute: 0)
    check(config.isInQuietHours(now: at1000), "10:00-10:01 at 10:00 → active")
    let at1001 = makeTime(hour: 10, minute: 1)
    check(!config.isInQuietHours(now: at1001), "10:00-10:01 at 10:01 → NOT active (end exclusive)")
}

// Positive: Near-full day 00:00-23:59
do {
    var config = NightModeConfig.default
    config.isEnabled = true
    config.startHour = 0; config.startMinute = 0
    config.endHour = 23; config.endMinute = 59
    check(config.isInQuietHours(now: makeTime(hour: 12, minute: 0)), "00:00-23:59 at noon → active")
    check(config.isInQuietHours(now: makeTime(hour: 0, minute: 0)), "00:00-23:59 at midnight → active")
    check(!config.isInQuietHours(now: makeTime(hour: 23, minute: 59)), "00:00-23:59 at 23:59 → NOT active (end exclusive)")
}

// Negative: Disabled → never active regardless of range
do {
    var config = NightModeConfig.default
    config.isEnabled = false
    config.startHour = 0; config.startMinute = 0
    config.endHour = 23; config.endMinute = 59
    check(!config.isInQuietHours(now: makeTime(hour: 12, minute: 0)), "disabled → not active even in range")
}

// ============================================================================
// MARK: - Test: isSystemDefault String Comparison (Bug 15)
// ============================================================================

section("isSystemDefault String Comparison (Bug 15)")

// Positive: Stored flag set to true
do {
    let p = Profile(id: UUID(), name: "System Default", iconName: "speaker.wave.2", triggerDeviceIDs: [],
                    publicOutputPriority: [], publicInputPriority: [],
                    privateOutputPriority: [], privateInputPriority: [],
                    preferredMode: .public, isSystemDefault: true)
    check(p.isSystemDefault, "isSystemDefault: true → isSystemDefault true")
}

// Negative: Flag defaults to false
do {
    let p = Profile(id: UUID(), name: "System Default", iconName: "speaker.wave.2", triggerDeviceIDs: [],
                    publicOutputPriority: [], publicInputPriority: [],
                    privateOutputPriority: [], privateInputPriority: [],
                    preferredMode: .public)
    check(!p.isSystemDefault, "isSystemDefault defaults to false even if name matches")
}

// Negative: Regular profile
do {
    let p = Profile(id: UUID(), name: "Home Studio", iconName: "speaker.wave.2", triggerDeviceIDs: [],
                    publicOutputPriority: [], publicInputPriority: [],
                    privateOutputPriority: [], privateInputPriority: [],
                    preferredMode: .public)
    check(!p.isSystemDefault, "Regular profile → NOT isSystemDefault")
}

// Negative: Flag false even with matching name
do {
    let p = Profile(id: UUID(), name: "system default", iconName: "speaker.wave.2", triggerDeviceIDs: [],
                    publicOutputPriority: [], publicInputPriority: [],
                    privateOutputPriority: [], privateInputPriority: [],
                    preferredMode: .public, isSystemDefault: false)
    check(!p.isSystemDefault, "isSystemDefault: false → NOT isSystemDefault regardless of name")
}

// ============================================================================
// MARK: - Test: EQ Bypass Amplitude Discontinuity (Bug 9)
// ============================================================================

section("EQ Bypass Amplitude Discontinuity (Bug 9)")

// Positive: Flat EQ → no discontinuity
do {
    let jump = eqBypassGainJump(bands: EQSettings.flat.bands, preamp: 0)
    checkApprox(jump, 0.0, tol: 0.01, "Flat EQ → zero gain jump on bypass")
}

// Regression (Bug 9): Non-flat EQ with +6dB band → 6dB jump
do {
    var bands = EQSettings.flat.bands
    bands[3].gain = 6.0
    let jump = eqBypassGainJump(bands: bands, preamp: 0)
    checkApprox(jump, 6.0, tol: 0.01, "+6dB band → 6dB discontinuity on bypass toggle")
}

// Regression (Bug 9): Preamp adds to discontinuity
do {
    var bands = EQSettings.flat.bands
    bands[3].gain = 6.0
    let jump = eqBypassGainJump(bands: bands, preamp: 3.0)
    checkApprox(jump, 9.0, tol: 0.01, "+6dB band + 3dB preamp → 9dB jump")
}

// Positive: Threshold boundary (below isFlat threshold)
do {
    var bands = EQSettings.flat.bands
    bands[0].gain = 0.005
    let jump = eqBypassGainJump(bands: bands, preamp: 0)
    check(jump < 0.01, "0.005dB band → negligible jump")
}

// Negative: All bands at -12dB → 12dB jump
do {
    var bands = EQSettings.flat.bands
    for i in 0..<bands.count { bands[i].gain = -12.0 }
    let jump = eqBypassGainJump(bands: bands, preamp: 0)
    checkApprox(jump, 12.0, tol: 0.01, "All bands at -12dB → 12dB jump on bypass")
}

// ============================================================================
// MARK: - Test: Sample Rate Default Fallback (Bug 11)
// ============================================================================

section("Sample Rate Default Fallback (Bug 11)")

// Positive: Valid rate passes through
do {
    checkEqual(resolveSampleRate(queryResult: 44100), 44100.0, "Valid rate 44100 → 44100")
    checkEqual(resolveSampleRate(queryResult: 96000), 96000.0, "Valid rate 96000 → 96000")
    checkEqual(resolveSampleRate(queryResult: 48000), 48000.0, "Valid rate 48000 → 48000")
}

// Regression (Bug 11): nil → falls back to 48000 silently
do {
    checkEqual(resolveSampleRate(queryResult: nil), 48000.0, "nil query → 48000 default (silent fallback)")
}

// Negative: Zero rate passes through (no validation)
do {
    checkEqual(resolveSampleRate(queryResult: 0), 0.0, "Zero rate → passes through (no validation)")
}

// Positive: Custom fallback
do {
    checkEqual(resolveSampleRate(queryResult: nil, fallback: 44100), 44100.0, "nil with custom fallback → 44100")
}

// ============================================================================
// MARK: - Test: Hardcoded Stereo Channel Count (Bug 12)
// ============================================================================

section("Hardcoded Stereo Channel Count (Bug 12)")

// Regression (Bug 12): Always returns 2 regardless of device
do {
    checkEqual(resolveChannelCount(deviceChannels: 1), 2, "Mono device (1 ch) → hardcoded 2")
    checkEqual(resolveChannelCount(deviceChannels: 2), 2, "Stereo device (2 ch) → hardcoded 2")
    checkEqual(resolveChannelCount(deviceChannels: 8), 2, "Multi-channel device (8 ch) → hardcoded 2")
    checkEqual(resolveChannelCount(deviceChannels: nil), 2, "Unknown device (nil ch) → hardcoded 2")
}

// ============================================================================
// MARK: - Level Meter RMS (F7)
// ============================================================================

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
    return sqrtf(sumSquares / Float(samples.count))
}

section("Level Meter RMS (F7)")

// RMS of silence → 0
do {
    let silence = [Float](repeating: 0, count: 1024)
    checkEqual(computeRMS(silence), Float(0), "RMS of silence is 0")
}

// RMS of full-scale sine → ~0.707
do {
    let sineWave = (0..<1024).map { Float(sin(Double($0) * 2.0 * .pi / 1024.0)) }
    let rms = computeRMS(sineWave)
    let expected: Float = 1.0 / sqrtf(2.0) // 0.7071...
    check(abs(rms - expected) < 0.01, "RMS of full-scale sine ≈ 0.707 (got \(rms))")
}

// RMS of DC offset 1.0 → 1.0
do {
    let dc = [Float](repeating: 1.0, count: 1024)
    checkEqual(computeRMS(dc), Float(1.0), "RMS of DC 1.0 is 1.0")
}

// Level clamped to 0-1
do {
    let loud = [Float](repeating: 2.0, count: 1024)
    let rms = computeRMS(loud)
    let clamped = min(rms, 1.0)
    checkEqual(clamped, Float(1.0), "Level clamped to 1.0 for loud signal (raw RMS=\(rms))")
}

// Empty input → 0
do {
    checkEqual(computeRMS([]), Float(0), "RMS of empty input is 0")
}

// ============================================================================
// MARK: - Results
// ============================================================================

print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("  RESULTS: \(passedTests)/\(totalTests) passed, \(failedTests) failed")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

if failedTests > 0 {
    print("❌ SOME TESTS FAILED")
    exit(1)
} else {
    print("✅ ALL TESTS PASSED")
    exit(0)
}
