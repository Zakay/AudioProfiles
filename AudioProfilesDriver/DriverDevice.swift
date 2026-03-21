// DriverDevice.swift — AudioProfilesDriver
//
// Handles all property queries on the Device (kObjectID_Device),
// both Stream objects, and IO operations (DoIOOperation).
//
// The device is a stereo Float32 loopback:
//   - The system writes audio to it via WriteMix  → stored in RingBuffer
//   - The companion app reads audio via ReadInput ← fetched from RingBuffer

import CoreAudio
import Darwin
import os.log

// MARK: - Custom property info list (advertised to the HAL)

private let customPropertyInfoList: [AudioServerPlugInCustomPropertyInfo] = [
    // kCustomProp_Name  — CFString, settable by companion app
    AudioServerPlugInCustomPropertyInfo(
        mSelector:         kCustomProp_Name,
        mPropertyDataType: kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
        mQualifierDataType: kAudioServerPlugInCustomPropertyDataTypeNone
    ),
    // kCustomProp_Shown — CFBoolean, settable by companion app
    AudioServerPlugInCustomPropertyInfo(
        mSelector:         kCustomProp_Shown,
        mPropertyDataType: kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
        mQualifierDataType: kAudioServerPlugInCustomPropertyDataTypeNone
    ),
    // kCustomProp_Identity — CFString, read-only (lets app discover us)
    AudioServerPlugInCustomPropertyInfo(
        mSelector:         kCustomProp_Identity,
        mPropertyDataType: kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
        mQualifierDataType: kAudioServerPlugInCustomPropertyDataTypeNone
    ),
]

// MARK: - Device property dispatch

func deviceHasProperty(
    objectID:  AudioObjectID,
    selector:  AudioObjectPropertySelector,
    scope:     AudioObjectPropertyScope
) -> Bool {
    switch objectID {
    case kObjectID_Device:
        return deviceObjectHasProperty(selector: selector, scope: scope)
    case kObjectID_Stream_Output, kObjectID_Stream_Input:
        return streamHasProperty(selector: selector)
    case kObjectID_Volume_Output:
        return volumeControlHasProperty(selector: selector)
    case kObjectID_Mute_Output:
        return muteControlHasProperty(selector: selector)
    default:
        return false
    }
}

func deviceIsPropertySettable(
    objectID:  AudioObjectID,
    selector:  AudioObjectPropertySelector,
    scope:     AudioObjectPropertyScope
) -> Bool {
    switch objectID {
    case kObjectID_Volume_Output:
        return selector == kAudioLevelControlPropertyScalarValue
            || selector == kAudioLevelControlPropertyDecibelValue
    case kObjectID_Mute_Output:
        return selector == kAudioBooleanControlPropertyValue
    default:
        switch selector {
        case kAudioDevicePropertyNominalSampleRate,
             kAudioDevicePropertyBufferFrameSize,
             kCustomProp_Name,
             kCustomProp_Shown:
            return true
        default:
            return false
        }
    }
}

func deviceGetPropertyDataSize(
    objectID:      AudioObjectID,
    selector:      AudioObjectPropertySelector,
    scope:         AudioObjectPropertyScope,
    qualifierSize: UInt32,
    qualifier:     UnsafeRawPointer?
) -> UInt32 {
    switch objectID {
    case kObjectID_Device:
        return deviceObjectGetPropertyDataSize(selector: selector, scope: scope)
    case kObjectID_Stream_Output, kObjectID_Stream_Input:
        return streamGetPropertyDataSize(selector: selector)
    case kObjectID_Volume_Output:
        return volumeControlGetPropertyDataSize(selector: selector)
    case kObjectID_Mute_Output:
        return muteControlGetPropertyDataSize(selector: selector)
    default:
        return 0
    }
}

