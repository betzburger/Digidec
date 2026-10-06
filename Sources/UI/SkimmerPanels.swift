// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Skimmer: Stationen und Spots

struct SkimmerMainPanel: View {
    @ObservedObject var controller: SkimmerController
    @ObservedObject var settings: SkimmerSettingsStore
    /// Station im CW- bzw. PSK-Modul öffnen (dort liest der fldigi-Decoder das Signal in Ruhe)
    var openStation: (SkimStation) -> Void
    /// Entwicklungshilfe: DIGIDEC_SKIMMER_TAB=spots öffnet die Spot-Liste (für Schnappschüsse)
    @State private var tab = ProcessInfo.processInfo.environment["DIGIDEC_SKIMMER_TAB"] == "spots" ? Tab.spots : Tab.stations

    enum Tab: String, CaseIterable, Identifiable {
        case stations = "SIGNALE", spots = "SPOTS"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Spots in Tagesdatei schreiben (Frequenz, Rufzeichen, Geschwindigkeit, Rauschabstand): \(controller.logger.fileURL().path)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Log-Datei im Finder zeigen")
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Listen leeren (Log bleibt)")
            }
            switch tab {
            case .stations:
                SkimmerStationTable(controller: controller, settings: settings)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(6)
                SkimmerDetail(controller: controller, settings: settings, openStation: openStation)
            case .spots:
                SkimmerSpotTable(spots: controller.spots, mode: settings.mode)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(6)
            }
        }
    }

    private var summary: String {
        let n = controller.visibleStations.count
        if controller.stations.isEmpty {
            return "Warten auf Signale (\(settings.mode.name)\(settings.dialHz.map { String(format: " · Dial %.3f MHz", Double($0) / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? ""))"
        }
        return "\(n) Signale · \(controller.stations.filter { $0.call != nil }.count) mit Rufzeichen · \(controller.spots.count) Spots"
    }
}

struct SkimmerStationTable: View {
    @ObservedObject var controller: SkimmerController
    @ObservedObject var settings: SkimmerSettingsStore

