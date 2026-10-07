// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private let tetraHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)
private let tetraRowFont = Font.system(size: 11, weight: .medium, design: .monospaced)

// MARK: - Hauptbereich

struct TETRAMainPanel: View {
    @ObservedObject var controller: TETRAController
    @ObservedObject var settings: TETRASettingsStore
    @State private var tab = Tab.fromEnvironment()

    enum Tab: String, CaseIterable, Identifiable {
        case calls = "GESPRÄCHE", network = "NETZ", subscribers = "TEILNEHMER", messages = "MELDUNGEN"
        var id: String { rawValue }
        /// Entwicklungshilfe: DIGIDEC_TETRA_TAB=network|subscribers|messages öffnet die Seite (für Schnappschüsse)
        static func fromEnvironment() -> Tab {
            switch ProcessInfo.processInfo.environment["DIGIDEC_TETRA_TAB"] {
            case "network": return .network
            case "subscribers": return .subscribers
            case "messages": return .messages
            default: return .calls
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
                .frame(width: 400)
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button { controller.logEnabled.toggle() } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Rufe, Sprecher, Kurznachrichten und Netzdaten in die Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()]) } label: { Image(systemName: "folder") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Log-Datei im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Listen leeren")
            }
            Group {
                switch tab {
                case .calls:
                    VStack(spacing: 6) {
                        TETRANowCard(controller: controller)
                        TETRACallTable(controller: controller)
                            .background(RadioTheme.bgDeep)
                            .cornerRadius(6)
                    }
                case .network: TETRANetworkView(controller: controller).background(RadioTheme.bgDeep).cornerRadius(6)
                case .subscribers: TETRASubscriberTable(controller: controller).background(RadioTheme.bgDeep).cornerRadius(6)
                case .messages: TETRAEventTable(controller: controller).background(RadioTheme.bgDeep).cornerRadius(6)
                }
            }
        }
    }

    private var summary: String {
        let s = controller.snapshot
        let live = s.calls.filter(\.isLive).count
        if s.calls.isEmpty, s.network == nil { return statusText }
        return "\(s.calls.count) Gespräche\(live > 0 ? " (\(live) laufen)" : "") · \(s.subscribers.count) Teilnehmer"
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Empfänger aus"
        case .running(let d): return "Warten auf TETRA (\(d))"
        case .error(let m): return m
        }
    }
}

// MARK: - Aktuelles Gespräch

