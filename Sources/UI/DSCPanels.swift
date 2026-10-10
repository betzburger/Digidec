// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Meldungsliste

struct DSCMessagePanel: View {
    @ObservedObject var controller: DSCController

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
                .help("Meldungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
            DSCTable(messages: controller.messages)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        if controller.messages.isEmpty { return "Warten auf Rufe (DSC-Kanäle: 2187,5 · 4207,5 · 6312 · 8414,5 · 12577 · 16804,5 kHz)" }
        let distress = controller.messages.filter(\.isDistress).count
        return "\(controller.messages.count) Rufe" + (distress > 0 ? " · \(distress) Seenot" : "")
    }
}

struct DSCTable: View {
    let messages: [DSCMessage]
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
            Text("Ruf").frame(width: 92, alignment: .leading)
            Text("Kat.").frame(width: 84, alignment: .leading)
            Text("Von").frame(width: 150, alignment: .leading)
            Text("An").frame(width: 120, alignment: .leading)
            Text("Inhalt").frame(maxWidth: .infinity, alignment: .leading)
            Text("ECC").frame(width: 34, alignment: .center)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ m: DSCMessage) -> some View {
        let color: Color = m.isDistress ? RadioTheme.ledRed : !m.eccOK ? RadioTheme.textDim : m.category == "DRINGLICHKEIT" ? RadioTheme.vfdAmber : RadioTheme.vfdGreen
        return HStack(spacing: 8) {
            Text(DSCController.utc.string(from: m.receivedAt)).frame(width: 56, alignment: .leading)
            Text(m.format.name).frame(width: 92, alignment: .leading)
            Text(m.category ?? "").frame(width: 84, alignment: .leading)
            Text(Self.partyText(m.from)).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(Self.partyText(m.to)).frame(width: 120, alignment: .leading).lineLimit(1)
            Text(m.summary).frame(maxWidth: .infinity, alignment: .leading)
            Text(m.eccOK ? "OK" : "?").frame(width: 34, alignment: .center)
        }
        .font(.system(size: 11, weight: m.isDistress ? .bold : .medium, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
        .help(tooltip(m))
    }

    /// MMSI, mit dem Namen des Schiffs dahinter, wenn es per AIS gehört wurde
    private static func partyText(_ mmsi: String?) -> String {
        guard let mmsi, !mmsi.isEmpty else { return "" }
        if let name = DigidecState.shared.vesselLabel(mmsi: mmsi) { return mmsi + " " + name }
        return mmsi
    }

    private func tooltip(_ m: DSCMessage) -> String {
        var s = "Symbole: " + m.symbols.map { $0 < 0 ? "--" : String(format: "%03d", $0) }.joined(separator: " ")
        s += m.centerHz > 0 ? "\nNF-Mitte \(Int(m.centerHz.rounded())) Hz" : "\nUKW Kanal 70, 1200 Bd"
        if !m.eccOK { s += "\nECC stimmt nicht: Inhalt unsicher" }
        if m.unreadable > 0 { s += "\n\(m.unreadable) Symbole in DX und RX unlesbar" }
        return s
    }
}

// MARK: - Abstimmanzeige und Einstellungen

struct DSCTuningPanel: View {
    @ObservedObject var controller: DSCController
    @ObservedObject var settings: DSCSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("DSC")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("100 Bd · 170 Hz")
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
            .help("SYNC: Phasing-Folge erkannt, ein Ruf wird gelesen")
            if let d = controller.lastDistress {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(RadioTheme.ledRed)
                    Text(verbatim: "SEENOT \(DSCController.utc.string(from: d.receivedAt)) · \(d.from ?? "?")")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.ledRed)
                }
                .help("Letzter Notruf: \(d.summary)")
            }
            if settings.channel.isVHF {
                HStack {
                    readout("TÖNE", "Y 1300 / B 2100 Hz")
                    Spacer()
                    readout("FM", "156,525 MHz")
                }
                .help("UKW-DSC Kanal 70: 1200 Bd, Y = 1300 Hz (tief), B = 2100 Hz (hoch); das Funkgerät steht auf FM")
            } else {
                HStack {
                    readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
                    Spacer()
                    readout("TÖNE", "\(Int(settings.centerHz - 85)) / \(Int(settings.centerHz + 85)) Hz")
                }
                HStack {
                    readout("GEMESSEN", controller.measuredCenter.map { "\(Int($0.rounded())) Hz" } ?? "---")
                    Spacer()
                    if let dial = settings.dialHz {
                        readout("DIAL", String(format: "%.3f", Double(dial) / 1000).replacingOccurrences(of: ".", with: ",") + " kHz")
                    }
                }
                .help("GEMESSEN: Mitte des erkannten Tonpaars im Abstand 170 Hz. DIAL: USB-Dial, damit der Rufträger bei der Mitte liegt")
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
    }
}

