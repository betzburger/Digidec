// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - DMR: beide Zeitschlitze und Verlauf

struct DMRMainPanel: View {
    @ObservedObject var controller: DMRController
    @ObservedObject var settings: DMRSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.calls.isEmpty ? "Warten auf DMR (4FSK 4800 Bd, FM-Diskriminator-Audio)" : "\(controller.calls.count) Gespräche")
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
            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<2, id: \.self) { slot in slotCard(slot) }
            }
            VoiceCallTable(calls: controller.calls, timeFormatter: DMRController.utc, hasDecoder: output.decoderName != nil,
                           replay: { controller.replay($0) }, targetTitle: "Ziel", viaTitle: "Zeitschlitz")
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private func slotCard(_ slot: Int) -> some View {
        let audible = controller.audibleSlot == slot || (settings.audioSlot == (slot == 0 ? .slot1 : .slot2))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("ZEITSCHLITZ \(slot + 1)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                if audible && output.decoderName != nil {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 8)).foregroundColor(RadioTheme.vfdCyan).help("Dieser Zeitschlitz ist zu hören")
                }
            }
            VoiceCallNowCard(call: controller.currentCall(slot: slot), locked: false, waiting: "kein Gespräch")
        }
        .frame(maxWidth: .infinity)
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - DMR: Abstimmanzeige

struct DMRTuningPanel: View {
    @ObservedObject var controller: DMRController
    @ObservedObject var settings: DMRSettingsStore
    @ObservedObject var output: VoiceOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("DMR")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("2 Zeitschlitze · 4FSK 4800 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: controller.locked, color: RadioTheme.vfdGreen)
                led("INVERS", on: controller.inverted, color: RadioTheme.vfdAmber)
                led("TON", on: output.decoderName != nil, color: RadioTheme.vfdCyan)
                Text(controller.locked ? (controller.baseStation ? "Basisstation" : "direkt") : "")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            PagerLevelBar(level: controller.level * 0.5)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("SPRACHBURSTS", "\(controller.stats.voiceBursts)")
                Spacer()
                readout("EINGEBETTET", "\(controller.stats.embeddedLC)")
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
                    .foregroundColor(controller.inputDB < DMRDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let s = controller.stats
            if s.bursts > 0 {
                let share = s.frames > 0 ? Int((100 * Double(s.cleanFrames) / Double(s.frames)).rounded()) : 0
                Text("Bursts \(s.bursts) · Sprachrahmen ohne Bitfehler \(share) % · Leerlauf \(s.idleBursts) · Kopf \(s.headers), Abschluss \(s.terminators) · Slot Type nicht lesbar \(s.slotTypeBad), Link Control \(s.lcBad) · Verluste \(s.lost)")
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

// MARK: - DMR: Einstellungen

struct DMRSettingsPanel: View {
    @ObservedObject var settings: DMRSettingsStore
    @ObservedObject var output: VoiceOutput
    @ObservedObject private var database = DMRIDDatabase.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceStickSettings(output: output)
            HStack(spacing: 6) {
                Text("SLOT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                ForEach(DMRAudioSlot.allCases) { slot in
                    Button(slot.title) { settings.audioSlot = slot }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.audioSlot == slot))
                        .lineLimit(1)
                        .fixedSize()
                        .help(slot == .auto ? "Ton des Zeitschlitzes, der zuerst ein Gespräch hat (bis es endet)" : "Nur den Ton dieses Zeitschlitzes abspielen (der Sprachchip hat nur einen Kanal)")
                }
            }
            HStack(spacing: 6) {
                Text("FARBCODE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: $settings.colorCode) {
                    Text("alle").tag(-1)
                    ForEach(0..<16, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 90)
                .help("Nur Bursts mit diesem Farbcode beachten (Repeater unterscheiden sich damit); „alle“ = ohne Filter")
            }
            HStack(spacing: 6) {
                Text("ID-LISTE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Button(database.count > 0 ? "AKTUALISIEREN" : "LADEN") { Task { await database.download() } }
                    .buttonStyle(ModeButtonStyle(isSelected: database.count > 0))
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(database.isLoading)
                    .help("Lädt die DMR-ID-Liste (Rufzeichen, Name, Ort; rund 17 MB) von radioid.net und speichert sie lokal. Das geschieht nur auf diesen Knopfdruck; sonst nimmt Digidec für DMR keine Verbindung ins Netz auf.")
                Text(database.status)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(database.count > 0 ? RadioTheme.vfdGreen : RadioTheme.textMuted)
                    .lineLimit(1)
            }
            Text("FM-Diskriminator-Audio, unbearbeitet (kein Hochpass, keine Entzerrung). Die Polarität wird erkannt. Basisstation (Repeater) mit beiden Zeitschlitzen und Direktmodus. Absender und Ziel stammen aus dem Sprach-Kopf oder (bei spätem Einstieg) aus der eingebetteten Information.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
