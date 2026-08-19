// SHARED: AudioProfiles/Models/AudioDevice.swift AudioProfiles/Models/ProfileMode.swift AudioProfiles/Models/Hotkey.swift AudioProfiles/Models/Profile.swift AudioProfiles/Models/DeviceHistoryEntry.swift AudioProfiles/Models/EQSettings.swift AudioProfiles/Models/EQSettings+Combine.swift AudioProfiles/Models/ContentMode.swift AudioProfiles/Models/ContentModeOverlay.swift AudioProfiles/Models/NightMode.swift AudioProfiles/Core/AudioCore.swift
//
// BehaviorTests.swift
//
// End-to-end behavioral tests that wire the REAL production models
// (AudioProfiles/Models/*) and the REAL canonical decision logic
// (AudioProfiles/Core/AudioCore.swift) together into a stateful simulation of
// the full event chain (SystemSimulator). Because the `// SHARED:` directive on
// the first line lists the real sources, build.sh compiles this test AGAINST
// production code — a production regression now fails these tests.
//
// The `// SHARED:` directive above is consumed by build.sh, which compiles the
// listed real sources alongside this file with swiftc (this file is no longer
// run directly with `swift`, so there is no shebang).
//
// What is REAL vs. a MIRROR:
//   • Models (AudioDevice, Profile/TriggerRule, ProfileMode, EQSettings/EQBand,
//     ContentModeOverlay, NightModeConfig, DeviceHistoryEntry) → REAL.
//   • Trigger matching, manual-override protection, device-history folding →
//     REAL (AudioCore.findBestTriggerMatch / shouldApplyTrigger /
//     updateDeviceHistory).
//   • Device resolution + pipeline-action + effective-EQ + fingerprint inside
//     SystemSimulator → clearly-labeled LOCAL MIRRORS of
//     ProfileManager.performEvaluation / AudioPipelineService.apply /
//     SoundModesStore.activeOverlay, kept faithful to current production.
//     PipelineFingerprint is a PRIVATE production struct, so the mirror below is
//     a structural copy — NOT the real type.
//
// Test Categories:
//   1. Device Lifecycle (7 tests)
//   2. Profile Auto-Switching (7 tests)
//   3. EQ Pipeline (9 tests)
//   4. Mode Switching (4 tests)
//   5. Fingerprint Deduplication (4 tests)
//   6. Edge Cases (7 tests)
//   7. Persistence Round-Trip (5 tests)

import Foundation

// AudioDevice is NOT Equatable in production. The simulator only ever compares
// resolved device UIDs (String?), so give the tests a local UID-based equality
// without touching the real model.
extension AudioDevice {
    static func sameUID(_ a: AudioDevice?, _ b: AudioDevice?) -> Bool { a?.id == b?.id }
}

// ============================================================================
// MARK: - Test-only profile factory
// ============================================================================
// The REAL Profile.init requires an explicit iconName (no default). This helper
// supplies a default so the test fixtures below stay terse. Everything else is
// forwarded straight to the production initializer.
func makeProfile(
    id: UUID,
    name: String,
    iconName: String = "speaker",
    triggerDeviceIDs: [String],
    triggerRules: [TriggerRule]? = nil,
    publicOutputPriority: [String], publicInputPriority: [String],
    privateOutputPriority: [String], privateInputPriority: [String],
    preferredMode: ProfileMode = .public, isSystemDefault: Bool = false
) -> Profile {
    Profile(
        id: id, name: name, iconName: iconName,
        triggerDeviceIDs: triggerDeviceIDs, triggerRules: triggerRules,
        publicOutputPriority: publicOutputPriority, publicInputPriority: publicInputPriority,
        privateOutputPriority: privateOutputPriority, privateInputPriority: privateInputPriority,
        preferredMode: preferredMode, isSystemDefault: isSystemDefault
    )
}

// ============================================================================
// MARK: - PipelineFingerprint (LOCAL structural mirror)
// ============================================================================
// PipelineFingerprint is a PRIVATE struct inside ProfileManager and cannot be
// imported. This is a structural copy with the same fields, used only to model
// the fingerprint-dedup behavior — it is NOT the production type.
struct PipelineFingerprint: Equatable {
    let profileID: UUID?
    let mode: ProfileMode
    let outputDeviceUID: String?
    let inputDeviceUID: String?
    let effectiveEQ: EQSettings
    let needsVirtualDriver: Bool
}

// ============================================================================
// MARK: - Pipeline action enum (LOCAL mirror of AudioPipelineService.apply)
// ============================================================================
// Enumerates the mutually-exclusive branches of AudioPipelineService.apply so
// tests can assert which one production would take. Not a production type.
enum PipelineAction: Equatable {
    case hotUpdate(EQSettings)
    case switchDevice(realUID: String, settings: EQSettings, virtualName: String)
    case startPipeline(realUID: String, settings: EQSettings, virtualName: String)
    case stopEQ(switchTo: String)
    case directSetDevice(String)
    case noOp
}

// ============================================================================
// MARK: - Device resolution MIRRORS (of ProfileManager.performEvaluation)
// ============================================================================
// Faithful to production performEvaluation:
//   • Walk the priority list; on the virtual device, look THROUGH to the real
//     device when EQ is running, else `break` (fall through to system default) —
//     production uses `break`, NOT `continue` to the next priority entry.
//   • If nothing resolves from the priority list, fall back to the CURRENT
//     SYSTEM DEFAULT output (production calls pipelineService.getDefaultOutputDevice).
//     This is why an empty priority list does NOT yield nil output.

func resolveOutputDevice(
    priorityList: [String],
    connectedDevices: [AudioDevice],
    currentSystemDefaultOutput: AudioDevice?,
    virtualDeviceUID: String? = nil,
    eqRunning: Bool = false,
    eqTargetUID: String? = nil
) -> (device: AudioDevice, uid: String)? {
    for deviceID in priorityList {
        if let device = connectedDevices.first(where: { $0.id == deviceID && $0.isOutput }) {
            if let vUID = virtualDeviceUID, device.id == vUID {
                if eqRunning, let realUID = eqTargetUID,
                   let realDevice = connectedDevices.first(where: { $0.id == realUID && $0.isOutput }) {
                    return (realDevice, realUID)
                }
                // Virtual device but EQ not running (or target gone): production
                // `break`s out of the priority walk and falls to system default.
                break
            }
            return (device, device.id)
        }
    }
    // Fall back to the current system default output (production behavior).
    if let sd = currentSystemDefaultOutput {
        return (sd, sd.id)
    }
    return nil
}

func resolveInputDevice(
    priorityList: [String],
    connectedDevices: [AudioDevice],
    currentSystemDefaultInput: AudioDevice?
) -> (device: AudioDevice, uid: String)? {
    for deviceID in priorityList {
        if let device = connectedDevices.first(where: { $0.id == deviceID && $0.isInput }) {
            return (device, device.id)
        }
    }
    // Fall back to current system default input (production behavior).
    if let sd = currentSystemDefaultInput {
        return (sd, sd.id)
    }
    return nil
}

