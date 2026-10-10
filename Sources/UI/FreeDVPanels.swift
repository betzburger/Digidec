// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - FreeDV: Zustand und Verlauf

struct FreeDVMainPanel: View {
    @ObservedObject var controller: FreeDVController
    @ObservedObject var settings: FreeDVSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.transmissions.isEmpty ? "Warten auf FreeDV \(settings.mode.title) (USB, NF 500 bis 2500 Hz)" : "\(controller.transmissions.count) Übertragungen")
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
                .help("Übertragungen in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    let target = controller.lastRecording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? controller.logger.fileURL()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: { Image(systemName: "folder") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Letzte Aufnahme (sonst die Log-Datei) im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Verlauf leeren (Log bleibt)")
            }
            FreeDVNowCard(controller: controller, mode: settings.mode)
            table
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("UTC").frame(width: 56, alignment: .leading)
                    Text("Modus").frame(width: 56, alignment: .leading)
                    Text("Text (Rufzeichen)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Dauer").frame(width: 56, alignment: .trailing)
                    Text("S/N").frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                ForEach(controller.transmissions.reversed()) { t in
                    HStack(spacing: 8) {
                        Text(FreeDVController.utc.string(from: t.start)).frame(width: 56, alignment: .leading)
                        Text(t.mode.title).frame(width: 56, alignment: .leading)
                        Text(t.text.isEmpty ? "—" : t.text).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(String(format: "%.0f s", t.seconds)).frame(width: 56, alignment: .trailing)
                        Text(String(format: "%.1f dB", t.averageSNR)).frame(width: 56, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(t.isLive ? RadioTheme.ledRed : RadioTheme.vfdGreen)
                }
            }
            .padding(6)
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Die laufende (oder zuletzt gehörte) Übertragung groß
struct FreeDVNowCard: View {
    @ObservedObject var controller: FreeDVController
    let mode: FreeDVMode

    var body: some View {
        let t = controller.transmissions.last
        VStack(alignment: .leading, spacing: 4) {
            if let t {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(t.isLive ? RadioTheme.ledRed : RadioTheme.bgPanel)
                        .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                        .frame(width: 10, height: 10)
                    Text(t.text.isEmpty ? "(ohne Rufzeichen)" : t.text)
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .foregroundColor(t.text.isEmpty ? RadioTheme.textDim : RadioTheme.vfdAmber)
                    Text("FreeDV \(t.mode.title)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Spacer()
                    Text(String(format: "%.0f s", t.seconds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(t.isLive ? RadioTheme.ledRed : RadioTheme.textMuted)
                }
                if t.isLive {
                    Text(String(format: "S/N %.1f dB · Ablage %+.0f Hz · Takt %+.0f ppm", controller.status.snr, controller.status.frequencyOffset, controller.status.clockOffsetPPM))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                }
            } else {
                Text("Keine Übertragung")
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

// MARK: - FreeDV: Abstimmanzeige

struct FreeDVTuningPanel: View {
    @ObservedObject var controller: FreeDVController
    @ObservedObject var settings: FreeDVSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("FREEDV")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("\(settings.mode.title) · digitale Sprache KW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: controller.status.sync, color: RadioTheme.vfdGreen)
                led("SPRACHE", on: controller.isSpeaking, color: RadioTheme.vfdCyan)
            }
            SNRBar(snr: controller.status.sync ? controller.status.snr : -10)
                .frame(height: 8)
                .help("Geschätzter Rauschabstand (−5 … +20 dB)")
            HStack {
                readout("S/N", controller.status.sync ? String(format: "%.1f dB", controller.status.snr) : "—")
                Spacer()
                readout("ABLAGE", controller.status.sync ? String(format: "%+.0f Hz", controller.status.frequencyOffset) : "—")
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
                    .foregroundColor(controller.inputDB < FreeDVDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios am Eingang (Vollaussteuerung = 0 dBFS)")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
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

struct SNRBar: View {
    let snr: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(RadioTheme.bgDeep)
                RoundedRectangle(cornerRadius: 3)
                    .fill(snr > 3 ? RadioTheme.vfdGreen : snr > -2 ? RadioTheme.vfdAmber : RadioTheme.textDim)
                    .frame(width: geo.size.width * min(1, max(0, (snr + 5) / 25)))
            }
        }
    }
}

// MARK: - FreeDV: Einstellungen

struct FreeDVSettingsPanel: View {
    @ObservedObject var settings: FreeDVSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(FreeDVMode.allCases) { m in
                    Button(m.title) { settings.mode = m }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.mode == m))
                        .lineLimit(1)
                        .fixedSize()
                        .help(m.detail)
                }
            }
            Text(settings.mode.detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("TON")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Button("AUSGABE") { settings.playAudio.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.playAudio))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Decodierte Sprache über den Standard-Ausgang abspielen")
                Button("SPERRE") { settings.squelch.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.squelch))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Ton nur bei Synchronisation (sonst bleibt es still); aus: alles, was das Modem liefert")
            }
            Text("Empfangs-Audio des Funkgeräts im USB-Seitenband (Filter 300 bis 2500 Hz, AGC an, nicht übersteuern). Sprache und Text kommen aus Codec2 von David Rowe VK5DGR (LGPL); der Sprachcodec ist frei, es braucht keinen Stick. Üblich: 14,236 MHz USB.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}
