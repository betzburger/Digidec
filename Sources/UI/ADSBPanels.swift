// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private let adsbHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)
private let adsbRowFont = Font.system(size: 11, weight: .medium, design: .monospaced)

// MARK: - Hauptbereich

struct ADSBMainPanel: View {
    @ObservedObject var controller: ADSBController
    @ObservedObject var settings: ADSBSettingsStore
    @ObservedObject var home: HomeLocation
    @State private var tab = Tab.fromEnvironment()

    enum Tab: String, CaseIterable, Identifiable {
        case aircraft = "FLUGZEUGE", messages = "MELDUNGEN"
        var id: String { rawValue }
        /// Entwicklungshilfe: DIGIDEC_ADSB_TAB=messages öffnet das Protokoll (für Schnappschüsse)
        static func fromEnvironment() -> Tab { ProcessInfo.processInfo.environment["DIGIDEC_ADSB_TAB"] == "messages" ? .messages : .aircraft }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Jedes Flugzeug nach dem Verschwinden mit Kennung, Land, Höhe und größter Entfernung in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Log-Datei im Finder zeigen")
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Liste leeren")
            }
            Group {
                switch tab {
                case .aircraft: ADSBAircraftTable(controller: controller, home: home)
                case .messages: ADSBMessageTable(entries: controller.recent)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        let n = controller.aircraft.count
        let p = controller.aircraft.filter(\.hasPosition).count
        if n == 0 { return statusText }
        return "\(n) Flugzeug\(n == 1 ? "" : "e") · \(p) mit Position · \(Int(controller.stats.messagesPerSecond.rounded())) Meldungen/s"
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Empfänger aus"
        case .running(let d): return "Warten auf Flugzeuge (\(d))"
        case .error(let m): return m
        }
    }
}

struct ADSBAircraftTable: View {
    @ObservedObject var controller: ADSBController
    let home: HomeLocation
    @Environment(\.openWindow) private var openWindow
    @State private var sort = Sort.recent

    enum Sort: String, CaseIterable { case recent = "ZULETZT", distance = "ENTFERNUNG", altitude = "HÖHE" }

