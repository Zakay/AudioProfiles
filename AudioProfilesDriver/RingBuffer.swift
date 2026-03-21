// RingBuffer.swift — AudioProfilesDriver
//
// Lock-protected Float32 ring buffer shared between the WriteMix IO operation
// (system audio flows in) and the ReadInput IO operation (app reads loopback).
// Both operations are called by coreaudiod on its own threads, hence the lock.
//
// Optimised for the real-time audio path: raw pointer storage (no Swift Array
// CoW or bounds checks), minimal lock hold time.

import Darwin   // os_unfair_lock, memcpy

final class RingBuffer {

    // MARK: - Storage

    private let capacity: Int          // total Float32 elements (frames × channels)
    private let buffer: UnsafeMutablePointer<Float32>
    private var writePos: Int = 0
    private var readPos:  Int = 0
    private var lock = os_unfair_lock()

    // MARK: - Init

    /// - Parameter frameCount: ring size in frames; total elements = frameCount × kChannelCount
    init(frameCount: Int = kRingBufferFrameCount) {
        capacity = frameCount * Int(kChannelCount)
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Write (WriteMix path — system audio in)

    /// Copy `frameCount` interleaved frames from `src` into the ring buffer.
    func write(from src: UnsafePointer<Float32>, frameCount: Int) {
        let count = frameCount * Int(kChannelCount)
        os_unfair_lock_lock(&lock)

        let available = capacity - writePos
        if count <= available {
            memcpy(buffer.advanced(by: writePos), src, count * MemoryLayout<Float32>.size)
        } else {
            let firstPart = available
            let secondPart = count - firstPart
            memcpy(buffer.advanced(by: writePos), src, firstPart * MemoryLayout<Float32>.size)
            memcpy(buffer, src.advanced(by: firstPart), secondPart * MemoryLayout<Float32>.size)
        }
        writePos = (writePos + count) % capacity

        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Read (ReadInput path — app reads loopback)

    /// Copy `frameCount` interleaved frames from the ring buffer into `dst`.
    /// Returns silence (zeros) if not enough data is available.
    func read(into dst: UnsafeMutablePointer<Float32>, frameCount: Int) {
        let count = frameCount * Int(kChannelCount)
        os_unfair_lock_lock(&lock)

        let filled = (writePos - readPos + capacity) % capacity
        guard filled >= count else {
            os_unfair_lock_unlock(&lock)
            memset(dst, 0, count * MemoryLayout<Float32>.size)
            return
        }

        let available = capacity - readPos
        if count <= available {
            memcpy(dst, buffer.advanced(by: readPos), count * MemoryLayout<Float32>.size)
        } else {
            let firstPart  = available
            let secondPart = count - firstPart
            memcpy(dst, buffer.advanced(by: readPos), firstPart * MemoryLayout<Float32>.size)
            memcpy(dst.advanced(by: firstPart), buffer, secondPart * MemoryLayout<Float32>.size)
        }
        readPos = (readPos + count) % capacity

        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Debug accessors

    var debugWritePos: Int { writePos }
    var debugReadPos: Int { readPos }

    // MARK: - Reset

    func reset() {
        os_unfair_lock_lock(&lock)
        memset(buffer, 0, capacity * MemoryLayout<Float32>.size)
        writePos = 0
        readPos  = 0
        os_unfair_lock_unlock(&lock)
    }
}
