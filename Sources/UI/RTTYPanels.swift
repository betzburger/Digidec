// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Empfangstext

struct ReceivePanel: View {
    @ObservedObject var controller: RTTYController
    @ObservedObject var textModel: ReceiveTextModel
    @ObservedObject var settings: RTTYSettingsStore
    @State private var showFilter = false

    init(controller: RTTYController, settings: RTTYSettingsStore) {
        self.controller = controller
        self.settings = settings
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
                    controller.toggleRecording()
                } label: {
                    Label(controller.isRecording ? Self.duration(controller.recordingDuration) : "REC",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "waveform.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.isRecording))
                .foregroundColor(controller.isRecording ? RadioTheme.ledRed : nil)
                .help("Eingangssignal als WAV aufnehmen (mit Begleitdatei der Einstellungen) – für den Vergleich mit fldigi. "
                      + "Ordner: ~/Documents/Digidec/Recordings")
                Button {
                    settings.options.synopDecoding.toggle()
                } label: {
                    Text("SYNOP")
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.options.synopDecoding))
                .help("Wettermeldungen (SYNOP/SHIP/BUOY) erkennen und als Klartext in Amber darunter anzeigen (fldigi-Decoder)")
                Button {
                    showFilter.toggle()
                } label: {
                    Label("FILTER", systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.textFilter.enabled))
                .help("Textfilter für Anzeige und Log: nur zwischen Start- und Stopptext ausgeben, RYRY-Füllzeichen weglassen. "
                      + "Aktuell: \(controller.textFilter.summary). Karten und SYNOP-Auswertung sehen weiter den ganzen Text.")
                .popover(isPresented: $showFilter) { filterEditor }
                Button {
                    controller.csvEnabled.toggle()
                } label: {
                    Text("CSV")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.csvEnabled))
                .help("Jede vollständig decodierte Wettermeldung als Zeile in eine Tabelle (CSV) schreiben: \(controller.csvWriter.fileURL().path)")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Empfangstext in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    let target = controller.lastRecording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                        ?? controller.logger.fileURL()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Letzte Aufnahme bzw. Log-Datei im Finder zeigen")
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
                .help("Anzeige leeren (das Log bleibt erhalten)")
            }
            ReceiveTextView(model: controller.textModel)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }
}

extension ReceivePanel {
    /// Einstellungen des Textfilters
    var filterEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEXTFILTER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Toggle("Filter einschalten", isOn: $controller.textFilter.enabled)
                .toggleStyle(.switch)
            HStack {
                Text("Ausgabe ab")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 84, alignment: .leading)
                TextField("z. B. BBXX", text: $controller.textFilter.start)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
            }
            HStack {
                Text("bis")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 84, alignment: .leading)
                TextField("z. B. NNNN", text: $controller.textFilter.stop)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
            }
            Toggle("RYRY-Füllzeichen weglassen", isOn: $controller.textFilter.hideFiller)
            Text("Der Text beginnt bei „ab“ und endet nach „bis“, danach wird wieder auf „ab“ gewartet. "
                 + "Groß-/Kleinschreibung egal. „bis“ wirkt nur zusammen mit „ab“. "
                 + "Anzeige und Log werden gefiltert, die Karten und die SYNOP-Auswertung bekommen weiter den ganzen Text.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 330)
        .background(RadioTheme.bgCard)
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Leuchtet grün, solange Zeichen ankommen
struct ActivityLED: View {
    let lastChar: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let active = lastChar.map { ctx.date.timeIntervalSince($0) < 1.0 } ?? false
            Circle()
                .fill(active ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                .shadow(color: active ? RadioTheme.vfdGreen.opacity(0.7) : .clear, radius: 3)
                .frame(width: 8, height: 8)
        }
        .help("Leuchtet, solange Zeichen decodiert werden")
    }
}

// MARK: - Abstimmanzeige (XY-Scope + Signal)

