// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Spotliste

struct WSPRActivityPanel: View {
    @ObservedObject var controller: WSPRController
    @ObservedObject var settings: WSPRSettingsStore

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
                .help("Spots im Format von ALL_WSPR.TXT in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
            WSPRTable(entries: controller.entries)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        guard let c = controller.lastSlot else { return "Warten auf den ersten Zyklus (alle 2 Minuten, gerade UTC-Minute)" }
        return "\(c.decodes.count) Spots um \(WSPRController.utc.string(from: c.slotStart)) UTC · "
            + String(format: "%.1f s Rechenzeit", c.duration)
            + (c.coverage < 0.9 ? String(format: " · nur %.0f %% Audio", c.coverage * 100) : "")
    }
}

/// Tabelle wie WSJT-X/wsprnet: UTC · dB · DT · Frequenz · Drift · Rufzeichen · Locator · Leistung · km
struct WSPRTable: View {
    let entries: [WSPREntry]
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
                if i > 0 && entries[i - 1].decode.slotStart != e.decode.slotStart {
                    Rectangle().fill(RadioTheme.borderSubtle).frame(height: 1).padding(.vertical, 1)
                }
                row(e).id(e.id)
            }
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 36, alignment: .leading)
            Text("dB").frame(width: 28, alignment: .trailing)
            Text("DT").frame(width: 34, alignment: .trailing)
            Text("MHz").frame(width: 76, alignment: .trailing)
            Text("Dr").frame(width: 20, alignment: .trailing)
            Text("DX").frame(width: 24, alignment: .center)
            Text("Rufzeichen").frame(width: 100, alignment: .leading)
            Text("Loc").frame(width: 52, alignment: .leading)
            Text("Leistung").frame(maxWidth: .infinity, alignment: .leading)
            Text("km").frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ e: WSPREntry) -> some View {
        let d = e.decode
        let m = d.message
        let color: Color = e.mentionsMe ? RadioTheme.ledRed : m.isHashed ? RadioTheme.textMuted : RadioTheme.vfdGreen
        return HStack(spacing: 8) {
            Text(WSPRController.utc.string(from: d.slotStart)).frame(width: 36, alignment: .leading)
            Text(String(format: "%+d", d.snrDB)).frame(width: 28, alignment: .trailing)
            Text(String(format: "%.1f", d.dt)).frame(width: 34, alignment: .trailing)
            Text(verbatim: String(format: "%.6f", e.rfHz / 1_000_000)).frame(width: 76, alignment: .trailing)
            Text(verbatim: "\(d.drift)").frame(width: 20, alignment: .trailing)
            Text(e.dxcc?.flag ?? "").frame(width: 24, alignment: .center)
            Text(m.call).frame(width: 100, alignment: .leading)
            Text(m.grid ?? "").frame(width: 52, alignment: .leading)
            Text(m.powerDBm.map { "\($0) dBm · \(m.powerLabel)" } ?? "").frame(maxWidth: .infinity, alignment: .leading)
            Text(e.km.map { String(format: "%.0f", $0) } ?? "").frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
        .help(tooltip(e))
    }

    private func tooltip(_ e: WSPREntry) -> String {
        var lines: [String] = []
        if let dx = e.dxcc {
            lines.append("\(dx.flag) \(dx.name) (\(dx.continent)) · CQ \(dx.cqZone) · ITU \(dx.ituZone)")
        }
        var s = String(format: "Sync %.2f · Durchgang %d · Drift %d Hz/min", e.decode.sync, e.decode.pass, e.decode.drift)
        if let km = e.km, let b = e.bearing { s += String(format: " · %.0f km, %.0f°", km, b) }
        lines.append(s)
        if e.decode.message.isHashed { lines.append("Rufzeichen nur als Hash empfangen (Typ 3)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Zyklus

struct WSPRCyclePanel: View {
    @ObservedObject var controller: WSPRController
    @ObservedObject var settings: WSPRSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let t = ctx.date.timeIntervalSince1970
                let inSlot = t.truncatingRemainder(dividingBy: WSPRCore.slotSeconds)
                let sending = inSlot >= 1 && inSlot < 111.6
                HStack(spacing: 8) {
                    Text(String(format: "%d:%02d", Int(inSlot) / 60, Int(inSlot) % 60))
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundColor(sending ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                        .frame(width: 60, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(RadioTheme.bgDeep)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(sending ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * inSlot / WSPRCore.slotSeconds)))
                            }
                        }
                        .frame(height: 6)
                        Text(controller.decoder.isBusy ? "DECODIERT …" : "EMPFANG · Decodieren bei 1:54")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                }
            }
            .help("Minute und Sekunde im 2-Minuten-Zyklus (UTC). Die Rechneruhr muss auf ±1 s genau gehen (Systemeinstellungen → Datum & Uhrzeit automatisch)")
            HStack {
                readout("ZYKLEN", "\(controller.slotCount)")
                Spacer()
                readout("STATIONEN", "\(controller.stationCount)")
                Spacer()
                readout("DIAL", settings.band.dialLabel)
            }
            if let b = controller.best, let km = b.km {
                HStack(spacing: 4) {
                    Text("DX")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Text("\(b.dxcc?.flag ?? "") \(b.decode.message.plainCall) · \(Int(km.rounded())) km")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                }
                .help("Weitester Empfang dieser Sitzung (Entfernung vom eigenen Locator \(settings.locator))")
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

// MARK: - Einstellungen

struct WSPRSettingsPanel: View {
    @ObservedObject var settings: WSPRSettingsStore
    @State private var callText = ""
    @State private var locText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(WSPRBand.allCases) { b in
                    Button { settings.band = b } label: { Text(b.rawValue).lineLimit(1).minimumScaleFactor(0.6) }
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
                    .help("Eigenes Rufzeichen: Spots daran erscheinen rot (Digidec sendet nie)")
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
                Button("±150 Hz") { settings.core.wide.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.core.wide))
                    .help("Suchbereich 1350 … 1650 Hz statt 1390 … 1610 Hz (wsprd „-w“)")
                Button("TIEF") { settings.core.deep.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.core.deep))
                    .help("Mehr Kandidaten prüfen (wsprd „-d“): langsamer, wenige Spots mehr")
            }
            HStack(spacing: 6) {
                label("ZEITKORR.")
                Slider(value: $settings.timeOffset, in: -1...1, step: 0.05)
                Text(String(format: "%+.2f s", settings.timeOffset))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 52, alignment: .trailing)
            }
            .help("Laufzeit vom Funkgerät bis zum Decoder. WSPR verträgt ± 2 s; liegt DT der meisten Stationen weit neben 0, hier nachstellen")
        }
    }

    private var dialHint: String {
        if let rig = settings.rigDialHz {
            let b = WSPRBand.band(forDial: rig)
            return "Funkgerät: \(String(format: "%.4f", Double(rig) / 1_000_000).replacingOccurrences(of: ".", with: ",")) MHz"
                + (b.map { " (\($0.rawValue))" } ?? " – kein WSPR-Kanal")
        }
        return "USB-Dial \(settings.band.dialLabel) MHz · Signale bei 1400 … 1600 Hz"
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
