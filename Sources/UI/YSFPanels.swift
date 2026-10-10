// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - YSF: laufende Aussendung und Verlauf

struct YSFMainPanel: View {
    @ObservedObject var controller: YSFController
    @ObservedObject var settings: YSFSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.calls.isEmpty ? "Warten auf YSF (C4FM 4800 Bd, FM-Diskriminator-Audio)" : "\(controller.calls.count) Aussendungen")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button { controller.toggleRecording() } label: {
                    Label(controller.isRecording ? Self.duration(controller.recordingDuration) : "REC",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "waveform.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.isRecording))
                .foregroundColor(controller.isRecording ? RadioTheme.ledRed : nil)
                .help("Eingangssignal als WAV aufnehmen (Quell-Abtastrate): zur Fehlersuche. Ordner: ~/Documents/Digidec/Recordings")
                Button { controller.logEnabled.toggle() } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Aussendungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    let target = controller.lastRecording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? controller.logger.fileURL()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: { Image(systemName: "folder") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Letzte Aufnahme (sonst die Log-Datei) im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Verlauf und Zähler leeren (Log bleibt)")
            }
            VoiceCallNowCard(call: controller.calls.last, locked: controller.locked, waiting: "Keine Aussendung")
            VoiceCallTable(calls: controller.calls, timeFormatter: YSFController.utc, hasDecoder: output.decoderName != nil, replay: { controller.replay($0) })
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - YSF: Abstimmanzeige

struct YSFTuningPanel: View {
    @ObservedObject var controller: YSFController
    @ObservedObject var settings: YSFSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("YSF")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("System Fusion · C4FM 4800 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: controller.locked, color: RadioTheme.vfdGreen)
                led("INVERS", on: controller.inverted, color: RadioTheme.vfdAmber)
                led("TON", on: output.decoderName != nil, color: RadioTheme.vfdCyan)
            }
            PagerLevelBar(level: controller.level * 0.5)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("RAHMEN", "\(controller.stats.frames)")
                Spacer()
                readout("SYNC VERPASST", "\(controller.stats.syncsMissed)")
                Spacer()
                readout("VERLOREN", "\(controller.stats.lost)")
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
                    .foregroundColor(controller.inputDB < YSFDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let s = controller.stats
            if s.syncs + s.frames > 0 {
                Text("Rahmen \(s.frames) · Kopfteil (FICH) nicht lesbar \(s.fichBad), davon abgeleitet \(s.inferred) · Signalverlust \(s.lost)")
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

// MARK: - YSF: Einstellungen

struct YSFSettingsPanel: View {
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceStickSettings(output: output)
            Text("FM-Diskriminator-Audio, unbearbeitet (kein Hochpass, keine Entzerrung). Die Polarität wird erkannt. Der Ton kommt nur im Modus V/D 2 (der übliche Digitalmodus); Rufzeichen werden auch in den anderen Modi gelesen.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
