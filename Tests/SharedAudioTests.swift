#!/usr/bin/env swift
//
// SharedAudioTests.swift
//
// Standalone test for the shared memory audio pipeline between the driver
// (SharedAudioBuffer) and the app (SharedAudioReader). Tests the cross-process
// mmap-based ring buffer without needing Core Audio or the actual driver.
//
// Run: swift Tests/SharedAudioTests.swift
//
// These tests validate:
//   1. File creation, mmap, and header initialization
//   2. Write → read round-trip with correct data
//   3. Wrap-around behavior when the ring buffer fills
//   4. Deinterleaving from interleaved (driver format) to non-interleaved (EQ format)
//   5. Under-run behavior (reader ahead of writer → silence)
//   6. Resync after gap
//   7. Cleanup on teardown

import Foundation
import Darwin
import CoreAudio
import AudioToolbox

// ============================================================================
// MARK: - Shared constants (mirrored from both sides)
// ============================================================================

let kTestShmPath = "/tmp/com.audioprofiles.eq-audio-test"
let kTestMagic: UInt32 = 0x41504551          // "APEQ"
let kTestVersion: UInt32 = 1
let kTestChannels: UInt32 = 2
let kTestFrameCapacity: Int = 4096
let kTestSampleRate: UInt32 = 48000

// ============================================================================
// MARK: - Shared memory header (identical to driver & app)
// ============================================================================

struct TestShmHeader {
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

// ============================================================================
// MARK: - Writer (simulates driver's SharedAudioBuffer)
// ============================================================================

final class TestWriter {
    let fd: Int32
    let totalSize: Int
    let mappedRegion: UnsafeMutableRawPointer
    let header: UnsafeMutablePointer<TestShmHeader>
    let samples: UnsafeMutablePointer<Float32>

    init?() {
        let headerSize = MemoryLayout<TestShmHeader>.size
        let sampleCount = kTestFrameCapacity * Int(kTestChannels)
        let dataSize = sampleCount * MemoryLayout<Float32>.size
        totalSize = headerSize + dataSize

        fd = open(kTestShmPath, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { print("FAIL: can't create \(kTestShmPath): errno=\(errno)"); return nil }
        guard ftruncate(fd, off_t(totalSize)) == 0 else { close(fd); return nil }
        guard let region = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              region != MAP_FAILED else { close(fd); return nil }

        mappedRegion = region
        header = region.bindMemory(to: TestShmHeader.self, capacity: 1)
        samples = region.advanced(by: headerSize)
            .bindMemory(to: Float32.self, capacity: sampleCount)

        header.pointee = TestShmHeader(
            magic: kTestMagic, version: kTestVersion,
            sampleRate: kTestSampleRate, channels: kTestChannels,
            frameCapacity: UInt32(kTestFrameCapacity), reserved1: 0,
            writeIndex: 0, reserved2: 0, reserved3: 0, reserved4: 0, reserved5: 0
        )
        memset(samples, 0, dataSize)
    }

    deinit {
        munmap(mappedRegion, totalSize)
        close(fd)
        unlink(kTestShmPath)
    }

    func write(from src: UnsafePointer<Float32>, frameCount: Int) {
        let ch = Int(kTestChannels)
        let sampleCount = frameCount * ch
        let capacity = kTestFrameCapacity * ch
        let currentIndex = header.pointee.writeIndex
        let writeOffset = Int(currentIndex % UInt64(kTestFrameCapacity)) * ch

        let available = capacity - writeOffset
        if sampleCount <= available {
            memcpy(samples.advanced(by: writeOffset), src, sampleCount * MemoryLayout<Float32>.size)
        } else {
            memcpy(samples.advanced(by: writeOffset), src, available * MemoryLayout<Float32>.size)
            memcpy(samples, src.advanced(by: available), (sampleCount - available) * MemoryLayout<Float32>.size)
        }
        OSMemoryBarrier()
        header.pointee.writeIndex = currentIndex &+ UInt64(frameCount)
    }
}

// ============================================================================
// MARK: - Reader (simulates app's SharedAudioReader)
// ============================================================================

final class TestReader {
    let fd: Int32
    let totalSize: Int
    let mappedRegion: UnsafeMutableRawPointer
    let header: UnsafePointer<TestShmHeader>
    let samples: UnsafePointer<Float32>
    var readIndex: UInt64 = 0
    let channels: Int
    let frameCapacity: Int

