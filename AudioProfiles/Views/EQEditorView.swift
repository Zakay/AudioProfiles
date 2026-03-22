import SwiftUI

// MARK: - EQEditorView
// Per-device EQ editor with interactive frequency response graph.
// Reads and writes through EQStore (global, not per-profile).

struct EQEditorView: View {

    let deviceUID: String
    let deviceName: String

    @ObservedObject private var eqStore = EQStore.shared
    @State private var selectedBand: Int? = nil
    @State private var showingPresetPicker = false

    private var settings: EQSettings { eqStore.settings(for: deviceUID) }
    private var mode: EQMode { eqStore.mode(for: deviceUID) }

    /// Active preset's headphone data (for FR curve drawing)
    private var activePresetHeadphone: EQPresetHeadphone? {
        guard let name = mode.presetHeadphoneName else { return nil }
        return EQPresetService.shared.headphone(named: name)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Interactive frequency response graph
            InteractiveEQGraphView(
                settings: settings,
                selectedBand: $selectedBand,
                frequencyResponse: activePresetHeadphone?.frequencyResponse,
                onChange: applySettingsAsCustom
            )

            // Preset row — compact single line
            presetRow

            // Preamp + band controls (custom mode only)
            if !mode.isPreset {
                dbSliderRow(
                    label: "Preamp",
                    value: settings.preamp,
                    range: EQSettings.preampRange,
                    onChange: { applySettingsAsCustom(settings.withPreamp($0)) }
                )

                if let idx = selectedBand, idx < settings.bands.count {
                    BandParameterPanel(
                        band: settings.bands[idx],
                        bandIndex: idx,
                        bandColor: EQColors.color(for: idx),
                        onGainChange: { applySettingsAsCustom(settings.withBand(at: idx, gain: $0)) },
                        onBandwidthChange: { applySettingsAsCustom(settings.withBand(at: idx, bandwidth: $0)) }
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

            Button {
                showingPresetPicker = true
            } label: {
                HStack(spacing: 4) {
                    if case .preset(let name, let target) = mode {
                        Text(name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(target)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Custom")
                            .font(.caption)
                            .fontWeight(.medium)
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
                        applyPreset(headphoneName: name, target: target, settings: settings)
                        showingPresetPicker = false
                    },
                    onSwitchToCustom: {
                        switchToCustom()
                        showingPresetPicker = false
                    }
                )
            }

            Spacer()
        }
    }

    // MARK: - Shared dB slider row

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

    /// Snap values within ±0.3 dB to exactly 0
    private func snapToZero(_ value: Float) -> Float {
        abs(value) < 0.3 ? 0 : value
    }

    // MARK: - Actions

    /// Apply settings and automatically switch to custom mode (user edited manually).
    private func applySettingsAsCustom(_ newSettings: EQSettings) {
        if mode.isPreset {
            eqStore.setMode(.custom, for: deviceUID)
        }
        applySettings(newSettings)
    }

    /// Apply a preset: set the mode and EQ settings together.
    private func applyPreset(headphoneName: String, target: String, settings: EQSettings) {
        eqStore.setMode(.preset(headphoneName: headphoneName, target: target), for: deviceUID)
        applySettings(settings)
    }

    /// Switch to custom mode without changing EQ values.
    private func switchToCustom() {
        eqStore.setMode(.custom, for: deviceUID)
    }

    private func applySettings(_ newSettings: EQSettings) {
        eqStore.setSettings(newSettings, for: deviceUID)

        let uid = deviceUID
        let name = deviceName

        Task { @MainActor in
            guard EQInstallationService.shared.isInstalled else { return }

            if EQEngineService.shared.isRunning,
               EQEngineService.shared.targetDeviceUID == uid {
                // Same device — hot update EQ bands
                EQEngineService.shared.updateSettings(newSettings)
            } else if EQEngineService.shared.isRunning {
                // Running on different device — switch to this one
                EQEngineService.shared.switchDevice(
                    realDeviceUID: uid,
                    settings: newSettings,
                    virtualDeviceName: "\(name) EQ"
                )
            } else if !newSettings.isFlat {
                // Not running — start EQ for this device
                EQEngineService.shared.start(
                    realDeviceUID: uid,
                    settings: newSettings,
                    virtualDeviceName: "\(name) EQ"
                )
            }
        }
    }

    private func dbLabel(_ gain: Float) -> String {
        gain == 0 ? "0.0 dB" : String(format: "%+.1f dB", gain)
    }
}

// MARK: - EQ Preset Popover

struct EQPresetPopover: View {
    let deviceName: String
    let mode: EQMode
    let onApplyPreset: (String, String, EQSettings) -> Void
    let onSwitchToCustom: () -> Void

    @State private var searchText = ""
    @State private var selectedHeadphone: EQPresetHeadphone? = nil

    private let presetService = EQPresetService.shared

    private var searchResults: [EQPresetHeadphone] {
        if searchText.isEmpty {
            return presetService.suggestions(forDeviceName: deviceName, limit: 40)
        }
        return presetService.search(query: searchText, limit: 40)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Search audio devices…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        if let first = searchResults.first {
                            selectedHeadphone = first
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        selectedHeadphone = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if let hp = selectedHeadphone {
                // Target selection for chosen headphone
                targetSection(for: hp)
            } else {
                // Custom option at top
                Button {
                    onSwitchToCustom()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .frame(width: 16)
                        Text("Custom")
                            .font(.system(size: 12))
                            .fontWeight(mode.isPreset ? .regular : .medium)
                        Spacer()
                        if !mode.isPreset {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()

                // Search results
                if searchResults.isEmpty && !searchText.isEmpty {
                    Text("No devices found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(10)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(searchResults) { hp in
                                Button {
                                    selectedHeadphone = hp
                                    searchText = hp.name
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(hp.name)
                                                .font(.system(size: 12))
                                                .foregroundColor(.primary)
                                            Text(hp.category)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if mode.presetHeadphoneName == hp.name {
                                            Image(systemName: "checkmark")
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 360)
        .onAppear {
            // If we already have a preset selected, pre-fill
            if let name = mode.presetHeadphoneName,
               let hp = presetService.headphone(named: name) {
                selectedHeadphone = hp
                searchText = hp.name
            }
        }
    }

    @ViewBuilder
    private func targetSection(for hp: EQPresetHeadphone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back button
            Button {
                selectedHeadphone = nil
                searchText = ""
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                    Text("Back")
                        .font(.system(size: 11))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Divider()

            // Headphone name header
            VStack(alignment: .leading, spacing: 2) {
                Text(hp.name)
                    .font(.system(size: 12, weight: .medium))
                Text("\(hp.brand) · \(hp.category)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Target curves
            ForEach(hp.targets, id: \.self) { target in
                let isActive = mode.presetTarget == target && mode.presetHeadphoneName == hp.name
                Button {
                    if let settings = presetService.toEQSettings(headphone: hp, target: target) {
                        onApplyPreset(hp.name, target, settings)
                    }
                } label: {
                    HStack {
                        Text(target)
                            .font(.system(size: 12))
                            .fontWeight(isActive ? .medium : .regular)
                        Spacer()
                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Band Colors

enum EQColors {
    static let palette: [Color] = [
        Color(hue: 0.52, saturation: 0.75, brightness: 0.9),  // cyan
        Color(hue: 0.60, saturation: 0.65, brightness: 0.95), // blue
        Color(hue: 0.72, saturation: 0.55, brightness: 0.85), // indigo
        Color(hue: 0.80, saturation: 0.55, brightness: 0.85), // purple
        Color(hue: 0.92, saturation: 0.55, brightness: 0.95), // pink
        Color(hue: 0.00, saturation: 0.65, brightness: 0.95), // red
        Color(hue: 0.08, saturation: 0.75, brightness: 0.95), // orange
        Color(hue: 0.15, saturation: 0.75, brightness: 0.95), // yellow
        Color(hue: 0.35, saturation: 0.60, brightness: 0.85), // green
        Color(hue: 0.45, saturation: 0.55, brightness: 0.85), // mint
    ]

    static func color(for index: Int) -> Color {
        palette[index % palette.count]
    }
}

// MARK: - Interactive EQ Graph

struct InteractiveEQGraphView: View {
    let settings: EQSettings
    @Binding var selectedBand: Int?
    let frequencyResponse: [(hz: Float, db: Float)]?
    let onChange: (EQSettings) -> Void

    private let minFreq: Double = 20
    private let maxFreq: Double = 20_000
    private let displayMin: Double = -13  // dB shown at bottom
    private let displayMax: Double = 13   // dB shown at top
    private let sampleCount = 300
    private let dotRadius: CGFloat = 7
    private let hitRadius: CGFloat = 18

    @State private var dragBand: Int? = nil
    /// Whether the drag has moved far enough from its start to count as a real drag
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Dark background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.1))

                Canvas { ctx, canvasSize in
                    let inset = graphInsets
                    let area = CGRect(
                        x: inset.left, y: inset.top,
                        width: canvasSize.width - inset.left - inset.right,
                        height: canvasSize.height - inset.top - inset.bottom
                    )
                    drawGrid(ctx, area: area)
                    drawFrequencyLabels(ctx, area: area)
                    drawDBLabels(ctx, area: area)
                    if let fr = frequencyResponse {
                        drawFrequencyResponse(ctx, area: area, response: fr)
                    }
                    drawPerBandCurves(ctx, area: area)
                    drawCompositeCurve(ctx, area: area)
                    drawDots(ctx, area: area)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let area = graphArea(in: size)
                        if dragBand == nil {
                            // First touch — find and select nearest band
                            let nearest = findNearestBand(at: value.startLocation, area: area)
                            dragBand = nearest
                            selectedBand = nearest
                            isDragging = false
                        }
                        // Only start moving the dot after a 4pt drag threshold
                        let dist = hypot(value.location.x - value.startLocation.x,
                                         value.location.y - value.startLocation.y)
                        if !isDragging && dist > 4 {
                            isDragging = true
                        }
                        if isDragging, let idx = dragBand {
                            // Vertical: gain
                            let gain = yToGain(value.location.y, area: area)
                            let clampedGain = Float(max(Double(EQSettings.gainRange.lowerBound),
                                                        min(Double(EQSettings.gainRange.upperBound), gain)))
                            let roundedGain = (clampedGain * 10).rounded() / 10
                            let snappedGain: Float = abs(roundedGain) < 0.3 ? 0 : roundedGain

                            // Horizontal: frequency (log scale)
                            let freq = Float(xToFreq(value.location.x, area: area))
                            // Snap to default frequency when within ~8% on log scale
                            let defaultFreq = EQSettings.standardFrequencies[idx]
                            let logRatio = abs(log2(freq / defaultFreq))
                            let snappedFreq = logRatio < 0.12 ? defaultFreq : freq

                            var updated = settings
                                .withBand(at: idx, gain: snappedGain)
                            updated = updated.withBand(at: idx, frequency: snappedFreq)
                            onChange(updated)
                        }
                    }
                    .onEnded { _ in
                        dragBand = nil
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) { location in
                let area = graphArea(in: size)
                if let idx = findNearestBand(at: location, area: area) {
                    onChange(settings.withBand(at: idx, gain: 0))
                }
            }
        }
        .frame(height: 220)
    }

    // MARK: - Layout

    private var graphInsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        (left: 38, right: 12, top: 10, bottom: 22)
    }

    private func graphArea(in size: CGSize) -> CGRect {
        let ins = graphInsets
        return CGRect(x: ins.left, y: ins.top,
                      width: size.width - ins.left - ins.right,
                      height: size.height - ins.top - ins.bottom)
    }

    // MARK: - Coordinate Conversion

    private func freqToX(_ freq: Double, area: CGRect) -> CGFloat {
        area.minX + CGFloat(log10(freq / minFreq) / log10(maxFreq / minFreq)) * area.width
    }

    private func gainToY(_ gain: Double, area: CGRect) -> CGFloat {
        let normalized = (gain - displayMin) / (displayMax - displayMin)
        return area.maxY - CGFloat(normalized) * area.height
    }

    private func yToGain(_ y: CGFloat, area: CGRect) -> Double {
        let normalized = Double(area.maxY - y) / Double(area.height)
        return displayMin + normalized * (displayMax - displayMin)
    }

    private func xToFreq(_ x: CGFloat, area: CGRect) -> Double {
        let normalized = Double(x - area.minX) / Double(area.width)
        return minFreq * pow(maxFreq / minFreq, normalized)
    }

    // MARK: - Hit Testing

    private func findNearestBand(at point: CGPoint, area: CGRect) -> Int? {
        var bestIdx: Int? = nil
        var bestDist: CGFloat = hitRadius

        for (i, band) in settings.bands.enumerated() {
            let bx = freqToX(Double(band.frequency), area: area)
            let by = gainToY(Double(band.gain), area: area)
            let dist = hypot(point.x - bx, point.y - by)
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Drawing: Grid

    private func drawGrid(_ ctx: GraphicsContext, area: CGRect) {
        let gridColor = Color.white.opacity(0.08)
        let zeroColor = Color.white.opacity(0.2)

        // Horizontal dB lines
        let dbSteps: [Double] = [-12, -9, -6, -3, 0, 3, 6, 9, 12]
        for db in dbSteps {
            let y = gainToY(db, area: area)
            var path = Path()
            path.move(to: CGPoint(x: area.minX, y: y))
            path.addLine(to: CGPoint(x: area.maxX, y: y))
            ctx.stroke(path, with: .color(db == 0 ? zeroColor : gridColor), lineWidth: 0.5)
        }

        // Vertical frequency lines
        let freqLines: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for freq in freqLines {
            let x = freqToX(freq, area: area)
            var path = Path()
            path.move(to: CGPoint(x: x, y: area.minY))
            path.addLine(to: CGPoint(x: x, y: area.maxY))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
    }

    // MARK: - Drawing: Labels

    private func drawFrequencyLabels(_ ctx: GraphicsContext, area: CGRect) {
        let labels: [(Double, String)] = [
            (32, "32"), (64, "64"), (125, "125"), (250, "250"), (500, "500"),
            (1000, "1k"), (2000, "2k"), (4000, "4k"), (8000, "8k"), (16000, "16k")
        ]
        for (freq, label) in labels {
            let x = freqToX(freq, area: area)
            ctx.draw(
                Text(label).font(.system(size: 8)).foregroundColor(Color.white.opacity(0.35)),
                at: CGPoint(x: x, y: area.maxY + 12),
                anchor: .center
            )
        }
    }

    private func drawDBLabels(_ ctx: GraphicsContext, area: CGRect) {
        let labels: [(Double, String)] = [(-12, "-12"), (-6, "-6"), (0, "0"), (6, "+6"), (12, "+12")]
        for (db, label) in labels {
            let y = gainToY(db, area: area)
            ctx.draw(
                Text(label).font(.system(size: 8)).foregroundColor(Color.white.opacity(0.35)),
                at: CGPoint(x: area.minX - 6, y: y),
                anchor: .trailing
            )
        }
    }

    // MARK: - Drawing: Frequency Response curve

    private func drawFrequencyResponse(_ ctx: GraphicsContext, area: CGRect, response: [(hz: Float, db: Float)]) {
        guard response.count >= 2 else { return }

        // FR data is normalized at 1kHz = 0dB, scale to fit our ±13dB display
        // Clamp to display range
        let pts: [CGPoint] = response.compactMap { point in
            let freq = Double(point.hz)
            guard freq >= minFreq && freq <= maxFreq else { return nil }
            let db = max(displayMin, min(displayMax, Double(point.db)))
            return CGPoint(x: freqToX(freq, area: area), y: gainToY(db, area: area))
        }
        guard pts.count >= 2 else { return }

        // Draw as a smooth dashed line
        var path = Path()
        path.move(to: pts[0])
        for i in 1..<pts.count {
            path.addLine(to: pts[i])
        }

        let frColor = Color(hue: 0.08, saturation: 0.7, brightness: 0.95) // warm orange
        ctx.stroke(path, with: .color(frColor.opacity(0.5)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

        // Draw small dots at each FR data point
        for pt in pts {
            let dot = Path(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4))
            ctx.fill(dot, with: .color(frColor.opacity(0.4)))
        }
    }

    // MARK: - Drawing: Per-band curves (faint individual responses)

    private func drawPerBandCurves(_ ctx: GraphicsContext, area: CGRect) {
        for (i, band) in settings.bands.enumerated() {
            guard abs(band.gain) >= 0.01 else { continue }
            let color = EQColors.color(for: i)
            let zeroY = gainToY(0, area: area)

            let pts: [CGPoint] = (0...sampleCount).map { s in
                let t = Double(s) / Double(sampleCount)
                let freq = minFreq * pow(maxFreq / minFreq, t)
                let g = bandGain(band: band, bandIndex: i, at: freq)
                return CGPoint(x: freqToX(freq, area: area), y: gainToY(g, area: area))
            }

            // Faint fill
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
            pts.forEach { fill.addLine(to: $0) }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.08)))

            // Faint stroke
            var stroke = Path()
            stroke.move(to: pts[0])
            pts.dropFirst().forEach { stroke.addLine(to: $0) }
            ctx.stroke(stroke, with: .color(color.opacity(0.25)), lineWidth: 1)
        }
    }

    // MARK: - Drawing: Composite curve

    private func drawCompositeCurve(_ ctx: GraphicsContext, area: CGRect) {
        let zeroY = gainToY(0, area: area)

        let pts: [CGPoint] = (0...sampleCount).map { s in
            let t = Double(s) / Double(sampleCount)
            let freq = minFreq * pow(maxFreq / minFreq, t)
            let g = totalGain(at: freq)
            return CGPoint(x: freqToX(freq, area: area), y: gainToY(g, area: area))
        }

        // Fill between curve and zero
        var fill = Path()
        fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
        pts.forEach { fill.addLine(to: $0) }
        fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(Color.white.opacity(0.06)))

        // White curve stroke
        var stroke = Path()
        stroke.move(to: pts[0])
        pts.dropFirst().forEach { stroke.addLine(to: $0) }
        ctx.stroke(stroke, with: .color(Color.white.opacity(0.85)), lineWidth: 1.5)
    }

    // MARK: - Drawing: Band dots

    private func drawDots(_ ctx: GraphicsContext, area: CGRect) {
        for (i, band) in settings.bands.enumerated() {
            let x = freqToX(Double(band.frequency), area: area)
            let y = gainToY(Double(band.gain), area: area)
            let center = CGPoint(x: x, y: y)
            let color = EQColors.color(for: i)
            let isSelected = selectedBand == i
            let r = isSelected ? dotRadius + 2 : dotRadius

            // Outer glow for selected
            if isSelected {
                let glow = Path(ellipseIn: CGRect(x: center.x - r - 3, y: center.y - r - 3,
                                                   width: (r + 3) * 2, height: (r + 3) * 2))
                ctx.fill(glow, with: .color(color.opacity(0.25)))
            }

            // Filled dot
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                              width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(color.opacity(isSelected ? 1.0 : 0.8)))

            // White border
            ctx.stroke(dot, with: .color(.white.opacity(isSelected ? 0.9 : 0.5)), lineWidth: isSelected ? 2 : 1)
        }
    }

    // MARK: - Signal Processing (visual approximation)

    private func bandGain(band: EQBand, bandIndex: Int, at freq: Double) -> Double {
        let g = Double(band.gain)
        guard abs(g) >= 0.01 else { return 0 }
        let f0 = Double(band.frequency)
        let bw = max(Double(band.bandwidth), 0.1)
        let logRatio = log2(freq / f0)

        let bands = settings.bands
        if bandIndex == 0 {
            return g * (1.0 - sigmoid(logRatio * 2.5 / bw))
        } else if bandIndex == bands.count - 1 {
            return g * sigmoid(logRatio * 2.5 / bw)
        } else {
            let sigma = bw / 2.0
            return g * exp(-0.5 * pow(logRatio / sigma, 2))
        }
    }

    private func totalGain(at freq: Double) -> Double {
        var gain = Double(settings.preamp)
        for (i, band) in settings.bands.enumerated() {
            gain += bandGain(band: band, bandIndex: i, at: freq)
        }
        return max(displayMin, min(displayMax, gain))
    }

    private func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }
}

// MARK: - Band Parameter Panel

struct BandParameterPanel: View {
    let band: EQBand
    let bandIndex: Int
    let bandColor: Color
    let onGainChange: (Float) -> Void
    let onBandwidthChange: (Float) -> Void

    // Must match EQEditorView.dbSliderRow widths
    private let labelWidth: CGFloat = 52
    private let valueWidth: CGFloat = 58

    var body: some View {
        VStack(spacing: 6) {
            // Header
            HStack(spacing: 5) {
                Circle()
                    .fill(bandColor)
                    .frame(width: 10, height: 10)
                Text("Band \(bandIndex + 1)")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("·")
                    .foregroundColor(.secondary)
                Text(frequencyLabel(band.frequency))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.leading, 2)

            // Gain slider
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

            // Bandwidth / Q slider
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
    }

    private func snapToZero(_ value: Float) -> Float {
        abs(value) < 0.3 ? 0 : value
    }

    private func frequencyLabel(_ freq: Float) -> String {
        freq >= 1000 ? String(format: "%g kHz", freq / 1000) : String(format: "%g Hz", freq)
    }

    private func dbLabel(_ gain: Float) -> String {
        gain == 0 ? "0.0 dB" : String(format: "%+.1f dB", gain)
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
