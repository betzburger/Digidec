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
        VStack(alignment: .leading, spacing: 8) {
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
                .frame(height: 100)
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
            Text(label)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(PSKMode.allCases) { m in
                    Button { settings.options.mode = m } label: { Text(m.displayName).lineLimit(1).minimumScaleFactor(0.7) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.mode == m))
                        .help(String(format: "%.2f Baud", m.baud) + (m.isQPSK ? " · QPSK mit Viterbi-Decoder (K=5)" : " · BPSK"))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(PSKBand.allCases) { b in
                    Button { settings.band = b } label: { Text(b.rawValue).lineLimit(1).minimumScaleFactor(0.7) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.band == b))
                        .help(b.dialHz.map { "Dial \(String(format: "%.3f", Double($0) / 1_000_000).replacingOccurrences(of: ".", with: ",")) MHz USB (nur mit QSY AUTO)" }
                              ?? "Funkgerät nicht abstimmen")
                }
            }
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
            Text(verbatim: "Klick in den Wasserfall setzt die Trägerfrequenz. Mitte \(Int(settings.centerHz.rounded())) Hz")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
