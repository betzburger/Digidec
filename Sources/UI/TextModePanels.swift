// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Gemeinsamer Empfangstext für Textbetriebsarten (PSK, Olivia, Contestia, MT63)

struct TextModeReceivePanel<C: TextModeController>: View {
    @ObservedObject var controller: C
    @ObservedObject var textModel: ReceiveTextModel

    init(controller: C) {
        self.controller = controller
        textModel = controller.textModel
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ActivityLED(lastChar: controller.lastCharacterDate)
                Text("\(textModel.characterCount) Zeichen")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Empfangstext in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Log-Datei im Finder zeigen")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.textModel.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Gesamten Empfangstext kopieren")
                Button {
                    controller.clearText()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Anzeige leeren (Log bleibt)")
            }
            ReceiveTextView(model: controller.textModel)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
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

private func smallLabel(_ s: String) -> some View {
    Text(s)
        .font(.system(size: 8, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
}

// MARK: - Olivia / Contestia

struct OliviaTuningPanel: View {
    @ObservedObject var controller: OliviaController
    @ObservedObject var settings: OliviaSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.options.familyName.uppercased())
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(settings.options.label)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                Spacer()
                Text(String(format: "%d Töne · %d Hz", settings.options.tones, settings.options.bandwidthHz))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help("Töne/Bandbreite. Absender und Empfänger müssen dieselbe Einstellung haben")
            SignalBar(metric: controller.status?.metric ?? 0, squelch: settings.options.squelchOn ? settings.options.squelch : nil)
                .help("fldigi-Metrik: 5 · (S/N des Synchronisierers − 3). Der Squelch-Strich zeigt die Schwelle des Reglers")
            HStack {
                readout("S/N", snText)
                Spacer()
                readout("ABW.", String(format: "%+.1f Hz", controller.status?.freqOffsetHz ?? 0))
                Spacer()
                readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
            }
        }
    }

    private var snText: String {
        guard let s = controller.status, s.snr > 0 else { return "---" }
        return String(format: "%.1f", s.snr)
    }
}

struct OliviaSettingsPanel: View {
    @ObservedObject var settings: OliviaSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("OLIVIA") { settings.options.contestia = false }
                    .buttonStyle(ModeButtonStyle(isSelected: !settings.options.contestia))
                    .help("Olivia: 64 Zeichen ASCII, sehr robust")
                Button("CONTESTIA") { settings.options.contestia = true }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.contestia))
                    .help("Contestia: wie Olivia, 6-Bit-Zeichensatz (Großbuchstaben, Ziffern), schneller")
            }
            HStack(spacing: 4) {
                smallLabel("TÖNE").frame(width: 38, alignment: .leading)
                ForEach(1...5, id: \.self) { e in
                    Button("\(2 * (1 << e))") { settings.options.tonesExp = e }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.tonesExp == e))
                }
            }
            HStack(spacing: 4) {
                smallLabel("BREITE").frame(width: 38, alignment: .leading)
                ForEach(0...4, id: \.self) { e in
                    Button { settings.options.bandwidthExp = e } label: { Text(verbatim: "\(125 * (1 << e))") }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.bandwidthExp == e))
                }
            }
            HStack(spacing: 6) {
                Button("REV") { settings.options.reverse.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.reverse))
                    .help("Seitenband umkehren (bei LSB)")
                Button("8 BIT") { settings.options.eightBit.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.eightBit))
                    .help("Erweiterte 8-Bit-Zeichen (Umlaute) über Fluchtzeichen")
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Synchronisierer-Schwelle: S/N = Regler/5 + 3")
                Slider(value: $settings.options.squelch, in: 0...100)
                    .disabled(!settings.options.squelchOn)
            }
            Text(verbatim: "Klick in den Wasserfall setzt die Mitte. Mitte \(Int(settings.centerHz.rounded())) Hz, Bandbreite \(settings.options.bandwidthHz) Hz")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}

// MARK: - MT63

struct MT63TuningPanel: View {
    @ObservedObject var controller: MT63Controller
    @ObservedObject var settings: MT63SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("MT63")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(settings.options.label)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                Spacer()
                Circle()
                    .fill(controller.status?.locked == true ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text("SYNC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.status?.locked == true ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
            .help("SYNC: Zeit- und Frequenzsynchronisierer eingerastet. MT63 braucht einige Sekunden, bis Text erscheint")
            SignalBar(metric: min(100, controller.status?.snr ?? 0), squelch: settings.options.squelchOn ? settings.options.squelch : nil)
                .help("S/N am FEC (fldigi, höchstens 99,9). Unter der Squelch-Marke wird nichts ausgegeben")
            HStack {
                readout("S/N", snText)
                Spacer()
                readout("ABW.", String(format: "%+.1f Hz", controller.status?.freqOffsetHz ?? 0))
                Spacer()
                readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
            }
        }
    }

    private var snText: String {
        guard let s = controller.status, s.snr > 0.5 else { return "---" }
        return String(format: "%.0f dB", 10 * log10(s.snr))
    }
}

