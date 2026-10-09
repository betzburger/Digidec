// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

/// Lineal am rechten Fensterrand: 0 bis 30 MHz von unten nach oben, gefärbt nach der Ausbreitung an diesem Ort und zu dieser Zeit
/// (rot = schlecht, weiß = mittel, grün = gut). Es zeigt auch das Fenster des SDR und die eingestellte Frequenz. Senkrecht, damit man es nicht
/// mit der Frequenzachse des Wasserfalls verwechselt.
struct PropagationRuler: View {
    @ObservedObject var service: PropagationService
    @ObservedObject var home: HomeLocation
    @ObservedObject var sdr: SDRController
    @ObservedObject var settings: SDRSettingsStore

    static let width: CGFloat = 62
    private static let maxMHz = 30.0
    private static let topPad: CGFloat = 40
    private static let bottomPad: CGFloat = 16
    private static let barX: CGFloat = 22
    private static let barWidth: CGFloat = 14
    /// Amateurfunkbänder (Mitte in MHz) als Beschriftung rechts des Balkens
    private static let bands: [(label: String, mhz: Double)] = [("160", 1.9), ("80", 3.65), ("40", 7.1), ("30", 10.12), ("20", 14.2), ("17", 18.12), ("15", 21.2), ("12", 24.94), ("10", 28.5)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snapshot = Snapshot(service: service, point: home.point ?? GeoPoint(lat: 50, lon: 10), located: home.point != nil, now: context.date)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(&ctx, size: size, snapshot: snapshot) }
                Text(snapshot.header)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 6)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { service.refresh(force: true) }
            .help(snapshot.help)
        }
        .frame(width: Self.width)
        .background(RadioTheme.bgDeep.opacity(0.6))
    }

    private struct Snapshot {
        var data: PropagationData?
        var elevation: Double
        var declination: Double
        var latitude: Double
        var header: String
        var help: String

        @MainActor
        init(service: PropagationService, point: GeoPoint, located: Bool, now: Date) {
            data = service.data
            latitude = point.lat
            elevation = SunPosition.elevationDegrees(latitude: point.lat, longitude: point.lon, date: now)
            declination = SunPosition.declinationDegrees(date: now)
            if let d = service.data {
                header = "SFI \(d.solarFlux.map(String.init) ?? "–")\nA \(d.aIndex.map(String.init) ?? "–")\nK \(d.kIndex.map(String.init) ?? "–")"
            } else {
                header = service.loading ? "lade …" : "keine\nDaten"
            }
            var lines = ["Kurzwellen-Ausbreitung 0 bis 30 MHz: rot schlecht, weiß mittel, grün gut"]
            if let d = service.data {
                let updated = d.updated.map { Self.format($0) } ?? "–"
                lines.append("Quelle: \(d.source) (N0NBH), Stand \(updated) UTC · Sonnenfluss \(d.solarFlux ?? 0), A-Index \(d.aIndex ?? 0), K-Index \(d.kIndex ?? 0), Sonnenflecken \(d.sunspots ?? 0)")
                lines.append(String(format: "Standort %.1f° N, %.1f° O · Sonne %+.0f° (%@) · Deklination %+.0f°", point.lat, point.lon, elevation, elevation > 6 ? "Tag" : elevation < -6 ? "Nacht" : "Dämmerung", declination))
                lines.append("Zwischen den Bandgruppen von HamQSL (80–40, 30–20, 17–15, 12–10 m) interpoliert, unter 3,5 MHz nach Tag/Nacht und Jahreszeit geschätzt. Grobe Orientierung, keine Streckenvorhersage.")
            } else if let e = service.lastError {
                lines.append("Abruf fehlgeschlagen: \(e)")
            }
            if !located { lines.append("Kein Standort eingetragen (Locator): Mitteleuropa angenommen") }
            lines.append("Klick: neu abrufen")
            help = lines.joined(separator: "\n")
        }

        static func format(_ d: Date) -> String {
            let f = DateFormatter()
            f.dateFormat = "dd.MM. HH:mm"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: d)
        }
    }

    private func y(_ mhz: Double, _ size: CGSize) -> CGFloat {
        let top = Self.topPad, bottom = size.height - Self.bottomPad
        return bottom - CGFloat(max(0, min(Self.maxMHz, mhz)) / Self.maxMHz) * (bottom - top)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, snapshot: Snapshot) {
        let barRect = CGRect(x: Self.barX, y: y(Self.maxMHz, size), width: Self.barWidth, height: y(0, size) - y(Self.maxMHz, size))
        // Farbbalken in 150 Stücken
        let steps = 150
        for k in 0..<steps {
            let lo = Self.maxMHz * Double(k) / Double(steps), hi = Self.maxMHz * Double(k + 1) / Double(steps)
            let mid = (lo + hi) / 2
            let color: Color
            if let d = snapshot.data {
                let c = PropagationModel.color(score: PropagationModel.score(frequencyMHz: mid, data: d, elevation: snapshot.elevation, declination: snapshot.declination, latitude: snapshot.latitude))
                color = Color(red: c.r, green: c.g, blue: c.b)
            } else {
                color = Color.gray.opacity(0.35)
            }
            let rect = CGRect(x: barRect.minX, y: y(hi, size), width: barRect.width, height: y(lo, size) - y(hi, size) + 0.6)
            ctx.fill(Path(rect), with: .color(color))
        }
        ctx.stroke(Path(roundedRect: barRect, cornerRadius: 2), with: .color(RadioTheme.borderSubtle), lineWidth: 1)

        // MHz-Skala links
        for mhz in stride(from: 0, through: 30, by: 5) {
            let yy = y(Double(mhz), size)
            ctx.stroke(Path { $0.move(to: CGPoint(x: Self.barX - 3, y: yy)); $0.addLine(to: CGPoint(x: Self.barX, y: yy)) }, with: .color(RadioTheme.textMuted), lineWidth: 1)
            ctx.draw(Text("\(mhz)").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textMuted),
                     at: CGPoint(x: Self.barX - 5, y: yy), anchor: .trailing)
        }
        // Amateurbänder rechts
        for b in Self.bands {
            let yy = y(b.mhz, size)
            ctx.stroke(Path { $0.move(to: CGPoint(x: barRect.maxX, y: yy)); $0.addLine(to: CGPoint(x: barRect.maxX + 3, y: yy)) }, with: .color(RadioTheme.textMuted), lineWidth: 1)
            ctx.draw(Text(b.label).font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim),
                     at: CGPoint(x: barRect.maxX + 5, y: yy), anchor: .leading)
        }
        ctx.draw(Text("MHz").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim), at: CGPoint(x: Self.barX + Self.barWidth / 2, y: size.height - 6), anchor: .center)

        // Fenster des SDR (nur der Teil unter 30 MHz)
        if sdr.isSelected, sdr.loHz > 0 {
            let half = SDRSettingsStore.window(forRate: Int(sdr.sampleRateHz)) / 1e6
            let lo = max(0, sdr.loHz / 1e6 - half), hi = min(Self.maxMHz, sdr.loHz / 1e6 + half)
            if hi > lo {
                let r = CGRect(x: barRect.minX - 2.5, y: y(hi, size), width: barRect.width + 5, height: y(lo, size) - y(hi, size))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(RadioTheme.vfdCyan), lineWidth: 1.6)
            }
        }
        // eingestellte Frequenz
        let f = settings.frequencyHz / 1e6
        if sdr.isSelected, f > 0, f <= Self.maxMHz {
            let yy = y(f, size)
            let tri = Path { p in
                p.move(to: CGPoint(x: barRect.minX - 1, y: yy))
                p.addLine(to: CGPoint(x: barRect.minX - 7, y: yy - 4))
                p.addLine(to: CGPoint(x: barRect.minX - 7, y: yy + 4))
                p.closeSubpath()
            }
            ctx.fill(tri, with: .color(RadioTheme.vfdAmber))
            ctx.stroke(Path { $0.move(to: CGPoint(x: barRect.minX, y: yy)); $0.addLine(to: CGPoint(x: barRect.maxX, y: yy)) }, with: .color(RadioTheme.vfdAmber), lineWidth: 1.4)
        }
    }
}
