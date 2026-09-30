import SwiftUI

/// Wasserfall mit Frequenzskala, Spektrumkurve und Mark/Space-Markern.
/// Klick oder Ziehen setzt die Audio-Mittenfrequenz des Decoders.
struct WaterfallView: View {
    @ObservedObject var model: WaterfallModel
    @ObservedObject var rtty: RTTYSettingsStore
    @ObservedObject var audio: AudioInputManager

    @State private var hoverHz: Double?

    private static let axisHeight: CGFloat = 16
    private static let spectrumHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 6) {
            controls
            GeometryReader { geo in
                let range = model.visibleRange(center: rtty.centerHz)
                let width = geo.size.width
                VStack(spacing: 0) {
                    FrequencyAxis(range: range)
                        .frame(height: Self.axisHeight)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            SpectrumGraph(spectrum: model.spectrum, binWidth: model.binWidth, range: range,
                                          floorDB: model.noiseFloor, rangeDB: model.rangeDB)
                                .frame(height: Self.spectrumHeight)
                            waterfallImage(range: range)
                        }
                        SignalMarkers(range: range, center: rtty.centerHz, parameters: rtty.decoderParameters, hoverHz: hoverHz)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        rtty.setCenter(frequency(atX: value.location.x, width: width, range: range))
                    })
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverHz = frequency(atX: p.x, width: width, range: range)
                        case .ended: hoverHz = nil
                        }
                    }
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
            .overlay(alignment: .center) {
                if !audio.isRunning {
                    Text("KEIN EINGANGSSIGNAL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(1.2)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ForEach(WaterfallModel.Span.allCases) { s in
                Button(s.label) { model.span = s }
                    .buttonStyle(ModeButtonStyle(isSelected: model.span == s))
                    .help("Angezeigter Bereich: \(s.label)" + (s == .full ? "" : " um die Mittenfrequenz"))
            }
            Spacer(minLength: 8)
            Text(readout)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("DYN")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Button { model.rangeDB = min(90, model.rangeDB + 5) } label: { Image(systemName: "minus") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Kontrast verringern (größerer Dynamikbereich)")
            Text("\(Int(model.rangeDB)) dB")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(width: 44)
            Button { model.rangeDB = max(20, model.rangeDB - 5) } label: { Image(systemName: "plus") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Kontrast erhöhen (kleinerer Dynamikbereich)")
        }
    }

    private var readout: String {
        let t = rtty.tones
        var s = "MITTE \(Int(rtty.centerHz)) Hz · M \(Int(t.mark.rounded())) · S \(Int(t.space.rounded()))"
        if let h = hoverHz { s += " · ▸ \(Int(h.rounded())) Hz" }
        return s
    }

    @ViewBuilder
    private func waterfallImage(range: ClosedRange<Double>) -> some View {
        if let image = model.image,
           let cropped = image.cropping(to: CGRect(x: range.lowerBound / model.binWidth, y: 0,
                                                   width: (range.upperBound - range.lowerBound) / model.binWidth,
                                                   height: Double(image.height))) {
            Image(decorative: cropped, scale: 1)
                .resizable()
                .interpolation(.medium)
        } else {
            Rectangle().fill(RadioTheme.bgDeep)
        }
    }

    private func frequency(atX x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double {
        let f = range.lowerBound + Double(max(0, min(x, width)) / max(width, 1)) * (range.upperBound - range.lowerBound)
        return f
    }
}

// MARK: - Frequenzskala

private struct FrequencyAxis: View {
    let range: ClosedRange<Double>

    var body: some View {
        Canvas { ctx, size in
            let span = range.upperBound - range.lowerBound
            let step: Double = span > 2500 ? 500 : span > 1200 ? 200 : span > 600 ? 100 : 50
            var f = (range.lowerBound / step).rounded(.up) * step
            while f <= range.upperBound {
                let x = CGFloat((f - range.lowerBound) / span) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 4))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(RadioTheme.textDim), lineWidth: 1)
                let label = Text("\(Int(f))")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                ctx.draw(label, at: CGPoint(x: min(max(x, 14), size.width - 14), y: 6), anchor: .center)
                f += step
            }
        }
        .background(RadioTheme.bgPanel)
    }
}

// MARK: - Spektrumkurve

private struct SpectrumGraph: View {
    let spectrum: [Float]
    let binWidth: Double
    let range: ClosedRange<Double>
    let floorDB: Float
    let rangeDB: Float

    var body: some View {
        Canvas { ctx, size in
            guard spectrum.count > 1 else { return }
            let span = range.upperBound - range.lowerBound
            let first = max(0, Int(range.lowerBound / binWidth))
            let last = min(spectrum.count - 1, Int((range.upperBound / binWidth).rounded(.up)))
            guard last > first else { return }
            let bottom = floorDB - 12
            let top = floorDB + rangeDB + 6
            func point(_ i: Int) -> CGPoint {
                let x = CGFloat((Double(i) * binWidth - range.lowerBound) / span) * size.width
                let v = CGFloat((spectrum[i] - bottom) / (top - bottom))
                return CGPoint(x: x, y: size.height * (1 - min(1, max(0, v))))
            }
            var line = Path()
            line.move(to: point(first))
            for i in (first + 1)...last { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: point(last).x, y: size.height))
            fill.addLine(to: CGPoint(x: point(first).x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(RadioTheme.vfdGreen.opacity(0.12)))
            ctx.stroke(line, with: .color(RadioTheme.vfdGreen), lineWidth: 1)
        }
        .background(RadioTheme.bgDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RadioTheme.borderSubtle).frame(height: 1)
        }
    }
}

// MARK: - Mark/Space-Marker

private struct SignalMarkers: View {
    let range: ClosedRange<Double>
    let center: Double
    let parameters: RTTYParameters
    let hoverHz: Double?

    var body: some View {
        Canvas { ctx, size in
            let span = range.upperBound - range.lowerBound
            func x(_ f: Double) -> CGFloat { CGFloat((f - range.lowerBound) / span) * size.width }

            // Belegte Bandbreite
            let bw = parameters.displayBandwidth
            let band = CGRect(x: x(center - bw / 2), y: 0, width: x(center + bw / 2) - x(center - bw / 2), height: size.height)
            ctx.fill(Path(band), with: .color(RadioTheme.vfdCyan.opacity(0.07)))

            let tones = parameters.tones(center: center)
            for (f, label, color) in [(tones.mark, "M", RadioTheme.vfdAmber), (tones.space, "S", RadioTheme.vfdCyan)] {
                let px = x(f)
                guard px >= 0, px <= size.width else { continue }
                var line = Path()
                line.move(to: CGPoint(x: px, y: 12))
                line.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(line, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text(label).font(.system(size: 9, weight: .black, design: .monospaced)).foregroundColor(color),
                         at: CGPoint(x: px, y: 6), anchor: .center)
            }

            if let h = hoverHz {
                var line = Path()
                line.move(to: CGPoint(x: x(h), y: 0))
                line.addLine(to: CGPoint(x: x(h), y: size.height))
                ctx.stroke(line, with: .color(RadioTheme.textBright.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
