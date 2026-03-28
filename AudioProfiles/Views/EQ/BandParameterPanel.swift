import SwiftUI

/// Shows gain and bandwidth sliders for the currently selected EQ band.
struct BandParameterPanel: View {
    let band: EQBand
    let bandIndex: Int
    let bandColor: Color
    let onGainChange: (Float) -> Void
    let onBandwidthChange: (Float) -> Void

    // Widths match EQEditorView.dbSliderRow for visual alignment
    private let labelWidth: CGFloat = 52
    private let valueWidth: CGFloat = 58

    var body: some View {
        VStack(spacing: 6) {
            header
            gainSlider
            bandwidthSlider
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(bandColor)
                .frame(width: 10, height: 10)
            Text("Band \(bandIndex + 1)")
                .font(.caption)
                .fontWeight(.medium)
            Text("·").foregroundColor(.secondary)
            Text(band.filterType.label)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            Text("·").foregroundColor(.secondary)
            Text(frequencyLabel(band.frequency))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.leading, 2)
    }

    private var gainSlider: some View {
        HStack(spacing: 8) {
            Text("Gain")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { Double(band.gain) },
                    set: { onGainChange(snapToZero(Float($0))) }
                ),
                in: Double(EQSettings.gainRange.lowerBound)...Double(EQSettings.gainRange.upperBound),
                step: 0.1
            )
            .tint(bandColor)

            Text(dbLabel(band.gain))
                .font(.caption.monospacedDigit())
                .foregroundColor(band.gain == 0 ? .secondary : .primary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private var bandwidthSlider: some View {
        HStack(spacing: 8) {
            Text("Width")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { Double(band.bandwidth) },
                    set: { onBandwidthChange(Float($0)) }
                ),
                in: Double(EQSettings.bandwidthRange.lowerBound)...Double(EQSettings.bandwidthRange.upperBound),
                step: 0.1
            )
            .tint(bandColor)

            Text(String(format: "%.1f oct", band.bandwidth))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    // MARK: - Helpers

    private func snapToZero(_ value: Float) -> Float { abs(value) < 0.3 ? 0 : value }

    private func frequencyLabel(_ freq: Float) -> String {
        freq >= 1000 ? String(format: "%g kHz", freq / 1000) : String(format: "%g Hz", freq)
    }

    private func dbLabel(_ gain: Float) -> String {
        gain == 0 ? "0.0 dB" : String(format: "%+.1f dB", gain)
    }
}
