// SHARED: AudioProfiles/Models/AudioDevice.swift AudioProfiles/Models/ProfileMode.swift AudioProfiles/Models/Hotkey.swift AudioProfiles/Models/Profile.swift AudioProfiles/Models/DeviceHistoryEntry.swift AudioProfiles/Core/AudioCore.swift
//
// SharedAudioTests.swift
//
// Standalone test for the shared memory audio pipeline between the driver
// (SharedAudioBuffer) and the app (SharedAudioReader). Tests the cross-process
// mmap-based ring buffer without needing Core Audio or the actual driver.
//
// The ring-buffer read-decision MATH (available / resync / framesToRead /
// framesDropped) is NOT reimplemented here — it comes from the production
// AudioCore.computeReadPlan (compiled in via the `// SHARED:` directive above,
// which build.sh reads). The RMS metering math likewise comes from
// AudioCore.computeRMSLevels. The local TestWriter/TestReader only cover the
// memcpy/deinterleave DATA path, which is not part of AudioCore.
//
// Run via build.sh (it resolves the SHARED directive), or manually:
//   swiftc <shared files...> Tests/SharedAudioTests.swift -o bin && ./bin
//
// These tests validate:
//   1. File creation, mmap, and header initialization
//   2. Write → read round-trip with correct data
//   3. Wrap-around behavior when the ring buffer fills
//   4. Deinterleaving from interleaved (driver format) to non-interleaved (EQ format)
//   5. Under-run behavior (reader ahead of writer → silence)
//   6. Resync after gap
//   7. Cleanup on teardown
//   8. AudioCore.computeReadPlan resync/drop arithmetic (real production code)
//   9. AudioCore.computeRMSLevels metering (real production code)