struct MT63SettingsPanel: View {
    @ObservedObject var settings: MT63SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                smallLabel("BREITE").frame(width: 42, alignment: .leading)
                ForEach([500, 1000, 2000], id: \.self) { bw in
                    Button { settings.options.bandwidthHz = bw } label: { Text(verbatim: "\(bw)") }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.bandwidthHz == bw))
                }
            }
            HStack(spacing: 4) {
                smallLabel("INTERL.").frame(width: 42, alignment: .leading)
                Button("KURZ") { settings.options.longInterleave = false }
                    .buttonStyle(ModeButtonStyle(isSelected: !settings.options.longInterleave))
                    .help("Verschachtelung 32 (3,2 s): kürzere Verzögerung")
                Button("LANG") { settings.options.longInterleave = true }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.longInterleave))
                    .help("Verschachtelung 64 (6,4 s): robuster bei Fading und Störungen")
            }
            HStack(spacing: 6) {
                Button("INTEGR.") { settings.options.longIntegration.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.longIntegration))
                    .help("Lange Empfangsintegration (fldigi): stabiler bei schwachen Signalen, langsamer beim Einrasten")
                Button("8 BIT") { settings.options.eightBit.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.eightBit))
                    .help("Erweiterte 8-Bit-Zeichen (Umlaute) über Fluchtzeichen")
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Ausgabe nur, wenn das S/N am FEC über der Schwelle liegt")
                Slider(value: $settings.options.squelch, in: 0...100)
                    .disabled(!settings.options.squelchOn)
            }
            Text(verbatim: "Klick in den Wasserfall setzt die Mitte. Mitte \(Int(settings.centerHz.rounded())) Hz, Band \(Int(settings.centerHz) - settings.options.bandwidthHz / 2) … \(Int(settings.centerHz) + settings.options.bandwidthHz / 2) Hz")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}

// MARK: - MFSK / DominoEX / Thor

struct MFSKTuningPanel: View {
    @ObservedObject var controller: MFSKController
    @ObservedObject var settings: MFSKSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.options.mode.displayName.uppercased())
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Spacer()
                Text(String(format: "%d Hz breit · %.0f Hz Audio", Int(settings.options.mode.bandwidthHz), settings.options.mode.sampleRate))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help("Breite des Tonfeldes. Absender und Empfänger müssen dieselbe Betriebsart haben")
            SignalBar(metric: controller.status?.metric ?? 0, squelch: settings.options.squelchOn ? settings.options.squelch : nil)
                .help("fldigi-Metrik des Decoders (0 … 100). Der Squelch-Strich zeigt die Schwelle des Reglers")
            HStack {
                readout("TÖNE", controller.status.map { "\($0.tones)" } ?? "---")
                Spacer()
                readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
            }
        }
    }
}

struct MFSKSettingsPanel: View {
    @ObservedObject var settings: MFSKSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            familyRow("MFSK", .mfsk, help: "MFSK: 16 oder 32 Töne, Viterbi-Korrektur; häufig MFSK16 (15,6 Baud) und MFSK32")
            familyRow("DOMINO", .dominoex, help: "DominoEX: IFK+ (Differenzmodulation), unempfindlich gegen Abstimmfehler und Mehrwegeempfang")
            familyRow("THOR", .thor, help: "Thor: wie DominoEX, mit Vorwärtsfehlerkorrektur und Verschachtelung")
            familyRow("THROB", .throb, help: "Throb: Tonpaare, sehr schmal und langsam (1, 2 oder 4 Zeichen je Sekunde); X = ThrobX mit 55 Zeichen")
            familyRow("IFKP", .ifkp, help: "IFKP: Incremental Frequency Keying Plus, 33 Töne, Geschwindigkeit 0,5 / 1,0 / 2,0")
            familyRow("FSQ", .fsq, help: "FSQ (Fast Simple QSO): Gruppenverkehr mit Rufzeichen; Baudrate 1,5 bis 6")
            HStack(spacing: 6) {
                Button("REV") { settings.options.reverse.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.reverse))
                    .help("Seitenband umkehren (bei LSB)")
                if settings.options.mode.family == .mfsk {
                    Button("AFC") { settings.options.afc.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.afc))
                        .help("Frequenznachführung (fldigi): die Mitte folgt dem Signal")
                }
                if settings.options.mode.family == .dominoex {
                    Button("FEC") { settings.options.fec.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.fec))
                        .help("MultiPsk-Vorwärtsfehlerkorrektur (nur, wenn der Sender sie benutzt)")
                }
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Ausgabe nur, wenn die Signalqualität über der Schwelle liegt")
                Slider(value: $settings.options.squelch, in: 0...100)
                    .disabled(!settings.options.squelchOn)
            }
            Text(verbatim: "Klick in den Wasserfall setzt die Mitte. Mitte \(Int(settings.centerHz.rounded())) Hz, Band \(Int(settings.centerHz - settings.options.mode.bandwidthHz / 2)) … \(Int(settings.centerHz + settings.options.mode.bandwidthHz / 2)) Hz")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private func familyRow(_ title: String, _ family: MFSKMode.Family, help: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            smallLabel(title).frame(width: 46, alignment: .leading).padding(.top, 5).help(help)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 5), spacing: 3) {
                ForEach(MFSKMode.mode(for: family)) { m in
                    Button { settings.options.mode = m } label: { Text(verbatim: m.shortName).lineLimit(1).minimumScaleFactor(0.6) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.mode == m))
                        .help("\(m.displayName), \(Int(m.bandwidthHz)) Hz breit")
                }
            }
        }
    }
}
