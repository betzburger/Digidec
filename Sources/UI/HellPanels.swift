// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Raster (Feld Hell, FSK Hell)

struct HellRasterPanel: View {
    @ObservedObject var controller: HellController
    @ObservedObject var raster: HellRasterModel
    @ObservedObject var settings: HellSettingsStore

    init(controller: HellController, settings: HellSettingsStore) {
        self.controller = controller
        raster = controller.raster
        self.settings = settings
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ActivityLED(lastChar: controller.lastColumnDate)
                Text(raster.columnCount == 0 ? "Warten auf Hell-Signal" : "\(raster.columnCount) Spalten")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Button {
                    save()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(raster.image == nil)
                .help("Das Bild als PNG speichern")
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Bild löschen")
            }
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(settings.options.blackboard ? Color.black : Color.white.opacity(0.92))
                    if let image = raster.image {
                        // Breite füllen; zu hohe Bilder zeigen den unteren (neuesten) Teil
                        let scale = geo.size.width / image.size.width
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: geo.size.width, height: image.size.height * scale)
                            .frame(maxHeight: geo.size.height, alignment: .bottom)
                            .clipped()
                    }
                }
                .cornerRadius(6)
            }
        }
    }

    private func save() {
        guard let data = raster.pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "hell.png"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

// MARK: - Abstimmanzeige und Einstellungen

private func hellReadout(_ label: String, _ value: String) -> some View {
    HStack(spacing: 4) {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
        Text(value)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(RadioTheme.vfdCyan)
    }
}

struct HellTuningPanel: View {
    @ObservedObject var controller: HellController
    @ObservedObject var settings: HellSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.options.mode.displayName.uppercased())
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Spacer()
                Text(String(format: "%.0f Hz breit", settings.options.mode.bandwidthHz))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help(settings.options.mode.note)
            SignalBar(metric: controller.status?.metric ?? 0, squelch: settings.options.squelchOn ? settings.options.squelch : nil)
                .help("Signalstärke (fldigi: 1000 · AGC-Pegel). Unter der Squelch-Marke werden keine Spalten geschrieben")
            HStack {
                hellReadout("FILTER", controller.status.map { "\(Int($0.filterHz.rounded())) Hz" } ?? "---")
                Spacer()
                hellReadout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
            }
        }
    }
}

struct HellSettingsPanel: View {
    @ObservedObject var settings: HellSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(HellMode.allCases) { m in
                    Button { settings.options.mode = m } label: { Text(verbatim: m.shortName).lineLimit(1).minimumScaleFactor(0.6) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.mode == m))
                        .help(m.note)
                }
            }
            HStack(spacing: 4) {
                Text("HÖHE").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim).frame(width: 38, alignment: .leading)
                ForEach([14, 20, 28, 36, 42], id: \.self) { h in
                    Button("\(h)") { settings.options.columnHeight = h }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.columnHeight == h))
                        .help("Spaltenlänge in Pixeln: die Schrifthöhe im Bild")
                }
            }
            HStack(spacing: 4) {
                Text("BREITE").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim).frame(width: 38, alignment: .leading)
                ForEach(1...3, id: \.self) { w in
                    Button("\(w)×") { settings.options.columnRepeat = w }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.columnRepeat == w))
                        .help("Jede Spalte so oft zeichnen: breitere Schrift")
                }
                Text("AGC").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim).padding(.leading, 6)
                ForEach([(1, "1"), (2, "2"), (3, "3")], id: \.0) { a in
                    Button(a.1) { settings.options.agc = a.0 }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.agc == a.0))
                        .help("Pegelnachführung: 1 langsam, 2 mittel, 3 schnell")
                }
            }
            HStack(spacing: 6) {
                if settings.options.mode.isFSK {
                    Button("REV") { settings.options.reverse.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.reverse))
                        .help("FSK-Hell: Töne vertauschen (bei LSB)")
                }
                Button("TAFEL") { settings.options.blackboard.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.blackboard))
                    .help("Umkehrdarstellung: weiße Schrift auf Schwarz")
                Button("SQL") { settings.options.squelchOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.squelchOn))
                    .help("Spalten nur bei ausreichender Signalstärke schreiben")
                Slider(value: $settings.options.squelch, in: 0...100)
                    .disabled(!settings.options.squelchOn)
            }
            Text(verbatim: "Hell überträgt Schrift als Bild: die Zeichen werden nicht erkannt. Klick in den Wasserfall setzt die Mitte. Mitte \(Int(settings.centerHz.rounded())) Hz, Band \(Int(settings.centerHz - settings.options.mode.bandwidthHz / 2)) … \(Int(settings.centerHz + settings.options.mode.bandwidthHz / 2)) Hz")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
