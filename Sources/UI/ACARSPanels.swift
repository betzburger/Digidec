// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - ACARS: Meldungsliste

struct ACARSMessagePanel: View {
    @ObservedObject var controller: ACARSController
    @ObservedObject var settings: ACARSSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
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
            ACARSTable(messages: controller.visible)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        if controller.count == 0 { return "Warten auf ACARS (\(settings.channel.label) MHz, AM)" }
        return "\(controller.visible.count) von \(controller.count) Meldungen · \(controller.aircraft.count) Flugzeuge"
    }
}

struct ACARSTable: View {
    let messages: [ACARSMessage]
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
            Text("UTC").frame(width: 76, alignment: .leading)
            Text("Kennzeichen").frame(width: 78, alignment: .leading)
            Text("Flug").frame(width: 62, alignment: .leading)
            Text("↕").frame(width: 14, alignment: .center)
            Text("Lbl").frame(width: 24, alignment: .leading)
            Text("ADS-B").frame(width: 104, alignment: .leading)
            Text("Meldung").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ m: ACARSMessage) -> some View {
        let color: Color = m.isEmpty ? RadioTheme.textMuted : m.isDownlink ? RadioTheme.vfdGreen : RadioTheme.vfdCyan
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ACARSController.utc.string(from: m.time)).frame(width: 76, alignment: .leading)
            Text(m.registration.isEmpty ? "–" : m.registration).frame(width: 78, alignment: .leading).lineLimit(1)
            Text(m.flightID ?? "").frame(width: 62, alignment: .leading).lineLimit(1)
            Image(systemName: m.isDownlink ? "arrow.down" : "arrow.up").font(.system(size: 8, weight: .bold)).frame(width: 14)
            Text(m.label).frame(width: 24, alignment: .leading)
            Text(DigidecState.shared.aircraftSummary(for: m) ?? "").frame(width: 104, alignment: .leading).lineLimit(1)
                .foregroundColor(RadioTheme.vfdAmber)
                .help("Dasselbe Flugzeug im ADS-B-Modul: Höhe und Entfernung")
            Text(m.isEmpty ? (ACARSLabels.describe(m.label) ?? "ohne Text") : m.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .help(tooltip(m))
    }

    private func tooltip(_ m: ACARSMessage) -> String {
        var t = (m.isDownlink ? "Vom Flugzeug" : "Zum Flugzeug") + " · Label \(m.label)"
        if let d = ACARSLabels.describe(m.label) { t += " (\(d))" }
        t += " · Block \(m.blockID) · Modus \(m.mode)"
        if !m.ack.isEmpty { t += " · Quittung \(m.ack)" }
        if let n = m.messageNumber { t += " · Nr. \(n)" }
        t += String(format: "\nPegel %.1f dB", m.levelDB)
        if m.corrected > 0 { t += " · \(m.corrected) Bit korrigiert" }
        if m.continues { t += "\nMeldung wird im nächsten Block fortgesetzt" }
        if m.isDownlink || m.label == "HX", let p = ACARSPositionParser.parse(label: m.label, text: m.text) {
            t += "\nPosition " + Geo.format(p.point) + (p.altitudeFt.map { $0 > 0 ? " · \(Int($0)) ft" : " · am Boden" } ?? "")
                + (p.timeUTC.map { " · \($0) UTC" } ?? "")
        }
        if let o = ACARSLabels.oooi(label: m.label, text: m.text) {
            var parts: [String] = []
            if let v = o.from { parts.append("von \(v)" + (AirportCatalog.shared.lookup(v).map { " (\($0.city))" } ?? "")) }
            if let v = o.to { parts.append("nach \(v)" + (AirportCatalog.shared.lookup(v).map { " (\($0.city))" } ?? "")) }
            if let v = o.out { parts.append("Gate ab \(v)") }
            if let v = o.off { parts.append("Start \(v)") }
            if let v = o.on { parts.append("Landung \(v)") }
            if let v = o.in { parts.append("Gate an \(v)") }
            if let v = o.eta { parts.append("ETA \(v)") }
            t += "\n" + parts.joined(separator: " · ")
        }
        return t
    }
}

// MARK: - ACARS: Abstimmanzeige und Einstellungen

