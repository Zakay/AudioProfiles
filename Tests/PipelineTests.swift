// SHARED: AudioProfiles/Models/AudioDevice.swift AudioProfiles/Models/ProfileMode.swift AudioProfiles/Models/Hotkey.swift AudioProfiles/Models/Profile.swift AudioProfiles/Models/DeviceHistoryEntry.swift AudioProfiles/Models/EQSettings.swift AudioProfiles/Models/EQSettings+Combine.swift AudioProfiles/Core/AudioCore.swift
//
// PipelineTests.swift
//
// Tests for the unidirectional pipeline, device priority resolution,
// EQ layer combination, fingerprint dedup, and profile trigger matching.
//
// This file compiles against the REAL production models and canonical core logic
// (see the `// SHARED:` directive above — build.sh compiles those Foundation-only
// sources alongside this test). AudioDevice, ProfileMode, EQSettings, EQBand,
// EQFilterType, TriggerRule, Profile, and EQSettings.combine are the shipped types.
// AudioCore.findBestTriggerMatch and AudioCore.computeReadPlan are the shipped logic.
//
// What is NOT in a shared file and is therefore kept as a clearly-labelled LOCAL
// MIRROR (faithful to current production, pending extraction into AudioCore):
//   - Device priority resolution flow (ProfileManager.performEvaluation)
//   - AudioPipelineService.apply action selection
//   - PipelineFingerprint (production's is a PRIVATE struct in ProfileManager —
//     it cannot be imported; the mirror here only proves structural equality)
//
// Run: swift Tests/PipelineTests.swift   (or via build.sh, which honours // SHARED:)
//
// These tests validate:
//   1. Device priority resolution — picks highest-priority connected device
//   2. Device fallback — falls back down priority list when top device disappears
//   3. Device re-resolution — picks higher-priority device when it appears
//   4. EQ layer combination (L1 base + L2 overlay)
//   5. EQ flat detection
//   6. Pipeline fingerprint dedup
//   7. Profile trigger matching (best match by device count)
//   8. Profile mode switching (public vs private priority lists)
//   9. Virtual driver need determination
//  10. Same-profile device change re-evaluation

import Foundation

// ============================================================================
// MARK: - Structural mirror: PipelineFingerprint
// ============================================================================
//
// PRODUCTION MIRROR (structural only). The real `PipelineFingerprint` is a
// PRIVATE struct inside `ProfileManager` and cannot be imported. This copy is a
// byte-for-byte field mirror so the dedup *shape* can be exercised. The equality
// tests below therefore only prove that Swift synthesises `Equatable` field-wise —
// they do NOT test production's actual dedup call site. Kept for regression value
// on the fingerprint field set; labelled honestly so nobody mistakes it for a
// production integration test.
struct PipelineFingerprint: Equatable {
    let profileID: UUID?
    let mode: ProfileMode
    let outputDeviceUID: String?
    let inputDeviceUID: String?
    let effectiveEQ: EQSettings
    let needsVirtualDriver: Bool
}

// ============================================================================
// MARK: - Test convenience: Profile builder + trigger-match wrapper
// ============================================================================

/// Thin convenience over the real `Profile.init`, which requires `iconName`.
/// Keeps the (many) call sites below terse while constructing the SHIPPED type.
func makeProfile(
    id: UUID = UUID(),
    name: String,
    triggerDeviceIDs: [String],
    triggerRules: [TriggerRule]? = nil,
    publicOutputPriority: [String], publicInputPriority: [String],
    privateOutputPriority: [String], privateInputPriority: [String],
    preferredMode: ProfileMode = .public,
    isSystemDefault: Bool = false
) -> Profile {
    Profile(
        id: id, name: name, iconName: "speaker",
        triggerDeviceIDs: triggerDeviceIDs,
        triggerRules: triggerRules,
        publicOutputPriority: publicOutputPriority,
        publicInputPriority: publicInputPriority,
        privateOutputPriority: privateOutputPriority,
        privateInputPriority: privateInputPriority,
        preferredMode: preferredMode,
        isSystemDefault: isSystemDefault
    )
}

/// Result wrapper so existing assertions on `.profile` keep working while the
/// match itself is computed by the REAL `AudioCore.findBestTriggerMatch`, which
/// returns a `profileID` (not the profile object). We resolve the ID back to the
/// profile here — no matching logic is reimplemented.
struct TriggerMatchResult {
    let profile: Profile
    let matchCount: Int
    let specificCount: Int
    let primaryTriggerDevice: String
}

func findBestTriggerMatch(
    profiles: [Profile],
    currentDeviceIDs: Set<String>,
    currentDevices: [AudioDevice] = []
) -> TriggerMatchResult? {
    guard let m = AudioCore.findBestTriggerMatch(
        profiles: profiles,
        currentDeviceIDs: currentDeviceIDs,
        currentDevices: currentDevices
    ) else { return nil }
    guard let profile = profiles.first(where: { $0.id == m.profileID }) else { return nil }
    return TriggerMatchResult(
        profile: profile,
        matchCount: m.matchCount,
        specificCount: m.specificCount,
        primaryTriggerDevice: m.primaryTriggerDevice
    )
}

// ============================================================================
// MARK: - LOCAL MIRROR: device priority resolution (pending extraction)
// ============================================================================
//
// PRODUCTION MIRROR of `ProfileManager.performEvaluation`'s output resolution
// walk. NOT yet in AudioCore. Faithful to production semantics:
//   - Walk the priority list; the FIRST connected output whose id matches wins.
//   - Virtual-device look-through: when the matched entry IS our virtual device,
//     production resolves to the real EQ target ONLY when EQ is running AND that
//     target is connected. Otherwise it leaves the resolution nil and `break`s —
//     it does NOT `continue` to the next priority entry. (This is the fixed drift:
//     the old reimplementation used `continue`.) Falling through to nil lets the
//     caller apply system-default resolution, exactly as production does.
func resolveOutputDevice(
    priorityList: [String],
    connectedDevices: [AudioDevice],
    virtualDeviceUID: String? = nil,
    eqRunning: Bool = false,
    eqTargetUID: String? = nil
) -> (device: AudioDevice, uid: String)? {
    for deviceID in priorityList {
        if let device = connectedDevices.first(where: { $0.id == deviceID && $0.isOutput }) {
            // Is this our virtual device? Look through to the real EQ target.
            if let vUID = virtualDeviceUID, device.id == vUID {
                if eqRunning, let realUID = eqTargetUID,
                   let realDevice = connectedDevices.first(where: { $0.id == realUID && $0.isOutput }) {
                    return (realDevice, realUID)
                }
                // Virtual entry but EQ not running / target absent → production does
                // nothing in this branch and then `break`s out of the walk (matches
                // `performEvaluation`). Result stays nil → caller uses system default.
                break
            }
            return (device, device.id)
        }
    }
    return nil
}

/// Resolve the best input device from a priority list, given connected devices.
/// Mirrors `ProfileManager.performEvaluation`'s input walk (first connected input wins).
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

// ============================================================================
// MARK: - Test infrastructure
// ============================================================================

var totalTests = 0
var passedTests = 0
var failedTests = 0
var currentSection = ""

func section(_ name: String) {
    currentSection = name
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
        print("  ❌ FAIL: \(message) (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    totalTests += 1
    if a == b {
        passedTests += 1
        print("  ✅ \(message)")
    } else {
        failedTests += 1
        print("  ❌ FAIL: \(message) — got '\(a)', expected '\(b)' (line \(line))")
    }
}

// ============================================================================
// MARK: - Test fixtures
// ============================================================================

let speakers = AudioDevice(id: "speakers-uid", name: "Studio Monitors", transportType: "Built-In", isInput: false, isOutput: true)
let headphones = AudioDevice(id: "beyerdynamic-uid", name: "Beyerdynamic DT 990", transportType: "USB", isInput: false, isOutput: true)
let bluetooth = AudioDevice(id: "airpods-uid", name: "AirPods Max", transportType: "Bluetooth", isInput: true, isOutput: true)
let builtinOutput = AudioDevice(id: "builtin-output-uid", name: "MacBook Pro Speakers", transportType: "Built-In", isInput: false, isOutput: true)
let builtinInput = AudioDevice(id: "builtin-input-uid", name: "MacBook Pro Microphone", transportType: "Built-In", isInput: true, isOutput: false)
let usbMic = AudioDevice(id: "usb-mic-uid", name: "Blue Yeti", transportType: "USB", isInput: true, isOutput: false)
let virtualDevice = AudioDevice(id: "virtual-eq-uid", name: "Studio Monitors EQ", transportType: "Other", isInput: false, isOutput: true)

let homeProfile = makeProfile(
    name: "Home Studio",
    triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"],
    publicOutputPriority: ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"],
    publicInputPriority: ["usb-mic-uid", "builtin-input-uid"],
    privateOutputPriority: ["beyerdynamic-uid", "speakers-uid", "builtin-output-uid"],
    privateInputPriority: ["usb-mic-uid", "builtin-input-uid"],
    preferredMode: .public
)

let officeProfile = makeProfile(
    name: "Office",
    triggerDeviceIDs: ["airpods-uid"],
    publicOutputPriority: ["airpods-uid", "builtin-output-uid"],
    publicInputPriority: ["airpods-uid", "builtin-input-uid"],
    privateOutputPriority: ["airpods-uid", "builtin-output-uid"],
    privateInputPriority: ["airpods-uid", "builtin-input-uid"],
    preferredMode: .public
)

let systemDefault = makeProfile(
    name: "System Default",
    triggerDeviceIDs: [],
    publicOutputPriority: [],
    publicInputPriority: [],
    privateOutputPriority: [],
    privateInputPriority: [],
    preferredMode: .public,
    isSystemDefault: true
)

// ============================================================================
// MARK: - Test: Device Priority Resolution
// ============================================================================

section("Device Priority Resolution — Basic")

do {
    // All devices connected: should pick speakers (first in public output priority)
    let devices = [speakers, headphones, builtinOutput, builtinInput, usbMic]
    let result = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "speakers-uid", "Public mode picks speakers (highest priority)")
}

do {
    // All devices connected, private mode: should pick headphones (first in private output priority)
    let devices = [speakers, headphones, builtinOutput, builtinInput, usbMic]
    let result = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "beyerdynamic-uid", "Private mode picks headphones (highest priority)")
}

do {
    // Input resolution: USB mic connected → picks it
    let devices = [speakers, headphones, builtinOutput, builtinInput, usbMic]
    let result = resolveInputDevice(
        priorityList: homeProfile.priorityList(isOutput: false, mode: .public),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "usb-mic-uid", "Input picks USB mic (highest priority)")
}

do {
    // Input resolution: USB mic NOT connected → falls back to builtin
    let devices = [speakers, headphones, builtinOutput, builtinInput]
    let result = resolveInputDevice(
        priorityList: homeProfile.priorityList(isOutput: false, mode: .public),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "builtin-input-uid", "Input falls back to builtin mic")
}

// ============================================================================
// MARK: - Test: Device Fallback (top device disappears)
// ============================================================================

section("Device Priority Resolution — Fallback")

do {
    // Speakers OFF → should fall back to headphones
    let devices = [headphones, builtinOutput, builtinInput, usbMic]
    let result = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "beyerdynamic-uid", "Speakers off → falls back to headphones")
}

do {
    // Both speakers and headphones OFF → falls back to builtin
    let devices = [builtinOutput, builtinInput, usbMic]
    let result = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "builtin-output-uid", "Speakers+headphones off → falls back to builtin")
}

do {
    // ALL priority devices gone → returns nil (caller uses system default)
    let devices = [builtinInput]  // Only input device connected
    let result = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    check(result == nil, "No output priority devices connected → returns nil")
}

do {
    // Private mode: headphones off → falls back to speakers
    let devices = [speakers, builtinOutput, builtinInput]
    let result = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: devices
    )
    checkEqual(result?.uid, "speakers-uid", "Private: headphones off → falls back to speakers")
}

// ============================================================================
// MARK: - Test: Device Re-resolution (higher-priority device appears)
// ============================================================================

section("Device Priority Resolution — Re-resolution (THE BUG SCENARIO)")

do {
    // Step 1: Speakers OFF → headphones selected
    let devicesWithout = [headphones, builtinOutput, builtinInput, usbMic]
    let result1 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devicesWithout
    )
    checkEqual(result1?.uid, "beyerdynamic-uid", "Step 1: speakers off → headphones selected")

    // Step 2: Speakers turn ON → speakers should now be selected (higher priority)
    let devicesWith = [speakers, headphones, builtinOutput, builtinInput, usbMic]
    let result2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devicesWith
    )
    checkEqual(result2?.uid, "speakers-uid", "Step 2: speakers on → speakers selected (higher priority)")

    // Verify the UIDs differ — this is what the fingerprint would catch
    check(result1?.uid != result2?.uid, "Resolved device changed — fingerprint will differ, pipeline will re-apply")
}

