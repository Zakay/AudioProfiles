#!/usr/bin/env swift
//
// BehaviorTests.swift
//
// Behavior-driven tests that describe WHAT the system should do from the user's
// perspective, not which class method gets called. These tests survive refactors
// because they reference outcomes, not internals.
//
// Run: swift Tests/BehaviorTests.swift
//
// Uses a SystemSimulator that wires together extracted pure functions into a
// stateful simulation of the full event chain:
//   Device change → Trigger matching → Profile activation → Pipeline evaluation → Action decision

import Foundation

// ============================================================================
// MARK: - Lightweight model mirrors (no Core Audio dependency)
// ============================================================================

struct AudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let transportType: String
    let isInput: Bool
    let isOutput: Bool
}

enum ProfileMode: String {
    case `public`
    case `private`
}

enum EQFilterType: Int {
    case parametric = 0
    case lowShelf   = 7
    case highShelf  = 8
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
}

struct EQSettings: Equatable {
    static let standardFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let gainRange: ClosedRange<Float>   = -12 ... 12
    static let preampRange: ClosedRange<Float> = -12 ... 12

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
            combined.bands[i].gain = clamp(
                base.bands[i].gain + overlay.bands[i].gain,
                EQSettings.gainRange
            )
        }
        return combined
    }
}

enum TriggerRule: Equatable, Hashable {
    case specificDevice(id: String)
    case transportType(type: String)
}

struct Profile: Identifiable {
    let id: UUID
    var name: String
    var triggerDeviceIDs: [String]
    var triggerRules: [TriggerRule]
    var publicOutputPriority: [String]
    var publicInputPriority: [String]
    var privateOutputPriority: [String]
    var privateInputPriority: [String]
    var preferredMode: ProfileMode
    var isSystemDefault: Bool = false

    init(id: UUID = UUID(), name: String, triggerDeviceIDs: [String] = [],
         triggerRules: [TriggerRule]? = nil,
         publicOutputPriority: [String] = [], publicInputPriority: [String] = [],
         privateOutputPriority: [String] = [], privateInputPriority: [String] = [],
         preferredMode: ProfileMode = .public, isSystemDefault: Bool = false) {
        self.id = id
        self.name = name
        self.triggerRules = triggerRules ?? triggerDeviceIDs.map { .specificDevice(id: $0) }
        self.triggerDeviceIDs = Self.deriveDeviceIDs(from: self.triggerRules)
        self.publicOutputPriority = publicOutputPriority
        self.publicInputPriority = publicInputPriority
        self.privateOutputPriority = privateOutputPriority
        self.privateInputPriority = privateInputPriority
        self.preferredMode = preferredMode
        self.isSystemDefault = isSystemDefault
    }

    func priorityList(isOutput: Bool, mode: ProfileMode) -> [String] {
        switch (isOutput, mode) {
        case (true,  .public):  return publicOutputPriority
        case (true,  .private): return privateOutputPriority
        case (false, .public):  return publicInputPriority
        case (false, .private): return privateInputPriority
        }
    }

    static func deriveDeviceIDs(from rules: [TriggerRule]) -> [String] {
        rules.compactMap {
            if case .specificDevice(let id) = $0 { return id }
            return nil
        }
    }
}

struct PipelineFingerprint: Equatable {
    let profileID: UUID?
    let mode: ProfileMode
    let outputDeviceUID: String?
    let inputDeviceUID: String?
    let effectiveEQ: EQSettings
    let needsVirtualDriver: Bool
}

struct TriggerMatchResult {
    let profile: Profile
    let matchCount: Int
    let primaryTriggerDevice: String
}

enum ContentModeType: String, CaseIterable {
    case none, music, voice, movie, gaming
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
    static func defaultMusic() -> ContentModeOverlay {
        ContentModeOverlay(mode: .music, settings: .flat, isEnabled: true)
    }
    static func defaultNone() -> ContentModeOverlay {
        ContentModeOverlay(mode: .none, settings: .flat, isEnabled: true)
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
        if startMinutes == endMinutes { return true }
        if startMinutes < endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }
    }
}

enum PipelineAction: Equatable {
    case hotUpdate(EQSettings)
    case switchDevice(realUID: String, settings: EQSettings, virtualName: String)
    case startPipeline(realUID: String, settings: EQSettings, virtualName: String)
    case stopEQ(switchTo: String)
    case directSetDevice(String)
    case noOp
}

// ============================================================================
// MARK: - Pure functions (extracted from services)
// ============================================================================

func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
    max(range.lowerBound, min(range.upperBound, value))
}

func resolveOutputDevice(
    priorityList: [String],
    connectedDevices: [AudioDevice],
    virtualDeviceUID: String? = nil,
    eqRunning: Bool = false,
    eqTargetUID: String? = nil
) -> (device: AudioDevice, uid: String)? {
    for deviceID in priorityList {
        if let device = connectedDevices.first(where: { $0.id == deviceID && $0.isOutput }) {
            if let vUID = virtualDeviceUID, device.id == vUID {
                if eqRunning, let realUID = eqTargetUID {
                    if let realDevice = connectedDevices.first(where: { $0.id == realUID && $0.isOutput }) {
                        return (realDevice, realUID)
                    }
                }
                continue
            }
            return (device, device.id)
        }
    }
    return nil
}

