import SwiftUI

/// Editor sheet for Night Mode's EQ overlay.
/// Reuses the same interactive graph and band controls as the main EQ editor.
struct NightModeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = SoundModesStore.shared

    @State private var settings: EQSettings = .flat
    @State private var selectedBand: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "moon.fill")
                    .foregroundColor(.indigo)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Night Mode — EQ Overlay")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Reduces bass and boosts clarity for quiet listening")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Reset to Default") {
                    settings = NightModeConfig.default.overlay
                    saveSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Interactive graph
            InteractiveEQGraphView(
                settings: settings,
                selectedBand: $selectedBand,
                frequencyResponse: nil,
                contentOverlay: nil,
                onChange: { newSettings in
                    settings = newSettings
                    saveSettings()
                }
            )
            .frame(height: 240)

            // Preamp slider
            HStack(spacing: 8) {
                Text("Preamp")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { Double(settings.preamp) },
                        set: {
                            settings.preamp = Float($0)
                            saveSettings()
                        }
                    ),
                    in: Double(EQSettings.gainRange.lowerBound)...Double(EQSettings.gainRange.upperBound),
                    step: 0.1
                )

                Text(String(format: "%+.1f dB", settings.preamp))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(settings.preamp == 0 ? .secondary : .primary)
                    .frame(width: 58, alignment: .trailing)
            }

            // Selected band parameters
            if let idx = selectedBand, idx < settings.bands.count {
                BandParameterPanel(
                    band: settings.bands[idx],
                    bandIndex: idx,
                    bandColor: bandColor(for: idx),
                    onGainChange: { newGain in
                        settings.bands[idx].gain = newGain
                        saveSettings()
                    },
                    onBandwidthChange: { newBW in
                        settings.bands[idx].bandwidth = newBW
                        saveSettings()
                    }
                )
            }

            // Done button
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 530)
        .onAppear {
            settings = store.nightMode.overlay
        }
    }

    private func saveSettings() {
        var config = store.nightMode
        config.overlay = settings
        store.setNightMode(config)
    }

    private func bandColor(for index: Int) -> Color {
        let colors: [Color] = [.cyan, .blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .mint]
        return colors[index % colors.count]
    }
}
