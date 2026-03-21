// DriverState.swift — AudioProfilesDriver
//
// Single source of truth for all mutable state inside the driver.
// Everything is accessed from coreaudiod's threads, so all mutations
// go through os_unfair_lock where needed, or are done on the main
// driver dispatch queue (gDriverQueue in DriverMain).

import CoreAudio
import Foundation

// MARK: - DriverState

/// Global singleton that holds the driver's runtime state.
/// Created during Initialize() and lives for the process lifetime.
final class DriverState: @unchecked Sendable {

    static let shared = DriverState()

    // MARK: HAL host reference (set during Initialize)

    /// The AudioServerPlugInHostInterface pointer given to us by coreaudiod.
    /// We call host.PropertiesChanged() through this to notify the HAL of state changes.
    var host: AudioServerPlugInHostRef?

    // MARK: Device visibility

    /// Controls whether the virtual device appears in macOS Sound settings.
    /// The companion app sets this via the kCustomProp_Shown custom property.
    var isShown: Bool = false {
        didSet {
            guard oldValue != isShown else { return }
            notifyPropertiesChanged(
                objectID: kObjectID_Device,
                selectors: [kAudioDevicePropertyIsHidden,
                            kAudioObjectPropertyOwnedObjects]
            )
            // Also notify the plugin-level device list
            notifyPropertiesChanged(
                objectID: kObjectID_Plugin,
                selectors: [kAudioObjectPropertyOwnedObjects,
                            kAudioPlugInPropertyDeviceList]
            )
        }
    }

    // MARK: Device name

    /// Display name shown in System Settings > Sound.
    /// The companion app sets this via the kCustomProp_Name custom property.
    var deviceName: String = kDeviceDefaultName as String {
        didSet {
            guard oldValue != deviceName else { return }
            notifyPropertiesChanged(
                objectID: kObjectID_Device,
                selectors: [kAudioObjectPropertyName]
            )
        }
    }

    // MARK: Buffer frame size

    var bufferFrameSize: UInt32 = 512 {
        didSet {
            guard oldValue != bufferFrameSize else { return }
            notifyPropertiesChanged(
                objectID: kObjectID_Device,
                selectors: [kAudioDevicePropertyBufferFrameSize]
            )
        }
    }

    // MARK: Sample rate

    var sampleRate: Float64 = kSampleRate {
        didSet {
            guard oldValue != sampleRate else { return }
            sharedBuffer?.updateSampleRate(sampleRate)
            notifyPropertiesChanged(
                objectID: kObjectID_Device,
                selectors: [kAudioDevicePropertyNominalSampleRate,
                            kAudioDevicePropertyAvailableNominalSampleRates]
            )
        }
    }

    // MARK: Volume / Mute

    /// Output volume as a scalar (0.0 … 1.0). macOS volume keys write here.
    var volumeScalar: Float32 = 1.0 {
        didSet {
            guard oldValue != volumeScalar else { return }
            notifyPropertiesChanged(
                objectID: kObjectID_Volume_Output,
                selectors: [kAudioLevelControlPropertyScalarValue,
                            kAudioLevelControlPropertyDecibelValue]
            )
        }
    }

    /// Output mute state.
    var isMuted: Bool = false {
        didSet {
            guard oldValue != isMuted else { return }
            notifyPropertiesChanged(
                objectID: kObjectID_Mute_Output,
                selectors: [kAudioBooleanControlPropertyValue]
            )
        }
    }

    /// dB range for the volume control
    static let volumeMinDB: Float32 = -96.0
    static let volumeMaxDB: Float32 = 0.0

    /// Convert scalar (0…1) to dB using a quadratic curve for natural feel
    var volumeDB: Float32 {
        get {
            if volumeScalar <= 0 { return Self.volumeMinDB }
            // Quadratic curve: dB = minDB + scalar² * (maxDB - minDB)
            return Self.volumeMinDB + (volumeScalar * volumeScalar) * (Self.volumeMaxDB - Self.volumeMinDB)
        }
        set {
            let clamped = min(max(newValue, Self.volumeMinDB), Self.volumeMaxDB)
            if clamped <= Self.volumeMinDB {
                volumeScalar = 0
            } else {
                // Inverse of quadratic: scalar = sqrt((dB - minDB) / (maxDB - minDB))
                let normalized = (clamped - Self.volumeMinDB) / (Self.volumeMaxDB - Self.volumeMinDB)
                volumeScalar = sqrtf(normalized)
            }
        }
    }

    /// The gain factor applied in the IO path — accounts for mute
    var ioGain: Float32 {
        isMuted ? 0.0 : volumeScalar
    }

    // MARK: IO state

    /// Number of clients currently doing IO (StartIO increments, StopIO decrements).
    private(set) var ioClientCount: Int = 0
    private var ioLock = os_unfair_lock()

    func startIO() {
        os_unfair_lock_lock(&ioLock)
        ioClientCount += 1
        if ioClientCount == 1 {
            // First client — anchor the timing
            anchorHostTime   = mach_absolute_time()
            anchorSampleTime = 0
        }
        os_unfair_lock_unlock(&ioLock)
    }

    func stopIO() {
        os_unfair_lock_lock(&ioLock)
        ioClientCount = max(0, ioClientCount - 1)
        if ioClientCount == 0 {
            ringBuffer.reset()
            sharedBuffer?.reset()
        }
        os_unfair_lock_unlock(&ioLock)
    }

    var isIORunning: Bool {
        os_unfair_lock_lock(&ioLock)
        defer { os_unfair_lock_unlock(&ioLock) }
        return ioClientCount > 0
    }

    // MARK: Ring buffer

    /// The loopback ring buffer: WriteMix writes here, ReadInput reads here.
    let ringBuffer = RingBuffer(frameCount: kRingBufferFrameCount)

    // MARK: Shared memory buffer

    /// Cross-process shared memory buffer for TCC-free audio transfer.
    /// The companion app reads from this via mmap instead of using Core Audio
    /// input APIs (which would trigger TCC microphone permission).
    let sharedBuffer: SharedAudioBuffer? = SharedAudioBuffer()

    // MARK: Timing (GetZeroTimeStamp)

    /// mach_absolute_time() captured when first IO client started
    private(set) var anchorHostTime:   UInt64  = 0
    private(set) var anchorSampleTime: Float64 = 0

    // MARK: - Notify HAL of property changes

    /// Tell coreaudiod to re-query a set of properties on a given audio object.
    func notifyPropertiesChanged(objectID: AudioObjectID, selectors: [AudioObjectPropertySelector]) {
        guard let host = host else { return }
        var addresses = selectors.map { selector in
            AudioObjectPropertyAddress(
                mSelector: selector,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
        }
        addresses.withUnsafeBufferPointer { buf in
            _ = host.pointee.PropertiesChanged(
                host,
                objectID,
                UInt32(buf.count),
                buf.baseAddress!
            )
        }
    }
}
