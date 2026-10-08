// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit
import CoreGraphics

// MARK: - HF-Wasserfall

/// Bild des I/Q-Fensters: Spalten folgen dynamisch der gewählten FFT-Auflösung (4.096 bis 32.768 Punkte), 25 Zeilen je Sekunde
@MainActor
final class SDRSpectrumModel: ObservableObject {
    static let defaultColumns = 4096
    static let history = 220

    @Published private(set) var image: CGImage?
    @Published private(set) var spectrum: [Float] = []
    @Published private(set) var floorDB: Float = -90
    /// Dynamikbereich der Farbskala in dB
    @Published var rangeDB: Float {
        didSet { UserDefaults.standard.set(rangeDB, forKey: "sdrRangeDB"); needsRedraw = true }
    }

    private let rowSource: @MainActor () -> [[Float]]
    private var pixels: [UInt32]
    private(set) var columns: Int
    private var dbRows: [[Float]] = []
    private var needsRedraw = false
    private var timer: Timer?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(rows: @escaping @MainActor () -> [[Float]]) {
        rowSource = rows
        let saved = UserDefaults.standard.float(forKey: "sdrRangeDB")
        rangeDB = (20...90).contains(saved) ? saved : 55
        columns = Self.defaultColumns
        pixels = [UInt32](repeating: WaterfallColorMap.lut[0], count: columns * Self.history)
    }

    /// Zeilen mit 25 Hz holen, solange die Ansicht sichtbar ist
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        let rows = rowSource()
        guard !rows.isEmpty || needsRedraw else { return }
        for raw in rows {
            if raw.count != columns && raw.count > 0 {
                columns = raw.count
                pixels = [UInt32](repeating: WaterfallColorMap.lut[0], count: columns * Self.history)
                dbRows.removeAll()
            }
            let row = raw
            // Rauschteppich: unteres Fünftel der Werte, langsam nachgeführt
            let sorted = row.sorted()
            let floor = sorted[sorted.count / 5]
            floorDB += (floor - floorDB) * (dbRows.isEmpty ? 1 : 0.05)
            let width = columns
            pixels.withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                (base + width).update(from: base, count: width * (Self.history - 1))
            }
            paint(row: row, at: 0)
            dbRows.insert(row, at: 0)
            if dbRows.count > Self.history { dbRows.removeLast() }
            spectrum = row
        }
        if needsRedraw {
            needsRedraw = false
            for (r, row) in dbRows.enumerated() { paint(row: row, at: r) }
        }
        image = makeImage()
    }

    private func paint(row: [Float], at r: Int) {
        let lut = WaterfallColorMap.lut
        let lo = floorDB - 6
        let width = columns
        pixels.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress! + r * width
            let count = min(width, row.count)
            for i in 0..<count { base[i] = lut[WaterfallColorMap.index(db: row[i], floorDB: lo, rangeDB: rangeDB)] }
        }
    }

    private func makeImage() -> CGImage? {
        let width = columns
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: Self.history, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func clear() {
        dbRows.removeAll()
        for i in pixels.indices { pixels[i] = WaterfallColorMap.lut[0] }
        needsRedraw = true
    }
}

/// Wählt zwischen NF-Wasserfall (Inhalt) und HF-Wasserfall des SDR-Empfängers
struct SDRWaterfallHost<Content: View>: View {
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var settings: SDRSettingsStore
    let controller: SDRController
    let module: DecoderModuleInfo
    @ViewBuilder var nf: () -> Content

    var body: some View {
        if audio.sourceKind == .sdr && !module.usesOwnIQDevice {
            if settings.showRFWaterfall || module == .channels {
                SDRSpectrumView(controller: controller, settings: settings, audio: audio)
            } else {
                nf().overlay(alignment: .topTrailing) {
                    Button("HF") { settings.showRFWaterfall = true }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                        .scaleEffect(0.85)
                        .help("HF-Wasserfall des SDR-Empfängers zeigen")
                }
            }
        } else {
            nf()
        }
    }
}

struct SDRSpectrumView: View {
    @ObservedObject var controller: SDRController
    @ObservedObject var settings: SDRSettingsStore
    @ObservedObject var audio: AudioInputManager
    @ObservedObject private var bank: SDRChannelBank
    @StateObject private var model: SDRSpectrumModelBox

    @State private var zoom: SDRZoomFactor
    @State private var hoverHz: Double?
    @State private var scrollMonitor: Any?

    init(controller: SDRController, settings: SDRSettingsStore, audio: AudioInputManager) {
        self.controller = controller
        self.settings = settings
        self.audio = audio
        bank = controller.bank
        _model = StateObject(wrappedValue: SDRSpectrumModelBox(controller: controller))
        let savedZoom = UserDefaults.standard.integer(forKey: "sdrZoomFactor")
        _zoom = State(initialValue: SDRZoomFactor(rawValue: savedZoom) ?? .x1)
    }

    private var centerFrequency: Double {
        if bank.isActive {
            if let pending = bank.pendingFrequencyHz { return pending }
            if let selID = bank.selectedID, let slot = bank.slots.first(where: { $0.id == selID }) {
                return slot.frequencyHz
            }
            return controller.loHz
        }
        return settings.frequencyHz
    }

    private var fullSpan: Double { Double(settings.effectiveSampleRate) }

    private var fullRange: ClosedRange<Double> {
        let lo = controller.loHz
        return (lo - fullSpan / 2)...(lo + fullSpan / 2)
    }

    private var visibleSpan: Double { zoom.visibleSpan(sampleRate: fullSpan) }

    private var effectiveBins: Int {
        settings.waterfallResolution.effectiveBins(sampleRate: fullSpan, zoom: zoom)
    }

    private func updateSpectrumResolution() {
        controller.engine.setSpectrumBins(effectiveBins)
    }

    private func range() -> ClosedRange<Double> {
        zoom.visibleRange(center: centerFrequency, sampleRate: fullSpan, loHz: controller.loHz)
    }

