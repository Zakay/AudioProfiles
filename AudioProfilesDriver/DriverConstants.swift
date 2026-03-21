// DriverConstants.swift — AudioProfilesDriver
//
// All compile-time constants for the AudioServerPlugin.
// The companion app (AudioProfiles) mirrors the custom-property selectors
// in EQDriverService.swift — they MUST stay in sync.

import CoreAudio

// MARK: - Bundle / Device identities

/// Bundle ID of the driver itself
let kDriverBundleID = "com.audioprofiles.driver"

/// Bundle ID of the companion app — used to authorise custom property writes
let kCompanionBundleID = "com.audioprofiles.AudioProfiles"

/// Persistent UID for the single virtual device.
/// The companion app looks up the device by this UID.
/// nonisolated(unsafe) because CFString is not Sendable but this value is effectively constant.
nonisolated(unsafe) let kDeviceUID: CFString = "AudioProfilesEQDevice-UID" as CFString

/// Model / name shown when the driver is installed but the companion app
/// hasn't yet told it a display name.
nonisolated(unsafe) let kDeviceDefaultName: CFString = "AudioProfiles EQ" as CFString

// MARK: - AudioObject IDs
// Stable LOCAL numeric IDs assigned to our objects within the plugin's namespace.
// Follows Apple's NullAudio / BlackHole convention: plugin = 1, device = 2, streams = 3/4.
// coreaudiod calls into our vtable with these LOCAL IDs; the HAL maps them to global IDs.
// NOTE: local ID 1 (kObjectID_Plugin) coincides with kAudioObjectSystemObject = 1,
// but in the local driver ID space, 1 always means OUR plugin, not the HAL system object.

let kObjectID_Plugin: AudioObjectID        = 1   // root plugin object
let kObjectID_Device: AudioObjectID        = 2   // the single virtual device
let kObjectID_Stream_Output: AudioObjectID = 3   // system → driver (WriteMix)
let kObjectID_Stream_Input:  AudioObjectID = 4   // driver → app   (ReadInput)
let kObjectID_Volume_Output: AudioObjectID = 5   // output volume control
let kObjectID_Mute_Output:   AudioObjectID = 6   // output mute control

// MARK: - Custom property selectors
// Four-char codes used for IPC between the companion app and this driver.
// AudioObjectSetPropertyData / AudioObjectGetPropertyData with these selectors.

/// CFString — the display name shown in System Settings and Sound
let kCustomProp_Name: AudioObjectPropertySelector    = fourCharCode("apnm")

/// CFBoolean — when false the device is hidden from the system
let kCustomProp_Shown: AudioObjectPropertySelector   = fourCharCode("apsh")

/// CFString — read-only, returns kDriverBundleID; lets the app discover us
let kCustomProp_Identity: AudioObjectPropertySelector = fourCharCode("apid")

// MARK: - Audio format

let kSampleRate: Float64 = 48000
let kChannelCount: UInt32 = 2
let kBitsPerChannel: UInt32 = 32
let kBytesPerFrame: UInt32 = kChannelCount * (kBitsPerChannel / 8)  // 8
let kFramesPerPacket: UInt32 = 1
let kBytesPerPacket: UInt32 = kBytesPerFrame * kFramesPerPacket       // 8

/// Supported sample rates advertised to the HAL
let kSupportedSampleRates: [Float64] = [44100, 48000, 88200, 96000]

// MARK: - IO Operation IDs
// From AudioServerPlugIn.h CF_ENUM(UInt32) — these are FourCC codes, not ordinals.
// Swift does not always import CF_ENUM members as top-level constants.
let kAPIOOperationReadInput: UInt32 = fourCharCode("read")  // kAudioServerPlugInIOOperationReadInput = 'read'
let kAPIOOperationWriteMix:  UInt32 = fourCharCode("rite")  // kAudioServerPlugInIOOperationWriteMix  = 'rite'

// MARK: - Ring buffer

/// Frames in the loopback ring buffer (≈85 ms at 48000 Hz)
let kRingBufferFrameCount: Int = 4096

// MARK: - Helpers

/// Convert a 4-character ASCII string to a UInt32 four-char code.
@inline(__always)
func fourCharCode(_ s: StaticString) -> UInt32 {
    precondition(s.utf8CodeUnitCount == 4, "fourCharCode requires exactly 4 characters")
    let p = s.utf8Start
    return (UInt32(p[0]) << 24)
         | (UInt32(p[1]) << 16)
         | (UInt32(p[2]) <<  8)
         |  UInt32(p[3])
}
