// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit
import CoreGraphics

// MARK: - HF-Wasserfall

/// Bild des I/Q-Fensters: 4096 Bins werden zu 1024 Spalten (Maximum), 25 Zeilen je Sekunde
@MainActor
final class SDRSpectrumModel: ObservableObject {
    static let columns = 1024
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
    private var dbRows: [[Float]] = []
    private var needsRedraw = false
    private var timer: Timer?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(rows: @escaping @MainActor () -> [[Float]]) {
        rowSource = rows
        let saved = UserDefaults.standard.float(forKey: "sdrRangeDB")
        rangeDB = (20...90).contains(saved) ? saved : 55
        pixels = [UInt32](repeating: WaterfallColorMap.lut[0], count: Self.columns * Self.history)
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

    private func reduce(_ row: [Float]) -> [Float] {
        let f = row.count / Self.columns
        guard f > 0 else { return row }
        var out = [Float](repeating: -140, count: Self.columns)
        for c in 0..<Self.columns {
            var m: Float = -200
            for k in 0..<f { m = max(m, row[c * f + k]) }
            out[c] = m
        }
        return out
    }

    private func update() {
        let rows = rowSource()
        guard !rows.isEmpty || needsRedraw else { return }
        let width = Self.columns
        for raw in rows {
            let row = reduce(raw)
            // Rauschteppich: unteres Fünftel der Werte, langsam nachgeführt
            let sorted = row.sorted()
            let floor = sorted[sorted.count / 5]
            floorDB += (floor - floorDB) * (dbRows.isEmpty ? 1 : 0.05)
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
        pixels.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress! + r * Self.columns
            for i in 0..<Self.columns { base[i] = lut[WaterfallColorMap.index(db: row[i], floorDB: lo, rangeDB: rangeDB)] }
        }
    }

    private func makeImage() -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Self.columns, height: Self.history, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.columns * 4, space: colorSpace,
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

    @State private var hoverHz: Double?
    @State private var scrollMonitor: Any?

    init(controller: SDRController, settings: SDRSettingsStore, audio: AudioInputManager) {
        self.controller = controller
        self.settings = settings
        self.audio = audio
        bank = controller.bank
        _model = StateObject(wrappedValue: SDRSpectrumModelBox(controller: controller))
    }

    private var span: Double { Double(settings.effectiveSampleRate) }

    private func range() -> ClosedRange<Double> {
        let lo = controller.loHz
        return (lo - span / 2)...(lo + span / 2)
    }

    var body: some View {
        VStack(spacing: 6) {
            controls
            GeometryReader { geo in
                let r = range()
                let width = geo.size.width
                VStack(spacing: 0) {
                    RFAxis(range: r)
                        .frame(height: 16)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            RFSpectrumGraph(spectrum: model.value.spectrum, floorDB: model.value.floorDB, rangeDB: model.value.rangeDB)
                                .frame(height: 54)
                            waterfallImage
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
        .onAppear { installScroll(); model.value.start() }
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
    private var waterfallImage: some View {
        if let image = model.value.image {
            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
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
            Spacer(minLength: 8)
            Text(readout)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
            Spacer(minLength: 8)
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

    private var readout: String {
        var s = bank.isActive ? "\(bank.slots.filter(\.enabled).count) Kanäle" : SDRFormat.frequency(settings.frequencyHz) + " MHz " + settings.mode.title
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

    /// Mausrad über dem Wasserfall stimmt ab (ein Schritt je Rasterung, mit Umschalttaste zehn)
    private func installScroll() {
        guard scrollMonitor == nil else { return }
        let c = controller
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard MainActor.assumeIsolated({ SDRHoverState.shared.hovering && !c.bank.isActive }) else { return event }
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

/// Breite des I/Q-Fensters: beim HackRF bis 20 MS/s wählbar, die anderen Geräte laufen fest mit 2,4 MS/s
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
                    Button("\(Self.rateText(r)) MS/s · nutzbar \(Self.widthText(r))") { settings.sampleRateHz = r }
                }
            } label: {
                Text("\(Self.rateText(rate)) MS/s · \(Self.widthText(rate))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(choices.count < 2)
            .help(choices.count < 2 ? "Dieses Gerät läuft fest mit 2,4 MS/s (nur dort geprüft)" : "Breite des I/Q-Fensters, das der HackRF liefert: der HF-Wasserfall zeigt so viel auf einmal, Mehrkanalbetrieb nutzt es für mehrere Decoder. Höhere Raten brauchen mehr Rechenzeit und einen schnellen USB-Anschluss; 20 MS/s braucht USB 3 oder einen guten USB-2-Anschluss ohne Hub.")
            Spacer(minLength: 0)
            if rate >= 14_400_000 {
                Text("viel Rechenlast")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
            }
        }
    }

    static func rateText(_ r: Int) -> String { String(format: "%g", Double(r) / 1e6).replacingOccurrences(of: ".", with: ",") }
    /// Nutzbare Breite (die Ränder des Geräts fallen ab): etwa 70 % der Abtastrate
    static func widthText(_ r: Int) -> String { String(format: "%.1f MHz", SDRSettingsStore.window(forRate: r) * 2 / 1e6).replacingOccurrences(of: ".", with: ",") }
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
            // Etwa zehn Marken: 200 kHz bei 2,4 MS/s, 500 kHz bei 4,8 und 1 MHz bei 9,6 MS/s
            let step = [200_000.0, 500_000, 1_000_000, 2_000_000].first { span / $0 <= 12 } ?? 2_000_000
            var f = (range.lowerBound / step).rounded(.up) * step
            while f <= range.upperBound {
                let x = CGFloat((f - range.lowerBound) / span) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 4))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(RadioTheme.textDim), lineWidth: 1)
                let label = Text(verbatim: String(format: step < 1_000_000 ? "%.1f" : "%.0f", f / 1e6).replacingOccurrences(of: ".", with: ","))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                ctx.draw(label, at: CGPoint(x: min(max(x, 14), size.width - 14), y: 6), anchor: .center)
                f += step
            }
        }
        .background(RadioTheme.bgPanel)
    }
}

struct RFSpectrumGraph: View {
    let spectrum: [Float]
    let floorDB: Float
    let rangeDB: Float

    var body: some View {
        Canvas { ctx, size in
            guard spectrum.count > 1 else { return }
            let bottom = floorDB - 12
            let top = floorDB + rangeDB + 6
            func point(_ i: Int) -> CGPoint {
                let x = CGFloat(i) / CGFloat(spectrum.count - 1) * size.width
                let v = CGFloat((spectrum[i] - bottom) / (top - bottom))
                return CGPoint(x: x, y: size.height * (1 - min(1, max(0, v))))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<spectrum.count { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(RadioTheme.vfdGreen.opacity(0.12)))
            ctx.stroke(line, with: .color(RadioTheme.vfdGreen), lineWidth: 1)
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
    @State private var showGain = false

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                label("PEGEL")
                SMeter(db: controller.snapshot.metrics.signalDB, open: controller.snapshot.metrics.squelchOpen || !settings.squelchEnabled)
                    .frame(height: 10)
                Text(String(format: "%.0f dB", controller.snapshot.metrics.signalDB))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 44, alignment: .trailing)
            }
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
                stepper("LNA", "\(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) }, plus: { settings.sdrplayLNAState = min(9, settings.sdrplayLNAState + 1) })
                stepper("ZF-MIND.", "\(settings.sdrplayIFGain) dB", minus: { settings.sdrplayIFGain = max(20, settings.sdrplayIFGain - 2) }, plus: { settings.sdrplayIFGain = min(59, settings.sdrplayIFGain + 2) })
            }
        }
    }

    private func stepper(_ title: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            label(title)
            Button("−", action: minus).buttonStyle(ModeButtonStyle(isSelected: false))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(minWidth: 52)
            Button("+", action: plus).buttonStyle(ModeButtonStyle(isSelected: false))
        }
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

/// Balken der Kanalleistung (−100 … 0 dB zur Vollaussteuerung)
private struct SMeter: View {
    let db: Double
    let open: Bool

    var body: some View {
        GeometryReader { geo in
            let v = CGFloat(max(0, min(1, (db + 100) / 100)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(RadioTheme.bgDeep)
                RoundedRectangle(cornerRadius: 2)
                    .fill(open ? RadioTheme.vfdGreen : RadioTheme.textDim)
                    .frame(width: geo.size.width * v)
            }
        }
    }
}
