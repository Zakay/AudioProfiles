// DriverMain.swift — AudioProfilesDriver
//
// All @_cdecl functions that implement the AudioServerPlugInDriverInterface
// vtable. The ObjC bridge (DriverBridge.m) creates the C struct with function
// pointers pointing to these symbols, and hands it to coreaudiod.
//
// Threading: coreaudiod calls these from its own threads.
// We serialise non-IO calls through gDriverQueue; IO operations are lock-free.

import CoreAudio
import Foundation
import os.log

// MARK: - Driver serial queue (non-IO operations)

let gDriverQueue = DispatchQueue(label: "com.audioprofiles.driver.main")
let gLog = OSLog(subsystem: "com.audioprofiles.driver", category: "main")

/// Format a 4-byte selector as a human-readable FourCC string like 'clas'
func fourCCString(_ code: UInt32) -> String {
    let b0 = UInt8((code >> 24) & 0xFF)
    let b1 = UInt8((code >> 16) & 0xFF)
    let b2 = UInt8((code >>  8) & 0xFF)
    let b3 = UInt8( code        & 0xFF)
    let bytes = [b0, b1, b2, b3]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return String(format: "0x%08X", code)
}

// MARK: - Lifecycle

@_cdecl("AP_Initialize")
func AP_Initialize(
    _ inDriver: AudioServerPlugInDriverRef,
    _ inHost:   AudioServerPlugInHostRef
) -> OSStatus {
    os_log(.info, log: gLog, "AP_Initialize called, host=%p", inHost)
    DriverState.shared.host = inHost
    os_log(.info, log: gLog, "AP_Initialize -> noErr")
    return noErr
}

@_cdecl("AP_CreateDevice")
func AP_CreateDevice(
    _ inDriver:    AudioServerPlugInDriverRef,
    _ inDesc:      CFDictionary,
    _ inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>,
    _ outDeviceID: UnsafeMutablePointer<AudioObjectID>
) -> OSStatus {
    // We don't support dynamic device creation — single device is always present
    return kAudioHardwareUnsupportedOperationError
}

@_cdecl("AP_DestroyDevice")
func AP_DestroyDevice(
    _ inDriver:   AudioServerPlugInDriverRef,
    _ inDeviceID: AudioObjectID
) -> OSStatus {
    return kAudioHardwareUnsupportedOperationError
}

@_cdecl("AP_AddDeviceClient")
func AP_AddDeviceClient(
    _ inDriver:     AudioServerPlugInDriverRef,
    _ inDeviceID:   AudioObjectID,
    _ inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>
) -> OSStatus {
    return noErr
}

@_cdecl("AP_RemoveDeviceClient")
func AP_RemoveDeviceClient(
    _ inDriver:     AudioServerPlugInDriverRef,
    _ inDeviceID:   AudioObjectID,
    _ inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>
) -> OSStatus {
    return noErr
}

@_cdecl("AP_PerformDeviceConfigurationChange")
func AP_PerformDeviceConfigurationChange(
    _ inDriver:       AudioServerPlugInDriverRef,
    _ inDeviceID:     AudioObjectID,
    _ inChangeAction: UInt64,
    _ inChangeInfo:   UnsafeMutableRawPointer?
) -> OSStatus {
    return noErr
}

@_cdecl("AP_AbortDeviceConfigurationChange")
func AP_AbortDeviceConfigurationChange(
    _ inDriver:       AudioServerPlugInDriverRef,
    _ inDeviceID:     AudioObjectID,
    _ inChangeAction: UInt64,
    _ inChangeInfo:   UnsafeMutableRawPointer?
) -> OSStatus {
    return noErr
}

// MARK: - Property queries

@_cdecl("AP_HasProperty")
func AP_HasProperty(
    _ inDriver:   AudioServerPlugInDriverRef,
    _ inObjectID: AudioObjectID,
    _ inClientID: UInt32,
    _ inAddress:  UnsafePointer<AudioObjectPropertyAddress>
) -> DarwinBoolean {
    let sel   = inAddress.pointee.mSelector
    let scope = inAddress.pointee.mScope
    let result: Bool
    switch inObjectID {
    case kObjectID_Plugin:
        result = pluginHasProperty(selector: sel, scope: scope)
    case kObjectID_Device, kObjectID_Stream_Output, kObjectID_Stream_Input,
         kObjectID_Volume_Output, kObjectID_Mute_Output:
        result = deviceHasProperty(objectID: inObjectID, selector: sel, scope: scope)
    default:
        result = false
    }
    os_log(.info, log: gLog, "AP_HasProperty obj=%u sel=%{public}@ -> %d",
           inObjectID, fourCCString(sel), result ? 1 : 0)
    return DarwinBoolean(result)
}

