// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - DRM: Dienst und Empfang

struct DRMMainPanel: View {
    @ObservedObject var controller: DRMController
    @ObservedObject var settings: DRMSettingsStore

    var body: some View {
        let s = controller.status
        VStack(alignment: .leading, spacing: 10) {
            if !s.locked {
                Text(controller.inputDB < DRMDiagnosis.silenceDB ? "Kein Audio am Eingang." : "Warten auf ein DRM-Signal …")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Text("DRM30 (OFDM, Modus A bis D, 4,5 bis 20 kHz). Das Signal muss im Audio zwischen etwa 1 und 22 kHz liegen; Empfänger auf USB mit mindestens 12 kHz Filterbreite, Dial = Sendefrequenz − 6 kHz.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            } else {
                service(s)
                Divider().background(RadioTheme.borderSubtle)
                details(s)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }

    @ViewBuilder
    private func service(_ s: DRMStatus) -> some View {
        let current = controller.currentService
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(controller.audioPeak > 0.01 ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                .frame(width: 10, height: 10)
            Text((current?.label.isEmpty ?? true) ? "(Dienstname wird gelesen)" : current!.label)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
                .lineLimit(1)
            Spacer()
            if let d = s.date {
                Text(String(format: "%02d.%02d.%04d %02d:%02d UTC", d.day, d.month, d.year, d.minutes / 60, d.minutes % 60))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
        if let c = current {
            HStack(spacing: 14) {
                if !c.languageTitle.isEmpty, c.language != 0 { tag("SPRACHE", c.languageTitle) }
                if !c.programmeTitle.isEmpty, c.descriptor != 0 { tag("PROGRAMM", c.programmeTitle) }
                if let a = c.audio { tag("AUDIO", "\(a.coding.title)\(a.sbr ? " + SBR" : "") · \(a.modeTitle) · \(a.outputRate % 1000 == 0 ? "\(a.outputRate / 1000)" : String(format: "%.1f", Double(a.outputRate) / 1000)) kHz") }
                if let id = c.id { tag("KENNUNG", String(format: "%06X", id)) }
                if c.caUsed { tag("ZUGANG", "bedingt (verschlüsselt)") }
            }
        }
        if !controller.text.isEmpty {
            Text(controller.text)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .lineLimit(3)
        }
        if !controller.unsupportedReason.isEmpty {
            Text(controller.unsupportedReason)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.ledYellow)
        }
        if s.services.count > 1 {
            HStack(spacing: 6) {
                ForEach(s.services, id: \.shortID) { sv in
                    Button("\(sv.shortID + 1) · \(sv.label.isEmpty ? (sv.isAudio ? "Audio" : "Daten") : sv.label)") { settings.service = sv.shortID }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.service == sv.shortID))
                        .disabled(!sv.isAudio)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ s: DRMStatus) -> some View {
        let mscNames = ["64-QAM", "hierarchisch (gemischt)", "hierarchisch (symmetrisch)", "16-QAM"]
        let sdcNames = ["16-QAM", "4-QAM"]
        VStack(alignment: .leading, spacing: 4) {
            row("ÜBERTRAGUNG", "Modus \(s.mode?.letter ?? "?") · \(s.occupancy?.title ?? "?") · Verschachtelung \(s.longInterleaver ? "lang (2 s)" : "kurz (0,4 s)")")
            row("KODIERUNG", "MSC \(mscNames[min(s.mscMode, 3)]) · SDC \(sdcNames[min(s.sdcMode, 1)])" + (s.streams.isEmpty ? "" : " · Schutzstufe \(s.protectionA)/\(s.protectionB)"))
            if !s.streams.isEmpty {
                let bytes = s.streams.reduce(0) { $0 + $1.lengthA + $1.lengthB }
                row("DATENRATE", String(format: "%.1f kbit/s Nutzdaten (%d Ströme)", Double(bytes) * 8 / 0.4 / 1000, s.streams.count))
            }
            row("EMPFANG", String(format: "SNR %.1f dB · Frequenzablage %+.1f Hz", s.snr, s.frequencyOffset - Double((s.frequencyOffset / 46.875).rounded()) * 46.875))
            row("RAHMEN", "FAC \(s.facGood)/\(s.facGood + s.facBad) · SDC \(s.sdcGood)/\(s.sdcGood + s.sdcBad) · MSC \(s.mscFrames) · Audio \(s.audioFramesGood)/\(s.audioFramesGood + s.audioFramesBad)")
        }
    }

    private func tag(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textBright)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim).frame(width: 84, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textBright)
        }
    }
}

enum DRMDiagnosis {
    static let silenceDB = -70.0
}

// MARK: - DRM: Abstimmanzeige

struct DRMTuningPanel: View {
    @ObservedObject var controller: DRMController
    @ObservedObject var settings: DRMSettingsStore

    var body: some View {
        let s = controller.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("DRM")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(s.locked ? "Modus \(s.mode?.letter ?? "?") · \(s.occupancy?.title ?? "")" : "DRM30 · OFDM")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("SYNC", on: s.locked, color: RadioTheme.vfdGreen)
                led("FAC", on: s.locked && s.facGood > 0 && s.facBad < s.facGood, color: RadioTheme.vfdCyan)
                led("SDC", on: s.sdcGood > 0, color: RadioTheme.vfdCyan)
                led("TON", on: controller.audioPeak > 0.005, color: RadioTheme.vfdAmber)
            }
            PagerLevelBar(level: s.locked ? min(1, max(0, (s.snr + 5) / 40)) : 0)
                .frame(height: 8)
                .help("Signal-Rausch-Verhältnis der Zellen (−5 … 35 dB)")
            HStack {
                readout("SNR", s.locked ? String(format: "%.1f dB", s.snr) : "—")
                Spacer()
                readout("MSC", "\(s.mscFrames)")
                Spacer()
                readout("TON", "\(s.audioFramesGood)/\(s.audioFramesGood + s.audioFramesBad)")
            }
            Text(controller.inputDB <= -119 ? "kein Audio" : String(format: "%.0f dBFS", controller.inputDB))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(controller.inputDB < DRMDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
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
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - DRM: Einstellungen

struct DRMSettingsPanel: View {
    @ObservedObject var settings: DRMSettingsStore
    @ObservedObject var controller: DRMController
    @State private var frequencyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("FREQUENZ")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 66, alignment: .leading)
                TextField("kHz", text: $frequencyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .frame(width: 90)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(5)
                    .onSubmit { commit() }
                    .help("Sendefrequenz (Mitte des Kanals) in kHz; mit Return übernehmen. Das Funkgerät wird auf USB mit dem Dial 6 kHz darunter gestellt.")
                Text("kHz")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            HStack(spacing: 6) {
                Text("TON")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 66, alignment: .leading)
                Button("AUS") { settings.muted.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.muted))
                    .help("Ton stummschalten")
                Slider(value: $settings.volume, in: 0...1)
                    .frame(width: 130)
            }
            Text("Empfänger: USB mit 12 kHz oder mehr Filterbreite (SDR: Kanalbreite einstellen), Dial 6 kHz unter der Sendefrequenz; das DRM-Signal liegt dann bei etwa 1 bis 11 kHz im Audio. Jeder Modus (A bis D) und jede Belegung (4,5 bis 20 kHz) wird selbst erkannt, ebenso die Trägerlage, solange das Signal im Audio liegt. Audio: AAC-LC mit SBR und Stereo sowie xHE-AAC (Mono und Stereo, mit dem Decoder von macOS); Datendienste und hierarchische Modulation werden nicht ausgewertet.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
        .onAppear { frequencyText = Self.format(settings.frequencyKHz) }
    }

    private func commit() {
        let t = frequencyText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(t), (100...30_000).contains(v) { settings.frequencyKHz = v }
        frequencyText = Self.format(settings.frequencyKHz)
    }

    private static func format(_ f: Double) -> String { f == f.rounded() ? String(Int(f)) : String(format: "%.1f", f) }
}
