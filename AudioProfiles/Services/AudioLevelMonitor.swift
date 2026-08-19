// AudioLevelMonitor.swift — AudioProfiles
//
// Reads real-time audio levels from the shared memory EQ pipeline buffer.
// Publishes RMS levels for left and right channels at ~30 Hz for the
// level meter overlay in the EQ graph.

import Foundation
import Combine

@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    @Published private(set) var leftLevel: Float = 0
    @Published private(set) var rightLevel: Float = 0

    private var timer: Timer?
    private var fd: Int32 = -1
    private var mappedRegion: UnsafeMutableRawPointer?
    private var totalSize: Int = 0
    private var cancellables = Set<AnyCancellable>()

    private let kShmPath = "/tmp/com.audioprofiles.eq-audio"

    // Header layout (must match SharedAudioReader.ShmHeader / driver):
    //   magic:         UInt32  offset  0
    //   version:       UInt32  offset  4
    //   sampleRate:    UInt32  offset  8
    //   channels:      UInt32  offset 12
    //   frameCapacity: UInt32  offset 16
    //   reserved1:     UInt32  offset 20
    //   writeIndex:    UInt64  offset 24
    //   reserved2-5:   UInt64  offsets 32, 40, 48, 56
    // Total header size: 64 bytes
    private let kHeaderSize = 64
    private let kChannelsOffset = 12
    private let kFrameCapacityOffset = 16
    private let kWriteIndexOffset = 24

    private init() {
        EQEngineService.shared.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                if running {
                    self?.startMonitoring()
                } else {
                    self?.stopMonitoring()
                }
            }
            .store(in: &cancellables)
    }

    private func startMonitoring() {
        guard fd == -1 else { return }

        fd = open(kShmPath, O_RDONLY)
        guard fd >= 0 else { return }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd); fd = -1; return
        }
        totalSize = Int(st.st_size)
        guard totalSize > kHeaderSize else {
            close(fd); fd = -1; return
        }

        mappedRegion = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0)
        guard mappedRegion != MAP_FAILED else {
            close(fd); fd = -1; mappedRegion = nil; return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLevels()
            }
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        if let region = mappedRegion, totalSize > 0 {
            munmap(region, totalSize)
        }
        mappedRegion = nil

        if fd >= 0 { close(fd); fd = -1 }
        totalSize = 0
        leftLevel = 0
        rightLevel = 0
    }

    private func updateLevels() {
        guard let region = mappedRegion else { return }

        let channels = Int(region.load(fromByteOffset: kChannelsOffset, as: UInt32.self))
        let frameCapacity = Int(region.load(fromByteOffset: kFrameCapacityOffset, as: UInt32.self))
        let writeIndex = region.load(fromByteOffset: kWriteIndexOffset, as: UInt64.self)

        guard channels >= 2, frameCapacity > 0 else { return }

        let samplesPtr = region.advanced(by: kHeaderSize).assumingMemoryBound(to: Float32.self)
        let totalSamples = frameCapacity * channels

        // Windowed RMS + smoothing arithmetic lives in AudioCore (shared with tests).
        let (l, r) = AudioCore.computeRMSLevels(
            sampleAt: { samplesPtr[$0] },
            totalSamples: totalSamples,
            channels: channels,
            frameCapacity: frameCapacity,
            writeIndex: writeIndex,
            windowFrames: 1024,
            previousLeft: leftLevel,
            previousRight: rightLevel,
            smoothing: 0.7
        )
        leftLevel = l
        rightLevel = r
    }
}