func deviceGetPropertyData(
    objectID:      AudioObjectID,
    selector:      AudioObjectPropertySelector,
    scope:         AudioObjectPropertyScope,
    qualifier:     UnsafeRawPointer?,
    qualifierSize: UInt32,
    outDataSize:   inout UInt32,
    outData:       UnsafeMutableRawPointer,
    client:        UnsafePointer<AudioServerPlugInClientInfo>?
) -> OSStatus {
    switch objectID {
    case kObjectID_Device:
        return deviceObjectGetPropertyData(
            selector: selector, scope: scope,
            outDataSize: &outDataSize, outData: outData
        )
    case kObjectID_Stream_Output:
        return streamGetPropertyData(
            objectID: kObjectID_Stream_Output,
            selector: selector, scope: scope,
            outDataSize: &outDataSize, outData: outData
        )
    case kObjectID_Stream_Input:
        return streamGetPropertyData(
            objectID: kObjectID_Stream_Input,
            selector: selector, scope: scope,
            outDataSize: &outDataSize, outData: outData
        )
    case kObjectID_Volume_Output:
        return volumeControlGetPropertyData(
            selector: selector, outDataSize: &outDataSize, outData: outData
        )
    case kObjectID_Mute_Output:
        return muteControlGetPropertyData(
            selector: selector, outDataSize: &outDataSize, outData: outData
        )
    default:
        return kAudioHardwareBadObjectError
    }
}

func deviceSetPropertyData(
    objectID:      AudioObjectID,
    selector:      AudioObjectPropertySelector,
    scope:         AudioObjectPropertyScope,
    qualifier:     UnsafeRawPointer?,
    qualifierSize: UInt32,
    dataSize:      UInt32,
    data:          UnsafeRawPointer
) -> OSStatus {

    switch objectID {

    case kObjectID_Volume_Output:
        guard dataSize >= MemoryLayout<Float32>.size else { return kAudioHardwareBadPropertySizeError }
        let value = data.load(as: Float32.self)
        switch selector {
        case kAudioLevelControlPropertyScalarValue:
            DriverState.shared.volumeScalar = min(max(value, 0), 1)
        case kAudioLevelControlPropertyDecibelValue:
            DriverState.shared.volumeDB = value
        default:
            return kAudioHardwareUnknownPropertyError
        }

    case kObjectID_Mute_Output:
        guard selector == kAudioBooleanControlPropertyValue else { return kAudioHardwareUnknownPropertyError }
        guard dataSize >= MemoryLayout<UInt32>.size else { return kAudioHardwareBadPropertySizeError }
        DriverState.shared.isMuted = data.load(as: UInt32.self) != 0

    default:
        switch selector {
        case kCustomProp_Name:
            guard dataSize >= MemoryLayout<CFString>.size else { return kAudioHardwareBadPropertySizeError }
            let cfName = data.load(as: CFString.self)
            DriverState.shared.deviceName = cfName as String

        case kCustomProp_Shown:
            guard dataSize >= MemoryLayout<CFBoolean>.size else { return kAudioHardwareBadPropertySizeError }
            let cfBool = data.load(as: CFBoolean.self)
            DriverState.shared.isShown = CFBooleanGetValue(cfBool)

        case kAudioDevicePropertyNominalSampleRate:
            guard dataSize >= MemoryLayout<Float64>.size else { return kAudioHardwareBadPropertySizeError }
            let rate = data.load(as: Float64.self)
            guard kSupportedSampleRates.contains(rate) else { return kAudioDeviceUnsupportedFormatError }
            DriverState.shared.sampleRate = rate

        case kAudioDevicePropertyBufferFrameSize:
            guard dataSize >= MemoryLayout<UInt32>.size else { return kAudioHardwareBadPropertySizeError }
            let size = data.load(as: UInt32.self)
            let clamped = min(max(size, 64), 4096)
            DriverState.shared.bufferFrameSize = clamped

        default:
            return kAudioHardwareUnknownPropertyError
        }
    }

    return noErr
}

// MARK: - IO Operations

