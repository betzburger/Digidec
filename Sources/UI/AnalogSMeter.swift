// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - Umschalter Abstimmanzeige ↔ S-Meter

/// Die Karte „Abstimmanzeige“: zeigt entweder die Anzeige des Moduls oder das analoge S-Meter des SDR-Empfängers.
/// Die Wahl gilt für alle Module und bleibt gespeichert.
struct TuningDisplayCard<Content: View>: View {
    let content: Content
    @ObservedObject var controller: SDRController
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var settings: SDRSettingsStore
    @AppStorage("digidec.tuningDisplayStyle") private var style = "tuning"

    var body: some View {
        Group {
            if style == "smeter" {
                AnalogSMeterPanel(controller: controller, audio: audio, settings: settings)
            } else {
                content
            }
        }
        .radioCard(title: "Abstimmanzeige", accessory: AnyView(toggle))
    }

    private var toggle: some View {
        ButtonGrid {
            Button("ABSTIMMUNG") { style = "tuning" }
                .buttonStyle(ModeButtonStyle(isSelected: style != "smeter", compact: true))
                .help("Abstimmanzeige des Moduls (Scope, Signalgüte, Mitte)")
            Button("S-METER") { style = "smeter" }
                .buttonStyle(ModeButtonStyle(isSelected: style == "smeter", compact: true))
                .help("Analoges S-Meter des SDR-Empfängers (IARU: S9 = −46 dBFS, 6 dB je S-Stufe)")
        }
    }
}

extension View {
    /// Karte „Abstimmanzeige“ mit Umschalter auf das analoge S-Meter
    func tuningCard(_ state: DigidecState) -> some View {
        TuningDisplayCard(content: self, controller: state.sdrController, audio: state.audio, settings: state.sdr)
    }
}

// MARK: - Karte mit Messwerten

struct AnalogSMeterPanel: View {
    @ObservedObject var controller: SDRController
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var settings: SDRSettingsStore

