# AudioProfiles Refactoring Plan

## How This Plan Was Made

Five agents reviewed the codebase independently:
1. **Structure map** — full file inventory (69 Swift files, ~15,200 lines)
2. **Views review** — identified fat views, missing component splits
3. **Services review** — identified god objects, coupling issues, dead code
4. **Tests review** — measured testability gaps (service layer: 3/10)
5. **Challenger** — rejected 5 over-engineering proposals; kept the grounded ones
6. **Synthesis** — produced the 6-phase plan below

## What Was Rejected (and Why)

| Rejected Proposal | Reason |
|---|---|
| Split ProfileManager into 3 classes (PipelineCoordinator + StateMachine + CRUD) | ProfileManager is 654 lines with one heavy method. Adding 2 new singletons redistributes complexity without removing it. Extract `performEvaluation` as a pure function if needed. |
| Two-phase service initialization protocol | One-time startup bug, already fixed. The current `DispatchQueue.main.async` defer is the right Cocoa pattern. A formal protocol adds ceremony for a solved problem. |
| Rewrite EQEngineService with async/await | Core Audio callbacks fire on the audio thread. Swift concurrency doesn't mix safely with real-time audio. The generation counter + listener pattern is battle-tested and correct. |
| SoundModesOrchestrator (third class to mediate two stores) | Two small classes (172 + 407 lines) with 3 cross-references. Zero bugs caused by the current design. A third mediator adds a file and two new communication channels for no gain. |
| ViewModels for every view (ConfigurationView, EQTabView, etc.) | Services are already `ObservableObject`. Adding wrapper classes that republish the same properties is pure indirection. ViewModels are only added where there is genuine business logic to extract (EQEditorView). |

## What Stays Permanently Unchanged

- `evaluateAndApply()` unidirectional pipeline — architecturally correct
- EQ state machine in `EQEngineService` — improved in place, not rewritten
- `AudioPipelineService.apply()` — correctly stateless, keep it that way
- `AudioProfilesDriver/` — working real-time audio driver, do not touch
- `Models/` layer — already clean; Hotkey backward-compat decoding must stay
- AppDelegate initialization order — load-bearing; the Task ordering matters
- Test file structure (standalone Swift scripts, no XCTest, no app imports)

---

## Phase 1 — Delete Dead Code

**Risk:** Zero. **Time:** 30 min.

Delete these files (all stubs with zero callers):
- `Services/HotkeyCoordinator.swift` (11 lines)
- `Services/HotkeyManager.swift` (8 lines)
- `Services/KeyCaptureService.swift` (6 lines)
- `Views/HotkeyConfigComponents.swift` (4 lines)
- `Views/DemoView.swift` (666 lines — confirm no reachable production path first)

Do NOT delete:
- `Models/Hotkey.swift` — struct needed for Codable backward compat with persisted user data
- `Profile.swift` hotkey decoding — same reason

**Verify:** `swift Tests/*.swift` all pass. `bash build.sh --no-driver` succeeds.

---

## Phase 2 — Fix Store→Pipeline Coupling

**Risk:** Medium. **Time:** 2h.

**Problem:** `EQStore`, `SoundModesStore`, `NightModeScheduler`, `ContentModeDetectionService`
all call `ProfileManager.shared.evaluateAndApply()` directly. This makes them impossible to
test in isolation and creates hidden dependency arrows pointing upward through the stack.

**Solution:** Add a `PassthroughSubject<Void, Never>` to `ProfileManager`. Stores send to the
subject instead of calling `evaluateAndApply()` directly. ProfileManager subscribes to it with
a 0ms debounce (coalesces rapid-fire events within the same run loop turn).

Files to change:
- `ProfileManager.swift` — add `pipelineInvalidationSubject`, subscribe in `initialize()`
- `EQStore.swift` — replace `ProfileManager.shared.evaluateAndApply()` (1 call)
- `SoundModesStore.swift` — replace (3 calls: `setEnabled`, `setOverlays`, `setNightMode`)
- `NightModeScheduler.swift` — replace (1 call)
- `ContentModeDetectionService.swift` — replace (1 call)

Keep as-is:
- `ProfileTriggerService` → `ProfileManager.evaluateAndApply()` — service-to-service call is
  acceptable; ProfileTriggerService is already a service, not a store.