import Foundation
import Darwin

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
//
// The DATA path (memcpy/deinterleave/wrap) is exercised here directly because
// it is not part of AudioCore. The read-DECISION arithmetic (available, resync,
// framesToRead, framesDropped) is delegated to AudioCore.computeReadPlan so the
// tests exercise the real production code, exactly as SharedAudioReader.read does.

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

    /// Read and deinterleave into separate channel buffers (simulates ABL read).
    /// The read plan (how much / resync) comes from production AudioCore; only the
    /// deinterleave/wrap memcpy loop lives here (that is the DATA path under test).
    func read(into channelBuffers: [UnsafeMutablePointer<Float32>], frameCount: Int) -> Int {
        let writeIdx = header.pointee.writeIndex
        OSMemoryBarrier()

        let plan = AudioCore.computeReadPlan(
            writeIndex: writeIdx,
            readIndex: readIndex,
            frameCapacity: frameCapacity,
            requestedFrames: frameCount
        )
        let framesToRead = plan.framesToRead

        if framesToRead > 0 {
            let cap = frameCapacity * channels
            // Pre-advance cursor, mirroring SharedAudioReader.read.
            let readStart = plan.newReadIndex - UInt64(framesToRead)
            let startOffset = Int(readStart % UInt64(frameCapacity)) * channels

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
        } else {
            for ch in 0..<channels {
                memset(channelBuffers[ch], 0, frameCount * MemoryLayout<Float32>.size)
            }
        }
        // Advance/resync exactly as the plan dictates.
        readIndex = plan.newReadIndex
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
// MARK: - AudioCore.computeReadPlan (real production ring-buffer arithmetic)
// ============================================================================

func testReadPlanNormal() {
    print("Test: computeReadPlan — normal, data available...")
    // 500 frames available, request 128 → read 128, no drop, no reset.
    let plan = AudioCore.computeReadPlan(
        writeIndex: 500, readIndex: 0, frameCapacity: 4096, requestedFrames: 128)
    assert(plan.available == 500, "available should be 500, got \(plan.available)")
    assert(plan.framesToRead == 128, "framesToRead should be 128, got \(plan.framesToRead)")
    assert(plan.newReadIndex == 128, "newReadIndex should be 128, got \(plan.newReadIndex)")
    assert(plan.framesDropped == 0, "framesDropped should be 0, got \(plan.framesDropped)")
    assert(!plan.didReset, "didReset should be false")
}

func testReadPlanUnderrun() {
    print("Test: computeReadPlan — underrun (no data)...")
    // writeIndex == readIndex → nothing available.
    let plan = AudioCore.computeReadPlan(
        writeIndex: 1000, readIndex: 1000, frameCapacity: 4096, requestedFrames: 256)
    assert(plan.available == 0, "available should be 0, got \(plan.available)")
    assert(plan.framesToRead == 0, "framesToRead should be 0, got \(plan.framesToRead)")
    assert(plan.newReadIndex == 1000, "newReadIndex unchanged on underrun, got \(plan.newReadIndex)")
    assert(plan.framesDropped == 0, "framesDropped should be 0")
    assert(!plan.didReset, "didReset should be false")
}

func testReadPlanDriverReset() {
    print("Test: computeReadPlan — driver reset (writeIndex < readIndex)...")
    // DRIFT FIX: the old local test asserted this case drops 4096 frames.
    // Production/AudioCore snaps readIndex to writeIndex and reads NOTHING —
    // it drops 0 (the stale data is abandoned, not "dropped"), didReset == true.
    let plan = AudioCore.computeReadPlan(
        writeIndex: 0, readIndex: 4096, frameCapacity: 4096, requestedFrames: 512)
    assert(plan.didReset, "didReset should be true on driver reset")
    assert(plan.framesDropped == 0, "DRIFT: framesDropped should be 0 on reset (was wrongly 4096), got \(plan.framesDropped)")
    assert(plan.available == 0, "available should be 0 after reset snap, got \(plan.available)")
    assert(plan.framesToRead == 0, "framesToRead should be 0 on reset, got \(plan.framesToRead)")
    assert(plan.newReadIndex == 0, "newReadIndex should snap to writeIndex (0), got \(plan.newReadIndex)")
}

func testReadPlanFellBehind() {
    print("Test: computeReadPlan — fell behind > capacity (the drop branch)...")
    // available (5000) > capacity (4096): this is the branch that drops frames.
    // Drops available - capacity = 904; reads up to capacity, clamped to request.
    let plan = AudioCore.computeReadPlan(
        writeIndex: 5000, readIndex: 0, frameCapacity: 4096, requestedFrames: 512)
    assert(plan.available == 4096, "available clamps to capacity 4096, got \(plan.available)")
    assert(plan.framesDropped == 904, "framesDropped should be 5000-4096=904, got \(plan.framesDropped)")
    assert(!plan.didReset, "didReset should be false (this is lag, not reset)")
    assert(plan.framesToRead == 512, "framesToRead clamps to request 512, got \(plan.framesToRead)")
    // Read cursor was force-advanced to writeIndex - capacity = 904, then + 512.
    assert(plan.newReadIndex == 904 + 512, "newReadIndex should be 1416, got \(plan.newReadIndex)")
}

func testReadPlanClampsToCapacity() {
    print("Test: computeReadPlan — request larger than capacity clamps...")
    // Plenty available, huge request → clamps to frameCapacity.
    let plan = AudioCore.computeReadPlan(
        writeIndex: 10000, readIndex: 0, frameCapacity: 4096, requestedFrames: 100000)
    // available 10000 > capacity → drops 10000-4096, reads capacity.
    assert(plan.framesDropped == 10000 - 4096, "framesDropped should be \(10000 - 4096), got \(plan.framesDropped)")
    assert(plan.framesToRead == 4096, "framesToRead clamps to capacity 4096, got \(plan.framesToRead)")
}

// ============================================================================
// MARK: - AudioCore.computeRMSLevels (real production metering)
// ============================================================================

func testRMSSilence() {
    print("Test: computeRMSLevels — silence → 0...")
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: { _ in 0 },
        totalSamples: 4096 * 2, channels: 2, frameCapacity: 4096,
        writeIndex: 0, windowFrames: 1024,
        previousLeft: 0, previousRight: 0, smoothing: 0.7)
    assertApprox(l, 0, "Silence left should be 0")
    assertApprox(r, 0, "Silence right should be 0")
}

func testRMSFullScaleSine() {
    print("Test: computeRMSLevels — full-scale sine → ~0.707...")
    // Interleaved stereo sine at amplitude 1.0. RMS of a sine is 1/sqrt(2) ≈ 0.707.
    // Start previous at the true RMS so the one-pole smoother stays at steady state
    // (isolates the RMS computation from the smoothing transient).
    let freq: Float = 8.0 // whole cycles across 1024-frame window → clean RMS
    let sampleAt: (Int) -> Float32 = { idx in
        let frame = idx / 2
        return sinf(2 * Float.pi * freq * Float(frame) / 1024.0)
    }
    let steady: Float = 1.0 / sqrtf(2.0)
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: sampleAt,
        totalSamples: 4096 * 2, channels: 2, frameCapacity: 4096,
        // writeIndex 1024 → window is frames [0, 1024) which we filled with the sine.
        writeIndex: 1024, windowFrames: 1024,
        previousLeft: steady, previousRight: steady, smoothing: 0.7)
    assertApprox(l, 0.707, tol: 0.01, "Full-scale sine left RMS should be ~0.707")
    assertApprox(r, 0.707, tol: 0.01, "Full-scale sine right RMS should be ~0.707")
}