do {
    // Opposite: irrelevant device connects → same device stays
    let devices1 = [headphones, builtinOutput, builtinInput]
    let result1 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices1
    )

    // Add USB mic (input device, doesn't affect output resolution)
    let devices2 = [headphones, builtinOutput, builtinInput, usbMic]
    let result2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices2
    )
    checkEqual(result1?.uid, result2?.uid, "Irrelevant device connect → same output device (fingerprint unchanged)")
}

// ============================================================================
// MARK: - Test: Device removal (current device disconnects)
// ============================================================================

section("Device Priority Resolution — Removal")

do {
    // Currently using speakers, speakers disconnect → headphones take over
    let before = [speakers, headphones, builtinOutput]
    let after  = [headphones, builtinOutput]

    let resultBefore = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: before
    )
    let resultAfter = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: after
    )

    checkEqual(resultBefore?.uid, "speakers-uid", "Before removal: speakers")
    checkEqual(resultAfter?.uid, "beyerdynamic-uid", "After removal: headphones take over")
    check(resultBefore?.uid != resultAfter?.uid, "Device changed → pipeline re-applies")
}

do {
    // Currently using headphones (private mode), headphones disconnect
    let before = [speakers, headphones, builtinOutput]
    let after  = [speakers, builtinOutput]

    let resultBefore = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: before
    )
    let resultAfter = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: after
    )

    checkEqual(resultBefore?.uid, "beyerdynamic-uid", "Private before: headphones")
    checkEqual(resultAfter?.uid, "speakers-uid", "Private after: speakers take over")
}

// ============================================================================
// MARK: - Test: Virtual device look-through
// ============================================================================

section("Virtual Device Look-through")

do {
    // Virtual device FIRST in priority, EQ running, but the real EQ target is NOT
    // connected. FIXED DRIFT: the old reimplementation `continue`d and fell back to
    // headphones. Production `performEvaluation` `break`s after the virtual entry
    // matched but could not be looked through → resolution stays nil → caller uses
    // system default. Old expectation: result == headphones. New: result == nil.
    let devices = [virtualDevice, headphones, builtinOutput]
    let priority = ["virtual-eq-uid", "beyerdynamic-uid", "builtin-output-uid"]
    let result = resolveOutputDevice(
        priorityList: priority,
        connectedDevices: devices,
        virtualDeviceUID: "virtual-eq-uid",
        eqRunning: true,
        eqTargetUID: "speakers-uid"  // EQ targets speakers, which is NOT connected
    )
    check(result == nil, "Virtual first + EQ target absent → break, fall through to system default (production `break`)")
}

do {
    // Virtual device in priority list, EQ running, real device connected
    let devices = [virtualDevice, speakers, headphones, builtinOutput]
    let priority = ["virtual-eq-uid", "beyerdynamic-uid", "builtin-output-uid"]
    let result = resolveOutputDevice(
        priorityList: priority,
        connectedDevices: devices,
        virtualDeviceUID: "virtual-eq-uid",
        eqRunning: true,
        eqTargetUID: "speakers-uid"
    )
    checkEqual(result?.uid, "speakers-uid", "Virtual device resolves to real target (speakers)")
    checkEqual(result?.device.name, "Studio Monitors", "Device name is the real device")
}

do {
    // Virtual device is FIRST in priority list, EQ NOT running.
    // FIXED DRIFT: the old reimplementation used `continue`, so it walked past the
    // virtual entry and picked headphones. Production `performEvaluation` uses
    // `break` — the virtual entry matched (it IS connected), so the loop stops, no
    // real device is resolved, and resolution falls through to the system default.
    // Old expectation: result == headphones. New expectation: result == nil.
    let devices = [virtualDevice, headphones, builtinOutput]
    let priority = ["virtual-eq-uid", "beyerdynamic-uid", "builtin-output-uid"]
    let result = resolveOutputDevice(
        priorityList: priority,
        connectedDevices: devices,
        virtualDeviceUID: "virtual-eq-uid",
        eqRunning: false,
        eqTargetUID: nil
    )
    check(result == nil, "EQ not running + virtual is first priority → break, fall through to system default (production `break` semantics)")
}

do {
    // Corollary: when EQ is not running and the virtual device is NOT first, a
    // higher-priority real device still resolves normally (the break only triggers
    // once the virtual entry is the one matched).
    let devices = [headphones, virtualDevice, builtinOutput]
    let priority = ["beyerdynamic-uid", "virtual-eq-uid", "builtin-output-uid"]
    let result = resolveOutputDevice(
        priorityList: priority,
        connectedDevices: devices,
        virtualDeviceUID: "virtual-eq-uid",
        eqRunning: false,
        eqTargetUID: nil
    )
    checkEqual(result?.uid, "beyerdynamic-uid", "Real device ahead of virtual entry resolves normally")
}

// ============================================================================
// MARK: - Test: Profile mode switching
// ============================================================================

section("Profile Mode Switching")

do {
    let devices = [speakers, headphones, builtinOutput, builtinInput, usbMic]

    let publicOutput = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    let privateOutput = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: devices
    )

    checkEqual(publicOutput?.uid, "speakers-uid", "Public mode → speakers")
    checkEqual(privateOutput?.uid, "beyerdynamic-uid", "Private mode → headphones")
    check(publicOutput?.uid != privateOutput?.uid, "Mode toggle changes resolved device")
}

do {
    // Office profile: same device in both modes
    let devices = [bluetooth, builtinOutput, builtinInput]
    let pub = resolveOutputDevice(
        priorityList: officeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    let priv = resolveOutputDevice(
        priorityList: officeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: devices
    )
    checkEqual(pub?.uid, priv?.uid, "Office profile: same device in both modes (AirPods)")
}

// ============================================================================
// MARK: - Test: EQ Settings
// ============================================================================

section("EQ Settings — Flat Detection")

do {
    let flat = EQSettings.flat
    check(flat.isFlat, "Default flat EQ is flat")
    checkEqual(flat.preamp, 0, "Flat preamp is 0")
    checkEqual(flat.bands.count, 10, "10 bands")
    check(flat.bands.allSatisfy(\.isFlat), "All bands are flat")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 3.0
    check(!eq.isFlat, "EQ with one non-zero band is NOT flat")
}

do {
    var eq = EQSettings.flat
    eq.preamp = 2.0
    check(!eq.isFlat, "EQ with non-zero preamp is NOT flat")
}

do {
    var eq = EQSettings.flat
    eq.bands[0].gain = 0.005  // Below threshold
    check(eq.isFlat, "EQ with gain < 0.01 is still flat")
}

// ============================================================================
// MARK: - Test: EQ Layer Combination
// ============================================================================

section("EQ Layer Combination (L1 base + L2 overlay)")

do {
    // Flat overlay → returns base unchanged
    var base = EQSettings.flat
    base.bands[2].gain = 3.0
    base.preamp = -2.0

    let result = EQSettings.combine(base: base, overlay: .flat)
    checkEqual(result, base, "Flat overlay returns base unchanged")
}

do {
    // Flat base + non-flat overlay → overlay gains with base structure
    var overlay = EQSettings.flat
    overlay.bands[5].gain = 4.0  // 1kHz +4dB

    let result = EQSettings.combine(base: .flat, overlay: overlay)
    checkEqual(result.bands[5].gain, 4.0, "Flat base: overlay gain applied")
    check(result.bands[0].filterType == .lowShelf, "Flat base: filter types preserved from base")
    check(result.bands[9].filterType == .highShelf, "Flat base: high shelf preserved from base")
}

do {
    // Both non-flat → additive
    var base = EQSettings.flat
    base.bands[3].gain = 5.0   // 250Hz +5dB
    base.preamp = -3.0

    var overlay = EQSettings.flat
    overlay.bands[3].gain = 4.0  // 250Hz +4dB
    overlay.preamp = 1.0

    let result = EQSettings.combine(base: base, overlay: overlay)
    checkEqual(result.bands[3].gain, 9.0, "Additive: 5 + 4 = 9 dB")
    checkEqual(result.preamp, -2.0, "Additive preamp: -3 + 1 = -2")
}

do {
    // Additive clamping at ±12 dB
    var base = EQSettings.flat
    base.bands[0].gain = 10.0

    var overlay = EQSettings.flat
    overlay.bands[0].gain = 8.0

    let result = EQSettings.combine(base: base, overlay: overlay)
    checkEqual(result.bands[0].gain, 12.0, "Clamped at +12 dB (10 + 8 → 12)")
}

do {
    // Negative clamping
    var base = EQSettings.flat
    base.bands[0].gain = -10.0

    var overlay = EQSettings.flat
    overlay.bands[0].gain = -5.0

    let result = EQSettings.combine(base: base, overlay: overlay)
    checkEqual(result.bands[0].gain, -12.0, "Clamped at -12 dB (-10 + -5 → -12)")
}

do {
    // Preamp clamping
    var base = EQSettings.flat
    base.preamp = 10.0

    var overlay = EQSettings.flat
    overlay.preamp = 8.0

    let result = EQSettings.combine(base: base, overlay: overlay)
    checkEqual(result.preamp, 12.0, "Preamp clamped at +12")
}

do {
    // Multiple bands combined
    var base = EQSettings.flat
    base.bands[0].gain = 2.0
    base.bands[3].gain = -3.0
    base.bands[7].gain = 5.0

    var overlay = EQSettings.flat
    overlay.bands[0].gain = -1.0
    overlay.bands[3].gain = 1.5
    overlay.bands[7].gain = -2.0

    let result = EQSettings.combine(base: base, overlay: overlay)
    checkEqual(result.bands[0].gain, 1.0, "Band 0: 2 + (-1) = 1")
    checkEqual(result.bands[3].gain, -1.5, "Band 3: -3 + 1.5 = -1.5")
    checkEqual(result.bands[7].gain, 3.0, "Band 7: 5 + (-2) = 3")
    check(result.bands[1].isFlat, "Untouched band stays flat")
    check(result.bands[5].isFlat, "Another untouched band stays flat")
}

do {
    // Two flat → flat
    let result = EQSettings.combine(base: .flat, overlay: .flat)
    check(result.isFlat, "Flat + flat = flat")
}

// ============================================================================
// MARK: - Test: Virtual Driver Need Determination
// ============================================================================

section("Virtual Driver Need")

do {
    let flat = EQSettings.flat
    let driverInstalled = true
    let need = !flat.isFlat && driverInstalled
    check(!need, "Flat EQ → no virtual driver needed")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let driverInstalled = true
    let need = !eq.isFlat && driverInstalled
    check(need, "Non-flat EQ + driver installed → virtual driver needed")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let driverInstalled = false
    let need = !eq.isFlat && driverInstalled
    check(!need, "Non-flat EQ + driver NOT installed → no virtual driver")
}

// ============================================================================
// MARK: - Test: Pipeline Fingerprint Dedup (STRUCTURAL MIRROR)
// ============================================================================
//
// NOTE: production's `PipelineFingerprint` is a PRIVATE struct inside ProfileManager
// and cannot be imported. These tests use the local structural mirror, so they only
// prove that Swift synthesises field-wise `Equatable` for that field set — they do
// NOT exercise production's dedup call site (`if fingerprint == lastFingerprint`).
// Kept for regression value on the field set; not an integration test.
section("Pipeline Fingerprint Dedup (structural mirror)")

do {
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fp1 == fp2, "Identical fingerprints are equal")
}

do {
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "beyerdynamic-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fp1 != fp2, "Different output device → different fingerprint")
}

do {
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .private,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fp1 != fp2, "Different mode → different fingerprint")
}

do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0

    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: eq, needsVirtualDriver: true
    )
    check(fp1 != fp2, "Different EQ → different fingerprint")
}

do {
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: officeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fp1 != fp2, "Different profile ID → different fingerprint")
}

do {
    // Input device change
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "builtin-input-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fp1 != fp2, "Different input device → different fingerprint")
}

do {
    // needsVirtualDriver change only
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: true
    )
    check(fp1 != fp2, "Different needsVirtualDriver → different fingerprint")
}

// ============================================================================
// MARK: - Test: Fingerprint scenario — same profile, device added
// ============================================================================

section("Fingerprint Scenario — Same Profile, Device Change")

