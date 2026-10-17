// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftCrossUI
@testable import DigidecCore

// Ansichten des Linux-Frontends (SwiftCrossUI). Gezeichnet wird in Canvases.swift / OriginalChrome.swift.

/// Zeigerzustand eines Tastenrasters (Klasse, damit die Zeichen- und Ereignisfunktionen ihn teilen)
@MainActor
final class PointerState {
    var hover: String?
    var pressed: String?
    var rects: [(id: String, rect: CGRect)] = []
    func id(at x: Double, _ y: Double) -> String? { rects.first { $0.rect.contains(CGPoint(x: x, y: y)) }?.id }
}

/// Tastenraster mit Zeigerverhalten (Hover, Drücken, Loslassen = Wahl)
struct KeyGrid: View {
    var items: [KeyItem]
    var columns: KeyColumns = .row
    var compact = false
    var palette: ThemePalette
    var onTap: @MainActor (String) -> Void
    @State private var pointer = PointerState()

    var body: some View {
        let pointer = self.pointer
        CairoCanvas(minimumSize: (60, Int(KeyGridMetrics.height(count: items.count, columns: columns, compact: compact))),
                    draw: { [items, columns, compact, palette] cr, w, h in
                        pointer.rects = drawKeyGrid(cr, w, h, items: items, columns: columns, compact: compact, hover: pointer.hover, pressed: pointer.pressed, palette: palette)
                    },
                    onPress: { x, y in pointer.pressed = pointer.id(at: x, y) },
                    onRelease: { [onTap] x, y in
                        if let id = pointer.id(at: x, y), id == pointer.pressed { onTap(id) }
                        pointer.pressed = nil
                    },
                    onHover: { point in pointer.hover = point.flatMap { pointer.id(at: $0.0, $0.1) } })
            .frame(height: Int(KeyGridMetrics.height(count: items.count, columns: columns, compact: compact)))
    }
}

/// Modulleiste (HF, VHF/UHF)
struct ModuleBar: View {
    let model: AppModel
    @State private var pointer = PointerState()

    var body: some View {
        let pointer = self.pointer
        let model = self.model
        CairoCanvas(minimumSize: (400, 100),
                    draw: { cr, w, h in
                        pointer.rects = drawModuleBarCanvas(cr, w, h, selected: model.state.activeModule, hover: pointer.hover, pressed: pointer.pressed, palette: model.palette)
                    },
                    onPress: { x, y in pointer.pressed = pointer.id(at: x, y) },
                    onRelease: { x, y in
                        if let id = pointer.id(at: x, y), id == pointer.pressed, let module = DecoderModuleInfo(rawValue: id) { model.state.select(module: module) }
                        pointer.pressed = nil
                    },
                    onHover: { point in pointer.hover = point.flatMap { pointer.id(at: $0.0, $0.1) } })
            .frame(height: 100)
    }
}

// MARK: - FT8

struct FT8ActivityCard: View {
    let model: AppModel

    var body: some View {
        _ = model.revision
        let state = model.state
        let controller = state.ft8Controller, settings = state.ft8
        let p = model.palette
        return RadioCard("Bandaktivität", palette: p) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(summary(controller)).font(mono(9, .semibold)).foregroundColor(color(p.textDim))
                    Spacer()
                    KeyGrid(items: [
                        KeyItem(id: "cq", label: "NUR CQ", isSelected: settings.cqOnly),
                        KeyItem(id: "unsure", label: "?", isSelected: settings.showUncertain),
                        KeyItem(id: "log", label: "LOG", isSelected: controller.logEnabled),
                        KeyItem(id: "clear", label: "LEEREN", isSelected: false),
                    ], columns: .row, palette: p) { id in
                        switch id {
                        case "cq": settings.cqOnly.toggle()
                        case "unsure": settings.showUncertain.toggle()
                        case "log": controller.logEnabled.toggle()
                        default: controller.clear()
                        }
                        model.bump()
                    }
                    .frame(width: 4 * HardwareKeyMetrics.width(label: "LEEREN") + 3 * 6)
                }
                CairoCanvas(minimumSize: (300, 200)) { cr, w, h in
                    drawFT8Table(cr, w, h, entries: controller.visible, palette: p)
                }
            }
        }
    }

    private func summary(_ c: FT8Controller) -> String {
        guard let cycle = c.lastCycle else { return "Warten auf den ersten Zyklus" }
        return "\(cycle.decodes.count) Decodes um \(FT8Controller.utc.string(from: cycle.cycleStart).prefix(4)) UTC · "
            + String(format: "%.1f s Rechenzeit", cycle.duration)
    }
}

enum HardwareKeyMetrics {
    static func width(label: String) -> Int { Int(HardwareKeyPainter.width(for: label, compact: false)) }
}

struct FT8CycleCard: View {
    let model: AppModel

