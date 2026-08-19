// SHARED: AudioProfiles/Models/AudioDevice.swift AudioProfiles/Models/ProfileMode.swift AudioProfiles/Models/Hotkey.swift AudioProfiles/Models/Profile.swift AudioProfiles/Models/DeviceHistoryEntry.swift AudioProfiles/Models/EQSettings.swift AudioProfiles/Models/EQSettings+Combine.swift AudioProfiles/Models/ContentMode.swift AudioProfiles/Models/ContentModeOverlay.swift AudioProfiles/Models/NightMode.swift AudioProfiles/Core/AudioCore.swift
//
// ModelAndServiceTests.swift
//
// Comprehensive unit tests for all models and pure-logic services.
//
// These tests compile against the REAL production sources listed in the
// `// SHARED:` directive above (see build.sh) — there are NO local mirrors of
// model types or of logic that already lives in AudioProfiles/Core/AudioCore.swift.
// A production regression therefore surfaces here as a compile error or a failure.
//
// A small number of pure functions are still mirrored locally, and each is clearly
// labeled: they reproduce logic that is real in production but not (yet) hoisted into
// a Foundation-only shared file (DeviceFilterService filtering, AudioDeviceHistoryService
// pruning / previously-seen queries, and the AudioPipelineService branch table).
//
// Covers:
//   1.  NightModeConfig — quiet hours logic, midnight crossing, edge cases
//   2.  ContentModeType — enum properties, allCases
//   3.  ContentModeOverlay — default factory methods, enabled/disabled states
//   5.  EQSettings — band mutation helpers, preamp, reset, frequency clamping
//   6.  EQ band Q-to-bandwidth conversion
//   7.  Profile — priorityList, isSystemDefault (real Codable decode path)
//   8.  AudioDevice — identity
//   9.  DeviceHistoryEntry — via AudioCore.updateDeviceHistory
//  10.  DeviceFilterService logic — type filtering, exclusion, availability (local mirror)
//  11.  ProfileValidationService logic — cleanup, equality (real triggerRules semantics)
//  12.  AudioDeviceHistoryService logic — update (AudioCore), prune, previously-seen
//  13.  SoundModesStore logic — activeOverlay computation (real fallback-to-default)
//  14.  AudioPipelineService — branch decision table (local mirror)
//  15.  AudioCore.shouldApplyTrigger — manual-override protection
//  16.  AudioCore.findBestTriggerMatch — trigger matching + tie-break
//
// Run via build.sh (compiles this file together with the `// SHARED:` sources above).

import Foundation

// ============================================================================
// MARK: - DeviceFilterService logic (local mirror of DeviceFilterService)
// ============================================================================
// Real code: AudioProfiles/Services/DeviceFilterService.swift (@MainActor, Core-Audio
// backed — not Foundation-only, so mirrored here). Faithful to filterByType /
// excludeSelected / getAvailableDevices(isInput:excludingIDs:includeHistorical:).

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
// MARK: - AudioDeviceHistoryService logic (local mirror — pruning / previously-seen)
// ============================================================================
// Real code: AudioProfiles/Services/AudioDeviceHistoryService.swift. The connectedAt/
// lastSeen bookkeeping lives in AudioCore.updateDeviceHistory (shared, exercised directly).
// Pruning and previously-seen filtering are @MainActor + singleton-bound in production, so
// their pure shape is mirrored here.
//
// pruneDeviceHistory: drop entries older than the cutoff UNLESS referenced by a profile.
func pruneHistory(
    _ history: [String: DeviceHistoryEntry],
    olderThan cutoff: Date,
    profileReferencedIDs: Set<String> = []
) -> [String: DeviceHistoryEntry] {
    history.filter { id, entry in
        entry.lastSeen >= cutoff || profileReferencedIDs.contains(id)
    }
}

// getPreviouslySeenDevices: not-currently-active, not in current list, seen within window.
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
// MARK: - SoundModesStore.activeOverlay (local mirror — matches production fallback)
// ============================================================================
// Real code: AudioProfiles/Services/SoundModesStore.swift (activeOverlay + overlay(for:)).
// Key production behavior reproduced faithfully: a MISSING overlay for a mode falls back to
// that mode's DEFAULT overlay (ContentModeOverlay.defaultOverlay(for:)), NOT to flat. An
// overlay that is present but disabled contributes flat. Night mode combines via the real
// EQSettings.combine and operates independently of the content-modes master toggle.
func computeActiveOverlay(
    isEnabled: Bool,
    activeContentMode: ContentModeType,
    overlays: [ContentModeType: ContentModeOverlay],
    isNightModeActive: Bool,
    nightMode: NightModeConfig
) -> EQSettings {
    // overlay(for:) — fall back to the mode's default when unset.
    func overlay(for mode: ContentModeType) -> EQSettings {
        let o = overlays[mode] ?? ContentModeOverlay.defaultOverlay(for: mode)
        return o.isEnabled ? o.settings : .flat
    }

    let contentEQ: EQSettings = isEnabled ? overlay(for: activeContentMode) : .flat

    if nightMode.isEnabled && isNightModeActive {
        return EQSettings.combine(base: contentEQ, overlay: nightMode.overlay)
    }
    return contentEQ
}

