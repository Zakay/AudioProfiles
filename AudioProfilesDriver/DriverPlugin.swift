// DriverPlugin.swift — AudioProfilesDriver
//
// Handles all property queries on the Plugin object (kObjectID_Plugin = 1).
// The plugin object is the root of the driver's object graph.
// coreaudiod calls HasProperty / GetPropertyDataSize / GetPropertyData
// on kObjectID_Plugin to discover what devices we own.

import CoreAudio

// MARK: - Plugin property dispatch

/// Returns true when the plugin object owns the given property.
func pluginHasProperty(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
) -> Bool {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyName,
         kAudioObjectPropertyOwnedObjects,
         kAudioPlugInPropertyDeviceList,
         kAudioPlugInPropertyTranslateUIDToDevice,
         kAudioPlugInPropertyResourceBundle:
        return true
    default:
        return false
    }
}

/// Returns the byte count for the given plugin property.
func pluginGetPropertyDataSize(
    selector: AudioObjectPropertySelector,
    scope:    AudioObjectPropertyScope
) -> UInt32 {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner:
        return UInt32(MemoryLayout<AudioClassID>.size)

    case kAudioObjectPropertyName,
         kAudioPlugInPropertyResourceBundle:
        return UInt32(MemoryLayout<CFString>.size)

    case kAudioObjectPropertyOwnedObjects,
         kAudioPlugInPropertyDeviceList:
        // Always expose our device — visibility is controlled by
        // kAudioDevicePropertyIsHidden so the companion app can always
        // find us by UID and call show() / hide().
        return UInt32(MemoryLayout<AudioObjectID>.size)

    case kAudioPlugInPropertyTranslateUIDToDevice:
        return UInt32(MemoryLayout<AudioObjectID>.size)

    default:
        return 0
    }
}

/// Fill `outData` with the plugin property value. Returns noErr or an OSStatus error.
func pluginGetPropertyData(
    selector:  AudioObjectPropertySelector,
    scope:     AudioObjectPropertyScope,
    qualifier: UnsafeRawPointer?,
    qualifierSize: UInt32,
    outDataSize: inout UInt32,
    outData: UnsafeMutableRawPointer
) -> OSStatus {
    switch selector {

    case kAudioObjectPropertyBaseClass:
        outDataSize = UInt32(MemoryLayout<AudioClassID>.size)
        outData.storeBytes(of: kAudioObjectClassID, as: AudioClassID.self)

    case kAudioObjectPropertyClass:
        outDataSize = UInt32(MemoryLayout<AudioClassID>.size)
        outData.storeBytes(of: kAudioPlugInClassID, as: AudioClassID.self)

    case kAudioObjectPropertyOwner:
        outDataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        outData.storeBytes(of: AudioObjectID(kAudioObjectSystemObject), as: AudioObjectID.self)

    case kAudioObjectPropertyName:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        // storeBytes requires BitwiseCopyable; store the raw retained pointer instead.
        outData.storeBytes(of: Unmanaged.passRetained(kDeviceDefaultName).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kAudioObjectPropertyOwnedObjects,
         kAudioPlugInPropertyDeviceList:
        // Always expose our device — visibility is controlled by
        // kAudioDevicePropertyIsHidden on the device object.
        outDataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        outData.storeBytes(of: kObjectID_Device, as: AudioObjectID.self)

    case kAudioPlugInPropertyTranslateUIDToDevice:
        // qualifier contains a CFString UID; return our device ID if it matches
        guard qualifierSize >= MemoryLayout<CFString>.size,
              let qPtr = qualifier else {
            return kAudioHardwareBadPropertySizeError
        }
        let uid = qPtr.load(as: CFString.self)
        let matched = CFEqual(uid, kDeviceUID)
        let result: AudioObjectID = matched ? kObjectID_Device : kAudioObjectUnknown
        outDataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        outData.storeBytes(of: result, as: AudioObjectID.self)

    case kAudioPlugInPropertyResourceBundle:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        outData.storeBytes(of: Unmanaged.passRetained("" as CFString).toOpaque(),
                           as: UnsafeRawPointer.self)

    default:
        return kAudioHardwareUnknownPropertyError
    }

    return noErr
}
