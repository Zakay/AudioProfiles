import Foundation

/// Canonical, dependency-free (Foundation-only) core logic shared by production and tests.
///
/// **Why this exists**: the standalone test scripts cannot import the app target, so they
/// used to *reimplement* production decision logic and assert against the copies. Those copies
/// drifted from production, producing green tests that no longer described shipped behavior.
/// Everything here is pure and Foundation-only, so both the app target (via the synchronized
/// file group) and the test scripts (compiled with these files, see build.sh) use the SAME code.
/// There is now one source of truth — a production regression fails the tests.
enum AudioCore {

    // MARK: - Shared-memory ring buffer read plan

    /// The outcome of deciding how much to read from the shared-memory ring buffer.
    struct ReadPlan: Equatable {
        /// Frames the reader will hand back this call (0 → output silence).
        let framesToRead: Int
        /// Read cursor after this call.
        let newReadIndex: UInt64
        /// Frames irrecoverably skipped because the writer lapped the reader.
        let framesDropped: Int
        /// Frames available before clamping to the request / capacity.
        let available: Int
        /// True when the read cursor had to be force-resynced to the writer (driver reset).
        let didReset: Bool
    }

    /// Pure ring-buffer read arithmetic, extracted verbatim from `SharedAudioReader.read`.
    ///
    /// Two resync conditions, matching production exactly:
    ///  1. `writeIndex < readIndex` → the driver restarted; snap the reader to the writer and
    ///     read nothing this call (drops 0 — the old data is simply abandoned).
    ///  2. `available > frameCapacity` → the reader fell more than a ring behind; skip forward,
    ///     dropping `available - frameCapacity` frames.
    static func computeReadPlan(
        writeIndex: UInt64,
        readIndex: UInt64,
        frameCapacity: Int,
        requestedFrames: Int
    ) -> ReadPlan {
        var readCursor = readIndex
        var available: Int
        var didReset = false

        if writeIndex >= readCursor {
            available = Int(writeIndex - readCursor)
        } else {
            // Driver reset (IO stopped/restarted). Snap to writer; nothing to read this call.
            readCursor = writeIndex
            available = 0
            didReset = true
        }

        var framesDropped = 0
        if available > frameCapacity {
            // Fell behind by more than the ring — oldest data overwritten.
            framesDropped = available - frameCapacity
            readCursor = writeIndex - UInt64(frameCapacity)
            available = frameCapacity
        }

        let framesToRead = min(min(available, requestedFrames), frameCapacity)
        let newReadIndex = framesToRead > 0 ? readCursor &+ UInt64(framesToRead) : readCursor

        return ReadPlan(
            framesToRead: framesToRead,
            newReadIndex: newReadIndex,
            framesDropped: framesDropped,
            available: available,
            didReset: didReset
        )
    }

    // MARK: - Audio level (RMS) metering

    /// Windowed per-channel RMS with a one-pole low-pass smoother, extracted from
    /// `AudioLevelMonitor.updateLevels`. `sampleAt` reads interleaved Float32 samples by index;
    /// production wraps an mmap pointer, tests wrap an array — same math for both.
    static func computeRMSLevels(
        sampleAt: (Int) -> Float32,
        totalSamples: Int,
        channels: Int,
        frameCapacity: Int,
        writeIndex: UInt64,
        windowFrames: Int = 1024,
        previousLeft: Float,
        previousRight: Float,
        smoothing: Float = 0.7
    ) -> (left: Float, right: Float) {
        guard channels >= 2, frameCapacity > 0 else {
            return (previousLeft, previousRight)
        }

        let framesToRead = min(windowFrames, frameCapacity)
        let writeFrame = Int(writeIndex % UInt64(frameCapacity))

        var sumL: Float = 0
        var sumR: Float = 0
        for i in 0..<framesToRead {
            let frameIdx = (writeFrame - framesToRead + i + frameCapacity) % frameCapacity
            let sampleIdx = frameIdx * channels
            guard sampleIdx + 1 < totalSamples else { continue }
            let l = sampleAt(sampleIdx)
            let r = sampleAt(sampleIdx + 1)
            sumL += l * l
            sumR += r * r
        }

        let rmsL = sqrtf(sumL / Float(framesToRead))
        let rmsR = sqrtf(sumR / Float(framesToRead))

        let left = previousLeft * smoothing + min(rmsL, 1.0) * (1 - smoothing)
        let right = previousRight * smoothing + min(rmsR, 1.0) * (1 - smoothing)
        return (left, right)
    }