// ============================================================================
// MARK: - computeActiveOverlay MIRROR (of SoundModesStore.activeOverlay)
// ============================================================================
// Faithful to production: when an overlay is MISSING for the active mode, the
// production `overlay(for:)` falls back to the mode's DEFAULT overlay (NOT to
// .flat). Night mode stacks independently of the content-modes master toggle.
func computeActiveOverlay(
    isEnabled: Bool,
    activeContentMode: ContentModeType,
    overlays: [ContentModeType: ContentModeOverlay],
    isNightModeActive: Bool,
    nightMode: NightModeConfig
) -> EQSettings {
    let contentEQ: EQSettings
    if isEnabled {
        // Mirror SoundModesStore.overlay(for:): missing → mode default overlay.
        let overlay = overlays[activeContentMode] ?? ContentModeOverlay.defaultOverlay(for: activeContentMode)
        contentEQ = overlay.isEnabled ? overlay.settings : .flat
    } else {
        contentEQ = .flat
    }
    if nightMode.isEnabled && isNightModeActive {
        return EQSettings.combine(base: contentEQ, overlay: nightMode.overlay)
    }
    return contentEQ
}

// ============================================================================
// MARK: - decidePipelineAction MIRROR (of AudioPipelineService.apply branches)
// ============================================================================
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
// MARK: - SystemState
// ============================================================================

struct SystemState {
    let activeProfileName: String?
    let activeMode: ProfileMode
    let outputDeviceName: String?
    let outputDeviceUID: String?
    let inputDeviceName: String?
    let effectiveEQ: EQSettings
    let needsVirtualDriver: Bool
    let pipelineAction: PipelineAction
    let wasAutoSwitched: Bool
    let fingerprintChanged: Bool
}

// ============================================================================
// MARK: - SystemSimulator
// ============================================================================

struct SystemSimulator {
    var profiles: [Profile]
    var activeProfileID: UUID?
    var activeMode: ProfileMode
    var connectedDevices: [AudioDevice]
    var deviceEQ: [String: EQSettings]
    var soundModesEnabled: Bool
    var activeContentMode: ContentModeType
    var contentOverlays: [ContentModeType: ContentModeOverlay]
    var nightMode: NightModeConfig
    var isNightModeActive: Bool
    var isAutoSwitchEnabled: Bool
    var isGlobalBypass: Bool
    /// Per-device EQ bypass, mirrors EQStore.isBypassed(for:). Production flattens
    /// effective EQ when EITHER global bypass OR the resolved device's bypass is set.
    var deviceBypass: [String: Bool]
    var driverInstalled: Bool
    var eqRunning: Bool
    var eqTargetUID: String?
    var virtualDeviceUID: String?
    /// Models the CURRENT system default endpoints. Production's performEvaluation
    /// falls back to these when the priority list resolves nothing — so an empty or
    /// unmatched priority list still yields a device, NOT nil.
    var currentSystemDefaultOutput: AudioDevice?
    var currentSystemDefaultInput: AudioDevice?
    var lastFingerprint: PipelineFingerprint?
    var lastManualSwitchTimestamp: Date?
    var deviceHistory: [String: DeviceHistoryEntry]