    var body: some View {
        let now = Date()
        let list = sorted(controller.visibleAircraft)
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if list.isEmpty { Text(emptyText).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim).padding(4) }
                    ForEach(list) { a in row(a, now: now) }
                }
                .padding(6)
            }
        }
    }

    private func sorted(_ l: [ADSBAircraft]) -> [ADSBAircraft] {
        switch sort {
        case .recent: return l
        case .distance: return l.sorted { (distance($0) ?? .infinity) < (distance($1) ?? .infinity) }
        case .altitude: return l.sorted { ($0.altitudeFt ?? Int.min) > ($1.altitudeFt ?? Int.min) }
        }
    }

    private var emptyText: String {
        switch controller.status {
        case .running: return "Noch kein Flugzeug gehört. 1090 MHz, Antenne mit freier Sicht; Verstärkung in den Einstellungen anpassen."
        case .error(let m): return m
        case .idle: return "Empfänger aus"
        }
    }

    private func distance(_ a: ADSBAircraft) -> Double? {
        guard let p = a.position, let h = home.point else { return nil }
        return Geo.distanceKm(h, p)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                sortButton("ZULETZT").frame(width: 46, alignment: .leading)
                Text("ICAO").frame(width: 52, alignment: .leading)
                Text("Kennung").frame(width: 72, alignment: .leading)
                Text("Land").frame(width: 120, alignment: .leading)
                sortButton("HÖHE").frame(width: 56, alignment: .trailing)
                Text("km/h").frame(width: 42, alignment: .trailing)
                Text("Kurs").frame(width: 38, alignment: .trailing)
                Text("ft/min").frame(width: 50, alignment: .trailing)
                sortButton("ENTFERNUNG").frame(width: 70, alignment: .trailing)
                Text("Sqk").frame(width: 38, alignment: .leading)
            }
            Text("Info").frame(maxWidth: .infinity, alignment: .leading)
            Text("Mld").frame(width: 38, alignment: .trailing)
            Text("dB").frame(width: 34, alignment: .trailing)
        }
        .font(adsbHeaderFont)
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func sortButton(_ title: String) -> some View {
        let target: Sort = title == "ZULETZT" ? .recent : title == "HÖHE" ? .altitude : .distance
        return Button(title == "ENTFERNUNG" ? "Entfernung" : title == "HÖHE" ? "Höhe" : "Zuletzt") { sort = target }
            .buttonStyle(.plain)
            .foregroundColor(sort == target ? RadioTheme.vfdCyan : RadioTheme.textDim)
            .help("Nach \(title.lowercased()) sortieren")
    }

    private func row(_ a: ADSBAircraft, now: Date) -> some View {
        let selected = controller.selection == a.id
        let km = distance(a)
        let stale = a.ageSeconds(now: now) > 60
        let color: Color = a.emergencyText != nil ? RadioTheme.ledRed : stale ? RadioTheme.textDim : a.hasPosition ? RadioTheme.vfdGreen : RadioTheme.vfdAmber
        return HStack(spacing: 8) {
            Group {
                Text("\(a.ageSeconds(now: now)) s").frame(width: 46, alignment: .leading)
                Text(a.icaoText).frame(width: 52, alignment: .leading)
                Text(a.callsign ?? "").frame(width: 72, alignment: .leading).lineLimit(1)
                Text(a.country.map { "\($0.flag) \($0.name)" } ?? "").frame(width: 120, alignment: .leading).lineLimit(1)
                Text(a.altitudeText ?? "").frame(width: 56, alignment: .trailing)
                Text(a.groundSpeedKn.map { String(format: "%.0f", $0 * 1.852) } ?? "").frame(width: 42, alignment: .trailing)
                Text(a.trackDeg.map { String(format: "%.0f°", $0) } ?? "").frame(width: 38, alignment: .trailing)
                Text(a.verticalRateFpm.map { "\($0)" } ?? "").frame(width: 50, alignment: .trailing)
                Text(km.map { String(format: "%.0f km", $0) } ?? (a.hasPosition ? "" : "–")).frame(width: 70, alignment: .trailing)
                Text(a.squawk ?? "").frame(width: 38, alignment: .leading)
            }
            Text(info(a)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text("\(a.messages)").frame(width: 38, alignment: .trailing)
            Text(a.levelDB.map { String(format: "%.0f", $0) } ?? "").frame(width: 34, alignment: .trailing)
        }
        .font(adsbRowFont)
        .foregroundColor(color)
        .padding(.vertical, 1)
        .background(selected ? color.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            controller.selection = a.id
            controller.showInfo(for: a.id)
            openWindow(id: "aircraft-info")
        }
        .onTapGesture { controller.selection = selected ? nil : a.id }
        .help(tooltip(a) + "\nDoppelklick: Flugzeugdaten (Foto, Typ, Strecke)")
    }

    private func info(_ a: ADSBAircraft) -> String {
        if let e = a.emergencyText { return "⚠ " + e }
        if let w = controller.details[a.id] {
            var parts: [String] = []
            if let d = w.shortDescription { parts.append(d) }
            if let r = w.route?.routeText { parts.append(r) }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return a.categoryText ?? ""
    }

    private func tooltip(_ a: ADSBAircraft) -> String {
        var t = "\(a.callsign ?? a.icaoText) · ICAO \(a.icaoText)"
        if let c = a.country { t += "\n\(c.flag) \(c.name)" }
        if let p = a.position { t += "\n" + Geo.format(p) }
        if let alt = a.altitudeFt { t += "\nHöhe \(alt) ft" }
        if let r = a.maxRangeKm { t += String(format: "\nWeitester Empfang %.0f km", r) }
        if let w = controller.details[a.id] {
            if let ty = w.fullTypeName { t += "\n" + ty + (w.registration.map { " (\($0))" } ?? "") }
            if let o = w.owner { t += "\n" + o }
            if let r = w.route, let o = r.origin, let d = r.destination { t += "\n\(o.name) → \(d.name)" }
        }
        return t
    }
}

struct ADSBMessageTable: View {
    let entries: [ADSBLogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if entries.isEmpty { Text("Noch keine Meldung empfangen").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim).padding(4) }
                    ForEach(entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(APRSController.utc.string(from: e.time)).frame(width: 56, alignment: .leading)
                            Text(e.summary).frame(width: 380, alignment: .leading).lineLimit(1)
                            Text("*" + e.message.hex + ";").frame(maxWidth: .infinity, alignment: .leading).foregroundColor(RadioTheme.textDim).lineLimit(1)
                        }
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(e.message.confidence == .corrected ? RadioTheme.vfdAmber : e.message.isExtendedSquitter ? RadioTheme.vfdGreen : RadioTheme.vfdCyan)
                        .id(e.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Reichweite und Meldungsrate (statt Wasserfall)

struct ADSBScopePanel: View {
    @ObservedObject var controller: ADSBController

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MELDUNGEN JE SEKUNDE")
                    .font(adsbHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ADSBRateChart(values: controller.rateHistory)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 14) {
                    stat("JETZT", String(format: "%.0f/s", controller.stats.messagesPerSecond))
                    stat("MELDUNGEN", "\(controller.stats.messageCount)")
                    stat("POSITIONEN", "\(controller.stats.positionCount)")
                    if controller.stats.rejectedPositions > 0 { stat("VERWORFEN", "\(controller.stats.rejectedPositions)") }
                    Spacer()
                }
                dfLine
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 4) {
                Text("REICHWEITE JE RICHTUNG")
                    .font(adsbHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ADSBRangePlot(sectors: controller.stats.rangeBySector)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxHeight: .infinity)
                Text(rangeText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            .frame(width: 250)
        }
        .padding(8)
    }

    private var rangeText: String {
        let best = controller.stats.rangeBySector.max() ?? 0
        return best > 0 ? String(format: "Weitester Empfang %.0f km", best) : "Ohne Standort und Positionen keine Reichweite"
    }

    private var dfLine: some View {
        let c = controller.stats.dfCounts
        let kinds: [(Int, String)] = [(17, "DF17"), (11, "DF11"), (4, "DF4"), (5, "DF5"), (20, "DF20"), (21, "DF21"), (0, "DF0")]
        let text = kinds.compactMap { kind -> String? in
            guard let n = c[kind.0] else { return nil }
            return "\(kind.1) \(n)"
        }.joined(separator: "  ")
        return Text(text.isEmpty ? "Noch keine Meldung" : text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(RadioTheme.textMuted)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

struct ADSBRateChart: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RadioTheme.bgDeep))
            let top = max(10, (values.max() ?? 0) * 1.2)
            // Hilfslinien
            for f in [0.25, 0.5, 0.75] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height * (1 - f)))
                p.addLine(to: CGPoint(x: size.width, y: size.height * (1 - f)))
                ctx.stroke(p, with: .color(RadioTheme.borderSubtle.opacity(0.6)), lineWidth: 0.5)
            }
            guard values.count > 1 else { return }
            var line = Path()
            let step = size.width / 239
            let offset = size.width - step * Double(values.count - 1)
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: offset + step * Double(i), y: size.height * (1 - min(1, v / top)))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: offset, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(RadioTheme.vfdGreen.opacity(0.18)))
            ctx.stroke(line, with: .color(RadioTheme.vfdGreen), lineWidth: 1.5)
            ctx.draw(Text(String(format: "%.0f", top)).font(.system(size: 8, design: .monospaced)).foregroundColor(RadioTheme.textDim), at: CGPoint(x: 12, y: 8))
        }
        .cornerRadius(4)
    }
}

