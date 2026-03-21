import SwiftUI

// MARK: - EQEditorView
// Per-device EQ editor used in the EQ tab.
// Reads and writes through EQStore (global, not per-profile).

struct EQEditorView: View {

    let deviceUID: String
    let deviceName: String

    @ObservedObject private var eqStore = EQStore.shared

    private var settings: EQSettings { eqStore.settings(for: deviceUID) }

    // Note: expansion/collapse is owned by EQTabView; this view renders content only.

    var body: some View {
        EQBandEditorView(settings: settings) { newSettings in
            let wasFlat = settings.isFlat
            AppLogger.error("[EQ-DIAG] onChange: wasFlat=\(wasFlat) newIsFlat=\(newSettings.isFlat) engineRunning=\(EQEngineService.shared.isRunning) targetUID=\(EQEngineService.shared.targetDeviceUID ?? "nil") deviceUID=\(deviceUID)")
            eqStore.setSettings(newSettings, for: deviceUID)

            if EQEngineService.shared.isRunning,
               EQEngineService.shared.targetDeviceUID == deviceUID {
                // Engine already running for this device → live-update bands
                Task { @MainActor in EQEngineService.shared.updateSettings(newSettings) }
            } else if !newSettings.isFlat && !EQEngineService.shared.isRunning && isCurrentOutputDevice {
                // Settings are non-flat, no engine running, device is the active output → engage
                AppLogger.error("[EQ-DIAG] Engaging EQ for \(deviceName)")
                engageEQ(settings: newSettings)
            }
        }
        onReset: {
            eqStore.setSettings(.flat, for: deviceUID)
            // If the engine is running for this device, stop it and switch back
            if EQEngineService.shared.isRunning,
               EQEngineService.shared.targetDeviceUID == deviceUID {
                EQEngineService.shared.stopSafe(switchTo: deviceUID)
            }
        }
    }

    /// Whether this device is the current system default output.
    private var isCurrentOutputDevice: Bool {
        AudioDeviceControlService().getDefaultOutputDevice()?.id == deviceUID
    }

    /// Start the EQ engine for this device if the driver is installed.
    private func engageEQ(settings: EQSettings) {
        AppLogger.error("[EQ-DIAG] engageEQ called, isInstalled=\(EQInstallationService.shared.isInstalled) installState=\(EQInstallationService.shared.installState)")
        guard EQInstallationService.shared.isInstalled else {
            AppLogger.error("[EQ-DIAG] Driver NOT installed — aborting engageEQ")
            return
        }
        EQEngineService.shared.start(
            realDeviceUID: deviceUID,
            settings: settings,
            virtualDeviceName: "\(deviceName) EQ"
        )
    }
}

// MARK: - EQCurveView
// Draws a smooth frequency-response curve from 20 Hz to 20 kHz.
// Band 0 = low shelf, band 9 = high shelf, bands 1-8 = parametric (Gaussian bell).

struct EQCurveView: View {
    let settings: EQSettings

    private let minFreq:      Double = 20
    private let maxFreq:      Double = 20_000
    private let displayRange: Double = 13     // ±13 dB visible (slight padding beyond ±12)
    private let sampleCount:  Int    = 240

    var body: some View {
        Canvas { ctx, size in
            drawGrid(ctx, size: size)
            drawCurve(ctx, size: size)
            drawBandTicks(ctx, size: size)
            drawLabels(ctx, size: size)
        }
        .frame(height: 88)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: Coordinate helpers

    private func xPos(_ freq: Double, w: CGFloat) -> CGFloat {
        CGFloat(log10(freq / minFreq) / log10(maxFreq / minFreq)) * w
    }

    private func yPos(_ gain: Double, h: CGFloat) -> CGFloat {
        CGFloat((1 - (gain / displayRange + 1) * 0.5)) * h
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        let h = size.height
        let w = size.width

        // ±6 dB (faint)
        for db in [-6.0, 6.0] {
            let lineY = yPos(db, h: h)
            var p = Path(); p.move(to: .init(x: 0, y: lineY)); p.addLine(to: .init(x: w, y: lineY))
            ctx.stroke(p, with: .color(.primary.opacity(0.07)), lineWidth: 0.5)
        }
        // 0 dB (slightly more visible)
        let zeroY = yPos(0, h: h)
        var z = Path(); z.move(to: .init(x: 0, y: zeroY)); z.addLine(to: .init(x: w, y: zeroY))
        ctx.stroke(z, with: .color(.primary.opacity(0.2)), lineWidth: 0.5)
    }

    private func drawCurve(_ ctx: GraphicsContext, size: CGSize) {
        let h = size.height
        let w = size.width
        let zeroY = yPos(0, h: h)

        let pts: [CGPoint] = (0...sampleCount).map { i in
            let t    = Double(i) / Double(sampleCount)
            let freq = minFreq * pow(maxFreq / minFreq, t)
            return CGPoint(x: xPos(freq, w: w), y: yPos(totalGain(at: freq), h: h))
        }

        // Fill between curve and zero line
        var fill = Path()
        fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
        pts.forEach { fill.addLine(to: $0) }
        fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(.accentColor.opacity(0.13)))

        // Stroke
        var stroke = Path()
        stroke.move(to: pts[0])
        pts.dropFirst().forEach { stroke.addLine(to: $0) }
        ctx.stroke(stroke, with: .color(.accentColor.opacity(0.8)), lineWidth: 1.5)
    }