do {
    // Step 1: speakers off → headphones resolved
    let devicesWithout = [headphones, builtinOutput, builtinInput, usbMic]
    let result1 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devicesWithout
    )
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: result1?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    // Step 2: speakers turn ON → speakers resolved
    let devicesWith = [speakers, headphones, builtinOutput, builtinInput, usbMic]
    let result2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devicesWith
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: result2?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    check(fp1 != fp2, "Speaker connects → fingerprint changes → pipeline re-applies (bug scenario)")
    checkEqual(fp1.outputDeviceUID, "beyerdynamic-uid", "Before: headphones")
    checkEqual(fp2.outputDeviceUID, "speakers-uid", "After: speakers")
}

do {
    // Step 1 & 2: irrelevant device connects → fingerprint unchanged
    let devices1 = [headphones, builtinOutput, builtinInput]
    let result1 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices1
    )
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: result1?.uid, inputDeviceUID: "builtin-input-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    // Add bluetooth (not in this profile's priority list)
    let devices2 = [headphones, builtinOutput, builtinInput, bluetooth]
    let result2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices2
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: result2?.uid, inputDeviceUID: "builtin-input-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    check(fp1 == fp2, "Irrelevant device connect → fingerprint unchanged → pipeline skips (efficient)")
}

// ============================================================================
// MARK: - Test: Profile Trigger Matching
// ============================================================================

section("Profile Trigger Matching")

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // Home devices connected: both speakers and headphones → home profile matches (2 triggers)
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid", "builtin-input-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Home Studio", "Both triggers connected → Home profile")
    checkEqual(match?.matchCount, 2, "Match count = 2 (speakers + headphones)")
}

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // Only AirPods connected → office profile
    let devices: Set<String> = ["airpods-uid", "builtin-output-uid", "builtin-input-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Office", "AirPods connected → Office profile")
    checkEqual(match?.matchCount, 1, "Match count = 1")
}

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // Only builtin devices → no triggers match
    let devices: Set<String> = ["builtin-output-uid", "builtin-input-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    check(match == nil, "No trigger devices → no match → falls back to System Default")
}

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // Both home and office triggers connected: home has 2 matches, office has 1
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid", "airpods-uid", "builtin-output-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Home Studio", "Home wins with 2 matches vs Office's 1")
}

do {
    // Only one home trigger device connected → still matches home (1 trigger is enough)
    let allProfiles = [systemDefault, homeProfile, officeProfile]
    let devices: Set<String> = ["beyerdynamic-uid", "builtin-output-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Home Studio", "Single trigger device → still matches")
    checkEqual(match?.matchCount, 1, "Match count = 1")
}

do {
    // System Default has no triggers → never matches
    let allProfiles = [systemDefault]
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    check(match == nil, "System Default has empty triggerDeviceIDs → never matches")
}

// ============================================================================
// MARK: - Test: Trigger + Priority combined scenario
// ============================================================================

section("Trigger + Priority Combined — Full Scenario")

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // Scenario: Start with only builtin → System Default
    let devices1: Set<String> = ["builtin-output-uid", "builtin-input-uid"]
    let match1 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices1)
    check(match1 == nil, "Step 1: only builtin → no match (System Default)")

    // User plugs in headphones → Home profile triggers
    let devices2: Set<String> = ["beyerdynamic-uid", "builtin-output-uid", "builtin-input-uid"]
    let match2 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices2)
    checkEqual(match2?.profile.name, "Home Studio", "Step 2: headphones plug in → Home profile")

    // Home profile, public mode, only headphones → resolves to headphones (speakers not connected)
    let connectedDevices2 = [headphones, builtinOutput, builtinInput]
    let output2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: connectedDevices2
    )
    checkEqual(output2?.uid, "beyerdynamic-uid", "Step 2: output = headphones (speakers off)")

    // User turns on speakers → same profile, but higher-priority device available
    let devices3: Set<String> = ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid", "builtin-input-uid"]
    let match3 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices3)
    checkEqual(match3?.profile.name, "Home Studio", "Step 3: still Home profile")

    let connectedDevices3 = [speakers, headphones, builtinOutput, builtinInput]
    let output3 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: connectedDevices3
    )
    checkEqual(output3?.uid, "speakers-uid", "Step 3: output switches to speakers (higher priority)")

    // User unplugs speakers → back to headphones
    let devices4: Set<String> = ["beyerdynamic-uid", "builtin-output-uid", "builtin-input-uid"]
    let match4 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices4)
    checkEqual(match4?.profile.name, "Home Studio", "Step 4: still Home profile")

    let connectedDevices4 = [headphones, builtinOutput, builtinInput]
    let output4 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: connectedDevices4
    )
    checkEqual(output4?.uid, "beyerdynamic-uid", "Step 4: back to headphones")
}

// ============================================================================
// MARK: - Test: EQ with device changes — combined
// ============================================================================

section("EQ + Device Changes Combined")

do {
    // Device has EQ preset → virtual driver needed
    var deviceEQ = EQSettings.flat
    deviceEQ.bands[3].gain = 5.0
    deviceEQ.bands[7].gain = -3.0

    let effectiveEQ = EQSettings.combine(base: deviceEQ, overlay: .flat)
    let needsVirtualDriver = !effectiveEQ.isFlat && true  // driver installed
    check(needsVirtualDriver, "Device with EQ preset → virtual driver needed")

    let fp = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: effectiveEQ, needsVirtualDriver: needsVirtualDriver
    )

    // Switch to device without EQ
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "beyerdynamic-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    check(fp != fp2, "Switching from EQ device to non-EQ device → different fingerprint")
}

do {
    // Sound modes overlay stacks on device EQ
    var deviceEQ = EQSettings.flat
    deviceEQ.bands[3].gain = 3.0  // Device correction: 250Hz +3dB

    var overlay = EQSettings.flat
    overlay.bands[5].gain = 2.0   // Content mode: 1kHz +2dB

    let effective = EQSettings.combine(base: deviceEQ, overlay: overlay)
    checkEqual(effective.bands[3].gain, 3.0, "Device correction preserved at 250Hz")
    checkEqual(effective.bands[5].gain, 2.0, "Content overlay applied at 1kHz")
    check(!effective.isFlat, "Combined EQ is not flat")
}

do {
    // Night mode stacks on content mode
    var contentOverlay = EQSettings.flat
    contentOverlay.bands[3].gain = 2.0  // Voice mode: +2dB at 250Hz

    var nightOverlay = EQSettings.flat
    nightOverlay.bands[0].gain = -3.0   // Night: -3dB bass

    // Content + Night (as done by SoundModesStore.activeOverlay)
    let combinedL2 = EQSettings.combine(base: contentOverlay, overlay: nightOverlay)
    checkEqual(combinedL2.bands[3].gain, 2.0, "Voice correction preserved")
    checkEqual(combinedL2.bands[0].gain, -3.0, "Night bass cut applied")

    // Then L1 (device) + L2 (combined)
    var deviceEQ = EQSettings.flat
    deviceEQ.bands[0].gain = 5.0

    let final = EQSettings.combine(base: deviceEQ, overlay: combinedL2)
    checkEqual(final.bands[0].gain, 2.0, "Device 5 + night -3 = 2 at bass")
    checkEqual(final.bands[3].gain, 2.0, "Voice +2 preserved at 250Hz")
}

// ============================================================================
// MARK: - Test: Empty priority lists
// ============================================================================

section("Edge Cases — Empty Priority Lists")

do {
    let result = resolveOutputDevice(
        priorityList: [],
        connectedDevices: [speakers, headphones, builtinOutput]
    )
    check(result == nil, "Empty priority list → nil (use system default)")
}

do {
    let result = resolveOutputDevice(
        priorityList: ["speakers-uid", "beyerdynamic-uid"],
        connectedDevices: []
    )
    check(result == nil, "No devices connected → nil")
}

do {
    // System Default profile has empty priority lists → always nil
    let result = resolveOutputDevice(
        priorityList: systemDefault.priorityList(isOutput: true, mode: .public),
        connectedDevices: [speakers, headphones, builtinOutput]
    )
    check(result == nil, "System Default profile has no priorities → nil")
}

// ============================================================================
// MARK: - Test: Priority list with unknown device IDs
// ============================================================================

section("Edge Cases — Unknown Devices in Priority List")

do {
    // Priority list references a device that doesn't exist anymore
    let priority = ["deleted-device-uid", "speakers-uid", "beyerdynamic-uid"]
    let devices = [speakers, headphones, builtinOutput]
    let result = resolveOutputDevice(priorityList: priority, connectedDevices: devices)
    checkEqual(result?.uid, "speakers-uid", "Skips unknown device, picks next available")
}

do {
    // All devices in priority list are disconnected
    let priority = ["deleted-device-uid", "another-unknown-uid"]
    let devices = [builtinOutput]
    let result = resolveOutputDevice(priorityList: priority, connectedDevices: devices)
    check(result == nil, "All priority devices unknown → nil")
}

// ============================================================================
// MARK: - Test: Input/output device flag filtering
// ============================================================================

section("Edge Cases — Input/Output Flag Filtering")

do {
    // USB mic is input-only — should not be resolved as output
    let priority = ["usb-mic-uid", "speakers-uid"]
    let devices = [usbMic, speakers]
    let result = resolveOutputDevice(priorityList: priority, connectedDevices: devices)
    checkEqual(result?.uid, "speakers-uid", "Input-only device skipped for output resolution")
}

do {
    // Speakers is output-only — should not be resolved as input
    let priority = ["speakers-uid", "builtin-input-uid"]
    let devices = [speakers, builtinInput]
    let result = resolveInputDevice(priorityList: priority, connectedDevices: devices)
    checkEqual(result?.uid, "builtin-input-uid", "Output-only device skipped for input resolution")
}

do {
    // AirPods are both input and output — works for both
    let outputResult = resolveOutputDevice(
        priorityList: ["airpods-uid"],
        connectedDevices: [bluetooth]
    )
    let inputResult = resolveInputDevice(
        priorityList: ["airpods-uid"],
        connectedDevices: [bluetooth]
    )
    checkEqual(outputResult?.uid, "airpods-uid", "AirPods resolved as output")
    checkEqual(inputResult?.uid, "airpods-uid", "AirPods resolved as input")
}

// ============================================================================
// MARK: - Test: Trigger matching edge cases
// ============================================================================

section("Trigger Matching — Edge Cases")

