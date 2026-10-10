// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Bandaktivität

/// Ansicht der Hauptkarte
enum JS8View: String, CaseIterable {
    case band, rx, stations

    var title: String {
        switch self {
        case .band: return "BAND"
        case .rx: return "EMPFANG"
        case .stations: return "STATIONEN"
        }
    }

    var help: String {
        switch self {
        case .band: return "Alle Nachrichten im Hörbereich, wie „Band Activity“ in JS8Call"
        case .rx: return "Nur die Nachrichten auf der gewählten Empfangsfrequenz und alle, die das eigene Rufzeichen nennen („RX Activity“)"
        case .stations: return "Gehörte Stationen mit Locator, letztem Pegel und letzter Aussage („Call Activity“)"
        }
    }
}

struct JS8ActivityPanel: View {
    @ObservedObject var controller: JS8Controller
    @ObservedObject var settings: JS8SettingsStore
    @AppStorage("js8View") private var viewRaw = JS8View.band.rawValue

    private var view: JS8View { JS8View(rawValue: viewRaw) ?? .band }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(JS8View.allCases, id: \.self) { v in
                    Button(v.title) { viewRaw = v.rawValue }
                        .buttonStyle(ModeButtonStyle(isSelected: view == v))
                        .help(v.help)
                }
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                    .padding(.leading, 4)
                Spacer()
                Button("HB") { settings.showHeartbeats.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showHeartbeats))
                    .help("Heartbeats und CQ-Rufe zeigen (ausgeschaltet bleiben nur Nachrichten)")
                Button("[ ]") { settings.showUncertain.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showUncertain))
                    .help("Rahmen mit geringer Güte zeigen (in JS8Call in eckigen Klammern; hier mit „?“)")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Rahmen im Format von ALL.TXT in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
                .help("Listen leeren (Log bleibt)")
            }
            Group {
                switch view {
                case .band: JS8Table(lines: controller.visible, settings: settings, myCall: settings.myCall)
                case .rx: JS8Table(lines: controller.rxLines, settings: settings, myCall: settings.myCall)
                case .stations: JS8StationTable(stations: controller.stations, settings: settings)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        guard let c = controller.lastCycle else { return "Warten auf den ersten Zyklus" }
        return "\(c.submode.letter) · \(c.decodes.count) Rahmen um \(JS8Controller.clockUTC.string(from: c.cycleStart)) UTC · "
            + String(format: "%.2f s Rechenzeit", c.duration)
            + (c.coverage < 0.95 ? String(format: " · nur %.0f %% Audio", c.coverage * 100) : "")
    }
}

/// Nachrichtenliste: UTC · dB · Hz · Betriebsart · Text (mit ♢ am Ende vollständiger Nachrichten)
struct JS8Table: View {
    let lines: [JS8Line]
    @ObservedObject var settings: JS8SettingsStore
    let myCall: String
    /// false: ohne ScrollView (UI-Vorschau)
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .onChange(of: lines.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: lines.last?.text) { _, _ in
                        if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            header
            ForEach(lines) { l in
                row(l).id(l.id)
            }
        }
        .padding(6)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("UTC").frame(width: 48, alignment: .leading)
            Text("dB").frame(width: 28, alignment: .trailing)
            Text("Hz").frame(width: 38, alignment: .trailing)
            Text("M").frame(width: 12, alignment: .center)
            Text("Nachricht").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func color(_ l: JS8Line) -> Color {
        let me = myCall.uppercased()
        if !me.isEmpty, l.to == me || l.from == me || l.text.contains(me) { return RadioTheme.ledRed }
        if l.isUncertain { return RadioTheme.textDim }
        if l.isHeartbeat || l.isCQ { return RadioTheme.vfdGreen }
        if l.kind == .directed || l.kind == .compoundDirected { return RadioTheme.vfdCyan }
        return RadioTheme.vfdAmber
    }

    private func row(_ l: JS8Line) -> some View {
        let selected = l.freqHz >= settings.rxHz - 10 && l.freqHz <= settings.rxHz + l.submode.bandwidth + 10
        return HStack(alignment: .top, spacing: 8) {
            Text(JS8Controller.utc.string(from: l.start)).frame(width: 48, alignment: .leading)
            Text(String(format: "%+d", l.snrDB)).frame(width: 28, alignment: .trailing)
            Text(verbatim: "\(Int(l.freqHz.rounded()))").frame(width: 38, alignment: .trailing)
            Text(l.submode.letter).frame(width: 12, alignment: .center)
            Text(display(l)).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            QRZButton(text: l.text).frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 11, weight: l.isHeartbeat ? .regular : .medium, design: .monospaced))
        .foregroundColor(color(l))
        .padding(.vertical, 1)
        .background(selected ? RadioTheme.vfdCyan.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { settings.setRx(l.freqHz - 1) }
        .help(tooltip(l))
    }