    /// Small tick marks at the bottom of the curve aligned to each band's frequency.
    private func drawBandTicks(_ ctx: GraphicsContext, size: CGSize) {
        for band in settings.bands {
            let bx = xPos(Double(band.frequency), w: size.width)
            var p = Path()
            p.move(to: CGPoint(x: bx, y: size.height - 4))
            p.addLine(to: CGPoint(x: bx, y: size.height))
            ctx.stroke(p, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
        }
    }

    /// dB labels on the left edge.
    private func drawLabels(_ ctx: GraphicsContext, size: CGSize) {
        let h = size.height
        for (db, label) in [(-12.0, "-12"), (0.0, "0"), (12.0, "+12")] {
            let y = yPos(db, h: h)
            ctx.draw(
                Text(label).font(.system(size: 7)).foregroundColor(.secondary.opacity(0.6)),
                at: CGPoint(x: 14, y: y),
                anchor: .center
            )
        }
    }

    // MARK: Signal processing (visual approximation)

    private func totalGain(at freq: Double) -> Double {
        var gain = Double(settings.preamp)
        let bands = settings.bands

        for (i, band) in bands.enumerated() {
            let g = Double(band.gain)
            guard abs(g) >= 0.01 else { continue }
            let f0 = Double(band.frequency)
            let bw = max(Double(band.bandwidth), 0.1)
            let logRatio = log2(freq / f0)

            switch i {
            case 0:                                     // Low shelf
                gain += g * (1.0 - sigmoid(logRatio * 2.5 / bw))
            case bands.count - 1:                       // High shelf
                gain += g * sigmoid(logRatio * 2.5 / bw)
            default:                                    // Parametric bell
                let sigma = bw / 2.0
                gain += g * exp(-0.5 * pow(logRatio / sigma, 2))
            }
        }
        return max(-displayRange, min(displayRange, gain))
    }

    private func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }
}

// MARK: - EQBandEditorView

struct EQBandEditorView: View {
    let settings: EQSettings
    let onChange: (EQSettings) -> Void
    let onReset:  () -> Void

    private let gainRange:    ClosedRange<Float> = EQSettings.gainRange
    private let sliderHeight: CGFloat            = 110

    var body: some View {
        VStack(spacing: 8) {
            // Preamp row
            HStack(spacing: 6) {
                Text("Preamp")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 46, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(settings.preamp) },
                        set: { onChange(settings.withPreamp(Float($0))) }
                    ),
                    in: Double(gainRange.lowerBound)...Double(gainRange.upperBound),
                    step: 0.1
                )

                Text(gainLabel(settings.preamp))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(settings.preamp == 0 ? .secondary : .primary)
                    .frame(width: 44, alignment: .trailing)
            }

            // Frequency response curve
            EQCurveView(settings: settings)

            // Band sliders
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(settings.bands.enumerated()), id: \.offset) { index, band in
                    BandSliderView(
                        frequency: band.frequency,
                        gain: band.gain,
                        gainRange: gainRange,
                        sliderHeight: sliderHeight,
                        onChange: { onChange(settings.withBand(at: index, gain: $0)) }
                    )
                }
            }

            // Reset — always present so layout never jumps; faded when already flat
            HStack {
                Spacer()
                Button("Reset to flat") { onReset() }
                    .font(.caption)
                    .foregroundColor(settings.isFlat ? .secondary.opacity(0.3) : .secondary)
                    .buttonStyle(.plain)
                    .disabled(settings.isFlat)
            }
        }
        .padding(.top, 4)
    }

    private func gainLabel(_ gain: Float) -> String {
        gain == 0 ? "0.0 dB" : String(format: "%+.1f dB", gain)
    }
}

// MARK: - BandSliderView

struct BandSliderView: View {
    let frequency: Float
    let gain: Float
    let gainRange: ClosedRange<Float>
    let sliderHeight: CGFloat
    let onChange: (Float) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(gainText)
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(gain == 0 ? .secondary : .primary)
                .frame(height: 12)

            Slider(
                value: Binding(
                    get: { Double(gain) },
                    set: { onChange(Float($0)) }
                ),
                in: Double(gainRange.lowerBound)...Double(gainRange.upperBound),
                step: 0.1
            )
            .rotationEffect(.degrees(-90))
            .frame(width: sliderHeight)
            .frame(width: 28, height: sliderHeight)
            .clipped()

            Text(frequencyLabel)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var gainText: String {
        gain == 0 ? "0" : String(format: "%+.1f", gain)
    }

    private var frequencyLabel: String {
        frequency >= 1000
            ? String(format: "%gk", frequency / 1000)
            : String(format: "%g", frequency)
    }
}

// MARK: - EQInstallPromptView

struct EQInstallPromptView: View {
    let deviceName: String
    @Binding var showingSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("EQ requires a one-time driver installation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button("Install Audio Component…") { showingSheet = true }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - EQDriverInstallSheet

struct EQDriverInstallSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var installService = EQInstallationService.shared
    @State private var isInstalling = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("EQ Audio Component")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "headphones",   text: "Apply per-device EQ curves to any output")
                FeatureRow(icon: "eye.slash",    text: "Invisible when not in use — no clutter")
                FeatureRow(icon: "lock.shield",  text: "Runs inside macOS audio system, no background process")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Text("This installs a small audio processing component into macOS's audio system (*/Library/Audio/Plug-Ins/HAL/*). You'll be asked for your admin password once. No restart is required.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                Button(isInstalling ? "Installing…" : "Install Component") { performInstall() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func performInstall() {
        isInstalling = true
        errorMessage = nil
        installService.install { success in
            isInstalling = false
            if success {
                isPresented = false
            } else if installService.installState == .notLoaded {
                // File was copied but coreaudiod is still loading the driver —
                // close the sheet; the repair banner in the EQ tab will guide the user.
                isPresented = false
            } else {
                errorMessage = "Installation failed or was cancelled. Please try again."
            }
        }
    }
}

// MARK: - FeatureRow

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundColor(.blue)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