func deviceDoIOOperation(
    deviceID:    AudioObjectID,
    streamID:    AudioObjectID,
    clientID:    UInt32,
    operationID: UInt32,
    ioBufferFrameSize: UInt32,
    ioAudioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {

    let ring = DriverState.shared.ringBuffer
    let frames = Int(ioBufferFrameSize)

    switch operationID {

    case kAPIOOperationWriteMix:
        // System audio → ring buffer + shared memory (real-time path — keep minimal)
        let abl = ioAudioBufferList.pointee
        if abl.mNumberBuffers > 0 {
            let buf = abl.mBuffers
            let ptr = buf.mData!.assumingMemoryBound(to: Float32.self)

            // Apply volume/mute gain inline
            let gain = DriverState.shared.ioGain
            if gain < 1.0 {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
                for i in 0..<count { ptr[i] *= gain }
            }

            ring.write(from: ptr, frameCount: frames)

            // Also write to shared memory for TCC-free app-side reading
            DriverState.shared.sharedBuffer?.write(from: ptr, frameCount: frames)
        }

    case kAPIOOperationReadInput:
        // Ring buffer → app (real-time path — keep minimal)
        if ioAudioBufferList.pointee.mNumberBuffers > 0 {
            let ptr = withUnsafeMutablePointer(to: &ioAudioBufferList.pointee.mBuffers) { bufPtr in
                bufPtr.pointee.mData!.assumingMemoryBound(to: Float32.self)
            }
            ring.read(into: ptr, frameCount: frames)
        }

    default:
        break   // Other operations (e.g. ConvertMix) — no-op
    }

    return noErr
}

// MARK: - GetZeroTimeStamp

/// Cached timebase info — never changes during process lifetime.
private let gTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func deviceGetZeroTimeStamp(
    deviceID:         AudioObjectID,
    clientID:         UInt32,
    outSampleTime:    inout Float64,
    outHostTime:      inout UInt64,
    outSeed:          inout UInt64
) -> OSStatus {

    let state = DriverState.shared
    let framesPerBuffer: Float64 = Float64(state.bufferFrameSize)

    let nanosPerTick   = Double(gTimebaseInfo.numer) / Double(gTimebaseInfo.denom)
    let nanosPerFrame  = 1_000_000_000.0 / state.sampleRate
    let ticksPerFrame  = nanosPerFrame / nanosPerTick

    let elapsed      = mach_absolute_time() - state.anchorHostTime
    let elapsedFrames = Double(elapsed) / ticksPerFrame
    let bufferIndex  = floor(elapsedFrames / framesPerBuffer)

    outSampleTime = bufferIndex * framesPerBuffer
    outHostTime   = state.anchorHostTime + UInt64((bufferIndex * framesPerBuffer) * ticksPerFrame)
    outSeed       = 1

    return noErr
}

// MARK: - Private: Device object properties

private func deviceObjectHasProperty(
    selector: AudioObjectPropertySelector,
    scope:    AudioObjectPropertyScope
) -> Bool {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyName,
         kAudioObjectPropertyOwnedObjects,
         kAudioDevicePropertyDeviceUID,
         kAudioDevicePropertyModelUID,
         kAudioDevicePropertyTransportType,
         kAudioDevicePropertyRelatedDevices,
         kAudioDevicePropertyClockDomain,
         kAudioDevicePropertyDeviceIsAlive,
         kAudioDevicePropertyDeviceIsRunning,
         kAudioDevicePropertyDeviceCanBeDefaultDevice,
         kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
         kAudioDevicePropertyLatency,
         kAudioDevicePropertyStreams,
         kAudioObjectPropertyControlList,
         kAudioDevicePropertySafetyOffset,
         kAudioDevicePropertyNominalSampleRate,
         kAudioDevicePropertyAvailableNominalSampleRates,
         kAudioDevicePropertyIsHidden,
         kAudioDevicePropertyZeroTimeStampPeriod,
         kAudioDevicePropertyBufferFrameSize,
         kAudioDevicePropertyBufferFrameSizeRange,
         kAudioObjectPropertyCustomPropertyInfoList,
         kCustomProp_Name,
         kCustomProp_Shown,
         kCustomProp_Identity:
        return true
    default:
        return false
    }
}