do {
    // Profile with trigger device that is input-only
    let inputTriggerProfile = makeProfile(
        id: UUID(), name: "Mic Profile",
        triggerDeviceIDs: ["usb-mic-uid"],
        publicOutputPriority: ["builtin-output-uid"],
        publicInputPriority: ["usb-mic-uid"],
        privateOutputPriority: ["builtin-output-uid"],
        privateInputPriority: ["usb-mic-uid"],
        preferredMode: .public
    )
    let devices: Set<String> = ["usb-mic-uid", "builtin-output-uid", "builtin-input-uid"]
    let match = findBestTriggerMatch(profiles: [inputTriggerProfile], currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Mic Profile", "Input-only trigger device still matches")
}

do {
    // Two profiles with same match count → first one wins
    let profile1 = makeProfile(
        id: UUID(), name: "Profile A",
        triggerDeviceIDs: ["speakers-uid"],
        publicOutputPriority: [], publicInputPriority: [],
        privateOutputPriority: [], privateInputPriority: [],
        preferredMode: .public
    )
    let profile2 = makeProfile(
        id: UUID(), name: "Profile B",
        triggerDeviceIDs: ["speakers-uid"],
        publicOutputPriority: [], publicInputPriority: [],
        privateOutputPriority: [], privateInputPriority: [],
        preferredMode: .public
    )
    let devices: Set<String> = ["speakers-uid"]
    let match = findBestTriggerMatch(profiles: [profile1, profile2], currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Profile A", "Tied match count → first profile wins")
}

do {
    // Profile with empty triggers → never matches
    let noTrigger = makeProfile(
        id: UUID(), name: "No Triggers",
        triggerDeviceIDs: [],
        publicOutputPriority: ["speakers-uid"], publicInputPriority: [],
        privateOutputPriority: ["speakers-uid"], privateInputPriority: [],
        preferredMode: .public
    )
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid"]
    let match = findBestTriggerMatch(profiles: [noTrigger], currentDeviceIDs: devices)
    check(match == nil, "Empty triggerDeviceIDs → never matches")
}

do {
    // Empty profiles array → nil
    let match = findBestTriggerMatch(profiles: [], currentDeviceIDs: ["speakers-uid"])
    check(match == nil, "No profiles → no match")
}

do {
    // Empty device set → nil
    let match = findBestTriggerMatch(profiles: [homeProfile], currentDeviceIDs: [])
    check(match == nil, "No devices → no match")
}

// ============================================================================
// MARK: - Test: Profile.priorityList accessor
// ============================================================================

section("Profile.priorityList Accessor")

do {
    checkEqual(
        homeProfile.priorityList(isOutput: true, mode: .public),
        ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"],
        "Public output priority"
    )
    checkEqual(
        homeProfile.priorityList(isOutput: true, mode: .private),
        ["beyerdynamic-uid", "speakers-uid", "builtin-output-uid"],
        "Private output priority"
    )
    checkEqual(
        homeProfile.priorityList(isOutput: false, mode: .public),
        ["usb-mic-uid", "builtin-input-uid"],
        "Public input priority"
    )
    checkEqual(
        homeProfile.priorityList(isOutput: false, mode: .private),
        ["usb-mic-uid", "builtin-input-uid"],
        "Private input priority"
    )
}

do {
    check(systemDefault.isSystemDefault, "System Default .isSystemDefault is true")
    check(!homeProfile.isSystemDefault, "Home profile .isSystemDefault is false")
}

// ============================================================================
// MARK: - Test: Full re-evaluation simulation
// ============================================================================

section("Full Re-evaluation Simulation")

/// Simulates the full evaluateAndApply pipeline for a given set of inputs.
/// Returns the fingerprint that would be computed.
func simulateEvaluation(
    profile: Profile,
    mode: ProfileMode,
    connectedDevices: [AudioDevice],
    defaultOutput: AudioDevice?,
    defaultInput: AudioDevice?,
    deviceEQ: [String: EQSettings],    // per-device-UID EQ
    soundModeOverlay: EQSettings,      // L2 overlay
    driverInstalled: Bool,
    virtualDeviceUID: String? = nil,
    eqRunning: Bool = false,
    eqTargetUID: String? = nil
) -> PipelineFingerprint {
    // Step 1: resolve output (falls back to system default, mirroring performEvaluation)
    let outputList = profile.priorityList(isOutput: true, mode: mode)
    let resolvedOutputUID: String? = resolveOutputDevice(
        priorityList: outputList,
        connectedDevices: connectedDevices,
        virtualDeviceUID: virtualDeviceUID,
        eqRunning: eqRunning,
        eqTargetUID: eqTargetUID
    )?.uid ?? defaultOutput?.id

    // Step 2: resolve input (falls back to system default)
    let inputList = profile.priorityList(isOutput: false, mode: mode)
    let resolvedInputUID: String? = resolveInputDevice(
        priorityList: inputList,
        connectedDevices: connectedDevices
    )?.uid ?? defaultInput?.id

    // Step 3: compute effective EQ
    let baseEQ = deviceEQ[resolvedOutputUID ?? ""] ?? .flat
    let effectiveEQ = EQSettings.combine(base: baseEQ, overlay: soundModeOverlay)

    // Step 4: virtual driver need
    let needsVirtualDriver = !effectiveEQ.isFlat && driverInstalled

    return PipelineFingerprint(
        profileID: profile.id,
        mode: mode,
        outputDeviceUID: resolvedOutputUID,
        inputDeviceUID: resolvedInputUID,
        effectiveEQ: effectiveEQ,
        needsVirtualDriver: needsVirtualDriver
    )
}

do {
    // Full scenario: speakers off → on (the bug scenario, end-to-end)
    let fp1 = simulateEvaluation(
        profile: homeProfile, mode: .public,
        connectedDevices: [headphones, builtinOutput, builtinInput, usbMic],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: .flat,
        driverInstalled: true
    )
    checkEqual(fp1.outputDeviceUID, "beyerdynamic-uid", "Full sim step 1: headphones")
    check(!fp1.needsVirtualDriver, "No EQ → no virtual driver")

    let fp2 = simulateEvaluation(
        profile: homeProfile, mode: .public,
        connectedDevices: [speakers, headphones, builtinOutput, builtinInput, usbMic],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: .flat,
        driverInstalled: true
    )
    checkEqual(fp2.outputDeviceUID, "speakers-uid", "Full sim step 2: speakers")
    check(fp1 != fp2, "Fingerprint differs → pipeline re-applies")
}

do {
    // Full scenario: device EQ makes virtual driver needed
    var speakerEQ = EQSettings.flat
    speakerEQ.bands[3].gain = 5.0

    let fp = simulateEvaluation(
        profile: homeProfile, mode: .public,
        connectedDevices: [speakers, headphones, builtinOutput, builtinInput, usbMic],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: ["speakers-uid": speakerEQ], soundModeOverlay: .flat,
        driverInstalled: true
    )
    check(fp.needsVirtualDriver, "Speaker has EQ → virtual driver needed")
    checkEqual(fp.effectiveEQ.bands[3].gain, 5.0, "EQ applied")
}

do {
    // Full scenario: mode toggle changes output device
    let fpPublic = simulateEvaluation(
        profile: homeProfile, mode: .public,
        connectedDevices: [speakers, headphones, builtinOutput, builtinInput, usbMic],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: .flat,
        driverInstalled: true
    )
    let fpPrivate = simulateEvaluation(
        profile: homeProfile, mode: .private,
        connectedDevices: [speakers, headphones, builtinOutput, builtinInput, usbMic],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: .flat,
        driverInstalled: true
    )
    checkEqual(fpPublic.outputDeviceUID, "speakers-uid", "Public: speakers")
    checkEqual(fpPrivate.outputDeviceUID, "beyerdynamic-uid", "Private: headphones")
    check(fpPublic != fpPrivate, "Mode toggle → different fingerprint")
}

do {
    // Full scenario: sound mode overlay activates virtual driver
    var overlay = EQSettings.flat
    overlay.bands[5].gain = 4.0  // Voice mode: 1kHz +4dB

    let fpNoOverlay = simulateEvaluation(
        profile: homeProfile, mode: .public,
        connectedDevices: [speakers, builtinOutput, builtinInput],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: .flat,
        driverInstalled: true
    )
    let fpWithOverlay = simulateEvaluation(
        profile: homeProfile, mode: .public,
        connectedDevices: [speakers, builtinOutput, builtinInput],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: overlay,
        driverInstalled: true
    )
    check(!fpNoOverlay.needsVirtualDriver, "No overlay → no virtual driver")
    check(fpWithOverlay.needsVirtualDriver, "Overlay active → virtual driver needed")
    check(fpNoOverlay != fpWithOverlay, "Overlay change → fingerprint differs")
}

do {
    // Full scenario: fallback to system default when no priority devices connected
    let fp = simulateEvaluation(
        profile: systemDefault, mode: .public,
        connectedDevices: [builtinOutput, builtinInput],
        defaultOutput: builtinOutput, defaultInput: builtinInput,
        deviceEQ: [:], soundModeOverlay: .flat,
        driverInstalled: true
    )
    checkEqual(fp.outputDeviceUID, "builtin-output-uid", "System Default: uses system default output")
    checkEqual(fp.inputDeviceUID, "builtin-input-uid", "System Default: uses system default input")
}

// ============================================================================
// MARK: - Test: Reentrancy guard simulation
// ============================================================================

section("Reentrancy Guard Simulation")

do {
    // Simulate the reentrancy guard logic
    var isEvaluating = false
    var needsReevaluation = false
    var evaluationCount = 0

    func simulateEvaluateAndApply(triggerReevaluation: Bool = false) {
        guard !isEvaluating else {
            needsReevaluation = true
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        var iterations = 0
        repeat {
            needsReevaluation = false
            evaluationCount += 1
            // Simulate a mid-evaluation event
            if triggerReevaluation && iterations == 0 {
                needsReevaluation = true
            }
            iterations += 1
            if iterations > 3 { break }
        } while needsReevaluation
    }

    evaluationCount = 0
    simulateEvaluateAndApply(triggerReevaluation: false)
    checkEqual(evaluationCount, 1, "Normal evaluation: runs once")

    evaluationCount = 0
    simulateEvaluateAndApply(triggerReevaluation: true)
    checkEqual(evaluationCount, 2, "With mid-evaluation event: runs twice")
}

do {
    // Simulate recursive call during evaluation → sets flag instead of recursing
    var isEvaluating = false
    var needsReevaluation = false
    var callsDuringEvaluation = 0

    isEvaluating = true
    // Simulate a call that arrives during evaluation
    if isEvaluating {
        needsReevaluation = true
        callsDuringEvaluation += 1
    }
    isEvaluating = false

    check(needsReevaluation, "Recursive call sets flag")
    checkEqual(callsDuringEvaluation, 1, "One call was deferred")
}

// ============================================================================
// MARK: - Test: Multi-step device lifecycle (the user's bug scenario)
// ============================================================================

section("Full Device Lifecycle — User Bug Scenario")

do {
    // Simulates: Home profile active, public mode.
    // Speakers OFF → headphones fallback → speakers ON → speakers should be selected
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // ---- Phase 1: Initial state — speakers off, headphones available ----
    let phase1Devices = [headphones, builtinOutput, builtinInput, usbMic]
    let phase1DeviceIDs: Set<String> = Set(phase1Devices.map { $0.id })

    let match1 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: phase1DeviceIDs)
    checkEqual(match1?.profile.name, "Home Studio", "Phase 1: headphones trigger → Home profile")

    let output1 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: phase1Devices
    )
    checkEqual(output1?.uid, "beyerdynamic-uid", "Phase 1: speakers off → headphones selected")

    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: output1?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    // ---- Phase 2: Speakers turn ON — same profile, different device should be picked ----
    let phase2Devices = [speakers, headphones, builtinOutput, builtinInput, usbMic]
    let phase2DeviceIDs: Set<String> = Set(phase2Devices.map { $0.id })

    // Trigger service sees device list changed
    check(phase1DeviceIDs != phase2DeviceIDs, "Device list changed (speakers added)")

    // Same profile still matches
    let match2 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: phase2DeviceIDs)
    checkEqual(match2?.profile.name, "Home Studio", "Phase 2: still Home profile")
    check(match2?.profile.id == match1?.profile.id, "Same profile ID — trigger calls evaluateAndApply()")

    // evaluateAndApply re-walks priority list with new devices
    let output2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: phase2Devices
    )
    checkEqual(output2?.uid, "speakers-uid", "Phase 2: speakers ON → speakers selected (higher priority)")

    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: output2?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    check(fp1 != fp2, "Fingerprint changed → pipeline re-applies with speakers")

    // ---- Phase 3: Speakers turn OFF again — back to headphones ----
    let phase3Devices = [headphones, builtinOutput, builtinInput, usbMic]
    let output3 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: phase3Devices
    )
    checkEqual(output3?.uid, "beyerdynamic-uid", "Phase 3: speakers off → back to headphones")

    let fp3 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: output3?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fp2 != fp3, "Fingerprint changed again → pipeline re-applies")
    check(fp1 == fp3, "State returned to phase 1 fingerprint")
}

// ============================================================================
// MARK: - Test: Irrelevant device connect — no change
// ============================================================================

section("Irrelevant Device Connect — Pipeline Stability")

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]
    let baseDevices = [headphones, builtinOutput, builtinInput, usbMic]

    let output1 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: baseDevices
    )
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: output1?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    // Add AirPods — not in homeProfile's priority list
    let withAirpods = [headphones, builtinOutput, builtinInput, usbMic, bluetooth]
    let output2 = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: withAirpods
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: output2?.uid, inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )

    check(fp1 == fp2, "AirPods connect → irrelevant to Home profile → fingerprint unchanged → no pipeline action")

    // Note: trigger service sees device change (different device IDs), evaluates triggers.
    // But findBestTriggerMatch still returns Home profile (more matching triggers).
    let match1 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: Set(baseDevices.map { $0.id }))
    let match2 = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: Set(withAirpods.map { $0.id }))
    checkEqual(match1?.profile.name, "Home Studio", "Home profile still matched without AirPods")
    checkEqual(match2?.profile.name, "Home Studio", "Home profile still matched with AirPods (2 > 1)")
}

// ============================================================================
// MARK: - Test: Device removal cascades to next priority
// ============================================================================

section("Device Removal — Cascading Priority Fallback")