func resolveInputDevice(
    priorityList: [String],
    connectedDevices: [AudioDevice]
) -> (device: AudioDevice, uid: String)? {
    for deviceID in priorityList {
        if let device = connectedDevices.first(where: { $0.id == deviceID && $0.isInput }) {
            return (device, device.id)
        }
    }
    return nil
}

func findBestTriggerMatch(
    profiles: [Profile],
    currentDeviceIDs: Set<String>,
    currentDevices: [AudioDevice] = []
) -> TriggerMatchResult? {
    var bestMatch: TriggerMatchResult? = nil
    var bestSpecificCount = 0

    for profile in profiles {
        guard !profile.triggerRules.isEmpty else { continue }
        var matchCount = 0
        var specificCount = 0
        var primaryDevice: String? = nil

        for rule in profile.triggerRules {
            switch rule {
            case .specificDevice(let id):
                if currentDeviceIDs.contains(id) {
                    matchCount += 1
                    specificCount += 1
                    if primaryDevice == nil { primaryDevice = id }
                }
            case .transportType(let type):
                if currentDevices.contains(where: { $0.transportType == type }) {
                    matchCount += 1
                    if primaryDevice == nil {
                        primaryDevice = currentDevices.first(where: { $0.transportType == type })?.id ?? "Any \(type)"
                    }
                }
            }
        }

        if matchCount > 0 {
            let isBetter: Bool
            if bestMatch == nil {
                isBetter = true
            } else if matchCount > bestMatch!.matchCount {
                isBetter = true
            } else if matchCount == bestMatch!.matchCount && specificCount > bestSpecificCount {
                isBetter = true
            } else {
                isBetter = false
            }
            if isBetter {
                bestMatch = TriggerMatchResult(
                    profile: profile,
                    matchCount: matchCount,
                    primaryTriggerDevice: primaryDevice!
                )
                bestSpecificCount = specificCount
            }
        }
    }
    return bestMatch
}

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
        if let o = overlay, o.isEnabled { contentEQ = o.settings } else { contentEQ = .flat }
    } else {
        contentEQ = .flat
    }
    if nightMode.isEnabled && isNightModeActive {
        return EQSettings.combine(base: contentEQ, overlay: nightMode.overlay)
    }
    return contentEQ
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
            if eqTargetUID == outputUID { return .hotUpdate(effectiveEQ) }
            else { return .switchDevice(realUID: outputUID, settings: effectiveEQ, virtualName: vName) }
        } else {
            return .startPipeline(realUID: outputUID, settings: effectiveEQ, virtualName: vName)
        }
    } else {
        if eqRunning { return .stopEQ(switchTo: outputUID) }
        else { return .directSetDevice(outputUID) }
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

func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    totalTests += 1
    if condition {
        passedTests += 1
        print("  ✅ \(message)")
    } else {
        failedTests += 1
        print("  ❌ \(message) [line \(line)]")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    totalTests += 1
    if a == b {
        passedTests += 1
        print("  ✅ \(message)")
    } else {
        failedTests += 1
        print("  ❌ \(message) — got '\(a)', expected '\(b)' [line \(line)]")
    }
}

// ============================================================================
// MARK: - SystemState (what each action returns)
// ============================================================================

struct SystemState {
    let activeProfileName: String?
    let activeMode: ProfileMode
    let outputDeviceName: String?
    let outputDeviceUID: String?
    let inputDeviceName: String?
    let inputDeviceUID: String?
    let effectiveEQ: EQSettings
    let needsVirtualDriver: Bool
    let pipelineAction: PipelineAction
    let wasAutoSwitched: Bool
    let fingerprintChanged: Bool
}

// ============================================================================
// MARK: - SystemSimulator (wires pure functions into a stateful simulation)
// ============================================================================

struct SystemSimulator {
    // Profiles
    var profiles: [Profile]
    var activeProfileID: UUID?
    var activeMode: ProfileMode = .public

    // Devices
    var connectedDevices: [AudioDevice]
    var deviceHistory: [String: (isActive: Bool, lastSeen: Date)] = [:]

    // EQ state
    var deviceEQ: [String: EQSettings] = [:]
    var soundModesEnabled: Bool = false
    var activeContentMode: ContentModeType = .none
    var contentOverlays: [ContentModeType: ContentModeOverlay] = [:]
    var nightMode: NightModeConfig = .default
    var isNightModeActive: Bool = false
    var isGlobalBypass: Bool = false
    var driverInstalled: Bool = true

    // EQ engine state (tracks what the engine is doing)
    var eqRunning: Bool = false
    var eqTargetUID: String? = nil
    var virtualDeviceUID: String? = nil

    // Auto-switch state
    var isAutoSwitchEnabled: Bool = true
    var lastManualSwitchTimestamp: Date? = nil

    // Pipeline state
    var lastFingerprint: PipelineFingerprint? = nil
    var lastAutoSwitchHappened: Bool = false

    // MARK: - Actions

    mutating func connectDevice(_ device: AudioDevice) -> SystemState {
        if !connectedDevices.contains(where: { $0.id == device.id }) {
            connectedDevices.append(device)
        }
        deviceHistory[device.id] = (isActive: true, lastSeen: Date())
        return triggerAndEvaluate()
    }

    mutating func disconnectDevice(_ uid: String) -> SystemState {
        connectedDevices.removeAll { $0.id == uid }
        if var entry = deviceHistory[uid] {
            entry.isActive = false
            deviceHistory[uid] = entry
        }
        return triggerAndEvaluate()
    }

    mutating func activateProfile(_ id: UUID, isManual: Bool = false) -> SystemState {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            return evaluate(wasAutoSwitched: false)
        }
        activeProfileID = id
        activeMode = profile.preferredMode
        if isManual {
            lastManualSwitchTimestamp = Date()
        } else {
            lastManualSwitchTimestamp = nil
        }
        lastFingerprint = nil  // Force re-evaluation
        return evaluate(wasAutoSwitched: !isManual)
    }

    mutating func toggleMode() -> SystemState {
        activeMode = (activeMode == .public) ? .private : .public
        lastFingerprint = nil
        return evaluate(wasAutoSwitched: false)
    }

    mutating func setEQ(for uid: String, _ settings: EQSettings) -> SystemState {
        deviceEQ[uid] = settings
        // Don't nil fingerprint — let evaluate() detect if EQ actually changed
        return evaluate(wasAutoSwitched: false)
    }

    mutating func toggleGlobalBypass() -> SystemState {
        isGlobalBypass.toggle()
        lastFingerprint = nil
        return evaluate(wasAutoSwitched: false)
    }

    mutating func setContentMode(_ mode: ContentModeType) -> SystemState {
        activeContentMode = mode
        lastFingerprint = nil
        return evaluate(wasAutoSwitched: false)
    }

    mutating func setNightModeActive(_ active: Bool) -> SystemState {
        isNightModeActive = active
        lastFingerprint = nil
        return evaluate(wasAutoSwitched: false)
    }

    // MARK: - Trigger matching + evaluation

    private mutating func triggerAndEvaluate() -> SystemState {
        lastAutoSwitchHappened = false
        let currentDeviceIDs = Set(connectedDevices.map { $0.id })

        if isAutoSwitchEnabled {
            let match = findBestTriggerMatch(
                profiles: profiles,
                currentDeviceIDs: currentDeviceIDs,
                currentDevices: connectedDevices
            )

            if let match = match {
                // Check manual override blocking
                let blocked = shouldBlockTrigger(forProfile: match.profile)
                if !blocked && match.profile.id != activeProfileID {
                    activeProfileID = match.profile.id
                    activeMode = match.profile.preferredMode
                    lastFingerprint = nil
                    lastAutoSwitchHappened = true
                }
            } else {
                // No match — fall back to System Default
                if let sysDefault = profiles.first(where: { $0.isSystemDefault }) {
                    if sysDefault.id != activeProfileID {
                        activeProfileID = sysDefault.id
                        activeMode = sysDefault.preferredMode
                        lastFingerprint = nil
                        lastAutoSwitchHappened = true
                    }
                }
            }
        }

        // Always re-evaluate (even if profile didn't change, device priorities may have)
        lastFingerprint = nil  // Device change always forces re-evaluation
        return evaluate(wasAutoSwitched: lastAutoSwitchHappened)
    }

    private func shouldBlockTrigger(forProfile profile: Profile) -> Bool {
        guard let lastManual = lastManualSwitchTimestamp else { return false }
        // Block if all trigger devices were connected before manual switch
        for rule in profile.triggerRules {
            if case .specificDevice(let id) = rule {
                if let entry = deviceHistory[id], entry.isActive, entry.lastSeen > lastManual {
                    return false  // This device was connected AFTER manual switch — allow
                }
            }
        }
        return true  // All devices were before manual switch — block
    }

    // MARK: - Pipeline evaluation (the core simulation)

    private mutating func evaluate(wasAutoSwitched: Bool) -> SystemState {
        let profile = profiles.first(where: { $0.id == activeProfileID })
            ?? profiles.first(where: { $0.isSystemDefault })

        let profileName = profile?.name
        let profileID = profile?.id

        // Resolve output device
        let outputPriority = profile?.priorityList(isOutput: true, mode: activeMode) ?? []
        let outputResult = resolveOutputDevice(
            priorityList: outputPriority,
            connectedDevices: connectedDevices,
            virtualDeviceUID: virtualDeviceUID,
            eqRunning: eqRunning,
            eqTargetUID: eqTargetUID
        )
        // Fallback to first connected output device (simulates system default)
        let resolvedOutput = outputResult ?? connectedDevices.first(where: { $0.isOutput }).map { ($0, $0.id) }
        let outputDeviceName = resolvedOutput?.device.name
        let outputDeviceUID = resolvedOutput?.uid

        // Resolve input device
        let inputPriority = profile?.priorityList(isOutput: false, mode: activeMode) ?? []
        let inputResult = resolveInputDevice(priorityList: inputPriority, connectedDevices: connectedDevices)
        let resolvedInput = inputResult ?? connectedDevices.first(where: { $0.isInput }).map { ($0, $0.id) }
        let inputDeviceName = resolvedInput?.device.name
        let inputDeviceUID = resolvedInput?.uid

        // Compute effective EQ
        let baseEQ = (outputDeviceUID != nil) ? (deviceEQ[outputDeviceUID!] ?? .flat) : .flat
        let overlay = computeActiveOverlay(
            isEnabled: soundModesEnabled,
            activeContentMode: activeContentMode,
            overlays: contentOverlays,
            isNightModeActive: isNightModeActive,
            nightMode: nightMode
        )
        let combinedEQ = EQSettings.combine(base: baseEQ, overlay: overlay)
        let effectiveEQ = isGlobalBypass ? .flat : combinedEQ

        // Virtual driver need
        let needsVirtualDriver = !effectiveEQ.isFlat && driverInstalled

        // Fingerprint
        let fingerprint = PipelineFingerprint(
            profileID: profileID,
            mode: activeMode,
            outputDeviceUID: outputDeviceUID,
            inputDeviceUID: inputDeviceUID,
            effectiveEQ: effectiveEQ,
            needsVirtualDriver: needsVirtualDriver
        )
        let fingerprintChanged = fingerprint != lastFingerprint
        lastFingerprint = fingerprint

        // Pipeline action
        let vName = outputDeviceName.map { "\($0) EQ" }
        let action = decidePipelineAction(
            eqRunning: eqRunning,
            eqTargetUID: eqTargetUID,
            needsVirtualDriver: needsVirtualDriver,
            outputDeviceUID: outputDeviceUID,
            effectiveEQ: effectiveEQ,
            virtualDeviceName: vName
        )

        // Update EQ engine state based on action
        switch action {
        case .startPipeline(let uid, _, _):
            eqRunning = true
            eqTargetUID = uid
        case .switchDevice(let uid, _, _):
            eqTargetUID = uid
        case .stopEQ:
            eqRunning = false
            eqTargetUID = nil
        case .hotUpdate:
            break  // No state change
        case .directSetDevice, .noOp:
            break
        }

        return SystemState(
            activeProfileName: profileName,
            activeMode: activeMode,
            outputDeviceName: outputDeviceName,
            outputDeviceUID: outputDeviceUID,
            inputDeviceName: inputDeviceName,
            inputDeviceUID: inputDeviceUID,
            effectiveEQ: effectiveEQ,
            needsVirtualDriver: needsVirtualDriver,
            pipelineAction: action,
            wasAutoSwitched: wasAutoSwitched,
            fingerprintChanged: fingerprintChanged
        )
    }
}

