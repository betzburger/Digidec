// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit
import VoiceCore

// MARK: - D-Star: laufende Aussendung und Verlauf

struct DStarMainPanel: View {
    @ObservedObject var controller: DStarController
    @ObservedObject var settings: DStarSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.toggleRecording()
                } label: {
                    Label(controller.isRecording ? Self.duration(controller.recordingDuration) : "REC",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "waveform.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.isRecording))
                .foregroundColor(controller.isRecording ? RadioTheme.ledRed : nil)
                .help("Eingangssignal als WAV aufnehmen (Quell-Abtastrate): zur Fehlersuche. Ordner: ~/Documents/Digidec/Recordings")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Aussendungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    let target = controller.lastRecording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? controller.logger.fileURL()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Letzte Aufnahme (sonst die Log-Datei) im Finder zeigen")
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Verlauf und Zähler leeren (Log bleibt)")
            }
            DStarNowCard(transmission: controller.transmissions.last, locked: controller.locked)
            DStarTable(controller: controller)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var summary: String {
        controller.transmissions.isEmpty ? "Warten auf D-Star (GMSK 4800 Bd, FM-Diskriminator-Audio)" : "\(controller.transmissions.count) Aussendungen"
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Die laufende (oder zuletzt gehörte) Aussendung groß
struct DStarNowCard: View {
    let transmission: DStarTransmission?
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = transmission {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(t.isLive ? RadioTheme.ledRed : RadioTheme.bgPanel)
                        .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                        .frame(width: 10, height: 10)
                    Text(t.myCall.isEmpty ? "(Rufzeichen unbekannt)" : t.myCall)
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                    if let my2 = t.header?.myCall2, !my2.isEmpty {
                        Text("/ \(my2)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdCyan)
                    }
                    Spacer()
                    Text(String(format: "%.1f s", t.seconds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(t.isLive ? RadioTheme.ledRed : RadioTheme.textMuted)
                }
                if let h = t.header {
                    Text("→ \(h.yourCall)   RPT1 \(h.repeater1.isEmpty ? "—" : h.repeater1)   RPT2 \(h.repeater2.isEmpty ? "—" : h.repeater2)\(h.isData ? "   DATEN" : "")\(h.isUrgent ? "   DRINGEND" : "")")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                }
                if let m = t.message {
                    Text("„\(m)“")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                }
                if let p = t.position {
                    Text(String(format: "Position %@ · %.4f° %.4f° · %@", p.callsign, p.latitude, p.longitude, p.comment))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                        .lineLimit(2)
                }
                if t.lateEntry {
                    Text("Später Einstieg: der Kopf wurde nicht gehört\(t.header == nil ? "" : ", Rufzeichen aus den Langsamdaten")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }
            } else {
                Text(locked ? "Aussendung wird empfangen …" : "Keine Aussendung")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}

struct DStarTable: View {
    @ObservedObject var controller: DStarController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                header
                ForEach(controller.transmissions.reversed()) { t in row(t).id(t.id) }
            }
            .padding(6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 56, alignment: .leading)
            Text("Rufzeichen").frame(width: 120, alignment: .leading)
            Text("Gegenstation").frame(width: 72, alignment: .leading)
            Text("Repeater").frame(width: 72, alignment: .leading)
            Text("Dauer").frame(width: 44, alignment: .trailing)
            Text("Text / Position").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 34)
            Text("").frame(width: 22)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ t: DStarTransmission) -> some View {
        let h = t.header
        let color: Color = t.isLive ? RadioTheme.ledRed : h == nil ? RadioTheme.textDim : RadioTheme.vfdGreen
        let detail = t.message ?? t.position.map { String(format: "%.3f° %.3f°", $0.latitude, $0.longitude) } ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DStarController.utc.string(from: t.start)).frame(width: 56, alignment: .leading)
            Text(((h?.myCall ?? "?") + ((h?.myCall2.isEmpty ?? true) ? "" : " /" + h!.myCall2))).frame(width: 120, alignment: .leading)
            Text(h?.yourCall ?? "").frame(width: 72, alignment: .leading)
            Text(h?.repeater1 ?? "").frame(width: 72, alignment: .leading)
            Text(String(format: "%.1f", t.seconds)).frame(width: 44, alignment: .trailing)
            Text(detail).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            QRZButton(text: h?.myCall ?? "").frame(width: 34, alignment: .trailing)
            Button {
                controller.replay(t)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(controller.output.decoderName == nil ? RadioTheme.textDim : RadioTheme.vfdCyan)
            .frame(width: 22)
            .disabled(controller.output.decoderName == nil || t.isLive)
            .help(controller.output.decoderName == nil ? "Kein Sprachdecoder: Stick in den Einstellungen wählen" : "Diese Aussendung noch einmal abspielen")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .help(tooltip(t))
    }

    private func tooltip(_ t: DStarTransmission) -> String {
        var s = DStarController.logLine(t)
        if t.lateEntry { s += "\nspäter Einstieg (ohne Kopf)" }
        if let p = t.position { s += "\n\(p.callsign): \(p.comment)" }
        s += "\n\(t.frames) Sprachrahmen" + (t.endedBy == .lost ? " · Signal ohne Ende-Kennung abgebrochen" : "")
        return s
    }
}

// MARK: - D-Star: Abstimmanzeige

struct DStarTuningPanel: View {
    @ObservedObject var controller: DStarController
    @ObservedObject var settings: DStarSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("D-STAR")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("DV · GMSK 4800 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: controller.locked, color: RadioTheme.vfdGreen)
                led("INVERS", on: controller.inverted, color: RadioTheme.vfdAmber)
                led("TON", on: controller.output.decoderName != nil, color: RadioTheme.vfdCyan)
            }
            PagerLevelBar(level: controller.level * 0.5)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("KÖPFE", "\(controller.stats.headersOK)")
                Spacer()
                readout("RAHMEN", "\(controller.stats.frames)")
                Spacer()
                readout("ENDEN", "\(controller.stats.ends)")
            }
            diagnosisView
        }
    }

    private var diagnosisView: some View {
        let d = controller.diagnosis
        let color: Color = d.severity == .ok ? RadioTheme.vfdGreen : d.severity == .waiting ? RadioTheme.vfdAmber : RadioTheme.ledRed
        return VStack(alignment: .leading, spacing: 4) {
            Divider().background(RadioTheme.borderSubtle)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(d.title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Spacer()
                Text(controller.inputDB <= -119 ? "kein Audio" : String(format: "%.0f dBFS", controller.inputDB))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(controller.inputDB < DStarDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let s = controller.stats
            if s.headersOK + s.headersBad + s.frames > 0 {
                Text("Köpfe \(s.headersOK) gut / \(s.headersBad) schlecht · später Einstieg \(s.lateEntries) · Synchronrahmen verpasst \(s.syncsMissed) · Signalverlust \(s.lost)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
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
            Text(LocalizedStringKey(label))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - D-Star: Einstellungen

struct DStarSettingsPanel: View {
    @ObservedObject var controller: DStarController
    @ObservedObject var settings: DStarSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceStickSettings(output: controller.output)
            Text("FM-Diskriminator-Audio, unbearbeitet (kein Hochpass, keine Entzerrung). Die Polarität wird erkannt. Ohne Sprachdecoder zeigt Digidec Rufzeichen, Repeater, Text und Positionen, aber keinen Ton.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