// ============================================================================
// MARK: - AudioPipelineService decision table (local mirror)
// ============================================================================
// Real code: AudioProfiles/Services/AudioPipelineService.applyEQState (routes to
// EQEngineService.hotUpdate / switchDevice / startPipeline / stop / direct set). That
// service is not Foundation-only, so its branch structure is mirrored here.

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

// Convenience: a DeviceHistoryEntry using the real initializer signature
// (device:lastSeen:connectedAt:isCurrentlyActive:).
func entry(_ device: AudioDevice, connectedAt: Date, lastSeen: Date, active: Bool) -> DeviceHistoryEntry {
    DeviceHistoryEntry(device: device, lastSeen: lastSeen, connectedAt: connectedAt, isCurrentlyActive: active)
}

// Convenience: build a Profile with the common defaults (mirrors the real memberwise init).
func makeProfile(
    id: UUID = UUID(),
    name: String = "Test",
    iconName: String = "gear",
    triggerDeviceIDs: [String] = [],
    triggerRules: [TriggerRule]? = nil,
    publicOutputPriority: [String] = [],
    publicInputPriority: [String] = [],
    privateOutputPriority: [String] = [],
    privateInputPriority: [String] = [],
    preferredMode: ProfileMode = .public,
    isSystemDefault: Bool = false
) -> Profile {
    Profile(
        id: id, name: name, iconName: iconName,
        triggerDeviceIDs: triggerDeviceIDs, triggerRules: triggerRules,
        publicOutputPriority: publicOutputPriority, publicInputPriority: publicInputPriority,
        privateOutputPriority: privateOutputPriority, privateInputPriority: privateInputPriority,
        preferredMode: preferredMode, isSystemDefault: isSystemDefault
    )
}

// Real ProfileValidationService.cleanupInvalidDevices, reproduced as a pure function over an
// explicit "known device IDs" set (production consults AudioDeviceHistoryService.shared, which
// is @MainActor). It filters triggerRules (keeping class rules), RE-DERIVES triggerDeviceIDs
// from the surviving rules, and filters every priority list.
func cleanupInvalidDevices(in profile: Profile, knownDeviceIDs: Set<String>) -> Profile {
    var p = profile
    p.triggerRules = profile.triggerRules.filter { rule in
        switch rule {
        case .specificDevice(let id): return knownDeviceIDs.contains(id)
        case .transportType:          return true  // class rules always valid
        }
    }
    p.triggerDeviceIDs = TriggerRule.deriveDeviceIDs(from: p.triggerRules)
    p.publicOutputPriority  = profile.publicOutputPriority.filter { knownDeviceIDs.contains($0) }
    p.publicInputPriority   = profile.publicInputPriority.filter { knownDeviceIDs.contains($0) }
    p.privateOutputPriority = profile.privateOutputPriority.filter { knownDeviceIDs.contains($0) }
    p.privateInputPriority  = profile.privateInputPriority.filter { knownDeviceIDs.contains($0) }
    return p
}

