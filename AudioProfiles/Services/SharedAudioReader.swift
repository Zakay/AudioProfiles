// SharedAudioReader.swift — AudioProfiles
//
// Reads audio from the driver's shared memory region without using any
// Core Audio input API — therefore no TCC microphone permission needed.
//
// The driver (running inside coreaudiod) creates and writes to the file
// at kSharedBufferPath. This reader opens it read-only via mmap and
// consumes audio data lock-free (single consumer).
//
// Used by EQEngineService's render callback to feed the NBandEQ unit.

import Foundation
import CoreAudio
import Darwin

// MARK: - Shared memory constants (must match driver's SharedAudioBuffer.swift)

private let kShmMagic: UInt32 = 0x41504551          // "APEQ"
private let kShmVersion: UInt32 = 1
private let kShmPath = "/tmp/com.audioprofiles.eq-audio"

/// Mirror of the driver's SharedAudioHeader — layout must be identical.
private struct ShmHeader {
    var magic: UInt32
    var version: UInt32
    var sampleRate: UInt32
    var channels: UInt32
    var frameCapacity: UInt32
    var reserved1: UInt32
    var writeIndex: UInt64
    var reserved2: UInt64
    var reserved3: UInt64
    var reserved4: UInt64
    var reserved5: UInt64
}

// MARK: - SharedAudioReader

/// Read-only consumer of the driver's shared memory audio buffer.
/// Designed to be called from a real-time audio render callback.
final class SharedAudioReader {

    private let fd: Int32
    private let totalSize: Int
    private let mappedRegion: UnsafeMutableRawPointer  // mmap returns mutable even for PROT_READ

    /// Typed pointers into the mapped region
    private let header: UnsafePointer<ShmHeader>
    private let samples: UnsafePointer<Float32>

    /// Local read position — only this reader advances it (not in shared memory)
    private var readIndex: UInt64 = 0

    /// Cached layout info from header
    let channels: Int
    let frameCapacity: Int

    // MARK: - Init / Deinit

    /// Open the shared memory file and map it read-only.
    /// Returns nil if the file doesn't exist, can't be mapped, or has bad magic/version.
    init?() {
        fd = open(kShmPath, O_RDONLY)
        guard fd >= 0 else {
            AppLogger.error("SharedAudioReader: can't open \(kShmPath): errno=\(errno)")
            return nil
        }

        // Get file size
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return nil
        }
        totalSize = Int(st.st_size)

        let headerSize = MemoryLayout<ShmHeader>.size
        guard totalSize > headerSize else {
            AppLogger.error("SharedAudioReader: file too small (\(totalSize) bytes)")
            close(fd)
            return nil
        }

        // Map read-only
        guard let region = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0),
              region != MAP_FAILED else {
            AppLogger.error("SharedAudioReader: mmap failed: errno=\(errno)")
            close(fd)
            return nil
        }

        mappedRegion = region
        header = UnsafeRawPointer(region).bindMemory(to: ShmHeader.self, capacity: 1)
        let sampleRegion = UnsafeRawPointer(region).advanced(by: headerSize)

        // Validate header
        guard header.pointee.magic == kShmMagic else {
            AppLogger.error("SharedAudioReader: bad magic \(header.pointee.magic)")
            munmap(region, totalSize)
            close(fd)
            return nil
        }
        guard header.pointee.version == kShmVersion else {
            AppLogger.error("SharedAudioReader: version mismatch \(header.pointee.version)")
            munmap(region, totalSize)
            close(fd)
            return nil
        }

        channels = Int(header.pointee.channels)
        frameCapacity = Int(header.pointee.frameCapacity)

        let expectedDataSize = frameCapacity * channels * MemoryLayout<Float32>.size
        guard totalSize >= headerSize + expectedDataSize else {
            AppLogger.error("SharedAudioReader: data region too small")
            munmap(region, totalSize)
            close(fd)
            return nil
        }

        samples = sampleRegion.bindMemory(to: Float32.self,
                                           capacity: frameCapacity * channels)

        // Start reading from the current write position (skip any stale data)
        OSMemoryBarrier()
        readIndex = header.pointee.writeIndex

        AppLogger.info("SharedAudioReader: mapped \(kShmPath), \(frameCapacity) frames, \(channels) ch")
    }

    deinit {
        munmap(mappedRegion, totalSize)
        close(fd)
    }

    // MARK: - Read (called from real-time render callback)

    /// Read `frameCount` frames from the shared buffer into a non-interleaved
    /// AudioBufferList (matching the EQ unit's expected format).
    ///
    /// The shared buffer stores interleaved stereo Float32 (matching the driver
    /// format). This method deinterleaves into separate per-channel buffers.
    ///
    /// Returns the number of frames actually read (may be less than requested
    /// if the driver hasn't written enough yet). Unread positions are zeroed.
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablBufs = UnsafeMutableAudioBufferListPointer(abl)
        let requestedFrames = Int(frameCount)

        // Load the driver's write index with an acquire barrier
        let writeIdx = header.pointee.writeIndex
        OSMemoryBarrier()

        // How many frames are available?
        // If writeIdx < readIndex, the driver reset (IO stopped/restarted) — resync.
        var available: Int
        if writeIdx >= readIndex {
            available = Int(writeIdx - readIndex)
        } else {
            readIndex = writeIdx
            available = 0
        }

        // If we've fallen behind by more than the ring capacity, resync
        // (the oldest data has been overwritten)
        if available > frameCapacity {
            readIndex = writeIdx - UInt64(frameCapacity)
            available = frameCapacity
        }

        // Don't read more than what's available or what's in the ring
        let framesToRead = min(min(available, requestedFrames), frameCapacity)

        if framesToRead > 0 {
            let cap = frameCapacity * channels
            let startOffset = Int(readIndex % UInt64(frameCapacity)) * channels

            // Read interleaved data and deinterleave into the ABL
            for ch in 0..<min(channels, ablBufs.count) {
                guard let dst = ablBufs[ch].mData?.assumingMemoryBound(to: Float32.self) else { continue }

                for f in 0..<framesToRead {
                    let srcIdx = (startOffset + f * channels + ch) % cap
                    dst[f] = samples[srcIdx]
                }

                // Zero-fill remainder
                if framesToRead < requestedFrames {
                    memset(dst.advanced(by: framesToRead), 0,
                           (requestedFrames - framesToRead) * MemoryLayout<Float32>.size)
                }
                ablBufs[ch].mDataByteSize = frameCount * 4
            }

            readIndex &+= UInt64(framesToRead)
        } else {
            // No data available — output silence
            for ch in 0..<ablBufs.count {
                guard let dst = ablBufs[ch].mData else { continue }
                memset(dst, 0, Int(frameCount) * MemoryLayout<Float32>.size)
                ablBufs[ch].mDataByteSize = frameCount * 4
            }
        }
    }

    // MARK: - Diagnostics

    /// Current sample rate reported by the driver
    var sampleRate: UInt32 {
        header.pointee.sampleRate
    }

    /// True if the shared memory region is still valid (file hasn't been removed)
    var isValid: Bool {
        header.pointee.magic == kShmMagic
    }

    /// Sync read position to current write position (skip stale data after pause)
    func resync() {
        OSMemoryBarrier()
        readIndex = header.pointee.writeIndex
    }
}
