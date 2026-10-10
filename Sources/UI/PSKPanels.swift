// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Empfangstext PSK

struct PSKReceivePanel: View {
    @ObservedObject var controller: PSKController
    @ObservedObject var textModel: ReceiveTextModel

    init(controller: PSKController) {
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

// MARK: - Abstimmanzeige PSK

struct PSKTuningPanel: View {
    @ObservedObject var controller: PSKController
    @ObservedObject var settings: PSKSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.options.mode.displayName)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(String(format: "%.2f Bd", settings.options.mode.baud).replacingOccurrences(of: ".", with: ","))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(controller.status?.dcd == true ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text("DCD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.status?.dcd == true ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
            .help("DCD: Träger erkannt, Zeichen werden ausgegeben (fldigi erkennt ihn am Vorspann aus Phasenumkehr oder an der Signalqualität über dem Squelch)")
            PhaseVectorScope(points: controller.scope)
                .frame(height: 75)
                .help("Phasenvektor der letzten Symbole (fldigi-Digiscope). BPSK: zwei Punkte gegenüber, QPSK: vier. Ein sauberes Signal bündelt die Punkte")
            SignalBar(metric: controller.status?.metric ?? 0,
                      squelch: settings.options.squelchOn ? settings.options.squelch : nil)
            HStack {
                readout("S/N", snText)
                Spacer()
                readout("IMD", imdText)
                Spacer()
                readout("MITTE", "\(Int((controller.status?.centerHz ?? settings.centerHz).rounded())) Hz")
            }
            .help("S/N und IMD aus den Goertzel-Filtern (fldigi). Aussagekräftig nur bei erkanntem Träger")
        }
    }

    private var snText: String {
        guard let s = controller.status, s.snrDB >= 6 else { return "---" }
        return String(format: "%.0f dB", s.snrDB)
    }

    private var imdText: String {
        guard let s = controller.status, s.snrDB >= 6, s.imdDB <= -10 else { return "---" }
        return String(format: "%.0f dB", s.imdDB)
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

/// Phasenvektor wie fldigis Digiscope (Modus PHASE): Pfeil je Symbol in Richtung der Phase, Länge = Qualität
struct PhaseVectorScope: View {
    let points: [(phase: Double, amplitude: Double)]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(RadioTheme.bgDeep))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 6
            var axes = Path()
            axes.move(to: CGPoint(x: c.x - r, y: c.y)); axes.addLine(to: CGPoint(x: c.x + r, y: c.y))
            axes.move(to: CGPoint(x: c.x, y: c.y - r)); axes.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(axes, with: .color(RadioTheme.borderSubtle), lineWidth: 1)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(RadioTheme.borderSubtle), lineWidth: 1)
            for (i, p) in points.enumerated() {
                let age = Double(i + 1) / Double(max(points.count, 1))          // neuere Punkte heller
                let len = CGFloat(min(max(p.amplitude, 0.05), 1)) * r
                let end = CGPoint(x: c.x + len * CGFloat(cos(p.phase)), y: c.y - len * CGFloat(sin(p.phase)))
                var line = Path()
                line.move(to: c)
                line.addLine(to: end)
                ctx.stroke(line, with: .color(RadioTheme.vfdGreen.opacity(0.15 + 0.5 * age)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4)),
                         with: .color(RadioTheme.vfdGreen.opacity(0.3 + 0.7 * age)))
            }
        }
    }
}

// MARK: - Einstellungen PSK

struct PSKSettingsPanel: View {
    @ObservedObject var settings: PSKSettingsStore
    @State private var selectedFamily: PSKMode.Family = .bpsk

    @State private var editingBand: PSKBandItem?
    @State private var isNewBand = false
    @State private var showBandEditor = false
    @State private var editName = ""
    @State private var editFreqText = ""
    @State private var editNote = ""

    private static func familyTitle(_ f: PSKMode.Family) -> String {
        switch f {
        case .bpsk: return "BPSK"
        case .qpsk: return "QPSK"
        case .pskr: return "PSKR"
        case .psk8: return "8PSK"
        }
    }

    private static func familyHelp(_ f: PSKMode.Family) -> String {
        switch f {
        case .bpsk: return "BPSK: Phasenumtastung mit 2 Phasen, Varicode"
        case .qpsk: return "QPSK: 4 Phasen mit Viterbi-Decoder (K=5)"
        case .pskr: return "PSKR: BPSK mit Vorwärtsfehlerkorrektur und Verschachtelung (robust bei Störungen)"
        case .psk8: return "8PSK: 8 Phasen, 16 kHz Abtastrate; mit F oder FL zusätzlich Fehlerkorrektur"
        }
    }