    init(profiles: [Profile] = [],
         activeProfileID: UUID? = nil,
         activeMode: ProfileMode = .public,
         connectedDevices: [AudioDevice] = [],
         deviceEQ: [String: EQSettings] = [:],
         deviceBypass: [String: Bool] = [:],
         soundModesEnabled: Bool = false,
         activeContentMode: ContentModeType = .none,
         contentOverlays: [ContentModeType: ContentModeOverlay] = [:],
         nightMode: NightModeConfig = .default,
         isNightModeActive: Bool = false,
         isAutoSwitchEnabled: Bool = true,
         isGlobalBypass: Bool = false,
         driverInstalled: Bool = true,
         eqRunning: Bool = false,
         eqTargetUID: String? = nil,
         virtualDeviceUID: String? = nil,
         currentSystemDefaultOutput: AudioDevice? = nil,
         currentSystemDefaultInput: AudioDevice? = nil) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.activeMode = activeMode
        self.connectedDevices = connectedDevices
        self.deviceEQ = deviceEQ
        self.deviceBypass = deviceBypass
        self.soundModesEnabled = soundModesEnabled
        self.activeContentMode = activeContentMode
        self.contentOverlays = contentOverlays
        self.nightMode = nightMode
        self.isNightModeActive = isNightModeActive
        self.isAutoSwitchEnabled = isAutoSwitchEnabled
        self.isGlobalBypass = isGlobalBypass
        self.driverInstalled = driverInstalled
        self.eqRunning = eqRunning
        self.eqTargetUID = eqTargetUID
        self.virtualDeviceUID = virtualDeviceUID
        self.currentSystemDefaultOutput = currentSystemDefaultOutput
        self.currentSystemDefaultInput = currentSystemDefaultInput
        self.lastFingerprint = nil
        self.lastManualSwitchTimestamp = nil
        self.deviceHistory = [:]
    }

    /// Core evaluation: wires pure functions in the same order as ProfileManager.performEvaluation()
    mutating func evaluate(wasAutoSwitched: Bool = false) -> SystemState {
        // Step 1: get active profile.
        // Production performEvaluation() begins with `guard let profile = activeProfile
        // else { return }` — with no active profile it does nothing and resolves no
        // device. Mirror that early return here.
        guard let activeProfile = profiles.first(where: { $0.id == activeProfileID }) else {
            return SystemState(
                activeProfileName: nil,
                activeMode: activeMode,
                outputDeviceName: nil,
                outputDeviceUID: nil,
                inputDeviceName: nil,
                effectiveEQ: .flat,
                needsVirtualDriver: false,
                pipelineAction: .noOp,
                wasAutoSwitched: wasAutoSwitched,
                fingerprintChanged: false
            )
        }

        // Step 2: resolve output device (falls back to system default like production)
        let outputList = activeProfile.priorityList(isOutput: true, mode: activeMode)
        let outputResult = resolveOutputDevice(
            priorityList: outputList,
            connectedDevices: connectedDevices,
            currentSystemDefaultOutput: currentSystemDefaultOutput,
            virtualDeviceUID: virtualDeviceUID,
            eqRunning: eqRunning,
            eqTargetUID: eqTargetUID
        )

        // Step 3: resolve input device (falls back to system default like production)
        let inputList = activeProfile.priorityList(isOutput: false, mode: activeMode)
        let inputResult = resolveInputDevice(
            priorityList: inputList,
            connectedDevices: connectedDevices,
            currentSystemDefaultInput: currentSystemDefaultInput
        )

        // Step 4: compute active overlay (L2 from content mode + night mode)
        let l2Overlay = computeActiveOverlay(
            isEnabled: soundModesEnabled,
            activeContentMode: activeContentMode,
            overlays: contentOverlays,
            isNightModeActive: isNightModeActive,
            nightMode: nightMode
        )

        // Step 5: EQSettings.combine(base: L1, overlay: L2), then bypass check.
        // Production flattens when global bypass OR the resolved device's per-device
        // bypass (EQStore.isBypassed) is set.
        let resolvedUID = outputResult?.uid ?? ""
        let baseEQ = deviceEQ[resolvedUID] ?? .flat
        let deviceBypassed = deviceBypass[resolvedUID] ?? false
        let effectiveEQ: EQSettings
        if isGlobalBypass || deviceBypassed {
            effectiveEQ = .flat
        } else {
            effectiveEQ = EQSettings.combine(base: baseEQ, overlay: l2Overlay)
        }

        // Step 6: needsVirtualDriver = !effectiveEQ.isFlat && driverInstalled
        let needsVirtualDriver = !effectiveEQ.isFlat && driverInstalled

        // Step 7: Build PipelineFingerprint
        let fingerprint = PipelineFingerprint(
            profileID: activeProfileID,
            mode: activeMode,
            outputDeviceUID: outputResult?.uid,
            inputDeviceUID: inputResult?.uid,
            effectiveEQ: effectiveEQ,
            needsVirtualDriver: needsVirtualDriver
        )

        // Step 8: compare with lastFingerprint
        let fingerprintChanged = fingerprint != lastFingerprint

        // Step 9: decidePipelineAction — what the pipeline service would do
        let action: PipelineAction
        if fingerprintChanged {
            action = decidePipelineAction(
                eqRunning: eqRunning,
                eqTargetUID: eqTargetUID,
                needsVirtualDriver: needsVirtualDriver,
                outputDeviceUID: outputResult?.uid,
                effectiveEQ: effectiveEQ,
                virtualDeviceName: outputResult.map { "\($0.device.name) EQ" }
            )
        } else {
            action = .noOp
        }

        // Step 10: Update simulator EQ engine state based on action
        if fingerprintChanged {
            lastFingerprint = fingerprint
            switch action {
            case .startPipeline(let uid, _, _):
                eqRunning = true
                eqTargetUID = uid
            case .switchDevice(let uid, _, _):
                eqTargetUID = uid
            case .stopEQ:
                eqRunning = false
                eqTargetUID = nil
            case .directSetDevice:
                break
            case .hotUpdate:
                break
            case .noOp:
                break
            }
        }

        return SystemState(
            activeProfileName: activeProfile.name,
            activeMode: activeMode,
            outputDeviceName: outputResult?.device.name,
            outputDeviceUID: outputResult?.uid,
            inputDeviceName: inputResult?.device.name,
            effectiveEQ: effectiveEQ,
            needsVirtualDriver: needsVirtualDriver,
            pipelineAction: action,
            wasAutoSwitched: wasAutoSwitched,
            fingerprintChanged: fingerprintChanged
        )
    }

    /// Resolve a profile from an AudioCore.TriggerMatch (which carries profileID, not the profile).
    private func profile(for match: AudioCore.TriggerMatch) -> Profile? {
        profiles.first(where: { $0.id == match.profileID })
    }

    /// Manual-override protection, delegated to the REAL production logic
    /// (AudioCore.shouldApplyTrigger): an auto-switch is allowed only if the matched
    /// profile has a currently-active trigger device whose `connectedAt` is AFTER the
    /// last manual switch. A device that predates the manual switch — even with a
    /// refreshed `lastSeen` — must NOT override the user. Mirrors
    /// ProfileTriggerService.evaluateTriggers, which also checks the primary matched
    /// device (may come from a class-based rule not in triggerDeviceIDs).
    private func triggerAllowedByManualOverride(_ match: AudioCore.TriggerMatch, profile: Profile) -> Bool {
        var deviceIDsToCheck = profile.triggerDeviceIDs
        if !deviceIDsToCheck.contains(match.primaryTriggerDevice) {
            deviceIDsToCheck.append(match.primaryTriggerDevice)
        }
        return AudioCore.shouldApplyTrigger(
            lastManualSwitch: lastManualSwitchTimestamp,
            triggerDeviceIDs: deviceIDsToCheck,
            history: deviceHistory
        )
    }

    mutating func connectDevice(_ device: AudioDevice) -> SystemState {
        if !connectedDevices.contains(where: { $0.id == device.id }) {
            connectedDevices.append(device)
        }

        // Fold the fresh scan into history using the REAL AudioCore logic
        // (connectedAt advances only on a disconnected → connected transition).
        deviceHistory = AudioCore.updateDeviceHistory(deviceHistory, with: connectedDevices, now: Date())

        var autoSwitched = false
        if isAutoSwitchEnabled {
            let currentDeviceIDs = Set(connectedDevices.map { $0.id })
            if let match = AudioCore.findBestTriggerMatch(
                profiles: profiles.filter { !$0.isSystemDefault },
                currentDeviceIDs: currentDeviceIDs,
                currentDevices: connectedDevices
            ), let matched = profile(for: match) {
                if triggerAllowedByManualOverride(match, profile: matched) && matched.id != activeProfileID {
                    activeProfileID = matched.id
                    activeMode = matched.preferredMode
                    autoSwitched = true
                }
            }
        }

        return evaluate(wasAutoSwitched: autoSwitched)
    }

    mutating func disconnectDevice(_ uid: String) -> SystemState {
        connectedDevices.removeAll { $0.id == uid }

        // Fold the scan (device now absent) into history via the REAL AudioCore logic;
        // the removed device is marked inactive but retained.
        deviceHistory = AudioCore.updateDeviceHistory(deviceHistory, with: connectedDevices, now: Date())

        var autoSwitched = false
        if isAutoSwitchEnabled {
            let currentDeviceIDs = Set(connectedDevices.map { $0.id })
            let newMatch = AudioCore.findBestTriggerMatch(
                profiles: profiles.filter { !$0.isSystemDefault },
                currentDeviceIDs: currentDeviceIDs,
                currentDevices: connectedDevices
            )

            if let match = newMatch, let matched = profile(for: match) {
                if matched.id != activeProfileID {
                    activeProfileID = matched.id
                    activeMode = matched.preferredMode
                    autoSwitched = true
                }
            } else {
                if let sd = profiles.first(where: { $0.isSystemDefault }) {
                    if sd.id != activeProfileID {
                        activeProfileID = sd.id
                        autoSwitched = true
                    }
                }
            }
        }

        return evaluate(wasAutoSwitched: autoSwitched)
    }

    mutating func activateProfile(_ id: UUID, isManual: Bool) -> SystemState {
        activeProfileID = id
        if let profile = profiles.first(where: { $0.id == id }) {
            activeMode = profile.preferredMode
        }
        if isManual {
            lastManualSwitchTimestamp = Date()
        }
        return evaluate()
    }

    mutating func toggleMode() -> SystemState {
        activeMode = activeMode == .public ? .private : .public
        return evaluate()
    }

    mutating func setEQ(for uid: String, _ settings: EQSettings) -> SystemState {
        deviceEQ[uid] = settings
        return evaluate()
    }

    mutating func toggleGlobalBypass() -> SystemState {
        isGlobalBypass.toggle()
        return evaluate()
    }

    /// Mirrors EQStore.setBypassed(_:for:) → re-evaluation.
    mutating func setDeviceBypass(_ bypassed: Bool, for uid: String) -> SystemState {
        deviceBypass[uid] = bypassed
        return evaluate()
    }

    mutating func setContentMode(_ mode: ContentModeType) -> SystemState {
        activeContentMode = mode
        return evaluate()
    }

    mutating func setNightModeActive(_ active: Bool) -> SystemState {
        isNightModeActive = active
        return evaluate()
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
    if condition {
        passedTests += 1
        print("  ✅ \(message)")
    } else {
        failedTests += 1
        print("  ❌ FAIL: \(message) (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
    totalTests += 1
    if a == b {
        passedTests += 1
        print("  ✅ \(message)")
    } else {
        failedTests += 1
        print("  ❌ FAIL: \(message) — got '\(a)', expected '\(b)' (line \(line))")
    }
}

func checkApprox(_ a: Float, _ b: Float, tol: Float = 0.01, _ message: String, line: Int = #line) {
    totalTests += 1
    if abs(a - b) <= tol {
        passedTests += 1
        print("  ✅ \(message)")
    } else {
        failedTests += 1
        print("  ❌ FAIL: \(message) — got \(a), expected ≈\(b) (line \(line))")
    }
}

// ============================================================================
// MARK: - Test fixtures
// ============================================================================

let speakers = AudioDevice(id: "speakers-uid", name: "Studio Monitors", transportType: "USB", isInput: false, isOutput: true)
let headphones = AudioDevice(id: "beyerdynamic-uid", name: "Beyerdynamic DT 990", transportType: "USB", isInput: false, isOutput: true)
let airpods = AudioDevice(id: "airpods-uid", name: "AirPods Max", transportType: "Bluetooth", isInput: true, isOutput: true)
let builtinOut = AudioDevice(id: "builtin-output-uid", name: "MacBook Pro Speakers", transportType: "Built-In", isInput: false, isOutput: true)
let builtinIn = AudioDevice(id: "builtin-input-uid", name: "MacBook Pro Microphone", transportType: "Built-In", isInput: true, isOutput: false)
let usbMic = AudioDevice(id: "usb-mic-uid", name: "Blue Yeti", transportType: "USB", isInput: true, isOutput: false)

let homeProfileID = UUID()
let officeProfileID = UUID()
let systemDefaultID = UUID()

let homeProfile = makeProfile(
    id: homeProfileID,
    name: "Home Studio",
    triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"],
    publicOutputPriority: ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"],
    publicInputPriority: ["usb-mic-uid", "builtin-input-uid"],
    privateOutputPriority: ["beyerdynamic-uid", "speakers-uid", "builtin-output-uid"],
    privateInputPriority: ["usb-mic-uid", "builtin-input-uid"],
    preferredMode: .public
)

let officeProfile = makeProfile(
    id: officeProfileID,
    name: "Office",
    triggerDeviceIDs: ["airpods-uid"],
    publicOutputPriority: ["airpods-uid", "builtin-output-uid"],
    publicInputPriority: ["airpods-uid", "builtin-input-uid"],
    privateOutputPriority: ["airpods-uid", "builtin-output-uid"],
    privateInputPriority: ["airpods-uid", "builtin-input-uid"],
    preferredMode: .public
)

let systemDefault = makeProfile(
    id: systemDefaultID,
    name: "System Default",
    triggerDeviceIDs: [],
    publicOutputPriority: [],
    publicInputPriority: [],
    privateOutputPriority: [],
    privateInputPriority: [],
    preferredMode: .public,
    isSystemDefault: true
)

// Helper: make a default simulator with standard profiles and devices
func makeSimulator(
    profiles: [Profile] = [systemDefault, homeProfile, officeProfile],
    activeProfileID: UUID? = nil,
    connected: [AudioDevice] = [builtinOut, builtinIn],
    mode: ProfileMode = .public,
    soundModesEnabled: Bool = false,
    driverInstalled: Bool = true,
    autoSwitch: Bool = true
) -> SystemSimulator {
    var sim = SystemSimulator(
        profiles: profiles,
        activeProfileID: activeProfileID ?? systemDefaultID,
        activeMode: mode,
        connectedDevices: connected,
        soundModesEnabled: soundModesEnabled,
        isAutoSwitchEnabled: autoSwitch,
        driverInstalled: driverInstalled,
        // Model the OS "current default" endpoints. Production's performEvaluation
        // falls back to these when the priority list resolves nothing — so a
        // profile with an empty/unmatched priority list still yields a device.
        // We use built-in as the natural default, consistent with a real Mac.
        currentSystemDefaultOutput: connected.first(where: { $0.isOutput }),
        currentSystemDefaultInput: connected.first(where: { $0.isInput })
    )
    for contentMode in ContentModeType.allCases {
        sim.contentOverlays[contentMode] = ContentModeOverlay.defaultOverlay(for: contentMode)
    }
    return sim
}

// ============================================================================
// MARK: - 1. Device Lifecycle (7 tests)
// ============================================================================

section("1. Device Lifecycle")

// Test 1: Speakers off → headphones used as fallback
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [headphones, builtinOut, builtinIn]
    )
    let state = sim.evaluate()
    checkEqual(state.outputDeviceUID, "beyerdynamic-uid",
               "DL1: Speakers off → headphones used as fallback")
}

