import SwiftUI

/// Compact status dots showing which audio processing layers are currently active
/// (Device EQ, Content Mode, Night Mode, Pipeline running).
struct AudioStatusIndicators: View {
    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var soundModes = SoundModesStore.shared
    @ObservedObject private var engine = EQEngineService.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    private var outputUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    private var hasDeviceEQ: Bool {
        guard let uid = outputUID else { return false }
        return !eqStore.settings(for: uid).isFlat && !profileManager.isProcessingBypassed
    }

    private var hasContentMode: Bool {
        soundModes.isEnabled && soundModes.activeContentMode != .none
    }

    private var hasNightMode: Bool {
        soundModes.nightMode.isEnabled && soundModes.isNightModeActive
    }

    var body: some View {
        let items = buildItems()
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 3) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
    }

    private struct StatusItem { let label: String; let color: Color }

    private func buildItems() -> [StatusItem] {
        var result: [StatusItem] = []
        if hasDeviceEQ    { result.append(StatusItem(label: "EQ", color: .blue)) }
        if hasContentMode { result.append(StatusItem(label: soundModes.activeContentMode.displayName, color: .blue)) }
        if hasNightMode   { result.append(StatusItem(label: "Night", color: .indigo)) }
        if engine.isRunning { result.append(StatusItem(label: "Processing", color: .green)) }
        return result
    }
}
