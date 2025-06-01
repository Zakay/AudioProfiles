import Foundation
import CoreAudio

/// Handles setting audio devices as default system input/output
class AudioDeviceControlService {
    
    /// Set device as default output
    /// - Parameter device: AudioDevice to set as default output
    /// - Returns: Success status
    func setDefaultOutputDevice(_ device: AudioDevice) -> Bool {
        return setDefaultDevice(device, isInput: false)
    }
    
    /// Set device as default input
    /// - Parameter device: AudioDevice to set as default input  
    /// - Returns: Success status
    func setDefaultInputDevice(_ device: AudioDevice) -> Bool {
        return setDefaultDevice(device, isInput: true)
    }
    
    /// Get currently set default output device
    /// - Returns: Default output device or nil if none set
    func getDefaultOutputDevice() -> AudioDevice? {
        return getDefaultDevice(isInput: false)
    }
    
    /// Get currently set default input device
    /// - Returns: Default input device or nil if none set  
    func getDefaultInputDevice() -> AudioDevice? {
        return getDefaultDevice(isInput: true)
    }
    
    // MARK: - Private Methods
    
    /// Set a device as the system default
    /// - Parameters:
    ///   - device: AudioDevice to set as default
    ///   - isInput: Whether this is for input (true) or output (false)
    /// - Returns: Success status
    private func setDefaultDevice(_ device: AudioDevice, isInput: Bool) -> Bool {
        // First, get the AudioObjectID for this device UID
        guard let audioObjectID = getAudioObjectID(for: device.id) else {
            AppLogger.error("Failed to find AudioObjectID for device: \(device.name) (UID: \(device.id))")
            return false
        }
        
        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let deviceType = isInput ? "input" : "output"
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioObjectID = audioObjectID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        
        if status == noErr {
            AppLogger.info("✅ Set default \(deviceType) device to: \(device.name)")
            return true
        } else {
            AppLogger.error("❌ Failed to set default \(deviceType) device: \(status)")
            return false
        }
    }
    
    /// Get the current default device
    /// - Parameter isInput: Whether to get input (true) or output (false) device
    /// - Returns: Currently set default device
    private func getDefaultDevice(isInput: Bool) -> AudioDevice? {
        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        guard status == noErr else {
            AppLogger.error("Failed to get default device: \(status)")
            return nil
        }
        
        return AudioDeviceFactory.createAudioDevice(from: deviceID)
    }
    
    /// Convert device UID back to AudioObjectID for Core Audio operations
    /// - Parameter deviceUID: Device's unique identifier
    /// - Returns: AudioObjectID if found, nil otherwise
    private func getAudioObjectID(for deviceUID: String) -> AudioObjectID? {
        // If the UID looks like a number, it might be an old-style AudioObjectID
        if let objectID = UInt32(deviceUID) {
            // Verify this device still exists
            if deviceExists(objectID) {
                return objectID
            }
        }
        
        // Search through all current devices to find one with matching UID
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
        
        guard status == noErr else { return nil }
        
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
        
        guard status == noErr else { return nil }
        
        // Check each device to see if its UID matches
        for deviceID in deviceIDs {
            if let currentUID = getDeviceUID(deviceID), currentUID == deviceUID {
                return deviceID
            }
        }
        
        return nil
    }
    
    /// Get device UID for an AudioObjectID
    /// - Parameter deviceID: Core Audio device ID
    /// - Returns: Device UID string if available
    private func getDeviceUID(_ deviceID: AudioObjectID) -> String? {
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

        return cfUID as String?
    }
    
    /// Check if a device with given AudioObjectID still exists
    /// - Parameter deviceID: AudioObjectID to check
    /// - Returns: True if device exists
    private func deviceExists(_ deviceID: AudioObjectID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyOwnedObjects,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )
        
        return status == noErr
    }
} 