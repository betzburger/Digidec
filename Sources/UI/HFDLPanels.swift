import SwiftUI
import AppKit

// MARK: - HFDL: Meldungsliste

struct HFDLMessagePanel: View {
    @ObservedObject var controller: HFDLController
    @ObservedObject var settings: HFDLSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
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
                .help("Meldungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
                .help("Liste leeren (Log bleibt)")
            }
            HFDLTable(controller: controller, events: controller.visible)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        if controller.frameCount == 0 {
            return "Warten auf HFDL (\(HFDLChannels.label(settings.frequencyKHz)) kHz, USB)"
        }
        return "\(controller.visible.count) von \(controller.events.count) Meldungen · \(controller.aircraft.count) Flugzeuge"
    }
}

struct HFDLTable: View {
    @ObservedObject var controller: HFDLController
    let events: [HFDLEvent]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { rows }
                .onChange(of: events.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            ForEach(events) { e in row(e).id(e.id) }
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 62, alignment: .leading)
            Text("kHz").frame(width: 40, alignment: .leading)
            Text("bit/s").frame(width: 38, alignment: .leading)
            Text("↕").frame(width: 14, alignment: .center)
            Text("Flug / Flugzeug").frame(width: 92, alignment: .leading)
            Text("Station").frame(width: 76, alignment: .leading)
            Text("Meldung").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ e: HFDLEvent) -> some View {
        let admin = e.kind == .squitter || e.kind == .logonConfirm || e.kind == .logonRequest || e.kind == .logonResume || e.kind == .logoff || e.kind == .logonDenied
        let hasContent = (e.acars.map { !$0.isEmpty } ?? false) || e.position != nil
        let color: Color = hasContent ? (e.uplink ? RadioTheme.vfdCyan : RadioTheme.vfdGreen) : admin ? RadioTheme.textMuted : (e.uplink ? RadioTheme.vfdCyan.opacity(0.7) : RadioTheme.vfdGreen.opacity(0.7))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(HFDLController.utc.string(from: e.time)).frame(width: 62, alignment: .leading)
            Text(HFDLChannels.label(e.freqKHz)).frame(width: 40, alignment: .leading)
            Text("\(e.bitRate)\(e.doubleSlot ? "D" : "")").frame(width: 38, alignment: .leading)
            Image(systemName: e.uplink ? "arrow.up" : "arrow.down").font(.system(size: 8, weight: .bold)).frame(width: 14)
            Text(e.kind == .squitter ? "" : controller.label(for: e)).frame(width: 92, alignment: .leading).lineLimit(1)
            Text(e.station.flatMap { HFDLStations.station($0)?.shortName } ?? "").frame(width: 76, alignment: .leading).lineLimit(1)
            Text(content(e)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .help(tooltip(e))
    }

    private func content(_ e: HFDLEvent) -> String {
        var parts: [String] = []
        if let m = e.acars {
            var text = m.isEmpty ? (ACARSLabels.describe(m.label) ?? "ohne Text") : m.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            if m.label == "SA", let adv = e.lines.first(where: { $0.hasPrefix("Medienhinweis: ") }) { text = String(adv.dropFirst("Medienhinweis: ".count)) }
            parts.append("\(m.label)  \(text)")
        } else {
            parts.append(e.title)
        }
        if let p = e.position { parts.append(Geo.format(p)) }
        if e.kind == .squitter, let q = e.squitter { parts.append("TDMA \(q.frameIndex)") }
        if let x = e.icaoHex, e.kind != .data { parts.append(x) }
        return parts.joined(separator: " · ")
    }

    private func tooltip(_ e: HFDLEvent) -> String {
        var t = (e.uplink ? "Vom Boden zum Flugzeug" : "Vom Flugzeug zum Boden") + " · \(e.title) · \(e.bitRate) bit/s \(e.doubleSlot ? "Doppel-Slot" : "Einfach-Slot")"
        t += String(format: " · SNR %.1f dB · Versatz %+.1f Hz", e.snrDB, e.freqErrorHz)
        if let x = e.icaoHex { t += " · ICAO \(x)" }
        if let r = e.registration { t += " · \(r)" }
        if let gs = e.station, let s = HFDLStations.station(gs) { t += "\nBodenstation: \(s.name)" }
        for l in e.lines { t += "\n" + l }
        if let m = e.acars {
            t += "\nACARS Label \(m.label)" + (ACARSLabels.describe(m.label).map { " (\($0))" } ?? "") + " · Block \(m.blockID)"
            if !m.text.isEmpty { t += "\n" + m.text }
        }
        if let p = e.position { t += "\nPosition " + Geo.format(p) + (e.positionTime.map { " · \($0) UTC" } ?? "") }
        return t
    }
}

// MARK: - HFDL: Abstimmanzeige

