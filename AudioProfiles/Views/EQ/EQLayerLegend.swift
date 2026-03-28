import SwiftUI

/// Shows which EQ layers are active: Device EQ (L1) and content/night overlay (L2+L3).
struct EQLayerLegend: View {
    let deviceUID: String
    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var soundModes = SoundModesStore.shared

    private var hasDeviceEQ: Bool { !eqStore.settings(for: deviceUID).isFlat }
    private var isBypassed: Bool { eqStore.isBypassed(for: deviceUID) }
    private var hasOverlay: Bool { !soundModes.activeOverlay().isFlat }

    var body: some View {
        HStack(spacing: 12) {
            // L1: Device EQ
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(hasDeviceEQ && !isBypassed ? 0.85 : 0.3))
                    .frame(width: 16, height: 2)
                Text("Device EQ")
                    .font(.caption2)
                    .foregroundColor(hasDeviceEQ && !isBypassed ? .primary : .secondary)
            }

            // L2+L3: Overlay
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.teal.opacity(hasOverlay ? 0.7 : 0.3))
                    .frame(width: 16, height: 2)
                Text(overlayLabel)
                    .font(.caption2)
                    .foregroundColor(hasOverlay ? .primary : .secondary)
            }

            // Bypass indicator
            if isBypassed {
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                    Text("Bypassed")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var overlayLabel: String {
        var parts: [String] = []
        if soundModes.isEnabled && soundModes.activeContentMode != .none {
            parts.append(soundModes.activeContentMode.displayName)
        }
        if soundModes.nightMode.isEnabled && soundModes.isNightModeActive {
            parts.append("Night")
        }
        return parts.isEmpty ? "Overlay" : parts.joined(separator: " + ")
    }
}