    private static func modeHelp(_ m: PSKMode) -> String {
        switch m.family {
        case .bpsk: return " · BPSK"
        case .qpsk: return " · QPSK mit Viterbi-Decoder (K=5)"
        case .pskr: return " · PSKR mit Fehlerkorrektur"
        case .psk8: return m.hasFEC ? " · 8PSK mit Fehlerkorrektur" : " · 8PSK ohne Fehlerkorrektur"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(PSKMode.Family.allCases, id: \.self) { family in
                    Button {
                        selectedFamily = family
                    } label: {
                        Text(Self.familyTitle(family))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: selectedFamily == family))
                    .help(Self.familyHelp(family))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(PSKMode.allCases.filter { $0.family == selectedFamily }) { m in
                    Button { settings.options.mode = m } label: { Text(m.shortName).lineLimit(1).minimumScaleFactor(0.6) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.mode == m))
                        .help(String(format: "%.0f Baud", m.baud) + Self.modeHelp(m))
                }
            }
            bandGrid
            HStack(spacing: 6) {
                Button("AFC") { settings.options.afc.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.afc))
                    .help("Frequenznachführung auf die Trägerphase (fldigi AFC)")
                Button("REV") { settings.options.reverse.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.reverse))
                    .disabled(!settings.options.mode.isQPSK)
                    .help("QPSK: Seitenband umkehren (bei LSB oder falsch eingestelltem Seitenband). Bei BPSK ohne Wirkung")
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Rauschsperre gegen die Signalqualität. Aus: es wird immer ausgegeben")
                Slider(value: $settings.options.squelch, in: 0...100)
                    .disabled(!settings.options.squelchOn)
            }
            Text(verbatim: "Mitte \(Int(settings.centerHz.rounded())) Hz · Klick im Wasserfall stimmt ab")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
        }
        .onAppear {
            selectedFamily = settings.options.mode.family
        }
        .onChange(of: settings.options.mode) { _, m in
            selectedFamily = m.family
        }
        .sheet(isPresented: $showBandEditor) {
            PresetModalSheet(
                title: isNewBand ? "NEUES PSK-BAND" : "PSK-BAND BEARBEITEN",
                isValid: !editName.trimmingCharacters(in: .whitespaces).isEmpty,
                onSave: saveBand,
                onCancel: { showBandEditor = false }
            ) {
                SimpleChannelEditorView(unitTitle: "Dial (MHz)", name: $editName, freqText: $editFreqText, note: $editNote)
            }
        }
    }

    private var bandGrid: some View {
        let count = settings.bands.count + 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(count, 6)), spacing: 4) {
            ForEach(settings.bands) { b in
                Button {
                    settings.selectBand(id: b.id)
                } label: {
                    Text(b.name).lineLimit(1).minimumScaleFactor(0.7)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.selectedBandID == b.id))
                .help(b.dialHz.map { "Dial \(String(format: "%.3f", Double($0) / 1_000_000).replacingOccurrences(of: ".", with: ",")) MHz USB (nur mit QSY AUTO)" }
                      ?? "Funkgerät nicht abstimmen")
                .presetContextMenu(
                    onEdit: { startEditBand(b) },
                    onDelete: settings.bands.count > 1 ? { settings.removeBand(id: b.id) } : nil,
                    onReset: { settings.resetBandsToDefault() }
                )
            }

            Button {
                startAddBand()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
            .help("Neues PSK-Band hinzufügen")
        }
    }

    private func startAddBand() {
        isNewBand = true
        editingBand = nil
        editName = ""
        editFreqText = ""
        editNote = ""
        showBandEditor = true
    }

    private func startEditBand(_ b: PSKBandItem) {
        isNewBand = false
        editingBand = b
        editName = b.name
        editFreqText = b.dialHz.map { String(format: "%.3f", Double($0) / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? ""
        editNote = b.note
        showBandEditor = true
    }

    private func saveBand() {
        let cleanText = editFreqText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let mhz = Double(cleanText)
        let hz = mhz.map { Int(($0 * 1_000_000).rounded()) }
        let name = editName.trimmingCharacters(in: .whitespaces)

        if isNewBand {
            let item = PSKBandItem(id: UUID().uuidString, name: name, dialHz: hz, note: editNote.trimmingCharacters(in: .whitespaces))
            settings.addBand(item)
        } else if let editingBand {
            let item = PSKBandItem(id: editingBand.id, name: name, dialHz: hz, note: editNote.trimmingCharacters(in: .whitespaces))
            settings.updateBand(item)
        }
        showBandEditor = false
    }
}