- `EQEditorView.swift` → `ProfileManager.shared.evaluateAndApply()` — addressed in Phase 4.

**New tests to add:** In `ModelAndServiceTests.swift`, add pure-function tests that verify the
overlay computation logic in `SoundModesStore` doesn't require ProfileManager to exist. These
follow the existing `computeActiveOverlay()` pattern.

**Verify:** All 688 tests pass. App responds to sound mode changes, EQ edits, night mode
scheduling exactly as before.

---

## Phase 3 — Split ConfigurationView

**Risk:** Low. **Time:** 1.5h.

**Problem:** `ConfigurationView.swift` is 346 lines. The `profilesTab` computed property alone
is 200+ lines. `topDeviceNames()` and `deviceInfoView()` contain device-resolution logic that
belongs in `ProfileDisplayFormatter`.

**Files to create:**
- `Views/ProfilesTabView.swift` — extracted profiles tab body (~220 lines). Accepts
  `@ObservedObject profileManager: ProfileManager`. Handles profile list, add/edit/delete
  sheet state, launch-at-login, auto-switch toggle.

**Files to change:**
- `ProfileDisplayFormatter.swift` — add `topDeviceNames(for:connectedDevices:)` and
  `deviceInfoSummary(for:connectedDevices:)` as pure functions (no singleton access). Move
  the resolution logic from ConfigurationView verbatim.
- `ConfigurationView.swift` — becomes a ~100-line TabView wrapper instantiating the four tab
  views. All profile-list logic moves to ProfilesTabView.

**New tests to add:** In `ModelAndServiceTests.swift`, add:
- `testTopDeviceNamesPublicPrivateSame` — single priority device, both modes return same name
- `testTopDeviceNamesPublicPrivateDiffer` — two different devices per mode
- `testTopDeviceNamesEmpty` — no priorities → (nil, nil)

**Verify:** Profiles tab renders identically. All existing tests pass.

---

## Phase 4 — Decompose EQEditorView

**Risk:** Moderate (largest view, some business logic extraction). **Time:** 3h.

**Problem:** `EQEditorView.swift` is 1,220 lines. It mixes:
- Custom drawing (InteractiveEQGraphView — 465 lines, self-contained)
- Band parameter editing (BandParameterPanel — 120 lines, self-contained)
- Preset management (EQPresetPopover — 200 lines)
- EQ colors (20 lines of constants)
- Install sheet UI (115 lines)
- Business logic: `applySettings()` at lines 183-218 calls `EQStore`, `EQEngineService`,
  `EQInstallationService`, and `ProfileManager` directly — this is pipeline orchestration, not
  view logic.

**Target structure:** Create `Views/EQ/` subdirectory.

New files:
- `Views/EQ/InteractiveEQGraphView.swift` — 465-line drawing component, extracted as-is
- `Views/EQ/BandParameterPanel.swift` — 120-line parameter editor, extracted as-is
- `Views/EQ/EQPresetPopover.swift` — 200-line preset picker, extracted as-is
- `Views/EQ/EQLayerLegend.swift` — 70-line legend, extracted as-is
- `Views/EQ/EQColors.swift` — 20-line color constants
- `Views/EQ/EQDriverInstallSheet.swift` — 115 lines (includes FeatureRow, LevelMeterView, LevelBar)
- `ViewModels/EQEditorViewModel.swift` — NEW: holds `applySettings()`, `applyPreset()`,
  `switchToCustom()` business logic. Coordinates EQStore, EQEngineService, EQInstallationService.
  Instead of calling `EQEngineService.startPipeline()` directly from the view, the ViewModel
  calls `ProfileManager.shared.evaluateAndApply()` and lets the pipeline decide. The hot-update
  path (`updateSettings()`) can remain as an optimization when running on the same device.

`Views/EQEditorView.swift` — becomes ~80-line compositor: wires sub-views together, reads
from EQStore and EQEditorViewModel.

**New tests to add:** In `ModelAndServiceTests.swift`, add pure function tests for the
`applySettings` decision logic (mirrors the existing `decidePipelineAction` pattern):
- `testApplySettingsFlatStopsEQ` — flat EQ → pipeline action is `stop`
- `testApplySettingsSameDeviceHotUpdates` — non-flat, same device → hot update
- `testApplySettingsDifferentDeviceSwitches` — non-flat, different device → switch