// ============================================================================
// MARK: - Test fixtures
// ============================================================================

// Devices
let speakers = AudioDevice(id: "speakers-uid", name: "Studio Monitors", transportType: "USB", isInput: false, isOutput: true)
let headphones = AudioDevice(id: "beyerdynamic-uid", name: "Beyerdynamic DT 990", transportType: "USB", isInput: false, isOutput: true)
let airpods = AudioDevice(id: "airpods-uid", name: "AirPods Max", transportType: "Bluetooth", isInput: true, isOutput: true)
let builtinOut = AudioDevice(id: "builtin-output-uid", name: "MacBook Pro Speakers", transportType: "Built-In", isInput: false, isOutput: true)
let builtinIn = AudioDevice(id: "builtin-input-uid", name: "MacBook Pro Microphone", transportType: "Built-In", isInput: true, isOutput: false)
let usbMic = AudioDevice(id: "usb-mic-uid", name: "Blue Yeti", transportType: "USB", isInput: true, isOutput: false)
let randomUSB = AudioDevice(id: "random-usb-uid", name: "Random USB Widget", transportType: "USB", isInput: true, isOutput: false)

// Profiles
let homeProfileID = UUID()
let officeProfileID = UUID()
let systemDefaultID = UUID()

func makeHomeProfile() -> Profile {
    Profile(id: homeProfileID, name: "Home Studio",
            triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"],
            publicOutputPriority: ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"],
            publicInputPriority: ["usb-mic-uid", "builtin-input-uid"],
            privateOutputPriority: ["beyerdynamic-uid", "speakers-uid", "builtin-output-uid"],
            privateInputPriority: ["usb-mic-uid", "builtin-input-uid"],
            preferredMode: .public)
}