// Test 2: Speakers turn on → become output (higher priority) [REGRESSION TEST for original bug]
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [headphones, builtinOut, builtinIn]
    )
    let state1 = sim.evaluate()
    checkEqual(state1.outputDeviceUID, "beyerdynamic-uid",
               "DL2a: Without speakers → headphones selected")

    let state2 = sim.connectDevice(speakers)
    checkEqual(state2.outputDeviceUID, "speakers-uid",
               "DL2b: Speakers turn on → speakers selected (higher priority) [BUG REGRESSION]")
    check(state2.fingerprintChanged, "DL2c: Fingerprint changed when speakers appeared")
}

// Test 3: Irrelevant USB mic plugged in → output unchanged
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [headphones, builtinOut, builtinIn]
    )
    let state1 = sim.evaluate()
    _ = sim.connectDevice(usbMic)
    let state2 = sim.evaluate()
    checkEqual(state1.outputDeviceUID, state2.outputDeviceUID,
               "DL3: USB mic plugged in → output device unchanged")
}

// Test 4: Current output unplugged → next priority takes over
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn]
    )
    let state1 = sim.evaluate()
    checkEqual(state1.outputDeviceUID, "speakers-uid", "DL4a: Initially using speakers")

    let state2 = sim.disconnectDevice("speakers-uid")
    checkEqual(state2.outputDeviceUID, "beyerdynamic-uid",
               "DL4b: Speakers unplugged → headphones take over")
}