struct TuningPanel: View {
    @ObservedObject var controller: RTTYController
    @ObservedObject var settings: RTTYSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            XYScopeView(points: controller.scope)
                .frame(height: 124)
            SignalBar(metric: controller.status?.metric ?? 0, squelch: settings.options.squelchOn ? settings.options.squelch : nil)
            HStack {
                readout("S/N", controller.status.map { String(format: "%.0f dB", $0.snrDB) } ?? "–")
                Spacer()
                readout("AFC", settings.options.afc == .off ? "aus"
                        : controller.status.map { String(format: "%+.1f Hz", $0.freqError) } ?? "–")
                Spacer()
                Button {
                    settings.resetCenter()
                } label: {
                    HStack(spacing: 3) {
                        readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 7.5))
                            .foregroundColor(RadioTheme.textDim)
                    }
                }
                .buttonStyle(.plain)
                .help("NF-Mittenfrequenz (Klick setzt auf Standard 1.000 Hz zurück)")
            }
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
        .help(label == "S/N" ? "S/N wie in fldigi (Messfenster zwischen Mark und Space; bei starken Signalen niedrig)" : "")
    }
}

/// Kreuzellipsen-Anzeige wie fldigi: Mark auf der waagerechten, Space auf der senkrechten Achse.
private struct XYScopeView: View {
    let points: [CGPoint]

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 4
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - r, y: c.y))
            cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - r))
            cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(cross, with: .color(RadioTheme.borderSubtle), lineWidth: 1)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(RadioTheme.borderSubtle.opacity(0.5)), lineWidth: 1)
            guard points.count > 1 else { return }
            // fldigi normiert auf ≈ ±0,8; 1,2 als Reserve
            let scale = r / 0.8
            var trace = Path()
            for (i, p) in points.enumerated() {
                let q = CGPoint(x: c.x + max(-1.2, min(1.2, p.x)) * scale, y: c.y - max(-1.2, min(1.2, p.y)) * scale)
                if i == 0 { trace.move(to: q) } else { trace.addLine(to: q) }
            }
            ctx.stroke(trace, with: .color(RadioTheme.vfdGreen.opacity(0.85)), lineWidth: 1)
        }
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
        .help("XY-Scope: waagerecht = Mark, senkrecht = Space. Richtig abgestimmt: zwei rechtwinklige Ellipsen")
    }
}

/// Signalqualität 0…100 (fldigi-Metrik) mit Squelch-Schwelle
struct SignalBar: View {
    let metric: Double
    let squelch: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text("SIG")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(RadioTheme.bgDeep)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(open ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, metric)) / 100))
                    if let squelch {
                        Rectangle()
                            .fill(RadioTheme.ledRed)
                            .frame(width: 2)
                            .offset(x: geo.size.width * CGFloat(squelch / 100) - 1)
                    }
                }
            }
            .frame(height: 8)
            Text(String(format: "%3.0f", metric))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .frame(width: 26, alignment: .trailing)
        }
        .help("Signalqualität wie fldigi (0–100). Roter Strich: Squelch-Schwelle")
    }

    private var open: Bool { squelch.map { metric >= $0 } ?? true }
}

// MARK: - Schnellschalter unter den Presets

struct RTTYQuickControls: View {
    @ObservedObject var settings: RTTYSettingsStore
    @Binding var showSettings: Bool

    private var sidebandLabel: String {
        switch settings.sidebandMode {
        case .auto: return settings.rigIsLSB == nil ? "AUTO" : (settings.effectiveLSB ? "A·LSB" : "A·USB")
        case .usb: return "USB"
        case .lsb: return "LSB"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("REV") { settings.toggleReverse() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.isReversed))
                    .help("Mark und Space vertauschen (Reverse)")
                Button("AFC") {
                    settings.options.afc = settings.options.afc == .off ? .normal : .off
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.options.afc != .off))
                .help("Automatische Frequenznachführung (\(settings.options.afc.label))")
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Squelch: Text nur bei ausreichender Signalqualität")
                Button(sidebandLabel) { settings.cycleSidebandMode() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.sidebandMode != .auto))
                    .help("Seitenband für die Kehrlage-Korrektur: AUTO (vom Funkgerät per rigctld) → USB → LSB. "
                          + "REV bezieht sich immer auf USB – bei LSB dreht Digidec automatisch um (wie fldigi).")
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Alle RTTY-Einstellungen")
            }
            if settings.options.squelchOn {
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { settings.options.squelch }, set: { settings.options.squelch = $0.rounded() }),
                           in: 0...100)
                        .tint(RadioTheme.ledRed)
                    Text("\(Int(settings.options.squelch))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                        .frame(width: 26, alignment: .trailing)
                }
                .help(settings.parameters.shift < 100 ? "Bei 85 Hz Shift erreicht die Signalqualität nur ≈ 30 – Squelch höchstens ≈ 20" : "Squelch-Schwelle")
            }
        }
    }
}
