// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private let vdlHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)
private let vdlRowFont = Font.system(size: 11, weight: .medium, design: .monospaced)

// MARK: - Hauptbereich

struct VDL2MainPanel: View {
    @ObservedObject var controller: VDL2Controller
    @ObservedObject var settings: VDL2SettingsStore
    @State private var tab = Tab.fromEnvironment()

    enum Tab: String, CaseIterable, Identifiable {
        case aircraft = "FLUGZEUGE", messages = "NACHRICHTEN", ground = "BODEN"
        var id: String { rawValue }
        /// Entwicklungshilfe: DIGIDEC_VDL2_TAB=messages|ground öffnet die Seite (für Schnappschüsse)
        static func fromEnvironment() -> Tab {
            switch ProcessInfo.processInfo.environment["DIGIDEC_VDL2_TAB"] {
            case "messages": return .messages
            case "ground": return .ground
            default: return .aircraft
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
                .frame(width: 330)
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button { controller.logEnabled.toggle() } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Jeden Rahmen mit Zeit, Kanal, Adressen und Inhalt in die Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()]) } label: { Image(systemName: "folder") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Log-Datei im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Listen leeren")
            }
            Group {
                switch tab {
                case .aircraft: VDL2AircraftTable(controller: controller)
                case .messages: VDL2MessageTable(entries: controller.recent)
                case .ground: VDL2GroundTable(controller: controller)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        let n = controller.aircraft.count
        if controller.totalFrames == 0 { return statusText }
        return "\(n) Flugzeug\(n == 1 ? "" : "e") · \(controller.totalFrames) Rahmen · \(controller.acarsCount) ACARS"
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Empfänger aus"
        case .running(let d): return "Warten auf VDL2 (\(d), \(settings.channels.count) Kanäle)"
        case .error(let m): return m
        }
    }
}

struct VDL2AircraftTable: View {
    @ObservedObject var controller: VDL2Controller

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("ICAO").frame(width: 56, alignment: .leading)
                    Text("KENNZ.").frame(width: 72, alignment: .leading)
                    Text("FLUG").frame(width: 66, alignment: .leading)
                    Text("BODEN").frame(width: 56, alignment: .leading)
                    Text("KANAL").frame(width: 56, alignment: .leading)
                    Text("ADS-B").frame(width: 104, alignment: .leading)
                    Text("LETZTE MELDUNG").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PEGEL").frame(width: 52, alignment: .trailing)
                    Text("RAHMEN").frame(width: 50, alignment: .trailing)
                    Text("VOR").frame(width: 48, alignment: .trailing)
                }
                .font(vdlHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.aircraft) { a in row(a, now: ctx.date) }
                    }
                }
            }
            .padding(6)
        }
    }

    private func row(_ a: VDL2Aircraft, now: Date) -> some View {
        let age = now.timeIntervalSince(a.lastSeen)
        let color: Color = age < 30 ? RadioTheme.ledRed : age < 300 ? RadioTheme.vfdGreen : RadioTheme.textDim
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(a.address.text).frame(width: 56, alignment: .leading)
            Text(a.registration ?? "–").frame(width: 72, alignment: .leading).lineLimit(1)
            Text(a.flight ?? "–").frame(width: 66, alignment: .leading).lineLimit(1)
            Text(a.groundStation ?? "–").frame(width: 56, alignment: .leading)
            Text(VDL2Channels.title(a.frequency)).frame(width: 56, alignment: .leading)
            Text(DigidecState.shared.aircraftSummary(for: a) ?? "").frame(width: 104, alignment: .leading).lineLimit(1)
                .foregroundColor(RadioTheme.vfdAmber)
            Text(a.lastText.isEmpty ? " " : a.lastText).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            Text(String(format: "%.0f dB", a.levelDB)).frame(width: 52, alignment: .trailing)
            Text("\(a.frames)").frame(width: 50, alignment: .trailing)
            Text(ageText(age)).frame(width: 48, alignment: .trailing)
        }
        .font(vdlRowFont)
        .foregroundColor(color)
        .help("\(a.address.text)\(a.registration.map { " · \($0)" } ?? "") · \(a.acarsMessages) ACARS-Meldungen · \(a.onGround.map { $0 ? "am Boden" : "in der Luft" } ?? "Lage unbekannt") · zuerst \(VDL2Controller.time(a.firstSeen))")
    }

    private func ageText(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s)) s" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        return "\(Int(s / 3600)) h"
    }
}

