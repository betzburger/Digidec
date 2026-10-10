// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - P25: Gespräch und Verlauf

struct P25MainPanel: View {
    @ObservedObject var controller: P25Controller
    @ObservedObject var settings: P25SettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.calls.isEmpty ? "Warten auf P25 (C4FM 4800 Bd, FM-Diskriminator-Audio)" : "\(controller.calls.count) Gespräche")
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
            VoiceCallTable(calls: controller.calls, timeFormatter: P25Controller.utc, hasDecoder: output.hasDecoder(for: .p25),
                           replay: { controller.replay($0) }, targetTitle: "Gruppe / Ziel", viaTitle: "NAC · Ruftyp")
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - P25: Abstimmanzeige

struct P25TuningPanel: View {
    @ObservedObject var controller: P25Controller
    @ObservedObject var settings: P25SettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("P25")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("12,5 kHz · C4FM 4800 Bd · Phase 1")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: controller.locked, color: RadioTheme.vfdGreen)
                led("INVERS", on: controller.inverted, color: RadioTheme.vfdAmber)
                led("TON", on: output.hasDecoder(for: .p25), color: RadioTheme.vfdCyan)
            }
            PagerLevelBar(level: controller.level * 0.5)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("EINHEITEN", "\(controller.stats.units)")
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
                    .foregroundColor(controller.inputDB < P25Diagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let s = controller.stats
            if s.units > 0 {
                let share = s.voiceFrames > 0 ? Int((100 * Double(s.cleanFrames) / Double(s.voiceFrames)).rounded()) : 0
                Text("Synchronisationen \(s.syncs) · Sprachrahmen ohne Bitfehler \(share) % · Linksteuerung gut \(s.lcGood), schlecht \(s.lcBad) · Verschlüsselungsdaten gut \(s.essGood), schlecht \(s.essBad) · Steuerkanal \(s.tsdu) · Verluste \(s.lost)")
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

// MARK: - P25: Einstellungen

struct P25SettingsPanel: View {
    @ObservedObject var settings: P25SettingsStore
    @ObservedObject var output: VoiceOutput
    @State private var nacText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceStickSettings(output: output)
            HStack(spacing: 6) {
                Text("NAC")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                TextField("alle", text: $nacText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .frame(width: 70)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(5)
                    .onSubmit { if let v = P25SettingsStore.parseNAC(nacText) { settings.nac = v } else { nacText = Self.text(settings.nac) } }
                    .help("Nur Aussendungen mit dieser Netzkennung (NAC, Hexzahl 000 bis FFF) anzeigen und abspielen; leer = alle. Mit Return übernehmen.")
                Text(settings.nac < 0 ? "alle Netze" : String(format: "NAC %03X", settings.nac))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            Text("FM-Diskriminator-Audio, unbearbeitet (kein Hochpass, keine Entzerrung), Empfänger mit etwa 12,5 kHz Filterbreite; die Polarität wird erkannt. Netzkennung (NAC), Gruppe oder Ziel und Quelle stammen aus der Linksteuerung der Sprachrahmen (LDU1), Hersteller, Algorithmus und Schlüsselnummer aus Kopf und LDU2. Verschlüsselte Gespräche bleiben stumm. Phase 1 (FDMA); Phase 2 (TDMA) und die Datenpakete werden nicht ausgewertet.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
        .onAppear { nacText = Self.text(settings.nac) }
    }

    private static func text(_ nac: Int) -> String { nac < 0 ? "" : String(format: "%03X", nac) }
}