func testRMSDC() {
    print("Test: computeRMSLevels — DC 1.0 → 1.0...")
    // Constant 1.0 → RMS is 1.0. Start previous at 1.0 for steady state.
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: { _ in 1.0 },
        totalSamples: 4096 * 2, channels: 2, frameCapacity: 4096,
        writeIndex: 0, windowFrames: 1024,
        previousLeft: 1.0, previousRight: 1.0, smoothing: 0.7)
    assertApprox(l, 1.0, "DC 1.0 left RMS should be 1.0")
    assertApprox(r, 1.0, "DC 1.0 right RMS should be 1.0")
}

func testRMSClampLoud() {
    print("Test: computeRMSLevels — loud (>1.0) signal clamps to 1.0...")
    // DC 4.0 → raw RMS 4.0, but production clamps min(rms, 1.0). Start prev at 1.0.
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: { _ in 4.0 },
        totalSamples: 4096 * 2, channels: 2, frameCapacity: 4096,
        writeIndex: 0, windowFrames: 1024,
        previousLeft: 1.0, previousRight: 1.0, smoothing: 0.7)
    assertApprox(l, 1.0, "Loud signal left should clamp to 1.0")
    assertApprox(r, 1.0, "Loud signal right should clamp to 1.0")
    assert(l <= 1.0 && r <= 1.0, "Levels must never exceed 1.0")
}

func testRMSChannelsGuard() {
    print("Test: computeRMSLevels — channels < 2 returns previous levels...")
    // Guard: channels >= 2 required. Mono → returns previous unchanged.
    let (l, r) = AudioCore.computeRMSLevels(
        sampleAt: { _ in 1.0 },
        totalSamples: 4096, channels: 1, frameCapacity: 4096,
        writeIndex: 0, windowFrames: 1024,
        previousLeft: 0.42, previousRight: 0.17, smoothing: 0.7)
    assertApprox(l, 0.42, "channels<2 guard returns previousLeft")
    assertApprox(r, 0.17, "channels<2 guard returns previousRight")
}

func testRMSOnePoleSmoothing() {
    print("Test: computeRMSLevels — one-pole smoothing from 0...")
    // DC 0.5 → rms 0.5. Starting from previous 0, smoothing 0.7:
    //   new = 0*0.7 + 0.5*(1-0.7) = 0.15  (i.e. 0.3 * rms with r=0.5).
    let r: Float = 0.5
    let (l, rr) = AudioCore.computeRMSLevels(
        sampleAt: { _ in r },
        totalSamples: 4096 * 2, channels: 2, frameCapacity: 4096,
        writeIndex: 0, windowFrames: 1024,
        previousLeft: 0, previousRight: 0, smoothing: 0.7)
    let expected: Float = 0.3 * r  // (1 - 0.7) * r
    assertApprox(l, expected, "One-pole: single call from 0 gives 0.3*r")
    assertApprox(rr, expected, "One-pole (right): single call from 0 gives 0.3*r")
}

// ============================================================================
// MARK: - Ring-seam DATA correctness (memcpy/deinterleave wrap)
// ============================================================================

