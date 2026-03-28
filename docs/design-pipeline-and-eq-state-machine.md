# Unidirectional Pipeline & EQ State Machine — Design Document

## Overview

All audio state changes flow through a single function: `ProfileManager.evaluateAndApply()`. Every event in the system — profile switch, mode toggle, EQ change, device connect/disconnect, sound mode update — calls this one function. It resolves the full desired state and hands it to `AudioPipelineService.apply()`, which realizes it against Core Audio.

The EQ engine (`EQEngineService`) uses an event-driven state machine to manage the virtual audio device lifecycle. It uses Core Audio property listeners instead of `Thread.sleep` or semaphores, and a generation counter to discard stale callbacks.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        Events                               │
│  Profile activated  ·  Mode toggled  ·  Device connected    │
│  EQ preset changed  ·  Sound mode changed  ·  Night mode    │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │  ProfileManager              │
              │  evaluateAndApply()          │
              │                              │
              │  1. Resolve output device    │
              │  2. Resolve input device     │
              │  3. Compute effective EQ     │
              │  4. Fingerprint check        │
              │  5. Call pipeline apply()    │
              └──────────────┬───────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │  AudioPipelineService        │
              │  apply()                     │
              │                              │
              │  Stateless executor:         │
              │  • Hot-update EQ settings    │
              │  • Switch real device        │
              │  • Start/stop EQ pipeline    │
              │  • Set default I/O devices   │
              └──────────────┬───────────────┘
                             │
                 ┌───────────┼───────────┐
                 ▼           ▼           ▼
          EQEngineService  EQDriver  AudioDevice
          (state machine)  Service   ControlService
```

## The evaluateAndApply Pipeline

### Entry Point

`ProfileManager.evaluateAndApply()` is the single entry point. Every caller that changes audio-relevant state must call it (or invalidate the fingerprint and call it).

### Reentrancy Guard

Because `evaluateAndApply()` can trigger Core Audio callbacks that themselves cause state changes (e.g., device list changes when the virtual device appears), it uses a reentrancy-safe loop:

```
evaluateAndApply():
    if isEvaluating:
        needsReevaluation = true    ← mark for re-run, don't recurse
        return
    isEvaluating = true

    repeat:
        needsReevaluation = false
        performEvaluation()         ← does the actual work
    while needsReevaluation          ← re-run if something changed mid-evaluation
    (max 3 iterations as safety)

    isEvaluating = false