**Verify:** EQ tab works end-to-end: preset picker, band sliders, graph interaction, driver
install sheet. All tests pass.

---

## Phase 5 — Split ProfileMenuView and EQTabView

**Risk:** Low (mechanical splits). **Time:** 2h.

**ProfileMenuView.swift** (419 lines): Three sub-components are already written as separate
structs in the same file. Extract them:
- `Views/ContentModesRow.swift`
- `Views/AudioStatusIndicators.swift`
- `Views/EQQuickAccessRow.swift`

`ProfileMenuView.swift` → ~180 lines (the main popover layout).

**EQTabView.swift** (312 lines): Device selection state (`outputDevices`, `selectedDeviceID`,
`refreshDevices()`, `autoSelectDevice()`) belongs in a ViewModel:
- `ViewModels/EQTabViewModel.swift` — owns device list state, subscribes to
  `AudioDeviceMonitor` device change events, auto-selects the active device.
- `Views/EQ/EQInstallBannerView.swift` — extract the banner variants (install, repair, update)
  which are 75+ lines of near-duplicate code with a clear shared layout.

**Verify:** Menu bar popover renders all rows. EQ tab device picker and banners work. Tests pass.

---

## Phase 6 — Protocol Abstractions for Core Services

**Risk:** Low (additive only). **Time:** 2h.

**Goal:** Enable future unit testing of services that currently require Core Audio to run.
No behavior changes — purely additive conformances.

New files in `Services/Protocols/`:
- `AudioDeviceControlServiceProtocol.swift`
  ```swift
  protocol AudioDeviceControlServiceProtocol {
      func getDefaultOutputDevice() -> AudioDevice?
      func getDefaultInputDevice() -> AudioDevice?
      @discardableResult func setDefaultOutputDevice(_ device: AudioDevice) -> Bool
      @discardableResult func setDefaultInputDevice(_ device: AudioDevice) -> Bool
  }
  ```
- `ProfilePersistenceServiceProtocol.swift`
  ```swift
  protocol ProfilePersistenceServiceProtocol {
      func loadProfiles() -> [Profile]
      @discardableResult func saveProfiles(_ profiles: [Profile]) -> Bool
  }
  ```
- `AudioDeviceProviding.swift`
  ```swift
  protocol AudioDeviceProviding {
      func getCurrentDevices() -> [AudioDevice]
  }
  ```

Files to change (add conformance only, no logic changes):
- `AudioDeviceControlService.swift` — add `: AudioDeviceControlServiceProtocol`
- `ProfilePersistenceService.swift` — add `: ProfilePersistenceServiceProtocol`
- `AudioDeviceFactory.swift` — add `: AudioDeviceProviding`
- `ProfileManager.swift` — change `persistenceService` property type to the protocol
- `AudioPipelineService.swift` — change `deviceControlService` property type to the protocol

**New tests to add:** In `ModelAndServiceTests.swift`:
- `testProfilePersistenceRoundTripWithMock` — `MockProfilePersistenceService` stores in memory;
  verify save→load preserves all profile fields
- `testAudioPipelineServiceWithMockControl` — mock device control verifies `setDefaultOutputDevice`
  is called with the correct device in the `direct` pipeline action case

**Verify:** All 688 tests pass. Build succeeds. No runtime behavior changes.

---

## Phase Sequencing Summary

| Phase | Files Changed | New Files | Risk | Tests Added |
|-------|--------------|-----------|------|-------------|
| 1 — Delete dead code | 5 deleted | 0 | Zero | 0 |
| 2 — Fix store coupling | 6 | 0 | Medium | 3 |
| 3 — Split ConfigurationView | 2 | 1 | Low | 3 |
| 4 — Decompose EQEditorView | 1 | 7 | Moderate | 3 |
| 5 — Split ProfileMenuView/EQTab | 2 | 5 | Low | 0 |
| 6 — Protocol abstractions | 5 | 3 | Low | 2 |

**Rule after every phase:** Run `swift Tests/BehaviorTests.swift && swift Tests/PipelineTests.swift && swift Tests/ModelAndServiceTests.swift && swift Tests/SharedAudioTests.swift` — all must pass before moving to the next phase.