func testRingSeamDataCorrectness() {
    print("Test: Ring-seam data correctness across the 4096-frame wrap...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    // Advance write position to 4000 by writing (and consuming) filler, so the
    // next real write straddles the 4096-frame boundary (4000 -> 4256, wraps at 4096).
    let fillerFrames = 4000
    let filler = UnsafeMutablePointer<Float32>.allocate(capacity: fillerFrames * 2)
    defer { filler.deallocate() }
    for i in 0..<(fillerFrames * 2) { filler[i] = -1.0 }
    writer.write(from: filler, frameCount: fillerFrames)

    let fdump = UnsafeMutablePointer<Float32>.allocate(capacity: fillerFrames)
    let fdumpR = UnsafeMutablePointer<Float32>.allocate(capacity: fillerFrames)
    defer { fdump.deallocate(); fdumpR.deallocate() }
    _ = reader.read(into: [fdump, fdumpR], frameCount: fillerFrames)  // consume filler

    // Write a known ramp of 256 frames straddling the wrap (writeIndex 4000 -> 4256).
    let rampFrames = 256
    let ramp = UnsafeMutablePointer<Float32>.allocate(capacity: rampFrames * 2)
    defer { ramp.deallocate() }
    for f in 0..<rampFrames {
        // Left = f, Right = f + 10000 — distinct, easy to verify per channel & per frame.
        ramp[f * 2] = Float32(f)
        ramp[f * 2 + 1] = Float32(f) + 10000
    }
    writer.write(from: ramp, frameCount: rampFrames)

    let left = UnsafeMutablePointer<Float32>.allocate(capacity: rampFrames)
    let right = UnsafeMutablePointer<Float32>.allocate(capacity: rampFrames)
    defer { left.deallocate(); right.deallocate() }

    let n = reader.read(into: [left, right], frameCount: rampFrames)
    assert(n == rampFrames, "Should read all \(rampFrames) ramp frames across wrap, got \(n)")

    var seamOK = true
    var firstBad = -1
    for f in 0..<rampFrames {
        if left[f] != Float32(f) || right[f] != Float32(f) + 10000 {
            seamOK = false
            if firstBad < 0 { firstBad = f }
        }
    }
    assert(seamOK, "Ramp must survive the ring wrap exactly (first bad frame: \(firstBad))")
    // Explicitly assert the samples immediately on either side of the 4096 seam.
    // writeIndex was 4000; frame index 96 corresponds to absolute 4096 (the wrap point).
    assertApprox(left[95], 95, "Sample just before seam (frame 95)")
    assertApprox(left[96], 96, "Sample just after seam (frame 96 = absolute 4096)")
    assertApprox(right[96], 96 + 10000, "Right channel across seam (frame 96)")
}

// ============================================================================
// MARK: - Partial read (request > available)
// ============================================================================

func testPartialRead() {
    print("Test: Partial read — request more than available, tail zero-filled...")
    guard let writer = TestWriter() else { assert(false, "Writer creation failed"); return }
    guard let reader = TestReader() else { assert(false, "Reader creation failed"); return }

    // Write only 100 frames of known data.
    let avail = 100
    let src = UnsafeMutablePointer<Float32>.allocate(capacity: avail * 2)
    defer { src.deallocate() }
    for f in 0..<avail {
        src[f * 2] = Float32(f) + 1       // left: 1..100
        src[f * 2 + 1] = Float32(f) + 501 // right: 501..600
    }
    writer.write(from: src, frameCount: avail)

    // Request 300 frames — more than the 100 available.
    let req = 300
    let left = UnsafeMutablePointer<Float32>.allocate(capacity: req)
    let right = UnsafeMutablePointer<Float32>.allocate(capacity: req)
    defer { left.deallocate(); right.deallocate() }
    for i in 0..<req { left[i] = 777; right[i] = 777 }  // poison to catch missing zero-fill

    let n = reader.read(into: [left, right], frameCount: req)
    assert(n == avail, "Partial read should return \(avail) available frames, got \(n)")

    // Head holds real data.
    var headOK = true
    for f in 0..<avail {
        if left[f] != Float32(f) + 1 || right[f] != Float32(f) + 501 { headOK = false }
    }
    assert(headOK, "Head of partial read must hold the real 100 frames")

    // Tail (frames avail..<req) must be zero-filled.
    var tailOK = true
    for f in avail..<req {
        if left[f] != 0 || right[f] != 0 { tailOK = false }
    }
    assert(tailOK, "Tail of partial read must be zero-filled (not poison)")
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

// AudioCore.computeReadPlan (real production ring-buffer math)
testReadPlanNormal()
testReadPlanUnderrun()
testReadPlanDriverReset()
testReadPlanFellBehind()
testReadPlanClampsToCapacity()

// AudioCore.computeRMSLevels (real production metering)
testRMSSilence()
testRMSFullScaleSine()
testRMSDC()
testRMSClampLoud()
testRMSChannelsGuard()
testRMSOnePoleSmoothing()

// DATA-path coverage
testRingSeamDataCorrectness()
testPartialRead()

print("\n=== Results: \(passCount)/\(testCount) passed, \(failCount) failed ===")

if failCount > 0 {
    print("\nSOME TESTS FAILED")
    exit(1)
} else {
    print("\nALL TESTS PASSED")
    exit(0)
}