// Test 5: ALL priority devices unplugged → built-in fallback (auto-switch disabled so profile stays)
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn],
        autoSwitch: false
    )
    _ = sim.disconnectDevice("speakers-uid")
    let state = sim.disconnectDevice("beyerdynamic-uid")
    checkEqual(state.outputDeviceUID, "builtin-output-uid",
               "DL5: All priority devices gone → built-in fallback (within same profile)")
}

// Test 6: Rapid connect A, connect B, disconnect A → correct final state
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [builtinOut, builtinIn]
    )
    _ = sim.connectDevice(headphones)
    _ = sim.connectDevice(speakers)
    let state = sim.disconnectDevice("beyerdynamic-uid")
    checkEqual(state.outputDeviceUID, "speakers-uid",
               "DL6: Rapid connect headphones, connect speakers, disconnect headphones → speakers active")
}

// Test 7: Disconnect then reconnect same device → returns to original state
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn]
    )
    let state1 = sim.evaluate()
    _ = sim.disconnectDevice("speakers-uid")
    let state3 = sim.connectDevice(speakers)
    checkEqual(state1.outputDeviceUID, state3.outputDeviceUID,
               "DL7: Disconnect then reconnect speakers → returns to original state")
}

// ============================================================================
// MARK: - 2. Profile Auto-Switching (7 tests)
// ============================================================================

section("2. Profile Auto-Switching")

// Test 1: AirPods connect → Office profile activates
do {
    var sim = makeSimulator(
        activeProfileID: systemDefaultID,
        connected: [builtinOut, builtinIn]
    )
    let state = sim.connectDevice(airpods)
    checkEqual(state.activeProfileName, "Office",
               "AS1: AirPods connect → Office profile activates")
    check(state.wasAutoSwitched, "AS1b: wasAutoSwitched flag is true")
}

// Test 2: Studio monitors connect → Home profile activates
do {
    var sim = makeSimulator(
        activeProfileID: systemDefaultID,
        connected: [builtinOut, builtinIn]
    )
    let state = sim.connectDevice(speakers)
    checkEqual(state.activeProfileName, "Home Studio",
               "AS2: Studio monitors connect → Home profile activates")
}

// Test 3: All trigger devices removed → System Default fallback
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn]
    )
    _ = sim.disconnectDevice("speakers-uid")
    let state = sim.disconnectDevice("beyerdynamic-uid")
    checkEqual(state.activeProfileName, "System Default",
               "AS3: All trigger devices removed → System Default fallback")
}

// Test 4: Manual override — a trigger device connected BEFORE the manual switch must NOT
// override the user, even when an unrelated device event re-runs evaluation.
// (Mirrors production connectedAt > lastManualSwitch, not a time-based debounce.)
do {
    var sim = makeSimulator(
        activeProfileID: officeProfileID,
        connected: [airpods, builtinOut, builtinIn]
    )
    // Headphones (a Home Studio trigger) were already connected 5 minutes ago.
    let past = Date().addingTimeInterval(-300)
    sim.deviceHistory["beyerdynamic-uid"] = DeviceHistoryEntry(
        device: headphones, lastSeen: past, connectedAt: past, isCurrentlyActive: true)
    sim.connectedDevices.append(headphones)
    // User then manually selected Office 1 minute ago (after headphones were already present).
    sim.lastManualSwitchTimestamp = Date().addingTimeInterval(-60)

    // An unrelated device (USB mic) is plugged in now → re-evaluation, but no NEW trigger connection.
    let state = sim.connectDevice(usbMic)
    checkEqual(state.activeProfileName, "Office",
               "AS4: Trigger device present before manual switch does NOT override user on unrelated event")
}

// Test 4b: A trigger device connected AFTER the manual switch DOES override — a fresh
// plug-in is new user intent, so auto-switch is allowed.
do {
    var sim = makeSimulator(
        activeProfileID: officeProfileID,
        connected: [airpods, builtinOut, builtinIn]
    )
    sim.lastManualSwitchTimestamp = Date().addingTimeInterval(-60)  // manual switch 1 min ago

    let state = sim.connectDevice(speakers)  // brand-new connection now → connectedAt > lastManualSwitch
    checkEqual(state.activeProfileName, "Home Studio",
               "AS4b: Trigger device connected after manual switch DOES override (fresh user intent)")
}

// Test 5: Two profiles match, more trigger matches wins
do {
    let multiTriggerProfile = makeProfile(
        id: UUID(),
        name: "Multi Trigger",
        triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"],
        publicOutputPriority: ["speakers-uid"],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let singleTriggerProfile = makeProfile(
        id: UUID(),
        name: "Single Trigger",
        triggerDeviceIDs: ["speakers-uid"],
        publicOutputPriority: ["speakers-uid"],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )

    let allProfiles = [singleTriggerProfile, multiTriggerProfile]
    let deviceIDs: Set<String> = ["speakers-uid", "beyerdynamic-uid"]
    // REAL AudioCore.findBestTriggerMatch — returns a profileID we resolve back.
    let match = AudioCore.findBestTriggerMatch(
        profiles: allProfiles,
        currentDeviceIDs: deviceIDs
    )
    let matchedProfile = match.flatMap { m in allProfiles.first { $0.id == m.profileID } }
    checkEqual(matchedProfile?.name, "Multi Trigger",
               "AS5: Two profiles match, more trigger matches wins")
    checkEqual(match?.matchCount, 2, "AS5b: Winner has match count of 2")
}

// Test 6: Auto-switching disabled → device changes don't switch profiles
do {
    var sim = makeSimulator(
        activeProfileID: systemDefaultID,
        connected: [builtinOut, builtinIn],
        autoSwitch: false
    )
    let state = sim.connectDevice(airpods)
    checkEqual(state.activeProfileName, "System Default",
               "AS6: Auto-switching disabled → AirPods connect doesn't switch profile")
    check(!state.wasAutoSwitched, "AS6b: wasAutoSwitched is false when auto-switch disabled")
}

// Test 7: Auto-switching disabled → priorities still re-evaluate within active profile
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [headphones, builtinOut, builtinIn],
        autoSwitch: false
    )
    let state1 = sim.evaluate()
    checkEqual(state1.outputDeviceUID, "beyerdynamic-uid", "AS7a: Initially headphones")

    let state2 = sim.connectDevice(speakers)
    checkEqual(state2.outputDeviceUID, "speakers-uid",
               "AS7b: Auto-switch off → priorities still re-evaluate within active profile")
}

// ============================================================================
// MARK: - 3. EQ Pipeline (9 tests)
// ============================================================================

section("3. EQ Pipeline")

// Test 1: Non-flat EQ preset → virtual driver activates
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 5.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ

    let state = sim.evaluate()
    check(state.needsVirtualDriver, "EQ1: Non-flat EQ → virtual driver activates")
    checkEqual(state.effectiveEQ.bands[3].gain, 5.0, "EQ1b: EQ correctly applied")
}

