// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private func packetAge(_ date: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 90 { return "\(s) s" }
    if s < 5400 { return "\(s / 60) min" }
    if s < 172_800 { return "\(s / 3600) h" }
    return "\(s / 86_400) d"
}

private func packetTime(_ date: Date) -> String { APRSController.utc.string(from: date) }

// MARK: - Hauptbereich

struct PacketMainPanel: View {
    @ObservedObject var controller: PacketController
    @ObservedObject var settings: PacketSettingsStore
    /// Entwicklungshilfe: DIGIDEC_PACKET_TAB=monitor|stations|digipeaters|sessions|mail|nodes öffnet die Karte (für Schnappschüsse)
    @State private var tab = Tab.fromEnvironment()

    enum Tab: String, CaseIterable, Identifiable {
        case monitor = "MONITOR", stations = "STATIONEN", digipeaters = "DIGIPEATER", sessions = "VERBINDUNGEN", mail = "NACHRICHTEN", nodes = "KNOTEN"
        var id: String { rawValue }

        static func fromEnvironment() -> Tab {
            switch ProcessInfo.processInfo.environment["DIGIDEC_PACKET_TAB"] {
            case "stations": return .stations
            case "digipeaters": return .digipeaters
            case "sessions": return .sessions
            case "mail": return .mail
            case "nodes": return .nodes
            default: return .monitor
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 560)
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
                .help("Rahmen und entpackte Nachrichten in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
                case .monitor: PacketMonitorTable(entries: controller.monitor)
                case .stations: PacketStationTable(stations: controller.stations)
                case .digipeaters: PacketDigipeaterTable(digipeaters: controller.digipeaters)
                case .sessions: PacketSessionView(controller: controller)
                case .mail: PacketMailView(controller: controller, settings: settings)
                case .nodes: PacketNodeTable(nodes: controller.nodes)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        if controller.frameCount == 0 { return "Warten auf Rahmen (\(settings.channel.label) MHz FM)" }
        var s = "\(controller.stations.count) Stationen · \(controller.frameCount) Rahmen"
        if controller.repairedCount > 0 { s += " (\(controller.repairedCount) repariert)" }
        return s
    }
}

private let packetHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)
private let packetRowFont = Font.system(size: 11, weight: .medium, design: .monospaced)

// MARK: - Monitor

struct PacketMonitorTable: View {
    let entries: [PacketMonitorEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if entries.isEmpty { PacketEmptyHint(text: "Noch kein Rahmen empfangen. Packet-Radio: FM, 1200 Bd, Diskriminator-Audio.") }
                    ForEach(entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(packetTime(e.time)).frame(width: 56, alignment: .leading)
                            Text(e.line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(3)
                        }
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(color(e))
                        .id(e.id)
                        .help(e.frame.ctl.type.meaning + (e.repaired ? " · Bit repariert, nicht ausgewertet" : ""))
                    }
                }
                .padding(6)
            }
            .onChange(of: entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func color(_ e: PacketMonitorEntry) -> Color {
        if e.repaired { return RadioTheme.textDim }
        switch e.frame.ctl.type {
        case .information: return RadioTheme.vfdCyan
        case .unnumberedInfo, .test, .exchangeID: return RadioTheme.vfdGreen
        case .connect, .connectExtended, .disconnect, .acknowledge, .disconnectedMode, .frameReject: return RadioTheme.vfdAmber
        default: return RadioTheme.textMuted
        }
    }
}

struct PacketEmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .padding(4)
    }
}

// MARK: - Stationen und Digipeater

struct PacketStationTable: View {
    let stations: [PacketStation]