struct VDL2MessageTable: View {
    let entries: [VDL2LogEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("UTC").frame(width: 56, alignment: .leading)
                    Text("KANAL").frame(width: 52, alignment: .leading)
                    Text("RICHTUNG").frame(width: 84, alignment: .leading)
                    Text("VON").frame(width: 50, alignment: .leading)
                    Text("AN").frame(width: 50, alignment: .leading)
                    Text("ART").frame(width: 34, alignment: .leading)
                    Text("INHALT").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(vdlHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                ForEach(entries.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(VDL2Controller.timeFormatter.string(from: e.time)).frame(width: 56, alignment: .leading)
                        Text(VDL2Channels.title(e.frame.frequency)).frame(width: 52, alignment: .leading)
                        Text(VDL2Format.direction(e.frame)).frame(width: 84, alignment: .leading)
                        Text(e.frame.source.text).frame(width: 50, alignment: .leading)
                        Text(e.frame.destination.text).frame(width: 50, alignment: .leading)
                        Text(e.frame.command + (e.frame.poll ? "*" : "")).frame(width: 34, alignment: .leading)
                        Text(e.summary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                    }
                    .font(vdlRowFont)
                    .foregroundColor(e.frame.acars != nil ? RadioTheme.vfdGreen : e.frame.kind == .information ? RadioTheme.vfdCyan : RadioTheme.textDim)
                    .help(help(e.frame))
                }
            }
            .padding(6)
        }
    }

    private func help(_ f: AVLCFrame) -> String {
        var s = "\(f.source.text) (\(f.source.typeText)) → \(f.destination.text) (\(f.destination.typeText)) · \(f.length) Byte · Pegel \(String(format: "%.1f", f.levelDB)) dB, Rauschen \(String(format: "%.1f", f.noiseDB)) dB, Takt \(String(format: "%+.1f", f.ppm)) ppm"
        if f.fecCorrections > 0 { s += " · \(f.fecCorrections) Byte durch Reed-Solomon korrigiert" }
        if let a = f.acars { s += "\n\(a.text)" } else if !f.payload.isEmpty { s += "\n" + VDL2Format.printable(f.payload, limit: 400) }
        return s
    }
}

