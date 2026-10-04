import SwiftUI
import AppKit

// MARK: - Funkruf: Meldungsliste

struct PagerMessagePanel: View {
    @ObservedObject var controller: PagerController
    @ObservedObject var settings: PagerSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.toggleRecording()
                } label: {
                    Label(controller.isRecording ? Self.duration(controller.recordingDuration) : "REC",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "waveform.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.isRecording))
                .foregroundColor(controller.isRecording ? RadioTheme.ledRed : nil)
                .help("Eingangssignal als WAV aufnehmen (Quell-Abtastrate): zur Fehlersuche, später mit decode_file.sh --pager nachdecodierbar. "
                      + "Ordner: ~/Documents/Digidec/Recordings")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Meldungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    let target = controller.lastRecording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? controller.logger.fileURL()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Letzte Aufnahme (sonst die Log-Datei) im Finder zeigen")
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Liste und Zähler der Diagnose leeren (Log bleibt)")
            }
            PagerTable(messages: controller.messages, watched: settings.watched, umlauts: settings.umlauts, skyper: settings.skyper)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        controller.messages.isEmpty ? "Warten auf Funkruf (\(settings.channel.label) MHz, FM)" : "\(controller.messages.count) Meldungen"
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PagerTable: View {
    let messages: [PagerMessage]
    var watched: Set<Int> = []
    var umlauts = false
    var skyper = false
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .onChange(of: messages.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            header
            ForEach(messages) { m in row(m).id(m.id) }
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 56, alignment: .leading)
            Text("System").frame(width: 84, alignment: .leading)
            Text("Rufnummer").frame(width: 78, alignment: .trailing)
            Text("F").frame(width: 14, alignment: .center)
            Text("Meldung").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ m: PagerMessage) -> some View {
        let color: Color = watched.contains(m.address) ? RadioTheme.ledRed : m.damaged > 0 ? RadioTheme.textDim : m.text.isEmpty ? RadioTheme.textMuted : RadioTheme.vfdGreen
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PagerController.utc.string(from: m.time)).frame(width: 56, alignment: .leading)
            Text(m.protocolName).frame(width: 84, alignment: .leading)
            Text(String(m.address)).frame(width: 78, alignment: .trailing)
            Text("\(m.function)").frame(width: 14, alignment: .center)
            Text(m.text.isEmpty ? "(nur Ruf)" : shown(m).replacingOccurrences(of: "\n", with: " ⏎ "))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .font(.system(size: 11, weight: watched.contains(m.address) ? .bold : .medium, design: .monospaced))
        .foregroundColor(color)
        .help(tooltip(m))
    }

    /// Klartext, auf Wunsch als Skyper entschlüsselt und mit deutschen Umlauten (nur bei Klartext, nicht bei Ziffern)
    private func shown(_ m: PagerMessage) -> String {
        guard m.text == m.alpha else { return m.text }
        var t = m.text
        if skyper, let s = PagerText.skyper(t) { t = s.text }
        return umlauts ? PagerText.germanUmlauts(t) : t
    }

    private func tooltip(_ m: PagerMessage) -> String {
        var t = "\(m.protocolName) · Rufnummer \(m.address) · Funktion \(m.function)"
        if let d = m.detail { t += " · \(d)" }
        if skyper, m.text == m.alpha, let s = PagerText.skyper(m.text) {
            t += "\nSkyper · Rubrik \(s.rubric) · Nr. \(s.number)\nGesendet als: \(m.text)"
        }
        if let a = m.alternative { t += "\n" + a }
        if m.corrected > 0 { t += "\n\(m.corrected) Bitfehler korrigiert" }
        if m.damaged > 0 { t += "\n\(m.damaged) Codewörter nicht lesbar: Text unvollständig" }
        return t
    }
}

// MARK: - Funkruf: Abstimmanzeige und Einstellungen

struct PagerTuningPanel: View {
    @ObservedObject var controller: PagerController
    @ObservedObject var settings: PagerSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PAGER")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("POCSAG · FLEX")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                ForEach(Array(["512", "1200", "2400", "FLEX"].enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(controller.synced.indices.contains(i) && controller.synced[i] ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                            .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(controller.synced.indices.contains(i) && controller.synced[i] ? RadioTheme.vfdGreen : RadioTheme.textDim)
                    }
                }
            }
            .help("Synchronisation je System: grün = Synchronwort erkannt, ein Stapel wird gelesen")
            PagerLevelBar(level: controller.level)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("FREQUENZ", settings.channel.frequencyHz.map { String(format: "%.4f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") + " MHz" } ?? "frei")
                Spacer()
                readout("MELDUNGEN", "\(controller.count)")
            }
            diagnosisView
        }
    }

    /// Was der Empfänger gesehen hat und was daraus folgt: kein Audio, kein Funkruf, verzerrt, schwach oder gut
    private var diagnosisView: some View {
        let d = controller.diagnosis
        let color: Color = d.severity == .ok ? RadioTheme.vfdGreen : d.severity == .waiting ? RadioTheme.vfdAmber : RadioTheme.ledRed
        return VStack(alignment: .leading, spacing: 4) {
            Divider().background(RadioTheme.borderSubtle)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(d.title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Spacer()
                Text(controller.inputDB <= -119 ? "kein Audio" : String(format: "%.0f dBFS", controller.inputDB))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(controller.inputDB < PagerDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang des Funkruf-Decoders (Vollaussteuerung = 0 dBFS). Brauchbar sind etwa −40 … −10 dBFS.")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(POCSAG.rates.enumerated()).filter { settings.rates.contains($0.element) }, id: \.offset) { i, rate in
                let st = controller.stats.indices.contains(i) ? controller.stats[i] : POCSAGStats()
                if st.preambles + st.syncs + st.batchesGood + st.batchesBad > 0 {
                    Text("\(rate) Bd · Vorspann \(st.preambles) · Sync \(st.syncs)\(st.inverted ? " (invers)" : "") · Stapel \(st.batchesGood) gut / \(st.batchesBad) schlecht · Wörter \(st.wordsGood)/\(st.wordsGood + st.wordsBad)\(st.equalized > 0 ? " · entzerrt \(st.equalized)" : "")")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .help("Vorspann: Folge wechselnder Bits vor jeder Aussendung. Sync: Synchronwort gefunden. Stapel: 16 Codewörter, „gut“ ab 10 gültigen. Wörter: gültige Codewörter von allen gelesenen (BCH-Prüfung). Entzerrt: Meldungen, die erst nach Entzerren des verbogenen Audios lesbar waren.")
                }
            }
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

struct PagerLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(RadioTheme.bgDeep)
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.45 ? RadioTheme.ledRed : level > 0.01 ? RadioTheme.vfdGreen : RadioTheme.textDim)
                    .frame(width: geo.size.width * min(1, max(0, level * 2)))
            }
        }
    }
}