```

This prevents both recursive calls and dropped events. If an event arrives during evaluation, it sets `needsReevaluation = true` and the loop picks it up.

### performEvaluation Steps

1. **Cancel pending teardown** — If a previous `stopSafe()` scheduled an async device-restore, cancel it before computing new state.

2. **Guard active profile** — No profile = nothing to do.

3. **Get current devices** — Snapshot of all Core Audio devices.

4. **Resolve output device** — Walk the profile's output priority list (for the current public/private mode). First connected device wins. Virtual device look-through: if the priority list points at our own virtual device, resolve through to the real device behind it.

5. **Resolve input device** — Same priority-list walk for input devices.

6. **Compute effective EQ** — Three-layer combination:
   ```
   Layer 1 (base):    EQStore.settings(for: outputUID)     — per-device correction preset
   Layer 2 (overlay): SoundModesStore.activeOverlay()       — content mode + night mode
   Effective EQ:      EQSettings.combine(base, overlay)     — additive band merging
   ```

7. **Determine virtual driver need** — `needsVirtualDriver = !effectiveEQ.isFlat && driverIsInstalled`

8. **Fingerprint check** — Build a `PipelineFingerprint` (profile ID, mode, output UID, input UID, effective EQ, needsVirtualDriver). If identical to the last applied fingerprint, skip — nothing changed.

9. **Apply** — Call `AudioPipelineService.apply()` with the resolved state.

10. **Update UI** — Set `activeOutputDeviceName` / `activeInputDeviceName` for SwiftUI bindings.

### Fingerprint Deduplication

The fingerprint prevents redundant Core Audio calls when multiple events fire for the same logical state (e.g., device reconnect re-triggers auto-detection but the same profile is already active). Callers that know they changed something (profile switch, mode toggle, profile edit) invalidate the fingerprint by setting `lastFingerprint = nil` before calling `evaluateAndApply()`.

```swift
struct PipelineFingerprint: Equatable {
    let profileID: UUID?
    let mode: ProfileMode
    let outputDeviceUID: String?
    let inputDeviceUID: String?
    let effectiveEQ: EQSettings
    let needsVirtualDriver: Bool
}
```

### Who Calls evaluateAndApply

| Caller | Trigger |
|---|---|
| `activateProfile()` | Profile switch (manual or auto-trigger) |
| `toggleMode()` | Public/private mode toggle |
| `upsert(_:)` | Profile edited (if active profile) |
| `SoundModesStore.setEnabled()` | Sound modes toggled |
| `SoundModesStore.setOverlays()` | Content mode EQ changed |
| `SoundModesStore.setNightMode()` | Night mode config changed |
| `NightModeScheduler` | Night mode activated/deactivated by schedule |
| `ContentModeDetectionService` | Content mode auto-detected change |
| `EQStore` | User edits device EQ preset |

All callers go through the same path — there is no separate "activate profile" vs "update EQ" vs "switch device" code path.

## AudioPipelineService.apply()

The pipeline service is stateless — it reads current state from `EQEngineService` and decides which operation to perform:

| Current State | Desired State | Action |
|---|---|---|
| EQ running, same device | EQ needed, same device | **Hot-update**: `updateSettings(effectiveEQ)` |
| EQ running, different device | EQ needed, different device | **Switch**: `switchDevice(realDeviceUID:, settings:, virtualDeviceName:)` |
| EQ not running | EQ needed | **Start**: `startPipeline(realDeviceUID:, settings:, virtualDeviceName:)` |
| EQ running | EQ not needed | **Stop**: `stopSafe(switchTo:)` |
| EQ not running | EQ not needed | **Direct**: `setDefaultOutputDevice(device)` |

It also handles orphan recovery: if the virtual device is the system default but `EQEngineService.isRunning` is false (crash recovery), it switches back to the real device and hides the virtual device.

## EQ Engine State Machine

### States

```
┌──────┐    startPipeline()    ┌─────────────────┐
│ idle │ ──────────────────►  │ preparingDevice  │
└──────┘                       └────────┬────────┘
   ▲                                    │ device appeared
   │ error/cancel                       ▼
   │                           ┌──────────────────────┐
   │                           │ preparingSampleRate   │
   │                           └────────┬─────────────┘
   │                                    │ rate matched
   │                                    ▼
   │                           ┌──────────────────┐
   │                           │ starting         │
   │                           └────────┬─────────┘
   │                                    │ AUs created + started
   │                                    ▼
   │          stopSafe()       ┌──────────────────┐
   │◄─────────────────────────│ running          │
   │                           └────────┬─────────┘
   │                                    │ switchDevice()
   │                                    ▼
   │                           (reuses preparingSampleRate
   │                            or finishSwitchDevice directly)
   │                                    │
   │◄───────────────────────────────────┘
   │          stopping
```

### States in Detail

| State | What's happening | Waiting for |
|---|---|---|
| `idle` | No pipeline active | Nothing |
| `preparingDevice` | Virtual device `show()` called, waiting for it to appear in HAL device list | `kAudioHardwarePropertyDevices` listener |
| `preparingSampleRate` | Virtual device visible, sample rate set, waiting for it to take effect | `kAudioDevicePropertyNominalSampleRate` listener |
| `starting` | Creating AudioUnits, wiring render callbacks, starting IO | Synchronous — no wait |
| `running` | Audio flowing: apps → virtual device → shared memory → EQ → real hardware | Nothing (steady state) |
| `stopping` | Teardown in progress, restoring real device as default | Async device restore |

### Event-Driven Waits (No Sleep, No Semaphores)

The state machine never blocks. Each wait is a Core Audio property listener + safety timer:

**Pattern** (used for both device appearance and sample rate):

1. Register `AudioObjectPropertyListenerBlock` BEFORE the action that triggers the change
2. Perform the action (`show()` or `resetVirtualDeviceRate()`)
3. Check immediately — if the condition is already met (device already visible, rate already matched), proceed synchronously
4. Otherwise, the listener callback fires when Core Audio reports the change → advances state machine
5. Safety timer (2s one-shot) fires if the listener never does → proceeds anyway

This pattern handles three scenarios:
- **Synchronous notification**: Listener fires during the `show()` call itself (common case)
- **Async notification**: Listener fires shortly after
- **No notification**: Device was already in the desired state, immediate check catches it
- **Failure**: Safety timer proceeds after 2s to avoid hanging forever

### Generation Counter

Rapid start/stop cycles (e.g., quickly switching profiles) can leave stale listener callbacks in flight. The generation counter prevents them from acting on outdated state:

```
startPipeline():
    gGeneration += 1                    ← new generation
    capturedGen = gGeneration

    listener = { [weak self] in
        guard capturedGen == gGeneration ← stale? bail out
        self.handleDeviceAppeared()
    }