struct TETRANowCard: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        let s = controller.snapshot
        let live = s.calls.last(where: { $0.isLive && $0.usageMarker == s.audioMarker }) ?? s.calls.last(where: \.isLive)
        VStack(alignment: .leading, spacing: 4) {
            if let c = live {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(c.encrypted || c.suspect ? RadioTheme.vfdAmber : RadioTheme.ledRed).frame(width: 9, height: 9)
                    Text(c.isGroup ? "GRUPPE" : "RUF")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Text(controller.label(c.target))
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                    Text("SPRECHER")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Text(controller.label(c.speaker ?? c.caller))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Spacer()
                    Text(String(format: "%.1f s", c.seconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
                Text(statusLine(c))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(c.encrypted || c.suspect ? RadioTheme.vfdAmber : RadioTheme.textMuted)
            } else {
                Text("kein Gespräch")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                Text(idleLine)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }

    private func statusLine(_ c: TETRACall) -> String {
        var parts: [String] = []
        if let f = c.carrierHz { parts.append("\(TETRAChannelPlan.title(f)) MHz") }
        if let t = c.timeslot { parts.append("Zeitschlitz \(t)") }
        parts.append("Marke \(c.usageMarker)")
        if c.encrypted { parts.append("verschlüsselt: kein Ton") }
        else if c.suspect { parts.append("fast nur fehlerhafte Rahmen (verschlüsselt oder gestört): kein Ton") }
        else if controller.output.tetraAvailable == false { parts.append("kein Sprachdecoder: nur Rufdaten") }
        else if !controller.output.playAudio { parts.append("Ton aus") }
        else if controller.snapshot.audioMarker != c.usageMarker { parts.append("läuft parallel zu einem anderen Gespräch") }
        return parts.joined(separator: " · ")
    }

    private var idleLine: String {
        let s = controller.snapshot
        if let n = s.network { return "Netz \(n.mcc)/\(n.mnc) · \(TETRAChannelPlan.title(n.downlinkHz)) MHz" }
        switch controller.status {
        case .error(let m): return m
        case .idle: return "Empfänger aus"
        case .running: return s.channels.contains(where: \.locked) ? "synchron, noch keine Systeminformation" : "suche den Steuerkanal"
        }
    }
}

// MARK: - Gespräche

struct TETRACallTable: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("UTC").frame(width: 56, alignment: .leading)
                    Text("AN").frame(maxWidth: .infinity, alignment: .leading)
                    Text("RUFER").frame(width: 130, alignment: .leading)
                    Text("SPRECHER").frame(width: 150, alignment: .leading)
                    Text("TS").frame(width: 26, alignment: .leading)
                    Text("MARKE").frame(width: 44, alignment: .leading)
                    Text("DAUER").frame(width: 48, alignment: .trailing)
                    Text("FEHLER").frame(width: 54, alignment: .trailing)
                    Text("STATUS").frame(width: 90, alignment: .leading)
                    Text(" ").frame(width: 24)
                }
                .font(tetraHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                ForEach(controller.snapshot.calls.reversed()) { c in row(c) }
                if controller.snapshot.calls.isEmpty {
                    Text("Noch kein Gespräch gehört")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            .padding(6)
        }
    }

    private func row(_ c: TETRACall) -> some View {
        let color: Color = c.isLive ? RadioTheme.ledRed : c.encrypted || c.suspect ? RadioTheme.vfdAmber : RadioTheme.vfdGreen
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TETRAController.timeFormatter.string(from: c.start)).frame(width: 56, alignment: .leading)
            Text(controller.label(c.target) + (c.isGroup ? "" : "  (Einzelruf)")).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(controller.label(c.caller)).frame(width: 130, alignment: .leading).lineLimit(1)
            Text(c.speakers.isEmpty ? controller.label(c.speaker) : c.speakers.map { controller.label($0) }.joined(separator: ", ")).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(c.timeslot.map(String.init) ?? "–").frame(width: 26, alignment: .leading)
            Text("\(c.usageMarker)").frame(width: 44, alignment: .leading)
            Text(String(format: "%.1f s", c.seconds)).frame(width: 48, alignment: .trailing)
            Text(c.frames > 0 ? "\(c.badFrames)/\(c.frames)" : "–").frame(width: 54, alignment: .trailing)
            Text(statusText(c)).frame(width: 90, alignment: .leading).lineLimit(1)
            Button { controller.replay(c) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain)
                .disabled(c.audio.isEmpty || !controller.output.tetraAvailable || c.encrypted || c.suspect)
                .help("Gespräch noch einmal abspielen")
                .frame(width: 24)
        }
        .font(tetraRowFont)
        .foregroundColor(color)
        .help(help(c))
    }

    private func statusText(_ c: TETRACall) -> String {
        if c.encrypted { return "verschlüsselt" }
        if c.suspect { return "gestört?" }
        return c.isLive ? "läuft" : c.released ? "beendet" : "ausgelaufen"
    }

    private func help(_ c: TETRACall) -> String {
        var s = "\(c.isGroup ? "Gruppenruf" : "Einzelruf") an \(controller.label(c.target))"
        if let id = c.callID { s += " · Ruf \(id)" }
        if let f = c.carrierHz { s += " · \(TETRAChannelPlan.title(f)) MHz" }
        s += " · \(c.frames) Sprachrahmen (\(c.badFrames) fehlerhaft, \(c.missingFrames) durch Signalisierung ersetzt)"
        return s
    }
}

// MARK: - Netz