struct HFDLTuningPanel: View {
    @ObservedObject var controller: HFDLController
    @ObservedObject var settings: HFDLSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("HFDL")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("PSK 1800 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(controller.inBurst ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text("BURST")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.inBurst ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
            .help("Synchronisation erkannt, ein Rahmen wird aufgenommen")
            HStack {
                readout("FREQUENZ", HFDLChannels.label(settings.frequencyKHz) + " kHz USB")
                Spacer()
                readout("RAHMEN", "\(controller.frameCount)")
            }
            HStack {
                readout("FLUGZEUGE", "\(controller.aircraft.count)")
                Spacer()
                readout("MIT ORT", "\(controller.aircraft.values.filter { $0.position != nil }.count)")
                    .help("Flugzeuge, von denen ein Ort gelesen wurde (ihr Weg erscheint als Linie auf der Karte)")
            }
            HStack {
                readout("SNR", controller.lastSNR.map { String(format: "%.1f dB", $0) } ?? "–")
                    .help("Rauschabstand des letzten Rahmens aus den Pilotsymbolen")
                Spacer()
                readout("VERSATZ", controller.lastFreqErrorHz.map { String(format: "%+.1f Hz", $0) } ?? "–")
                    .help("Frequenzabweichung des letzten Rahmens (Doppler und Abstimmung)")
            }
            if controller.frameCount > 0 {
                HStack(spacing: 6) {
                    ForEach([300, 600, 1200, 1800], id: \.self) { r in
                        readout("\(r)", "\(controller.rateCounts[r, default: 0])")
                    }
                    Spacer()
                }
                .help("Rahmen je Datenrate (bit/s)")
            }
            if controller.burstCount > controller.frameCount {
                readout("VERWORFEN", "\(controller.burstCount - controller.frameCount)")
                    .help("Erkannte Synchronisationen, deren Rahmen sich nicht fehlerfrei decodieren ließ")
            }
            if let last = controller.lastDate { readout("LETZTER", HFDLController.utc.string(from: last)) }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - HFDL: Kanalwahl und Einstellungen

struct HFDLSettingsPanel: View {
    @ObservedObject var controller: HFDLController
    @ObservedObject var settings: HFDLSettingsStore
    @State private var band: HFDLBand?
    @State private var showStations = false

    private var shownBand: HFDLBand { band ?? HFDLBand.of(kHz: settings.frequencyKHz) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("KANÄLE") { showStations = false }
                    .buttonStyle(ModeButtonStyle(isSelected: !showStations))
                    .help("Kanal nach Band wählen")
                Button("STATIONEN") { showStations = true }
                    .buttonStyle(ModeButtonStyle(isSelected: showStations))
                    .help("Bodenstationen mit den Frequenzen, die laut ihren Squittern gerade benutzt werden")
            }
            if showStations {
                HFDLStationsPanel(controller: controller, settings: settings)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(HFDLChannels.usedBands) { b in
                        Button { band = b } label: {
                            Text(verbatim: b.title.replacingOccurrences(of: " MHz", with: "")).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: shownBand == b))
                        .help("\(b.title)-Band")
                    }
                }
                Text("Kanäle im \(shownBand.title)-Band (kHz)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(HFDLChannels.channels(in: shownBand), id: \.kHz) { c in
                        Button { settings.frequencyKHz = c.kHz } label: {
                            Text(verbatim: HFDLChannels.label(c.kHz)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: abs(settings.frequencyKHz - c.kHz) < 0.5))
                        .help(c.stations.map(\.name).joined(separator: "\n") + "\n(mit QSY AUTO stimmt Digidec das Funkgerät in USB auf \(HFDLChannels.label(c.kHz)) kHz ab)")
                    }
                }
            }
            HStack(spacing: 6) {
                Button("UPLINK") { settings.showUplink.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showUplink))
                    .help("Meldungen vom Boden zum Flugzeug zeigen")
                Button("SQUITTER") { settings.showSquitters.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showSquitters))
                    .help("Squitter der Bodenstationen (alle 32 s) in der Liste zeigen")
                Button("NUR INHALT") { settings.onlyContent.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.onlyContent))
                    .help("Nur Meldungen mit ACARS-Text oder Ortsangabe zeigen")
            }
            Text("USB, Dial = Kanalfrequenz; das Signal liegt bei 1440 Hz im NF und braucht etwa 2,1 kHz Bandbreite. Ein Flugzeug erscheint auf der Karte, sobald eine Meldung seinen Ort enthält. Welche Kanäle gerade belegt sind, zeigen die Squitter der Bodenstationen.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}

// MARK: - HFDL: Bodenstationen

struct HFDLStationsPanel: View {
    @ObservedObject var controller: HFDLController
    @ObservedObject var settings: HFDLSettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(HFDLStations.all) { s in
                    let st = controller.stations[s.id]
                    let age = st.map { ctx.date.timeIntervalSince($0.lastHeard) }
                    Button {
                        if let f = st?.frequenciesInUseKHz.first ?? s.frequenciesKHz.first { settings.frequencyKHz = f }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(age))
                                .frame(width: 6, height: 6)
                            Text(s.shortName).frame(width: 86, alignment: .leading).lineLimit(1)
                            Text(freqText(s, st)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Text(age.map { $0 < 90 ? "\(Int($0)) s" : $0 < 5400 ? "\(Int($0 / 60)) min" : "\(Int($0 / 3600)) h" } ?? "")
                                .foregroundColor(RadioTheme.textMuted)
                        }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(age.map { $0 < 600 ? RadioTheme.vfdGreen : RadioTheme.textDim } ?? RadioTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help(s.name + "\nZugewiesen: " + s.frequenciesKHz.map { HFDLChannels.label($0) }.joined(separator: ", ") + " kHz\nKlick: auf die erste benutzte Frequenz stellen")
                }
            }
        }
    }

    private func color(_ age: TimeInterval?) -> Color {
        guard let age else { return RadioTheme.bgPanel }
        return age < 120 ? RadioTheme.vfdGreen : age < 900 ? RadioTheme.ledYellow : RadioTheme.textMuted
    }

    private func freqText(_ s: HFDLStation, _ st: HFDLStationStatus?) -> String {
        if let st, !st.frequenciesInUseKHz.isEmpty { return st.frequenciesInUseKHz.map { HFDLChannels.label($0) }.joined(separator: " ") }
        return "–"
    }
}
