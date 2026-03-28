import SwiftUI

/// Per-device EQ editor — wires the interactive graph, preset picker, and band controls together.
///
/// All business logic (EQ store writes, pipeline decisions) lives in EQEditorViewModel.
/// All drawing lives in InteractiveEQGraphView.
/// All sub-components are in Views/EQ/.
struct EQEditorView: View {

    let deviceUID: String
    let deviceName: String

    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var soundModesStore = SoundModesStore.shared
    @StateObject private var vm = EQEditorViewModel()

    @State private var selectedBand: Int? = nil
    @State private var showingPresetPicker = false

    private var settings: EQSettings { eqStore.settings(for: deviceUID) }
    private var mode: EQMode { eqStore.mode(for: deviceUID) }

    private var activePresetHeadphone: EQPresetHeadphone? {
        guard let name = mode.presetHeadphoneName else { return nil }
        return EQPresetService.shared.headphone(named: name)
    }

    var body: some View {
        VStack(spacing: 8) {
            InteractiveEQGraphView(
                settings: settings,
                selectedBand: $selectedBand,
                frequencyResponse: activePresetHeadphone?.frequencyResponse,
                contentOverlay: soundModesStore.isEnabled ? soundModesStore.activeOverlay() : nil,
                onChange: { vm.applySettingsAsCustom($0, deviceUID: deviceUID, mode: mode) }
            )

            EQLayerLegend(deviceUID: deviceUID)

            presetRow

            if !mode.isPreset {
                dbSliderRow(
                    label: "Preamp",
                    value: settings.preamp,
                    range: EQSettings.preampRange,
                    onChange: { vm.applySettingsAsCustom(settings.withPreamp($0), deviceUID: deviceUID, mode: mode) }
                )

                if let idx = selectedBand, idx < settings.bands.count {
                    BandParameterPanel(
                        band: settings.bands[idx],
                        bandIndex: idx,
                        bandColor: EQColors.color(for: idx),
                        onGainChange: { vm.applySettingsAsCustom(settings.withBand(at: idx, gain: $0), deviceUID: deviceUID, mode: mode) },
                        onBandwidthChange: { vm.applySettingsAsCustom(settings.withBand(at: idx, bandwidth: $0), deviceUID: deviceUID, mode: mode) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    // MARK: - Preset Row

    private var presetRow: some View {
        HStack(spacing: 6) {
            Text("Preset")
                .font(.caption)
                .foregroundColor(.secondary)

            Button { showingPresetPicker = true } label: {
                HStack(spacing: 4) {
                    if case .preset(let name, let target) = mode {
                        Text(name).font(.caption).fontWeight(.medium).lineLimit(1)
                        Text("·").font(.caption).foregroundColor(.secondary)
                        Text(target).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    } else {
                        Text("Custom").font(.caption).fontWeight(.medium)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPresetPicker, arrowEdge: .bottom) {
                EQPresetPopover(
                    deviceName: deviceName,
                    mode: mode,
                    onApplyPreset: { name, target, settings in
                        vm.applyPreset(headphoneName: name, target: target, settings: settings, deviceUID: deviceUID)
                        showingPresetPicker = false
                    },
                    onSwitchToCustom: {
                        vm.switchToCustom(deviceUID: deviceUID)
                        showingPresetPicker = false
                    }
                )
            }

            Spacer()
        }
    }

    // MARK: - Shared dB Slider Row

    private func dbSliderRow(
        label: String,
        value: Float,
        range: ClosedRange<Float>,
        tint: Color? = nil,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(snapToZero(Float($0))) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 0.1
            )
            .tint(tint)

            Text(dbLabel(value))
                .font(.caption.monospacedDigit())
                .foregroundColor(value == 0 ? .secondary : .primary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func snapToZero(_ value: Float) -> Float { abs(value) < 0.3 ? 0 : value }
    private func dbLabel(_ gain: Float) -> String { gain == 0 ? "0.0 dB" : String(format: "%+.1f dB", gain) }
}