    var body: some View {
        let now = Date()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Zuletzt").frame(width: 48, alignment: .leading)
                    Text("Station").frame(width: 90, alignment: .leading)
                    Text("Rolle").frame(width: 76, alignment: .leading)
                    Text("Name").frame(width: 64, alignment: .leading)
                    Text("Weg").frame(width: 150, alignment: .leading)
                    Text("Text / Kennung").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Rahmen").frame(width: 50, alignment: .trailing)
                }
                .font(packetHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                if stations.isEmpty { PacketEmptyHint(text: "Noch keine Station gehört") }
                ForEach(stations) { s in
                    let color: Color = s.sid?.isWinlink == true ? RadioTheme.vfdCyan : s.sid != nil ? RadioTheme.vfdAmber : s.isDigipeater ? RadioTheme.vfdAmber : s.direct ? RadioTheme.vfdGreen : RadioTheme.textMuted
                    HStack(spacing: 8) {
                        Text(packetAge(s.lastHeard, now: now)).frame(width: 48, alignment: .leading)
                        Text(s.call).frame(width: 90, alignment: .leading).lineLimit(1)
                        Text(s.role).frame(width: 76, alignment: .leading).lineLimit(1)
                        Text(s.alias ?? "").frame(width: 64, alignment: .leading).lineLimit(1)
                        Text(s.lastPath.isEmpty ? "direkt" : s.lastPath.joined(separator: ",")).frame(width: 150, alignment: .leading).lineLimit(1)
                        Text(s.sid?.text ?? s.lastText ?? "").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text("\(s.frames)").frame(width: 50, alignment: .trailing)
                    }
                    .font(packetRowFont)
                    .foregroundColor(color)
                    .padding(.vertical, 1)
                    .help(tooltip(s))
                }
            }
            .padding(6)
        }
    }

    private func tooltip(_ s: PacketStation) -> String {
        var t = s.call
        if let sid = s.sid { t += "\nKennung: \(sid.text)" }
        if let a = s.alias { t += "\nNET/ROM-Name: \(a)" }
        if !s.lastPath.isEmpty { t += "\nWeg: \(s.lastPath.joined(separator: ","))" }
        if let l = s.lastText { t += "\n\(l)" }
        if s.sessions > 0 { t += "\n\(s.sessions) Verbindung(en)" }
        return t
    }
}

struct PacketDigipeaterTable: View {
    let digipeaters: [PacketDigipeater]

    var body: some View {
        let now = Date()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Zuletzt").frame(width: 48, alignment: .leading)
                    Text("Digipeater").frame(width: 100, alignment: .leading)
                    Text("Gehört").frame(width: 60, alignment: .trailing)
                    Text("Im Weg").frame(width: 60, alignment: .trailing)
                    Text("Stationen").frame(width: 70, alignment: .trailing)
                    Text("Weitergegeben für").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(packetHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                if digipeaters.isEmpty { PacketEmptyHint(text: "Noch kein Digipeater gehört (ein Digipeater zeigt sich im Weg mit „*“, wenn er einen Rahmen weitergegeben hat)") }
                ForEach(digipeaters) { d in
                    HStack(spacing: 8) {
                        Text(packetAge(d.lastHeard, now: now)).frame(width: 48, alignment: .leading)
                        Text(d.call).frame(width: 100, alignment: .leading).lineLimit(1)
                        Text("\(d.heard)").frame(width: 60, alignment: .trailing)
                        Text("\(d.inPath)").frame(width: 60, alignment: .trailing)
                        Text("\(d.sources.count)").frame(width: 70, alignment: .trailing)
                        Text(d.sources.sorted().prefix(8).joined(separator: " ") + (d.sources.count > 8 ? " …" : "")).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    }
                    .font(packetRowFont)
                    .foregroundColor(d.heard > 0 ? RadioTheme.vfdAmber : RadioTheme.textMuted)
                    .padding(.vertical, 1)
                    .help("Gehört: Rahmen, bei denen dieser Digipeater der letzte Sender war (also hier direkt zu hören). Im Weg: Rahmen, die er schon weitergegeben hatte.")
                }
            }
            .padding(6)
        }
    }
}

// MARK: - NET/ROM

struct PacketNodeTable: View {
    let nodes: [PacketNodeEntry]