struct VDL2GroundTable: View {
    @ObservedObject var controller: VDL2Controller

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("ADRESSE").frame(width: 70, alignment: .leading)
                    Text("KANÄLE").frame(maxWidth: .infinity, alignment: .leading)
                    Text("RAHMEN").frame(width: 60, alignment: .trailing)
                    Text("VOR").frame(width: 48, alignment: .trailing)
                }
                .font(vdlHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.groundStations) { g in
                            let age = ctx.date.timeIntervalSince(g.lastSeen)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(g.address.text).frame(width: 70, alignment: .leading)
                                Text(g.frequencies.sorted().map { VDL2Channels.title($0) }.joined(separator: "  ")).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(g.frames)").frame(width: 60, alignment: .trailing)
                                Text(age < 60 ? "\(Int(age)) s" : "\(Int(age / 60)) min").frame(width: 48, alignment: .trailing)
                            }
                            .font(vdlRowFont)
                            .foregroundColor(age < 60 ? RadioTheme.vfdGreen : RadioTheme.textDim)
                            .help("Bodenstation \(g.address.text) (\(g.address.typeText))")
                        }
                    }
                }
                if controller.groundStations.isEmpty {
                    Text("Noch keine Bodenstation gehört")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Empfang (statt Wasserfall)

struct VDL2ScopePanel: View {
    @ObservedObject var controller: VDL2Controller

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SIGNALAKTIVITÄT")
                    .font(vdlHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ADSBRateChart(values: controller.activityHistory)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 14) {
                    stat("RAHMEN", "\(controller.totalFrames)")
                    stat("ACARS", "\(controller.acarsCount)")
                    stat("FLUGZEUGE", "\(controller.aircraft.count)")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text("KANÄLE")
                    .font(vdlHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                VDL2ChannelBars(channels: controller.stats.channels)
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

/// Pegel der Kanäle als Balken (dB gegen Vollaussteuerung, −80 … −20 dB)
struct VDL2ChannelBars: View {
    let channels: [VDL2Engine.ChannelInfo]

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
            let lo = -80.0, hi = -20.0
            for (i, c) in channels.enumerated() {
                let x = slot * CGFloat(i)
                let level = max(0, min(1, (c.powerDB - lo) / (hi - lo)))
                let noise = max(0, min(1, (c.noiseDB - lo) / (hi - lo)))
                let rect = CGRect(x: x + slot * 0.18, y: plotHeight * (1 - level), width: slot * 0.64, height: plotHeight * level)
                ctx.fill(Path(rect), with: .color(c.statistics.frames > 0 ? RadioTheme.vfdGreen.opacity(0.8) : RadioTheme.vfdCyan.opacity(0.6)))
                var n = Path()
                n.move(to: CGPoint(x: x + slot * 0.1, y: plotHeight * (1 - noise)))
                n.addLine(to: CGPoint(x: x + slot * 0.9, y: plotHeight * (1 - noise)))
                ctx.stroke(n, with: .color(RadioTheme.vfdAmber), lineWidth: 1)
                let label = String(format: "%.3f", c.frequency / 1e6).replacingOccurrences(of: "136.", with: "")
                ctx.draw(Text(label).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textDim),
                         at: CGPoint(x: x + slot / 2, y: size.height - labelHeight / 2))
                if c.statistics.frames > 0 {
                    ctx.draw(Text("\(c.statistics.frames)").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.bgDeep),
                             at: CGPoint(x: x + slot / 2, y: max(8, plotHeight * (1 - level) + 7)))
                }
            }
        }
        .cornerRadius(4)
    }
}

// MARK: - Abstimmanzeige

struct VDL2TuningPanel: View {
    @ObservedObject var controller: VDL2Controller
    @ObservedObject var settings: VDL2SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("VDL MODE 2")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("\(VDL2Channels.title(settings.centerFrequency)) MHz · \(controller.stats.sampleRate > 0 ? String(format: "%.1f MS/s", Double(controller.stats.sampleRate) / 1e6) : "2 MS/s")")
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
            HStack {
                readout("FLUGZEUGE", "\(controller.aircraft.count)")
                Spacer()
                readout("RAHMEN", "\(controller.totalFrames)")
            }
            HStack {
                readout("SYNC", "\(sum(\.syncs))")
                Spacer()
                readout("BURSTS", "\(sum(\.bursts))")
            }
            HStack {
                readout("KOPF FEHLER", "\(sum(\.headerErrors))")
                Spacer()
                readout("RS FEHLER", "\(sum(\.fecErrors))")
            }
            HStack {
                readout("FCS FEHLER", "\(sum(\.badFCS))")
                Spacer()
                readout("ÜBERSTEUERT", String(format: "%.1f %%", controller.stats.clippedFraction * 100))
                    .foregroundColor(controller.stats.clippedFraction > 0.02 ? RadioTheme.ledRed : RadioTheme.vfdCyan)
            }
            if controller.stats.clippedFraction > 0.02 {
                Text("Übersteuert: Verstärkung verringern.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledRed)
            }
            if controller.stats.droppedBlocks > 0 {
                Text("Rechner zu langsam: \(controller.stats.droppedBlocks) Datenblöcke verworfen. Weniger Kanäle wählen.")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }
        }
    }

    private func sum(_ key: KeyPath<VDL2Statistics, Int>) -> Int { controller.stats.channels.reduce(0) { $0 + $1.statistics[keyPath: key] } }

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

