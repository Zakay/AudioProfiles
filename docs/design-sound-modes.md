# Sound Modes — Design Document

**Target**: macOS 26+ (Tahoe) — simplifies implementation, Foundation Models guaranteed available

## Overview

Two-layer EQ system:
- **Layer 1 (existing)**: Device correction — per-device presets (Harman, Diffuse Field, etc.)
- **Layer 2 (new)**: Content mode overlay — adjusts EQ based on what's playing

Final EQ = device correction + content overlay. Virtual driver always active when feature is enabled.

## Content Modes (mutually exclusive, auto-detected)

| Mode | Trigger | EQ Overlay |
|---|---|---|
| Music | Default / music apps detected | None (baseline) |
| Voice/Meeting | App has active mic input | Boost 2-4kHz, cut <200Hz |
| Movie | Video app + long duration (>30min) | Bass boost, 3-5kHz dialogue clarity |
| Podcast | Podcast app detected | Speech presence, less aggressive than Voice |
| Gaming | Game app detected | Spatial/immersive adjustments |

## Environment Mode (stacks on top of content mode)

| Mode | Trigger | Effect |
|---|---|---|
| Night | Time-based quiet hours (user-configured) | Compress dynamic range, reduce bass |

## Detection Signals (no manual app assignment table needed)

1. **Mic active** (`kAudioProcessPropertyIsRunningInput`) → Voice/Meeting. Most critical case, zero config.
2. **Now Playing metadata** — media type, duration, app bundle ID via `MRMediaRemoteGetNowPlayingInfo`
3. **Apple Foundation Models** — classify unknown apps by name/description on-device
4. **User override** — quick submenu in popover if auto-detection gets it wrong

## Foundation Models — Additional Uses

### Preset Auto-Matching
When new device connects:
1. System reports device name (e.g., "LE-JBL Flip 6")
2. Foundation Model extracts brand ("JBL"), model ("Flip 6"), type ("Bluetooth speaker")
3. Search preset database for closest match
4. Suggest to user → confirm or pick alternative

Eliminates manual browsing through 4800+ presets.

### App Classification
For apps not in known-apps list and without clear Now Playing metadata:
- Ask Foundation Model: "Is 'IINA' a music player, video player, or game?" → "Video player" → Movie mode

## UI/UX Design

### Settings Window — New "Sound Modes" Tab

```
[ Profiles ]  [ EQ ]  [ Sound Modes ]
```

**Layout (top to bottom):**
- **Master toggle** — OFF by default. When off, feature is completely invisible elsewhere.
- **Content Modes list** — Music, Voice, Movie, Podcast, Gaming. Each with [Edit] for overlay EQ.
- **Environment section** — Night Mode with quiet hours time picker + auto-enable checkbox.
- **Detection status** — shows what's currently detected and why (e.g., "FaceTime detected with mic → Voice mode")

### Menu Bar Popover — One New Row (only when enabled)

```
♫ Voice mode (FaceTime)
```

Click opens submenu: Auto, Music, Voice, Movie, Podcast, Gaming + Night mode checkbox.

### EQ Tab — Combined Curve

When content overlay active:
- Second dashed line on graph showing combined result
- Status line: "Active overlay: Voice mode (via FaceTime) [Override ▾]"

### Mode Overlay Editor (simplified EQ)

5-6 broad bands with sliders — not full parametric:
- Low Cut, Low Mid, Mid, Presence, Brilliance
- Optional dynamic range compression slider
- Preset per mode with Reset to Default

## Architecture

### New Services
- `ContentModeService` — watches Now Playing + mic state, publishes active content mode via Combine
- Uses `kAudioHardwarePropertyProcessObjectList` for mic detection
- Uses `MRMediaRemoteGetNowPlayingInfo` for app/media detection
- Uses Foundation Models for unknown app classification

### EQ Pipeline Change
- Virtual driver always active when Sound Modes enabled (even if no device correction)
- `EQEngineService` sums Layer 1 + Layer 2 gains per band before applying
- If sum clips, auto-reduce preamp

### Data Model
- `ContentModeOverlay` struct — simplified EQ delta + compression params
- Stored in `EQStore`, keyed by mode name (device-independent)
- `SoundModesSettings` — master toggle, quiet hours, manual override state

## Priority Signal Hierarchy

1. **User manual pin** — always wins
2. **Mic active** — Voice/Meeting (highest auto-detect priority)
3. **Now Playing metadata** — media type if reported
4. **Foundation Model classification** — for unknown apps
5. **Default** — Music (no overlay)