    var body: some View {
        let now = Date()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Zuletzt").frame(width: 48, alignment: .leading)
                    Text("Name").frame(width: 70, alignment: .leading)
                    Text("Knoten").frame(width: 90, alignment: .leading)
                    Text("Güte").frame(width: 40, alignment: .trailing)
                    Text("Nachbar").frame(width: 90, alignment: .leading)
                    Text("Gehört von").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(packetHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                if nodes.isEmpty { PacketEmptyHint(text: "Noch keine NET/ROM-Knotenliste gehört (Aussendung „NODES“, PID CF)") }
                ForEach(nodes) { n in
                    HStack(spacing: 8) {
                        Text(packetAge(n.lastHeard, now: now)).frame(width: 48, alignment: .leading)
                        Text(n.alias).frame(width: 70, alignment: .leading).lineLimit(1)
                        Text(n.call).frame(width: 90, alignment: .leading).lineLimit(1)
                        Text("\(n.quality)").frame(width: 40, alignment: .trailing)
                        Text(n.neighbour).frame(width: 90, alignment: .leading).lineLimit(1)
                        Text(n.heardFrom).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    }
                    .font(packetRowFont)
                    .foregroundColor(n.quality >= 150 ? RadioTheme.vfdGreen : n.quality >= 80 ? RadioTheme.vfdAmber : RadioTheme.textMuted)
                    .padding(.vertical, 1)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Verbindungen

struct PacketSessionView: View {
    @ObservedObject var controller: PacketController

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 330)
            Divider().background(RadioTheme.borderSubtle)
            detail
        }
    }

    private var list: some View {
        let now = Date()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if controller.sessions.isEmpty { PacketEmptyHint(text: "Noch keine Verbindung gehört. Verbindungen erkennt Digipeater-Betrieb, Mailbox und Winlink.") }
                ForEach(controller.sessions) { s in
                    let selected = controller.selectedSession == s.id
                    HStack(spacing: 6) {
                        Image(systemName: icon(s)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(s.caller) → \(s.callee)").lineLimit(1)
                            Text(subtitle(s, now: now))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(badge(s))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.bgDeep)
                            .padding(.horizontal, 4)
                            .background(badgeColor(s))
                            .cornerRadius(3)
                    }
                    .font(packetRowFont)
                    .foregroundColor(s.isOpen ? RadioTheme.vfdGreen : RadioTheme.textMuted)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(selected ? RadioTheme.vfdGreen.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.selectedSession = selected ? nil : s.id }
                }
            }
            .padding(6)
        }
    }

    private func icon(_ s: PacketSession) -> String {
        switch s.state {
        case .connecting: return "phone.arrow.up.right"
        case .connected: return "phone.connection.fill"
        case .observed: return "phone.connection"
        case .closed: return "phone.down"
        case .refused: return "phone.down.fill"
        }
    }

    private func badge(_ s: PacketSession) -> String {
        switch s.kind {
        case .winlink: return "WINLINK"
        case .mailbox: return "MAILBOX"
        case .text: return s.state == .refused ? "ABGELEHNT" : ""
        }
    }

    private func badgeColor(_ s: PacketSession) -> Color {
        switch s.kind {
        case .winlink: return RadioTheme.vfdCyan
        case .mailbox: return RadioTheme.vfdAmber
        case .text: return RadioTheme.ledRed
        }
    }

    private func subtitle(_ s: PacketSession, now: Date) -> String {
        var t = "\(packetTime(s.started)) · \(s.infoFrames) Datenrahmen · \(s.bytes[0] + s.bytes[1]) Byte"
        switch s.state {
        case .connecting: t += " · Aufbau"
        case .connected: t += " · steht"
        case .observed: t += " · mitgehört"
        case .closed: t += " · beendet"
        case .refused: t += ""
        }
        if !s.via.isEmpty { t += " · via " + s.via.joined(separator: ",") }
        return t
    }

    @ViewBuilder
    private var detail: some View {
        if let id = controller.selectedSession, let s = controller.sessions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                header(s)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(s.lines) { l in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(packetTime(l.time)).frame(width: 52, alignment: .leading).foregroundColor(RadioTheme.textDim)
                                    Text(l.kind == .note ? "#" : l.direction == 0 ? "→" : "←").frame(width: 12)
                                    Text(l.text).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundColor(color(l))
                                .id(l.id)
                            }
                        }
                    }
                    .onChange(of: s.lines.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                proposals(s)
            }
            .padding(6)
        } else {
            PacketEmptyHint(text: "Verbindung links auswählen: Gesprächsverlauf, Kennungen und Winlink-Nachrichten")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func color(_ l: PacketSessionLine) -> Color {
        switch l.kind {
        case .note: return RadioTheme.textDim
        case .binary: return RadioTheme.textMuted
        case .text: return l.direction == 0 ? RadioTheme.vfdAmber : RadioTheme.vfdCyan
        }
    }

    private func header(_ s: PacketSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.title).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.transcript, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Gesprächsverlauf in die Zwischenablage kopieren")
            }
            Text(statistics(s))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .lineLimit(2)
        }
    }

    private func statistics(_ s: PacketSession) -> String {
        var parts = ["\(s.frames) Rahmen", "\(s.infoFrames) Daten"]
        if s.retransmissions > 0 { parts.append("\(s.retransmissions) Wiederholungen") }
        if s.gaps > 0 { parts.append("\(s.gaps) Lücken") }
        let sids = s.mail.sids.compactMap { $0?.text }
        if !sids.isEmpty { parts.append("Kennung " + sids.joined(separator: " / ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func proposals(_ s: PacketSession) -> some View {
        let all = s.mail.proposals.flatMap { $0 }
        if !all.isEmpty || !s.mail.notes.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("WEITERLEITUNG").font(packetHeaderFont).foregroundColor(RadioTheme.textDim)
                ForEach(Array(all.enumerated()), id: \.offset) { _, p in
                    Text(proposalText(p))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(p.delivered ? RadioTheme.vfdCyan : p.answer == "-" ? RadioTheme.textDim : RadioTheme.vfdAmber)
                        .lineLimit(1)
                }
                ForEach(Array(s.mail.notes.enumerated()), id: \.offset) { _, n in
                    Text("! " + n).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.ledRed).lineLimit(2)
                }
            }
            .padding(4)
            .background(RadioTheme.bgPanel)
            .cornerRadius(4)
        }
    }

    private func proposalText(_ p: MailProposal) -> String {
        let state = p.delivered ? "✓ gelesen" : p.answer == "+" ? "angenommen" : p.answer == "-" ? "abgelehnt" : p.answer == "=" ? "zurückgestellt" : "Antwort nicht gehört"
        if p.code == "C" || p.code == "D" { return "\(p.type) \(p.mid) · \(p.size) Byte (gepackt \(p.compressedSize)) · \(state)" }
        return "\(p.line) · \(state)"
    }
}

