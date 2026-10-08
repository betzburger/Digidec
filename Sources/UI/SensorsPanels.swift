// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private let sensHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)
private let sensRowFont = Font.system(size: 11, weight: .medium, design: .monospaced)

// MARK: - Hauptbereich

struct SensorsMainPanel: View {
    @ObservedObject var controller: SensorsController
    @ObservedObject var settings: SensorsSettingsStore
    @State private var tab = Tab.fromEnvironment()

    enum Tab: String, CaseIterable, Identifiable {
        case sensors = "SENSOREN", telegrams = "TELEGRAMME", unknown = "UNBEKANNT"
        var id: String { rawValue }
        /// Entwicklungshilfe: DIGIDEC_SENSORS_TAB=telegrams oder unknown öffnet das Protokoll bzw. die unbekannten Pakete (für Schnappschüsse)
        static func fromEnvironment() -> Tab {
            switch ProcessInfo.processInfo.environment["DIGIDEC_SENSORS_TAB"] {
            case "telegrams": return .telegrams
            case "unknown": return .unknown
            default: return .sensors
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button { controller.logEnabled.toggle() } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Jedes Telegramm mit Zeit, Gerät, Kennung und Messwerten in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()]) } label: { Image(systemName: "folder") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Log-Datei im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Liste leeren")
            }
            Group {
                switch tab {
                case .sensors: SensorsTable(controller: controller)
                case .telegrams: SensorsTelegramTable(entries: controller.recent)
                case .unknown: SensorsUnknownTable(controller: controller)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        let n = controller.stations.count
        if tab == .unknown {
            let g = controller.unknownGroups.count
            return g == 0 ? "keine unbekannten Pakete" : "\(g) Art\(g == 1 ? "" : "en") · \(controller.stats.unknownPackages) Pakete ohne Decoder"
        }
        if n == 0 { return statusText }
        return "\(n) Sensor\(n == 1 ? "" : "en") · \(controller.stats.decoded) Telegramme · \(settings.band.title)"
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Empfänger aus"
        case .running(let d): return "Warten auf Sensoren (\(d), \(settings.band.title))"
        case .error(let m): return m
        }
    }
}

struct SensorsTable: View {
    @ObservedObject var controller: SensorsController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("GERÄT").frame(width: 170, alignment: .leading)
                    Text("ID").frame(width: 64, alignment: .leading)
                    Text("KANAL").frame(width: 40, alignment: .leading)
                    Text("WERTE").frame(maxWidth: .infinity, alignment: .leading)
                    Text("VERLAUF").frame(width: 80, alignment: .leading)
                    Text("PEGEL").frame(width: 52, alignment: .trailing)
                    Text("N").frame(width: 34, alignment: .trailing)
                    Text("VOR").frame(width: 48, alignment: .trailing)
                }
                .font(sensHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.stations) { s in row(s, now: ctx.date) }
                    }
                }
            }
            .padding(6)
        }
    }

    private func row(_ s: SensorStation, now: Date) -> some View {
        let age = now.timeIntervalSince(s.lastSeen)
        let color: Color = s.latest.batteryOK == false ? RadioTheme.vfdAmber : age < 30 ? RadioTheme.ledRed : age < 300 ? RadioTheme.vfdGreen : RadioTheme.textDim
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(s.model).frame(width: 170, alignment: .leading).lineLimit(1)
            Text(s.idText).frame(width: 64, alignment: .leading).lineLimit(1)
            Text(s.channelText).frame(width: 40, alignment: .leading)
            Text(s.summary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            Sparkline(values: s.trend.map(\.1)).frame(width: 80, height: 14)
            Text(String(format: "%.0f dB", s.rssiDB)).frame(width: 52, alignment: .trailing)
            Text("\(s.transmissions)").frame(width: 34, alignment: .trailing)
            Text(ageText(age)).frame(width: 48, alignment: .trailing)
        }
        .font(sensRowFont)
        .foregroundColor(color)
        .help("\(s.model) · \(s.isFSK ? "FSK" : "OOK") · Pegel \(String(format: "%.1f", s.rssiDB)) dB, Rauschabstand \(String(format: "%.1f", s.snrDB)) dB, Ablage \(Int(s.frequencyOffsetHz)) Hz · zuerst \(SensorsController.time(s.firstSeen))")
    }

    private func ageText(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s)) s" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        return "\(Int(s / 3600)) h"
    }
}

/// Linie über die letzten Werte (Skalierung auf den Bereich)
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
                let span = max(hi - lo, 0.1)
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = g.size.height * (1 - CGFloat((v - lo) / span))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(RadioTheme.vfdCyan, lineWidth: 1)
        }
    }
}