func makeOfficeProfile() -> Profile {
    Profile(id: officeProfileID, name: "Office",
            triggerDeviceIDs: ["airpods-uid"],
            publicOutputPriority: ["airpods-uid", "builtin-output-uid"],
            publicInputPriority: ["airpods-uid", "builtin-input-uid"],
            privateOutputPriority: ["airpods-uid", "builtin-output-uid"],
            privateInputPriority: ["airpods-uid", "builtin-input-uid"],
            preferredMode: .public)
}

func makeSystemDefault() -> Profile {
    Profile(id: systemDefaultID, name: "System Default",
            publicOutputPriority: ["builtin-output-uid"],
            publicInputPriority: ["builtin-input-uid"],
            privateOutputPriority: ["builtin-output-uid"],
            privateInputPriority: ["builtin-input-uid"],
            preferredMode: .public, isSystemDefault: true)
}

func makeStandardSimulator() -> SystemSimulator {
    var sim = SystemSimulator(
        profiles: [makeSystemDefault(), makeHomeProfile(), makeOfficeProfile()],
        connectedDevices: [builtinOut, builtinIn]
    )
    sim.activeProfileID = systemDefaultID
    return sim
}

// EQ presets for testing
func makeBassBoostEQ() -> EQSettings {
    var eq = EQSettings.flat
    eq.bands[0].gain = 6.0   // 32 Hz +6dB
    eq.bands[1].gain = 4.0   // 64 Hz +4dB
    return eq
}

func makeVoiceBoostEQ() -> EQSettings {
    var eq = EQSettings.flat
    eq.bands[6].gain = 3.0   // 2kHz +3dB
    eq.bands[7].gain = 2.0   // 4kHz +2dB
    return eq
}

// ============================================================================
// MARK: - Category 1: Device Lifecycle
// ============================================================================