// MARK: - Nachrichten

struct PacketMailView: View {
    @ObservedObject var controller: PacketController
    @ObservedObject var settings: PacketSettingsStore

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 330)
            Divider().background(RadioTheme.borderSubtle)
            detail
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if controller.mail.isEmpty {
                    PacketEmptyHint(text: settings.decodeMail
                        ? "Noch keine Nachricht entpackt. Winlink-Nachrichten stehen erst nach der Übertragung zur Verfügung; Voraussetzung: kein Rahmen verpasst."
                        : "Nachrichten lesen ist ausgeschaltet (Einstellungen: NACHRICHTEN)")
                }
                ForEach(controller.mail) { item in
                    let selected = controller.selectedMail == item.id
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.message.subject.isEmpty ? "(ohne Betreff)" : item.message.subject).lineLimit(1)
                        Text("\(packetTime(item.message.received)) · \(item.message.from) → \(item.message.to.first ?? "?")\(item.message.to.count > 1 ? " +\(item.message.to.count - 1)" : "") · \(item.message.size) Byte")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .lineLimit(1)
                    }
                    .font(packetRowFont)
                    .foregroundColor(RadioTheme.vfdCyan)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? RadioTheme.vfdCyan.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.selectedMail = selected ? nil : item.id }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = controller.selectedMail, let item = controller.mail.first(where: { $0.id == id }) {
            let m = item.message
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.subject.isEmpty ? "(ohne Betreff)" : m.subject).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
                    VStack(alignment: .leading, spacing: 1) {
                        field("Von", m.from)
                        field("An", m.to.joined(separator: ", "))
                        if !m.cc.isEmpty { field("Cc", m.cc.joined(separator: ", ")) }
                        field("Datum", m.date + (m.type.isEmpty ? "" : " · " + m.type))
                        field("MID", m.mid + (m.mbo.isEmpty ? "" : " · Mailbox " + m.mbo))
                        field("Gehört", "\(item.caller) ↔ \(item.callee) · \(m.size) Byte (gepackt \(m.compressedSize))")
                    }
                    Divider().background(RadioTheme.borderSubtle)
                    Text(m.body.replacingOccurrences(of: "\r\n", with: "\n"))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(m.attachments.enumerated()), id: \.offset) { _, a in
                        AttachmentRow(attachment: a)
                    }
                }
                .padding(8)
            }
        } else {
            PacketEmptyHint(text: "Nachricht links auswählen. Nachrichten anderer bitte vertraulich behandeln und nicht weitergeben.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(packetHeaderFont).foregroundColor(RadioTheme.textDim).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan).textSelection(.enabled)
        }
    }
}