    // MARK: - Trigger matching

    /// Best-matching profile for a set of connected devices. Extracted from
    /// `ProfileTriggerService.findBestMatch`. Tie-break: equal match counts → more
    /// specific (`.specificDevice`) matches win.
    struct TriggerMatch: Equatable {
        let profileID: UUID
        let matchCount: Int
        let specificCount: Int
        let primaryTriggerDevice: String
    }

    static func findBestTriggerMatch(
        profiles: [Profile],
        currentDeviceIDs: Set<String>,
        currentDevices: [AudioDevice] = []
    ) -> TriggerMatch? {
        var best: TriggerMatch? = nil

        for profile in profiles {
            guard !profile.triggerRules.isEmpty else { continue }

            var matchCount = 0
            var specificCount = 0
            var primaryDevice: String? = nil

            for rule in profile.triggerRules {
                switch rule {
                case .specificDevice(let id):
                    if currentDeviceIDs.contains(id) {
                        matchCount += 1
                        specificCount += 1
                        if primaryDevice == nil { primaryDevice = id }
                    }
                case .transportType(let type):
                    if currentDevices.contains(where: { $0.transportType == type }) {
                        matchCount += 1
                        if primaryDevice == nil {
                            primaryDevice = currentDevices.first(where: { $0.transportType == type })?.id ?? "Any \(type)"
                        }
                    }
                }
            }

            if matchCount > 0 {
                let isBetter: Bool
                if best == nil {
                    isBetter = true
                } else if matchCount > best!.matchCount {
                    isBetter = true
                } else if matchCount == best!.matchCount && specificCount > best!.specificCount {
                    isBetter = true
                } else {
                    isBetter = false
                }
                if isBetter {
                    best = TriggerMatch(
                        profileID: profile.id,
                        matchCount: matchCount,
                        specificCount: specificCount,
                        primaryTriggerDevice: primaryDevice!
                    )
                }
            }
        }
        return best
    }

    // MARK: - Manual-override protection

    /// Whether an automatic trigger may fire given a prior manual selection. Extracted from
    /// `ProfileManager.shouldApplyTrigger`. Allowed only if a trigger device is currently
    /// active AND connected (`connectedAt`) after the manual switch — a device that predates
    /// the manual switch (even with a refreshed `lastSeen`) must not override the user.
    static func shouldApplyTrigger(
        lastManualSwitch: Date?,
        triggerDeviceIDs: [String],
        history: [String: DeviceHistoryEntry]
    ) -> Bool {
        guard let lastManualSwitch = lastManualSwitch else { return true }
        for deviceID in triggerDeviceIDs {
            if let entry = history[deviceID],
               entry.isCurrentlyActive,
               entry.connectedAt > lastManualSwitch {
                return true
            }
        }
        return false
    }

    // MARK: - Device history update

    /// Fold a fresh device scan into the history map. Extracted from
    /// `AudioDeviceHistoryService.performCompleteUpdate`.
    ///  - `lastSeen` refreshes to `now` for every connected device.
    ///  - `connectedAt` advances ONLY on a disconnected → connected transition (or first sight).
    ///  - Devices absent from the scan are marked inactive but retained.
    static func updateDeviceHistory(
        _ current: [String: DeviceHistoryEntry],
        with devices: [AudioDevice],
        now: Date
    ) -> [String: DeviceHistoryEntry] {
        var updated = current
        let currentIDs = Set(devices.map { $0.id })

        // Mark existing entries active/inactive; preserve connectedAt unless (re)connecting.
        for (id, entry) in current {
            let isActive = currentIDs.contains(id)
            let connectedAt = (isActive && !entry.isCurrentlyActive) ? now : entry.connectedAt
            updated[id] = DeviceHistoryEntry(
                device: entry.device,
                lastSeen: isActive ? now : entry.lastSeen,
                connectedAt: connectedAt,
                isCurrentlyActive: isActive
            )
        }

        // Add/refresh currently-connected devices.
        for device in devices {
            if let existing = updated[device.id] {
                updated[device.id] = DeviceHistoryEntry(
                    device: device,
                    lastSeen: now,
                    connectedAt: existing.connectedAt,
                    isCurrentlyActive: true
                )
            } else {
                updated[device.id] = DeviceHistoryEntry(
                    device: device,
                    lastSeen: now,
                    connectedAt: now,
                    isCurrentlyActive: true
                )
            }
        }
        return updated
    }
}