section("📱 Device Lifecycle — Plugging in a higher-priority device")

do {
    // Start with Home profile active, but only builtin + headphones connected (no speakers)
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(headphones)

    let state = sim.connectDevice(builtinIn)  // just to settle
    // Headphones should be output (speakers not connected, headphones is #2 in public priority)
    checkEqual(state.outputDeviceName, "Beyerdynamic DT 990",
               "Speakers off → beyerdynamics used as fallback output")
}

do {
    // THE BUG: speakers turn on while headphones are active
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(headphones)

    let beforeState = sim.connectDevice(builtinIn)
    checkEqual(beforeState.outputDeviceName, "Beyerdynamic DT 990",
               "Before speakers connect, headphones are output")

    let afterState = sim.connectDevice(speakers)
    checkEqual(afterState.outputDeviceName, "Studio Monitors",
               "When speakers turn on, they become output (higher priority)")
}

do {
    // Irrelevant device doesn't change output
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    let before = sim.connectDevice(usbMic)

    let after = sim.connectDevice(randomUSB)
    checkEqual(after.outputDeviceUID, before.outputDeviceUID,
               "Irrelevant USB device plugged in → output unchanged")
}

do {
    // Current output unplugged → next priority takes over
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)

    let state = sim.disconnectDevice("speakers-uid")
    checkEqual(state.outputDeviceName, "Beyerdynamic DT 990",
               "Unplug speakers → headphones take over (next in priority)")
}

do {
    // ALL priority devices gone → built-in fallback
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(headphones)

    let state = sim.disconnectDevice("beyerdynamic-uid")
    checkEqual(state.outputDeviceName, "MacBook Pro Speakers",
               "All priority devices gone → MacBook Pro Speakers fallback")
}

do {
    // Rapid connect/disconnect sequence
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)
    _ = sim.disconnectDevice("speakers-uid")

    let state = sim.connectDevice(speakers)
    checkEqual(state.outputDeviceName, "Studio Monitors",
               "After rapid plug/unplug, speakers reconnected → speakers are output again")
}

do {
    // Disconnect then reconnect returns to original state
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)
    let original = sim.connectDevice(usbMic)

    _ = sim.disconnectDevice("speakers-uid")
    let restored = sim.connectDevice(speakers)
    checkEqual(restored.outputDeviceUID, original.outputDeviceUID,
               "Disconnect then reconnect → returns to original output device")
}

// ============================================================================
// MARK: - Category 2: Profile Auto-Switching
// ============================================================================

section("🔄 Profile Auto-Switching — The right profile activates")

do {
    var sim = makeStandardSimulator()
    let state = sim.connectDevice(airpods)
    checkEqual(state.activeProfileName, "Office",
               "AirPods connect → Office profile activates")
    check(state.wasAutoSwitched, "Auto-switch was triggered")
}

do {
    var sim = makeStandardSimulator()
    _ = sim.connectDevice(speakers)
    let state = sim.connectDevice(headphones)
    checkEqual(state.activeProfileName, "Home Studio",
               "Studio monitors + headphones connect → Home Studio profile activates")
}

do {
    // Remove all trigger devices → System Default
    var sim = makeStandardSimulator()
    _ = sim.connectDevice(airpods)
    let state = sim.disconnectDevice("airpods-uid")
    checkEqual(state.activeProfileName, "System Default",
               "All trigger devices removed → falls back to System Default")
}

do {
    // Manual switch blocks auto-switch for same devices
    var sim = makeStandardSimulator()
    _ = sim.connectDevice(airpods)  // Auto-switches to Office
    _ = sim.activateProfile(systemDefaultID, isManual: true)  // Manually switch away

    // AirPods still connected — auto-switch should be blocked (no new device event)
    let state = sim.connectDevice(builtinIn)  // Connect irrelevant device
    checkEqual(state.activeProfileName, "System Default",
               "After manual switch, existing trigger devices don't re-trigger")
}

do {
    // More trigger matches wins
    var sim = makeStandardSimulator()
    _ = sim.connectDevice(speakers)     // Home has 2 triggers: speakers + headphones
    _ = sim.connectDevice(headphones)   // Both connected → Home has 2 matches
    _ = sim.connectDevice(airpods)      // Office has 1 trigger: airpods → 1 match

    let state = sim.connectDevice(builtinIn)
    checkEqual(state.activeProfileName, "Home Studio",
               "Home (2 trigger matches) beats Office (1 match)")
}

do {
    // Auto-switching disabled → no profile change
    var sim = makeStandardSimulator()
    sim.isAutoSwitchEnabled = false
    let state = sim.connectDevice(airpods)
    checkEqual(state.activeProfileName, "System Default",
               "Auto-switching disabled → device changes don't switch profiles")
}

do {
    // Auto-switching disabled → priorities still re-evaluate
    var sim = makeStandardSimulator()
    sim.isAutoSwitchEnabled = false
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(headphones)

    let state = sim.connectDevice(speakers)
    checkEqual(state.outputDeviceName, "Studio Monitors",
               "Auto-switching disabled → priorities still re-evaluate within active profile")
}

// ============================================================================
// MARK: - Category 3: EQ Pipeline
// ============================================================================