do {
    // Remove devices one by one and verify each fallback
    let all = [speakers, headphones, builtinOutput]
    let priority = homeProfile.priorityList(isOutput: true, mode: .public) // [speakers, headphones, builtin]

    // All available → speakers
    let r1 = resolveOutputDevice(priorityList: priority, connectedDevices: all)
    checkEqual(r1?.uid, "speakers-uid", "All connected → speakers (#1)")

    // Remove speakers → headphones
    let r2 = resolveOutputDevice(priorityList: priority, connectedDevices: [headphones, builtinOutput])
    checkEqual(r2?.uid, "beyerdynamic-uid", "Remove speakers → headphones (#2)")

    // Remove headphones too → builtin
    let r3 = resolveOutputDevice(priorityList: priority, connectedDevices: [builtinOutput])
    checkEqual(r3?.uid, "builtin-output-uid", "Remove headphones → builtin (#3)")

    // Remove everything → nil (system default fallback)
    let r4 = resolveOutputDevice(priorityList: priority, connectedDevices: [])
    check(r4 == nil, "All removed → nil (use system default)")

    // Add back headphones only → headphones (not speakers because speakers not connected)
    let r5 = resolveOutputDevice(priorityList: priority, connectedDevices: [headphones])
    checkEqual(r5?.uid, "beyerdynamic-uid", "Only headphones connected → headphones")

    // Add speakers back → speakers (higher priority)
    let r6 = resolveOutputDevice(priorityList: priority, connectedDevices: [speakers, headphones])
    checkEqual(r6?.uid, "speakers-uid", "Speakers reconnect → speakers (higher priority)")
}

// ============================================================================
// MARK: - Test: Profile trigger — no profile loses all triggers
// ============================================================================

section("Trigger Scenarios — Various Device Combinations")

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // All trigger devices connected: home wins (more triggers)
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid", "airpods-uid", "builtin-output-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Home Studio", "Home wins: 2 triggers vs Office's 1")
    checkEqual(match?.matchCount, 2, "2 matching triggers")
}

do {
    let allProfiles = [systemDefault, homeProfile, officeProfile]

    // Only AirPods + speakers: Home has 1 match (speakers), Office has 1 (AirPods) → first wins (Home)
    let devices: Set<String> = ["speakers-uid", "airpods-uid", "builtin-output-uid"]
    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    // Tie: both have 1 match. Home is earlier in array → Home wins
    checkEqual(match?.matchCount, 1, "Tied at 1 match each")
    // The first profile in the array with 1 match wins
    checkEqual(match?.profile.name, "Home Studio", "Tie-break: first profile in array wins")
}

do {
    // Edge: device that's BOTH a trigger AND in priority list
    let allProfiles = [systemDefault, homeProfile]
    let devices: Set<String> = ["beyerdynamic-uid", "builtin-output-uid"]

    let match = findBestTriggerMatch(profiles: allProfiles, currentDeviceIDs: devices)
    checkEqual(match?.profile.name, "Home Studio", "Single trigger device → profile matches")

    // And the same device should be resolvable as output
    let output = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: [headphones, builtinOutput]
    )
    checkEqual(output?.uid, "beyerdynamic-uid", "Trigger device also used as output device")
}

// ============================================================================
// MARK: - Test: EQ layer changes causing fingerprint diffs
// ============================================================================

section("EQ Changes — Fingerprint Sensitivity")

do {
    // Same profile + device, but EQ changes → different fingerprint
    let eq1 = EQSettings.flat
    var eq2 = EQSettings.flat
    eq2.bands[3].gain = 5.0

    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: eq1, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: eq2, needsVirtualDriver: true
    )
    check(fp1 != fp2, "EQ preset change → fingerprint differs → pipeline re-applies")
}

do {
    // needsVirtualDriver changes while everything else stays the same
    let fp1 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fp2 = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: "speakers-uid", inputDeviceUID: "usb-mic-uid",
        effectiveEQ: .flat, needsVirtualDriver: true
    )
    check(fp1 != fp2, "Virtual driver need change alone → different fingerprint")
}

// ============================================================================
// MARK: - Test: Profile with single device in priority — no ambiguity
// ============================================================================

section("Single-Device Priority — Clear Behavior")

do {
    let singleDeviceProfile = makeProfile(
        id: UUID(),
        name: "Simple",
        triggerDeviceIDs: ["speakers-uid"],
        publicOutputPriority: ["speakers-uid"],
        publicInputPriority: ["builtin-input-uid"],
        privateOutputPriority: ["speakers-uid"],
        privateInputPriority: ["builtin-input-uid"],
        preferredMode: .public
    )

    // Device connected → selected
    let r1 = resolveOutputDevice(
        priorityList: singleDeviceProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: [speakers, builtinOutput]
    )
    checkEqual(r1?.uid, "speakers-uid", "Single priority device connected → selected")

    // Device disconnected → nil (fallback to system default)
    let r2 = resolveOutputDevice(
        priorityList: singleDeviceProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: [builtinOutput]
    )
    check(r2 == nil, "Single priority device disconnected → nil")
}

// ============================================================================
// MARK: - Test: Three-layer EQ computation end-to-end
// ============================================================================

section("Three-Layer EQ Computation — End to End")

do {
    // Layer 1: Device correction (Harman target: bass boost, treble cut)
    var deviceEQ = EQSettings.flat
    deviceEQ.bands[0].gain = 6.0   // 32Hz +6dB
    deviceEQ.bands[1].gain = 4.0   // 64Hz +4dB
    deviceEQ.bands[8].gain = -2.0  // 8kHz -2dB
    deviceEQ.preamp = -3.0

    // Layer 2a: Content mode (Voice: speech presence boost)
    var voiceOverlay = EQSettings.flat
    voiceOverlay.bands[5].gain = 3.0   // 1kHz +3dB
    voiceOverlay.bands[6].gain = 2.0   // 2kHz +2dB
    voiceOverlay.bands[3].gain = -1.0  // 250Hz -1dB (reduce muddiness)

    // Layer 2b: Night mode (compress dynamics, reduce bass)
    var nightOverlay = EQSettings.flat
    nightOverlay.bands[0].gain = -4.0  // 32Hz -4dB
    nightOverlay.bands[1].gain = -2.0  // 64Hz -2dB

    // Step 1: Combine L2 = content + night
    let l2 = EQSettings.combine(base: voiceOverlay, overlay: nightOverlay)
    checkEqual(l2.bands[5].gain, 3.0, "L2: voice 1kHz preserved")
    checkEqual(l2.bands[0].gain, -4.0, "L2: night bass cut applied")
    checkEqual(l2.bands[1].gain, -2.0, "L2: night 64Hz cut applied")
    checkEqual(l2.bands[3].gain, -1.0, "L2: voice 250Hz cut preserved")

    // Step 2: Combine L1 + L2 = effective EQ
    let effective = EQSettings.combine(base: deviceEQ, overlay: l2)
    checkEqual(effective.bands[0].gain, 2.0, "Effective 32Hz: device +6 + night -4 = 2")
    checkEqual(effective.bands[1].gain, 2.0, "Effective 64Hz: device +4 + night -2 = 2")
    checkEqual(effective.bands[5].gain, 3.0, "Effective 1kHz: voice +3 (device was 0)")
    checkEqual(effective.bands[6].gain, 2.0, "Effective 2kHz: voice +2")
    checkEqual(effective.bands[8].gain, -2.0, "Effective 8kHz: device -2 (voice doesn't touch)")
    checkEqual(effective.bands[3].gain, -1.0, "Effective 250Hz: voice -1 (device was 0)")
    checkEqual(effective.preamp, -3.0, "Effective preamp: device -3 + overlay 0 = -3")
    check(!effective.isFlat, "Three-layer combined EQ is not flat")
}

// ============================================================================
// MARK: - Test: Mode toggle changes output AND input
// ============================================================================

section("Mode Toggle — Both Output and Input Change")

do {
    // Home profile: public uses speakers+USB mic, private uses headphones+USB mic
    let devices = [speakers, headphones, builtinOutput, builtinInput, usbMic]

    let pubOut = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .public),
        connectedDevices: devices
    )
    let privOut = resolveOutputDevice(
        priorityList: homeProfile.priorityList(isOutput: true, mode: .private),
        connectedDevices: devices
    )
    let pubIn = resolveInputDevice(
        priorityList: homeProfile.priorityList(isOutput: false, mode: .public),
        connectedDevices: devices
    )
    let privIn = resolveInputDevice(
        priorityList: homeProfile.priorityList(isOutput: false, mode: .private),
        connectedDevices: devices
    )

    // Output differs
    checkEqual(pubOut?.uid, "speakers-uid", "Public output: speakers")
    checkEqual(privOut?.uid, "beyerdynamic-uid", "Private output: headphones")
    check(pubOut?.uid != privOut?.uid, "Mode toggle changes output device")

    // Input same (both modes have same input priority)
    checkEqual(pubIn?.uid, "usb-mic-uid", "Public input: USB mic")
    checkEqual(privIn?.uid, "usb-mic-uid", "Private input: USB mic")
    check(pubIn?.uid == privIn?.uid, "Input stays the same across modes (same priority list)")

    // Fingerprints differ because output differs
    let fpPub = PipelineFingerprint(
        profileID: homeProfile.id, mode: .public,
        outputDeviceUID: pubOut?.uid, inputDeviceUID: pubIn?.uid,
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    let fpPriv = PipelineFingerprint(
        profileID: homeProfile.id, mode: .private,
        outputDeviceUID: privOut?.uid, inputDeviceUID: privIn?.uid,
        effectiveEQ: .flat, needsVirtualDriver: false
    )
    check(fpPub != fpPriv, "Mode toggle → different fingerprint → pipeline re-applies")
}

// ============================================================================
// MARK: - Test: Device list analysis (shouldProceed logic)
// ============================================================================

section("Device List Analysis — shouldProceed Logic")

do {
    // Same device list → should NOT proceed (skip evaluation)
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"]
    let lastEvaluated = devices  // Same
    let shouldProceed = devices != lastEvaluated
    check(!shouldProceed, "Same device list → skip evaluation")
}

do {
    // Device added → should proceed
    let before: Set<String> = ["beyerdynamic-uid", "builtin-output-uid"]
    let after: Set<String> = ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"]
    check(before != after, "Device added → should proceed")
}

do {
    // Device removed → should proceed
    let before: Set<String> = ["speakers-uid", "beyerdynamic-uid", "builtin-output-uid"]
    let after: Set<String> = ["beyerdynamic-uid", "builtin-output-uid"]
    check(before != after, "Device removed → should proceed")
}

do {
    // Device swapped (one removed, one added) → should proceed
    let before: Set<String> = ["speakers-uid", "builtin-output-uid"]
    let after: Set<String> = ["airpods-uid", "builtin-output-uid"]
    check(before != after, "Device swapped → should proceed")
}

do {
    // Manual trigger → always proceed even with same devices
    let devices: Set<String> = ["speakers-uid"]
    let lastEvaluated = devices
    let isManual = true
    let shouldProceed = isManual || devices != lastEvaluated
    check(shouldProceed, "Manual trigger → always proceed")
}

// ============================================================================
// MARK: - Test: Duplicate device IDs in priority list
// ============================================================================

section("Edge Cases — Duplicate Device IDs in Priority List")

do {
    // Duplicate entries in priority list → first occurrence wins (same device)
    let priority = ["speakers-uid", "speakers-uid", "beyerdynamic-uid"]
    let devices = [speakers, headphones, builtinOutput]
    let result = resolveOutputDevice(priorityList: priority, connectedDevices: devices)
    checkEqual(result?.uid, "speakers-uid", "Duplicate in priority → first match wins")
}

do {
    // All duplicates, none connected → nil
    let priority = ["unknown-uid", "unknown-uid"]
    let result = resolveOutputDevice(priorityList: priority, connectedDevices: [builtinOutput])
    check(result == nil, "All duplicates of unknown device → nil")
}

// ============================================================================
// MARK: - LOCAL MIRROR: EQEngineService.stopSafe branch selection
// ============================================================================
//
// FIXED CONTRADICTION: the old helper modelled a `connectedDeviceUIDs.contains(uid)`
// connectivity gate and returned `canResolve`. Production has NO such gate. Reading
// EQEngineService.stopSafe:
//   - `stopSafe(switchTo:)` sets state=.stopping and ALWAYS schedules an async,
//     generation-guarded teardown to that UID. Device resolution/connectivity is
//     checked later, at teardown execution time — not here.
//   - `stopSafe()` (no arg) hides the virtual device immediately IF `!isRunning`
//     OR there is no `targetDeviceUID`; otherwise it tears down to the target UID.
// This mirror captures only that branch selection (the shipped decision), not the
// fictional synchronous connectivity resolution the old test asserted.
enum StopSafeBranch: Equatable {
    /// EQDriverService.hide() only — nothing running / nothing to switch to.
    case hideOnly
    /// Schedule async teardown, switching the default output to this UID.
    case teardown(switchTo: String)
}

/// Mirrors `stopSafe(switchTo:)` — unconditional teardown to the requested UID.
func stopSafeSwitchTo(_ uid: String) -> StopSafeBranch {
    .teardown(switchTo: uid)
}