    init?() {
        fd = open(kTestShmPath, O_RDONLY)
        guard fd >= 0 else { print("FAIL: can't open \(kTestShmPath): errno=\(errno)"); return nil }

        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        totalSize = Int(st.st_size)

        let headerSize = MemoryLayout<TestShmHeader>.size
        guard totalSize > headerSize else { close(fd); return nil }

        guard let region = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0),
              region != MAP_FAILED else { close(fd); return nil }

        mappedRegion = region
        header = UnsafeRawPointer(region).bindMemory(to: TestShmHeader.self, capacity: 1)
        let sampleRegion = UnsafeRawPointer(region).advanced(by: headerSize)

        guard header.pointee.magic == kTestMagic else {
            munmap(region, totalSize); close(fd); return nil
        }

        channels = Int(header.pointee.channels)
        frameCapacity = Int(header.pointee.frameCapacity)
        samples = sampleRegion.bindMemory(to: Float32.self, capacity: frameCapacity * channels)

        // Start at current write position
        OSMemoryBarrier()
        readIndex = header.pointee.writeIndex
    }

    deinit {
        munmap(mappedRegion, totalSize)
        close(fd)
    }

    /// Read and deinterleave into separate channel buffers (simulates ABL read)
    func read(into channelBuffers: [UnsafeMutablePointer<Float32>], frameCount: Int) -> Int {
        let writeIdx = header.pointee.writeIndex
        OSMemoryBarrier()

        var available = writeIdx >= readIndex ? Int(writeIdx - readIndex) : 0

        // Resync if fallen behind by more than ring capacity
        if available > frameCapacity {
            readIndex = writeIdx - UInt64(frameCapacity)
            available = frameCapacity
        }

        let framesToRead = min(min(available, frameCount), frameCapacity)

        if framesToRead > 0 {
            let cap = frameCapacity * channels
            let startOffset = Int(readIndex % UInt64(frameCapacity)) * channels

            for ch in 0..<channels {
                let dst = channelBuffers[ch]
                for f in 0..<framesToRead {
                    let srcIdx = (startOffset + f * channels + ch) % cap
                    dst[f] = samples[srcIdx]
                }
                // Zero remainder
                for f in framesToRead..<frameCount {
                    dst[f] = 0
                }
            }
            readIndex &+= UInt64(framesToRead)
        } else {
            for ch in 0..<channels {
                memset(channelBuffers[ch], 0, frameCount * MemoryLayout<Float32>.size)
            }
        }
        return framesToRead
    }

    func resync() {
        OSMemoryBarrier()
        readIndex = header.pointee.writeIndex
    }
}

// ============================================================================
// MARK: - Test infrastructure
// ============================================================================

var testCount = 0
var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    testCount += 1
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL [\(line)]: \(msg)")
    }
}

func assertApprox(_ a: Float32, _ b: Float32, tol: Float32 = 0.0001, _ msg: String, line: Int = #line) {
    assert(abs(a - b) < tol, "\(msg): expected \(b), got \(a)", line: line)
}

// ============================================================================
// MARK: - Tests
// ============================================================================

func testHeaderLayout() {
    print("Test: Header layout...")
    let size = MemoryLayout<TestShmHeader>.size
    assert(size == 64, "Header should be 64 bytes, got \(size)")

    let writeIndexOffset = MemoryLayout<TestShmHeader>.offset(of: \TestShmHeader.writeIndex)!
    assert(writeIndexOffset == 24, "writeIndex offset should be 24, got \(writeIndexOffset)")
    assert(writeIndexOffset % 8 == 0, "writeIndex must be 8-byte aligned for atomic access")
}