    var body: some View {
        let list = controller.visibleStations
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 6)
                .padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        Text(controller.stations.isEmpty
                             ? "Noch kein Signal gefunden. Der Skimmer braucht einige Sekunden Audio, bis ein Signal über dem Rauschen (Schwelle \(Int(settings.thresholdDB)) dB) sicher gelesen wird."
                             : "Alle Signale sind ausgeblendet (Mindest-Rauschabstand \(Int(settings.minSNR)) dB\(settings.onlyCalls ? ", nur mit Rufzeichen" : "")).")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textMuted)
                            .padding(.top, 3)
                    }
                    ForEach(list) { s in row(s, now: now) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 10)
            Text("NF Hz").frame(width: 52, alignment: .trailing)
            Text("HF kHz").frame(width: 76, alignment: .trailing)
            Text("Rufzeichen").frame(width: 92, alignment: .leading)
            Text("Land").frame(width: 170, alignment: .leading)
            Text("S/N").frame(width: 34, alignment: .trailing)
            Text(settings.mode == .cw ? "WpM" : "Baud").frame(width: 38, alignment: .trailing)
            Text("vor").frame(width: 40, alignment: .trailing)
            Text("Text").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ s: SkimStation, now: Date) -> some View {
        let selected = controller.selection == s.id
        let age = max(0, now.timeIntervalSince(s.lastHeard))
        let color: Color = !s.isLive ? RadioTheme.textMuted : s.isCQ ? RadioTheme.vfdGreen : s.call != nil ? RadioTheme.vfdCyan : RadioTheme.vfdAmber
        let rf = s.rfHz(dialHz: settings.dialHz, lsb: settings.rigIsLSB ?? false)
        return HStack(spacing: 8) {
            Circle().fill(s.isLive && age < 8 ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                .frame(width: 8, height: 8).frame(width: 10)
            Text(String(Int(s.audioHz.rounded()))).frame(width: 52, alignment: .trailing)
            Text(rf.map { String(format: "%.1f", $0 / 1000).replacingOccurrences(of: ".", with: ",") } ?? "–").frame(width: 76, alignment: .trailing)
            Text(s.call ?? "…").frame(width: 92, alignment: .leading).fontWeight(s.isCQ ? .bold : .medium)
            Text(s.dxcc.map { "\($0.flag) \($0.name)" } ?? "").frame(width: 170, alignment: .leading).lineLimit(1)
            Text(String(Int(s.snrDB.rounded()))).frame(width: 34, alignment: .trailing)
            Text(String(Int(s.speed.rounded()))).frame(width: 38, alignment: .trailing)
            Text(ageText(age)).frame(width: 40, alignment: .trailing)
            Text(s.text.replacingOccurrences(of: "\n", with: " ⏎ ").suffix(60))
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .padding(.vertical, 1)
        .background(selected ? color.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { controller.selection = selected ? nil : s.id }
        .help(tooltip(s, rf: rf))
    }

    private func ageText(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : "\(Int(s / 3600)) h"
    }

    private func tooltip(_ s: SkimStation, rf: Double?) -> String {
        var t = (s.call ?? "Rufzeichen noch unbekannt") + " · " + s.mode.name
        t += String(format: "\nNF %.1f Hz", s.audioHz)
        if let rf { t += String(format: " · HF %.2f kHz", rf / 1000) }
        t += String(format: "\nS/N %.0f dB (500 Hz) · %.0f %@", s.snrDB, s.speed, s.mode == .cw ? "WpM" : "Baud")
        if let d = s.dxcc { t += "\n\(d.flag) \(d.name)" }
        if s.isCQ { t += "\nRuft CQ" }
        if !s.isLive { t += "\nSignal nicht mehr da" }
        return t
    }
}

/// Gewählte Station: ganzer gelesener Text, Knopf zum Öffnen im CW- bzw. PSK-Modul
struct SkimmerDetail: View {
    @ObservedObject var controller: SkimmerController
    @ObservedObject var settings: SkimmerSettingsStore
    var openStation: (SkimStation) -> Void

    var body: some View {
        if let id = controller.selection, let s = controller.stations.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(s.call ?? "?")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Text(String(format: "NF %.0f Hz · %.0f dB · %.0f %@", s.audioHz, s.snrDB, s.speed, s.mode == .cw ? "WpM" : "Baud"))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                    Spacer()
                    Button {
                        openStation(s)
                    } label: {
                        Label("IN \(s.mode == .cw ? "CW" : "PSK") ÖFFNEN", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Zum \(s.mode == .cw ? "CW" : "PSK")-Modul wechseln und den Ton auf dieses Signal stellen (dort liest der fldigi-Empfänger mit AFC und Einstellungen)")
                }
                ScrollView {
                    Text(s.text.isEmpty ? "(noch kein Text)" : s.text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 64)
                .padding(6)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
            }
        }
    }
}

struct SkimmerSpotTable: View {
    let spots: [SkimSpot]
    let mode: SkimMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("UTC").frame(width: 56, alignment: .leading)
                Text("Frequenz").frame(width: 84, alignment: .trailing)
                Text("Rufzeichen").frame(width: 96, alignment: .leading)
                Text("Land").frame(width: 170, alignment: .leading)
                Text("S/N").frame(width: 34, alignment: .trailing)
                Text(mode == .cw ? "WpM" : "Baud").frame(width: 38, alignment: .trailing)
                Text("Art").frame(width: 32, alignment: .leading)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 3)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if spots.isEmpty {
                            Text("Noch keine Spots. Ein Spot entsteht, sobald ein Rufzeichen nach CQ oder DE gelesen wurde (oder zweimal).")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                        }
                        ForEach(spots) { s in
                            row(s).id(s.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .onChange(of: spots.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ s: SkimSpot) -> some View {
        HStack(spacing: 8) {
            Text(SkimmerController.utc.string(from: s.time)).frame(width: 56, alignment: .leading)
            Text(s.rfHz.map { String(format: "%.1f", $0 / 1000).replacingOccurrences(of: ".", with: ",") } ?? "NF \(Int(s.audioHz))")
                .frame(width: 84, alignment: .trailing)
            Text(s.call).frame(width: 96, alignment: .leading).fontWeight(.bold)
            Text(s.dxcc.map { "\($0.flag) \($0.name)" } ?? "").frame(width: 170, alignment: .leading).lineLimit(1)
            Text(String(Int(s.snrDB.rounded()))).frame(width: 34, alignment: .trailing)
            Text(String(Int(s.speed.rounded()))).frame(width: 38, alignment: .trailing)
            Text(s.kind).frame(width: 32, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(s.kind == "CQ" ? RadioTheme.vfdGreen : RadioTheme.vfdCyan)
    }
}

// MARK: - Skimmer: Abstimmanzeige und Einstellungen

struct SkimmerTuningPanel: View {
    @ObservedObject var controller: SkimmerController
    @ObservedObject var settings: SkimmerSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SKIMMER")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(settings.mode.name)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Text(controller.inputDB <= -119 ? "kein Audio" : String(format: "%.0f dBFS", controller.inputDB))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(controller.inputDB < -70 ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios (Vollaussteuerung = 0 dBFS); brauchbar sind etwa −40 … −10 dBFS")
            }
            HStack {
                readout("SIGNALE", "\(controller.stations.filter(\.isLive).count)")
                Spacer()
                readout("SUCHE", "\(controller.trackCount) Träger")
            }
            HStack {
                readout("CQ", "\(controller.stations.filter { $0.isLive && $0.isCQ }.count)")
                Spacer()
                readout("SPOTS", "\(controller.spots.count)")
            }
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

struct SkimmerSettingsPanel: View {
    @ObservedObject var settings: SkimmerSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(SkimMode.allCases) { m in
                    Button(m.name) { settings.mode = m }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.mode == m))
                        .help(m == .cw ? "Alle CW-Signale im Audio lesen" : "Alle \(m.name)-Signale im Audio lesen (Träger im Abstand von mindestens etwa 60 Hz)")
                }
            }
            Text("BAND")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            if settings.mode == .cw {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(SkimBand.allCases) { b in
                        Button { settings.cwBand = b } label: { Text(verbatim: b == .free ? "frei" : b.rawValue.replacingOccurrences(of: "m", with: " m")).lineLimit(1).minimumScaleFactor(0.7) }
                            .buttonStyle(ModeButtonStyle(isSelected: settings.cwBand == b))
                            .help(b.dialHz.map { String(format: "Dial %.3f MHz USB: CW-Bereich ab hier, Signale 0,3 … 2,7 kHz darüber (nur mit QSY AUTO wird das Funkgerät abgestimmt)", Double($0) / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? "Funkgerät nicht abstimmen")
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(PSKBand.allCases) { b in
                        Button { settings.pskBand = b } label: { Text(verbatim: b == .free ? "frei" : b.rawValue.replacingOccurrences(of: "m", with: " m")).lineLimit(1).minimumScaleFactor(0.7) }
                            .buttonStyle(ModeButtonStyle(isSelected: settings.pskBand == b))
                            .help(b.dialHz.map { String(format: "Dial %.3f MHz USB (PSK31-Anruffrequenz)", Double($0) / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? "Funkgerät nicht abstimmen")
                    }
                }
            }
            HStack(spacing: 6) {
                label("SCHWELLE")
                Slider(value: $settings.thresholdDB, in: 4...16, step: 1)
                Text("\(Int(settings.thresholdDB)) dB")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 40, alignment: .trailing)
            }
            .help("Abstand eines Trägers zum Rauschen, ab dem ein Signal gesucht wird. Kleiner = empfindlicher, aber mehr falsche Treffer")
            HStack(spacing: 6) {
                label("MIN S/N")
                Stepper(value: $settings.minSNR, in: -5...25, step: 1) {
                    Text("\(Int(settings.minSNR)) dB")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                .help("Signale unter diesem Rauschabstand (in 500 Hz) erscheinen nicht in der Liste")
                Spacer()
                Button("NUR RUFZ.") { settings.onlyCalls.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.onlyCalls))
                    .help("Nur Signale zeigen, deren Rufzeichen erkannt wurde")
            }
            HStack(spacing: 6) {
                label("HALTEN")
                Stepper(value: $settings.holdMinutes, in: 1...60, step: 1) {
                    Text("\(Int(settings.holdMinutes)) min")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                .help("Wie lange ein Signal nach seinem Ende (abgedunkelt) in der Liste bleibt")
            }
            Text("Das Funkgerät steht in USB mit breitem Filter (2,4 … 3 kHz). Der Skimmer liest alle Signale im Audio gleichzeitig; Klick im Wasserfall wählt die nächste Station. Rauschabstand in 500 Hz (wie CW Skimmer und Reverse Beacon Network).")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }
}