    var body: some View {
        _ = model.revision
        let state = model.state
        let controller = state.ft8Controller, settings = state.ft8
        let p = model.palette
        return RadioCard(nil, palette: p) {
            VStack(alignment: .leading, spacing: 8) {
                CairoCanvas(framesPerSecond: 8, minimumSize: (200, 30)) { cr, w, h in
                    drawFT8Cycle(cr, w, h, busy: controller.decoder.isBusy, palette: p)
                }
                .frame(height: 30)
                CairoCanvas(framesPerSecond: 2, minimumSize: (200, 16)) { cr, w, h in
                    drawReadouts(cr, w, h, items: [("ZYKLEN", "\(controller.cycleCount)"), ("RX", "\(Int(settings.rxHz)) Hz"),
                                                   ("DIAL", String(format: "%.3f", Double(settings.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ","))], palette: p)
                }
                .frame(height: 16)
                CairoCanvas(minimumSize: (200, 120)) { cr, w, h in
                    drawFT8Table(cr, w, h, entries: Array(controller.rxEntries.suffix(40)), palette: p)
                }
                .frame(height: 120)
            }
        }
    }
}

struct FT8SettingsCard: View {
    let model: AppModel
    @State private var call = ""
    @State private var locator = ""
    @State private var loaded = false

    var body: some View {
        _ = model.revision
        let settings = model.state.ft8
        let p = model.palette
        if !loaded { DispatchQueue.main.async { call = settings.myCall; locator = settings.locator; loaded = true } }
        return RadioCard("FT8", palette: p) {
            VStack(alignment: .leading, spacing: 8) {
                KeyGrid(items: FT8Band.allCases.map { KeyItem(id: $0.rawValue, label: $0.rawValue, isSelected: settings.band == $0) },
                        columns: .fill(6), palette: p) { id in
                    if let band = FT8Band(rawValue: id) { settings.band = band; model.bump() }
                }
                Text(dialHint(settings)).font(mono(9)).foregroundColor(color(p.textMuted))
                HStack(spacing: 6) {
                    Text("RUF").font(mono(8, .bold)).foregroundColor(color(p.textDim))
                    TextField("DL…", text: $call)
                        .onSubmit { settings.myCall = call.trimmingCharacters(in: .whitespaces).uppercased(); call = settings.myCall }
                        .frame(width: 90)
                    Text("LOC").font(mono(8, .bold)).foregroundColor(color(p.textDim))
                    TextField("JN49WS", text: $locator)
                        .onSubmit {
                            let l = locator.trimmingCharacters(in: .whitespaces).uppercased()
                            if Maidenhead.coordinate(l) != nil { settings.locator = l }
                            locator = settings.locator
                        }
                        .frame(width: 80)
                }
                HStack(spacing: 6) {
                    Text("RECHENZEIT").font(mono(8, .bold)).foregroundColor(color(p.textDim))
                    KeyGrid(items: [1.5, 3.0, 5.0].map { b in
                        KeyItem(id: "\(b)", label: String(format: "%.1f s", b).replacingOccurrences(of: ".", with: ","), isSelected: settings.core.budgetSeconds == b)
                    }, columns: .spread, palette: p) { id in
                        if let b = Double(id) { settings.core.budgetSeconds = b; model.bump() }
                    }
                }
                HStack(spacing: 6) {
                    Text("ZEITKORR.").font(mono(8, .bold)).foregroundColor(color(p.textDim))
                    Slider(value: Binding(get: { settings.timeOffset }, set: { settings.timeOffset = $0; model.bump() }), in: -1...1)
                    Text(String(format: "%+.2f s", settings.timeOffset)).font(mono(9, .semibold)).foregroundColor(color(p.vfdCyan))
                }
            }
        }
    }

    private func dialHint(_ settings: FT8SettingsStore) -> String {
        if let rig = settings.rigDialHz {
            let b = FT8Band.band(forDial: rig)
            return "Funkgerät: \(String(format: "%.3f", Double(rig) / 1_000_000).replacingOccurrences(of: ".", with: ",")) MHz" + (b.map { " (\($0.rawValue))" } ?? " – kein FT8-Kanal")
        }
        return "USB-Dial \(settings.band.dialLabel) MHz"
    }
}

// MARK: - Hauptfenster

struct MainView: View {
    let model: AppModel

    var body: some View {
        _ = model.revision
        let state = model.state
        let p = model.palette
        return VStack(spacing: 8) {
            CairoCanvas(framesPerSecond: 1, minimumSize: (400, 56)) { cr, w, h in drawHeaderCanvas(cr, w, h, palette: p) }
                .frame(height: 56)
            ModuleBar(model: model)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    RadioCard("Wasserfall", palette: p) {
                        CairoCanvas(minimumSize: (300, 200)) { cr, w, h in
                            drawFT8Waterfall(cr, w, h, image: state.waterfall.image, binWidth: state.waterfall.binWidth, rxHz: state.ft8.rxHz,
                                             minHz: state.ft8.core.minHz, maxHz: state.ft8.core.maxHz, palette: p)
                        }
                        .frame(height: 220)
                    }
                    FT8ActivityCard(model: model)
                }
                VStack(spacing: 8) {
                    RadioCard("Abstimmanzeige", palette: p) {
                        CairoCanvas(minimumSize: (300, 190)) { cr, w, h in
                            drawSMeterPanel(cr, w, h, db: -100, live: false, readingText: "", ballistics: model.ballistics, palette: p)
                        }
                        .frame(height: 190)
                    }
                    FT8CycleCard(model: model)
                    FT8SettingsCard(model: model)
                }
                .frame(width: 360)
            }
            Text(state.audio.statusText).font(mono(10)).foregroundColor(color(p.textMuted))
        }
        .padding(10)
        .background(color(p.bgDeep))
    }
}
