import Foundation
import CoreAudio
import AudioToolbox

/// The user-visible output state owned by a Core Audio endpoint.
struct AudioOutputState: Equatable {
    let volume: Float32?
    let isMuted: Bool?
}

/// Reads, writes, and verifies volume/mute state across physical and virtual outputs.
/// A nil field means that endpoint has no software control for that property.
final class AudioOutputStateService {
    private let verificationAttempts = 20
    private let verificationDelay: TimeInterval = 0.01
    private let volumeTolerance: Float32 = 0.02

    func resolveDeviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioPlugInPropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID: CFString = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func readState(from deviceID: AudioObjectID) -> AudioOutputState {
        AudioOutputState(
            volume: readVolume(from: deviceID),
            isMuted: readMute(from: deviceID)
        )
    }

    /// Reads a hardware snapshot and distinguishes a genuinely unsupported
    /// control from a property that exists but temporarily failed to read.
    func readReliableHardwareState(from deviceID: AudioObjectID) -> AudioOutputState? {
        let state = readState(from: deviceID)

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let exposesVolume = AudioObjectHasProperty(deviceID, &volumeAddress)
        let exposesMute = !readableElements(for: kAudioDevicePropertyMute, on: deviceID).isEmpty

        guard (!exposesVolume || state.volume != nil),
              (!exposesMute || state.isMuted != nil) else {
            AppLogger.error("Could not reliably snapshot hardware volume/mute state")
            return nil
        }
        return state
    }

    /// The virtual driver always exposes both controls. Treat a missing read as
    /// an I/O failure, not as an unsupported property, so teardown cannot
    /// silently discard the user's state.
    func readRequiredVirtualState(from deviceID: AudioObjectID) -> AudioOutputState? {
        let state = readState(from: deviceID)
        guard state.volume != nil, state.isMuted != nil else {
            AppLogger.error("Could not read required volume/mute state from virtual output")
            return nil
        }
        return state
    }

    /// State to apply to the virtual driver. A hardware endpoint without a
    /// software control is physically fixed at full gain and unmuted.
    func virtualStateRepresentingHardware(_ hardware: AudioOutputState) -> AudioOutputState {
        return AudioOutputState(
            volume: hardware.volume ?? 1.0,
            isMuted: hardware.isMuted ?? false
        )
    }

    /// Returns full-gain/unmuted for exactly the controls present in the saved
    /// hardware snapshot. This avoids a second, transient read deciding that a
    /// real control should be skipped.
    func fullState(matching hardware: AudioOutputState) -> AudioOutputState {
        return AudioOutputState(
            volume: hardware.volume == nil ? nil : 1.0,
            isMuted: hardware.isMuted == nil ? nil : false
        )
    }

    /// Drops fields that the destination genuinely does not expose. This is
    /// needed for fixed-volume HDMI/digital outputs: their direct-output state
    /// cannot accept a software volume or mute value.
    func state(_ source: AudioOutputState, supportedBy deviceID: AudioObjectID) -> AudioOutputState {
        let destination = readState(from: deviceID)
        return AudioOutputState(
            volume: destination.volume == nil ? nil : source.volume,
            isMuted: destination.isMuted == nil ? nil : source.isMuted
        )
    }

    @discardableResult
    func applyAndVerify(
        _ state: AudioOutputState,
        to deviceID: AudioObjectID,
        context: String
    ) -> Bool {
        let volumeOK = state.volume.map { setAndVerifyVolume($0, on: deviceID) } ?? true
        let muteOK = state.isMuted.map { setAndVerifyMute($0, on: deviceID) } ?? true

        if !volumeOK || !muteOK {
            AppLogger.error(
                "Audio state handoff failed while \(context) " +
                "(volume=\(state.volume.map { String(format: "%.0f%%", $0 * 100) } ?? "unsupported"), " +
                "mute=\(state.isMuted.map { String(describing: $0) } ?? "unsupported"))"
            )
        }
        return volumeOK && muteOK
    }

    // MARK: - Volume

    private func readVolume(from deviceID: AudioObjectID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        for attempt in 0..<verificationAttempts {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return min(max(volume, 0), 1)
            }
            waitBeforeRetry(attempt)
        }
        return nil
    }

    private func setAndVerifyVolume(_ requested: Float32, on deviceID: AudioObjectID) -> Bool {
        let volume = min(max(requested, 0), 1)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard isSettable(deviceID, address: &address) else { return false }

        for attempt in 0..<verificationAttempts {
            var value = volume
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            if status == noErr,
               let actual = readVolume(from: deviceID),
               abs(actual - volume) <= volumeTolerance {
                return true
            }
            waitBeforeRetry(attempt)
        }
        return false
    }

    // MARK: - Mute

    private func readMute(from deviceID: AudioObjectID) -> Bool? {
        let elements = readableElements(for: kAudioDevicePropertyMute, on: deviceID)
        guard !elements.isEmpty else { return nil }

        for attempt in 0..<verificationAttempts {
            let values = elements.compactMap { element -> UInt32? in
                var address = propertyAddress(kAudioDevicePropertyMute, element: element)
                var value: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
                    ? value
                    : nil
            }
            if values.count == elements.count {
                return values.allSatisfy { $0 != 0 }
            }
            waitBeforeRetry(attempt)
        }
        return nil
    }

    private func setAndVerifyMute(_ isMuted: Bool, on deviceID: AudioObjectID) -> Bool {
        let elements = writableElements(for: kAudioDevicePropertyMute, on: deviceID)
        guard !elements.isEmpty else { return false }

        for attempt in 0..<verificationAttempts {
            var allWritesSucceeded = true
            for element in elements {
                var address = propertyAddress(kAudioDevicePropertyMute, element: element)
                var value: UInt32 = isMuted ? 1 : 0
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<UInt32>.size),
                    &value
                )
                allWritesSucceeded = allWritesSucceeded && status == noErr
            }
            if allWritesSucceeded, readMute(from: deviceID) == isMuted {
                return true
            }
            waitBeforeRetry(attempt)
        }
        return false
    }

    // MARK: - Core Audio helpers

    private func readableElements(
        for selector: AudioObjectPropertySelector,
        on deviceID: AudioObjectID
    ) -> [AudioObjectPropertyElement] {
        let main = kAudioObjectPropertyElementMain
        var mainAddress = propertyAddress(selector, element: main)
        if AudioObjectHasProperty(deviceID, &mainAddress) { return [main] }

        return (1...32).compactMap { rawElement in
            let element = AudioObjectPropertyElement(rawElement)
            var address = propertyAddress(selector, element: element)
            return AudioObjectHasProperty(deviceID, &address) ? element : nil
        }
    }

    private func writableElements(
        for selector: AudioObjectPropertySelector,
        on deviceID: AudioObjectID
    ) -> [AudioObjectPropertyElement] {
        let main = kAudioObjectPropertyElementMain
        var mainAddress = propertyAddress(selector, element: main)
        if AudioObjectHasProperty(deviceID, &mainAddress),
           isSettable(deviceID, address: &mainAddress) {
            return [main]
        }

        return (1...32).compactMap { rawElement in
            let element = AudioObjectPropertyElement(rawElement)
            var address = propertyAddress(selector, element: element)
            guard AudioObjectHasProperty(deviceID, &address),
                  isSettable(deviceID, address: &address) else { return nil }
            return element
        }
    }

    private func isSettable(
        _ deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private func waitBeforeRetry(_ attempt: Int) {
        if attempt + 1 < verificationAttempts {
            Thread.sleep(forTimeInterval: verificationDelay)
        }
    }
}