// Test 2: Flat EQ → virtual driver stays off
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.deviceEQ["speakers-uid"] = .flat

    let state = sim.evaluate()
    check(!state.needsVirtualDriver, "EQ2: Flat EQ → virtual driver stays off")
}

// Test 3: Bypass EQ → virtual driver stops
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 5.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ
    sim.eqRunning = true
    sim.eqTargetUID = "speakers-uid"
    _ = sim.evaluate()  // establish fingerprint

    let state = sim.toggleGlobalBypass()
    check(!state.needsVirtualDriver, "EQ3: Bypass EQ → virtual driver stops")
    check(state.effectiveEQ.isFlat, "EQ3b: Bypassed EQ is flat")
}

// Test 4: Un-bypass EQ → virtual driver restarts
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 5.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ
    sim.isGlobalBypass = true
    _ = sim.evaluate()  // establish bypassed fingerprint

    let state = sim.toggleGlobalBypass()
    check(state.needsVirtualDriver, "EQ4: Un-bypass → virtual driver restarts")
    check(!state.effectiveEQ.isFlat, "EQ4b: Un-bypassed EQ is non-flat")
}

// Test 5: Content mode overlay combines with device EQ
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 3.0  // device: +3dB at 250Hz

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn],
        soundModesEnabled: true
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ
    sim.activeContentMode = .voice
    sim.contentOverlays[.voice] = ContentModeOverlay.defaultVoice()

    let state = sim.evaluate()
    checkEqual(state.effectiveEQ.bands[3].gain, 3.0,
               "EQ5: Device EQ at 250Hz preserved when content mode active")
    check(state.effectiveEQ.bands[6].gain > 0,
          "EQ5b: Voice overlay boosts 2kHz on top of device EQ")
    check(state.needsVirtualDriver, "EQ5c: Combined non-flat EQ needs virtual driver")
}

// Test 6: Night mode stacks on top of content mode
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn],
        soundModesEnabled: true
    )
    sim.activeContentMode = .voice
    sim.contentOverlays[.voice] = ContentModeOverlay.defaultVoice()
    var nm = NightModeConfig.default
    nm.isEnabled = true
    sim.nightMode = nm

    let stateNoNight = sim.evaluate()
    let stateWithNight = sim.setNightModeActive(true)

    // Night mode cuts bass (-4dB at 32Hz), voice also cuts bass (-2dB) → more negative total
    check(stateWithNight.effectiveEQ.bands[0].gain < stateNoNight.effectiveEQ.bands[0].gain,
          "EQ6: Night mode stacks on content mode — more bass cut than content alone")
}

// Test 7: Global bypass overrides everything to flat
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 8.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn],
        soundModesEnabled: true
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ
    sim.activeContentMode = .voice
    sim.contentOverlays[.voice] = ContentModeOverlay.defaultVoice()
    sim.isNightModeActive = true
    sim.nightMode.isEnabled = true
    sim.isGlobalBypass = true

    let state = sim.evaluate()
    check(state.effectiveEQ.isFlat, "EQ7: Global bypass overrides everything to flat")
    check(!state.needsVirtualDriver, "EQ7b: Global bypass → no virtual driver needed")
}

// Test 7c: Per-device bypass (EQStore.isBypassed) flattens EQ for that device only.
// Production flattens effective EQ when EITHER global bypass OR the resolved device's
// per-device bypass is set — this exercises the per-device branch specifically.
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 6.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ

    let active = sim.evaluate()
    check(active.needsVirtualDriver, "EQ7c-pre: Speaker EQ non-flat → driver needed before per-device bypass")

    let bypassed = sim.setDeviceBypass(true, for: "speakers-uid")
    check(bypassed.effectiveEQ.isFlat,
          "EQ7c: Per-device bypass flattens EQ for the resolved device (global bypass OFF)")
    check(!bypassed.needsVirtualDriver, "EQ7d: Per-device bypass → no virtual driver needed")
}

// Test 8: Switching devices preserves per-device EQ
do {
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 5.0

    var headphoneEQ = EQSettings.flat
    headphoneEQ.bands[7].gain = 3.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn]
    )
    sim.deviceEQ["speakers-uid"] = speakerEQ
    sim.deviceEQ["beyerdynamic-uid"] = headphoneEQ

    let stateSpeakers = sim.evaluate()
    checkEqual(stateSpeakers.effectiveEQ.bands[3].gain, 5.0,
               "EQ8a: Speakers EQ applied when speakers active (public mode)")

    let stateHeadphones = sim.toggleMode()
    checkEqual(stateHeadphones.effectiveEQ.bands[7].gain, 3.0,
               "EQ8b: Headphone EQ applied after mode switch to headphones")
    check(stateHeadphones.effectiveEQ.bands[3].gain < 0.01,
          "EQ8c: Speaker EQ band flat when headphones active (per-device EQ)")
}

// Test 9: No device EQ + active content mode → only overlay applied
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn],
        soundModesEnabled: true
    )
    // No device EQ set
    sim.activeContentMode = .voice
    sim.contentOverlays[.voice] = ContentModeOverlay.defaultVoice()

    let state = sim.evaluate()
    check(state.effectiveEQ.bands[6].gain > 0,
          "EQ9: No device EQ + voice content mode → voice overlay applied as-is")
    check(!state.effectiveEQ.isFlat, "EQ9b: Result is non-flat")
}

// ============================================================================
// MARK: - 4. Mode Switching (4 tests)
// ============================================================================

section("4. Mode Switching")

// Test 1: Toggle to Headphones → headphones selected
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn],
        mode: .public
    )
    let state = sim.toggleMode()
    checkEqual(state.activeMode, .private, "MS1a: Toggled to private mode")
    checkEqual(state.outputDeviceUID, "beyerdynamic-uid",
               "MS1b: Toggle to Headphones → headphones selected")
}

// Test 2: Toggle back to Speakers → speakers selected
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn],
        mode: .private
    )
    let state = sim.toggleMode()
    checkEqual(state.activeMode, .public, "MS2a: Toggled back to public mode")
    checkEqual(state.outputDeviceUID, "speakers-uid",
               "MS2b: Toggle back to Speakers → speakers selected")
}

// Test 3: Mode toggle changes both input and output
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, headphones, builtinOut, builtinIn, usbMic],
        mode: .public
    )
    let statePub = sim.evaluate()
    let statePriv = sim.toggleMode()

    check(statePub.outputDeviceUID != statePriv.outputDeviceUID ||
          statePub.inputDeviceName != statePriv.inputDeviceName,
          "MS3: Mode toggle changes output and/or input device")
}