struct DSCSettingsPanel: View {
    @ObservedObject var settings: DSCSettingsStore

    @State private var editingChannel: DSCChannelItem?
    @State private var isNewChannel = false
    @State private var showChannelEditor = false
    @State private var editLabel = ""
    @State private var editFreqText = ""
    @State private var editIsVHF = false
    @State private var editNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            channelGrid

            if !settings.activeChannelItem.isVHF {
                HStack(spacing: 6) {
                    Button("AUTO") { settings.autoCenter.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.autoCenter))
                        .help("Mitte aus dem Tonpaar (Abstand 170 Hz) nachführen")
                    Button("REV") { settings.reversed.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.reversed))
                        .help("Seitenband umkehren (bei LSB): tiefer und hoher Ton vertauscht")
                }
            }
            if settings.activeChannelItem.isVHF {
                Text("UKW Kanal 70: FM, Diskriminator- oder Lautsprecher-Audio, 1200 Bd. Keine Abstimmung nötig.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            } else {
                Text(String(format: NSLocalizedString("USB, Rufträger bei %lld Hz. Klick in den Wasserfall setzt die Mitte (schaltet AUTO aus).", comment: ""), Int(settings.centerHz.rounded())))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
        .sheet(isPresented: $showChannelEditor) {
            PresetModalSheet(
                title: isNewChannel ? "NEUER DSC-KANAL" : "DSC-KANAL BEARBEITEN",
                isValid: !editLabel.trimmingCharacters(in: .whitespaces).isEmpty,
                onSave: saveChannel,
                onCancel: { showChannelEditor = false }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey("Bezeichnung"))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .frame(width: 110, alignment: .leading)
                        TextField("z. B. 2187,5 oder K70", text: $editLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey("Frequenz (kHz)"))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .frame(width: 110, alignment: .leading)
                        TextField("z. B. 2187,5 oder 156525 (leer = frei)", text: $editFreqText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey("Band / Mode"))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .frame(width: 110, alignment: .leading)
                        Button("MF/HF (USB)") { editIsVHF = false }
                            .buttonStyle(ModeButtonStyle(isSelected: !editIsVHF))
                        Button("UKW (FM)") { editIsVHF = true }
                            .buttonStyle(ModeButtonStyle(isSelected: editIsVHF))
                    }
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey("Notiz"))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .frame(width: 110, alignment: .leading)
                        TextField("z. B. Seenot / Arbeitskanal", text: $editNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    private var channelGrid: some View {
        let count = settings.channels.count + 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(count, 5)), spacing: 4) {
            ForEach(settings.channels) { c in
                Button {
                    settings.selectChannel(id: c.id)
                } label: {
                    Text(verbatim: c.label).lineLimit(1).minimumScaleFactor(0.7)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.selectedChannelID == c.id))
                .help(c.frequencyHz == nil ? "Funkgerät nicht abstimmen" : (c.isVHF ? "UKW-DSC Kanal 70, 156,525 MHz, FM" : "DSC \(c.label) kHz"))
                .presetContextMenu(
                    onEdit: { startEditChannel(c) },
                    onDelete: settings.channels.count > 1 ? { settings.removeChannel(id: c.id) } : nil,
                    onReset: { settings.resetChannelsToDefault() }
                )
            }

            Button {
                startAddChannel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
            .help("Neuen DSC-Kanal hinzufügen")
        }
    }

    private func startAddChannel() {
        isNewChannel = true
        editingChannel = nil
        editLabel = ""
        editFreqText = ""
        editIsVHF = false
        editNote = ""
        showChannelEditor = true
    }

    private func startEditChannel(_ c: DSCChannelItem) {
        isNewChannel = false
        editingChannel = c
        editLabel = c.label
        if let f = c.frequencyHz {
            let khz = f / 1000
            editFreqText = khz == khz.rounded() ? String(format: "%.0f", khz) : String(format: "%.1f", khz).replacingOccurrences(of: ".", with: ",")
        } else {
            editFreqText = ""
        }
        editIsVHF = c.isVHF
        editNote = c.note
        showChannelEditor = true
    }

    private func saveChannel() {
        let clean = editFreqText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let freqHz = clean.isEmpty ? nil : (Double(clean).map { $0 * 1000 })
        let item = DSCChannelItem(
            id: editingChannel?.id ?? UUID().uuidString,
            label: editLabel.trimmingCharacters(in: .whitespaces),
            frequencyHz: freqHz,
            isVHF: editIsVHF,
            note: editNote.trimmingCharacters(in: .whitespaces)
        )
        if isNewChannel {
            settings.addChannel(item)
        } else {
            settings.updateChannel(item)
        }
        showChannelEditor = false
    }
}