/// Polardiagramm: weiteste Position je 10°-Sektor (Norden oben)
struct ADSBRangePlot: View {
    let sectors: [Double]

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 12
            let best = sectors.max() ?? 0
            let step = best > 600 ? 200.0 : best > 300 ? 100.0 : best > 120 ? 50.0 : 25.0
            let rings = max(2, Int(ceil(max(best, step) / step)))
            let maxKm = Double(rings) * step
            for i in 1...rings {
                let r = radius * Double(i) / Double(rings)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(RadioTheme.borderSubtle), lineWidth: 0.7)
                if i == rings || i == 1 {
                    ctx.draw(Text("\(Int(Double(i) * step))").font(.system(size: 8, design: .monospaced)).foregroundColor(RadioTheme.textDim), at: CGPoint(x: c.x + 3 + 8, y: c.y - r + 6))
                }
            }
            for (label, a) in [("N", 0.0), ("O", 90.0), ("S", 180.0), ("W", 270.0)] {
                let ang = (a - 90) * .pi / 180
                ctx.draw(Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textMuted),
                         at: CGPoint(x: c.x + (radius + 7) * cos(ang), y: c.y + (radius + 7) * sin(ang)))
            }
            guard best > 0 else { return }
            var poly = Path()
            for (i, km) in sectors.enumerated() {
                let a0 = (Double(i) * 10 - 90) * .pi / 180, a1 = (Double(i + 1) * 10 - 90) * .pi / 180
                let r = radius * min(1, km / maxKm)
                let p0 = CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0))
                let p1 = CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1))
                if i == 0 { poly.move(to: p0) } else { poly.addLine(to: p0) }
                poly.addLine(to: p1)
            }
            poly.closeSubpath()
            ctx.fill(poly, with: .color(RadioTheme.vfdGreen.opacity(0.25)))
            ctx.stroke(poly, with: .color(RadioTheme.vfdGreen), lineWidth: 1.2)
        }
    }
}