/// Mirrors `stopSafe()` (no argument).
func stopSafeNoArg(isRunning: Bool, targetDeviceUID: String?) -> StopSafeBranch {
    guard isRunning, let uid = targetDeviceUID else { return .hideOnly }
    return .teardown(switchTo: uid)
}

// ============================================================================
// MARK: - Helper: Orphan Recovery (mirrors AudioPipelineService orphan detection)
// ============================================================================

func shouldRecoverOrphan(
    eqRunning: Bool,
    virtualDeviceExists: Bool,
    currentDefaultIsVirtual: Bool
) -> Bool {
    return !eqRunning && virtualDeviceExists && currentDefaultIsVirtual
}

// ============================================================================
// MARK: - Helper: Shared Memory Resync Decision (delegates to real AudioCore)
// ============================================================================
//
// FIXED DRIFT: this helper used to reimplement the ring-buffer math and reported
// `framesDropped = readIndex - writeIndex` for the reset case — attributing drops
// to the wrong branch. It now delegates to the SHIPPED `AudioCore.computeReadPlan`,
// so the tests describe real reader behaviour:
//   - `writeIndex < readIndex` → driver RESET: reader snaps to writer, reads nothing,
//     drops 0 (old ring data is simply abandoned; `didReset == true`).
//   - `available > frameCapacity` → reader lapped: drops `available - capacity`.
// "needsResync" here means "the cursor was force-moved": didReset OR frames dropped.
func resyncDecision(
    writeIndex: UInt64,
    readIndex: UInt64,
    frameCapacity: Int,
    requestedFrames: Int = 4096
) -> (needsResync: Bool, framesDropped: Int, plan: AudioCore.ReadPlan) {
    let plan = AudioCore.computeReadPlan(
        writeIndex: writeIndex,
        readIndex: readIndex,
        frameCapacity: frameCapacity,
        requestedFrames: requestedFrames
    )
    let needsResync = plan.didReset || plan.framesDropped > 0
    return (needsResync: needsResync, framesDropped: plan.framesDropped, plan: plan)
}

// ============================================================================
// MARK: - Helper: Auto-Switch Notification Decision
// ============================================================================

func shouldNotifyAutoSwitch(
    matchProfileID: UUID?,
    currentActiveID: UUID?,
    isManual: Bool
) -> Bool {
    guard !isManual else { return false }
    guard let matchID = matchProfileID else { return false }
    return matchID != currentActiveID
}

// ============================================================================
// MARK: - Test: Trigger Tie-Breaking (Bug 16)
// ============================================================================

section("Trigger Tie-Breaking (Bug 16)")