struct SensorsTelegramTable: View {
    let entries: [SensorLogEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("UTC").frame(width: 56, alignment: .leading)
                    Text("GERÄT").frame(width: 170, alignment: .leading)
                    Text("KENNUNG").frame(width: 110, alignment: .leading)
                    Text("INHALT").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(sensHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                ForEach(entries.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(SensorsController.timeFormatter.string(from: e.time)).frame(width: 56, alignment: .leading)
                        Text(e.event.reading.model).frame(width: 170, alignment: .leading).lineLimit(1)
                        Text(ident(e.event.reading)).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(e.summary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                    }
                    .font(sensRowFont)
                    .foregroundColor(RadioTheme.vfdGreen)
                    .help(e.event.reading.fields.map { "\($0.key) = \($0.value.text)" }.joined(separator: "\n"))
                }
            }
            .padding(6)
        }
    }

    private func ident(_ r: SensorReading) -> String {
        var s = r["id"]?.text ?? ""
        if let c = r["channel"] { s += " K\(c.text)" }
        return s
    }
}


// MARK: - Unbekannte Pakete

/// Pakete, die kein Decoder kennt, nach Art gruppiert (Modulation, Breiten, Länge): regelmäßige Sender mit wiederholten Zeilen sind Kandidaten für einen neuen Decoder
struct SensorsUnknownTable: View {
    @ObservedObject var controller: SensorsController
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("ART").frame(width: 190, alignment: .leading)
                        Text("BREITEN µS").frame(width: 150, alignment: .leading)
                        Text("BITS").frame(width: 52, alignment: .trailing)
                        Text("WDH").frame(width: 34, alignment: .trailing)
                        Text("ABSTAND").frame(width: 62, alignment: .trailing)
                        Text("N").frame(width: 38, alignment: .trailing)
                        Text("PEGEL").frame(width: 52, alignment: .trailing)
                        Text("VOR").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(sensHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                    .padding(.bottom, 3)
                    if controller.unknownGroups.isEmpty {
                        Text("Noch nichts Unbekanntes gehört. Hier erscheinen Aussendungen, die kein Decoder erkennt: Fernbedienungen, Klingeln, Reifendrucksensoren und Sensoren, die dem Katalog fehlen. Wiederholte Zeilen und ein gleichmäßiger Abstand sprechen für einen Sensor.")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(controller.unknownGroups) { g in row(g, now: ctx.date) }
                        }
                    }
                }
                .padding(6)
            }
            if let g = controller.unknownGroups.first(where: { $0.id == selection }) {
                Divider().overlay(RadioTheme.borderSubtle)
                detail(g)
            }
        }
    }

    private func row(_ g: UnknownGroup, now: Date) -> some View {
        let age = now.timeIntervalSince(g.last)
        let u = g.latest
        let color: Color = g.isPeriodic ? RadioTheme.vfdGreen : age < 30 ? RadioTheme.vfdAmber : RadioTheme.textMuted
        let widths = (u.pulseBins.map { "\($0.mean)" }.joined(separator: "·")) + " / " + (u.gapBins.map { "\($0.mean)" }.joined(separator: "·"))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text((g.isPeriodic ? "⏱ " : "") + u.modulation + (u.isFSK ? " · \(Int(u.frequencyOffsetHz / 1000)) kHz" : "")).frame(width: 190, alignment: .leading).lineLimit(1)
            Text(widths).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(u.rowBits.max().map { "\($0)" } ?? "–").frame(width: 52, alignment: .trailing)
            Text(g.maxRepeats > 1 ? "×\(g.maxRepeats)" : "").frame(width: 34, alignment: .trailing)
            Text(g.intervalSeconds.map { Self.interval($0) } ?? "").frame(width: 62, alignment: .trailing)
            Text("\(g.count)").frame(width: 38, alignment: .trailing)
            Text(String(format: "%.0f dB", u.rssiDB)).frame(width: 52, alignment: .trailing)
            Text(age < 60 ? "\(Int(age)) s" : age < 3600 ? "\(Int(age / 60)) min" : "\(Int(age / 3600)) h").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(sensRowFont)
        .foregroundColor(color)
        .padding(.vertical, 2)
        .background(selection == g.id ? RadioTheme.vfdCyan.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = selection == g.id ? nil : g.id }
        .help("Klick zeigt die Einzelheiten. ⏱ = meldet sich in gleichmäßigem Abstand.")
    }

    private static func interval(_ s: Double) -> String {
        s < 90 ? "\(Int(s.rounded())) s" : "\(Int((s / 60).rounded())) min"
    }

    private func detail(_ g: UnknownGroup) -> some View {
        let u = g.latest
        let text = Self.detailText(g)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(g.signature).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
                Spacer()
                Button("KOPIEREN") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Einzelheiten in die Zwischenablage (zum Weitergeben oder für einen neuen Decoder)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([controller.unknownLogger.fileURL()]) } label: { Image(systemName: "folder") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Protokoll der unbekannten Pakete mit allen Breiten im Finder zeigen (bei eingeschaltetem LOG)")
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            if u.rows.isEmpty {
                Text("Die Bits ließen sich nicht ableiten: die Breiten gehören zu keiner der bekannten Modulationsarten.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }
        }
        .padding(8)
    }

    static func detailText(_ g: UnknownGroup) -> String {
        let u = g.latest
        func binText(_ b: [PulseBin]) -> String { b.map { "\($0.mean) µs (×\($0.count), \($0.min) bis \($0.max))" }.joined(separator: ", ") }
        var t = "Art: \(u.modulation)   Pakete: \(g.count)   Pegel: \(String(format: "%.1f", u.rssiDB)) dB   Rauschabstand: \(String(format: "%.1f", u.snrDB)) dB   Ablage: \(Int(u.frequencyOffsetHz)) Hz\n"
        t += "Pulse: \(u.numPulses)   Dauer: \(u.durationMicroseconds) µs   Pulsbreiten: \(binText(u.pulseBins))\n"
        t += "Lückenbreiten: \(binText(u.gapBins))\n"
        if let i = g.intervalSeconds { t += "Abstand der Aussendungen: etwa \(Int(i.rounded())) s" + (g.isPeriodic ? " (gleichmäßig)" : "") + "\n" }
        if u.shortWidth > 0 { t += "Zeiten für den Decoder: kurz \(u.shortWidth) µs, lang \(u.longWidth) µs\n" }
        for r in u.rows { t += r + "\n" }
        t += "Breiten (Puls/Lücke, µs): " + stride(from: 0, to: min(u.widths.count, 160), by: 2).map { "\(u.widths[$0])/\(u.widths[$0 + 1])" }.joined(separator: " ")
        return t
    }
}

