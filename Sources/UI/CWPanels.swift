// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Empfangstext CW

struct CWReceivePanel: View {
    @ObservedObject var controller: CWController
    @ObservedObject var textModel: ReceiveTextModel

    init(controller: CWController) {
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

// MARK: - Abstimmanzeige CW

struct CWTuningPanel: View {
    @ObservedObject var controller: CWController
    @ObservedObject var settings: CWSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(wpmText)
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundColor(controller.status.map { $0.wpm > 0 } == true ? RadioTheme.vfdGreen : RadioTheme.textDim)
                Text("WpM")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Text(settings.options.track ? "NACHFÜHRUNG \(trackRange)" : "FEST")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help("Vom Decoder erkannte Geschwindigkeit (fldigi: aus den Punkt-/Strichlängen nachgeführt)")
            EnvelopeScope(values: controller.scope, threshold: controller.status?.level ?? 0)
                .frame(height: 54)
                .help("Hüllkurve nach dem Filter (fldigi-Digiscope); gestrichelt die Entscheidungsschwelle")
            SignalBar(metric: controller.status?.metric ?? 0,
                      squelch: settings.options.squelchOn ? settings.options.squelch : nil)
            HStack {
                readout("FILTER", "\(Int(settings.effectiveBandwidth)) Hz")
                Spacer()
                readout("TON", "\(Int(settings.centerHz.rounded())) Hz")
            }
        }
    }

    private var wpmText: String {
        guard let w = controller.status?.wpm, w > 0 else { return "--" }
        return String(format: "%.0f", w)
    }

    private var trackRange: String {
        let o = settings.options
        return "\(max(o.lowerWPM, o.speedWPM - o.rangeWPM))–\(min(o.upperWPM, o.speedWPM + o.rangeWPM))"
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

/// Hüllkurve der letzten Zeichen wie fldigis Digiscope im CW-Modus
struct EnvelopeScope: View {
    let values: [Double]
    let threshold: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(RadioTheme.bgDeep))
            guard values.count > 1 else { return }
            let y = { (v: Double) in size.height - 3 - CGFloat(min(max(v, 0), 1)) * (size.height - 6) }
            var p = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                i == 0 ? p.move(to: CGPoint(x: x, y: y(v))) : p.addLine(to: CGPoint(x: x, y: y(v)))
            }
            ctx.stroke(p, with: .color(RadioTheme.vfdGreen), lineWidth: 1.2)
            if threshold > 0 {
                var t = Path()
                t.move(to: CGPoint(x: 0, y: y(threshold)))
                t.addLine(to: CGPoint(x: size.width, y: y(threshold)))
                ctx.stroke(t, with: .color(RadioTheme.vfdAmber.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }
}

// MARK: - Einstellungen CW

struct CWSettingsPanel: View {
    @ObservedObject var settings: CWSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                label("START")
                Stepper(value: $settings.options.speedWPM, in: 5...60) {
                    Text("\(settings.options.speedWPM) WpM")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                .help("Startgeschwindigkeit und Mitte des Nachführbereichs (fldigi: CW speed)")
                Spacer()
                Button("TRACK") { settings.options.track.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.track))
                    .help("Geschwindigkeit nachführen (fldigi: Speed tracking)")
            }
            HStack(spacing: 6) {
                label("FILTER")
                ForEach(CWSettingsStore.bandwidths, id: \.self) { bw in
                    Button("\(bw)") {
                        settings.options.bandwidthHz = bw
                        settings.options.matchedFilter = false
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: !settings.options.matchedFilter && settings.options.bandwidthHz == bw))
                }
                Button("MF") { settings.options.matchedFilter.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.matchedFilter))
                    .help("Matched Filter: Bandbreite = 2 × WpM (fldigi)")
            }
            HStack(spacing: 6) {
                label("ATTACK").frame(width: 46, alignment: .leading)
                picker3(\.attack)
                Spacer()
            }
            .help("Anstieg der Pegelnachführung (fldigi: Attack). Bei Fading schneller")
            HStack(spacing: 6) {
                label("DECAY").frame(width: 46, alignment: .leading)
                picker3(\.decay)
                Spacer()
            }
            .help("Abfall der Pegelnachführung (fldigi: Decay)")
            HStack(spacing: 6) {
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Rauschsperre gegen die Signalqualität")
                Slider(value: $settings.options.squelch, in: 0...100)
                    .disabled(!settings.options.squelchOn)
                Button("SOM") { settings.options.somDecoding.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.somDecoding))
                    .help("Mustererkennung (Self-Organizing Map) statt Tabelle – fldigi-Option für unsaubere Handtastung")
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }

    private func picker3(_ key: WritableKeyPath<FldigiCWCore.Options, Int>) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(["LANGSAM", "MITTEL", "SCHNELL"].enumerated()), id: \.offset) { i, s in
                Button(s) { settings.options[keyPath: key] = i }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options[keyPath: key] == i))
            }
        }
    }
}