private func deviceObjectGetPropertyDataSize(
    selector: AudioObjectPropertySelector,
    scope:    AudioObjectPropertyScope
) -> UInt32 {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioDevicePropertyTransportType,
         kAudioDevicePropertyClockDomain,
         kAudioDevicePropertyDeviceIsAlive,
         kAudioDevicePropertyDeviceIsRunning,
         kAudioDevicePropertyDeviceCanBeDefaultDevice,
         kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
         kAudioDevicePropertyLatency,
         kAudioDevicePropertySafetyOffset,
         kAudioDevicePropertyZeroTimeStampPeriod,
         kAudioDevicePropertyIsHidden,
         kAudioDevicePropertyBufferFrameSize:
        return UInt32(MemoryLayout<UInt32>.size)

    case kAudioDevicePropertyBufferFrameSizeRange:
        return UInt32(MemoryLayout<AudioValueRange>.size)

    case kAudioDevicePropertyNominalSampleRate:
        return UInt32(MemoryLayout<Float64>.size)

    case kAudioObjectPropertyName,
         kAudioDevicePropertyDeviceUID,
         kAudioDevicePropertyModelUID,
         kCustomProp_Name,
         kCustomProp_Identity:
        return UInt32(MemoryLayout<CFString>.size)

    case kCustomProp_Shown:
        return UInt32(MemoryLayout<CFBoolean>.size)

    case kAudioObjectPropertyOwnedObjects:
        // Two streams + volume control + mute control
        return UInt32(4 * MemoryLayout<AudioObjectID>.size)

    case kAudioDevicePropertyRelatedDevices:
        return UInt32(MemoryLayout<AudioObjectID>.size)

    case kAudioDevicePropertyStreams:
        // Input scope → 1 stream, Output scope → 1 stream, Global → both
        switch scope {
        case kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput:
            return UInt32(MemoryLayout<AudioObjectID>.size)
        default: // global
            return UInt32(2 * MemoryLayout<AudioObjectID>.size)
        }

    case kAudioObjectPropertyControlList:
        return UInt32(2 * MemoryLayout<AudioObjectID>.size)  // volume + mute

    case kAudioDevicePropertyAvailableNominalSampleRates:
        return UInt32(kSupportedSampleRates.count * MemoryLayout<AudioValueRange>.size)

    case kAudioObjectPropertyCustomPropertyInfoList:
        return UInt32(customPropertyInfoList.count * MemoryLayout<AudioServerPlugInCustomPropertyInfo>.size)

    default:
        return 0
    }
}