```

Every listener callback and safety timer captures the generation at creation time. If `gGeneration` has moved on by the time the callback fires, the callback removes its listener and returns without action.

`cancel()` also increments the generation, making all in-flight callbacks immediately stale.

### switchDevice — Hot-Swap Path

When EQ is already running and the output device changes (e.g., profile switch from headphones to speakers, both with EQ), `switchDevice()` avoids tearing down and recreating the virtual device:

1. Increment generation (stales old callbacks)
2. Restore old real device volume from virtual device
3. Stop old AudioUnits (but do NOT hide virtual device or change system default)
4. If sample rates differ → enter `preparingSampleRate` via the same state machine
5. If rates match → `finishSwitchDevice()` directly
6. Create new AudioUnits wired to the new real device
7. Start IO — virtual device stays as system default throughout

Apps never see a device change — only the hardware endpoint changes.

### stopForTermination — Synchronous Bypass

At app quit (`applicationWillTerminate`), the state machine is bypassed entirely. `stopForTermination()` performs synchronous teardown because the process exits immediately after return. It blocks the main thread to restore the real device as system default — the only place in the codebase where blocking is acceptable.

### coreaudiod Restart Handling

Two listeners handle `coreaudiod` restarts:

1. **Direct Core Audio listener** (audio thread, immediate): Sets `gRenderStopped` atomically so render callbacks bail out before touching dead AudioUnits
2. **Combine subscriber** (main thread, debounced): Nils the AU references, resets state to `idle`, hides virtual device

The split ensures render callbacks are poisoned immediately (audio thread safety) while main-thread cleanup happens safely afterward.

## Audio Data Flow

When EQ is active:

```
┌─────────┐     ┌───────────────┐      ┌───────────────────┐
│  Apps   │────►│ Virtual Device │────►│ SharedAudioBuffer  │
│         │     │ (WriteMix)     │     │ (mmap'd file)      │
└─────────┘     └───────────────┘      └─────────┬─────────┘
                                                  │ read (no TCC)
                                                  ▼
                                       ┌───────────────────┐
                                       │ SharedAudioReader  │
                                       │ (mmap, in-app)     │
                                       └─────────┬─────────┘
                                                  │
                                                  ▼
                                       ┌───────────────────┐
                                       │ NBandEQ AudioUnit  │
                                       │ (10-band PEQ)      │
                                       └─────────┬─────────┘
                                                  │
                                                  ▼
                                       ┌───────────────────┐
                                       │ Output AUHAL       │
                                       │ (real hardware)     │
                                       └───────────────────┘
```

The shared memory path avoids TCC microphone permission — the driver writes audio into an mmap'd file, and the app reads directly from that file. No Core Audio input API is used on the app side.

## EQ Layers

```
Layer 1 — Device Correction (per-device, user-selected preset)
    │
    │  EQSettings.combine(base: L1, overlay: L2)
    ▼
Layer 2 — Content Mode Overlay (auto-detected: music/voice/movie/gaming)
    │
    │  If night mode active: EQSettings.combine(base: contentOverlay, overlay: nightOverlay)
    ▼
Effective EQ → applied to NBandEQ AudioUnit
```

- **Layer 1**: Stored in `EQStore`, keyed by device UID. User picks a preset (Harman, Diffuse Field, etc.) or creates custom bands.
- **Layer 2**: Stored in `SoundModesStore`. Auto-detected content mode overlay + optional night mode overlay. Additive combination.
- **Flat EQ** (`isFlat`): If the effective EQ has all bands at 0 dB, the virtual driver is not needed. The pipeline skips EQ entirely and routes directly to the real device.

## Key Design Decisions

**Why a single evaluateAndApply instead of per-event handlers?**
Every audio-relevant event can affect the same state (which device, which EQ, whether virtual driver is needed). Separate handlers would need to coordinate and could produce inconsistent intermediate states. A single function that recomputes everything from scratch is simpler and correct by construction.

**Why fingerprint dedup instead of diffing?**
The fingerprint is cheap to compute and compare. Diffing individual fields would require tracking what changed and conditionally applying — more complex for no benefit. The fingerprint naturally handles cases where multiple fields change simultaneously.

**Why event-driven state machine instead of async/await?**
Core Audio property changes are delivered via `AudioObjectPropertyListenerBlock`. These fire on Core Audio's internal thread and can fire synchronously during the call that causes the change (e.g., `show()` triggers a `kAudioHardwarePropertyDevices` notification inline). An async/await approach would need to bridge this, adding complexity. The listener + generation counter approach is minimal and matches Core Audio's native callback model.

**Why a generation counter instead of cancellation tokens?**
The generation counter is a single atomic integer checked in render callbacks (real-time audio thread). Cancellation tokens would require heap allocation and reference counting, which are not safe on the audio thread. The generation counter is lock-free and zero-allocation.