// Test 4: Only one device connected → same device in both modes
do {
    // AirPods are in both pub and priv priority lists for officeProfile
    var sim = makeSimulator(
        activeProfileID: officeProfileID,
        connected: [airpods, builtinOut, builtinIn],
        mode: .public
    )
    let statePub = sim.evaluate()
    let statePriv = sim.toggleMode()
    checkEqual(statePub.outputDeviceUID, statePriv.outputDeviceUID,
               "MS4: Office profile with AirPods: same device in both modes")
}

// ============================================================================
// MARK: - 5. Fingerprint Deduplication (4 tests)
// ============================================================================

section("5. Fingerprint Deduplication")

// Test 1: Same state evaluated twice → no action second time
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    let state1 = sim.evaluate()
    let state2 = sim.evaluate()
    check(state1.fingerprintChanged, "FD1a: First evaluation triggers action")
    check(!state2.fingerprintChanged, "FD1b: Second identical evaluation → no action (fingerprint unchanged)")
    checkEqual(state2.pipelineAction, PipelineAction.noOp, "FD1c: Pipeline action is noOp on second evaluation")
}

// Test 2: Device change → action taken
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [headphones, builtinOut, builtinIn]
    )
    _ = sim.evaluate()  // establish baseline

    let state = sim.connectDevice(speakers)
    check(state.fingerprintChanged, "FD2: Device change → fingerprint changed → action taken")
    checkEqual(state.outputDeviceUID, "speakers-uid", "FD2b: New output device is speakers")
}

// Test 3: EQ change only → action taken
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    _ = sim.evaluate()  // establish baseline

    var newEQ = EQSettings.flat
    newEQ.bands[3].gain = 4.0
    let state = sim.setEQ(for: "speakers-uid", newEQ)
    check(state.fingerprintChanged, "FD3: EQ change → fingerprint changed → action taken")
    check(!state.effectiveEQ.isFlat, "FD3b: New EQ is non-flat")
}

// Test 4: Profile change, same device → action taken
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [airpods, builtinOut, builtinIn]
    )
    _ = sim.evaluate()

    let state = sim.activateProfile(officeProfileID, isManual: true)
    check(state.fingerprintChanged, "FD4: Profile change → fingerprint changed → action taken")
}

// ============================================================================
// MARK: - 6. Edge Cases (7 tests)
// ============================================================================

section("6. Edge Cases")

