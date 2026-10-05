// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Stationen, Pakete, Nachrichten

struct APRSMainPanel: View {
    @ObservedObject var controller: APRSController
    @ObservedObject var settings: APRSSettingsStore
    @ObservedObject var home: HomeLocation
    @State private var tab = Tab.stations

    enum Tab: String, CaseIterable, Identifiable {
        case stations = "STATIONEN", packets = "PAKETE", messages = "NACHRICHTEN"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
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
                .help("Pakete im TNC2-Format in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
                .help("Listen leeren (Log bleibt)")
            }
            Group {
                switch tab {
                case .stations: APRSStationTable(controller: controller, home: home)
                case .packets: APRSPacketTable(entries: controller.packets)
                case .messages: APRSMessageTable(entries: controller.messages)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        if controller.frameCount == 0 { return "Warten auf Pakete (\(settings.channel.label) MHz FM)" }
        var s = "\(controller.stations.count) Stationen · \(controller.frameCount) Pakete"
        if controller.repairedCount > 0 { s += " (\(controller.repairedCount) repariert)" }
        return s
    }
}

struct APRSStationTable: View {
    @ObservedObject var controller: APRSController
    let home: HomeLocation

    var body: some View {
        let stations = controller.sortedStations
        let now = Date()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                ForEach(stations) { s in row(s, now: now) }
            }
            .padding(6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 14)
            Text("Zuletzt").frame(width: 48, alignment: .leading)
            Text("Station").frame(width: 100, alignment: .leading)
            Text("Symbol").frame(width: 96, alignment: .leading)
            Text("km").frame(width: 48, alignment: .trailing)
            Text("Info").frame(maxWidth: .infinity, alignment: .leading)
            Text("Pkt").frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ s: APRSStation, now: Date) -> some View {
        let km = s.position.flatMap { p in home.point.map { Geo.distanceKm($0, p) } }
        let color: Color = s.killed ? RadioTheme.textDim : s.micEStatus == "Notfall" ? RadioTheme.ledRed : s.weather != nil ? MapTone.weather.color
            : s.isObject ? RadioTheme.vfdCyan : s.direct ? RadioTheme.vfdAmber : RadioTheme.vfdGreen
        let selected = controller.selection == s.id
        return HStack(spacing: 8) {
            Image(systemName: s.symbol?.systemImage ?? "mappin").frame(width: 14)
            Text(s.ageText(now: now)).frame(width: 48, alignment: .leading)
            Text(s.call).frame(width: 100, alignment: .leading).lineLimit(1)
            Text(s.symbol?.name ?? "").frame(width: 96, alignment: .leading).lineLimit(1)
            Text(km.map { String(format: "%.0f", $0) } ?? (s.position == nil ? "–" : "")).frame(width: 48, alignment: .trailing)
            Text(info(s)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text("\(s.packetCount)").frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .padding(.vertical, 1)
        .background(selected ? color.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { controller.selection = selected ? nil : s.id }
        .help(tooltip(s))
    }

    private func info(_ s: APRSStation) -> String {
        if let w = s.weather { return w.summary }
        var parts: [String] = []
        if let v = s.speedKnots, v >= 1 { parts.append("\(Int((v * 1.852).rounded())) km/h") }
        if let m = s.micEStatus { parts.append(m) }
        if !s.comment.isEmpty { parts.append(s.comment) } else if let st = s.status { parts.append(st) }
        return parts.joined(separator: " · ")
    }

    private func tooltip(_ s: APRSStation) -> String {
        var t = s.call
        if let p = s.position { t += "\n" + Geo.format(p) }
        if !s.lastPath.isEmpty { t += "\nWeg: " + s.lastPath.joined(separator: ",") }
        if let d = s.device { t += "\nGerät: \(d)" }
        if !s.comment.isEmpty { t += "\n" + s.comment }
        return t
    }
}

struct APRSPacketTable: View {
    let entries: [APRSLogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(APRSController.utc.string(from: e.time)).frame(width: 56, alignment: .leading)
                            Text(e.tnc2 + (e.repaired ? "  ~" : ""))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(e.repaired ? RadioTheme.textDim : e.packet.micEStatus == "Notfall" ? RadioTheme.ledRed : RadioTheme.vfdGreen)
                        .id(e.id)
                        .help(e.summary)
                    }
                }
                .padding(6)
            }
            .onChange(of: entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

struct APRSMessageTable: View {
    let entries: [APRSMessageEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        Text("Keine Nachrichten empfangen")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                    ForEach(entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(APRSController.utc.string(from: e.time)).frame(width: 56, alignment: .leading)
                            Text(e.from).frame(width: 90, alignment: .leading)
                            Text("→ " + e.to).frame(width: 100, alignment: .leading)
                            Text(e.text).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(e.kind == .bulletin ? RadioTheme.vfdAmber : RadioTheme.vfdCyan)
                        .id(e.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Abstimmanzeige und Einstellungen

struct APRSTuningPanel: View {
    @ObservedObject var controller: APRSController
    @ObservedObject var settings: APRSSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("APRS")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("AFSK 1200 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(controller.synced ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text("DCD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.synced ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
            .help("DCD: ein Paket wird gerade gelesen (Flag-Folge erkannt)")
            LevelBar(level: controller.level)
                .frame(height: 8)
                .help("Signalpegel der Töne 1200 und 2200 Hz (Hüllkurve)")
            HStack {
                readout("TÖNE", "\(Int(settings.centerHz - 500)) / \(Int(settings.centerHz + 500)) Hz")
                Spacer()
                readout("FREQUENZ", settings.channel.frequencyHz.map { String(format: "%.3f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") + " MHz" } ?? "frei")
            }
            HStack {
                readout("PAKETE", "\(controller.frameCount)")
                Spacer()
                readout("STATIONEN", "\(controller.stations.count)")
            }
            if let last = controller.lastFrameDate {
                readout("LETZTES", APRSController.utc.string(from: last) + " UTC")
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

private struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(RadioTheme.bgDeep)
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.9 ? RadioTheme.ledRed : level > 0.02 ? RadioTheme.vfdGreen : RadioTheme.textDim)
                    .frame(width: geo.size.width * min(1, max(0, level)))
            }
        }
    }
}

struct APRSSettingsPanel: View {
    @ObservedObject var settings: APRSSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(APRSChannel.allCases) { c in
                    Button { settings.channel = c } label: {
                        VStack(spacing: 1) {
                            Text(verbatim: c.name)
                            Text(verbatim: c.label).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                        }
                        .lineLimit(1)
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.channel == c))
                    .help(c.note + (c.frequencyHz == nil ? "" : " (nur mit QSY AUTO wird das Funkgerät in FM abgestimmt)"))
                }
            }
            HStack(spacing: 6) {
                Button("KORREKTUR") { settings.repairBits.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.repairBits))
                    .help("Ein fehlerhaftes Bit umkehren, wenn die Prüfsumme sonst stimmt. Solche Pakete stehen im Protokoll (~), aber nie auf der Karte")
                Button(settings.emphasis == .auto ? "AUDIO AUTO" : settings.emphasis == .on ? "DE-EMPH." : "FLACH") {
                    let all = AFSKReceiver.Emphasis.allCases
                    settings.emphasis = all[(all.firstIndex(of: settings.emphasis)! + 1) % all.count]
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.emphasis != .auto))
                .help("Audioart: AUTO liest flaches Diskriminator-Audio und de-emphasiertes Lautsprecher-Audio gleichzeitig. FLACH oder DE-EMPH. (hohe Töne angehoben) nutzt nur einen Weg und spart Rechenzeit. Klicken zum Umschalten")
            }
            HStack(spacing: 6) {
                Text("KARTE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach([1.0, 6.0, 24.0, 0.0], id: \.self) { h in
                    Button(h == 0 ? "ALLE" : "\(Int(h)) h") { settings.mapHours = h }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.mapHours == h))
                        .help(h == 0 ? "Alle Stationen auf der Karte" : "Nur Stationen, die in den letzten \(Int(h)) Stunden gehört wurden")
                }
            }
            Text(verbatim: "FM schmal (Diskriminator-Audio, ohne Rauschsperre). Klick in den Wasserfall setzt die Abweichung der Töne (\(Int(settings.offsetHz.rounded())) Hz).")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