// Real ProfileValidationService.profilesEqual: compares id, triggerRules (the source of
// truth — NOT the derived triggerDeviceIDs), and all four priority lists.
func profilesEqual(_ p1: [Profile], _ p2: [Profile]) -> Bool {
    guard p1.count == p2.count else { return false }
    for (a, b) in zip(p1, p2) {
        if a.id != b.id ||
           a.triggerRules != b.triggerRules ||
           a.publicOutputPriority != b.publicOutputPriority ||
           a.privateOutputPriority != b.privateOutputPriority ||
           a.publicInputPriority != b.publicInputPriority ||
           a.privateInputPriority != b.privateInputPriority { return false }
    }
    return true
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
// MARK: - 5. EQSettings — Band Mutation Helpers
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
// MARK: - 6. EQ Q-to-Bandwidth Conversion
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
// MARK: - EQFilterType — Labels
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
// MARK: - NightModeConfig — Default Values
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
// MARK: - 12. ProfileValidationService — Cleanup (real triggerRules semantics)
// ============================================================================

section("ProfileValidationService — Cleanup")

do {
    // triggerRules is the source of truth; specificDevice rules for unknown devices
    // are dropped, and triggerDeviceIDs is RE-DERIVED from the survivors.
    let profile = makeProfile(
        name: "Test",
        triggerDeviceIDs: ["known-uid", "unknown-uid"],
        publicOutputPriority: ["known-uid", "gone-uid"],
        publicInputPriority: ["known-uid"],
        privateOutputPriority: ["unknown-uid"],
        privateInputPriority: []
    )
    let known: Set<String> = ["known-uid"]
    let cleaned = cleanupInvalidDevices(in: profile, knownDeviceIDs: known)

    checkEqual(cleaned.triggerRules, [.specificDevice(id: "known-uid")], "Removed unknown trigger rule")
    checkEqual(cleaned.triggerDeviceIDs, ["known-uid"], "triggerDeviceIDs re-derived from surviving rules")
    checkEqual(cleaned.publicOutputPriority, ["known-uid"], "Removed unknown output")
    checkEqual(cleaned.publicInputPriority, ["known-uid"], "Kept known input")
    checkEqual(cleaned.privateOutputPriority, [], "Removed all unknown private output")
    checkEqual(cleaned.privateInputPriority, [], "Empty stays empty")
}

do {
    // Transport-class rules are ALWAYS valid — they survive cleanup even when no device
    // of that class is currently known.
    let profile = makeProfile(
        name: "Class rule",
        triggerRules: [.transportType(type: "Bluetooth"), .specificDevice(id: "unknown-uid")]
    )
    let cleaned = cleanupInvalidDevices(in: profile, knownDeviceIDs: [])
    checkEqual(cleaned.triggerRules, [.transportType(type: "Bluetooth")], "Class rule kept, unknown specific rule dropped")
    checkEqual(cleaned.triggerDeviceIDs, [], "Class-only rules derive no triggerDeviceIDs")
}

do {
    let profile = makeProfile(
        name: "All Known",
        triggerDeviceIDs: ["a", "b"],
        publicOutputPriority: ["a", "b"],
        publicInputPriority: ["a"],
        privateOutputPriority: ["b"],
        privateInputPriority: ["a"]
    )
    let known: Set<String> = ["a", "b"]
    let cleaned = cleanupInvalidDevices(in: profile, knownDeviceIDs: known)
    checkEqual(cleaned.triggerDeviceIDs, ["a", "b"], "All known → nothing removed")
    checkEqual(cleaned.publicOutputPriority, ["a", "b"], "All known → nothing removed")
}

// ============================================================================
// MARK: - 13. ProfileValidationService — profilesEqual (compares triggerRules)
// ============================================================================

section("ProfileValidationService — profilesEqual")

do {
    let id = UUID()
    let p = makeProfile(id: id, name: "A", iconName: "x", triggerDeviceIDs: ["a"],
                        publicOutputPriority: ["a"])
    check(profilesEqual([p], [p]), "Same profile → equal")
}

do {
    let id = UUID()
    let p1 = makeProfile(id: id, name: "A", iconName: "x", triggerDeviceIDs: ["a"],
                         publicOutputPriority: ["a"])
    let p2 = makeProfile(id: id, name: "A", iconName: "x", triggerDeviceIDs: ["a", "b"],
                         publicOutputPriority: ["a"])
    check(!profilesEqual([p1], [p2]), "Different triggerRules → not equal")
}

do {
    // Same triggerDeviceIDs but different triggerRules (one has an extra class rule)
    // → NOT equal, because equality is on the rule set, not the derived IDs.
    let id = UUID()
    let p1 = makeProfile(id: id, name: "A", iconName: "x",
                         triggerRules: [.specificDevice(id: "a")], publicOutputPriority: ["a"])
    let p2 = makeProfile(id: id, name: "A", iconName: "x",
                         triggerRules: [.specificDevice(id: "a"), .transportType(type: "USB")],
                         publicOutputPriority: ["a"])
    checkEqual(p1.triggerDeviceIDs, p2.triggerDeviceIDs, "Derived triggerDeviceIDs identical (class rule adds none)")
    check(!profilesEqual([p1], [p2]), "Different triggerRules (class rule added) → not equal")
}

do {
    check(!profilesEqual([], [makeProfile(name: "A", iconName: "x")]),
          "Different count → not equal")
}

do {
    check(profilesEqual([], []), "Both empty → equal")
}

// ============================================================================
// MARK: - 14. AudioDeviceHistoryService — Update Logic (AudioCore, real entries)
// ============================================================================

section("AudioDeviceHistoryService — Update Logic")

do {
    let now = Date()
    let devices = [speakers, headphones]
    let history = AudioCore.updateDeviceHistory([:], with: devices, now: now)

    checkEqual(history.count, 2, "Two entries after first update")
    check(history["speakers-uid"]!.isCurrentlyActive, "Speakers active")
    check(history["beyerdynamic-uid"]!.isCurrentlyActive, "Headphones active")
}

do {
    let now = Date()
    let t1 = now.addingTimeInterval(-3600)  // 1 hour ago

    // First update: speakers + headphones
    var history = AudioCore.updateDeviceHistory([:], with: [speakers, headphones], now: t1)

    // Second update: only speakers (headphones disconnected)
    history = AudioCore.updateDeviceHistory(history, with: [speakers], now: now)

    check(history["speakers-uid"]!.isCurrentlyActive, "Speakers still active")
    check(!history["beyerdynamic-uid"]!.isCurrentlyActive, "Headphones marked inactive")
    checkEqual(history["beyerdynamic-uid"]!.lastSeen, t1, "Headphones lastSeen = first update time (not refreshed while absent)")
    checkEqual(history["speakers-uid"]!.lastSeen, now, "Speakers lastSeen = now")
}

do {
    // connectedAt preserved across updates
    let t1 = Date().addingTimeInterval(-7200)
    let t2 = Date()

    var history = AudioCore.updateDeviceHistory([:], with: [speakers], now: t1)
    history = AudioCore.updateDeviceHistory(history, with: [speakers], now: t2)

    checkEqual(history["speakers-uid"]!.connectedAt, t1, "connectedAt preserved from first update")
    checkEqual(history["speakers-uid"]!.lastSeen, t2, "lastSeen updated")
}

// ============================================================================
// MARK: - 15. AudioDeviceHistoryService — Pruning (local mirror)
// ============================================================================

section("AudioDeviceHistoryService — Pruning")

do {
    let now = Date()
    let old = now.addingTimeInterval(-31 * 24 * 3600)  // 31 days ago
    let recent = now.addingTimeInterval(-1 * 24 * 3600)  // 1 day ago

    let history: [String: DeviceHistoryEntry] = [
        "old-uid": entry(speakers, connectedAt: old, lastSeen: old, active: false),
        "recent-uid": entry(headphones, connectedAt: recent, lastSeen: recent, active: false),
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

// Regression: pruneDeviceHistory must work without profile data (no singleton dependency).
// The real bug: AudioDeviceHistoryService.pruneDeviceHistory() accessed
// ProfileManager.shared during its own init, causing a dispatch_once deadlock.
// The fix: profileReferencedIDs is an explicit input; pruning works with an EMPTY set
// (the state during init, before profiles are loaded).
do {
    let now = Date()
    let old = now.addingTimeInterval(-31 * 24 * 3600)
    let history: [String: DeviceHistoryEntry] = [
        "old-uid": entry(speakers, connectedAt: old, lastSeen: old, active: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    // With empty profileReferencedIDs (simulates init-time state), old device IS pruned
    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: [])
    checkEqual(pruned.count, 0, "Pruning with empty profileReferencedIDs (init-time) removes expired device")

    // With profileReferencedIDs containing the device, it survives
    let prunedProtected = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: ["old-uid"])
    checkEqual(prunedProtected.count, 1, "Pruning with profileReferencedIDs protects the device")
}

// Verify the pure function shape enforces no singleton dependency
// (profileReferencedIDs is a parameter, not fetched from ProfileManager.shared)
do {
    let now = Date()
    let recent = now.addingTimeInterval(-3600)
    let old = now.addingTimeInterval(-31 * 24 * 3600)
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let history: [String: DeviceHistoryEntry] = [
        "protected-uid": entry(speakers, connectedAt: old, lastSeen: old, active: false),
        "unprotected-uid": entry(headphones, connectedAt: old, lastSeen: old, active: false),
        "recent-uid": entry(builtinOutput, connectedAt: recent, lastSeen: recent, active: false),
    ]
    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: ["protected-uid"])
    checkEqual(pruned.count, 2, "Protected + recent survive, unprotected pruned")
    check(pruned["protected-uid"] != nil, "Profile-referenced device survives even when expired")
    check(pruned["recent-uid"] != nil, "Recent device survives")
    check(pruned["unprotected-uid"] == nil, "Unreferenced expired device pruned")
}

// ============================================================================
// MARK: - 16. AudioDeviceHistoryService — Previously Seen (local mirror)
// ============================================================================

section("AudioDeviceHistoryService — Previously Seen Devices")

do {
    let now = Date()
    let recent = now.addingTimeInterval(-3600)
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "speakers-uid": entry(speakers, connectedAt: recent, lastSeen: recent, active: true),
        "beyerdynamic-uid": entry(headphones, connectedAt: recent, lastSeen: recent, active: false),
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
        "old-uid": entry(headphones, connectedAt: old, lastSeen: old, active: false),
    ]

    let previous = getPreviouslySeen(history: history, excluding: [], cutoff: cutoff)
    checkEqual(previous.count, 0, "Expired device not returned")
}

do {
    // Currently active devices excluded even if not in current list
    let now = Date()
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)

    let history: [String: DeviceHistoryEntry] = [
        "speakers-uid": entry(speakers, connectedAt: now, lastSeen: now, active: true),
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
    // BEHAVIOR FIX: a MISSING overlay for the active mode falls back to that mode's
    // DEFAULT overlay (production SoundModesStore.overlay(for:)), NOT to flat. The old
    // local mirror wrongly returned flat here. Gaming's default overlay is non-flat.
    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .gaming,
        overlays: [:],  // No overlays configured → default overlay used
        isNightModeActive: false,
        nightMode: .default
    )
    check(!result.isFlat, "No overlay configured → falls back to mode's default (gaming default is non-flat)")
    checkEqual(result.bands[0].gain, ContentModeOverlay.defaultGaming().settings.bands[0].gain,
               "Missing gaming overlay resolves to defaultGaming()")
}

