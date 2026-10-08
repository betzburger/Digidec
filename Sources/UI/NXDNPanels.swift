// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - NXDN: Gespräch und Verlauf

struct NXDNMainPanel: View {
    @ObservedObject var controller: NXDNController
    @ObservedObject var settings: NXDNSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.calls.isEmpty ? "Warten auf NXDN (4FSK 2400 / 4800 Bd, FM-Diskriminator-Audio)" : "\(controller.calls.count) Gespräche")
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
            VoiceCallTable(calls: controller.calls, timeFormatter: NXDNController.utc, hasDecoder: output.decoderName != nil,
                           replay: { controller.replay($0) }, targetTitle: "Ziel", viaTitle: "RAN · Ruftyp")
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - NXDN: Abstimmanzeige

struct NXDNTuningPanel: View {
    @ObservedObject var controller: NXDNController
    @ObservedObject var settings: NXDNSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NXDN")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(controller.baud >= 4800 ? "12,5 kHz · 4FSK 4800 Bd" : controller.baud > 0 ? "6,25 kHz · 4FSK 2400 Bd" : "6,25 / 12,5 kHz · 4FSK 2400 / 4800 Bd")
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
                readout("GESPRÄCHE", "\(controller.stats.calls)")
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
                    .foregroundColor(controller.inputDB < NXDNDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let s = controller.stats
            if s.frames > 0 {
                let share = s.voiceFrames > 0 ? Int((100 * Double(s.cleanFrames) / Double(s.voiceFrames)).rounded()) : 0
                Text("Synchronisationen \(s.syncs) · Sprachrahmen ohne Bitfehler \(share) % · SACCH gut \(s.sacchGood), schlecht \(s.sacchBad) · FACCH1 gut \(s.facchGood), schlecht \(s.facchBad) · Verluste \(s.lost)")
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
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - NXDN: Einstellungen

struct NXDNSettingsPanel: View {
    @ObservedObject var settings: NXDNSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceStickSettings(output: output)
            HStack(spacing: 6) {
                Text("RAN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: $settings.ran) {
                    Text("alle").tag(-1)
                    ForEach(0..<64, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 90)
                .help("Nur Gespräche mit dieser Funkzugangsnummer (RAN, 0 bis 63) anzeigen und abspielen; „alle“ = ohne Filter")
            }
            Text("FM-Diskriminator-Audio, unbearbeitet (kein Hochpass, keine Entzerrung). NXDN48 (6,25 kHz, 2400 Bd) und NXDN96 (12,5 kHz, 4800 Bd) werden zugleich gesucht; die Polarität wird erkannt. Quelle, Ziel, Ruftyp und Funkzugangsnummer (RAN) stammen aus dem Rufkopf und dem SACCH; chiffrierte Gespräche (Scrambler, DES, AES) bleiben stumm. Sprache mit dem Halbraten-Codec (EHR); Icom IDAS (Typ D) wird nur als Sprache abgespielt, ohne Kennungen. Datenverkehr und Steuerkanäle der Bündelfunknetze werden nicht ausgewertet.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