    private func setZoom(_ z: SDRZoomFactor) {
        zoom = z
        UserDefaults.standard.set(z.rawValue, forKey: "sdrZoomFactor")
        updateSpectrumResolution()
    }

    private func zoomIn() {
        setZoom(zoom.next())
    }

    private func zoomOut() {
        setZoom(zoom.previous())
    }

    var body: some View {
        VStack(spacing: 6) {
            controls
            GeometryReader { geo in
                let r = range()
                let full = fullRange
                let width = geo.size.width
                VStack(spacing: 0) {
                    RFAxis(range: r)
                        .frame(height: 16)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            RFSpectrumGraph(spectrum: model.value.spectrum, range: r, fullRange: full,
                                            floorDB: model.value.floorDB, rangeDB: model.value.rangeDB)
                                .frame(height: 54)
                            waterfallImage(range: r, fullRange: full)
                        }
                        if bank.isActive {
                            RFBankMarkers(range: r, bank: bank, hoverHz: hoverHz)
                        } else {
                            RFMarker(range: r, settings: settings, hoverHz: hoverHz)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let f = snap(frequency(atX: value.location.x, width: width, range: r))
                        if bank.isActive { bank.pendingFrequencyHz = f } else { controller.tune(frequencyHz: f) }
                    })
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverHz = frequency(atX: p.x, width: width, range: r); SDRHoverState.shared.hovering = true
                        case .ended: hoverHz = nil; SDRHoverState.shared.hovering = false
                        }
                    }
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
            .overlay(alignment: .center) {
                if case .running = controller.status {} else {
                    Text(overlayText)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(statusIsError ? RadioTheme.ledYellow : RadioTheme.textDim)
                        .tracking(1.2)
                        .multilineTextAlignment(.center)
                        .padding(12)
                }
            }
        }
        .onAppear {
            installScroll()
            updateSpectrumResolution()
            model.value.start()
        }
        .onDisappear { removeScroll(); model.value.stop(); SDRHoverState.shared.hovering = false }
    }

    private var statusIsError: Bool { if case .error = controller.status { return true } else { return false } }

    private var overlayText: String {
        switch controller.status {
        case .error(let m): return m
        default: return controller.isSuspended ? "SDR PAUSIERT: DAS MODUL LIEST DAS GERÄT SELBST" : "SDR-EMPFÄNGER STARTET …"
        }
    }

    @ViewBuilder
    private func waterfallImage(range: ClosedRange<Double>, fullRange: ClosedRange<Double>) -> some View {
        if let image = model.value.image {
            let fSpan = fullRange.upperBound - fullRange.lowerBound
            let vSpan = range.upperBound - range.lowerBound
            let imgW = Double(image.width)
            let imgH = Double(image.height)
            if zoom == .x1 || vSpan >= fSpan || fSpan <= 0 {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            } else {
                let cropX = max(0, min(imgW, ((range.lowerBound - fullRange.lowerBound) / fSpan) * imgW))
                let cropW = max(1, min(imgW - cropX, (vSpan / fSpan) * imgW))
                let cropRect = CGRect(x: cropX, y: 0, width: cropW, height: imgH)
                if let cropped = image.cropping(to: cropRect) {
                    Image(decorative: cropped, scale: 1).resizable().interpolation(.medium)
                } else {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                }
            }
        } else {
            Rectangle().fill(RadioTheme.bgDeep)
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button("NF") { settings.showRFWaterfall = false }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Zum NF-Wasserfall (Audio des Empfängers) wechseln")
            Text("HF")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)

            ForEach(SDRZoomFactor.allCases) { z in
                Button(z.label) { setZoom(z) }
                    .buttonStyle(ModeButtonStyle(isSelected: zoom == z))
                    .help("HF-Zoom: \(z.label)" + (z == .x1 ? " (gesamtes I/Q-Fenster)" : " um die Abstimmfrequenz"))
            }

            Spacer(minLength: 8)
            Text(readout)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
            Spacer(minLength: 8)

            Menu {
                ForEach(SDRWaterfallResolution.allCases) { r in
                    Button {
                        settings.waterfallResolution = r
                        updateSpectrumResolution()
                    } label: {
                        HStack {
                            Text(r.title)
                            if settings.waterfallResolution == r {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("FFT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Text(fftLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(fftTooltip)

            Text("DYN")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Button { model.value.rangeDB = min(90, model.value.rangeDB + 5) } label: { Image(systemName: "minus") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
            Text("\(Int(model.value.rangeDB)) dB")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(width: 44)
            Button { model.value.rangeDB = max(20, model.value.rangeDB - 5) } label: { Image(systemName: "plus") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
        }
    }

    private var fftLabel: String {
        switch settings.waterfallResolution {
        case .auto:
            return "Auto (\(formatBins(effectiveBins)))"
        case .r4k, .r8k, .r16k, .r32k:
            return settings.waterfallResolution.shortLabel
        }
    }

    private var fftTooltip: String {
        let b = effectiveBins
        let binHz = Int((fullSpan / Double(b)).rounded())
        return "FFT-Auflösung: \(b) Bins (ca. \(binHz) Hz je Bin). Im Auto-Modus passt sich die Auflösung beim Zoomen von 4k bis 32k an."
    }

    private func formatBins(_ b: Int) -> String {
        if b >= 1024 { return "\(b / 1024)k" }
        return "\(b)"
    }

    private var readout: String {
        var s = bank.isActive ? "\(bank.slots.filter(\.enabled).count) Kanäle" : SDRFormat.frequency(settings.frequencyHz) + " MHz " + settings.mode.title
        if zoom != .x1 {
            s += " · Span " + SDRFormat.stepName(visibleSpan)
        }
        if let h = hoverHz { s += " · ▸ " + SDRFormat.frequency(h) }
        return s
    }

    private func snap(_ f: Double) -> Double {
        let step = settings.stepHz >= 1000 ? settings.stepHz : 100
        return (f / step).rounded() * step
    }

    private func frequency(atX x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(max(0, min(x, width)) / max(width, 1)) * (range.upperBound - range.lowerBound)
    }

    /// Mausrad über dem Wasserfall stimmt ab (ein Schritt je Rasterung, mit Umschalttaste zehn);
    /// mit Wahltaste (Option) oder Trackpad-Pinch wird der HF-Zoom verstellt
    private func installScroll() {
        guard scrollMonitor == nil else { return }
        let c = controller
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard MainActor.assumeIsolated({ SDRHoverState.shared.hovering }) else { return event }

            if event.type == .magnify {
                let mag = event.magnification
                if abs(mag) > 0.06 {
                    Task { @MainActor in
                        if mag > 0 {
                            zoomIn()
                        } else {
                            zoomOut()
                        }
                    }
                    return nil
                }
                return event
            }

            if event.modifierFlags.contains(.option) {
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
                guard abs(delta) > 0.5 else { return nil }
                Task { @MainActor in
                    if delta > 0 {
                        zoomIn()
                    } else {
                        zoomOut()
                    }
                }
                return nil
            }

            guard MainActor.assumeIsolated({ !c.bank.isActive }) else { return event }
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            guard abs(delta) > 0.5 else { return nil }
            let steps = delta > 0 ? 1 : -1
            let mult: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            Task { @MainActor in c.step(steps, multiplier: mult) }
            return nil
        }
    }

    private func removeScroll() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }
}

/// Ob die Maus über dem HF-Wasserfall steht (für das Mausrad)
@MainActor
final class SDRHoverState {
    static let shared = SDRHoverState()
    var hovering = false
}

/// Hält das Modell in einer StateObject-Hülle (das Modell braucht den Controller zum Anlegen)
@MainActor
final class SDRSpectrumModelBox: ObservableObject {
    let value: SDRSpectrumModel
    private var forward: Any?

    init(rows: @escaping @MainActor () -> [[Float]]) {
        value = SDRSpectrumModel(rows: rows)
        forward = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    init(controller: SDRController) {
        value = SDRSpectrumModel(rows: { controller.engine.takeSpectrumRows() })
        forward = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// Breite des I/Q-Fensters: beim HackRF bis 20 MS/s, beim SDRplay von 62,5 kS/s bis 10 MS/s wählbar, RTL-SDR läuft fest mit 2,4 MS/s
struct SDRWindowPicker: View {
    @ObservedObject var settings: SDRSettingsStore

    var body: some View {
        let rate = settings.effectiveSampleRate
        let choices = SDRSettingsStore.sampleRateChoices(for: settings.source)
        HStack(spacing: 6) {
            Text("FENSTER")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Menu {
                ForEach(choices, id: \.self) { r in
                    Button("\(Self.rateText(r)) · nutzbar \(Self.widthText(r))") { settings.sampleRateHz = r }
                }
            } label: {
                Text("\(Self.rateText(rate)) · \(Self.widthText(rate))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(choices.count < 2)
            .help(helpText(choices.count))
            Spacer(minLength: 0)
            if rate >= 14_400_000 {
                Text("viel Rechenlast")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
            }
        }
    }

    private func helpText(_ count: Int) -> String {
        if count < 2 { return "Dieses Gerät läuft fest mit 2,4 MS/s (nur dort geprüft)" }
        if settings.source == .sdrplay {
            return "Breite des I/Q-Fensters, das der SDRplay liefert: 2 bis 10 MS/s direkt, darunter dezimiert die API des Geräts das 2-MS/s-Signal bis herab zu 62,5 kS/s (schmal und rauschärmer für einzelne Signale). Der analoge ZF-Filter richtet sich nach der Rate (Wahl unten). Höhere Raten brauchen mehr Rechenzeit; UKW-Rundfunk braucht mindestens 250 kS/s."
        }
        return "Breite des I/Q-Fensters, das der HackRF liefert: der HF-Wasserfall zeigt so viel auf einmal, Mehrkanalbetrieb nutzt es für mehrere Decoder. Höhere Raten brauchen mehr Rechenzeit und einen schnellen USB-Anschluss; 20 MS/s braucht USB 3 oder einen guten USB-2-Anschluss ohne Hub."
    }

    /// „2,4 MS/s“, „62,5 kS/s“
    static func rateText(_ r: Int) -> String {
        r < 1_000_000 ? String(format: "%g kS/s", Double(r) / 1e3).replacingOccurrences(of: ".", with: ",")
                      : String(format: "%g MS/s", Double(r) / 1e6).replacingOccurrences(of: ".", with: ",")
    }
    /// Nutzbare Breite (die Ränder des Geräts fallen ab): etwa 70 % der Abtastrate
    static func widthText(_ r: Int) -> String {
        let w = SDRSettingsStore.window(forRate: r) * 2
        return w < 1_000_000 ? String(format: "%.0f kHz", w / 1e3) : String(format: "%.1f MHz", w / 1e6).replacingOccurrences(of: ".", with: ",")
    }
}

enum SDRFormat {
    /// 145,500000 (MHz, sechs Nachkommastellen)
    static func frequency(_ hz: Double) -> String {
        String(format: "%.6f", hz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    static func stepName(_ hz: Double) -> String {
        if hz >= 1e6 { return String(format: "%g MHz", hz / 1e6).replacingOccurrences(of: ".", with: ",") }
        if hz >= 1000 { return String(format: "%g kHz", hz / 1000).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%g Hz", hz)
    }
}

struct RFAxis: View {
    let range: ClosedRange<Double>

    var body: some View {
        Canvas { ctx, size in
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return }
            let steps: [Double] = [
                500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000, 5_000_000
            ]
            let step = steps.first { span / $0 <= 12 } ?? 2_000_000
            var f = (range.lowerBound / step).rounded(.up) * step
            while f <= range.upperBound {
                let x = CGFloat((f - range.lowerBound) / span) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 4))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(RadioTheme.textDim), lineWidth: 1)

                let labelText: String
                if step >= 1_000_000 {
                    labelText = String(format: "%.0f", f / 1e6)
                } else if step >= 100_000 {
                    labelText = String(format: "%.1f", f / 1e6).replacingOccurrences(of: ".", with: ",")
                } else if step >= 10_000 {
                    labelText = String(format: "%.2f", f / 1e6).replacingOccurrences(of: ".", with: ",")
                } else if step >= 1_000 {
                    labelText = String(format: "%.3f", f / 1e6).replacingOccurrences(of: ".", with: ",")
                } else {
                    labelText = String(format: "%.4f", f / 1e6).replacingOccurrences(of: ".", with: ",")
                }

                let label = Text(verbatim: labelText)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                ctx.draw(label, at: CGPoint(x: min(max(x, 18), size.width - 18), y: 6), anchor: .center)
                f += step
            }
        }
        .background(RadioTheme.bgPanel)
    }
}

struct RFSpectrumGraph: View {
    let spectrum: [Float]
    var range: ClosedRange<Double>? = nil
    var fullRange: ClosedRange<Double>? = nil
    let floorDB: Float
    let rangeDB: Float

    var body: some View {
        Canvas { ctx, size in
            guard spectrum.count > 1 else { return }
            let bottom = floorDB - 12
            let top = floorDB + rangeDB + 6
            let count = spectrum.count

            if let range, let fullRange, fullRange.upperBound > fullRange.lowerBound, range.upperBound > range.lowerBound {
                let fullSpan = fullRange.upperBound - fullRange.lowerBound
                let visibleSpan = range.upperBound - range.lowerBound
                let first = max(0, min(count - 1, Int(((range.lowerBound - fullRange.lowerBound) / fullSpan * Double(count - 1)).rounded(.down))))
                let last = max(first, min(count - 1, Int(((range.upperBound - fullRange.lowerBound) / fullSpan * Double(count - 1)).rounded(.up))))
                guard last > first else { return }

                func point(_ i: Int) -> CGPoint {
                    let f = fullRange.lowerBound + (Double(i) / Double(count - 1)) * fullSpan
                    let x = CGFloat((f - range.lowerBound) / visibleSpan) * size.width
                    let v = CGFloat((spectrum[i] - bottom) / (top - bottom))
                    let y = size.height * (1 - min(1, max(0, v)))
                    return CGPoint(x: x, y: y)
                }

                var line = Path()
                let p0 = point(first)
                line.move(to: CGPoint(x: min(0, p0.x), y: p0.y))
                line.addLine(to: p0)
                for i in (first + 1)...last {
                    line.addLine(to: point(i))
                }
                let pLast = point(last)
                line.addLine(to: CGPoint(x: max(size.width, pLast.x), y: pLast.y))

                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(RadioTheme.vfdGreen.opacity(0.12)))
                ctx.stroke(line, with: .color(RadioTheme.vfdGreen), lineWidth: 1)
            } else {
                func point(_ i: Int) -> CGPoint {
                    let x = CGFloat(i) / CGFloat(count - 1) * size.width
                    let v = CGFloat((spectrum[i] - bottom) / (top - bottom))
                    return CGPoint(x: x, y: size.height * (1 - min(1, max(0, v))))
                }
                var line = Path()
                line.move(to: point(0))
                for i in 1..<count { line.addLine(to: point(i)) }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(RadioTheme.vfdGreen.opacity(0.12)))
                ctx.stroke(line, with: .color(RadioTheme.vfdGreen), lineWidth: 1)
            }
        }
        .background(RadioTheme.bgDeep)
        .overlay(alignment: .bottom) { Rectangle().fill(RadioTheme.borderSubtle).frame(height: 1) }
    }
}

/// Kanäle der Kanalbank im Wasserfall: Durchlassbereich, Mittenlinie und Nummer; ausgeschaltete oder außerhalb liegende Kanäle gedämpft
private struct RFBankMarkers: View {
    let range: ClosedRange<Double>
    @ObservedObject var bank: SDRChannelBank
    let hoverHz: Double?

    var body: some View {
        Canvas { ctx, size in
            let span = range.upperBound - range.lowerBound
            func x(_ f: Double) -> CGFloat { CGFloat((f - range.lowerBound) / span) * size.width }
            for (n, slot) in bank.slots.enumerated() {
                let f = slot.frequencyHz
                guard f > range.lowerBound - 50_000, f < range.upperBound + 50_000 else { continue }
                let on = slot.enabled && bank.plan.covered.contains(slot.id)
                let selected = bank.selectedID == slot.id
                let color: Color = on ? (selected ? RadioTheme.vfdAmber : RadioTheme.vfdCyan) : RadioTheme.textDim
                let band = CGRect(x: x(f - slot.bandwidthHz / 2), y: 0, width: max(2, x(f + slot.bandwidthHz / 2) - x(f - slot.bandwidthHz / 2)), height: size.height)
                ctx.fill(Path(band), with: .color(color.opacity(on ? 0.22 : 0.10)))
                var line = Path()
                line.move(to: CGPoint(x: x(f), y: 0))
                line.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(line, with: .color(color), lineWidth: selected ? 1.6 : 1)
                let tag = Text(verbatim: "\(n + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                ctx.draw(tag, at: CGPoint(x: min(max(x(f), 6), size.width - 6), y: 8), anchor: .center)
            }
            if let pending = bank.pendingFrequencyHz {
                var line = Path()
                line.move(to: CGPoint(x: x(pending), y: 0))
                line.addLine(to: CGPoint(x: x(pending), y: size.height))
                ctx.stroke(line, with: .color(RadioTheme.vfdGreen), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
            if let h = hoverHz {
                var hl = Path()
                hl.move(to: CGPoint(x: x(h), y: 0))
                hl.addLine(to: CGPoint(x: x(h), y: size.height))
                ctx.stroke(hl, with: .color(RadioTheme.textBright.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Gehörte Frequenz und Durchlassbereich im Wasserfall
private struct RFMarker: View {
    let range: ClosedRange<Double>
    @ObservedObject var settings: SDRSettingsStore
    let hoverHz: Double?

    var body: some View {
        Canvas { ctx, size in
            let span = range.upperBound - range.lowerBound
            func x(_ f: Double) -> CGFloat { CGFloat((f - range.lowerBound) / span) * size.width }
            let f = settings.frequencyHz
            let bw = settings.bandwidthHz
            let low: Double, high: Double
            switch settings.mode {
            case .usb: low = f + 100; high = f + 100 + bw
            case .lsb: low = f - 100 - bw; high = f - 100
            default: low = f - bw / 2; high = f + bw / 2
            }
            let band = CGRect(x: x(low), y: 0, width: max(2, x(high) - x(low)), height: size.height)
            ctx.fill(Path(band), with: .color(RadioTheme.vfdCyan.opacity(0.14)))
            var line = Path()
            line.move(to: CGPoint(x: x(f), y: 0))
            line.addLine(to: CGPoint(x: x(f), y: size.height))
            ctx.stroke(line, with: .color(RadioTheme.vfdAmber), lineWidth: 1.2)
            if let h = hoverHz {
                var hl = Path()
                hl.move(to: CGPoint(x: x(h), y: 0))
                hl.addLine(to: CGPoint(x: x(h), y: size.height))
                ctx.stroke(hl, with: .color(RadioTheme.textBright.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bedienkarte

/// Statt der Geräteliste, wenn die Quelle „SDR“ gewählt ist: Frequenz, Betriebsart, Breite, Squelch, Mithören und das Gerät
struct SDRControlView: View {
    @ObservedObject var controller: SDRController
    @ObservedObject var settings: SDRSettingsStore
    @State private var frequencyText = ""
    @FocusState private var frequencyFocused: Bool
    @State private var showGain = ProcessInfo.processInfo.environment["DIGIDEC_SDR_GAIN"] != nil   // für Schnappschüsse

    private static let steps: [Double] = [100, 500, 1_000, 5_000, 6_250, 8_333, 9_000, 10_000, 12_500, 25_000, 100_000, 1_000_000]

    @ObservedObject private var bank: SDRChannelBank

    init(controller: SDRController, settings: SDRSettingsStore) {
        self.controller = controller
        self.settings = settings
        bank = controller.bank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bank.isActive {
                Text("KANALBANK · \(bank.slots.filter(\.enabled).count) Kanäle zugleich, Mitte \(SDRFormat.frequency(controller.loHz)) MHz. Frequenzen, Betriebsarten und Decoder je Kanal stehen im Modul MEHRKANAL.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    label("LAUTST.")
                    Slider(value: $settings.volume, in: 0...1)
                }
            } else {
                frequencyRow
                modeRow
                bandwidthRow
                levelRow
                optionsRow
            }
            Divider().overlay(RadioTheme.borderSubtle)
            deviceRow
            statusLine
        }
        .onAppear { frequencyText = Self.plainMHz(settings.frequencyHz) }
        .onChange(of: settings.frequencyHz) { _, new in if !frequencyFocused { frequencyText = Self.plainMHz(new) } }
    }

    private static func plainMHz(_ hz: Double) -> String {
        String(format: "%.6f", hz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    private func commitFrequency() {
        let cleaned = frequencyText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let mhz = Double(cleaned), mhz > 0 { controller.tune(frequencyHz: mhz * 1e6) }
        frequencyText = Self.plainMHz(settings.frequencyHz)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }

    private var frequencyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button("−") { controller.step(-1) }.buttonStyle(ModeButtonStyle(isSelected: false))
                TextField("MHz", text: $frequencyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .multilineTextAlignment(.center)
                    .focused($frequencyFocused)
                    .onSubmit { commitFrequency() }
                    .padding(.vertical, 3)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(5)
                    .help("Frequenz in MHz eingeben und Return drücken; im HF-Wasserfall klicken oder das Mausrad drehen")
                Button("+") { controller.step(1) }.buttonStyle(ModeButtonStyle(isSelected: false))
            }
            HStack(spacing: 6) {
                label("SCHRITT")
                Menu(SDRFormat.stepName(settings.stepHz)) {
                    ForEach(Self.steps, id: \.self) { s in Button(SDRFormat.stepName(s)) { settings.stepHz = s } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Text("MITTE " + SDRFormat.frequency(controller.loHz) + " MHz")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
    }

    private var modeRow: some View {
        HStack(spacing: 4) {
            ForEach([SDRMode.wfm, .nfm, .am, .usb, .lsb, .cw]) { m in
                Button(m.title) { settings.select(mode: m) }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.mode == m || (m == .cw && settings.mode == .cwr)))
                    .lineLimit(1)
                    .help(Self.modeHelp(m))
            }
        }
    }

    private static func modeHelp(_ m: SDRMode) -> String {
        switch m {
        case .wfm: return "UKW-Rundfunk mit Stereo-Decoder (19-kHz-Pilot), 230 kHz Kanalbreite und De-Emphase; liefert das Multiplexsignal für RDS"
        case .nfm: return "Schmalband-FM: Sprechfunk, AIS, APRS, Funkruf, Radiosonden (Diskriminator-Audio ohne De-Emphase)"
        case .am: return "Amplitudenmodulation: Flugfunk, ACARS, VOR/ILS"
        case .usb: return "Oberes Seitenband (Dial = Trägerfrequenz bei unterdrücktem Träger)"
        case .lsb: return "Unteres Seitenband"
        default: return "Telegrafie: der Träger auf der Dial-Frequenz wird als Ton hörbar"
        }
    }

    private var bandwidthRow: some View {
        HStack(spacing: 4) {
            label("BREITE")
            ForEach(settings.mode.bandwidthChoices, id: \.self) { b in
                Button(Self.bwText(b)) { settings.bandwidthHz = b }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.bandwidthHz == b))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .scaleEffect(0.9)
            }
        }
    }

    private static func bwText(_ b: Double) -> String {
        b >= 1000 ? String(format: "%gk", b / 1000).replacingOccurrences(of: ".", with: ",") : String(format: "%g", b)
    }

    private var levelRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label("SIGNAL")
                Spacer(minLength: 4)
                let db = controller.snapshot.metrics.signalDB
                let (sText, _) = SDRSMeterScale.reading(db: db)
                let sColor = SMeterView.zoneColor(for: db)
                HStack(spacing: 5) {
                    Text(sText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(sColor)
                    Text(String(format: "%+.0f dB", db))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            SMeterView(
                db: controller.snapshot.metrics.signalDB,
                squelchDB: settings.squelchEnabled ? settings.squelchDB : nil,
                open: controller.snapshot.metrics.squelchOpen || !settings.squelchEnabled
            )
            .frame(height: 22)
            if settings.mode == .wfm {
                HStack(spacing: 6) {
                    label("STEREO")
                    let m = controller.snapshot.metrics
                    Text(!settings.wfmStereo ? "MONO (aus)" : m.stereoLocked ? (m.stereoBlend > 0.9 ? "STEREO" : "STEREO · MISCHT (\(Int(m.stereoBlend * 100)) %)") : "MONO · KEIN PILOT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(m.stereoLocked && settings.wfmStereo ? RadioTheme.vfdGreen : RadioTheme.textMuted)
                    Spacer(minLength: 0)
                    Text(String(format: "PILOT %.1f kHz", m.pilotKHz))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            HStack(spacing: 6) {
                Button("SQUELCH") { settings.squelchEnabled.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.squelchEnabled))
                    .scaleEffect(0.9, anchor: .leading)
                    .help("Ton sperren, wenn die Kanalleistung unter der Schwelle liegt (nicht für digitale Verfahren einschalten, die Rauschen brauchen)")
                Slider(value: $settings.squelchDB, in: -100...(-10))
                    .disabled(!settings.squelchEnabled)
                Text(String(format: "%.0f", settings.squelchDB))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .frame(width: 28, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Button("MITHÖREN") { settings.monitor.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.monitor))
                    .scaleEffect(0.9, anchor: .leading)
                    .help("Das demodulierte Audio über den Standard-Ausgang des Macs hören")
                Slider(value: $settings.volume, in: 0...1)
                    .disabled(!settings.monitor)
            }
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 4) {
            Button("FOLGT MODUL") { settings.followModules.toggle() }
                .buttonStyle(ModeButtonStyle(isSelected: settings.followModules))
                .lineLimit(1)
                .scaleEffect(0.85, anchor: .leading)
                .help("Das gewählte Modul (AIS, APRS, Funkruf, FT8 …) stellt Frequenz, Betriebsart und Breite ein, wenn es eine feste Frequenz hat")
            Spacer(minLength: 0)
            if settings.mode == .wfm {
                Button("STEREO") { settings.wfmStereo.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.wfmStereo))
                    .scaleEffect(0.85)
                    .help("Stereo decodieren, sobald der 19-kHz-Pilot da ist; bei schwachem Empfang wird langsam auf Mono übergeblendet")
                Button(settings.wfmDeemphasis75 ? "75 µs" : "50 µs") { settings.wfmDeemphasis75.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .scaleEffect(0.85)
                    .help("Zeitkonstante der De-Emphase: 50 µs in Europa, 75 µs in Amerika und Japan")
            }
            if settings.mode == .nfm || settings.mode == .wfm {
                Button("DE-EMPH") { settings.deemphasis.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.deemphasis))
                    .scaleEffect(0.85)
                    .help(settings.mode == .wfm ? "De-Emphase des Rundfunks (hell = an; Rundfunk braucht sie)" : "De-Emphase für Sprache (75 µs). Für Digitalverfahren aus.")
            }
            if settings.mode == .nfm {
                Button("AFC") { settings.afc.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.afc))
                    .scaleEffect(0.85)
                    .help("Gleichanteil des Demodulators nachführen (gleicht eine Frequenzablage des Senders aus)")
            }
            if settings.mode.isSSB {
                Button("AGC") { settings.agc.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.agc))
                    .scaleEffect(0.85)
                    .help("Automatische Verstärkungsregelung")
            }
        }
    }

    private var deviceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                label("GERÄT")
                ForEach([ADSBSourceKind.hackrf, .rtlsdr, .sdrplay]) { k in
                    Button(k.title) { settings.source = k }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.source == k))
                        .lineLimit(1)
                        .scaleEffect(0.9)
                        .help(k.detail)
                }
                Spacer(minLength: 0)
                Button(showGain ? "▾ GAIN" : "▸ GAIN") { showGain.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: showGain))
                    .scaleEffect(0.9, anchor: .trailing)
                    .help("Verstärkung und Zusatzfunktionen des Geräts")
            }
            SDRWindowPicker(settings: settings)
            if settings.source == .sdrplay { SDRplayOverloadHint() }
            if showGain { gainControls }
        }
    }

    @ViewBuilder
    private var gainControls: some View {
        switch settings.source {
        case .hackrf:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button("AMP 14 dB") { settings.hackrfAmp.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfAmp)).scaleEffect(0.9, anchor: .leading)
                    Button("BIAS-T") { settings.hackrfBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfBias)).scaleEffect(0.9, anchor: .leading)
                }
                stepper("LNA", "\(settings.hackrfLNA) dB", minus: { settings.hackrfLNA = max(0, settings.hackrfLNA - 8) }, plus: { settings.hackrfLNA = min(40, settings.hackrfLNA + 8) })
                stepper("VGA", "\(settings.hackrfVGA) dB", minus: { settings.hackrfVGA = max(0, settings.hackrfVGA - 2) }, plus: { settings.hackrfVGA = min(62, settings.hackrfVGA + 2) })
            }
        case .rtlsdr:
            VStack(alignment: .leading, spacing: 4) {
                stepper("GAIN", settings.rtlGain > 0 ? String(format: "%.1f dB", settings.rtlGain) : "AGC",
                        minus: { settings.rtlGain = settings.rtlGain <= 0 ? 0 : max(0, settings.rtlGain - 4) },
                        plus: { settings.rtlGain = min(49.6, settings.rtlGain + 4) })
                HStack(spacing: 4) {
                    Button("BIAS-T") { settings.rtlBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.rtlBias)).scaleEffect(0.9, anchor: .leading)
                    stepper("PPM", "\(settings.rtlPPM)", minus: { settings.rtlPPM -= 1 }, plus: { settings.rtlPPM += 1 })
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    label("TUNER")
                    Button("A") { settings.sdrplayTuner = 0 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 0))
                    Button("B") { settings.sdrplayTuner = 1 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 1))
                    Button("AGC") { settings.sdrplayAGC.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayAGC))
                    Button("BIAS-T") { settings.sdrplayBias.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayBias))
                }
                .scaleEffect(0.9, anchor: .leading)
                SDRplayNotchButtons(rf: $settings.sdrplayRfNotch, dab: $settings.sdrplayDabNotch)
                    .scaleEffect(0.9, anchor: .leading)
                HStack(spacing: 4) {
                    label("FILTER")
                    Menu {
                        Button("Automatisch (nach der Rate)") { settings.sdrplayBandwidth = 0 }
                        ForEach(SDRplayPlan.bandwidthsKHz, id: \.self) { kHz in
                            Button(Self.filterName(kHz)) { settings.sdrplayBandwidth = kHz }
                        }
                    } label: {
                        Text(settings.sdrplayBandwidth == 0
                             ? "AUTO · " + Self.filterName(SDRplayPlan.bandwidthKHz(outputHz: Double(settings.effectiveSampleRate), requested: 0))
                             : Self.filterName(settings.sdrplayBandwidth))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Analoger ZF-Filter des SDRplay vor dem Wandler (200 kHz bis 8 MHz). Automatisch: bei Raten ab 2 MS/s der größte, der nicht breiter ist als die Rate; darunter der kleinste, der die Rate noch durchlässt. Ein schmalerer Filter hält Nachbarsender fern, muss aber mindestens so breit sein wie das Signal. Bei Raten unter 2 MS/s dezimiert die API digital.")
                }
                .scaleEffect(0.9, anchor: .leading)
                stepper("LNA-DÄMPFUNG", "Stufe \(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) }, plus: { settings.sdrplayLNAState = min(9, settings.sdrplayLNAState + 1) }, help: SDRplayHelp.lna)
                stepper("ZF-DÄMPFUNG", "\(settings.sdrplayIFGain) dB", minus: { settings.sdrplayIFGain = max(20, settings.sdrplayIFGain - 2) }, plus: { settings.sdrplayIFGain = min(59, settings.sdrplayIFGain + 2) }, help: SDRplayHelp.ifGain)
            }
        }
    }

    /// „200 kHz“, „1,536 MHz“, „5 MHz“
    static func filterName(_ kHz: Int) -> String {
        kHz < 1000 ? "\(kHz) kHz" : String(format: "%g MHz", Double(kHz) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    private func stepper(_ title: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void, help: String = "") -> some View {
        HStack(spacing: 6) {
            label(title)
            Button("−", action: minus).buttonStyle(ModeButtonStyle(isSelected: false))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(minWidth: 52)
            Button("+", action: plus).buttonStyle(ModeButtonStyle(isSelected: false))
        }
        .help(help)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let m = controller.tuneMessage {
            Text(m)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.ledYellow)
                .fixedSize(horizontal: false, vertical: true)
        }
        if controller.snapshot.clippedFraction > 0.02 {
            Text("Übersteuert: Verstärkung verringern.")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.ledRed)
        } else if controller.snapshot.activity > 0 && controller.snapshot.activity < 2.0 {
            Text("Zu schwach ausgesteuert: Verstärkung erhöhen.")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
        }
        if controller.snapshot.droppedBlocks > 0 {
            Text("Rechner zu langsam: \(controller.snapshot.droppedBlocks) Datenblöcke verworfen.")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
        }
    }
}

/// Professionelles S-Meter nach IARU-Standard (S0 bis S9+46 dB) mit gestochen scharfer Skala,
/// VFD-Farbzonen (S0–S3 bläulich, S3–S9 grün, S9–S9+10 gelb-orange, ab S9+10 orange-rot),
/// LED-Segmentierung und Squelch-Schwellenmarker
struct SMeterView: View {
    let db: Double
    var squelchDB: Double? = nil
    let open: Bool

    public static func zoneColor(for db: Double) -> Color {
        switch SDRSMeterScale.zone(for: db) {
        case .blue:
            return Color(red: 0.25, green: 0.65, blue: 1.00)
        case .green:
            return RadioTheme.vfdGreen
        case .yellow:
            return RadioTheme.ledYellow
        case .red:
            return db <= -26.0 ? RadioTheme.vfdAmber : RadioTheme.ledRed
        }
    }

    private struct TickItem {
        let db: Double
        let isMajor: Bool
        var fraction: CGFloat { CGFloat(SDRSMeterScale.fraction(db: db)) }
    }

    private static let ticks: [TickItem] = [
        TickItem(db: -94.0, isMajor: false), // S1
        TickItem(db: -88.0, isMajor: false), // S2
        TickItem(db: -82.0, isMajor: true),  // S3
        TickItem(db: -76.0, isMajor: false), // S4
        TickItem(db: -70.0, isMajor: true),  // S5
        TickItem(db: -64.0, isMajor: false), // S6
        TickItem(db: -58.0, isMajor: true),  // S7
        TickItem(db: -52.0, isMajor: false), // S8
        TickItem(db: -46.0, isMajor: true),  // S9
        TickItem(db: -36.0, isMajor: true),  // +10
        TickItem(db: -26.0, isMajor: true),  // +20
        TickItem(db: -16.0, isMajor: false), // +30
        TickItem(db: -6.0,  isMajor: true),  // +40
    ]

    var body: some View {
        VStack(spacing: 2) {
            scaleHeader
                .frame(height: 11)
            barView
                .frame(height: 8)
        }
    }

    private var scaleHeader: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                // Ticks nach unten zur Oberkante des Balkens
                Path { p in
                    for item in Self.ticks {
                        let x = w * item.fraction
                        let tickH: CGFloat = item.isMajor ? 4.0 : 2.5
                        p.move(to: CGPoint(x: x, y: h))
                        p.addLine(to: CGPoint(x: x, y: h - tickH))
                    }
                }
                .stroke(RadioTheme.borderSubtle, lineWidth: 0.75)

                // S3-Tick (bläulich)
                Path { p in
                    let x3 = w * CGFloat(SDRSMeterScale.fraction(db: -82.0))
                    p.move(to: CGPoint(x: x3, y: h)); p.addLine(to: CGPoint(x: x3, y: h - 3.5))
                }
                .stroke(Color(red: 0.25, green: 0.65, blue: 1.00), lineWidth: 0.8)

                // S9-Tick (grün)
                Path { p in
                    let x9 = w * CGFloat(SDRSMeterScale.fraction(db: -46.0))
                    p.move(to: CGPoint(x: x9, y: h)); p.addLine(to: CGPoint(x: x9, y: h - 4.5))
                }
                .stroke(RadioTheme.vfdGreen, lineWidth: 1.0)

                // +10-Tick (gelb)
                Path { p in
                    let x10 = w * CGFloat(SDRSMeterScale.fraction(db: -36.0))
                    p.move(to: CGPoint(x: x10, y: h)); p.addLine(to: CGPoint(x: x10, y: h - 4.0))
                }
                .stroke(RadioTheme.ledYellow, lineWidth: 1.0)

                // +20, +40 Ticks (orange / rot)
                Path { p in
                    let x20 = w * CGFloat(SDRSMeterScale.fraction(db: -26.0))
                    let x40 = w * CGFloat(SDRSMeterScale.fraction(db: -6.0))
                    p.move(to: CGPoint(x: x20, y: h)); p.addLine(to: CGPoint(x: x20, y: h - 4.0))
                    p.move(to: CGPoint(x: x40, y: h)); p.addLine(to: CGPoint(x: x40, y: h - 4.0))
                }
                .stroke(RadioTheme.ledRed.opacity(0.85), lineWidth: 1.0)

                // Skalenbeschriftung farblich passend zu den Zonen
                Group {
                    scaleText("S", at: 3, color: Color(red: 0.25, green: 0.65, blue: 1.00), bold: true)
                    scaleText("3", at: w * 0.18, color: Color(red: 0.25, green: 0.65, blue: 1.00))
                    scaleText("5", at: w * 0.30, color: RadioTheme.vfdGreen)
                    scaleText("7", at: w * 0.42, color: RadioTheme.vfdGreen)
                    scaleText("9", at: w * 0.54, color: RadioTheme.vfdGreen, bold: true)
                    scaleText("+10", at: w * 0.64, color: RadioTheme.ledYellow, bold: true)
                    scaleText("+20", at: w * 0.74, color: RadioTheme.vfdAmber, bold: true)
                    scaleText("+40", at: min(w - 11, w * 0.94), color: RadioTheme.ledRed.opacity(0.9), bold: true)
                }
            }
        }
    }

    private func scaleText(_ text: String, at x: CGFloat, color: Color, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 7, weight: bold ? .bold : .medium, design: .monospaced))
            .foregroundColor(color)
            .position(x: x, y: 3.5)
    }

    private var sMeterGradient: some View {
        LinearGradient(
            stops: [
                // S0 - S3 (0.00 ... 0.18): bläulich
                .init(color: Color(red: 0.15, green: 0.52, blue: 0.95), location: 0.00),
                .init(color: Color(red: 0.18, green: 0.65, blue: 0.95), location: 0.16),
                // S3 - S9 (0.18 ... 0.54): grün
                .init(color: RadioTheme.vfdGreen, location: 0.19),
                .init(color: RadioTheme.vfdGreen, location: 0.52),
                // S9 - S9+10 (0.54 ... 0.64): gelb-orange
                .init(color: RadioTheme.ledYellow, location: 0.55),
                .init(color: RadioTheme.vfdAmber, location: 0.63),
                // ab S9+10 (0.64 ... 1.00): orange - rot
                .init(color: Color(red: 1.00, green: 0.45, blue: 0.12), location: 0.66),
                .init(color: RadioTheme.ledRed, location: 1.00)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var barView: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let v = CGFloat(SDRSMeterScale.fraction(db: db))
            let fillW = max(0, min(w, w * v))

            ZStack(alignment: .leading) {
                // Hintergrund-Schacht
                RoundedRectangle(cornerRadius: 2)
                    .fill(RadioTheme.bgDeep)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(RadioTheme.borderSubtle, lineWidth: 0.75)
                    )

                // Aktiver Signalpegel (Gradient an gesamter Breite w verankert, per Maske auf fillW beschnitten)
                if fillW > 1 {
                    sMeterGradient
                        .frame(width: w, height: h)
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .frame(width: fillW, height: h)
                        }
                        .opacity(open ? 1.0 : 0.35)
                }

                // Subtile vertikale LED-Segment-Teiler
                Path { p in
                    var x: CGFloat = 5.0
                    while x < w - 2 {
                        p.move(to: CGPoint(x: x, y: 1))
                        p.addLine(to: CGPoint(x: x, y: h - 1))
                        x += 5.0
                    }
                }
                .stroke(RadioTheme.bgDeep.opacity(0.85), lineWidth: 0.75)

                // Squelch-Schwellen-Marker
                if let sq = squelchDB {
                    let sqX = max(1, min(w - 2, w * CGFloat(SDRSMeterScale.fraction(db: sq))))
                    Rectangle()
                        .fill(RadioTheme.vfdAmber)
                        .frame(width: 1.5, height: h)
                        .position(x: sqX, y: h / 2)
                        .shadow(color: RadioTheme.vfdAmber.opacity(0.6), radius: 1.5)
                }
            }
        }
    }
}

private typealias SMeter = SMeterView