struct PagerSettingsPanel: View {
    @ObservedObject var settings: PagerSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(PagerChannel.allCases) { c in
                    Button { settings.channel = c } label: {
                        VStack(spacing: 1) {
                            Text(verbatim: c.name)
                            Text(verbatim: c.label).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                        }
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.channel == c))
                    .help(c.note + (c.frequencyHz == nil ? "" : " (nur mit QSY AUTO wird das Funkgerät in FM abgestimmt)"))
                }
            }
            // Zwei Reihen: oben, was gelesen wird, darunter, wie der Text angezeigt wird (alle Knöpfe einzeilig, sonst brechen „1.200“ und „SKYPER“ um)
            HStack(spacing: 6) {
                Text("POCSAG")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                ForEach(POCSAG.rates, id: \.self) { r in
                    Button("\(r)") {
                        if settings.rates.contains(r) { if settings.rates.count > 1 { settings.rates.remove(r) } } else { settings.rates.insert(r) }
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.rates.contains(r)))
                    .lineLimit(1)
                    .fixedSize()
                    .help("POCSAG mit \(r) Baud lesen")
                }
                Button("FLEX") { settings.flex.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.flex))
                    .lineLimit(1)
                    .fixedSize()
                    .help("FLEX (1600/3200 Baud) lesen")
            }
            HStack(spacing: 6) {
                Text("ANZEIGE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Button("SKYPER") { settings.skyper.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.skyper))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Skyper-Meldungen lesbar machen: Das Skyper-Netz sendet jedes Zeichen um 1 nach oben verschoben (Leerzeichen als !) und vor dem Text Rubrik und Nummer. Das ist keine Verschlüsselung. Aus: der Text wird so gezeigt, wie er gesendet wurde (im Tooltip steht immer die Rohfassung).")
                Button("ÄÖÜ") { settings.umlauts.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.umlauts))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Deutsche Umlaute anzeigen: Funkrufempfänger belegen { | } ~ mit ä ö ü ß und [ \\ ] mit Ä Ö Ü (7-Bit-Zeichensatz DIN 66003). Aus: der Text wird so gezeigt, wie er gesendet wurde.")
            }
            HStack(spacing: 6) {
                Text("RUFNUMMERN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextField("z. B. 2504, 1234567", text: $settings.watch)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .help("Diese Rufnummern (RIC, durch Komma getrennt) erscheinen rot in der Liste")
            }
            Text("FM, Diskriminator-Audio ohne Rauschsperre. Alle Baudraten laufen gleichzeitig, die Polarität wird erkannt.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}

// MARK: - Töne (DTMF, Selektivruf)

struct TonesListPanel: View {
    @ObservedObject var controller: TonesController
    @ObservedObject var settings: TonesSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.sequences.isEmpty ? "Warten auf Tonfolgen (\(settings.standards.count) Normen aktiv)" : "\(controller.sequences.count) Tonfolgen")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Tonfolgen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text("UTC").frame(width: 76, alignment: .leading)
                            Text("Norm").frame(width: 70, alignment: .leading)
                            Text("Folge").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .padding(.bottom, 3)
                        ForEach(controller.sequences) { s in
                            HStack(spacing: 8) {
                                Text(TonesController.utc.string(from: s.start)).frame(width: 76, alignment: .leading)
                                Text(s.standard.name).frame(width: 70, alignment: .leading)
                                Text(s.text + (s.isComplete ? "" : " …")).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(s.isComplete ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                            .id(s.id)
                            .help(s.standard.note)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: controller.sequences.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }
}

struct TonesTuningPanel: View {
    @ObservedObject var controller: TonesController
    @ObservedObject var settings: TonesSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("TÖNE")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("DTMF · SELEKTIVRUF · SELCAL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            PagerLevelBar(level: controller.level)
                .frame(height: 8)
                .help("Audiopegel")
            Text(ToneStandard.allCases.filter(settings.standards.contains).map(\.name).joined(separator: " · "))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

struct TonesSettingsPanel: View {
    @ObservedObject var settings: TonesSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(ToneStandard.allCases) { s in
                    Button(s.name) { settings.toggle(s) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.standards.contains(s)))
                        .help(s.note)
                }
            }
            Text("Mehrere Normen laufen gleichzeitig. ZVEI 1, 2 und 3 unterscheiden sich nur in den Hilfstönen: Stimmt die Ziffernfolge, ist es meist ZVEI 1 (Deutschland). Zeichen A–F sind Hilfs- und Wiederholtöne. SELCAL ruft Flugzeuge auf HF (USB): zwei Doppeltöne ergeben einen Code wie AB-CD.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