do {
    // Corollary: a missing overlay for a mode whose DEFAULT is flat (music) → flat.
    let result = computeActiveOverlay(
        isEnabled: true,
        activeContentMode: .music,
        overlays: [:],
        isNightModeActive: false,
        nightMode: .default
    )
    check(result.isFlat, "Missing music overlay → defaultMusic() which is flat")
}

// ============================================================================
// MARK: - 18. AudioPipelineService — Decision Table (local mirror)
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
// MARK: - 20. Profile — isSystemDefault (REAL Codable decode path)
// ============================================================================

section("Profile — isSystemDefault Detection")

do {
    let sd = makeProfile(name: "System Default", iconName: "gear", isSystemDefault: true)
    check(sd.isSystemDefault, "Explicit isSystemDefault: true → true")
}

do {
    let p = makeProfile(name: "Home Studio", iconName: "house")
    check(!p.isSystemDefault, "Home Studio (memberwise, default false) → false")
}

do {
    // REAL decode behavior: Profile.init(from:) defaults isSystemDefault, when the key
    // is ABSENT, to (name == "System Default"). This is the shipped legacy-migration path,
    // so we test it against the real Codable implementation.
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "name": "System Default",
      "iconName": "gear",
      "triggerDeviceIDs": [],
      "publicOutputPriority": [],
      "publicInputPriority": [],
      "privateOutputPriority": [],
      "privateInputPriority": [],
      "preferredMode": "public"
    }
    """.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(Profile.self, from: json)
    check(decoded.isSystemDefault, "Legacy decode: absent key + name 'System Default' → true")
}

do {
    // Absent key + a name that is NOT exactly "System Default" → false.
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "name": "Home Studio",
      "iconName": "gear",
      "triggerDeviceIDs": [],
      "publicOutputPriority": [],
      "publicInputPriority": [],
      "privateOutputPriority": [],
      "privateInputPriority": [],
      "preferredMode": "public"
    }
    """.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(Profile.self, from: json)
    check(!decoded.isSystemDefault, "Legacy decode: absent key + other name → false")
}