// MARK: - Empfang (statt Wasserfall)

struct SensorsScopePanel: View {
    @ObservedObject var controller: SensorsController

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SIGNALAKTIVITÄT")
                    .font(sensHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ADSBRateChart(values: controller.activityHistory)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 14) {
                    stat("PAKETE", "\(controller.stats.packages)")
                    stat("TELEGRAMME", "\(controller.stats.decoded)")
                    stat("SENSOREN", "\(controller.stations.count)")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text("GERÄTE")
                    .font(sensHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(models, id: \.0) { m in
                            HStack {
                                Text(m.0).lineLimit(1)
                                Spacer()
                                Text("\(m.1)")
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdGreen)
                        }
                        if models.isEmpty {
                            Text("Noch kein Sensor gehört")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                        }
                    }
                }
            }
            .frame(width: 250)
        }
        .padding(8)
    }

    private var models: [(String, Int)] {
        Dictionary(grouping: controller.stations, by: \.model).map { ($0.key, $0.value.reduce(0) { $0 + $1.transmissions }) }.sorted { $0.1 > $1.1 }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - Abstimmanzeige

struct SensorsTuningPanel: View {
    @ObservedObject var controller: SensorsController
    @ObservedObject var settings: SensorsSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SENSOREN")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("\(settings.band.title) · \(controller.stats.processRate > 0 ? "\(controller.stats.processRate / 1000) kS/s" : "2 MS/s")")
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
                readout("SENSOREN", "\(controller.stations.count)")
                Spacer()
                readout("TELEGRAMME", "\(controller.stats.decoded)")
            }
            HStack {
                readout("PAKETE OOK", "\(controller.stats.ookPackages)")
                Spacer()
                readout("PAKETE FSK", "\(controller.stats.fskPackages)")
            }
            HStack {
                readout("UNBEKANNT", "\(controller.stats.unknownPackages)")
                Spacer()
            }
            HStack {
                readout("RAUSCHEN", String(format: "%.0f dB", controller.stats.noiseDB))
                Spacer()
                readout("ÜBERSTEUERT", String(format: "%.1f %%", controller.stats.clippedFraction * 100))
                    .foregroundColor(controller.stats.clippedFraction > 0.02 ? RadioTheme.ledRed : RadioTheme.vfdCyan)
            }
            if controller.stats.clippedFraction > 0.02 {
                Text("Übersteuert: Verstärkung verringern.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledRed)
            }
            if controller.stats.activity > 0 && controller.stats.activity < 2.5 && controller.fileOverride == nil {
                Text("Zu schwach ausgesteuert (Rauschen unter 2 Stufen des Wandlers): Verstärkung erhöhen, sonst gehen schwache Sensoren unter.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.stats.droppedBlocks > 0 {
                Text("Rechner zu langsam: \(controller.stats.droppedBlocks) Datenblöcke verworfen.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }
            if controller.stats.packages > 20 && controller.stats.decoded == 0 {
                Text("Pakete ohne Treffer: andere Geräte in der Nähe oder Sensoren, die nicht im Katalog stehen (\(SensorCatalog.all.count) Decoder). Reiter UNBEKANNT zeigt sie mit Breiten und Bits.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Einstellungen

struct SensorsSettingsPanel: View {
    @ObservedObject var controller: SensorsController
    @ObservedObject var settings: SensorsSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("BAND")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach(SensorBand.allCases) { b in
                    Button(b.title) { settings.band = b }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.band == b))
                        .lineLimit(1)
                        .fixedSize()
                        .help(b == .mhz433 ? "Die meisten Thermometer, Hygrometer und Wetterstationen für den Hausgebrauch (OOK und FSK, Abtastrate 250 kS/s)" : "Bresser, Ecowitt, LaCrosse IT+, TFA Marbella und Verwandte (FSK, 1 MS/s)")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(ADSBSourceKind.allCases) { k in
                    Button { settings.source = k } label: { Text(k.title).lineLimit(1).minimumScaleFactor(0.5) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.source == k))
                        .help(k.detail)
                }
            }
            Text(settings.source == .file ? "Aufnahme: 8-Bit-I/Q (vorzeichenlos), Abtastrate aus dem Dateinamen (…_250k, …_1000k), sonst 250 kS/s." : settings.source.detail)
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
            }
            HStack(spacing: 6) {
                Text("ENTFERNEN NACH (MIN)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach([15, 60, 360, 0], id: \.self) { m in
                    Button(m == 0 ? "nie" : "\(m)") { settings.expireMinutes = m }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.expireMinutes == m))
                        .help("Sensoren aus der Liste nehmen, die so lange nichts gesendet haben")
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
                        .help("Eingebauter Vorverstärker (14 dB)")
                    Button("BIAS-T") { settings.hackrfBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfBias))
                        .help("Speisespannung (3,3 V) am Antennenanschluss für einen Antennenverstärker")
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
                        help: "Tunerverstärkung; 0 = automatisch. Für Funksensoren ist feste Verstärkung (30 bis 40 dB) oft besser.")
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
                    Button("A") { settings.sdrplayTuner = 0 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 0))
                    Button("B") { settings.sdrplayTuner = 1 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 1))
                    Button("AGC") { settings.sdrplayAGC.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayAGC))
                        .help("Automatische Verstärkungsregelung (ZF)")
                    Button("BIAS-T") { settings.sdrplayBias.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayBias))
                }
                SDRplayOverloadHint()
                SDRplayNotchButtons(rf: $settings.sdrplayRfNotch, dab: $settings.sdrplayDabNotch)
                stepper("LNA-DÄMPFUNG", "Stufe \(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) },
                        plus: { settings.sdrplayLNAState = min(9, settings.sdrplayLNAState + 1) }, help: SDRplayHelp.lna)
                stepper("ZF-DÄMPFUNG", "\(settings.sdrplayIFGain) dB", minus: { settings.sdrplayIFGain = max(20, settings.sdrplayIFGain - 2) },
                        plus: { settings.sdrplayIFGain = min(59, settings.sdrplayIFGain + 2) }, help: SDRplayHelp.ifGain)
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
                        plus: { settings.sdrplayLNAState = min(27, settings.sdrplayLNAState + 1) }, help: "Verstärkungsstufe des SDRplay")
            }
        case .file:
            HStack(spacing: 6) {
                Button("ÖFFNEN …") {
                    let panel = NSOpenPanel()
                    panel.message = "Aufnahme mit 8-Bit-I/Q (vorzeichenlos); die Abtastrate steht im Dateinamen (…_250k.cu8, …_1000k.cu8)"
                    if panel.runModal() == .OK, let url = panel.url {
                        controller.fileSampleRate = SensorsController.sampleRate(inFileName: url.lastPathComponent)
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

/// Statt der Audio-Eingangskarte: Funksensoren lesen I/Q-Daten direkt vom Funkgerät
struct SensorsReceiverCard: View {
    @ObservedObject var controller: SensorsController

    var body: some View {
        Text("Funksensoren brauchen keinen Audioeingang: Digidec liest die I/Q-Daten (2 MS/s) selbst vom Gerät. Solange das Modul offen ist, gehört das Gerät Digidec; beim Wechsel in ein anderes Modul wird es freigegeben.")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(RadioTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