// Test 1: Empty profile (no priorities) → falls back to current system default.
// DRIFT FIX: previously asserted nil. Production performEvaluation() falls back to
// pipelineService.getDefaultOutputDevice() when the priority list resolves nothing,
// so an empty priority list yields the system default output, NOT nil.
do {
    let emptyProfileID = UUID()
    let emptyProfile = makeProfile(
        id: emptyProfileID,
        name: "Empty Profile",
        triggerDeviceIDs: [],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    var sim = makeSimulator(
        profiles: [emptyProfile],
        activeProfileID: emptyProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    // System default output modeled as built-in (see makeSimulator).
    sim.currentSystemDefaultOutput = builtinOut
    let state = sim.evaluate()
    checkEqual(state.outputDeviceUID, "builtin-output-uid",
               "EC1: Empty priority list → falls back to current system default output")
}

// Test 2: Profile whose priority devices are all disconnected → falls back to system default.
// DRIFT FIX: previously asserted nil. When NONE of the priority devices are connected,
// production still resolves the current system default output (built-in here), not nil.
do {
    // Create a profile that only lists specific non-builtin devices
    let strictProfile = makeProfile(
        id: UUID(),
        name: "Strict Profile",
        triggerDeviceIDs: [],
        publicOutputPriority: ["speakers-uid", "beyerdynamic-uid"],  // no builtin
        publicInputPriority: ["usb-mic-uid"],
        privateOutputPriority: ["beyerdynamic-uid"],
        privateInputPriority: ["usb-mic-uid"],
        preferredMode: .public
    )
    var sim = makeSimulator(
        profiles: [strictProfile],
        activeProfileID: strictProfile.id,
        connected: [builtinOut, builtinIn]  // none of the priority devices connected
    )
    let state = sim.evaluate()
    checkEqual(state.outputDeviceUID, "builtin-output-uid",
               "EC2: No priority device connected → falls back to current system default output")
}

// Test 3: Night mode start==end → always active (24h, per our fix)
do {
    let nm1 = NightModeConfig(isEnabled: true, startHour: 10, startMinute: 0, endHour: 10, endMinute: 0, overlay: .flat)
    check(nm1.isInQuietHours(), "EC3a: Night mode start==end → always active at any time")

    let nm2 = NightModeConfig(isEnabled: true, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0, overlay: .flat)
    check(nm2.isInQuietHours(), "EC3b: Night mode 00:00==00:00 → always active")
}

// Test 4: System Default profile behaves as fallback.
// DRIFT FIX: EC4b previously asserted nil. System Default has an empty priority list,
// so production falls back to the current system default output (built-in here).
do {
    var sim = makeSimulator(
        activeProfileID: systemDefaultID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.currentSystemDefaultOutput = builtinOut
    let state = sim.evaluate()
    checkEqual(state.activeProfileName, "System Default", "EC4a: System Default profile active")
    checkEqual(state.outputDeviceUID, "builtin-output-uid",
               "EC4b: System Default (empty priority list) → falls back to current system default output")
    check(!state.needsVirtualDriver, "EC4c: System Default with no EQ → no virtual driver")
}

// Test 5: All profiles deleted → still works (doesn't crash)
do {
    var sim = makeSimulator(
        profiles: [],
        activeProfileID: UUID(),
        connected: [builtinOut, builtinIn]
    )
    let state = sim.evaluate()
    check(state.activeProfileName == nil, "EC5a: No profiles → no active profile name")
    check(state.outputDeviceUID == nil, "EC5b: No profiles → no output resolved")
    check(true, "EC5c: Empty profiles array handled gracefully (no crash)")
}

// Test 6: Bypass while EQ not running → stays flat, no error
do {
    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [speakers, builtinOut, builtinIn]
    )
    sim.eqRunning = false
    sim.isGlobalBypass = true

    let state = sim.evaluate()
    check(state.effectiveEQ.isFlat, "EC6: Bypass while EQ not running → flat, no error")
    check(!state.needsVirtualDriver, "EC6b: No virtual driver when bypassed")
}

// Test 7: Device connect while EQ running → hot-switch action
do {
    var headphoneEQ = EQSettings.flat
    headphoneEQ.bands[7].gain = 3.0
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 5.0

    var sim = makeSimulator(
        activeProfileID: homeProfileID,
        connected: [headphones, builtinOut, builtinIn]
    )
    sim.deviceEQ["beyerdynamic-uid"] = headphoneEQ
    sim.deviceEQ["speakers-uid"] = speakerEQ
    sim.eqRunning = true
    sim.eqTargetUID = "beyerdynamic-uid"
    _ = sim.evaluate()  // establish baseline with headphones

    let state = sim.connectDevice(speakers)
    checkEqual(state.outputDeviceUID, "speakers-uid",
               "EC7a: Device connect while EQ running → switches to higher priority device")
    check(state.fingerprintChanged, "EC7b: Fingerprint changed for device hot-switch")
}

// ============================================================================
// MARK: - 7. Persistence Round-Trip (5 tests)
// ============================================================================

section("7. Persistence Round-Trip")

// Test 1: Save profiles → load → identical
do {
    let profiles = [homeProfile, officeProfile, systemDefault]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let data = try encoder.encode(profiles)
    let loaded = try decoder.decode([Profile].self, from: data)

    checkEqual(loaded.count, profiles.count, "RT1a: Same profile count after round-trip")
    for (original, restored) in zip(profiles, loaded) {
        checkEqual(original.id, restored.id, "RT1b: Profile ID preserved: \(original.name)")
        checkEqual(original.name, restored.name, "RT1c: Profile name preserved: \(original.name)")
    }
}

// Test 2: Profile with trigger rules → round-trip preserved
do {
    let profileWithRules = makeProfile(
        id: UUID(),
        name: "BT Profile",
        triggerDeviceIDs: [],
        triggerRules: [
            .specificDevice(id: "airpods-uid"),
            .transportType(type: "Bluetooth")
        ],
        publicOutputPriority: ["airpods-uid"],
        publicInputPriority: ["airpods-uid"],
        privateOutputPriority: ["airpods-uid"],
        privateInputPriority: ["airpods-uid"],
        preferredMode: .public
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(profileWithRules)
    let loaded = try decoder.decode(Profile.self, from: data)

    checkEqual(loaded.triggerRules.count, 2, "RT2a: Trigger rules count preserved")
    checkEqual(loaded.triggerRules[0], .specificDevice(id: "airpods-uid"),
               "RT2b: specificDevice rule preserved")
    checkEqual(loaded.triggerRules[1], .transportType(type: "Bluetooth"),
               "RT2c: transportType rule preserved")
}

// Test 3: Empty list → round-trip preserved
do {
    let profiles: [Profile] = []
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(profiles)
    let loaded = try decoder.decode([Profile].self, from: data)
    checkEqual(loaded.count, 0, "RT3: Empty list round-trips to empty list")
}

// Test 4: Profile with all fields → every field preserved
do {
    let fullProfile = Profile(
        id: UUID(),
        name: "Full Profile",
        iconName: "headphones",
        triggerDeviceIDs: ["dev-1", "dev-2"],
        publicOutputPriority: ["dev-1", "dev-2"],
        publicInputPriority: ["dev-3"],
        privateOutputPriority: ["dev-2", "dev-1"],
        privateInputPriority: ["dev-3", "dev-4"],
        preferredMode: .private,
        isSystemDefault: false
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(fullProfile)
    let loaded = try decoder.decode(Profile.self, from: data)

    checkEqual(loaded.iconName, "headphones", "RT4a: iconName preserved")
    checkEqual(loaded.publicOutputPriority, ["dev-1", "dev-2"], "RT4b: publicOutputPriority preserved")
    checkEqual(loaded.publicInputPriority, ["dev-3"], "RT4c: publicInputPriority preserved")
    checkEqual(loaded.privateOutputPriority, ["dev-2", "dev-1"], "RT4d: privateOutputPriority preserved")
    checkEqual(loaded.privateInputPriority, ["dev-3", "dev-4"], "RT4e: privateInputPriority preserved")
    checkEqual(loaded.preferredMode, .private, "RT4f: preferredMode preserved")
    checkEqual(loaded.isSystemDefault, false, "RT4g: isSystemDefault preserved")
}

// Test 5: Legacy profile (no triggerRules) → migrates via the REAL Profile decoder.
// This exercises production Profile.init(from:) directly (no local mirror): missing
// triggerRules are migrated from triggerDeviceIDs, and — critically — a missing
// isSystemDefault key is INFERRED from name == "System Default".
do {
    // Legacy JSON: has triggerDeviceIDs but NO triggerRules, and NO isSystemDefault key.
    let legacyJSON = """
    {
        "id": "12345678-1234-1234-1234-123456789012",
        "name": "Legacy Profile",
        "iconName": "speaker",
        "triggerDeviceIDs": ["device-a", "device-b"],
        "publicOutputPriority": ["device-a"],
        "publicInputPriority": ["device-b"],
        "privateOutputPriority": ["device-a"],
        "privateInputPriority": ["device-b"],
        "preferredMode": "public"
    }
    """
    let data = legacyJSON.data(using: .utf8)!

    // Decode straight into the REAL Profile — no throwaway mirror.
    let legacy = try JSONDecoder().decode(Profile.self, from: data)

    checkEqual(legacy.triggerDeviceIDs, ["device-a", "device-b"],
               "RT5a: Legacy profile triggerDeviceIDs loaded")
    checkEqual(legacy.triggerRules.count, 2, "RT5b: Real decoder migrated to 2 triggerRules")
    checkEqual(legacy.triggerRules[0], .specificDevice(id: "device-a"),
               "RT5c: First rule migrated correctly by real decoder")
    checkEqual(legacy.triggerRules[1], .specificDevice(id: "device-b"),
               "RT5d: Second rule migrated correctly by real decoder")
    check(!legacy.isSystemDefault,
          "RT5e: Missing isSystemDefault + non-default name → inferred false")

    // Legacy JSON named "System Default" with NO isSystemDefault key → inferred true.
    let legacySystemDefaultJSON = """
    {
        "id": "22345678-1234-1234-1234-123456789012",
        "name": "System Default",
        "iconName": "speaker",
        "triggerDeviceIDs": [],
        "publicOutputPriority": [],
        "publicInputPriority": [],
        "privateOutputPriority": [],
        "privateInputPriority": []
    }
    """
    let sdData = legacySystemDefaultJSON.data(using: .utf8)!
    let legacySD = try JSONDecoder().decode(Profile.self, from: sdData)
    check(legacySD.isSystemDefault,
          "RT5f: Missing isSystemDefault + name == 'System Default' → inferred true (real migration)")

    // Round-trip through the real encoder: triggerDeviceIDs must ALWAYS be written.
    let reencoded = try JSONEncoder().encode(legacy)
    let obj = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
    check((obj?["triggerDeviceIDs"] as? [String]) == ["device-a", "device-b"],
          "RT5g: Real encoder always writes triggerDeviceIDs for backward compat")
    check(obj?["hotkey"] == nil,
          "RT5h: Real encoder no longer writes the removed hotkey field")
}

// ============================================================================
// MARK: - Summary
// ============================================================================

print("\n════════════════════════════════════════════════════════")
print("  BehaviorTests Summary")
print("════════════════════════════════════════════════════════")
print("  Total:  \(totalTests)")
print("  Passed: \(passedTests)")
print("  Failed: \(failedTests)")
if failedTests == 0 {
    print("  ✅ All tests passed!")
} else {
    print("  ❌ \(failedTests) test(s) FAILED")
}
print("════════════════════════════════════════════════════════")
exit(failedTests > 0 ? 1 : 0)