struct TETRANetworkView: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        let s = controller.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let n = s.network {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ZELLE").font(tetraHeaderFont).foregroundColor(RadioTheme.textDim)
                        kv("Land (MCC) / Netz (MNC)", "\(n.mcc) / \(n.mnc)")
                        if let sync = s.channels.first(where: { $0.sync != nil })?.sync { kv("Farbcode", "\(sync.colourCode)") }
                        kv("Standortbereich", "\(n.locationArea)")
                        kv("Hauptträger", "\(n.mainCarrier) · Band \(n.band) · \(TETRAChannelPlan.title(n.downlinkHz)) MHz")
                        if let ul = n.uplinkHz { kv("Aufwärtsstrecke", "\(TETRAChannelPlan.title(ul)) MHz") }
                        kv("Dienste", services(n))
                        if let cck = n.cckID { kv("Schlüsselkennung (CCK)", "\(cck)") }
                        if let hf = n.hyperframe { kv("Hyperframe", "\(hf)") }
                    }
                } else {
                    Text("Noch keine Systeminformation (BNCH) empfangen")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
                Text("TRÄGER").font(tetraHeaderFont).foregroundColor(RadioTheme.textDim)
                HStack(spacing: 8) {
                    Text("MHz").frame(width: 78, alignment: .leading)
                    Text("SYNC").frame(width: 66, alignment: .leading)
                    Text("PEGEL").frame(width: 56, alignment: .trailing)
                    Text("VERSATZ").frame(width: 66, alignment: .trailing)
                    Text("ZEIT").frame(width: 70, alignment: .leading)
                    Text("SYNC-B").frame(width: 50, alignment: .trailing)
                    Text("NORMAL").frame(width: 56, alignment: .trailing)
                    Text("CRC OK/FEHL").frame(width: 90, alignment: .trailing)
                    Text("VERKEHR").frame(width: 58, alignment: .trailing)
                }
                .font(tetraHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                ForEach(s.channels, id: \.frequency) { c in
                    HStack(spacing: 8) {
                        Text(TETRAChannelPlan.title(c.frequency)).frame(width: 78, alignment: .leading)
                        Text(c.locked ? (c.inverted ? "ja (I/Q)" : "ja") : "nein").frame(width: 66, alignment: .leading)
                        Text(String(format: "%.0f dB", c.powerDB)).frame(width: 56, alignment: .trailing)
                        Text(String(format: "%+.0f Hz", c.offsetHz)).frame(width: 66, alignment: .trailing)
                        Text(c.tetraTime).frame(width: 70, alignment: .leading)
                        Text("\(c.syncBursts)").frame(width: 50, alignment: .trailing)
                        Text("\(c.normalBursts)").frame(width: 56, alignment: .trailing)
                        Text("\(c.crcOK)/\(c.crcBad)").frame(width: 90, alignment: .trailing)
                        Text("\(c.trafficBlocks)").frame(width: 58, alignment: .trailing)
                    }
                    .font(tetraRowFont)
                    .foregroundColor(c.locked ? RadioTheme.vfdGreen : RadioTheme.textDim)
                }
                if s.channels.isEmpty {
                    Text("Kein Träger eingerichtet")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).frame(width: 190, alignment: .leading).foregroundColor(RadioTheme.textDim)
            Text(v).foregroundColor(RadioTheme.vfdCyan)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private func services(_ n: TETRANetworkInfo) -> String {
        var l: [String] = []
        if n.voiceService { l.append("Sprache") }
        if n.circuitData { l.append("Leitungsdaten") }
        if n.sndcp { l.append("Paketdaten") }
        if n.registrationMandatory { l.append("Anmeldung Pflicht") }
        if n.migration { l.append("Migration") }
        if n.airEncryption { l.append("Luftverschlüsselung") }
        return l.isEmpty ? "–" : l.joined(separator: ", ")
    }
}

// MARK: - Teilnehmer

struct TETRASubscriberTable: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("KENNUNG").frame(width: 180, alignment: .leading)
                    Text("ZULETZT").frame(width: 110, alignment: .leading)
                    Text("MELDUNGEN").frame(width: 80, alignment: .trailing)
                    Text("RUFE").frame(width: 50, alignment: .trailing)
                    Text("VOR").frame(width: 56, alignment: .trailing)
                    Text(" ").frame(maxWidth: .infinity)
                }
                .font(tetraHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.snapshot.subscribers.sorted { $0.lastSeen > $1.lastSeen }) { s in
                            let age = ctx.date.timeIntervalSince(s.lastSeen)
                            HStack(spacing: 8) {
                                Text(controller.label(s.ssi)).frame(width: 180, alignment: .leading).lineLimit(1)
                                Text(s.lastRole.isEmpty ? "–" : s.lastRole).frame(width: 110, alignment: .leading)
                                Text("\(s.count)").frame(width: 80, alignment: .trailing)
                                Text("\(s.calls)").frame(width: 50, alignment: .trailing)
                                Text(age < 60 ? "\(Int(age)) s" : age < 3600 ? "\(Int(age / 60)) min" : "\(Int(age / 3600)) h").frame(width: 56, alignment: .trailing)
                                Text(" ").frame(maxWidth: .infinity)
                            }
                            .font(tetraRowFont)
                            .foregroundColor(age < 60 ? RadioTheme.vfdGreen : RadioTheme.textDim)
                        }
                    }
                }
                if controller.snapshot.subscribers.isEmpty {
                    Text("Noch kein Teilnehmer gehört")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Meldungen

struct TETRAEventTable: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("UTC").frame(width: 56, alignment: .leading)
                    Text("TDMA").frame(width: 66, alignment: .leading)
                    Text("ART").frame(width: 70, alignment: .leading)
                    Text("INHALT").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(tetraHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                ForEach(controller.snapshot.events.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(TETRAController.timeFormatter.string(from: e.time)).frame(width: 56, alignment: .leading)
                        Text(e.tetraTime).frame(width: 66, alignment: .leading)
                        Text(e.kind).frame(width: 70, alignment: .leading)
                        Text(e.text).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                    }
                    .font(tetraRowFont)
                    .foregroundColor(color(e.kind))
                }
                if controller.snapshot.events.isEmpty {
                    Text("Noch keine Meldung")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            .padding(6)
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "SDS": return RadioTheme.vfdCyan
        case "RUF", "SPRECHER": return RadioTheme.vfdGreen
        case "VERSCHL.": return RadioTheme.vfdAmber
        case "NETZ", "INFO": return RadioTheme.textMuted
        default: return RadioTheme.textDim
        }
    }
}