// Positive: Higher match count wins regardless of position
do {
    let p1 = makeProfile(id: UUID(), name: "One Match", triggerDeviceIDs: ["speakers-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let p2 = makeProfile(id: UUID(), name: "Two Matches", triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let result = findBestTriggerMatch(profiles: [p1, p2], currentDeviceIDs: Set(["speakers-uid", "beyerdynamic-uid"]))
    checkEqual(result?.profile.name, "Two Matches", "Higher match count wins even if second in array")
    checkEqual(result?.matchCount, 2, "Match count is 2")
}

// Regression (Bug 16): Tied match count → first in array wins (arbitrary)
do {
    let p1 = makeProfile(id: UUID(), name: "First", triggerDeviceIDs: ["speakers-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let p2 = makeProfile(id: UUID(), name: "Second", triggerDeviceIDs: ["beyerdynamic-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let result = findBestTriggerMatch(profiles: [p1, p2], currentDeviceIDs: Set(["speakers-uid", "beyerdynamic-uid"]))
    checkEqual(result?.profile.name, "First", "Tied at 1 match → first in array wins (arbitrary)")
}

// Regression (Bug 16): Three-way tie → first wins
do {
    let p1 = makeProfile(id: UUID(), name: "A", triggerDeviceIDs: ["speakers-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let p2 = makeProfile(id: UUID(), name: "B", triggerDeviceIDs: ["beyerdynamic-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let p3 = makeProfile(id: UUID(), name: "C", triggerDeviceIDs: ["airpods-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let result = findBestTriggerMatch(profiles: [p1, p2, p3], currentDeviceIDs: Set(["speakers-uid", "beyerdynamic-uid", "airpods-uid"]))
    checkEqual(result?.profile.name, "A", "Three-way tie → first profile wins")
}

// Positive: Profile with fewer matches loses to profile with more matches
do {
    let p1 = makeProfile(id: UUID(), name: "One", triggerDeviceIDs: ["speakers-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let p2 = makeProfile(id: UUID(), name: "Three", triggerDeviceIDs: ["speakers-uid", "beyerdynamic-uid", "airpods-uid"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let result = findBestTriggerMatch(profiles: [p1, p2], currentDeviceIDs: Set(["speakers-uid", "beyerdynamic-uid", "airpods-uid"]))
    checkEqual(result?.profile.name, "Three", "3 matches beats 1 match")
}

// Negative: No triggers on any profile → nil
do {
    let p1 = makeProfile(id: UUID(), name: "NoTriggers", triggerDeviceIDs: [],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let result = findBestTriggerMatch(profiles: [p1], currentDeviceIDs: Set(["speakers-uid"]))
    check(result == nil, "Profile with no triggers → nil match")
}

// Negative: No devices match any triggers → nil
do {
    let p1 = makeProfile(id: UUID(), name: "Unmatched", triggerDeviceIDs: ["unknown-uid-1", "unknown-uid-2"],
                     publicOutputPriority: [], publicInputPriority: [],
                     privateOutputPriority: [], privateInputPriority: [],
                     preferredMode: .public)
    let result = findBestTriggerMatch(profiles: [p1], currentDeviceIDs: Set(["speakers-uid"]))
    check(result == nil, "No matching devices → nil")
}

// Negative: Empty profiles list → nil
do {
    let result = findBestTriggerMatch(profiles: [], currentDeviceIDs: Set(["speakers-uid"]))
    check(result == nil, "Empty profiles → nil")
}

// ============================================================================
// MARK: - Test: stopSafe branch selection
// ============================================================================
//
// REWRITTEN (was "stopSafe with Non-Existent Device UID (Bug 6)"). The old tests
// asserted a synchronous `connectedDeviceUIDs.contains(uid)` "canResolve" gate that
// production does NOT have — `stopSafe` schedules an async, generation-guarded
// teardown and resolves the device at execution time. Those assertions modelled
// fictional logic, so they are replaced with the SHIPPED branch selection.
section("stopSafe branch selection")

// stopSafe(switchTo:) always schedules a teardown to the requested UID —
// no connectivity check here (that happens later, inside the async teardown).
do {
    let result = stopSafeSwitchTo("speakers-uid")
    checkEqual(result, .teardown(switchTo: "speakers-uid"), "stopSafe(switchTo:) → teardown to that UID unconditionally")
}

// Even a currently-disconnected UID still schedules a teardown (production defers
// resolution to teardown time; it does NOT refuse up front). This is the corrected
// behaviour for the old "Bug 6" case.
do {
    let result = stopSafeSwitchTo("disconnected-uid")
    checkEqual(result, .teardown(switchTo: "disconnected-uid"), "stopSafe(switchTo:) schedules teardown even for a not-yet-connected UID (resolved at teardown time)")
}

// stopSafe() (no arg), running + target present → teardown to target UID.
do {
    let result = stopSafeNoArg(isRunning: true, targetDeviceUID: "speakers-uid")
    checkEqual(result, .teardown(switchTo: "speakers-uid"), "stopSafe() running + target → teardown to targetDeviceUID")
}

// stopSafe() (no arg), not running / no target → hide only.
do {
    let result = stopSafeNoArg(isRunning: false, targetDeviceUID: nil)
    checkEqual(result, .hideOnly, "stopSafe() not running + no target → hide only")
}

// stopSafe() (no arg), running but no target → hide only (guard requires both).
do {
    let result = stopSafeNoArg(isRunning: true, targetDeviceUID: nil)
    checkEqual(result, .hideOnly, "stopSafe() running but no targetDeviceUID → hide only")
}

// ============================================================================
// MARK: - Test: Orphan Recovery at Startup (Bug 5)
// ============================================================================

section("Orphan Recovery at Startup (Bug 5)")

// Positive: Orphan detected — EQ not running, virtual is system default
do {
    let result = shouldRecoverOrphan(eqRunning: false, virtualDeviceExists: true, currentDefaultIsVirtual: true)
    check(result, "EQ not running + virtual is default → should recover orphan")
}

// Positive: EQ running + virtual is default → not an orphan
do {
    let result = shouldRecoverOrphan(eqRunning: true, virtualDeviceExists: true, currentDefaultIsVirtual: true)
    check(!result, "EQ running + virtual is default → normal state, no recovery")
}

// Positive: EQ not running + virtual is NOT default → not orphaned
do {
    let result = shouldRecoverOrphan(eqRunning: false, virtualDeviceExists: true, currentDefaultIsVirtual: false)
    check(!result, "EQ not running + virtual not default → no orphan")
}

// Positive: No virtual device exists → no recovery possible
do {
    let result = shouldRecoverOrphan(eqRunning: false, virtualDeviceExists: false, currentDefaultIsVirtual: false)
    check(!result, "No virtual device → nothing to recover")
}

// Regression (Bug 5): Fresh launch with orphaned device → should recover
do {
    // Simulates: app crashed with virtual device as default, now relaunching
    let result = shouldRecoverOrphan(eqRunning: false, virtualDeviceExists: true, currentDefaultIsVirtual: true)
    check(result, "Fresh launch + orphaned virtual device → recover (Bug 5 regression)")
}

// Negative: Virtual exists but not default, EQ running → no recovery
do {
    let result = shouldRecoverOrphan(eqRunning: true, virtualDeviceExists: true, currentDefaultIsVirtual: false)
    check(!result, "EQ running + virtual not default → no recovery needed")
}

// ============================================================================
// MARK: - Helper: PipelineAction (mirrors AudioPipelineService decision logic)
// ============================================================================

// LOCAL MIRROR of AudioPipelineService.apply's action selection (pending extraction).
// Faithful to the production if/else-if chain, in order:
//   1. needsVirtualDriver && outputUID != nil && virtualName != nil:
//        eqRunning && target == outputUID → hotUpdate (updateSettings)
//        eqRunning                        → switchDevice
//        !eqRunning                       → startPipeline
//   2. else if eqRunning && outputUID != nil → stopEQ(switchTo:)   (stopSafe(switchTo:))
//   3. else if eqRunning                     → stopEQNoTarget       (stopSafe())
//   4. else if !needsVirtualDriver && outputDevice != nil → directSetDevice
//   5. otherwise → noOp
// Note: production branch 1 also falls through when `needsVirtualDriver` is true but
// outputUID/virtualName is nil; here `virtualDeviceName` defaults from outputUID and
// the vName-nil case only arises when outputUID is nil, handled by the ordering below.
enum PipelineAction: Equatable {
    case hotUpdate(EQSettings)
    case switchDevice(realUID: String, settings: EQSettings, virtualName: String)
    case startPipeline(realUID: String, settings: EQSettings, virtualName: String)
    case stopEQ(switchTo: String)
    case stopEQNoTarget                 // stopSafe() — EQ running, no output resolved
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
    // Branch 1: virtual driver needed and we have a concrete output UID.
    if needsVirtualDriver, let outputUID = outputDeviceUID {
        let vName = virtualDeviceName ?? "\(outputUID) EQ"
        if eqRunning {
            return eqTargetUID == outputUID
                ? .hotUpdate(effectiveEQ)
                : .switchDevice(realUID: outputUID, settings: effectiveEQ, virtualName: vName)
        } else {
            return .startPipeline(realUID: outputUID, settings: effectiveEQ, virtualName: vName)
        }
    }
    // Branch 2: EQ running, no longer needed, output UID present → stop + switch.
    if eqRunning, let outputUID = outputDeviceUID {
        return .stopEQ(switchTo: outputUID)
    }
    // Branch 3: EQ running, no output resolved → stopSafe() (hide/teardown to target).
    if eqRunning {
        return .stopEQNoTarget
    }
    // Branch 4: no EQ needed, concrete output → set it directly.
    if !needsVirtualDriver, let outputUID = outputDeviceUID {
        return .directSetDevice(outputUID)
    }
    // Branch 5: nothing to do.
    return .noOp
}

// ============================================================================
// MARK: - Test: Pipeline Action with Disconnected Device (Bug 6 extended)
// ============================================================================

section("Pipeline Action with Disconnected Device (Bug 6 extended)")

// Positive: nil outputDeviceUID → noOp
do {
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: false, outputDeviceUID: nil,
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .noOp, "nil outputDeviceUID → noOp")
}

// EQ running, no longer needed, output UID present → stopEQ(switchTo:).
// The switchTo UID may currently be disconnected; production still schedules the
// stop and resolves the device at teardown time (there is no up-front gate).
do {
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: false, outputDeviceUID: "disconnected-uid",
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .stopEQ(switchTo: "disconnected-uid"), "EQ running + flat + output resolved → stopEQ(switchTo:), resolution deferred to teardown")
}

// EQ running, needs stop, but NO output device resolved → stopSafe() no-arg branch.
do {
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: false, outputDeviceUID: nil,
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .stopEQNoTarget, "EQ running + no output resolved → stopSafe() (branch 3), NOT noOp")
}

// Positive: EQ not running, no driver needed, valid UID → directSetDevice
do {
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: false, outputDeviceUID: "speakers-uid",
        effectiveEQ: .flat, virtualDeviceName: nil
    )
    checkEqual(action, .directSetDevice("speakers-uid"), "No EQ needed + valid UID → directSetDevice")
}

// Positive: EQ running, needs to keep running, same device → hotUpdate
do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: true, outputDeviceUID: "speakers-uid",
        effectiveEQ: eq, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .hotUpdate(eq), "Same device + non-flat → hotUpdate")
}

// Positive: EQ running, different device → switchDevice
do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let action = decidePipelineAction(
        eqRunning: true, eqTargetUID: "speakers-uid",
        needsVirtualDriver: true, outputDeviceUID: "beyerdynamic-uid",
        effectiveEQ: eq, virtualDeviceName: "Headphones EQ"
    )
    checkEqual(action, .switchDevice(realUID: "beyerdynamic-uid", settings: eq, virtualName: "Headphones EQ"), "EQ running + different device → switchDevice")
}

// Positive: EQ not running, driver needed → startPipeline
do {
    var eq = EQSettings.flat
    eq.bands[3].gain = 5.0
    let action = decidePipelineAction(
        eqRunning: false, eqTargetUID: nil,
        needsVirtualDriver: true, outputDeviceUID: "speakers-uid",
        effectiveEQ: eq, virtualDeviceName: "Speakers EQ"
    )
    checkEqual(action, .startPipeline(realUID: "speakers-uid", settings: eq, virtualName: "Speakers EQ"), "EQ not running + driver needed → startPipeline")
}

// ============================================================================
// MARK: - Test: Shared Memory Resync (Bug 10)
// ============================================================================

section("Shared Memory Resync (Bug 10)")

// Positive: Reader close behind writer → no resync
do {
    let result = resyncDecision(writeIndex: 100, readIndex: 80, frameCapacity: 4096)
    check(!result.needsResync, "Reader behind writer → no resync needed")
    checkEqual(result.framesDropped, 0, "No frames dropped")
}

// Positive: Reader exactly at writer → no resync, 0 available
do {
    let result = resyncDecision(writeIndex: 100, readIndex: 100, frameCapacity: 4096)
    check(!result.needsResync, "Reader at writer → no resync")
    checkEqual(result.framesDropped, 0, "No frames dropped when caught up")
}

// Writer reset (writeIndex < readIndex) → cursor snapped to writer.
// FIXED DRIFT: the old reimplementation reported framesDropped = readIndex - writeIndex.
// Real AudioCore.computeReadPlan for the RESET branch drops 0 (the old ring contents
// are abandoned, not "dropped"); it sets didReset=true, available=0.
// Old expectation: framesDropped > 0. New expectation: didReset true, framesDropped == 0.
do {
    let result = resyncDecision(writeIndex: 10, readIndex: 5000, frameCapacity: 4096)
    check(result.plan.didReset, "Writer reset (write<read) → didReset, cursor snaps to writer")
    check(result.needsResync, "Reset counts as a resync (cursor force-moved)")
    checkEqual(result.framesDropped, 0, "Reset drops 0 frames (old ring abandoned, not dropped)")
    checkEqual(result.plan.framesToRead, 0, "Nothing read on the reset call")
    checkEqual(result.plan.newReadIndex, 10, "Read cursor snapped to writer (10)")
}

// FIXED CONTRADICTION (was labelled "Bug 10 — dropped exactly capacity frames").
// resyncDecision(writeIndex:0, readIndex:4096, cap:4096) is the RESET case (0 < 4096),
// NOT the drop case. Real behaviour: didReset=true, framesDropped == 0.
// Old expectation: framesDropped == 4096. New expectation: 0.
do {
    let result = resyncDecision(writeIndex: 0, readIndex: 4096, frameCapacity: 4096)
    check(result.plan.didReset, "write(0) < read(4096) → RESET branch (not a drop)")
    checkEqual(result.framesDropped, 0, "Reset drops 0 frames — old expectation of 4096 was drift")
    checkEqual(result.plan.newReadIndex, 0, "Cursor snapped to writer (0)")
}

// The ACTUAL drop branch: reader lapped by more than a full ring
// (available > frameCapacity). Only here does computeReadPlan drop frames.
do {
    // write ahead of read by 6000 > capacity 4096 → drops 6000 - 4096 = 1904.
    let result = resyncDecision(writeIndex: 6000, readIndex: 0, frameCapacity: 4096)
    check(!result.plan.didReset, "write >= read → not a reset")
    check(result.needsResync, "Lapped reader → resync (frames dropped)")
    checkEqual(result.framesDropped, 1904, "Dropped available - capacity = 6000 - 4096 = 1904")
    checkEqual(result.plan.available, 4096, "Available clamped to capacity after skip-forward")
    checkEqual(result.plan.newReadIndex, 6000, "Cursor advanced by the (clamped) read of 4096 from 1904")
}

// Positive: Writer ahead of reader within capacity → no resync, no drops
do {
    let result = resyncDecision(writeIndex: 100000, readIndex: 99990, frameCapacity: 4096)
    check(!result.needsResync, "Writer ahead of reader (normal progress) → no resync")
    checkEqual(result.framesDropped, 0, "10 frames available, well within capacity → nothing dropped")
    checkEqual(result.plan.framesToRead, 10, "Reads the 10 available frames")
}

// Negative: Both at zero → no resync
do {
    let result = resyncDecision(writeIndex: 0, readIndex: 0, frameCapacity: 4096)
    check(!result.needsResync, "Both at zero → no resync")
}

// ============================================================================
// MARK: - Test: Auto-Switching Disabled (shouldProceed logic)
// ============================================================================

section("Auto-Switching Disabled — shouldProceed Logic")

// Positive: Auto-switching disabled + automatic trigger → blocked
do {
    let isAutoDisabled = true
    let isManual = false
    let shouldProceed = !isAutoDisabled || isManual
    check(!shouldProceed, "Auto disabled + automatic → blocked")
}

// Positive: Auto-switching disabled + manual trigger → proceeds
do {
    let isAutoDisabled = true
    let isManual = true
    let shouldProceed = !isAutoDisabled || isManual
    check(shouldProceed, "Auto disabled + manual → proceeds")
}

// Positive: Auto-switching enabled + device list unchanged → skip
do {
    let devices: Set<String> = ["speakers-uid"]
    let lastEvaluated: Set<String> = ["speakers-uid"]
    let isManual = false
    let shouldProceed = isManual || devices != lastEvaluated
    check(!shouldProceed, "Enabled + unchanged devices → skip")
}

// Positive: Auto-switching enabled + device list changed → proceed
do {
    let devices: Set<String> = ["speakers-uid", "beyerdynamic-uid"]
    let lastEvaluated: Set<String> = ["speakers-uid"]
    let isManual = false
    let shouldProceed = isManual || devices != lastEvaluated
    check(shouldProceed, "Enabled + changed devices → proceed")
}

// ============================================================================
// MARK: - Test: ProfileMode Naming (Bug 13)
// ============================================================================

section("ProfileMode Naming (Bug 13)")

// Positive: Mode rawValues documented
do {
    checkEqual(ProfileMode.public.rawValue, "public", "ProfileMode.public rawValue")
    checkEqual(ProfileMode.private.rawValue, "private", "ProfileMode.private rawValue")
}

// Positive: displayName returns user-facing labels
do {
    checkEqual(ProfileMode.public.displayName, "Speakers", "ProfileMode.public.displayName")
    checkEqual(ProfileMode.private.displayName, "Headphones", "ProfileMode.private.displayName")
}

// Positive: Public mode selects public priority list
do {
    let p = homeProfile
    let output = p.priorityList(isOutput: true, mode: .public)
    checkEqual(output, p.publicOutputPriority, "Public mode → publicOutputPriority")
    let input = p.priorityList(isOutput: false, mode: .public)
    checkEqual(input, p.publicInputPriority, "Public mode → publicInputPriority")
}

// Positive: Private mode selects private priority list
do {
    let p = homeProfile
    let output = p.priorityList(isOutput: true, mode: .private)
    checkEqual(output, p.privateOutputPriority, "Private mode → privateOutputPriority")
    let input = p.priorityList(isOutput: false, mode: .private)
    checkEqual(input, p.privateInputPriority, "Private mode → privateInputPriority")
}

// ============================================================================
// MARK: - Test: Auto-Switch Notification Decision (Bug 14)
// ============================================================================

section("Auto-Switch Notification Decision (Bug 14)")

// Positive: New profile triggered automatically → should notify
do {
    let id1 = UUID()
    let id2 = UUID()
    let result = shouldNotifyAutoSwitch(matchProfileID: id2, currentActiveID: id1, isManual: false)
    check(result, "New profile auto-triggered → notify")
}

// Positive: Same profile re-evaluated automatically → don't notify
do {
    let id1 = UUID()
    let result = shouldNotifyAutoSwitch(matchProfileID: id1, currentActiveID: id1, isManual: false)
    check(!result, "Same profile re-evaluated → no notification (no spam)")
}

// Positive: New profile triggered manually → don't notify
do {
    let id1 = UUID()
    let id2 = UUID()
    let result = shouldNotifyAutoSwitch(matchProfileID: id2, currentActiveID: id1, isManual: true)
    check(!result, "Manual trigger → no notification")
}

// Positive: Fallback (nil match) → don't notify from this function
do {
    let id1 = UUID()
    let result = shouldNotifyAutoSwitch(matchProfileID: nil, currentActiveID: id1, isManual: false)
    check(!result, "nil match → no notification from this function")
}

// Negative: Both nil → don't notify
do {
    let result = shouldNotifyAutoSwitch(matchProfileID: nil, currentActiveID: nil, isManual: false)
    check(!result, "Both nil → no notification")
}

// ============================================================================
// MARK: - Class-Based Trigger Rules (Item 14)
// ============================================================================

section("Class-Based Trigger Rules (Item 14)")

// Positive: .transportType("Bluetooth") matches any Bluetooth device
do {
    let btProfile = makeProfile(
        id: UUID(),
        name: "BT Profile",
        triggerDeviceIDs: [],
        triggerRules: [.transportType(type: "Bluetooth")],
        publicOutputPriority: ["airpods-uid"],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let devices = [bluetooth, builtinOutput]
    let result = findBestTriggerMatch(
        profiles: [btProfile],
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result != nil, "transportType(Bluetooth) matches when Bluetooth device connected")
    checkEqual(result?.profile.name, "BT Profile", "Matched profile is BT Profile")
}

// Positive: .specificDevice(id:) matches only that device
do {
    let specificProfile = makeProfile(
        id: UUID(),
        name: "Specific Profile",
        triggerDeviceIDs: [],
        triggerRules: [.specificDevice(id: "airpods-uid")],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let devices = [bluetooth, builtinOutput]
    let result = findBestTriggerMatch(
        profiles: [specificProfile],
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result != nil, "specificDevice matches when exact device connected")
    checkEqual(result?.profile.name, "Specific Profile", "Matched profile is Specific Profile")
}

// Positive: Mixed rules work together — both specific + class match
do {
    let mixedProfile = makeProfile(
        id: UUID(),
        name: "Mixed Profile",
        triggerDeviceIDs: [],
        triggerRules: [
            .specificDevice(id: "speakers-uid"),
            .transportType(type: "Bluetooth")
        ],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let devices = [speakers, bluetooth, builtinOutput]
    let result = findBestTriggerMatch(
        profiles: [mixedProfile],
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result != nil, "Mixed rules: both specific + class match")
    checkEqual(result?.matchCount, 2, "Mixed rules: match count is 2")
}

// Negative: .transportType("USB") does NOT match a Bluetooth device
do {
    let usbProfile = makeProfile(
        id: UUID(),
        name: "USB Profile",
        triggerDeviceIDs: [],
        triggerRules: [.transportType(type: "USB")],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let devices = [bluetooth, builtinOutput]  // no USB devices
    let result = findBestTriggerMatch(
        profiles: [usbProfile],
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result == nil, "transportType(USB) does NOT match when only Bluetooth connected")
}

// Positive: Specific match beats class match in tie-breaking
do {
    let specificProfile = makeProfile(
        id: UUID(),
        name: "Specific Wins",
        triggerDeviceIDs: [],
        triggerRules: [.specificDevice(id: "airpods-uid")],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let classProfile = makeProfile(
        id: UUID(),
        name: "Class Match",
        triggerDeviceIDs: [],
        triggerRules: [.transportType(type: "Bluetooth")],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let devices = [bluetooth]
    // Both match with count 1, but specific should win
    let result = findBestTriggerMatch(
        profiles: [classProfile, specificProfile],  // class first in list
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result != nil, "Tie-break: a match found")
    checkEqual(result?.profile.name, "Specific Wins", "Tie-break: specific match beats class match")
}

// Migration: Profile constructed from legacy triggerDeviceIDs has correct triggerRules
do {
    let legacyProfile = makeProfile(
        id: UUID(),
        name: "Legacy",
        triggerDeviceIDs: ["airpods-uid", "speakers-uid"],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    checkEqual(legacyProfile.triggerRules.count, 2, "Migration: 2 triggerDeviceIDs → 2 triggerRules")
    check(legacyProfile.triggerRules[0] == .specificDevice(id: "airpods-uid"), "Migration: first rule is specificDevice(airpods-uid)")
    check(legacyProfile.triggerRules[1] == .specificDevice(id: "speakers-uid"), "Migration: second rule is specificDevice(speakers-uid)")
}

// TriggerRule.displayName
do {
    let specific = TriggerRule.specificDevice(id: "my-device-uid")
    checkEqual(specific.displayName, "my-device-uid", "specificDevice displayName returns the id")
    let transport = TriggerRule.transportType(type: "Bluetooth")
    checkEqual(transport.displayName, "Any Bluetooth", "transportType displayName returns 'Any Bluetooth'")
}

// Class rule counts as 1 match even if multiple devices of that class are connected
do {
    let btDevice2 = AudioDevice(id: "bt-speaker-uid", name: "BT Speaker", transportType: "Bluetooth", isInput: false, isOutput: true)
    let btProfile = makeProfile(
        id: UUID(),
        name: "BT Only",
        triggerDeviceIDs: [],
        triggerRules: [.transportType(type: "Bluetooth")],
        publicOutputPriority: [],
        publicInputPriority: [],
        privateOutputPriority: [],
        privateInputPriority: [],
        preferredMode: .public
    )
    let devices = [bluetooth, btDevice2, builtinOutput]
    let result = findBestTriggerMatch(
        profiles: [btProfile],
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result != nil, "Class rule matches with multiple BT devices connected")
    checkEqual(result?.matchCount, 1, "Class rule counts as 1 match, not per-device")
}

// Backward compat: existing profiles with only triggerDeviceIDs still work in findBestTriggerMatch
do {
    // homeProfile and officeProfile were created with triggerDeviceIDs, should have auto-derived triggerRules
    let devices = [bluetooth, builtinOutput]
    let result = findBestTriggerMatch(
        profiles: [homeProfile, officeProfile],
        currentDeviceIDs: Set(devices.map(\.id)),
        currentDevices: devices
    )
    check(result != nil, "Backward compat: legacy profiles match via auto-derived triggerRules")
    checkEqual(result?.profile.name, "Office", "Backward compat: Office profile matches airpods (Bluetooth)")
}

// ============================================================================
// MARK: - Test: EQ Bypass Toggle (F1)
// ============================================================================

// LOCAL MIRROR of ProfileManager.performEvaluation step 6/6b (pending extraction).
// Production computes `combine(base:overlay:)` then flattens when EITHER the global
// processing bypass OR the per-device bypass is set:
//     if isProcessingBypassed || EQStore.shared.isBypassed(for: outputUID) { effectiveEQ = .flat }
// This mirror ORs the same two flags. The single-`isBypassed` call sites below pass
// the combined flag through `globalBypassed` (default false), so they keep working.
func computeEffectiveEQWithBypass(
    baseEQ: EQSettings,
    overlay: EQSettings,
    isBypassed: Bool,
    globalBypassed: Bool = false
) -> EQSettings {
    if globalBypassed || isBypassed { return .flat }
    return EQSettings.combine(base: baseEQ, overlay: overlay)
}

do {
    section("EQ Bypass Toggle (F1)")

    let nonFlatBase: EQSettings = {
        var eq = EQSettings.flat
        eq.bands[2].gain = 3.0   // 125 Hz +3 dB
        eq.bands[5].gain = -2.0  // 1 kHz -2 dB
        return eq
    }()

    let nonFlatOverlay: EQSettings = {
        var eq = EQSettings.flat
        eq.bands[0].gain = 1.5   // 32 Hz +1.5 dB
        eq.bands[7].gain = -1.0  // 4 kHz -1 dB
        return eq
    }()

    // 1. bypass=true -> effectiveEQ is flat
    do {
        let result = computeEffectiveEQWithBypass(baseEQ: nonFlatBase, overlay: nonFlatOverlay, isBypassed: true)
        check(result.isFlat, "Bypass true: effectiveEQ is flat regardless of non-flat base+overlay")
    }

    // 2. bypass=false -> effectiveEQ preserved (non-flat)
    do {
        let result = computeEffectiveEQWithBypass(baseEQ: nonFlatBase, overlay: nonFlatOverlay, isBypassed: false)
        check(!result.isFlat, "Bypass false: effectiveEQ is non-flat (settings preserved)")
    }

    // 3. unknown device defaults to not bypassed (empty dict)
    do {
        let bypassDict: [String: Bool] = [:]
        let deviceUID = "unknown-device-uid"
        let isBypassed = bypassDict[deviceUID] ?? false
        check(!isBypassed, "Unknown device defaults to not bypassed (empty bypass dict)")
    }

    // 4. bypass on->off restores original settings
    do {
        let combined = EQSettings.combine(base: nonFlatBase, overlay: nonFlatOverlay)
        let bypassed = computeEffectiveEQWithBypass(baseEQ: nonFlatBase, overlay: nonFlatOverlay, isBypassed: true)
        let restored = computeEffectiveEQWithBypass(baseEQ: nonFlatBase, overlay: nonFlatOverlay, isBypassed: false)
        check(bypassed.isFlat, "Bypass on: EQ is flat")
        checkEqual(restored, combined, "Bypass off: EQ restored to original combined settings")
    }

    // 5. bypass overrides overlay too (non-flat overlay + bypass -> still flat)
    do {
        let result = computeEffectiveEQWithBypass(baseEQ: .flat, overlay: nonFlatOverlay, isBypassed: true)
        check(result.isFlat, "Bypass overrides non-flat overlay: result is flat")
    }

    // 6. bypass + flat base + flat overlay -> still flat (no change)
    do {
        let result = computeEffectiveEQWithBypass(baseEQ: .flat, overlay: .flat, isBypassed: true)
        check(result.isFlat, "Bypass with flat base + flat overlay: still flat")
    }

    // 7. Per-device bypass flattens EQ even when the GLOBAL flag is off.
    //    Matches production's OR-of-two-flags:
    //    isProcessingBypassed(false) || EQStore.isBypassed(for:)(true) → flatten.
    do {
        let result = computeEffectiveEQWithBypass(
            baseEQ: nonFlatBase, overlay: nonFlatOverlay,
            isBypassed: true, globalBypassed: false
        )
        check(result.isFlat, "Per-device bypass ON + global OFF → EQ flattened (real OR-of-two-flags rule)")
    }

    // 8. Global bypass flattens EQ even when the PER-DEVICE flag is off.
    do {
        let result = computeEffectiveEQWithBypass(
            baseEQ: nonFlatBase, overlay: nonFlatOverlay,
            isBypassed: false, globalBypassed: true
        )
        check(result.isFlat, "Global bypass ON + per-device OFF → EQ flattened (real OR-of-two-flags rule)")
    }

    // 9. Neither flag set → EQ preserved (the OR is false).
    do {
        let result = computeEffectiveEQWithBypass(
            baseEQ: nonFlatBase, overlay: nonFlatOverlay,
            isBypassed: false, globalBypassed: false
        )
        check(!result.isFlat, "Neither bypass flag set → EQ preserved")
    }
}

// ============================================================================
// MARK: - Bypass All Processing (F4)
// ============================================================================

do {
    section("Bypass All Processing (F4)")

    do {
        var eq = EQSettings.flat
        eq.bands[3].gain = 5.0
        let overlay = EQSettings.flat
        // Global bypass ON
        let effective = true ? EQSettings.flat : EQSettings.combine(base: eq, overlay: overlay)
        check(effective.isFlat, "Global bypass ON → flat EQ")
    }

    do {
        var eq = EQSettings.flat
        eq.bands[3].gain = 5.0
        let overlay = EQSettings.flat
        // Global bypass OFF
        let effective = false ? EQSettings.flat : EQSettings.combine(base: eq, overlay: overlay)
        check(!effective.isFlat, "Global bypass OFF → preserves EQ")
    }

    do {
        var eq = EQSettings.flat
        eq.bands[3].gain = 5.0
        var overlay = EQSettings.flat
        overlay.bands[5].gain = 2.0
        // Global bypass overrides BOTH base and overlay
        let effective = true ? EQSettings.flat : EQSettings.combine(base: eq, overlay: overlay)
        check(effective.isFlat, "Global bypass overrides base + overlay")
    }

    do {
        // Global bypass OFF + per-device bypass ON → still flat (per-device takes effect)
        let isGlobalBypassed = false
        let isDeviceBypassed = true
        var eq = EQSettings.flat
        eq.bands[3].gain = 5.0
        let effective = (isGlobalBypassed || isDeviceBypassed) ? EQSettings.flat : eq
        check(effective.isFlat, "Per-device bypass still works when global is off")
    }
}

// ============================================================================
// MARK: - Auto-Switch Diagnostics (F8)
// ============================================================================

struct TestTriggerEvent {
    let profileName: String
    let triggerDeviceName: String
    let timestamp: Date
    let wasAutomatic: Bool

    var timeAgo: String {
        let interval = Date().timeIntervalSince(timestamp)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

do {
    section("Auto-Switch Diagnostics (F8)")

    // timeAgo: <60s → "Just now"
    do {
        let event = TestTriggerEvent(profileName: "Test", triggerDeviceName: "AirPods", timestamp: Date().addingTimeInterval(-30), wasAutomatic: true)
        check(event.timeAgo == "Just now", "timeAgo <60s → 'Just now' (got '\(event.timeAgo)')")
    }

    // timeAgo: 300s → "5m ago"
    do {
        let event = TestTriggerEvent(profileName: "Test", triggerDeviceName: "AirPods", timestamp: Date().addingTimeInterval(-300), wasAutomatic: true)
        check(event.timeAgo == "5m ago", "timeAgo 300s → '5m ago' (got '\(event.timeAgo)')")
    }

    // timeAgo: 7200s → "2h ago"
    do {
        let event = TestTriggerEvent(profileName: "Test", triggerDeviceName: "AirPods", timestamp: Date().addingTimeInterval(-7200), wasAutomatic: true)
        check(event.timeAgo == "2h ago", "timeAgo 7200s → '2h ago' (got '\(event.timeAgo)')")
    }

    // timeAgo: 90000s → "1d ago"
    do {
        let event = TestTriggerEvent(profileName: "Test", triggerDeviceName: "AirPods", timestamp: Date().addingTimeInterval(-90000), wasAutomatic: true)
        check(event.timeAgo == "1d ago", "timeAgo 90000s → '1d ago' (got '\(event.timeAgo)')")
    }

    // automatic event records device name
    do {
        let event = TestTriggerEvent(profileName: "Studio", triggerDeviceName: "Scarlett 2i2", timestamp: Date(), wasAutomatic: true)
        check(event.wasAutomatic == true, "Automatic event: wasAutomatic is true")
        check(event.triggerDeviceName == "Scarlett 2i2", "Automatic event records device name '\(event.triggerDeviceName)'")
    }

    // manual event records "Manual"
    do {
        let event = TestTriggerEvent(profileName: "Home", triggerDeviceName: "Manual", timestamp: Date(), wasAutomatic: false)
        check(event.wasAutomatic == false, "Manual event: wasAutomatic is false")
        check(event.triggerDeviceName == "Manual", "Manual event records 'Manual' as trigger device")
    }
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