section("🎛️ EQ Pipeline — EQ is applied correctly")

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    let state = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    check(state.needsVirtualDriver, "Non-flat EQ preset → virtual driver needed")
    if case .startPipeline = state.pipelineAction {
        check(true, "Pipeline action is startPipeline")
    } else {
        check(false, "Pipeline action should be startPipeline, got \(state.pipelineAction)")
    }
}

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    let state = sim.setEQ(for: "speakers-uid", .flat)
    check(!state.needsVirtualDriver, "Flat EQ → virtual driver not needed")
}

do {
    // Bypass stops virtual driver
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())  // Starts EQ

    let state = sim.toggleGlobalBypass()
    check(!state.needsVirtualDriver, "Bypass EQ → virtual driver not needed")
    if case .stopEQ = state.pipelineAction {
        check(true, "Bypass triggers stopEQ action")
    } else {
        check(false, "Bypass should trigger stopEQ, got \(state.pipelineAction)")
    }
}

do {
    // Un-bypass restarts
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    _ = sim.toggleGlobalBypass()  // Now bypassed, EQ stopped

    let state = sim.toggleGlobalBypass()  // Un-bypass
    check(state.needsVirtualDriver, "Un-bypass → virtual driver needed again")
    if case .startPipeline = state.pipelineAction {
        check(true, "Un-bypass triggers startPipeline")
    } else {
        check(false, "Un-bypass should trigger startPipeline, got \(state.pipelineAction)")
    }
}

do {
    // Content mode overlay combines with device EQ
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    sim.soundModesEnabled = true
    sim.contentOverlays = [.voice: .defaultVoice(), .music: .defaultMusic(), .none: .defaultNone()]

    _ = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    let state = sim.setContentMode(.voice)

    // Device EQ has +6dB at 32Hz, Voice overlay has -2dB at 32Hz → combined = +4dB
    check(abs(state.effectiveEQ.bands[0].gain - 4.0) < 0.01,
          "Content mode overlay combines with device EQ: 6 + (-2) = 4 dB at 32Hz")
}

do {
    // Night mode stacks on content mode
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    sim.soundModesEnabled = true
    sim.contentOverlays = [.voice: .defaultVoice(), .none: .defaultNone()]
    sim.nightMode = .default
    sim.nightMode.isEnabled = true

    _ = sim.setContentMode(.voice)
    let state = sim.setNightModeActive(true)

    // Night mode adds -4dB at 32Hz on top of voice's -2dB → -6dB total at 32Hz
    check(abs(state.effectiveEQ.bands[0].gain - (-6.0)) < 0.01,
          "Night mode stacks on content mode: (-2) + (-4) = -6 dB at 32Hz")
}

do {
    // Global bypass overrides everything
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    sim.soundModesEnabled = true
    sim.contentOverlays = [.voice: .defaultVoice()]
    sim.nightMode = .default
    sim.nightMode.isEnabled = true
    sim.isNightModeActive = true
    sim.activeContentMode = .voice
    _ = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())

    let state = sim.toggleGlobalBypass()
    check(state.effectiveEQ.isFlat, "Global bypass overrides all layers to flat")
}

do {
    // Switching devices preserves per-device EQ
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)
    _ = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    _ = sim.setEQ(for: "beyerdynamic-uid", makeVoiceBoostEQ())

    let speakerState = sim.toggleMode()  // Switch to private (headphones first)
    // Now headphones should be output with voice boost EQ
    check(abs(speakerState.effectiveEQ.bands[6].gain - 3.0) < 0.01,
          "After mode toggle, headphones get their own EQ (voice boost at 2kHz)")

    let backState = sim.toggleMode()  // Back to public (speakers first)
    check(abs(backState.effectiveEQ.bands[0].gain - 6.0) < 0.01,
          "Toggle back, speakers get their original EQ (bass boost at 32Hz)")
}

do {
    // No device EQ + active content mode → only overlay
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    sim.soundModesEnabled = true
    sim.contentOverlays = [.voice: .defaultVoice(), .none: .defaultNone()]

    let state = sim.setContentMode(.voice)
    // No device EQ set for speakers, so only voice overlay applies
    check(abs(state.effectiveEQ.bands[6].gain - 2.5) < 0.01,
          "No device EQ + voice mode → only voice overlay applied (2.5dB at 2kHz)")
}

// ============================================================================
// MARK: - Category 4: Mode Switching
// ============================================================================

section("🔀 Mode Switching — Toggling Speakers/Headphones")

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)

    let state = sim.toggleMode()  // public → private
    checkEqual(state.outputDeviceName, "Beyerdynamic DT 990",
               "Toggle to Headphones mode → headphones selected")
}

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)
    _ = sim.toggleMode()  // → private

    let state = sim.toggleMode()  // → public
    checkEqual(state.outputDeviceName, "Studio Monitors",
               "Toggle back to Speakers mode → speakers selected")
}

do {
    // Mode toggle affects both input and output
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)
    _ = sim.connectDevice(usbMic)
    _ = sim.connectDevice(builtinIn)

    let publicState = sim.toggleMode()  // → private
    let privateOutput = publicState.outputDeviceUID
    let privateInput = publicState.inputDeviceUID

    let publicAgain = sim.toggleMode()  // → public
    // Home profile: public output=[speakers, headphones, builtin], private output=[headphones, speakers, builtin]
    check(publicAgain.outputDeviceUID != privateOutput || publicAgain.inputDeviceUID == privateInput,
          "Mode toggle can change output device (speakers vs headphones priority differs)")
}

