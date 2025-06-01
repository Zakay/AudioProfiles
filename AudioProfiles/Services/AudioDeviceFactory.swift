import Foundation
import CoreAudio

/// Responsible for creating AudioDevice instances from Core Audio system data
class AudioDeviceFactory {
    
    /// Get all currently connected audio devices
    /// - Parameter sorted: Whether to sort devices by name
    /// - Returns: Array of currently active AudioDevice instances
    static func getCurrentDevices(sorted: Bool = false) -> [AudioDevice] {
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )
        
        guard status == noErr else {
            AppLogger.error("Failed to get audio devices property size: \(status)")
            return []
        }
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        
        guard status == noErr else {
            AppLogger.error("Failed to get audio devices: \(status)")
            return []
        }
        
        let devices = deviceIDs.compactMap { createAudioDevice(from: $0) }
        return sorted ? devices.sorted { $0.name < $1.name } : devices
    }
    
    /// Create an AudioDevice from a Core Audio device ID
    /// - Parameter deviceID: Core Audio AudioObjectID
    /// - Returns: AudioDevice instance or nil if creation fails
    static func createAudioDevice(from deviceID: AudioObjectID) -> AudioDevice? {
        // ——— Get Persistent Device UID (Hardware Identifier) ———
        var cfUID: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        withUnsafeMutableBytes(of: &cfUID) { rawBuf in
            let rawPtr = rawBuf.baseAddress!
            AudioObjectGetPropertyData(
                deviceID,
                &uidAddr,
                0,
                nil,
                &uidSize,
                rawPtr
            )
        }

        // Use the device UID as our persistent identifier
        // Fall back to AudioObjectID if UID is not available (shouldn't happen but safety first)
        let deviceUID = (cfUID as String?) ?? "\(deviceID)"

        // ——— Name (safe CFString fetch) ———
        var cfName: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Provide raw pointer to cfName's storage
        withUnsafeMutableBytes(of: &cfName) { rawBuf in
            let rawPtr = rawBuf.baseAddress!
            AudioObjectGetPropertyData(
                deviceID,
                &nameAddr,
                0,
                nil,
                &nameSize,
                rawPtr
            )
        }

        let name = (cfName as String?) ?? "Unknown Device"
        
        // ——— Transport Type ———
        let transportType = getTransportType(for: deviceID)

        // ——— Stream Check ———
        let isInput  = hasStreams(deviceID, kAudioObjectPropertyScopeInput)
        let isOutput = hasStreams(deviceID, kAudioObjectPropertyScopeOutput)

        return AudioDevice(
            id: deviceUID,  // Now using persistent hardware UID instead of temporary AudioObjectID
            name: name,
            transportType: transportType,
            isInput: isInput,
            isOutput: isOutput
        )
    }
    
    /// Get transport type for a device
    private static func getTransportType(for deviceID: AudioObjectID) -> String {
        var transport: UInt32 = 0
        var transSize = UInt32(MemoryLayout<UInt32>.size)
        var transAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            deviceID,
            &transAddr,
            0,
            nil,
            &transSize,
            &transport
        )
        
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:    return "Built-In"
        case kAudioDeviceTransportTypeUSB:        return "USB"
        case kAudioDeviceTransportTypeBluetooth:  return "Bluetooth"
        default:                                  return "Other"
        }
    }
    
    /// Check if device has streams for given scope
    private static func hasStreams(_ deviceID: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let stat = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        return stat == noErr && size > 0
    }
} 