    var body: some View {
        // Entwicklungshilfe für Schnappschüsse: DIGIDEC_SMETER_DEMO=<dBFS> zeigt das beleuchtete Instrument ohne Empfänger
        let demo = ProcessInfo.processInfo.environment["DIGIDEC_SMETER_DEMO"].flatMap(Double.init)
        let running: Bool = { if case .running = controller.status { return true } else { return false } }()
        let live = demo != nil || (audio.sourceKind == .sdr && controller.isSelected && !controller.isSuspended && running)
        let db = demo ?? (live ? controller.snapshot.metrics.signalDB : SDRSMeterScale.minDB)
        VStack(spacing: 8) {
            AnalogSMeterView(db: db, lit: live)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if live {
                    let (sText, _) = SDRSMeterScale.reading(db: db)
                    Text(sText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(SMeterView.zoneColor(for: db))
                    Text(String(format: "%+.0f dBFS", db))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                    Spacer(minLength: 4)
                    Text(settings.mode.title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Text(SDRFormat.frequency(settings.frequencyHz) + " MHz")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                } else {
                    Text("KEIN SDR-EMPFANG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(1.0)
                    Spacer(minLength: 0)
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - Zeigerbewegung

/// Zeigerbewegung wie bei einem Drehspulinstrument: Feder mit Dämpfung, leichtes Überschwingen
final class NeedleBallistics: @unchecked Sendable {
    private var value = 0.0
    private var velocity = 0.0
    private var last: Date?

    /// 0 … 1 für den Zielwert; der Zeiger folgt mit Eigenfrequenz ≈ 2,2 Hz und Dämpfung 0,8
    func step(target: Double, now: Date) -> Double {
        guard let last else { self.last = now; value = target; return value }
        let dt = min(0.1, max(0, now.timeIntervalSince(last)))
        self.last = now
        let omega = 14.0, zeta = 0.8
        let n = 4
        let h = dt / Double(n)
        for _ in 0..<n {
            let acc = omega * omega * (target - value) - 2 * zeta * omega * velocity
            velocity += acc * h
            value += velocity * h
        }
        return value
    }
}

// MARK: - Instrument

/// Analoges S-Meter im Stil der Transceiver der 1970er/80er Jahre: Metallrahmen mit Schrauben, hinterleuchtete Skala (Bernstein),
/// S-Stufen nach IARU, rote Zone über S9, zweite Skala in dBFS, Zeiger mit Schatten, Glasreflex.
struct AnalogSMeterView: View {
    let db: Double
    let lit: Bool
    @State private var ballistics = NeedleBallistics()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let target = SDRSMeterScale.fraction(db: db)
                let needle = ballistics.step(target: target, now: timeline.date)
                SMeterPainter(size: size, needle: needle, lit: lit).draw(&ctx)
            }
        }
        .aspectRatio(1.75, contentMode: .fit)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        .accessibilityLabel("S-Meter")
    }
}

private struct SMeterPainter {
    let size: CGSize
    let needle: Double
    let lit: Bool

    // Farben des Aufdrucks (dunkles Braun auf Bernstein)
    private let ink = Color(red: 0.13, green: 0.07, blue: 0.03)
    private let inkSoft = Color(red: 0.30, green: 0.17, blue: 0.07)
    private let red = Color(red: 0.72, green: 0.07, blue: 0.04)

    private var faceRect: CGRect { CGRect(origin: .zero, size: size).insetBy(dx: 9, dy: 9) }
    private var faceH: CGFloat { faceRect.height }
    private var pivot: CGPoint { CGPoint(x: faceRect.midX, y: faceRect.minY + faceH * 1.20) }
    private var radius: CGFloat { faceH * 0.98 }
    private var maxAngle: Double { min(52.0 * .pi / 180, asin(Double((faceRect.width / 2 - 20) / radius))) }

    private func angle(db: Double) -> Double { -maxAngle + 2 * maxAngle * SDRSMeterScale.fraction(db: db) }
    private func point(_ a: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: pivot.x + r * CGFloat(sin(a)), y: pivot.y - r * CGFloat(cos(a)))
    }

    private func arc(from db0: Double, to db1: Double, radius r: CGFloat) -> Path {
        var p = Path()
        let steps = 90
        for i in 0...steps {
            let d = db0 + (db1 - db0) * Double(i) / Double(steps)
            let pt = point(angle(db: d), r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    func draw(_ ctx: inout GraphicsContext) {
        let outer = CGRect(origin: .zero, size: size)
        drawBezel(&ctx, outer)

        let face = Path(roundedRect: faceRect, cornerRadius: 6)
        ctx.drawLayer { layer in
            layer.clip(to: face)
            drawFace(&layer)
            drawScales(&layer)
            drawNeedle(&layer)
            drawPlate(&layer)
            if !lit { layer.fill(Path(faceRect), with: .color(.black.opacity(0.58))) }
            drawGlass(&layer, face)
        }
    }

    // MARK: Rahmen

    private func drawBezel(_ ctx: inout GraphicsContext, _ outer: CGRect) {
        let bezel = Path(roundedRect: outer, cornerRadius: 12)
        ctx.fill(bezel, with: .linearGradient(
            Gradient(colors: [Color(red: 0.46, green: 0.47, blue: 0.50), Color(red: 0.20, green: 0.21, blue: 0.23), Color(red: 0.07, green: 0.07, blue: 0.08)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(Path(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 11.5), with: .color(.black.opacity(0.8)), lineWidth: 1)
        ctx.stroke(Path(roundedRect: outer.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 10.5),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.45), .white.opacity(0.03), .clear]),
                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.6)), lineWidth: 1)
        // Absatz zur Scheibe: dunkle Fase mit Lichtkante unten
        let step = Path(roundedRect: faceRect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 8)
        ctx.fill(step, with: .linearGradient(Gradient(colors: [.black.opacity(0.9), Color(red: 0.16, green: 0.16, blue: 0.18)]),
                                             startPoint: CGPoint(x: 0, y: faceRect.minY), endPoint: CGPoint(x: 0, y: faceRect.maxY)))
        // Schrauben in den Ecken
        for c in [CGPoint(x: 4.5, y: 4.5), CGPoint(x: size.width - 4.5, y: 4.5), CGPoint(x: 4.5, y: size.height - 4.5), CGPoint(x: size.width - 4.5, y: size.height - 4.5)] {
            let r: CGFloat = 2.6
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .radialGradient(Gradient(colors: [Color(red: 0.75, green: 0.76, blue: 0.78), Color(red: 0.25, green: 0.26, blue: 0.28)]),
                                                center: CGPoint(x: c.x - 0.8, y: c.y - 0.8), startRadius: 0, endRadius: r * 1.4))
            ctx.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 0.6)
            var slot = Path()
            slot.move(to: CGPoint(x: c.x - r * 0.7, y: c.y + r * 0.35)); slot.addLine(to: CGPoint(x: c.x + r * 0.7, y: c.y - r * 0.35))
            ctx.stroke(slot, with: .color(.black.opacity(0.75)), lineWidth: 0.7)
        }
    }

    // MARK: Zifferblatt

    private func drawFace(_ ctx: inout GraphicsContext) {
        let rect = Path(faceRect)
        // Papier, von der Mitte her durchleuchtet
        ctx.fill(rect, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(red: 1.00, green: 0.91, blue: 0.64), location: 0),
                .init(color: Color(red: 0.96, green: 0.76, blue: 0.40), location: 0.55),
                .init(color: Color(red: 0.66, green: 0.41, blue: 0.13), location: 1),
            ]),
            center: CGPoint(x: faceRect.midX, y: faceRect.minY + faceH * 0.42), startRadius: 0, endRadius: faceRect.width * 0.72))
        // Lämpchen oben links und rechts
        for x in [faceRect.minX + 6, faceRect.maxX - 6] {
            ctx.fill(rect, with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.97, blue: 0.78).opacity(0.65), Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.18), .clear]),
                center: CGPoint(x: x, y: faceRect.minY - 2), startRadius: 0, endRadius: faceRect.width * 0.42))
        }
        // Papierstruktur: feine waagerechte Streifen
        var y = faceRect.minY
        while y < faceRect.maxY {
            ctx.fill(Path(CGRect(x: faceRect.minX, y: y, width: faceRect.width, height: 0.5)), with: .color(.black.opacity(0.018)))
            y += 2
        }
    }

    // MARK: Skalen

    private func drawScales(_ ctx: inout GraphicsContext) {
        let r = radius
        // Hauptskala: S0 … S9 dunkel, darüber rot und kräftiger
        ctx.stroke(arc(from: -100, to: -46, radius: r), with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
        ctx.stroke(arc(from: -46, to: 0, radius: r), with: .color(red), style: StrokeStyle(lineWidth: 3.2, lineCap: .butt))

        // Teilstriche nach außen (S-Stufen alle 6 dB, darüber alle 10 dB, Zwischenstriche alle 5 dB)
        var ticks: [(db: Double, len: CGFloat, color: Color, width: CGFloat)] = []
        for n in 0...9 {
            let major = n % 2 == 1
            ticks.append((-100 + 6 * Double(n), major ? 9 : 5.5, ink, major ? 1.3 : 0.9))
        }
        for k in 1...9 {
            let d = -46 + 5 * Double(k)
            if k % 2 == 0 { ticks.append((d, 9, red, 1.5)) } else { ticks.append((d, 5, red, 1.0)) }
        }
        for t in ticks {
            let a = angle(db: t.db)
            var p = Path()
            p.move(to: point(a, r)); p.addLine(to: point(a, r + t.len))
            ctx.stroke(p, with: .color(t.color), lineWidth: t.width)
        }

        // Ziffern innen, radial ausgerichtet
        for n in [1, 3, 5, 7, 9] {
            label("\(n)", db: -100 + 6 * Double(n), r: r - 13, size: 11, color: ink, &ctx)
        }
        for (d, t) in [(-36.0, "+10"), (-26.0, "+20"), (-16.0, "+30"), (-6.0, "+40")] {
            label(t, db: d, r: r - 13, size: 9.5, color: red, &ctx)
        }
        label("S", db: -100, r: r - 28, size: 13, color: ink, upright: true, &ctx)
        label("dB", db: -1, r: r - 28, size: 9, color: red, upright: true, &ctx)

        // Zweite Skala in dBFS, innen
        let r2 = r * 0.70
        ctx.stroke(arc(from: -100, to: 0, radius: r2), with: .color(inkSoft), lineWidth: 0.9)
        for d in stride(from: -100.0, through: 0.0, by: 10.0) {
            let a = angle(db: d)
            let major = Int(d) % 20 == 0
            var p = Path()
            p.move(to: point(a, r2)); p.addLine(to: point(a, r2 + (major ? 6 : 3.5)))
            ctx.stroke(p, with: .color(inkSoft), lineWidth: major ? 1.0 : 0.7)
            if major && d > -100 { label(d == 0 ? "0" : "\(Int(d))", db: d, r: r2 - 9, size: 7.5, color: inkSoft, &ctx) }
        }
        label("dBFS", db: -97, r: r2 - 10, size: 7, color: inkSoft, upright: true, &ctx)
    }

    private func label(_ text: String, db: Double, r: CGFloat, size: CGFloat, color: Color, upright: Bool = false, _ ctx: inout GraphicsContext) {
        let a = angle(db: db)
        let at = point(a, r)
        let t = Text(text).font(.system(size: size, weight: .bold, design: .rounded)).foregroundColor(color)
        ctx.drawLayer { l in
            l.translateBy(x: at.x, y: at.y)
            if !upright { l.rotate(by: Angle(radians: a)) }
            l.draw(t, at: .zero, anchor: .center)
        }
    }

    // MARK: Zeiger

    private func drawNeedle(_ ctx: inout GraphicsContext) {
        let clamped = max(-0.03, min(1.03, needle))
        let a = -maxAngle + 2 * maxAngle * clamped
        let tip = point(a, radius + 6)
        func body(offset: CGSize) -> Path {
            let base = 3.4 * 0.5
            let nx = CGFloat(cos(a)), ny = CGFloat(sin(a))   // senkrecht zur Zeigerrichtung
            var p = Path()
            p.move(to: CGPoint(x: pivot.x + nx * base + offset.width, y: pivot.y + ny * base + offset.height))
            p.addLine(to: CGPoint(x: tip.x + nx * 0.35 + offset.width, y: tip.y + ny * 0.35 + offset.height))
            p.addLine(to: CGPoint(x: tip.x - nx * 0.35 + offset.width, y: tip.y - ny * 0.35 + offset.height))
            p.addLine(to: CGPoint(x: pivot.x - nx * base + offset.width, y: pivot.y - ny * base + offset.height))
            p.closeSubpath()
            return p
        }
        // Schatten auf dem Zifferblatt (Parallaxe unter der Glasscheibe)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 1.6))
            l.fill(body(offset: CGSize(width: 3.0, height: 3.5)), with: .color(.black.opacity(lit ? 0.32 : 0.2)))
        }
        ctx.fill(body(offset: .zero), with: .color(Color(red: 0.09, green: 0.05, blue: 0.04)))
        // Lichtkante auf dem Zeiger
        var hi = Path()
        hi.move(to: point(a, radius * 0.5)); hi.addLine(to: tip)
        ctx.stroke(hi, with: .color(.white.opacity(lit ? 0.22 : 0.08)), lineWidth: 0.5)
    }

    // MARK: Fußplatte

    private func drawPlate(_ ctx: inout GraphicsContext) {
        let top = faceRect.minY + faceH * 0.88
        let plate = CGRect(x: faceRect.minX, y: top, width: faceRect.width, height: faceRect.maxY - top)
        ctx.fill(Path(plate), with: .linearGradient(
            Gradient(colors: [Color(red: 0.22, green: 0.15, blue: 0.10), Color(red: 0.07, green: 0.05, blue: 0.04)]),
            startPoint: CGPoint(x: 0, y: plate.minY), endPoint: CGPoint(x: 0, y: plate.maxY)))
        ctx.fill(Path(CGRect(x: plate.minX, y: plate.minY, width: plate.width, height: 1)), with: .color(.white.opacity(0.28)))
        ctx.fill(Path(CGRect(x: plate.minX, y: plate.minY - 1.2, width: plate.width, height: 1.2)), with: .color(.black.opacity(0.35)))
        let amber = Color(red: 1.0, green: 0.74, blue: 0.30).opacity(lit ? 0.95 : 0.35)
        let l = Text("DIGIDEC").font(.system(size: 7.5, weight: .heavy, design: .monospaced)).foregroundColor(amber)
        ctx.draw(l, at: CGPoint(x: plate.minX + 10, y: plate.midY), anchor: .leading)
        let r = Text("SIGNAL STRENGTH").font(.system(size: 6.5, weight: .bold, design: .monospaced)).foregroundColor(amber.opacity(0.8))
        ctx.draw(r, at: CGPoint(x: plate.maxX - 10, y: plate.midY), anchor: .trailing)
    }

    // MARK: Glas

    private func drawGlass(_ ctx: inout GraphicsContext, _ face: Path) {
        // Innenschatten am Rand der Scheibe
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 3))
            l.stroke(face, with: .color(.black.opacity(0.55)), lineWidth: 7)
        }
        // Reflex: schräges Lichtband oben
        var gloss = Path()
        gloss.move(to: CGPoint(x: faceRect.minX, y: faceRect.minY))
        gloss.addLine(to: CGPoint(x: faceRect.maxX, y: faceRect.minY))
        gloss.addLine(to: CGPoint(x: faceRect.maxX, y: faceRect.minY + faceH * 0.16))
        gloss.addQuadCurve(to: CGPoint(x: faceRect.minX, y: faceRect.minY + faceH * 0.50),
                           control: CGPoint(x: faceRect.midX + faceRect.width * 0.12, y: faceRect.minY + faceH * 0.20))
        gloss.closeSubpath()
        ctx.fill(gloss, with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0.0)]),
                                              startPoint: CGPoint(x: faceRect.minX, y: faceRect.minY),
                                              endPoint: CGPoint(x: faceRect.midX, y: faceRect.minY + faceH * 0.5)))
        // feine Lichtkante an der Oberkante der Scheibe
        ctx.stroke(Path(roundedRect: faceRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5.5),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.35), .clear]), startPoint: CGPoint(x: 0, y: faceRect.minY), endPoint: CGPoint(x: 0, y: faceRect.minY + 14)), lineWidth: 0.8)
    }
}