// MARK: - Empfänger und Einstellungen

struct ADSBTuningPanel: View {
    @ObservedObject var controller: ADSBController
    @ObservedObject var settings: ADSBSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ADS-B")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("1090 MHz · 2 MS/s")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(dotColor)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                readout("FLUGZEUGE", "\(controller.aircraft.count)")
                Spacer()
                readout("MIT POSITION", "\(controller.aircraft.filter(\.hasPosition).count)")
            }
            HStack {
                readout("MELDUNGEN/S", String(format: "%.0f", controller.stats.messagesPerSecond))
                Spacer()
                readout("WEITESTER", (controller.stats.rangeBySector.max() ?? 0) > 0 ? String(format: "%.0f km", controller.stats.rangeBySector.max() ?? 0) : "–")
            }
            HStack {
                readout("RAUSCHEN", String(format: "%.0f", controller.stats.activity))
                Spacer()
                readout("ÜBERSTEUERT", String(format: "%.1f %%", controller.stats.clippedFraction * 100))
                    .foregroundColor(controller.stats.clippedFraction > 0.02 ? RadioTheme.ledRed : RadioTheme.vfdCyan)
            }
            if controller.stats.clippedFraction > 0.02 {
                Text("Übersteuert: Verstärkung verringern.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledRed)
            }
            if controller.stats.droppedBlocks > 0 {
                Text("Rechner zu langsam: \(controller.stats.droppedBlocks) Datenblöcke verworfen.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }
        }
    }

    private var dotColor: Color {
        switch controller.status {
        case .running: return RadioTheme.vfdGreen
        case .error: return RadioTheme.ledRed
        case .idle: return RadioTheme.bgPanel
        }
    }

    private var statusColor: Color {
        if case .error = controller.status { return RadioTheme.ledRed }
        return RadioTheme.textMuted
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Empfänger aus"
        case .running(let d): return "Empfang: \(d)"
        case .error(let m): return m
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(RadioTheme.vfdCyan)
    }
}