func testCreateAndMap() {
    print("Test: Create writer and map reader...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    assert(reader.channels == 2, "channels should be 2")
    assert(reader.frameCapacity == kTestFrameCapacity, "frameCapacity mismatch")
    assert(reader.header.pointee.sampleRate == kTestSampleRate, "sampleRate mismatch")

    _ = writer  // keep alive
    _ = reader
}

func testBasicWriteRead() {
    print("Test: Basic write → read round-trip...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    // Write 128 frames of known data (interleaved stereo)
    let frameCount = 128
    let sampleCount = frameCount * 2  // stereo
    let src = UnsafeMutablePointer<Float32>.allocate(capacity: sampleCount)
    defer { src.deallocate() }

    for i in 0..<sampleCount {
        // Left channel: 0.1, 0.1, ... Right channel: 0.2, 0.2, ...
        src[i] = (i % 2 == 0) ? 0.1 : 0.2
    }

    writer.write(from: src, frameCount: frameCount)

    // Read back into separate channel buffers
    let left = UnsafeMutablePointer<Float32>.allocate(capacity: frameCount)
    let right = UnsafeMutablePointer<Float32>.allocate(capacity: frameCount)
    defer { left.deallocate(); right.deallocate() }

    let framesRead = reader.read(into: [left, right], frameCount: frameCount)
    assert(framesRead == frameCount, "Should read all \(frameCount) frames, got \(framesRead)")

    // Verify deinterleaved data
    var leftOK = true, rightOK = true
    for i in 0..<frameCount {
        if abs(left[i] - 0.1) > 0.0001 { leftOK = false }
        if abs(right[i] - 0.2) > 0.0001 { rightOK = false }
    }
    assert(leftOK, "Left channel should all be 0.1")
    assert(rightOK, "Right channel should all be 0.2")
}

func testWrapAround() {
    print("Test: Wrap-around at ring boundary...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    let frameCount = 512
    let sampleCount = frameCount * 2
    let src = UnsafeMutablePointer<Float32>.allocate(capacity: sampleCount)
    defer { src.deallocate() }

    // Write enough to wrap around (4096 frame capacity)
    for batch in 0..<10 {
        for i in 0..<sampleCount {
            src[i] = Float32(batch) + Float32(i % 2) * 0.01
        }
        writer.write(from: src, frameCount: frameCount)
    }

    // Should have 5120 frames written, capacity is 4096, so reader can read up to 4096
    let left = UnsafeMutablePointer<Float32>.allocate(capacity: 512)
    let right = UnsafeMutablePointer<Float32>.allocate(capacity: 512)
    defer { left.deallocate(); right.deallocate() }

    var totalRead = 0
    for _ in 0..<10 {
        let n = reader.read(into: [left, right], frameCount: 512)
        totalRead += n
        if n == 0 { break }
    }

    // Should read at most frameCapacity frames total
    assert(totalRead <= kTestFrameCapacity, "Should read at most \(kTestFrameCapacity), got \(totalRead)")
    assert(totalRead > 0, "Should have read some frames")
}

func testUnderrun() {
    print("Test: Under-run (no data) → silence...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    let left = UnsafeMutablePointer<Float32>.allocate(capacity: 256)
    let right = UnsafeMutablePointer<Float32>.allocate(capacity: 256)
    defer { left.deallocate(); right.deallocate() }

    // Fill with non-zero to verify they get zeroed
    for i in 0..<256 { left[i] = 999; right[i] = 999 }

    // Read without writing anything
    let n = reader.read(into: [left, right], frameCount: 256)
    assert(n == 0, "Should read 0 frames on underrun, got \(n)")
    assert(left[0] == 0, "Left should be silence")
    assert(right[0] == 0, "Right should be silence")

    _ = writer
}

func testResync() {
    print("Test: Resync skips stale data...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    let src = UnsafeMutablePointer<Float32>.allocate(capacity: 512)
    defer { src.deallocate() }

    // Write 256 frames
    for i in 0..<512 { src[i] = 1.0 }
    writer.write(from: src, frameCount: 256)

    // Resync reader — should skip those 256 frames
    reader.resync()

    // Write 128 more frames with distinct data
    for i in 0..<256 { src[i] = 2.0 }
    writer.write(from: src, frameCount: 128)

    let left = UnsafeMutablePointer<Float32>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float32>.allocate(capacity: 128)
    defer { left.deallocate(); right.deallocate() }

    let n = reader.read(into: [left, right], frameCount: 128)
    assert(n == 128, "Should read 128 frames after resync, got \(n)")
    assertApprox(left[0], 2.0, "Data after resync should be 2.0")
}

func testMonotonicWriteIndex() {
    print("Test: writeIndex is monotonically increasing...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    let src = UnsafeMutablePointer<Float32>.allocate(capacity: 1024)
    defer { src.deallocate() }
    for i in 0..<1024 { src[i] = 0.5 }

    var prevIndex = reader.header.pointee.writeIndex

    for _ in 0..<20 {
        writer.write(from: src, frameCount: 512)
        let newIndex = reader.header.pointee.writeIndex
        assert(newIndex > prevIndex, "writeIndex should increase monotonically")
        prevIndex = newIndex
    }
}

func testLargeSequentialWriteRead() {
    print("Test: Large sequential write/read (simulates real audio)...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    let bufSize = 512  // Typical IO buffer size
    let src = UnsafeMutablePointer<Float32>.allocate(capacity: bufSize * 2)
    let dstL = UnsafeMutablePointer<Float32>.allocate(capacity: bufSize)
    let dstR = UnsafeMutablePointer<Float32>.allocate(capacity: bufSize)
    defer { src.deallocate(); dstL.deallocate(); dstR.deallocate() }

    var totalWritten = 0
    var totalRead = 0
    var errors = 0

    // Simulate 1000 IO cycles
    for cycle in 0..<1000 {
        // Write
        let val = Float32(cycle % 100) / 100.0
        for i in 0..<(bufSize * 2) {
            src[i] = val + Float32(i % 2) * 0.001  // Slightly different per channel
        }
        writer.write(from: src, frameCount: bufSize)
        totalWritten += bufSize

        // Read
        let n = reader.read(into: [dstL, dstR], frameCount: bufSize)
        totalRead += n

        if n == bufSize {
            // Verify data integrity: check first sample of each channel
            let expectedL = val
            let expectedR = val + 0.001
            if abs(dstL[0] - expectedL) > 0.001 { errors += 1 }
            if abs(dstR[0] - expectedR) > 0.001 { errors += 1 }
        }
    }

    assert(totalRead == totalWritten, "Total read (\(totalRead)) should equal written (\(totalWritten))")
    assert(errors == 0, "Data integrity errors: \(errors)")
}

func testCleanup() {
    print("Test: File cleanup on deinit...")
    do {
        let writer = TestWriter()
        assert(writer != nil, "Writer should be created")
        assert(access(kTestShmPath, F_OK) == 0, "File should exist while writer is alive")
    }
    // Writer deinit should unlink the file
    assert(access(kTestShmPath, F_OK) != 0, "File should be removed after writer deinit")
}

// ============================================================================
// MARK: - Run all tests
// ============================================================================

print("=== SharedAudio Memory Tests ===\n")

testHeaderLayout()
testCreateAndMap()
testBasicWriteRead()
testWrapAround()
testUnderrun()
testResync()
testMonotonicWriteIndex()
testLargeSequentialWriteRead()
testCleanup()

print("\n=== Results: \(passCount)/\(testCount) passed, \(failCount) failed ===")

if failCount > 0 {
    print("\nSOME TESTS FAILED")
    exit(1)
} else {
    print("\nALL TESTS PASSED")
    exit(0)
}
