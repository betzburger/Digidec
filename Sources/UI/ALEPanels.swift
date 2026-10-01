import SwiftUI
import AppKit

// MARK: - Aussendungen

struct ALEMessagePanel: View {
    @ObservedObject var controller: ALEController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Aussendungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
            ALETable(messages: controller.messages)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        controller.messages.isEmpty ? "Warten auf ALE (8-FSK, Töne 750 … 2500 Hz, USB)" : "\(controller.messages.count) Aussendungen · \(controller.wordCount) Wörter"
    }
}

struct ALETable: View {
    let messages: [ALEMessage]
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
        LazyVStack(alignment: .leading, spacing: 0) {
            header
            ForEach(messages) { m in row(m).id(m.id) }
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 56, alignment: .leading)
            Text("Art").frame(width: 84, alignment: .leading)
            Text("Q").frame(width: 26, alignment: .trailing)
            Text("Inhalt").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ m: ALEMessage) -> some View {
        let color: Color = m.kind == "NACHRICHT" ? RadioTheme.vfdAmber : m.quality < 40 ? RadioTheme.textMuted : RadioTheme.vfdGreen
        return HStack(spacing: 8) {
            Text(ALEController.utc.string(from: m.receivedAt)).frame(width: 56, alignment: .leading)
            Text(m.kind).frame(width: 84, alignment: .leading)
            Text(verbatim: "\(m.quality)").frame(width: 26, alignment: .trailing)
            Text(m.summary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(2)
        .help(tooltip(m))
    }

    private func tooltip(_ m: ALEMessage) -> String {
        var s = "\(m.words.count) Wörter · Q = einstimmige Bit des schlechtesten Wortes (48 = fehlerfrei) · Ø \(String(format: "%.1f", m.meanErrors)) Golay-Fehler je Wort"
        s += "\nVerstimmung \(Int(m.offsetHz.rounded())) Hz\n" + m.words.map { "\($0.preamble.name) \($0.text)" }.joined(separator: " | ")
        return s
    }
}

// MARK: - Abstimmanzeige und Einstellungen

struct ALETuningPanel: View {
    @ObservedObject var controller: ALEController
    @ObservedObject var settings: ALESettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ALE")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("8-FSK · 125 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(controller.locked ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text("SYNC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.locked ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
            .help("SYNC: Wörter im 392-ms-Raster werden gelesen")
            SignalBar(metric: min(100, controller.purity * 100 / 0.8), squelch: nil)
                .help("Anteil der Energie im stärksten der acht Töne: ein ALE-Signal erreicht deutlich mehr als Rauschen (≈ 13 %)")
            HStack {
                readout("VERSTIMMUNG", "\(Int(settings.offsetHz.rounded())) Hz")
                Spacer()
                readout("WÖRTER", "\(controller.wordCount)")
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

struct ALESettingsPanel: View {
    @ObservedObject var settings: ALESettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("AUTO") { settings.auto.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.auto))
                    .help("Verstimmung aus bekannten Wörtern nachführen (Energievergleich 15 Hz über und unter jedem Ton)")
                Button("−10") { settings.auto = false; settings.setOffset(settings.offsetHz - 10) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                Button("0") { settings.auto = false; settings.setOffset(0) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Verstimmung 0: Töne bei 750 … 2500 Hz")
                Button("+10") { settings.auto = false; settings.setOffset(settings.offsetHz + 10) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
            }
            HStack(spacing: 4) {
                Text("ZUVERL.")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 44, alignment: .leading)
                ForEach(ALESensitivity.allCases) { s in
                    Button(s.rawValue.uppercased()) { settings.sensitivity = s }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sensitivity == s))
                        .help("Mindestens \(s.firstMinimum) einstimmige Bit (von 48) für das erste, \(s.lockedMinimum) für folgende Wörter")
                }
            }
            Text(verbatim: "USB, Tonblock 750 … 2500 Hz (Mitte \(Int(settings.centerHz.rounded())) Hz). Klick in den Wasserfall setzt die Mitte (schaltet AUTO aus).")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