// MARK: - Empfang (statt Wasserfall)

struct TETRAScopePanel: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SIGNALAKTIVITÄT")
                    .font(tetraHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ADSBRateChart(values: controller.activityHistory)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 14) {
                    stat("GESPRÄCHE", "\(controller.snapshot.calls.count)")
                    stat("TEILNEHMER", "\(controller.snapshot.subscribers.count)")
                    stat("TRÄGER", "\(controller.snapshot.channels.count)")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text("TRÄGER")
                    .font(tetraHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                TETRAChannelBars(channels: controller.snapshot.channels)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 330)
        }
        .padding(8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

/// Pegel der Träger als Balken (dB gegen Vollaussteuerung, −80 … −10 dB); grün = synchron
struct TETRAChannelBars: View {
    let channels: [TETRAEngine.ChannelStatus]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RadioTheme.bgDeep))
            guard !channels.isEmpty else {
                ctx.draw(Text("kein Empfang").font(.system(size: 9, design: .monospaced)).foregroundColor(RadioTheme.textMuted), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let labelHeight: CGFloat = 12
            let plotHeight = size.height - labelHeight
            let slot = size.width / CGFloat(channels.count)
            let lo = -80.0, hi = -10.0
            for (i, c) in channels.enumerated() {
                let x = slot * CGFloat(i)
                let level = max(0, min(1, (c.powerDB - lo) / (hi - lo)))
                let rect = CGRect(x: x + slot * 0.18, y: plotHeight * (1 - level), width: slot * 0.64, height: plotHeight * level)
                ctx.fill(Path(rect), with: .color(c.locked ? RadioTheme.vfdGreen.opacity(0.8) : RadioTheme.vfdCyan.opacity(0.6)))
                ctx.draw(Text(String(format: "%.2f", c.frequency / 1e6)).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textDim),
                         at: CGPoint(x: x + slot / 2, y: size.height - labelHeight / 2))
            }
        }
        .cornerRadius(4)
    }
}