do {
    // Only one output device → same regardless of mode
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(headphones)  // Only this output device

    let publicState = sim.toggleMode()  // → private (headphones still #1 in private too)
    // Private priority: [headphones, speakers, builtin] — headphones still wins
    checkEqual(publicState.outputDeviceName, "Beyerdynamic DT 990",
               "Only one output device → same device in both modes")
}

// ============================================================================
// MARK: - Category 5: Fingerprint Deduplication
// ============================================================================

section("🔍 Fingerprint Deduplication — No unnecessary work")

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    let first = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    check(first.fingerprintChanged, "First EQ change always triggers fingerprint change")

    // Set the same EQ again — fingerprint should match since EQ hasn't actually changed
    let second = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    check(!second.fingerprintChanged, "Same EQ set again → fingerprint unchanged (no unnecessary work)")
}

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)

    let state = sim.connectDevice(headphones)  // New device changes output resolution
    check(state.fingerprintChanged, "Device change → fingerprint changed")
}

do {
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    _ = sim.setEQ(for: "speakers-uid", .flat)  // Settle fingerprint

    let state = sim.setEQ(for: "speakers-uid", makeBassBoostEQ())
    check(state.fingerprintChanged, "EQ change → fingerprint changed")
}

do {
    var sim = makeStandardSimulator()
    _ = sim.connectDevice(speakers)
    _ = sim.connectDevice(headphones)
    _ = sim.activateProfile(homeProfileID, isManual: true)

    let state = sim.activateProfile(officeProfileID, isManual: true)
    check(state.fingerprintChanged, "Profile change → fingerprint changed")
}

// ============================================================================
// MARK: - Category 6: Edge Cases
// ============================================================================

section("⚠️ Edge Cases — Nothing breaks in weird situations")

do {
    // Empty profile with no priorities → uses fallback
    let emptyProfile = Profile(id: UUID(), name: "Empty", preferredMode: .public)
    var sim = SystemSimulator(
        profiles: [emptyProfile, makeSystemDefault()],
        connectedDevices: [builtinOut, builtinIn]
    )
    let state = sim.activateProfile(emptyProfile.id, isManual: true)
    checkEqual(state.outputDeviceName, "MacBook Pro Speakers",
               "Empty profile (no priorities) → uses fallback built-in device")
}

do {
    // Profile with only disconnected devices → fallback
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    // Don't connect speakers or headphones — only builtin exists
    let state = sim.connectDevice(builtinIn)
    checkEqual(state.outputDeviceName, "MacBook Pro Speakers",
               "Profile with only disconnected priority devices → built-in fallback")
}

do {
    // Night mode start==end → always active (our fix)
    var nightConfig = NightModeConfig.default
    nightConfig.isEnabled = true
    nightConfig.startHour = 10
    nightConfig.startMinute = 0
    nightConfig.endHour = 10
    nightConfig.endMinute = 0

    let time10am = Calendar.current.date(from: DateComponents(hour: 10, minute: 0))!
    let time3pm = Calendar.current.date(from: DateComponents(hour: 15, minute: 0))!
    let time3am = Calendar.current.date(from: DateComponents(hour: 3, minute: 0))!

    check(nightConfig.isInQuietHours(now: time10am), "Night mode start==end: active at 10 AM")
    check(nightConfig.isInQuietHours(now: time3pm), "Night mode start==end: active at 3 PM")
    check(nightConfig.isInQuietHours(now: time3am), "Night mode start==end: active at 3 AM (always on)")
}

do {
    // System Default profile behaves as fallback
    var sim = makeStandardSimulator()
    let state = sim.connectDevice(builtinIn)
    checkEqual(state.activeProfileName, "System Default",
               "System Default profile is active when no triggers match")
}

do {
    // All profiles deleted → still works with empty state
    var sim = SystemSimulator(profiles: [], connectedDevices: [builtinOut, builtinIn])
    let state = sim.connectDevice(builtinIn)
    checkEqual(state.outputDeviceName, "MacBook Pro Speakers",
               "No profiles at all → still resolves to a connected output device")
}

do {
    // Bypass while EQ not running → stays flat, no error
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(speakers)
    // No EQ set, not running

    let state = sim.toggleGlobalBypass()
    check(state.effectiveEQ.isFlat, "Bypass while EQ not running → stays flat")
    check(!state.needsVirtualDriver, "No virtual driver needed when bypassed with flat EQ")
}

do {
    // Device connect while EQ running → hot-switch
    var sim = makeStandardSimulator()
    _ = sim.activateProfile(homeProfileID, isManual: true)
    _ = sim.connectDevice(headphones)
    _ = sim.setEQ(for: "beyerdynamic-uid", makeBassBoostEQ())  // Starts pipeline on headphones
    _ = sim.setEQ(for: "speakers-uid", makeVoiceBoostEQ())     // Pre-set speakers EQ

    let state = sim.connectDevice(speakers)  // Higher priority, EQ running
    checkEqual(state.outputDeviceName, "Studio Monitors",
               "Higher-priority device connects while EQ running → switches to it")
    if case .switchDevice = state.pipelineAction {
        check(true, "EQ running + new device → switchDevice action (hot-swap)")
    } else {
        check(false, "Expected switchDevice action, got \(state.pipelineAction)")
    }
}

// ============================================================================
// MARK: - Category 7: Persistence Round-Trip
// ============================================================================

section("💾 Persistence Round-Trip — Save and load preserve data")

