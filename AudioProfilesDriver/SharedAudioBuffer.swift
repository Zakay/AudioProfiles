// SharedAudioBuffer.swift — AudioProfilesDriver
//
// Cross-process ring buffer: the driver writes audio in WriteMix,
// the companion app reads it directly via mmap (no Core Audio input API
// needed — hence no TCC microphone permission required).
//
// Uses a file in /tmp/ as the backing store. The driver creates and owns
// the file. The app opens it read-only.
//
// Lock-free single-producer (driver WriteMix) / single-consumer (app
// render callback) design. Only the writeIndex is shared; the consumer
// tracks its own read position locally.

import Darwin
import os.log

// MARK: - Shared memory layout

/// Header that lives at the start of the shared memory region.
/// Must match SharedAudioReader in the companion app EXACTLY.
/// Total: 64 bytes (one cache line).
struct SharedAudioHeader {
    var magic: UInt32           // 0x41504551 = "APEQ"
    var version: UInt32         // Protocol version (1)
    var sampleRate: UInt32      // Current sample rate (e.g. 48000)
    var channels: UInt32        // Channel count (2)
    var frameCapacity: UInt32   // Frames in the ring buffer
    var reserved1: UInt32       // Alignment padding
    var writeIndex: UInt64      // Monotonically increasing frame count (atomic on aligned access)
    var reserved2: UInt64       // Padding to 64 bytes
    var reserved3: UInt64
    var reserved4: UInt64
    var reserved5: UInt64
}

let kSharedAudioMagic: UInt32 = 0x41504551      // "APEQ"
let kSharedAudioVersion: UInt32 = 1
let kSharedBufferPath = "/tmp/com.audioprofiles.eq-audio"
let kSharedFrameCapacity = 4096                  // ~85ms at 48 kHz

// MARK: - SharedAudioBuffer (producer — driver side)

/// Created by the driver during Initialize. Writes audio data in the
/// WriteMix IO path. The companion app reads from the same file via mmap.
final class SharedAudioBuffer {

    private let fd: Int32
    private let totalSize: Int
    private let mappedRegion: UnsafeMutableRawPointer

    /// Typed pointers into the mapped region
    private let header: UnsafeMutablePointer<SharedAudioHeader>
    private let samples: UnsafeMutablePointer<Float32>

    init?() {
        let headerSize = MemoryLayout<SharedAudioHeader>.size       // 64
        let sampleCount = kSharedFrameCapacity * Int(kChannelCount)
        let dataSize = sampleCount * MemoryLayout<Float32>.size
        totalSize = headerSize + dataSize

        // Create the file (world-readable so the user's app process can read it)
        fd = open(kSharedBufferPath, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            os_log(.error, "SharedAudioBuffer: failed to create %{public}@: errno=%d",
                   kSharedBufferPath, errno)
            return nil
        }

        // Set file size
        guard ftruncate(fd, off_t(totalSize)) == 0 else {
            os_log(.error, "SharedAudioBuffer: ftruncate failed: errno=%d", errno)
            close(fd)
            return nil
        }

        // Map it
        guard let region = mmap(nil, totalSize, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, 0),
              region != MAP_FAILED else {
            os_log(.error, "SharedAudioBuffer: mmap failed: errno=%d", errno)
            close(fd)
            return nil
        }

        mappedRegion = region
        header = region.bindMemory(to: SharedAudioHeader.self, capacity: 1)
        samples = region.advanced(by: headerSize)
            .bindMemory(to: Float32.self, capacity: sampleCount)

        // Initialize header
        header.pointee = SharedAudioHeader(
            magic: kSharedAudioMagic,
            version: kSharedAudioVersion,
            sampleRate: UInt32(kSampleRate),
            channels: kChannelCount,
            frameCapacity: UInt32(kSharedFrameCapacity),
            reserved1: 0,
            writeIndex: 0,
            reserved2: 0, reserved3: 0, reserved4: 0, reserved5: 0
        )

        // Zero the audio data
        memset(samples, 0, dataSize)

        os_log(.info, "SharedAudioBuffer: created at %{public}@, %d bytes",
               kSharedBufferPath, totalSize)
    }

    deinit {
        munmap(mappedRegion, totalSize)
        close(fd)
        unlink(kSharedBufferPath)
        os_log(.info, "SharedAudioBuffer: cleaned up %{public}@", kSharedBufferPath)
    }

    // MARK: - Write (called from WriteMix — real-time IO thread)

    /// Write interleaved Float32 frames into the shared ring buffer.
    /// Lock-free: single producer only. Uses OSMemoryBarrier to ensure
    /// sample data is visible to the consumer before writeIndex advances.
    func write(from src: UnsafePointer<Float32>, frameCount: Int) {
        let ch = Int(kChannelCount)
        let sampleCount = frameCount * ch
        let capacity = kSharedFrameCapacity * ch

        // Current write position in the ring (derived from monotonic writeIndex)
        let currentIndex = header.pointee.writeIndex
        let writeOffset = Int(currentIndex % UInt64(kSharedFrameCapacity)) * ch

        // Copy with potential wrap-around
        let available = capacity - writeOffset
        if sampleCount <= available {
            memcpy(samples.advanced(by: writeOffset), src,
                   sampleCount * MemoryLayout<Float32>.size)
        } else {
            memcpy(samples.advanced(by: writeOffset), src,
                   available * MemoryLayout<Float32>.size)
            memcpy(samples, src.advanced(by: available),
                   (sampleCount - available) * MemoryLayout<Float32>.size)
        }

        // Ensure all sample writes are visible before we advance the index.
        // On ARM64 (Apple Silicon), this is a dmb ish; on x86-64, mfence.
        OSMemoryBarrier()

        // Advance the write index — aligned UInt64 store is naturally atomic
        // on both x86-64 (TSO) and ARM64 (aligned access).
        header.pointee.writeIndex = currentIndex &+ UInt64(frameCount)
    }

    // MARK: - Maintenance

    /// Update the sample rate in the header (called when device rate changes).
    func updateSampleRate(_ rate: Float64) {
        header.pointee.sampleRate = UInt32(rate)
    }

    /// Reset the buffer (called when IO stops).
    func reset() {
        header.pointee.writeIndex = 0
        let sampleCount = kSharedFrameCapacity * Int(kChannelCount)
        memset(samples, 0, sampleCount * MemoryLayout<Float32>.size)
    }
}