struct VDL2SettingsPanel: View {
    @ObservedObject var controller: VDL2Controller
    @ObservedObject var settings: VDL2SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("KANÄLE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Button("EUROPA") { settings.channels = VDL2Channels.europe }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.channels.sorted() == VDL2Channels.europe))
                    .help("136,725 · 136,775 · 136,825 · 136,875 · 136,925 · 136,975 MHz")
                Button("ALLE") { settings.channels = VDL2Channels.all }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.channels.count == VDL2Channels.all.count))
                    .help("Alle üblichen Kanäle (mehr Rechenlast)")
                Button("CSC") { settings.channels = [VDL2.commonSignallingChannel / 1e6] }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.channels == [136.975]))
                    .help("Nur der gemeinsame Signalisierungskanal 136,975 MHz")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(VDL2Channels.all, id: \.self) { f in
                    Button { settings.toggle(f) } label: { Text(VDL2Channels.title(f * 1e6)).lineLimit(1).minimumScaleFactor(0.6) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.channels.contains(f)))
                        .help("Kanal \(VDL2Channels.title(f * 1e6)) MHz überwachen")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(ADSBSourceKind.allCases) { k in
                    Button { settings.source = k } label: { Text(k.title).lineLimit(1).minimumScaleFactor(0.5) }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.source == k))
                        .help(k.detail)
                }
            }
            Text(settings.source == .file ? "Aufnahme: I/Q als WAV (8 oder 16 Bit, stereo) oder .cu8. Die Abtastrate steht im Dateinamen (…_1050kHz) oder im Kopf; die Aufnahme enthält einen Kanal in der Mitte (wie bei dumpvdl2)." : settings.source.detail)
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
            HStack(spacing: 6) {
                Text("ENTFERNEN NACH (MIN)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach([10, 30, 120, 0], id: \.self) { m in
                    Button(m == 0 ? "nie" : "\(m)") { settings.expireMinutes = m }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.expireMinutes == m))
                        .help("Flugzeuge aus der Liste nehmen, die so lange nichts gesendet haben")
                }
            }
        }
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
                        help: "Tunerverstärkung; 0 = automatisch. Für VDL2 sind 30 bis 45 dB üblich.")
                HStack(spacing: 6) {
                    Button("BIAS-T") { settings.rtlBias.toggle() }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.rtlBias))
                        .help("Speisespannung am Antennenanschluss (nur bei RTL-SDR V3 und ähnlichen)")
                    stepper("PPM", "\(settings.rtlPPM)", minus: { settings.rtlPPM -= 1 }, plus: { settings.rtlPPM += 1 }, help: "Frequenzkorrektur des Quarzes")
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
                    panel.message = "I/Q-Aufnahme: WAV (8 oder 16 Bit, stereo) oder .cu8; die Abtastrate steht im Dateinamen (…_1050kHz.wav) oder im WAV-Kopf"
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

/// Statt der Audio-Eingangskarte: VDL2 liest I/Q-Daten direkt vom Funkgerät
struct VDL2ReceiverCard: View {
    @ObservedObject var controller: VDL2Controller

    var body: some View {
        Text("VDL Mode 2 braucht keinen Audioeingang: Digidec liest die I/Q-Daten (2 MS/s) selbst vom Gerät und demoduliert alle gewählten Kanäle zugleich. Solange das Modul offen ist, gehört das Gerät Digidec; beim Wechsel in ein anderes Modul wird es freigegeben.")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(RadioTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