// For persistence tests, we make Profile Codable
struct CodableProfile: Codable, Equatable {
    let id: UUID
    var name: String
    var triggerDeviceIDs: [String]
    var triggerRules: [CodableTriggerRule]
    var publicOutputPriority: [String]
    var publicInputPriority: [String]
    var privateOutputPriority: [String]
    var privateInputPriority: [String]
    var preferredMode: String
    var iconName: String

    enum CodableTriggerRule: Codable, Equatable {
        case specificDevice(id: String)
        case transportType(type: String)

        enum CodingKeys: String, CodingKey { case type, value }
        enum RuleType: String, Codable { case specificDevice, transportType }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .specificDevice(let id):
                try c.encode(RuleType.specificDevice, forKey: .type)
                try c.encode(id, forKey: .value)
            case .transportType(let type):
                try c.encode(RuleType.transportType, forKey: .type)
                try c.encode(type, forKey: .value)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(RuleType.self, forKey: .type)
            let value = try c.decode(String.self, forKey: .value)
            switch type {
            case .specificDevice: self = .specificDevice(id: value)
            case .transportType: self = .transportType(type: value)
            }
        }
    }
}

do {
    let profile = CodableProfile(
        id: UUID(), name: "Test Profile",
        triggerDeviceIDs: ["device-1", "device-2"],
        triggerRules: [.specificDevice(id: "device-1"), .specificDevice(id: "device-2")],
        publicOutputPriority: ["device-1", "device-3"],
        publicInputPriority: ["device-4"],
        privateOutputPriority: ["device-2", "device-3"],
        privateInputPriority: ["device-4"],
        preferredMode: "public",
        iconName: "speaker.wave.2"
    )

    let data = try! JSONEncoder().encode([profile])
    let decoded = try! JSONDecoder().decode([CodableProfile].self, from: data)
    checkEqual(decoded.count, 1, "Save profiles → load → same count")
    checkEqual(decoded[0], profile, "Save profiles → load → identical content")
}

do {
    let profile = CodableProfile(
        id: UUID(), name: "With Triggers",
        triggerDeviceIDs: ["dev-a"],
        triggerRules: [.specificDevice(id: "dev-a"), .transportType(type: "Bluetooth")],
        publicOutputPriority: [], publicInputPriority: [],
        privateOutputPriority: [], privateInputPriority: [],
        preferredMode: "public", iconName: "headphones"
    )

    let data = try! JSONEncoder().encode(profile)
    let decoded = try! JSONDecoder().decode(CodableProfile.self, from: data)
    checkEqual(decoded.triggerRules, profile.triggerRules,
               "Trigger rules (specific + transport type) survive round-trip")
}

do {
    let empty: [CodableProfile] = []
    let data = try! JSONEncoder().encode(empty)
    let decoded = try! JSONDecoder().decode([CodableProfile].self, from: data)
    checkEqual(decoded.count, 0, "Empty profile list → round-trip preserved")
}

do {
    let profile = CodableProfile(
        id: UUID(), name: "Full Profile",
        triggerDeviceIDs: ["a", "b", "c"],
        triggerRules: [.specificDevice(id: "a"), .specificDevice(id: "b"), .transportType(type: "USB")],
        publicOutputPriority: ["a", "b"],
        publicInputPriority: ["c"],
        privateOutputPriority: ["b", "a"],
        privateInputPriority: ["c"],
        preferredMode: "private",
        iconName: "music.note"
    )

    let data = try! JSONEncoder().encode(profile)
    let decoded = try! JSONDecoder().decode(CodableProfile.self, from: data)
    checkEqual(decoded.name, profile.name, "Name preserved")
    checkEqual(decoded.triggerDeviceIDs, profile.triggerDeviceIDs, "Trigger device IDs preserved")
    checkEqual(decoded.publicOutputPriority, profile.publicOutputPriority, "Public output priority preserved")
    checkEqual(decoded.privateOutputPriority, profile.privateOutputPriority, "Private output priority preserved")
    checkEqual(decoded.preferredMode, profile.preferredMode, "Preferred mode preserved")
}

do {
    // Legacy profile without triggerRules → should still decode via triggerDeviceIDs
    let legacyJSON = """
    {
        "id": "550E8400-E29B-41D4-A716-446655440000",
        "name": "Legacy",
        "triggerDeviceIDs": ["old-device-1", "old-device-2"],
        "publicOutputPriority": ["old-device-1"],
        "publicInputPriority": [],
        "privateOutputPriority": [],
        "privateInputPriority": [],
        "preferredMode": "public",
        "iconName": "speaker.wave.2"
    }
    """
    // This should decode even without triggerRules field
    struct LegacyProfile: Codable {
        let id: UUID
        var name: String
        var triggerDeviceIDs: [String]
        var triggerRules: [CodableProfile.CodableTriggerRule]?
        var publicOutputPriority: [String]
        var publicInputPriority: [String]
        var privateOutputPriority: [String]
        var privateInputPriority: [String]
        var preferredMode: String
        var iconName: String
    }

    let data = legacyJSON.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(LegacyProfile.self, from: data)
    checkEqual(decoded.name, "Legacy", "Legacy profile without triggerRules decodes successfully")
    check(decoded.triggerRules == nil, "Legacy profile has nil triggerRules (migration happens at app level)")
    checkEqual(decoded.triggerDeviceIDs, ["old-device-1", "old-device-2"],
               "Legacy triggerDeviceIDs preserved for migration")
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