private func deviceObjectGetPropertyData(
    selector:    AudioObjectPropertySelector,
    scope:       AudioObjectPropertyScope,
    outDataSize: inout UInt32,
    outData:     UnsafeMutableRawPointer
) -> OSStatus {

    let state = DriverState.shared

    switch selector {

    case kAudioObjectPropertyBaseClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioObjectClassID, as: AudioClassID.self)

    case kAudioObjectPropertyClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioDeviceClassID, as: AudioClassID.self)

    case kAudioObjectPropertyOwner:
        outDataSize = 4
        outData.storeBytes(of: kObjectID_Plugin, as: AudioObjectID.self)

    case kAudioObjectPropertyName:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        // storeBytes requires BitwiseCopyable; store the raw retained pointer instead.
        outData.storeBytes(of: Unmanaged.passRetained(state.deviceName as CFString).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kAudioDevicePropertyDeviceUID:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        outData.storeBytes(of: Unmanaged.passRetained(kDeviceUID).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kAudioDevicePropertyModelUID:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        outData.storeBytes(of: Unmanaged.passRetained("AudioProfilesEQ-Model" as CFString).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kAudioDevicePropertyTransportType:
        outDataSize = 4
        outData.storeBytes(of: kAudioDeviceTransportTypeVirtual, as: UInt32.self)

    case kAudioDevicePropertyRelatedDevices:
        outDataSize = 4
        outData.storeBytes(of: kObjectID_Device, as: AudioObjectID.self)

    case kAudioDevicePropertyClockDomain:
        outDataSize = 4
        outData.storeBytes(of: UInt32(0), as: UInt32.self)

    case kAudioDevicePropertyDeviceIsAlive:
        outDataSize = 4
        outData.storeBytes(of: UInt32(1), as: UInt32.self)

    case kAudioDevicePropertyDeviceIsRunning:
        outDataSize = 4
        outData.storeBytes(of: state.isIORunning ? UInt32(1) : UInt32(0), as: UInt32.self)

    case kAudioDevicePropertyDeviceCanBeDefaultDevice,
         kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        outDataSize = 4
        outData.storeBytes(of: UInt32(1), as: UInt32.self)

    case kAudioDevicePropertyLatency:
        outDataSize = 4
        outData.storeBytes(of: UInt32(0), as: UInt32.self)

    case kAudioDevicePropertySafetyOffset:
        outDataSize = 4
        outData.storeBytes(of: UInt32(0), as: UInt32.self)

    case kAudioDevicePropertyZeroTimeStampPeriod:
        outDataSize = 4
        outData.storeBytes(of: UInt32(512), as: UInt32.self)

    case kAudioDevicePropertyBufferFrameSize:
        outDataSize = 4
        outData.storeBytes(of: DriverState.shared.bufferFrameSize, as: UInt32.self)

    case kAudioDevicePropertyBufferFrameSizeRange:
        outDataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        outData.storeBytes(of: AudioValueRange(mMinimum: 64, mMaximum: 4096), as: AudioValueRange.self)

    case kAudioDevicePropertyNominalSampleRate:
        outDataSize = 8
        outData.storeBytes(of: state.sampleRate, as: Float64.self)

    case kAudioDevicePropertyAvailableNominalSampleRates:
        let count = kSupportedSampleRates.count
        outDataSize = UInt32(count * MemoryLayout<AudioValueRange>.size)
        let ptr = outData.bindMemory(to: AudioValueRange.self, capacity: count)
        for (i, rate) in kSupportedSampleRates.enumerated() {
            ptr[i] = AudioValueRange(mMinimum: rate, mMaximum: rate)
        }

    case kAudioObjectPropertyOwnedObjects:
        outDataSize = UInt32(4 * MemoryLayout<AudioObjectID>.size)
        let ptr = outData.bindMemory(to: AudioObjectID.self, capacity: 4)
        ptr[0] = kObjectID_Stream_Output
        ptr[1] = kObjectID_Stream_Input
        ptr[2] = kObjectID_Volume_Output
        ptr[3] = kObjectID_Mute_Output

    case kAudioDevicePropertyStreams:
        // Return appropriate stream(s) for scope
        switch scope {
        case kAudioObjectPropertyScopeInput:
            outDataSize = UInt32(MemoryLayout<AudioObjectID>.size)
            outData.storeBytes(of: kObjectID_Stream_Input, as: AudioObjectID.self)
        case kAudioObjectPropertyScopeOutput:
            outDataSize = UInt32(MemoryLayout<AudioObjectID>.size)
            outData.storeBytes(of: kObjectID_Stream_Output, as: AudioObjectID.self)
        default: // global — return both streams
            outDataSize = UInt32(2 * MemoryLayout<AudioObjectID>.size)
            let ptr = outData.bindMemory(to: AudioObjectID.self, capacity: 2)
            ptr[0] = kObjectID_Stream_Output
            ptr[1] = kObjectID_Stream_Input
        }

    case kAudioObjectPropertyControlList:
        outDataSize = UInt32(2 * MemoryLayout<AudioObjectID>.size)
        let ptr = outData.bindMemory(to: AudioObjectID.self, capacity: 2)
        ptr[0] = kObjectID_Volume_Output
        ptr[1] = kObjectID_Mute_Output

    case kAudioDevicePropertyIsHidden:
        outDataSize = 4
        // Hidden when not shown — this is the eqMac-style visibility mechanism
        outData.storeBytes(of: state.isShown ? UInt32(0) : UInt32(1), as: UInt32.self)

    // --- Custom properties ---

    case kCustomProp_Identity:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        outData.storeBytes(of: Unmanaged.passRetained(kDriverBundleID as CFString).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kCustomProp_Name:
        outDataSize = UInt32(MemoryLayout<CFString>.size)
        outData.storeBytes(of: Unmanaged.passRetained(state.deviceName as CFString).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kCustomProp_Shown:
        outDataSize = UInt32(MemoryLayout<CFBoolean>.size)
        let cfBool: CFBoolean = state.isShown ? kCFBooleanTrue : kCFBooleanFalse
        outData.storeBytes(of: Unmanaged.passRetained(cfBool).toOpaque(),
                           as: UnsafeRawPointer.self)

    case kAudioObjectPropertyCustomPropertyInfoList:
        let count = customPropertyInfoList.count
        outDataSize = UInt32(count * MemoryLayout<AudioServerPlugInCustomPropertyInfo>.size)
        let ptr = outData.bindMemory(to: AudioServerPlugInCustomPropertyInfo.self, capacity: count)
        for (i, info) in customPropertyInfoList.enumerated() {
            ptr[i] = info
        }

    default:
        return kAudioHardwareUnknownPropertyError
    }

    return noErr
}

// MARK: - Private: Stream properties

private func streamHasProperty(selector: AudioObjectPropertySelector) -> Bool {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyOwnedObjects,
         kAudioStreamPropertyIsActive,
         kAudioStreamPropertyDirection,
         kAudioStreamPropertyTerminalType,
         kAudioStreamPropertyStartingChannel,
         kAudioStreamPropertyLatency,
         kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat,
         kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats:
        return true
    default:
        return false
    }
}

private func streamGetPropertyDataSize(selector: AudioObjectPropertySelector) -> UInt32 {
    switch selector {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
         kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel,
         kAudioStreamPropertyLatency:
        return UInt32(MemoryLayout<UInt32>.size)
    case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
        return UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    case kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats:
        return UInt32(kSupportedSampleRates.count * MemoryLayout<AudioStreamRangedDescription>.size)
    case kAudioObjectPropertyOwnedObjects:
        return 0
    default:
        return 0
    }
}

private func streamGetPropertyData(
    objectID:    AudioObjectID,
    selector:    AudioObjectPropertySelector,
    scope:       AudioObjectPropertyScope,
    outDataSize: inout UInt32,
    outData:     UnsafeMutableRawPointer
) -> OSStatus {

    let isInput = (objectID == kObjectID_Stream_Input)

    switch selector {
    case kAudioObjectPropertyBaseClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioObjectClassID, as: AudioClassID.self)

    case kAudioObjectPropertyClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioStreamClassID, as: AudioClassID.self)

    case kAudioObjectPropertyOwner:
        outDataSize = 4
        outData.storeBytes(of: kObjectID_Device, as: AudioObjectID.self)

    case kAudioObjectPropertyOwnedObjects:
        outDataSize = 0

    case kAudioStreamPropertyIsActive:
        outDataSize = 4
        outData.storeBytes(of: UInt32(1), as: UInt32.self)

    case kAudioStreamPropertyDirection:
        outDataSize = 4
        // 0 = output, 1 = input
        outData.storeBytes(of: isInput ? UInt32(1) : UInt32(0), as: UInt32.self)

    case kAudioStreamPropertyTerminalType:
        outDataSize = 4
        outData.storeBytes(of: kAudioStreamTerminalTypeLine, as: UInt32.self)

    case kAudioStreamPropertyStartingChannel:
        outDataSize = 4
        outData.storeBytes(of: UInt32(1), as: UInt32.self)

    case kAudioStreamPropertyLatency:
        outDataSize = 4
        outData.storeBytes(of: UInt32(0), as: UInt32.self)

    case kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat:
        outDataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = makeASBD(sampleRate: DriverState.shared.sampleRate)
        outData.storeBytes(of: asbd, as: AudioStreamBasicDescription.self)

    case kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats:
        let count = kSupportedSampleRates.count
        outDataSize = UInt32(count * MemoryLayout<AudioStreamRangedDescription>.size)
        let ptr = outData.bindMemory(to: AudioStreamRangedDescription.self, capacity: count)
        for (i, rate) in kSupportedSampleRates.enumerated() {
            ptr[i] = AudioStreamRangedDescription(
                mFormat: makeASBD(sampleRate: rate),
                mSampleRateRange: AudioValueRange(mMinimum: rate, mMaximum: rate)
            )
        }

    default:
        return kAudioHardwareUnknownPropertyError
    }

    return noErr
}