    /// Text mit Endzeichen: ♢ für vollständige Nachrichten, ? bei geringer Güte
    private func display(_ l: JS8Line) -> String {
        var s = l.text.trimmingCharacters(in: .whitespaces)
        if l.isComplete && l.frameCount > 1 { s += " ♢" }
        if l.isUncertain { s += " ?" }
        return s
    }

    private func tooltip(_ l: JS8Line) -> String {
        var s = "\(l.submode.title) · \(l.frameCount) Rahmen · bester Pegel \(l.snrDB) dB · \(Int(l.freqHz.rounded())) Hz"
        if l.hasGap { s += "\nEs fehlen Rahmen (Zyklus nicht decodiert)" }
        if !l.isComplete { s += "\nNachricht noch offen" }
        s += "\nKlick: Empfangsfrequenz auf diese Stelle"
        return s
    }
}

/// Stationen: DX · Rufzeichen · Locator · dB · Hz · M · zuletzt · Anzahl · km · letzte Aussage
struct JS8StationTable: View {
    let stations: [JS8Station]
    @ObservedObject var settings: JS8SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { ctx in
            let sorted = stations.sorted { $0.lastHeard > $1.lastHeard }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    header
                    ForEach(sorted) { s in row(s, now: ctx.date) }
                }
                .padding(6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("DX").frame(width: 24, alignment: .center)
            Text("Rufzeichen").frame(width: 100, alignment: .leading)
            Text("Loc").frame(width: 40, alignment: .leading)
            Text("dB").frame(width: 28, alignment: .trailing)
            Text("Hz").frame(width: 38, alignment: .trailing)
            Text("M").frame(width: 12, alignment: .center)
            Text("vor").frame(width: 44, alignment: .trailing)
            Text("N").frame(width: 24, alignment: .trailing)
            Text("km").frame(width: 48, alignment: .trailing)
            Text("Zuletzt").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 34)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func age(_ d: TimeInterval) -> String {
        d < 90 ? "\(Int(max(0, d))) s" : d < 5400 ? "\(Int(d / 60)) min" : "\(Int(d / 3600)) h"
    }

    private func row(_ s: JS8Station, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(s.dxcc?.flag ?? "").frame(width: 24, alignment: .center)
            Text(s.call).frame(width: 100, alignment: .leading)
            Text(s.grid ?? "").frame(width: 40, alignment: .leading)
            Text(String(format: "%+d", s.snrDB)).frame(width: 28, alignment: .trailing)
            Text(verbatim: "\(Int(s.freqHz.rounded()))").frame(width: 38, alignment: .trailing)
            Text(s.submode.letter).frame(width: 12, alignment: .center)
            Text(age(now.timeIntervalSince(s.lastHeard))).frame(width: 44, alignment: .trailing)
            Text(verbatim: "\(s.count)").frame(width: 24, alignment: .trailing)
            Text(s.km.map { String(format: "%.0f", $0) } ?? "").frame(width: 48, alignment: .trailing)
            Text(s.lastText.trimmingCharacters(in: .whitespaces)).frame(maxWidth: .infinity, alignment: .leading)
            QRZButton(text: s.call).frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(s.mentionsMe ? RadioTheme.ledRed : RadioTheme.vfdGreen)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { settings.setRx(s.freqHz - 1) }
        .help(tooltip(s))
    }

