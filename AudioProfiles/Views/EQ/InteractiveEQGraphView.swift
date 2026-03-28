import SwiftUI

/// Interactive 10-band EQ frequency response graph.
/// Supports drag-to-move band dots (gain + frequency) and drag on width handles (bandwidth).
/// Double-tap a band dot to reset its gain to 0 dB.
struct InteractiveEQGraphView: View {
    let settings: EQSettings
    @Binding var selectedBand: Int?
    let frequencyResponse: [(hz: Float, db: Float)]?
    let contentOverlay: EQSettings?
    let onChange: (EQSettings) -> Void

    private let minFreq: Double = 20
    private let maxFreq: Double = 20_000
    private let displayMin: Double = -13
    private let displayMax: Double = 13
    private let sampleCount = 300
    private let dotRadius: CGFloat = 7
    private let hitRadius: CGFloat = 18

    @State private var dragBand: Int? = nil
    @State private var isDragging = false
    @State private var draggingWidthHandle = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
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
                    if let overlay = contentOverlay, !overlay.isFlat {
                        drawContentOverlayCurve(ctx, area: area, overlay: overlay)
                    }
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
                            if let widthIdx = findNearestWidthHandle(at: value.startLocation, area: area) {
                                dragBand = widthIdx
                                selectedBand = widthIdx
                                draggingWidthHandle = true
                            } else {
                                let nearest = findNearestBand(at: value.startLocation, area: area)
                                dragBand = nearest
                                selectedBand = nearest
                                draggingWidthHandle = false
                            }
                            isDragging = false
                        }
                        let dist = hypot(value.location.x - value.startLocation.x,
                                         value.location.y - value.startLocation.y)
                        if !isDragging && dist > 4 { isDragging = true }

                        if isDragging, let idx = dragBand {
                            if draggingWidthHandle {
                                let band = settings.bands[idx]
                                let centerX = freqToX(Double(band.frequency), area: area)
                                let distFromCenter = abs(value.location.x - centerX)
                                let dragFreq = xToFreq(centerX + distFromCenter, area: area)
                                let bandwidth = Float(abs(log2(dragFreq / Double(band.frequency))) * 2)
                                let clamped = max(EQSettings.bandwidthRange.lowerBound,
                                                  min(EQSettings.bandwidthRange.upperBound, bandwidth))
                                onChange(settings.withBand(at: idx, bandwidth: (clamped * 10).rounded() / 10))
                            } else {
                                let gain = yToGain(value.location.y, area: area)
                                let clampedGain = Float(max(Double(EQSettings.gainRange.lowerBound),
                                                            min(Double(EQSettings.gainRange.upperBound), gain)))
                                let roundedGain = (clampedGain * 10).rounded() / 10
                                let snappedGain: Float = abs(roundedGain) < 0.3 ? 0 : roundedGain

                                let freq = Float(xToFreq(value.location.x, area: area))
                                let defaultFreq = EQSettings.standardFrequencies[idx]
                                let snappedFreq = abs(log2(freq / defaultFreq)) < 0.12 ? defaultFreq : freq

                                var updated = settings.withBand(at: idx, gain: snappedGain)
                                updated = updated.withBand(at: idx, frequency: snappedFreq)
                                onChange(updated)
                            }
                        }
                    }
                    .onEnded { _ in
                        dragBand = nil
                        isDragging = false
                        draggingWidthHandle = false
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
        .overlay(alignment: .trailing) {
            if EQEngineService.shared.isRunning {
                LevelMeterView()
                    .frame(width: 20)
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
            }
        }
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
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        return bestIdx
    }

    private func findNearestWidthHandle(at point: CGPoint, area: CGRect) -> Int? {
        guard let idx = selectedBand, idx < settings.bands.count else { return nil }
        let band = settings.bands[idx]
        guard abs(band.gain) >= 0.5 else { return nil }
        let (leftPt, rightPt) = widthHandlePositions(bandIndex: idx, area: area)
        let r: CGFloat = 14
        if hypot(point.x - leftPt.x,  point.y - leftPt.y)  < r { return idx }
        if hypot(point.x - rightPt.x, point.y - rightPt.y) < r { return idx }
        return nil
    }

    private func widthHandlePositions(bandIndex: Int, area: CGRect) -> (left: CGPoint, right: CGPoint) {
        let band = settings.bands[bandIndex]
        let f0 = Double(band.frequency)
        let bw = Double(band.bandwidth)
        let halfGain = Double(band.gain) * 0.5
        let leftPt  = CGPoint(x: freqToX(f0 * pow(2.0, -bw / 2.0), area: area), y: gainToY(halfGain, area: area))
        let rightPt = CGPoint(x: freqToX(f0 * pow(2.0,  bw / 2.0), area: area), y: gainToY(halfGain, area: area))
        return (leftPt, rightPt)
    }

    // MARK: - Drawing: Grid

    private func drawGrid(_ ctx: GraphicsContext, area: CGRect) {
        let gridColor = Color.white.opacity(0.08)
        let zeroColor = Color.white.opacity(0.2)
        for db in [-12.0, -9, -6, -3, 0, 3, 6, 9, 12] {
            let y = gainToY(db, area: area)
            var path = Path()
            path.move(to: CGPoint(x: area.minX, y: y))
            path.addLine(to: CGPoint(x: area.maxX, y: y))
            ctx.stroke(path, with: .color(db == 0 ? zeroColor : gridColor), lineWidth: 0.5)
        }
        for freq in [32.0, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
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
            (32,"32"), (64,"64"), (125,"125"), (250,"250"), (500,"500"),
            (1000,"1k"), (2000,"2k"), (4000,"4k"), (8000,"8k"), (16000,"16k")
        ]
        for (freq, label) in labels {
            ctx.draw(
                Text(label).font(.system(size: 8)).foregroundColor(Color.white.opacity(0.35)),
                at: CGPoint(x: freqToX(freq, area: area), y: area.maxY + 12),
                anchor: .center
            )
        }
    }

    private func drawDBLabels(_ ctx: GraphicsContext, area: CGRect) {
        for (db, label) in [(-12.0,"-12"), (-6,"-6"), (0,"0"), (6,"+6"), (12,"+12")] {
            ctx.draw(
                Text(label).font(.system(size: 8)).foregroundColor(Color.white.opacity(0.35)),
                at: CGPoint(x: area.minX - 6, y: gainToY(db, area: area)),
                anchor: .trailing
            )
        }
    }

    // MARK: - Drawing: Frequency Response curve

    private func drawFrequencyResponse(_ ctx: GraphicsContext, area: CGRect, response: [(hz: Float, db: Float)]) {
        guard response.count >= 2 else { return }
        let pts: [CGPoint] = response.compactMap { point in
            let freq = Double(point.hz)
            guard freq >= minFreq && freq <= maxFreq else { return nil }
            return CGPoint(x: freqToX(freq, area: area),
                           y: gainToY(max(displayMin, min(displayMax, Double(point.db))), area: area))
        }
        guard pts.count >= 2 else { return }
        var path = Path()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.addLine(to: $0) }
        let frColor = Color(hue: 0.08, saturation: 0.7, brightness: 0.95)
        ctx.stroke(path, with: .color(frColor.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        for pt in pts {
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)),
                     with: .color(frColor.opacity(0.4)))
        }
    }

    // MARK: - Drawing: Per-band curves

    private func drawPerBandCurves(_ ctx: GraphicsContext, area: CGRect) {
        for (i, band) in settings.bands.enumerated() {
            guard abs(band.gain) >= 0.01 else { continue }
            let color = EQColors.color(for: i)
            let zeroY = gainToY(0, area: area)
            let pts: [CGPoint] = (0...sampleCount).map { s in
                let t = Double(s) / Double(sampleCount)
                let freq = minFreq * pow(maxFreq / minFreq, t)
                return CGPoint(x: freqToX(freq, area: area),
                               y: gainToY(bandGain(band: band, bandIndex: i, at: freq), area: area))
            }
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
            pts.forEach { fill.addLine(to: $0) }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.08)))
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
            return CGPoint(x: freqToX(freq, area: area), y: gainToY(totalGain(at: freq), area: area))
        }
        var fill = Path()
        fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
        pts.forEach { fill.addLine(to: $0) }
        fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(Color.white.opacity(0.06)))
        var stroke = Path()
        stroke.move(to: pts[0])
        pts.dropFirst().forEach { stroke.addLine(to: $0) }
        ctx.stroke(stroke, with: .color(Color.white.opacity(0.85)), lineWidth: 1.5)
    }

    // MARK: - Drawing: Content overlay curve

    private func drawContentOverlayCurve(_ ctx: GraphicsContext, area: CGRect, overlay: EQSettings) {
        let combined = EQSettings.combine(base: settings, overlay: overlay)
        let pts: [CGPoint] = (0...sampleCount).map { s in
            let t = Double(s) / Double(sampleCount)
            let freq = minFreq * pow(maxFreq / minFreq, t)
            var g = Double(combined.preamp)
            for (i, band) in combined.bands.enumerated() {
                g += bandGain(band: band, bandIndex: i, at: freq)
            }
            g = max(displayMin, min(displayMax, g))
            return CGPoint(x: freqToX(freq, area: area), y: gainToY(g, area: area))
        }
        var stroke = Path()
        stroke.move(to: pts[0])
        pts.dropFirst().forEach { stroke.addLine(to: $0) }
        ctx.stroke(stroke, with: .color(Color.teal.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    }

    // MARK: - Drawing: Band dots

    private func drawDots(_ ctx: GraphicsContext, area: CGRect) {
        for (i, band) in settings.bands.enumerated() {
            let center = CGPoint(x: freqToX(Double(band.frequency), area: area),
                                 y: gainToY(Double(band.gain), area: area))
            let color = EQColors.color(for: i)
            let isSelected = selectedBand == i
            let r = isSelected ? dotRadius + 2 : dotRadius

            if isSelected {
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - r - 3, y: center.y - r - 3,
                                                 width: (r + 3) * 2, height: (r + 3) * 2)),
                         with: .color(color.opacity(0.25)))
            }

            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(color.opacity(isSelected ? 1.0 : 0.8)))
            ctx.stroke(dot, with: .color(.white.opacity(isSelected ? 0.9 : 0.5)), lineWidth: isSelected ? 2 : 1)

            if isSelected && abs(band.gain) >= 0.5 {
                let (leftPt, rightPt) = widthHandlePositions(bandIndex: i, area: area)
                let handleR: CGFloat = 4
                for pt in [leftPt, rightPt] {
                    guard pt.x >= area.minX && pt.x <= area.maxX else { continue }
                    let handle = Path(ellipseIn: CGRect(x: pt.x - handleR, y: pt.y - handleR,
                                                         width: handleR * 2, height: handleR * 2))
                    ctx.fill(handle, with: .color(color.opacity(0.6)))
                    ctx.stroke(handle, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }
                var line = Path()
                line.move(to: leftPt)
                line.addLine(to: rightPt)
                ctx.stroke(line, with: .color(color.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
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