// MARK: - Volume control properties

private func volumeControlHasProperty(selector: AudioObjectPropertySelector) -> Bool {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyOwnedObjects,
         kAudioLevelControlPropertyScalarValue,
         kAudioLevelControlPropertyDecibelValue,
         kAudioLevelControlPropertyDecibelRange,
         kAudioControlPropertyScope,
         kAudioControlPropertyElement:
        return true
    default:
        return false
    }
}

private func volumeControlGetPropertyDataSize(selector: AudioObjectPropertySelector) -> UInt32 {
    switch selector {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner, kAudioControlPropertyScope,
         kAudioControlPropertyElement:
        return UInt32(MemoryLayout<UInt32>.size)
    case kAudioLevelControlPropertyScalarValue,
         kAudioLevelControlPropertyDecibelValue:
        return UInt32(MemoryLayout<Float32>.size)
    case kAudioLevelControlPropertyDecibelRange:
        return UInt32(MemoryLayout<AudioValueRange>.size)
    case kAudioObjectPropertyOwnedObjects:
        return 0
    default:
        return 0
    }
}

private func volumeControlGetPropertyData(
    selector:    AudioObjectPropertySelector,
    outDataSize: inout UInt32,
    outData:     UnsafeMutableRawPointer
) -> OSStatus {
    let state = DriverState.shared

    switch selector {
    case kAudioObjectPropertyBaseClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioLevelControlClassID, as: AudioClassID.self)

    case kAudioObjectPropertyClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioVolumeControlClassID, as: AudioClassID.self)

    case kAudioObjectPropertyOwner:
        outDataSize = 4
        outData.storeBytes(of: kObjectID_Device, as: AudioObjectID.self)

    case kAudioControlPropertyScope:
        outDataSize = 4
        outData.storeBytes(of: kAudioObjectPropertyScopeOutput, as: UInt32.self)

    case kAudioControlPropertyElement:
        outDataSize = 4
        outData.storeBytes(of: kAudioObjectPropertyElementMain, as: UInt32.self)

    case kAudioObjectPropertyOwnedObjects:
        outDataSize = 0

    case kAudioLevelControlPropertyScalarValue:
        outDataSize = UInt32(MemoryLayout<Float32>.size)
        outData.storeBytes(of: state.volumeScalar, as: Float32.self)

    case kAudioLevelControlPropertyDecibelValue:
        outDataSize = UInt32(MemoryLayout<Float32>.size)
        outData.storeBytes(of: state.volumeDB, as: Float32.self)

    case kAudioLevelControlPropertyDecibelRange:
        outDataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        outData.storeBytes(of: AudioValueRange(
            mMinimum: Float64(DriverState.volumeMinDB),
            mMaximum: Float64(DriverState.volumeMaxDB)
        ), as: AudioValueRange.self)

    default:
        return kAudioHardwareUnknownPropertyError
    }

    return noErr
}

