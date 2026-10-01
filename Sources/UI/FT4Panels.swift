import SwiftUI
import AppKit

// MARK: - Bandaktivität

struct FT4ActivityPanel: View {
    @ObservedObject var controller: FT4Controller
    @ObservedObject var settings: FT4SettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Button("NUR CQ") { settings.cqOnly.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.cqOnly))
                    .help("Nur CQ-Rufe (und Meldungen an das eigene Rufzeichen) zeigen")
                Button("?") { settings.showUncertain.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showUncertain))
                    .help("Unsichere Decodes zeigen (wenig übereinstimmende Bits oder unplausible Rufzeichen; wie WSJT-X „?“)")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Decodes im WSJT-X-Format (ALL.TXT) in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
            FT4Table(entries: controller.visible)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        guard let c = controller.lastCycle else { return "Warten auf den ersten Zyklus" }
        return "\(c.decodes.count) Decodes um \(FT4Controller.utc.string(from: c.cycleStart).prefix(4)) UTC · "
            + String(format: "%.2f s Rechenzeit", c.duration)
            + (c.coverage < 0.95 ? String(format: " · nur %.0f %% Audio", c.coverage * 100) : "")
    }
}

/// Tabelle wie WSJT-X: UTC · dB · DT · Freq · Meldung · Entfernung
struct FT4Table: View {
    let entries: [FT4Entry]
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .onChange(of: entries.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                let newCycle = i == 0 || entries[i - 1].decode.cycleStart != e.decode.cycleStart
                if newCycle && i > 0 {
                    Rectangle().fill(RadioTheme.borderSubtle).frame(height: 1).padding(.vertical, 1)
                }
                row(e).id(e.id)
            }
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 48, alignment: .leading)
            Text("dB").frame(width: 28, alignment: .trailing)
            Text("DT").frame(width: 34, alignment: .trailing)
            Text("Freq").frame(width: 40, alignment: .trailing)
            Text("Meldung").frame(maxWidth: .infinity, alignment: .leading)
            Text("km").frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ e: FT4Entry) -> some View {
        let d = e.decode
        let color: Color = e.mentionsMe ? RadioTheme.ledRed
            : d.isUncertain ? RadioTheme.textDim
            : d.message.isCQ ? RadioTheme.vfdGreen : RadioTheme.vfdCyan
        return HStack(spacing: 8) {
            Text(FT4Controller.utc.string(from: d.cycleStart)).frame(width: 48, alignment: .leading)
            Text(String(format: "%+d", d.snrDB)).frame(width: 28, alignment: .trailing)
            Text(String(format: "%.1f", d.dt)).frame(width: 34, alignment: .trailing)
            Text(verbatim: "\(Int(d.freqHz.rounded()))").frame(width: 40, alignment: .trailing)
            Text(d.text + (d.isUncertain ? " ?" : "")).frame(maxWidth: .infinity, alignment: .leading)
            Text(e.km.map { String(format: "%.0f", $0) } ?? "").frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 11, weight: d.message.isCQ ? .bold : .medium, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
        .help(tooltip(e))
    }

    private func tooltip(_ e: FT4Entry) -> String {
        var s = "\(e.decode.correctBits)/174 Bits, Durchgang \(e.decode.pass + 1)"
        if let km = e.km, let b = e.bearing { s += String(format: " · %.0f km, %.0f°", km, b) }
        return s
    }
}

// MARK: - Zyklus und Empfangsfrequenz

struct FT4CyclePanel: View {
    @ObservedObject var controller: FT4Controller
    @ObservedObject var settings: FT4SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let t = ctx.date.timeIntervalSince1970
                let inCycle = t.truncatingRemainder(dividingBy: FT4Core.cycleSeconds)
                HStack(spacing: 8) {
                    Text(String(format: "%03.1f", inCycle))
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(inCycle >= 5.04 ? RadioTheme.vfdAmber : RadioTheme.vfdGreen)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(RadioTheme.bgDeep)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(inCycle >= 5.04 ? RadioTheme.vfdAmber : RadioTheme.vfdGreen)
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * inCycle / FT4Core.cycleSeconds)))
                            }
                        }
                        .frame(height: 6)
                        Text(controller.decoder.isBusy ? "DECODIERT …" : "EMPFANG · Decodieren bei 7,1 s")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                }
            }
            .help("Sekunde im 7,5-s-Zyklus (UTC). Die Rechneruhr muss auf ±0,5 s genau gehen (Systemeinstellungen → Datum & Uhrzeit automatisch)")
            HStack {
                readout("ZYKLEN", "\(controller.cycleCount)")
                Spacer()
                readout("RX", "\(Int(settings.rxHz)) Hz")
                Spacer()
                readout("DIAL", String(format: "%.3f", Double(settings.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ","))
            }
            FT4Table(entries: Array(controller.rxEntries.suffix(40)))
                .frame(height: 120)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
                .help("Meldungen nahe der Empfangsfrequenz (Klick in den Wasserfall) und an das eigene Rufzeichen")
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

// MARK: - Einstellungen

struct FT4SettingsPanel: View {
    @ObservedObject var settings: FT4SettingsStore
    @State private var callText = ""
    @State private var locText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(FT4Band.allCases) { b in
                    Button(b.rawValue) { settings.band = b }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.band == b))
                        .help("Dial \(b.dialLabel) MHz USB")
                }
            }
            Text(dialHint)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
            HStack(spacing: 6) {
                label("RUF")
                TextField("DL…", text: $callText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { settings.myCall = callText.trimmingCharacters(in: .whitespaces).uppercased(); callText = settings.myCall }
                    .onAppear { callText = settings.myCall }
                    .help("Eigenes Rufzeichen: Meldungen daran erscheinen rot (Digidec sendet nie)")
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
                Slider(value: $settings.timeOffset, in: -0.5...0.5, step: 0.02)
                Text(String(format: "%+.2f s", settings.timeOffset))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 52, alignment: .trailing)
            }
            .help("Laufzeit vom Funkgerät bis zum Decoder. Liegt DT der meisten Stationen deutlich über 0, hier erhöhen")
        }
    }

    private var dialHint: String {
        if let rig = settings.rigDialHz {
            let b = FT4Band.band(forDial: rig)
            return "Funkgerät: \(String(format: "%.3f", Double(rig) / 1_000_000).replacingOccurrences(of: ".", with: ",")) MHz"
                + (b.map { " (\($0.rawValue))" } ?? " – kein FT4-Kanal")
        }
        return "USB-Dial \(settings.band.dialLabel) MHz"
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }

    private func applyLocator() {
        let l = locText.trimmingCharacters(in: .whitespaces).uppercased()
        if Maidenhead.coordinate(l) != nil { settings.locator = l }
        locText = settings.locator
    }
}