    private func tooltip(_ s: JS8Station) -> String {
        var lines: [String] = []
        if let dx = s.dxcc { lines.append("\(dx.flag) \(dx.name) (\(dx.continent)) · CQ \(dx.cqZone) · ITU \(dx.ituZone)") }
        if let km = s.km, let b = s.bearing { lines.append(String(format: "%.0f km, %.0f°", km, b)) }
        lines.append("Klick: Empfangsfrequenz auf \(Int(s.freqHz.rounded())) Hz")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Zyklus

struct JS8CyclePanel: View {
    @ObservedObject var controller: JS8Controller
    @ObservedObject var settings: JS8SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let t = ctx.date.timeIntervalSince1970
                VStack(spacing: 5) {
                    ForEach(settings.modes.sorted()) { mode in
                        cycleRow(mode, t: t)
                    }
                }
            }
            .help("Stelle im Zyklus jeder gewählten Betriebsart (UTC-Raster). Die Rechneruhr muss auf ±1 s genau gehen (Systemeinstellungen → Datum & Uhrzeit automatisch)")
            HStack {
                readout("ZYKLEN", "\(controller.cycleCount)")
                Spacer()
                readout("RAHMEN", "\(controller.frameCount)")
                Spacer()
                readout("STATIONEN", "\(controller.stations.count)")
            }
            HStack {
                readout("DIAL", settings.band.dialLabel)
                Spacer()
                readout("RX", "\(Int(settings.rxHz.rounded())) Hz")
            }
        }
    }

    private func cycleRow(_ mode: JS8Submode, t: Double) -> some View {
        let period = mode.periodSeconds
        let inCycle = t.truncatingRemainder(dividingBy: period)
        let sending = inCycle >= mode.startDelay && inCycle < mode.startDelay + mode.txDuration
        let color = sending ? RadioTheme.vfdGreen : RadioTheme.vfdAmber
        return HStack(spacing: 8) {
            Text(mode.letter)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(RadioTheme.bgDeep)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * inCycle / period)))
                        Rectangle().fill(RadioTheme.vfdCyan.opacity(0.8)).frame(width: 1.5)
                            .offset(x: max(0, min(geo.size.width, geo.size.width * mode.decodeAt / period)))
                    }
                }
                .frame(height: 6)
                Text(String(format: "%@ · %.0f s · %.2f Baud · %.0f Hz", mode.title, period, mode.baud, mode.bandwidth))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            Text(String(format: "%4.1f", inCycle))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - Einstellungen

struct JS8SettingsPanel: View {
    @ObservedObject var settings: JS8SettingsStore
    @State private var callText = ""
    @State private var locText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(JS8Band.allCases) { b in
                    Button { settings.band = b } label: { Text(b.rawValue).lineLimit(1).minimumScaleFactor(0.6) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.band == b))
                        .help("Dial \(b.dialLabel) MHz USB")
                }
            }
            Text(dialHint)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
            HStack(spacing: 4) {
                ForEach(JS8Submode.allCases) { m in
                    Button { settings.toggle(m) } label: { Text(m.letter) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.modes.contains(m)))
                        .help("\(m.title): \(Int(m.periodSeconds)) s Zyklus, \(String(format: "%.2f", m.baud)) Baud, \(Int(m.bandwidth)) Hz breit, etwa \(m.wordsPerMinute) Wörter je Minute. Mehrere Betriebsarten lassen sich zugleich decodieren.")
                }
                Text(modeHint)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(spacing: 6) {
                label("RUF")
                TextField("DL…", text: $callText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { settings.myCall = callText.trimmingCharacters(in: .whitespaces).uppercased(); callText = settings.myCall }
                    .onAppear { callText = settings.myCall }
                    .help("Eigenes Rufzeichen: Nachrichten daran erscheinen rot (Digidec sendet nie)")
                label("LOC")
                TextField("JN49WS", text: $locText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 70)
                    .onSubmit { applyLocator() }
                    .onAppear { locText = settings.locator }
                    .help("Eigener Locator für die Entfernungen")
            }
            HStack(spacing: 6) {
                label("ZEITKORR.")
                Slider(value: $settings.timeOffset, in: -1...1, step: 0.05)
                Text(String(format: "%+.2f s", settings.timeOffset))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 52, alignment: .trailing)
            }
            .help("Laufzeit vom Funkgerät bis zum Decoder. JS8 verträgt etwa ±1,5 s im Normalmodus; liegt DT der meisten Stationen weit neben 0, hier nachstellen")
        }
    }

    private var modeHint: String {
        settings.modes.sorted().map(\.letter).joined(separator: "+") + " aktiv"
    }

    private var dialHint: String {
        if let rig = settings.rigDialHz {
            let b = JS8Band.band(forDial: rig)
            return "Funkgerät: \(String(format: "%.3f", Double(rig) / 1_000_000).replacingOccurrences(of: ".", with: ",")) MHz"
                + (b.map { " (\($0.rawValue))" } ?? " – kein JS8-Kanal")
        }
        return "USB-Dial \(settings.band.dialLabel) MHz · Signale bei 500 … 3000 Hz"
    }

    private func label(_ s: String) -> some View {
        Text(LocalizedStringKey(s))
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }

    private func applyLocator() {
        let l = locText.trimmingCharacters(in: .whitespaces).uppercased()
        if Maidenhead.coordinate(l) != nil { settings.locator = l }
        locText = settings.locator
    }
}