// MARK: - Mute control properties

private func muteControlHasProperty(selector: AudioObjectPropertySelector) -> Bool {
    switch selector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyOwnedObjects,
         kAudioBooleanControlPropertyValue,
         kAudioControlPropertyScope,
         kAudioControlPropertyElement:
        return true
    default:
        return false
    }
}

private func muteControlGetPropertyDataSize(selector: AudioObjectPropertySelector) -> UInt32 {
    switch selector {
    case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner, kAudioControlPropertyScope,
         kAudioControlPropertyElement, kAudioBooleanControlPropertyValue:
        return UInt32(MemoryLayout<UInt32>.size)
    case kAudioObjectPropertyOwnedObjects:
        return 0
    default:
        return 0
    }
}

private func muteControlGetPropertyData(
    selector:    AudioObjectPropertySelector,
    outDataSize: inout UInt32,
    outData:     UnsafeMutableRawPointer
) -> OSStatus {
    switch selector {
    case kAudioObjectPropertyBaseClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioBooleanControlClassID, as: AudioClassID.self)

    case kAudioObjectPropertyClass:
        outDataSize = 4
        outData.storeBytes(of: kAudioMuteControlClassID, as: AudioClassID.self)

    case kAudioObjectPropertyOwner:
        outDataSize = 4
        outData.storeBytes(of: kObjectID_Device, as: AudioObjectID.self)

    case kAudioControlPropertyScope:
        outDataSize = 4
        outData.storeBytes(of: kAudioObjectPropertyScopeOutput, as: UInt32.self)

    case kAudioControlPropertyElement:
        outDataSize = 4
        outData.storeBytes(of: kAudioObjectPropertyElementMain, as: UInt32.self)

    case kAudioObjectPropertyOwnedObjects:
        outDataSize = 0

    case kAudioBooleanControlPropertyValue:
        outDataSize = 4
        outData.storeBytes(of: DriverState.shared.isMuted ? UInt32(1) : UInt32(0), as: UInt32.self)

    default:
        return kAudioHardwareUnknownPropertyError
    }

    return noErr
}

// MARK: - ASBD factory

private func makeASBD(sampleRate: Float64) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate:       sampleRate,
        mFormatID:         kAudioFormatLinearPCM,
        mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket:   kBytesPerPacket,
        mFramesPerPacket:  kFramesPerPacket,
        mBytesPerFrame:    kBytesPerFrame,
        mChannelsPerFrame: kChannelCount,
        mBitsPerChannel:   kBitsPerChannel,
        mReserved:         0
    )
}