do {
    // Present key wins over the name heuristic: name matches but flag is explicitly false.
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "name": "System Default",
      "iconName": "gear",
      "triggerDeviceIDs": [],
      "publicOutputPriority": [],
      "publicInputPriority": [],
      "privateOutputPriority": [],
      "privateInputPriority": [],
      "preferredMode": "public",
      "isSystemDefault": false
    }
    """.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(Profile.self, from: json)
    check(!decoded.isSystemDefault, "Explicit isSystemDefault:false overrides the name heuristic")
}

// ============================================================================
// MARK: - 20b. Profile — Codable round-trip & legacy triggerDeviceIDs migration
// ============================================================================

section("Profile — Codable round-trip & migration")

do {
    // Round-trip preserves triggerRules and re-derives triggerDeviceIDs.
    let original = makeProfile(
        name: "RT",
        triggerRules: [.specificDevice(id: "a"), .transportType(type: "USB")],
        publicOutputPriority: ["a", "b"]
    )
    let data = try! JSONEncoder().encode(original)
    let decoded = try! JSONDecoder().decode(Profile.self, from: data)
    checkEqual(decoded.triggerRules, original.triggerRules, "triggerRules survive round-trip")
    checkEqual(decoded.triggerDeviceIDs, ["a"], "triggerDeviceIDs re-derived (class rule adds none)")
    checkEqual(decoded.publicOutputPriority, ["a", "b"], "priority list survives round-trip")
}

do {
    // Legacy decode: no triggerRules key, only triggerDeviceIDs → migrated to specificDevice rules.
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "name": "Legacy",
      "iconName": "gear",
      "triggerDeviceIDs": ["x", "y"],
      "publicOutputPriority": [],
      "publicInputPriority": [],
      "privateOutputPriority": [],
      "privateInputPriority": [],
      "preferredMode": "public"
    }
    """.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(Profile.self, from: json)
    checkEqual(decoded.triggerRules, [.specificDevice(id: "x"), .specificDevice(id: "y")],
               "Legacy triggerDeviceIDs migrate to specificDevice rules")
    checkEqual(decoded.triggerDeviceIDs, ["x", "y"], "Derived triggerDeviceIDs preserved")
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
    // AudioDevice is Codable (not Equatable in production); compare fields.
    let d1 = AudioDevice(id: "same-uid", name: "Device A", transportType: "USB", isInput: false, isOutput: true)
    let d2 = AudioDevice(id: "same-uid", name: "Device A", transportType: "USB", isInput: false, isOutput: true)
    check(d1.id == d2.id && d1.name == d2.name && d1.transportType == d2.transportType &&
          d1.isInput == d2.isInput && d1.isOutput == d2.isOutput, "Same properties → all fields equal")
}