struct ADSBSettingsPanel: View {
    @ObservedObject var controller: ADSBController
    @ObservedObject var settings: ADSBSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(ADSBSourceKind.allCases) { k in
                    Button {
                        if settings.source == k {
                            controller.retry()
                        } else {
                            settings.source = k
                        }
                    } label: { Text(LocalizedStringKey(k.title)).lineLimit(1).minimumScaleFactor(0.5) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.source == k))
                        .help(k.detail)
                }
            }
            Text(settings.source.detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            sourceControls
            HStack(spacing: 6) {
                Button(controller.status == .idle ? "START" : "STOPP") {
                    if case .running = controller.status { controller.stopSource() } else { controller.startSource() }
                }
                .buttonStyle(ModeButtonStyle(isSelected: { if case .running = controller.status { return true } else { return false } }()))
                .help("Empfänger starten oder anhalten (gibt das Gerät frei, z. B. für GQRX)")
                Button("NUR MIT POSITION") { settings.onlyWithPosition.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.onlyWithPosition))
                    .help("Nur Flugzeuge mit bekannter Position in der Liste")
                Button("WEGE") { settings.showTracks.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showTracks))
                    .help("Bisherigen Weg der Flugzeuge auf der Karte zeigen")
            }
            HStack(spacing: 6) {
                Button("NETZ-SUCHE") { settings.webLookup.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.webLookup))
                    .help("Flugzeugdaten (Typ, Betreiber, Strecke, Foto) im Netz suchen: bei adsbdb.com und planespotters.net, nur mit ICAO-Adresse und Rufzeichen des angeklickten Flugzeugs")
                Button("AUTO-INFO") { settings.autoLookup.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.autoLookup && settings.webLookup))
                    .help("Typ, Betreiber und Strecke aller Flugzeuge im Hintergrund abfragen (höchstens eine Abfrage je Sekunde). Sendet die ICAO-Adressen und Rufzeichen aller gehörten Flugzeuge an adsbdb.com.")
                Button("INFO BEI KLICK") { settings.openInfoOnClick.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.openInfoOnClick))
                    .help("Klick auf ein Flugzeug in der Karte öffnet das Fenster Flugzeugdaten")
            }
            HStack(spacing: 6) {
                Text("ENTFERNEN NACH (MIN)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach([1, 5, 15, 60], id: \.self) { m in
                    Button("\(m)") { settings.expireMinutes = m }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.expireMinutes == m))
                        .help("Flugzeuge aus der Liste nehmen, die so lange nichts gesendet haben")
                }
            }
        }
    }

    @ViewBuilder
    private var sourceControls: some View {
        switch settings.source {
        case .hackrf:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button("AMP 14 dB") { settings.hackrfAmp.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfAmp))
                        .help("Eingebauter Vorverstärker (14 dB). Bei starken Signalen und Außenantenne mit Vorverstärker eher aus.")
                    Button("BIAS-T") { settings.hackrfBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfBias))
                        .help("Speisespannung (3,3 V) am Antennenanschluss für einen Antennenverstärker. Nur einschalten, wenn die Antenne sie braucht.")
                }
                stepper("LNA", "\(settings.hackrfLNA) dB", minus: { settings.hackrfLNA = max(0, settings.hackrfLNA - 8) }, plus: { settings.hackrfLNA = min(40, settings.hackrfLNA + 8) },
                        help: "Verstärkung im Hochfrequenzteil, 0 bis 40 dB in 8-dB-Stufen")
                stepper("VGA", "\(settings.hackrfVGA) dB", minus: { settings.hackrfVGA = max(0, settings.hackrfVGA - 2) }, plus: { settings.hackrfVGA = min(62, settings.hackrfVGA + 2) },
                        help: "Verstärkung im Basisband, 0 bis 62 dB in 2-dB-Stufen")
            }
        case .rtlsdr:
            VStack(alignment: .leading, spacing: 6) {
                stepper("VERSTÄRKUNG", settings.rtlGain > 0 ? String(format: "%.1f dB", settings.rtlGain) : "AGC",
                        minus: { settings.rtlGain = settings.rtlGain <= 0 ? 0 : max(0, settings.rtlGain - 4) },
                        plus: { settings.rtlGain = min(49.6, settings.rtlGain + 4) },
                        help: "Tunerverstärkung; 0 = automatisch (Tuner-AGC). Es wird die nächste Stufe des Tuners gewählt.")
                HStack(spacing: 6) {
                    Button("BIAS-T") { settings.rtlBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.rtlBias))
                        .help("Speisespannung am Antennenanschluss (nur bei RTL-SDR V3 und ähnlichen)")
                    stepper("PPM", "\(settings.rtlPPM)", minus: { settings.rtlPPM -= 1 }, plus: { settings.rtlPPM += 1 }, help: "Frequenzkorrektur des Quarzes")
                }
            }
        case .sdrplay:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("TUNER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Button("A") { settings.sdrplayTuner = 0 }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 0))
                        .help("RSPduo: Tuner A (50-Ω-Anschluss). Andere Modelle haben nur einen Tuner.")
                    Button("B") { settings.sdrplayTuner = 1 }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 1))
                        .help("RSPduo: Tuner B (zweiter SMA-Anschluss)")
                    Button("AGC") { settings.sdrplayAGC.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayAGC))
                        .help("Automatische Verstärkungsregelung (ZF). Aus = feste ZF-Verstärkung, meist besser für kurze Pulse.")
                    Button("BIAS-T") { settings.sdrplayBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayBias))
                        .help("Speisespannung am Antennenanschluss (RSPduo) für einen Antennenverstärker. Nur einschalten, wenn die Antenne sie braucht.")
                }
                SDRplayOverloadHint()
                SDRplayNotchButtons(rf: $settings.sdrplayRfNotch, dab: $settings.sdrplayDabNotch)
                stepper("LNA-DÄMPFUNG", "Stufe \(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) },
                        plus: { settings.sdrplayLNAState = min(9, settings.sdrplayLNAState + 1) },
                        help: SDRplayHelp.lna)
                stepper("ZF-DÄMPFUNG", "\(settings.sdrplayIFGain) dB", minus: { settings.sdrplayIFGain = max(20, settings.sdrplayIFGain - 2) },
                        plus: { settings.sdrplayIFGain = min(59, settings.sdrplayIFGain + 2) },
                        help: SDRplayHelp.ifGain)
                stepper("PPM", "\(settings.sdrplayPPM)", minus: { settings.sdrplayPPM -= 1 }, plus: { settings.sdrplayPPM += 1 }, help: "Frequenzkorrektur des Quarzes")
                if !SDRplayAPISource.isInstalled() {
                    Text("Die SDRplay-API fehlt: „Hardware API MacOS“ von sdrplay.com/api installieren.")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
        case .sdrconnect:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Rechner", text: $settings.sdrconnectHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                    TextField("Port", value: $settings.sdrconnectPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 60)
                }
                stepper("LNA-DÄMPFUNG", "Stufe \(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) },
                        plus: { settings.sdrplayLNAState = min(27, settings.sdrplayLNAState + 1) },
                        help: "Verstärkungsstufe des SDRplay (0 = höchste Verstärkung, größere Zahl = weniger)")
                Text("SDRconnect: Server einschalten, das Gerät dort wählen. Dann hier START.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        case .file:
            HStack(spacing: 6) {
                Button("ÖFFNEN …") {
                    let panel = NSOpenPanel()
                    panel.message = "Aufnahme mit 8-Bit-I/Q (2 MS/s, vorzeichenlos)"
                    if panel.runModal() == .OK, let url = panel.url {
                        controller.fileOverride = url
                        controller.startSource()
                    }
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                Text(controller.fileOverride?.lastPathComponent ?? "keine Aufnahme")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .lineLimit(1)
            }
        }
    }

    private func stepper(_ label: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Button("−", action: minus).buttonStyle(ModeButtonStyle(isSelected: false))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(minWidth: 52)
            Button("+", action: plus).buttonStyle(ModeButtonStyle(isSelected: false))
        }
        .help(help)
    }
}

/// Statt der Audio-Eingangskarte: ADS-B liest I/Q-Daten direkt vom Funkgerät
struct ADSBReceiverCard: View {
    @ObservedObject var controller: ADSBController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ADS-B braucht keinen Audioeingang: Digidec liest die I/Q-Daten (2 MS/s, 1090 MHz) selbst vom Gerät. Solange das Modul offen ist, gehört das Gerät Digidec; beim Wechsel in ein anderes Modul wird es freigegeben.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