struct ACARSTuningPanel: View {
    @ObservedObject var controller: ACARSController
    @ObservedObject var settings: ACARSSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ACARS")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("MSK 2400 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(controller.inFrame ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text("DCD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.inFrame ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
            .help("DCD: Synchronisation erkannt, ein Block wird gelesen")
            HStack {
                readout("FREQUENZ", settings.channel.frequencyHz.map { String(format: "%.3f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") + " MHz" } ?? "frei")
                Spacer()
                readout("MELDUNGEN", "\(controller.count)")
            }
            HStack {
                readout("FLUGZEUGE", "\(controller.aircraft.count)")
                Spacer()
                readout("MIT ORT", "\(controller.aircraft.values.filter { $0.position != nil }.count)")
                    .help("Flugzeuge, von denen eine Positionsmeldung gelesen wurde (ihr Weg erscheint als Linie auf der Karte)")
            }
            if let last = controller.lastDate { readout("LETZTE", ACARSController.utc.string(from: last)) }
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

struct ACARSSettingsPanel: View {
    @ObservedObject var settings: ACARSSettingsStore

    @State private var editingChannel: ACARSChannelItem?
    @State private var isNewChannel = false
    @State private var showChannelEditor = false
    @State private var editName = ""
    @State private var editFreqText = ""
    @State private var editNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            channelGrid

            HStack(spacing: 6) {
                Button("UPLINK") { settings.showUplink.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.showUplink))
                    .help("Meldungen vom Boden zum Flugzeug zeigen")
                Button("LEERE AUS") { settings.hideEmpty.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.hideEmpty))
                    .help("Quittungen und Verbindungstests ohne Text ausblenden")
            }
            Text("AM, mit der Rauschsperre auf Dauerrauschen. Das NF-Audio trägt die Töne 1200 und 2400 Hz. Die Karte zeigt Flugzeuge, deren Meldungen eine Position enthalten (der Weg erscheint als Linie), und Start- und Zielflughäfen aus den OOOI-Berichten.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
        .sheet(isPresented: $showChannelEditor) {
            PresetModalSheet(
                title: isNewChannel ? "NEUER ACARS-KANAL" : "ACARS-KANAL BEARBEITEN",
                isValid: !editName.trimmingCharacters(in: .whitespaces).isEmpty,
                onSave: saveChannel,
                onCancel: { showChannelEditor = false }
            ) {
                SimpleChannelEditorView(unitTitle: "Frequenz (MHz)", name: $editName, freqText: $editFreqText, note: $editNote)
            }
        }
    }

    private var channelGrid: some View {
        let count = settings.channels.count + 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(count, 4)), spacing: 4) {
            ForEach(settings.channels) { c in
                Button {
                    settings.selectChannel(id: c.id)
                } label: {
                    Text(verbatim: c.label)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.selectedChannelID == c.id))
                .help(c.note.isEmpty ? (c.frequencyHz == nil ? "Funkgerät nicht abstimmen" : "ACARS \(c.label) MHz") : c.note)
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
            .help("Neuen ACARS-Kanal hinzufügen")
        }
    }

    private func startAddChannel() {
        isNewChannel = true
        editingChannel = nil
        editName = ""
        editFreqText = ""
        editNote = ""
        showChannelEditor = true
    }

    private func startEditChannel(_ c: ACARSChannelItem) {
        isNewChannel = false
        editingChannel = c
        editName = c.name
        editFreqText = c.frequencyHz.map { String(format: "%.3f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? ""
        editNote = c.note
        showChannelEditor = true
    }

    private func saveChannel() {
        let cleanText = editFreqText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let mhz = Double(cleanText)
        let hz = mhz.map { $0 * 1_000_000 }
        let name = editName.trimmingCharacters(in: .whitespaces)

        if isNewChannel {
            let item = ACARSChannelItem(id: UUID().uuidString, name: name, frequencyHz: hz, note: editNote.trimmingCharacters(in: .whitespaces))
            settings.addChannel(item)
        } else if let editingChannel {
            let item = ACARSChannelItem(id: editingChannel.id, name: name, frequencyHz: hz, note: editNote.trimmingCharacters(in: .whitespaces))
            settings.updateChannel(item)
        }
        showChannelEditor = false
    }
}