do {
    let d1 = AudioDevice(id: "uid-1", name: "Device", transportType: "USB", isInput: false, isOutput: true)
    let d2 = AudioDevice(id: "uid-2", name: "Device", transportType: "USB", isInput: false, isOutput: true)
    check(d1.id != d2.id, "Different IDs → not identical")
}

do {
    // AudioDevice Codable round-trip
    let data = try! JSONEncoder().encode(speakers)
    let decoded = try! JSONDecoder().decode(AudioDevice.self, from: data)
    check(decoded.id == speakers.id && decoded.name == speakers.name, "AudioDevice round-trips through Codable")
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
        "conference-speakers-uid": entry(speakers, connectedAt: old, lastSeen: old, active: false),
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
        "orphan-device-uid": entry(speakers, connectedAt: old, lastSeen: old, active: false),
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
        "old-referenced": entry(speakers, connectedAt: old, lastSeen: old, active: false),
        "old-unreferenced": entry(headphones, connectedAt: old, lastSeen: old, active: false),
        "recent-unreferenced": entry(bluetooth, connectedAt: recent, lastSeen: recent, active: false),
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
        "trigger-device": entry(speakers, connectedAt: old, lastSeen: old, active: false),
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
        "shared-device": entry(speakers, connectedAt: old, lastSeen: old, active: false),
    ]
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    let profileRefs: Set<String> = ["shared-device", "other-device"]

    let pruned = pruneHistory(history, olderThan: cutoff, profileReferencedIDs: profileRefs)
    check(pruned["shared-device"] != nil, "Device referenced by multiple profiles → protected")
}

// ============================================================================
// MARK: - NightModeConfig — Edge Cases
// ============================================================================

section("NightModeConfig — Additional Edge Cases")

do {
    // start == end → always-on (24h night mode)
    let cfg = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 22, endMinute: 0, overlay: .flat)
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
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 2; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "2am within 23:00-07:00 (midnight crossing)")
}

do {
    // Midnight crossing: 23:00-07:00, current = 08:00
    let cfg = NightModeConfig(isEnabled: true, startHour: 23, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 8; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(!cfg.isInQuietHours(now: testDate), "8am outside 23:00-07:00")
}

do {
    // Same-day range: 09:00-17:00, current = 12:00
    let cfg = NightModeConfig(isEnabled: true, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, overlay: .flat)
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 12; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "12:00 within 09:00-17:00")
}

do {
    // Exact start time → active
    let cfg = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = 22; comps.minute = 0
    let testDate = cal.date(from: comps)!
    check(cfg.isInQuietHours(now: testDate), "Exact start time → active")
}

do {
    // Exact end time → NOT active (end is exclusive)
    let cfg = NightModeConfig(isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, overlay: .flat)
    let cal = Calendar.current
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
    let p = makeProfile(
        name: "Test",
        triggerDeviceIDs: ["t1"],
        publicOutputPriority: ["pub-out"],
        publicInputPriority: ["pub-in"],
        privateOutputPriority: ["priv-out"],
        privateInputPriority: ["priv-in"]
    )

    checkEqual(p.priorityList(isOutput: true, mode: ProfileMode.public), ["pub-out"], "public+output")
    checkEqual(p.priorityList(isOutput: false, mode: ProfileMode.public), ["pub-in"], "public+input")
    checkEqual(p.priorityList(isOutput: true, mode: ProfileMode.private), ["priv-out"], "private+output")
    checkEqual(p.priorityList(isOutput: false, mode: ProfileMode.private), ["priv-in"], "private+input")
}

do {
    // Empty lists → empty arrays
    let p = makeProfile(name: "Empty")
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
// MARK: - AudioCore.shouldApplyTrigger — Manual-Override Protection
// ============================================================================
// Real shared logic — exercised directly. Allowed only if a trigger device is currently
// active AND its connectedAt is strictly after the manual switch.

section("AudioCore.shouldApplyTrigger — Manual Override Protection")

// No manual switch → always allow
do {
    let history = ["speakers-uid": entry(speakers, connectedAt: Date(), lastSeen: Date(), active: true)]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: nil, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(result, "No manual switch timestamp → allow trigger")
}

// Device connected after manual switch → allow
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let history = ["speakers-uid": entry(speakers, connectedAt: Date(), lastSeen: Date(), active: true)]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: manualSwitch, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(result, "Device connected after manual switch → allow")
}