@_cdecl("AP_IsPropertySettable")
func AP_IsPropertySettable(
    _ inDriver:    AudioServerPlugInDriverRef,
    _ inObjectID:  AudioObjectID,
    _ inClientID:  UInt32,
    _ inAddress:   UnsafePointer<AudioObjectPropertyAddress>,
    _ outSettable: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
    let sel   = inAddress.pointee.mSelector
    let scope = inAddress.pointee.mScope
    outSettable.pointee = DarwinBoolean(
        deviceIsPropertySettable(objectID: inObjectID, selector: sel, scope: scope)
    )
    return noErr
}

@_cdecl("AP_GetPropertyDataSize")
func AP_GetPropertyDataSize(
    _ inDriver:        AudioServerPlugInDriverRef,
    _ inObjectID:      AudioObjectID,
    _ inClientID:      UInt32,
    _ inAddress:       UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierSize: UInt32,
    _ inQualifierData: UnsafeRawPointer?,
    _ outDataSize:     UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let sel   = inAddress.pointee.mSelector
    let scope = inAddress.pointee.mScope
    let status: OSStatus
    switch inObjectID {
    case kObjectID_Plugin:
        outDataSize.pointee = pluginGetPropertyDataSize(selector: sel, scope: scope)
        status = noErr
    case kObjectID_Device, kObjectID_Stream_Output, kObjectID_Stream_Input,
         kObjectID_Volume_Output, kObjectID_Mute_Output:
        outDataSize.pointee = deviceGetPropertyDataSize(
            objectID: inObjectID, selector: sel, scope: scope,
            qualifierSize: inQualifierSize, qualifier: inQualifierData
        )
        status = noErr
    default:
        outDataSize.pointee = 0
        status = kAudioHardwareBadObjectError
    }
    os_log(.info, log: gLog, "AP_GetPropertyDataSize obj=%u sel=%{public}@ -> size=%u status=%d",
           inObjectID, fourCCString(sel), outDataSize.pointee, status)
    return status
}

@_cdecl("AP_GetPropertyData")
func AP_GetPropertyData(
    _ inDriver:          AudioServerPlugInDriverRef,
    _ inObjectID:        AudioObjectID,
    _ inClientID:        UInt32,
    _ inAddress:         UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierSize:   UInt32,
    _ inQualifierData:   UnsafeRawPointer?,
    _ inDataSize:        UInt32,
    _ outDataSize:       UnsafeMutablePointer<UInt32>,
    _ outData:           UnsafeMutableRawPointer
) -> OSStatus {
    let sel   = inAddress.pointee.mSelector
    let scope = inAddress.pointee.mScope
    outDataSize.pointee = inDataSize
    let status: OSStatus
    switch inObjectID {
    case kObjectID_Plugin:
        status = pluginGetPropertyData(
            selector: sel, scope: scope,
            qualifier: inQualifierData, qualifierSize: inQualifierSize,
            outDataSize: &outDataSize.pointee, outData: outData
        )
    case kObjectID_Device, kObjectID_Stream_Output, kObjectID_Stream_Input,
         kObjectID_Volume_Output, kObjectID_Mute_Output:
        status = deviceGetPropertyData(
            objectID: inObjectID, selector: sel, scope: scope,
            qualifier: inQualifierData, qualifierSize: inQualifierSize,
            outDataSize: &outDataSize.pointee, outData: outData, client: nil
        )
    default:
        status = kAudioHardwareBadObjectError
    }
    os_log(.info, log: gLog, "AP_GetPropertyData obj=%u sel=%{public}@ outSize=%u -> status=%d",
           inObjectID, fourCCString(sel), outDataSize.pointee, status)
    return status
}

@_cdecl("AP_SetPropertyData")
func AP_SetPropertyData(
    _ inDriver:        AudioServerPlugInDriverRef,
    _ inObjectID:      AudioObjectID,
    _ inClientID:      Int32,   // pid_t
    _ inAddress:       UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierSize: UInt32,
    _ inQualifierData: UnsafeRawPointer?,
    _ inDataSize:      UInt32,
    _ inData:          UnsafeRawPointer
) -> OSStatus {
    let sel   = inAddress.pointee.mSelector
    let scope = inAddress.pointee.mScope
    return deviceSetPropertyData(
        objectID: inObjectID, selector: sel, scope: scope,
        qualifier: inQualifierData, qualifierSize: inQualifierSize,
        dataSize: inDataSize, data: inData
    )
}

