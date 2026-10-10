// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - M17: Gespräch und Verlauf

struct M17MainPanel: View {
    @ObservedObject var controller: M17Controller
    @ObservedObject var settings: M17SettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.calls.isEmpty ? "Warten auf M17 (4FSK 4800 Bd, FM-Diskriminator-Audio)" : "\(controller.calls.count) Gespräche")
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
                .help("Gespräche in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
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
            VoiceCallNowCard(call: controller.currentCall ?? controller.calls.last, locked: controller.locked, waiting: "kein Gespräch")
            VoiceCallTable(calls: controller.calls, timeFormatter: M17Controller.utc, hasDecoder: false, replay: { _ in },
                           targetTitle: "Ziel", viaTitle: "Kanal", replayAvailable: false)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - M17: Abstimmanzeige

struct M17TuningPanel: View {
    @ObservedObject var controller: M17Controller
    @ObservedObject var settings: M17SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("M17")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("4FSK 4800 Bd · Codec2")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: controller.locked, color: RadioTheme.vfdGreen)
                led("INVERS", on: controller.inverted, color: RadioTheme.vfdAmber)
                led("TON", on: settings.playAudio, color: RadioTheme.vfdCyan)
                Text(controller.locked ? String(format: "Bitfehler %.1f %%", Double(controller.errorRate) * 100) : "")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            PagerLevelBar(level: controller.level * 0.5)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("RAHMEN", "\(controller.stats.streamFrames)")
                Spacer()
                readout("LSF", "\(controller.stats.lsfFrames + controller.stats.lsfFromLICH)")
                Spacer()
                readout("PAKETE", "\(controller.stats.packets)")
                Spacer()
                readout("GESPRÄCHE", "\(controller.stats.calls)")
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
                    .foregroundColor(controller.inputDB < M17Diagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let s = controller.stats
            if s.syncs > 0 {
                Text("Synchronisationen \(s.syncs) · Strom-Rahmen \(s.streamFrames), Paket-Rahmen \(s.packetFrames) (Pakete \(s.packets), fehlerhaft \(s.packetsBad)), BERT-Rahmen \(s.bertFrames), LSF-Rahmen \(s.lsfFrames), LSF aus LICH \(s.lsfFromLICH) · nicht lesbar \(s.badFrames), LSF-Prüfsumme \(s.lsfBad) · Ende-Kennungen \(s.endMarkers) · Verluste \(s.lost)")
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

// MARK: - M17: Einstellungen

struct M17SettingsPanel: View {
    @ObservedObject var settings: M17SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("TON")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Button("AUSGABE") { settings.playAudio.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.playAudio))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Empfangene Sprache über den Standard-Ausgang abspielen (Codec2 3200 und 1600; verschlüsselte Gespräche bleiben stumm)")
                Text("Codec2 in Digidec, kein Sprachstick nötig")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("CAN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: $settings.channelAccessNumber) {
                    Text("alle").tag(-1)
                    ForEach(0..<16, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 90)
                .help("Kanalzugriffsnummer: nur Gespräche mit dieser Nummer anzeigen und abspielen (trennt mehrere Gespräche auf derselben Frequenz); „alle“ = ohne Filter")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("SCHLÜSSEL (Signaturprüfung)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextEditor(text: $settings.publicKeys)
                    .font(.system(size: 9, design: .monospaced))
                    .frame(height: 46)
                    .scrollContentBackground(.hidden)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(4)
                    .help("Eine Zeile je Station: RUFZEICHEN gefolgt vom öffentlichen Schlüssel (128 Hexstellen, x und y der Kurve secp256r1). Signierte Gespräche dieser Station werden damit geprüft.")
            }
            Text("FM-Diskriminator-Audio, unbearbeitet (kein Hochpass, keine Entzerrung). Die Polarität wird erkannt. Absender, Ziel und Zusatzdaten (Text, Position) kommen aus dem Link Setup Frame, bei spätem Einstieg aus den LICH-Anteilen der Strom-Rahmen. Paketmodus (SMS, APRS, IPv4 …) mit CRC-Prüfung, BERT-Test (Bitfehlerrate) und Signaturprüfung mit hinterlegtem Schlüssel sind dabei. Nicht unterstützt: Entschlüsselung.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