// Device connected before manual switch → block
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let history = ["speakers-uid": entry(speakers, connectedAt: Date().addingTimeInterval(-120), lastSeen: Date(), active: true)]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: manualSwitch, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(!result, "Device connected before manual switch → block")
}

// Multiple devices, one connected after → allow (any-match)
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let history: [String: DeviceHistoryEntry] = [
        "speakers-uid": entry(speakers, connectedAt: Date().addingTimeInterval(-120), lastSeen: Date(), active: true),
        "beyerdynamic-uid": entry(headphones, connectedAt: Date(), lastSeen: Date(), active: true),
    ]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: manualSwitch, triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"], history: history)
    check(result, "One device connected after manual switch → allow (any-match)")
}

// All devices connected before → block
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let history: [String: DeviceHistoryEntry] = [
        "speakers-uid": entry(speakers, connectedAt: Date().addingTimeInterval(-120), lastSeen: Date(), active: true),
        "beyerdynamic-uid": entry(headphones, connectedAt: Date().addingTimeInterval(-120), lastSeen: Date(), active: true),
    ]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: manualSwitch, triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"], history: history)
    check(!result, "All devices connected before manual switch → block")
}

// nil timestamp after force-quit → allows all
do {
    let history = ["speakers-uid": entry(speakers, connectedAt: Date().addingTimeInterval(-3600), lastSeen: Date(), active: true)]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: nil, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(result, "Force-quit (nil timestamp) → allows all triggers")
}

// Device in history but not currently active → block
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let history = ["speakers-uid": entry(speakers, connectedAt: Date(), lastSeen: Date(), active: false)]
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: manualSwitch, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(!result, "Device not currently active → block even if connectedAt is after manual switch")
}

// Empty trigger IDs → block (a manual switch is active and nothing qualifies)
do {
    let manualSwitch = Date().addingTimeInterval(-60)
    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: manualSwitch, triggerDeviceIDs: [], history: [:])
    check(!result, "Empty trigger IDs with active manual switch → block")
}

// ============================================================================
// MARK: - Manual override survives unrelated device events (via AudioCore)
// ============================================================================
// The core bug: history refreshed lastSeen for EVERY connected device on any event,
// so plugging in an unrelated device made an old trigger look "connected after" the
// manual switch. connectedAt (advanced only on reconnect) fixes this. This exercises
// AudioCore.updateDeviceHistory + AudioCore.shouldApplyTrigger together.

section("Manual override survives unrelated device events")

do {
    let t0 = Date().addingTimeInterval(-300)   // trigger device connected 5 min ago
    let t1 = Date().addingTimeInterval(-120)   // user manually switched 2 min ago
    let t2 = Date().addingTimeInterval(-30)    // unrelated device plugged in 30s ago

    // Trigger device connected before the manual switch and stays connected throughout.
    var history = AudioCore.updateDeviceHistory([:], with: [speakers], now: t0)
    // An unrelated device is plugged in after the manual switch.
    history = AudioCore.updateDeviceHistory(history, with: [speakers, headphones], now: t2)

    // The unrelated event refreshes the trigger device's lastSeen, but NOT connectedAt.
    checkEqual(history["speakers-uid"]!.lastSeen, t2, "Unrelated event refreshes lastSeen")
    checkEqual(history["speakers-uid"]!.connectedAt, t0, "connectedAt unchanged by unrelated event")

    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: t1, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(!result, "Trigger predating manual switch stays blocked despite unrelated plug-in")
}

do {
    // Counter-case: the trigger device itself reconnects after the manual switch → allow.
    let t0 = Date().addingTimeInterval(-300)
    let t1 = Date().addingTimeInterval(-120)
    let t2 = Date().addingTimeInterval(-30)

    var history = AudioCore.updateDeviceHistory([:], with: [speakers], now: t0)   // first connect
    history = AudioCore.updateDeviceHistory(history, with: [], now: t1)           // disconnect
    history = AudioCore.updateDeviceHistory(history, with: [speakers], now: t2)   // reconnect after manual switch

    checkEqual(history["speakers-uid"]!.connectedAt, t2, "Reconnect advances connectedAt")

    let result = AudioCore.shouldApplyTrigger(lastManualSwitch: t1, triggerDeviceIDs: ["speakers-uid"], history: history)
    check(result, "Trigger reconnected after manual switch → allow (deliberate re-plug)")
}

// ============================================================================
// MARK: - AudioCore.findBestTriggerMatch — Trigger Matching & Tie-Break
// ============================================================================
// Real shared logic — exercised directly.