// MARK: - IO Lifecycle

@_cdecl("AP_StartIO")
func AP_StartIO(
    _ inDriver:   AudioServerPlugInDriverRef,
    _ inDeviceID: AudioObjectID,
    _ inClientID: UInt32
) -> OSStatus {
    os_log(.info, log: gLog, "AP_StartIO deviceID=%u clientID=%u", inDeviceID, inClientID)
    DriverState.shared.startIO()
    return noErr
}

@_cdecl("AP_StopIO")
func AP_StopIO(
    _ inDriver:   AudioServerPlugInDriverRef,
    _ inDeviceID: AudioObjectID,
    _ inClientID: UInt32
) -> OSStatus {
    DriverState.shared.stopIO()
    return noErr
}

@_cdecl("AP_GetZeroTimeStamp")
func AP_GetZeroTimeStamp(
    _ inDriver:       AudioServerPlugInDriverRef,
    _ inDeviceID:     AudioObjectID,
    _ inClientID:     UInt32,
    _ outSampleTime:  UnsafeMutablePointer<Float64>,
    _ outHostTime:    UnsafeMutablePointer<UInt64>,
    _ outSeed:        UnsafeMutablePointer<UInt64>
) -> OSStatus {
    return deviceGetZeroTimeStamp(
        deviceID:      inDeviceID,
        clientID:      inClientID,
        outSampleTime: &outSampleTime.pointee,
        outHostTime:   &outHostTime.pointee,
        outSeed:       &outSeed.pointee
    )
}

@_cdecl("AP_WillDoIOOperation")
func AP_WillDoIOOperation(
    _ inDriver:      AudioServerPlugInDriverRef,
    _ inDeviceID:    AudioObjectID,
    _ inClientID:    UInt32,
    _ inOperationID: UInt32,
    _ outWillDo:     UnsafeMutablePointer<DarwinBoolean>,
    _ outWillDoInPlace: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
    let willDo: Bool
    switch inOperationID {
    case kAPIOOperationReadInput,
         kAPIOOperationWriteMix:
        willDo = true
    default:
        willDo = false
    }
    outWillDo.pointee        = DarwinBoolean(willDo)
    outWillDoInPlace.pointee = true
    return noErr
}

@_cdecl("AP_BeginIOOperation")
func AP_BeginIOOperation(
    _ inDriver:      AudioServerPlugInDriverRef,
    _ inDeviceID:    AudioObjectID,
    _ inClientID:    UInt32,
    _ inOperationID: UInt32,
    _ inIOBufferFrameSize: UInt32,
    _ inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus { noErr }

@_cdecl("AP_DoIOOperation")
func AP_DoIOOperation(
    _ inDriver:      AudioServerPlugInDriverRef,
    _ inDeviceID:    AudioObjectID,
    _ inStreamID:    AudioObjectID,
    _ inClientID:    UInt32,
    _ inOperationID: UInt32,
    _ inIOBufferFrameSize: UInt32,
    _ inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>,
    _ ioMainBuffer: UnsafeMutableRawPointer?,
    _ ioSecondaryBuffer: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let buffer = ioMainBuffer else { return noErr }

    // Wrap the raw pointer in an AudioBufferList for deviceDoIOOperation
    var abl = AudioBufferList()
    abl.mNumberBuffers = 1
    withUnsafeMutablePointer(to: &abl.mBuffers) { bufPtr in
        bufPtr.pointee.mNumberChannels = kChannelCount
        bufPtr.pointee.mDataByteSize   = inIOBufferFrameSize * kBytesPerFrame
        bufPtr.pointee.mData           = buffer
    }

    return withUnsafeMutablePointer(to: &abl) { ablPtr in
        deviceDoIOOperation(
            deviceID:    inDeviceID,
            streamID:    inStreamID,
            clientID:    inClientID,
            operationID: inOperationID,
            ioBufferFrameSize: inIOBufferFrameSize,
            ioAudioBufferList: ablPtr
        )
    }
}

@_cdecl("AP_EndIOOperation")
func AP_EndIOOperation(
    _ inDriver:      AudioServerPlugInDriverRef,
    _ inDeviceID:    AudioObjectID,
    _ inClientID:    UInt32,
    _ inOperationID: UInt32,
    _ inIOBufferFrameSize: UInt32,
    _ inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus { noErr }