private struct AttachmentRow: View {
    let attachment: WinlinkMessage.Attachment

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
            Text("\(attachment.name) · \(attachment.size) Byte")
            Spacer()
            Button("SPEICHERN") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.name
                if panel.runModal() == .OK, let url = panel.url { try? Data(attachment.data).write(to: url) }
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundColor(RadioTheme.vfdAmber)
        .padding(4)
        .background(RadioTheme.bgPanel)
        .cornerRadius(4)
    }
}

// MARK: - Abstimmanzeige und Einstellungen

struct PacketTuningPanel: View {
    @ObservedObject var controller: PacketController
    @ObservedObject var settings: PacketSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PACKET")
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
            .help("DCD: ein Rahmen wird gerade gelesen (Flag-Folge erkannt)")
            PacketLevelBar(level: controller.level)
                .frame(height: 8)
                .help("Signalpegel der Töne 1200 und 2200 Hz (Hüllkurve)")
            HStack {
                readout("TÖNE", "\(Int(settings.centerHz - 500)) / \(Int(settings.centerHz + 500)) Hz")
                Spacer()
                readout("FREQUENZ", settings.channel.frequencyHz.map { String(format: "%.4f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") + " MHz" } ?? "frei")
            }
            HStack {
                readout("RAHMEN", "\(controller.frameCount)")
                Spacer()
                readout("STATIONEN", "\(controller.stations.count)")
            }
            HStack {
                readout("VERBINDUNGEN", "\(controller.openSessions) / \(controller.sessions.count)")
                Spacer()
                readout("NACHRICHTEN", "\(controller.mail.count)")
            }
            if let last = controller.lastFrameDate {
                readout("LETZTER", packetTime(last) + " UTC")
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

private struct PacketLevelBar: View {
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

struct PacketSettingsPanel: View {
    @ObservedObject var settings: PacketSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2 m")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            channelGrid(PacketChannel.allCases.filter { !$0.isUHF && $0 != .free })
            Text("70 cm")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            channelGrid(PacketChannel.allCases.filter { $0.isUHF } + [.free])
            HStack(spacing: 6) {
                Button("KORREKTUR") { settings.repairBits.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.repairBits))
                    .help("Ein fehlerhaftes Bit umkehren, wenn die Prüfsumme sonst stimmt (nur ungesicherte Rahmen). Solche Rahmen stehen im Monitor (~), nie in Stationen oder Verbindungen")
                Button(settings.emphasis == .auto ? "AUDIO AUTO" : settings.emphasis == .on ? "DE-EMPH." : "FLACH") {
                    let all = AFSKReceiver.Emphasis.allCases
                    settings.emphasis = all[(all.firstIndex(of: settings.emphasis)! + 1) % all.count]
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.emphasis != .auto))
                .help("Audioart: AUTO liest flaches Diskriminator-Audio und de-emphasiertes Lautsprecher-Audio gleichzeitig. Klicken zum Umschalten")
                Button("NACHRICHTEN") { settings.decodeMail.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.decodeMail))
                    .help("Winlink-Nachrichten entpacken und lesen. Aus: nur Rahmen, Verbindungen und Weiterleitungs-Vorschläge")
            }
            Text(verbatim: "FM schmal (Diskriminator-Audio, ohne Rauschsperre), 1200 Bd. 9600 Bd (G3RUH) wird nicht gelesen. Klick in den Wasserfall setzt die Abweichung der Töne (\(Int(settings.offsetHz.rounded())) Hz).")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private func channelGrid(_ channels: [PacketChannel]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(channels) { c in
                Button { settings.channel = c } label: {
                    Text(verbatim: c == .free ? "frei" : c.name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.channel == c))
                .help(c.note + (c.frequencyHz == nil ? "" : " (nur mit QSY AUTO wird das Funkgerät in FM abgestimmt)"))
            }
        }
    }
}