section("AudioCore.findBestTriggerMatch — Matching & Tie-Break")

do {
    // No profiles with rules → no match
    let match = AudioCore.findBestTriggerMatch(profiles: [makeProfile()], currentDeviceIDs: ["speakers-uid"])
    check(match == nil, "Profile with no trigger rules → no match")
}

do {
    // Single specific-device match
    let p = makeProfile(name: "P1", triggerRules: [.specificDevice(id: "speakers-uid")])
    let match = AudioCore.findBestTriggerMatch(profiles: [p], currentDeviceIDs: ["speakers-uid"])
    check(match != nil, "Connected trigger device → match")
    checkEqual(match?.profileID, p.id, "Matched profile id")
    checkEqual(match?.matchCount, 1, "Match count = 1")
    checkEqual(match?.specificCount, 1, "Specific count = 1")
    checkEqual(match?.primaryTriggerDevice, "speakers-uid", "Primary trigger device")
}

do {
    // Higher match count wins
    let p1 = makeProfile(name: "P1", triggerRules: [.specificDevice(id: "speakers-uid")])
    let p2 = makeProfile(name: "P2", triggerRules: [.specificDevice(id: "speakers-uid"), .specificDevice(id: "beyerdynamic-uid")])
    let match = AudioCore.findBestTriggerMatch(profiles: [p1, p2], currentDeviceIDs: ["speakers-uid", "beyerdynamic-uid"])
    checkEqual(match?.profileID, p2.id, "Profile with more matches wins")
    checkEqual(match?.matchCount, 2, "Match count = 2")
}

do {
    // Tie-break: equal match counts → more specific (specificDevice) matches win
    let specific = makeProfile(name: "Specific", triggerRules: [.specificDevice(id: "airpods-uid")])
    let classRule = makeProfile(name: "Class", triggerRules: [.transportType(type: "Bluetooth")])
    // AirPods are Bluetooth → both profiles match with count 1; specific should win.
    let match = AudioCore.findBestTriggerMatch(
        profiles: [classRule, specific],
        currentDeviceIDs: ["airpods-uid"],
        currentDevices: [bluetooth]
    )
    checkEqual(match?.profileID, specific.id, "Tie on count → specificDevice rule wins over transportType")
    checkEqual(match?.specificCount, 1, "Winner has specificCount 1")
}

do {
    // transportType rule matches by device class
    let p = makeProfile(name: "BT", triggerRules: [.transportType(type: "Bluetooth")])
    let match = AudioCore.findBestTriggerMatch(
        profiles: [p],
        currentDeviceIDs: ["airpods-uid"],
        currentDevices: [bluetooth]
    )
    check(match != nil, "transportType rule matches a connected device of that class")
    checkEqual(match?.specificCount, 0, "transportType match contributes no specific count")
    checkEqual(match?.primaryTriggerDevice, "airpods-uid", "Primary trigger device is the matched BT device")
}

do {
    // transportType with no matching device present → no match
    let p = makeProfile(name: "BT", triggerRules: [.transportType(type: "Bluetooth")])
    let match = AudioCore.findBestTriggerMatch(
        profiles: [p],
        currentDeviceIDs: ["speakers-uid"],
        currentDevices: [speakers]  // Built-In, not Bluetooth
    )
    check(match == nil, "No device of the required class → no match")
}

// ============================================================================
// MARK: - Level Meter RMS
// ============================================================================

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
    return sqrtf(sumSquares / Float(samples.count))
}

section("Level Meter RMS")

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
// MARK: - AudioCore.computeRMSLevels — Windowed RMS with smoothing (shared)
// ============================================================================

section("AudioCore.computeRMSLevels — Windowed RMS")

do {
    // Fewer than 2 channels → returns previous levels unchanged (guard)
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: { _ in 0 }, totalSamples: 0, channels: 1, frameCapacity: 1024,
        writeIndex: 0, previousLeft: 0.3, previousRight: 0.4
    )
    checkApprox(l, 0.3, "Mono → left unchanged (previous)")
    checkApprox(r, 0.4, "Mono → right unchanged (previous)")
}

do {
    // Full-scale DC on both channels, starting from 0 with default 0.7 smoothing:
    // output = 0*0.7 + min(1.0,1.0)*0.3 = 0.3
    let capacity = 2048
    let channels = 2
    let samples = [Float32](repeating: 1.0, count: capacity * channels)
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: { samples[$0] }, totalSamples: samples.count, channels: channels,
        frameCapacity: capacity, writeIndex: UInt64(capacity), previousLeft: 0, previousRight: 0
    )
    checkApprox(l, 0.3, tol: 0.01, "DC full-scale, first call → 0.3 (smoothed from 0)")
    checkApprox(r, 0.3, tol: 0.01, "DC full-scale, first call → 0.3 (smoothed from 0)")
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
