import Foundation
import CoreAudio

// MARK: - Shared custom-property selectors
// Must stay in sync with DriverConstants.swift in the driver target.

private let kAPCustomProp_Name:     AudioObjectPropertySelector = fourCC("apnm")
private let kAPCustomProp_Shown:    AudioObjectPropertySelector = fourCC("apsh")
private let kAPCustomProp_Identity: AudioObjectPropertySelector = fourCC("apid")

private let kDriverDeviceUID = "AudioProfilesEQDevice-UID"

@inline(__always)
private func fourCC(_ s: StaticString) -> UInt32 {
    precondition(s.utf8CodeUnitCount == 4)
    let p = s.utf8Start
    return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
}

// MARK: - EQDriverService

/// Communicates with the installed AudioProfilesDriver via CoreAudio's custom
/// property API.  All writes go through AudioObjectSetPropertyData, routed by
/// coreaudiod into the driver's SetPropertyData callback.
///
/// Key operations:
///   - `show(name:)`  — makes the virtual device appear in System Settings
///   - `hide()`       — makes it disappear (device is still loaded, just invisible)
///   - `setName(_:)`  — updates the display name at any time
///   - `findDevice()` — returns the AudioObjectID of our virtual device, if present
final class EQDriverService {

    static let shared = EQDriverService()
    private init() {}

    // MARK: - Public API

    /// Find and show the virtual device, setting its display name.
    /// Call AFTER setting the system default output to the virtual device.
    @discardableResult
    func show(name: String) -> Bool {
        guard let deviceID = findDevice() else {
            AppLogger.error("EQDriverService: virtual device not found — driver may not be installed.")
            return false
        }
        setName(name, on: deviceID)
        setShown(true, on: deviceID)
        AppLogger.info("EQDriverService: virtual device shown as '\(name)'")
        return true
    }

    /// Hide the virtual device.
    /// Call ONLY AFTER switching system default output back to real hardware.
    @discardableResult
    func hide() -> Bool {
        guard let deviceID = findDevice() else { return false }
        setShown(false, on: deviceID)
        AppLogger.info("EQDriverService: virtual device hidden")
        return true
    }

    /// Update the display name of the virtual device without changing visibility.
    func setName(_ name: String) {
        guard let deviceID = findDevice() else { return }
        setName(name, on: deviceID)
    }

    /// Return the AudioObjectID of the virtual device, or nil if not present.
    ///
    /// Uses `kAudioPlugInPropertyTranslateUIDToDevice` first — this finds the
    /// device even when it's hidden (kAudioDevicePropertyIsHidden = 1), since
    /// `kAudioHardwarePropertyDevices` excludes hidden devices.
    /// Falls back to enumerating the visible device list for robustness.
    func findDevice() -> AudioObjectID? {
        // Primary: translate our known UID directly — works for hidden devices too
        if let id = translateUIDToDevice(kDriverDeviceUID) {
            return id
        }

        // Fallback: enumerate visible devices and match by custom identity or UID
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            if let identity = readCFString(property: kAPCustomProp_Identity, from: id),
               identity == "com.audioprofiles.driver" {
                return id
            }
        }

        for id in deviceIDs {
            if let uid = readCFString(property: kAudioDevicePropertyDeviceUID, from: id),
               uid == kDriverDeviceUID {
                return id
            }
        }
        return nil
    }

    /// Ask the HAL to translate a device UID to an AudioObjectID.
    /// Returns nil if no device with that UID is registered.
    private func translateUIDToDevice(_ uid: String) -> AudioObjectID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioPlugInPropertyTranslateUIDToDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID: CFString = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propAddr,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Return the AudioDevice struct for the virtual device (used by EQEngineService).
    func findAudioDevice() -> AudioDevice? {
        guard let objectID = findDevice() else { return nil }
        return AudioDeviceFactory.createAudioDevice(from: objectID)
    }

    /// Check if a given device UID is our virtual EQ device.
    func isOurVirtualDevice(_ deviceUID: String) -> Bool {
        return deviceUID == kDriverDeviceUID
    }

    /// Check if a given AudioObjectID is our virtual EQ device.
    func isOurVirtualDevice(objectID: AudioObjectID) -> Bool {
        guard let ourID = findDevice() else { return false }
        return objectID == ourID
    }

    // MARK: - Private

    private func setShown(_ shown: Bool, on deviceID: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAPCustomProp_Shown,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cfBool: CFBoolean = shown ? kCFBooleanTrue : kCFBooleanFalse
        let status = withUnsafeMutableBytes(of: &cfBool) { rawBuf in
            AudioObjectSetPropertyData(
                deviceID, &addr,
                0, nil,
                UInt32(MemoryLayout<CFBoolean>.size),
                rawBuf.baseAddress!
            )
        }
        if status != noErr {
            AppLogger.error("EQDriverService: setShown failed with \(status)")
        }
    }

    private func setName(_ name: String, on deviceID: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAPCustomProp_Name,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cfName: CFString = name as CFString
        let status = withUnsafeMutableBytes(of: &cfName) { rawBuf in
            AudioObjectSetPropertyData(
                deviceID, &addr,
                0, nil,
                UInt32(MemoryLayout<CFString>.size),
                rawBuf.baseAddress!
            )
        }
        if status != noErr {
            AppLogger.error("EQDriverService: setName failed with \(status)")
        }
    }

    private func readCFString(property: AudioObjectPropertySelector,
                              from deviceID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: property,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cfStr: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutableBytes(of: &cfStr) { rawBuf in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, rawBuf.baseAddress!)
        }
        guard status == noErr, let str = cfStr else { return nil }
        return str as String
    }
}