// MARK: - Abstimmanzeige

struct TETRATuningPanel: View {
    @ObservedObject var controller: TETRAController
    @ObservedObject var settings: TETRASettingsStore

    var body: some View {
        let s = controller.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("TETRA")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(settings.carriers.first.map { "\(TETRAChannelPlan.title(TETRAChannelPlan.hz($0))) MHz" } ?? "Hauptträger fehlt")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Circle()
                    .fill(dotColor)
                    .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                led("SYNC", on: s.channels.contains(where: \.locked), color: RadioTheme.vfdGreen)
                led("INVERS", on: s.channels.contains(where: { $0.locked && $0.inverted }), color: RadioTheme.vfdAmber)
                led("TON", on: controller.output.tetraAvailable, color: RadioTheme.vfdCyan)
            }
            if let n = s.network {
                Text("Netz \(n.mcc)/\(n.mnc) · \(TETRAChannelPlan.title(n.downlinkHz)) MHz · Standortbereich \(n.locationArea)\(n.airEncryption ? " · Luftverschlüsselung" : "")")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                readout("GESPRÄCHE", "\(s.calls.count)")
                Spacer()
                readout("TEILNEHMER", "\(s.subscribers.count)")
            }
            HStack {
                readout("SYNC-BURSTS", "\(s.channels.reduce(0) { $0 + $1.syncBursts })")
                Spacer()
                readout("CRC FEHLER", "\(s.channels.reduce(0) { $0 + $1.crcBad })")
            }
            HStack {
                readout("ÜBERSTEUERT", String(format: "%.1f %%", s.clippedFraction * 100))
                    .foregroundColor(s.clippedFraction > 0.02 ? RadioTheme.ledRed : RadioTheme.vfdCyan)
                Spacer()
            }
            if s.clippedFraction > 0.02 {
                Text("Übersteuert: Verstärkung verringern.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledRed)
            }
            if s.droppedBlocks > 0 {
                Text("Rechner zu langsam: \(s.droppedBlocks) Datenblöcke verworfen. Weniger Träger einrichten.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }
            if case .running = controller.status, !controller.output.tetraAvailable {
                Text("Es ist kein Sprachdecoder für TETRA vorhanden: Digidec zeigt Netz, Rufe, Teilnehmer und Kurznachrichten, spielt aber keinen Ton ab.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dotColor: Color {
        switch controller.status {
        case .running: return RadioTheme.vfdGreen
        case .error: return RadioTheme.ledRed
        case .idle: return RadioTheme.bgPanel
        }
    }

    private var statusColor: Color {
        if case .error = controller.status { return RadioTheme.ledRed }
        return RadioTheme.textMuted
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Empfänger aus"
        case .running(let d): return "Empfang: \(d)"
        case .error(let m): return m
        }
    }

    private func led(_ name: String, on: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? color : RadioTheme.bgPanel)
                .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(on ? color : RadioTheme.textDim)
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(RadioTheme.vfdCyan)
    }
}

// MARK: - Einstellungen

struct TETRASettingsPanel: View {
    @ObservedObject var controller: TETRAController
    @ObservedObject var settings: TETRASettingsStore
    @State private var mainText = ""
    @State private var extraText = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("HAUPTTRÄGER")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextField("z. B. 426,700", text: $mainText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 100)
                    .onSubmit { commit() }
                Text("MHz")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help("Frequenz des Steuerkanals (Hauptträger, Abwärtsstrecke) des eigenen Netzes in MHz, Eingabe mit Return bestätigen")
            HStack(spacing: 6) {
                Text("WEITERE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextField("weitere Träger, MHz", text: $extraText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .onSubmit { commit() }
            }
            .help("Weitere Träger des Netzes (Verkehrskanäle), durch Leerzeichen getrennt. Nicht nötig, wenn „Träger automatisch zuschalten“ an ist.")
            HStack(spacing: 6) {
                Button("TRÄGER AUTOMATISCH") { settings.autoFollow.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.autoFollow))
                    .help("Träger zuschalten, auf die eine Kanalzuweisung verweist (innerhalb des Empfangsfensters von rund 1,7 MHz)")
                Button("ÜBERNEHMEN") { commit() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
            }
            HStack(spacing: 6) {
                Text("GRUPPEN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextField("alle (oder GSSI, durch Komma getrennt)", text: $settings.listenGroups)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
            }
            .help("Nur Gespräche dieser Gruppen (oder Teilnehmer) abspielen; leer = alle unverschlüsselten Gespräche")
            Text("NAMEN (KENNUNG=NAME)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            TextEditor(text: $settings.labels)
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 54)
                .cornerRadius(4)
                .help("Je Zeile eine Kennung und ihr Name, etwa „100601=Werkschutz“")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(ADSBSourceKind.allCases) { k in
                    Button { settings.source = k } label: { Text(k.title).lineLimit(1).minimumScaleFactor(0.5) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.source == k))
                        .help(k.detail)
                }
            }
            Text(settings.source == .file ? "Aufnahme: I/Q als WAV (8 oder 16 Bit, stereo, ab 48 kS/s) oder .cu8; die Abtastrate steht im WAV-Kopf oder im Dateinamen (…_2M.cu8). Ein Träger in der Mitte." : settings.source.detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            sourceControls
            HStack(spacing: 6) {
                Button(controller.status == .idle ? "START" : "STOPP") {
                    if case .running = controller.status { controller.stopSource() } else { controller.startSource() }
                }
                .buttonStyle(ModeButtonStyle(isSelected: { if case .running = controller.status { return true } else { return false } }()))
                .help("Empfänger starten oder anhalten (gibt das Gerät frei, z. B. für GQRX)")
            }
            Text("Nur für das eigene Netz: Digidec empfängt den Träger, den man einträgt, und gibt unverschlüsselte Gespräche wieder. Verschlüsselte Gespräche bleiben stumm; es wird nicht versucht, Verschlüsselung zu umgehen. Vor dem Mithören im Betrieb die Erlaubnis des Netzbetreibers und der Geschäftsleitung einholen.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            mainText = settings.carriers.first.map { String(format: "%.4f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
            extraText = settings.carriers.dropFirst().map { String(format: "%.4f", $0).replacingOccurrences(of: ".", with: ",") }.joined(separator: " ")
        }
    }

    private func commit() {
        let main = TETRASettingsStore.parseFrequencies(mainText).first
        let extra = TETRASettingsStore.parseFrequencies(extraText)
        var list: [Double] = []
        if let m = main { list.append(m) }
        list += extra
        if list != settings.carriers { settings.carriers = list }
    }

    @ViewBuilder
    private var sourceControls: some View {
        switch settings.source {
        case .hackrf:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button("AMP 14 dB") { settings.hackrfAmp.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfAmp))
                        .help("Eingebauter Vorverstärker (14 dB)")
                    Button("BIAS-T") { settings.hackrfBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.hackrfBias))
                        .help("Speisespannung (3,3 V) am Antennenanschluss für einen Antennenverstärker")
                }
                stepper("LNA", "\(settings.hackrfLNA) dB", minus: { settings.hackrfLNA = max(0, settings.hackrfLNA - 8) }, plus: { settings.hackrfLNA = min(40, settings.hackrfLNA + 8) },
                        help: "Verstärkung im Hochfrequenzteil, 0 bis 40 dB in 8-dB-Stufen")
                stepper("VGA", "\(settings.hackrfVGA) dB", minus: { settings.hackrfVGA = max(0, settings.hackrfVGA - 2) }, plus: { settings.hackrfVGA = min(62, settings.hackrfVGA + 2) },
                        help: "Verstärkung im Basisband, 0 bis 62 dB in 2-dB-Stufen")
            }
        case .rtlsdr:
            VStack(alignment: .leading, spacing: 6) {
                stepper("VERSTÄRKUNG", settings.rtlGain > 0 ? String(format: "%.1f dB", settings.rtlGain) : "AGC",
                        minus: { settings.rtlGain = settings.rtlGain <= 0 ? 0 : max(0, settings.rtlGain - 4) },
                        plus: { settings.rtlGain = min(49.6, settings.rtlGain + 4) },
                        help: "Tunerverstärkung; 0 = automatisch")
                HStack(spacing: 6) {
                    Button("BIAS-T") { settings.rtlBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.rtlBias))
                        .help("Speisespannung am Antennenanschluss (nur bei RTL-SDR V3 und ähnlichen)")
                    stepper("PPM", "\(settings.rtlPPM)", minus: { settings.rtlPPM -= 1 }, plus: { settings.rtlPPM += 1 }, help: "Frequenzkorrektur des Quarzes (Digidec gleicht Reste bis etwa ±8 kHz selbst aus)")
                }
            }
        case .sdrplay:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("TUNER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Button("A") { settings.sdrplayTuner = 0 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 0))
                    Button("B") { settings.sdrplayTuner = 1 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 1))
                    Button("AGC") { settings.sdrplayAGC.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayAGC))
                        .help("Automatische Verstärkungsregelung (ZF)")
                    Button("BIAS-T") { settings.sdrplayBias.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayBias))
                }
                stepper("LNA-STUFE", "\(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) },
                        plus: { settings.sdrplayLNAState = min(9, settings.sdrplayLNAState + 1) }, help: "Stufe des rauscharmen Vorverstärkers (0 = höchste Verstärkung)")
                stepper("ZF-MINDERUNG", "\(settings.sdrplayIFGain) dB", minus: { settings.sdrplayIFGain = max(20, settings.sdrplayIFGain - 2) },
                        plus: { settings.sdrplayIFGain = min(59, settings.sdrplayIFGain + 2) }, help: "Verstärkungsminderung im Zwischenfrequenzteil (nur ohne AGC)")
                stepper("PPM", "\(settings.sdrplayPPM)", minus: { settings.sdrplayPPM -= 1 }, plus: { settings.sdrplayPPM += 1 }, help: "Frequenzkorrektur des Quarzes")
                if !SDRplayAPISource.isInstalled() {
                    Text("Die SDRplay-API fehlt: „Hardware API MacOS“ von sdrplay.com/api installieren.")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
        case .sdrconnect:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Rechner", text: $settings.sdrconnectHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                    TextField("Port", value: $settings.sdrconnectPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 60)
                }
                stepper("LNA-STUFE", "\(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) },
                        plus: { settings.sdrplayLNAState = min(27, settings.sdrplayLNAState + 1) }, help: "Verstärkungsstufe des SDRplay")
            }
        case .file:
            HStack(spacing: 6) {
                Button("ÖFFNEN …") {
                    let panel = NSOpenPanel()
                    panel.message = "I/Q-Aufnahme: WAV (8 oder 16 Bit, stereo, ab 48 kS/s) oder .cu8"
                    if panel.runModal() == .OK, let url = panel.url {
                        controller.fileOverride = url
                        controller.startSource()
                    }
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                Text(controller.fileOverride?.lastPathComponent ?? "keine Aufnahme")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .lineLimit(1)
            }
        }
    }

    private func stepper(_ label: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Button("−", action: minus).buttonStyle(ModeButtonStyle(isSelected: false))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(minWidth: 52)
            Button("+", action: plus).buttonStyle(ModeButtonStyle(isSelected: false))
        }
        .help(help)
    }
}

/// Statt der Audio-Eingangskarte: TETRA liest I/Q-Daten direkt vom Gerät
struct TETRAReceiverCard: View {
    @ObservedObject var controller: TETRAController

    var body: some View {
        Text("TETRA braucht keinen Audioeingang: Digidec liest die I/Q-Daten (2 MS/s) selbst vom Gerät und empfängt den Hauptträger des eigenen Netzes sowie die Träger, auf die Rufe verweisen. Solange das Modul offen ist, gehört das Gerät Digidec; beim Wechsel in ein anderes Modul wird es freigegeben. Der Ton läuft über den Standard-Ausgang des Rechners.")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(RadioTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
