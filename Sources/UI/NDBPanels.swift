// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private let ndbHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)
private let ndbRowFont = Font.system(size: 11, weight: .medium, design: .monospaced)

// MARK: - Hauptbereich

struct NDBMainPanel: View {
    @ObservedObject var controller: NDBController
    @ObservedObject var settings: NDBSettingsStore
    @State private var tab = Tab.fromEnvironment()

    enum Tab: String, CaseIterable, Identifiable {
        case receive = "EMPFANG", nearby = "UMKREIS", scan = "SUCHLAUF"
        var id: String { rawValue }
        /// Entwicklungshilfe: DIGIDEC_NDB_TAB=nearby|scan öffnet die Seite (für Schnappschüsse)
        static func fromEnvironment() -> Tab {
            switch ProcessInfo.processInfo.environment["DIGIDEC_NDB_TAB"] {
            case "nearby": return .nearby
            case "scan": return .scan
            default: return .receive
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
                .frame(width: 300)
                Text(summary)
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
                .help("Eingangssignal als WAV aufnehmen: zur Fehlersuche. Ordner: ~/Documents/Digidec/Recordings")
                Button { controller.logEnabled.toggle() } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Gelesene Kennungen in die Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([controller.lastRecording ?? controller.logger.fileURL()]) } label: { Image(systemName: "folder") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Letzte Aufnahme (sonst die Log-Datei) im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Listen leeren")
            }
            Group {
                switch tab {
                case .receive: NDBReceiveView(controller: controller)
                case .nearby: NDBNearbyTable(controller: controller, settings: settings)
                case .scan: NDBScanView(controller: controller, settings: settings)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var summary: String {
        let n = controller.heard.count
        return n == 0 ? "Warten auf eine Kennung" : "\(n) Funkfeuer gehört"
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Empfang

struct NDBReceiveView: View {
    @ObservedObject var controller: NDBController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(controller.ident.isEmpty ? "–––" : controller.ident)
                        .font(.system(size: 40, weight: .black, design: .monospaced))
                        .foregroundColor(controller.identConfirmed ? RadioTheme.vfdGreen : controller.ident.isEmpty ? RadioTheme.textDim : RadioTheme.vfdAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.carrierKHz.map { NDBFormat.khzText($0) } ?? "Frequenz unbekannt")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdCyan)
                        Text(controller.reading.present ? NDBFormat.toneKind(controller.reading.toneHz) : "kein Ton")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(RadioTheme.textMuted)
                    }
                    Spacer()
                    Text(controller.identConfirmed ? "bestätigt" : controller.ident.isEmpty ? "" : "unbestätigt")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(controller.identConfirmed ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                }
                matchView
                Text(controller.diagnosis.title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.diagnosis.ok ? RadioTheme.vfdGreen : RadioTheme.ledRed)
                if !controller.diagnosis.advice.isEmpty {
                    Text(controller.diagnosis.advice)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().background(RadioTheme.borderSubtle)
                Text("GEHÖRT").font(ndbHeaderFont).foregroundColor(RadioTheme.textDim)
                HStack(spacing: 8) {
                    Text("KENNUNG").frame(width: 66, alignment: .leading)
                    Text("kHz").frame(width: 56, alignment: .trailing)
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("ENTF.").frame(width: 70, alignment: .trailing)
                    Text("S/N").frame(width: 44, alignment: .trailing)
                    Text("×").frame(width: 28, alignment: .trailing)
                    Text("LISTE").frame(width: 48, alignment: .leading)
                    Text("VOR").frame(width: 50, alignment: .trailing)
                }
                .font(ndbHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.heard) { e in row(e, now: ctx.date) }
                    }
                }
                if controller.heard.isEmpty {
                    Text("Noch kein Funkfeuer gelesen. Das Funkgerät auf die Frequenz eines Funkfeuers stellen (AM, 2 bis 3 kHz) oder in UMKREIS eines anklicken.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
                if !controller.reads.isEmpty {
                    Text("LESUNGEN: " + controller.reads.suffix(8).map(\.text).joined(separator: "  "))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var matchView: some View {
        switch controller.match {
        case .confirmed(let s):
            Text("✓ \(s.name) (\(s.country)) · \(s.frequencyText)" + distance(s))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdGreen)
        case .identOnly(let s, let d):
            Text("Kennung passt zu \(s.name) (\(s.country)), Liste \(s.frequencyText)" + (abs(d) > 0.05 ? String(format: ", Abweichung %+.1f kHz", d).replacingOccurrences(of: ".", with: ",") : "") + distance(s))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
        case .frequencyOnly(let list):
            Text("Auf dieser Frequenz laut Liste: " + list.prefix(3).map { "\($0.ident) \($0.name)" }.joined(separator: ", ") + " – gelesene Kennung weicht ab")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
        case .unknown:
            Text(controller.identConfirmed ? "Nicht in der Liste" : " ")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private func distance(_ s: NDBStation) -> String {
        guard let h = controller.home() else { return "" }
        let km = Geo.distanceKm(h, s.point), b = Geo.bearing(from: h, to: s.point)
        return " · \(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)"
    }

    private func row(_ e: NDBHeard, now: Date) -> some View {
        let age = now.timeIntervalSince(e.last)
        let color: Color = age < 120 ? RadioTheme.vfdGreen : age < 1800 ? RadioTheme.vfdCyan : RadioTheme.textDim
        return HStack(spacing: 8) {
            Text(e.ident).frame(width: 66, alignment: .leading)
            Text(String(format: "%.1f", e.frequencyKHz).replacingOccurrences(of: ".", with: ",")).frame(width: 56, alignment: .trailing)
            Text(e.station.map { "\($0.name) (\($0.country))" } ?? "unbekannt").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(e.km.map { Geo.formatKm($0) } ?? "–").frame(width: 70, alignment: .trailing)
            Text(String(format: "%.0f dB", e.snrDB)).frame(width: 44, alignment: .trailing)
            Text("\(e.count)").frame(width: 28, alignment: .trailing)
            Text(e.confirmedByList ? "ja" : e.station != nil ? "Freq." : "nein").frame(width: 48, alignment: .leading)
            Text(age < 90 ? "\(Int(age)) s" : age < 5400 ? "\(Int(age / 60)) min" : "\(Int(age / 3600)) h").frame(width: 50, alignment: .trailing)
        }
        .font(ndbRowFont)
        .foregroundColor(color)
    }
}

// MARK: - Umkreis

struct NDBNearbyTable: View {
    @ObservedObject var controller: NDBController
    @ObservedObject var settings: NDBSettingsStore

    var body: some View {
        let list = controller.nearby()
        let heardIDs = Set(controller.heard.compactMap { $0.station?.id })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("KENNUNG").frame(width: 66, alignment: .leading)
                    Text("kHz").frame(width: 56, alignment: .trailing)
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("LAND").frame(width: 40, alignment: .leading)
                    Text("ENTF.").frame(width: 70, alignment: .trailing)
                    Text("RICHTUNG").frame(width: 70, alignment: .leading)
                    Text(" ").frame(width: 30)
                }
                .font(ndbHeaderFont)
                .foregroundColor(RadioTheme.textDim)
                .padding(.bottom, 3)
                ForEach(list, id: \.station.id) { item in
                    let s = item.station
                    let isHeard = heardIDs.contains(s.id)
                    HStack(spacing: 8) {
                        Text(s.ident).frame(width: 66, alignment: .leading)
                        Text(String(format: "%.0f", s.frequencyKHz)).frame(width: 56, alignment: .trailing)
                        Text(s.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(s.country).frame(width: 40, alignment: .leading)
                        Text(Geo.formatKm(item.km)).frame(width: 70, alignment: .trailing)
                        Text(controller.home().map { Geo.compass(Geo.bearing(from: $0, to: s.point)) } ?? "–").frame(width: 70, alignment: .leading)
                        Text(isHeard ? "✓" : " ").frame(width: 30)
                    }
                    .font(ndbRowFont)
                    .foregroundColor(isHeard ? RadioTheme.vfdGreen : RadioTheme.textMuted)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.tune(to: s) }
                    .help("Anklicken: Funkgerät auf \(s.frequencyText) (AM) stellen")
                }
                if list.isEmpty {
                    Text(controller.home() == nil ? "Standort (Locator) fehlt." : "Keine Funkfeuer im Umkreis von \(Int(settings.radiusKm)) km.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Suchlauf

struct NDBScanView: View {
    @ObservedObject var controller: NDBController
    @ObservedObject var settings: NDBSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(controller.scan == .off ? "SUCHLAUF STARTEN" : "STOPP") {
                    if controller.scan == .off { controller.startScan() } else { controller.stopScan() }
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.scan != .off))
                .help("Das Funkgerät der Reihe nach auf die Funkfeuer im Umkreis stellen und jeweils auf die Kennung warten")
                if case .running(let i, let n, let f) = controller.scan {
                    Text("\(i) von \(n) · \(NDBFormat.khzText(f))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                Spacer()
            }
            Text("Der Suchlauf stellt das Funkgerät (über rigctld) auf jede Frequenz der Funkfeuer im Umkreis von \(Int(settings.radiusKm)) km, wartet bis zu \(Int(settings.dwellSeconds)) s auf die Kennung (früher, wenn sie gelesen und bestätigt ist) und geht weiter. Funkfeuer wiederholen die Kennung alle 10 bis 60 s.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(controller.scanLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(ndbRowFont)
                            .foregroundColor(line.contains("nichts") ? RadioTheme.textDim : RadioTheme.vfdGreen)
                    }
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Abstimmanzeige

struct NDBTuningPanel: View {
    @ObservedObject var controller: NDBController
    @ObservedObject var settings: NDBSettingsStore

    var body: some View {
        let r = controller.reading
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NDB")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(controller.carrierKHz.map { NDBFormat.khzText($0) } ?? "keine Frequenz")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("TON", on: r.present, color: RadioTheme.vfdGreen)
                led("TASTUNG", on: r.keyed, color: RadioTheme.vfdAmber)
                led("KENNUNG", on: controller.identConfirmed, color: RadioTheme.vfdCyan)
            }
            PagerLevelBar(level: max(0, min(0.4, r.snrDB / 80)))
                .frame(height: 8)
                .help("Abstand des Tons zum Rauschen")
            HStack {
                readout("TON", r.present ? "\(Int(r.toneHz.rounded())) Hz" : "–")
                Spacer()
                readout("S/N", r.present ? String(format: "%.0f dB", r.snrDB) : "–")
            }
            HStack {
                readout("EINGANG", controller.inputDB <= -119 ? "kein Audio" : String(format: "%.0f dBFS", controller.inputDB))
                Spacer()
                readout("MODE", controller.rigMode ?? "–")
            }
            ADSBRateChart(values: controller.toneHistory.map { max(0, $0) })
                .frame(height: 32)
                .help("Verlauf des Abstands von Ton zu Rauschen")
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
        }
        .foregroundColor(RadioTheme.vfdCyan)
    }
}

// MARK: - Einstellungen

struct NDBSettingsPanel: View {
    @ObservedObject var controller: NDBController
    @ObservedObject var settings: NDBSettingsStore
    @State private var freqText = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("FREQUENZ")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextField("vom Funkgerät", text: $freqText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 100)
                    .onSubmit { commit() }
                Text("kHz")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Button("ÜBERNEHMEN") { commit() }.buttonStyle(ModeButtonStyle(isSelected: false))
            }
            .help("Frequenz von Hand eintragen, wenn kein Funkgerät über rigctld verbunden ist; leer lassen, um sie vom Funkgerät zu lesen")
            HStack(spacing: 6) {
                Text("TON")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Button("AUTO") { settings.fixedToneHz = 0 }.buttonStyle(ModeButtonStyle(isSelected: settings.fixedToneHz == 0))
                    .help("Den Kennungston selbst suchen (250 bis 2400 Hz)")
                Button("400") { settings.fixedToneHz = 400 }.buttonStyle(ModeButtonStyle(isSelected: settings.fixedToneHz == 400))
                Button("1020") { settings.fixedToneHz = 1020 }.buttonStyle(ModeButtonStyle(isSelected: settings.fixedToneHz == 1020))
                Text(settings.fixedToneHz > 0 ? "\(Int(settings.fixedToneHz)) Hz fest" : "")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            HStack(spacing: 6) {
                Text("UMKREIS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach([150.0, 400.0, 800.0, 1500.0], id: \.self) { km in
                    Button("\(Int(km)) km") { settings.radiusKm = km }.buttonStyle(ModeButtonStyle(isSelected: settings.radiusKm == km))
                }
            }
            .help("Funkfeuer innerhalb dieser Entfernung vom Standort in Liste, Karte und Suchlauf")
            HStack(spacing: 6) {
                Text("VERWEILEN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                ForEach([20.0, 45.0, 70.0], id: \.self) { s in
                    Button("\(Int(s)) s") { settings.dwellSeconds = s }.buttonStyle(ModeButtonStyle(isSelected: settings.dwellSeconds == s))
                }
            }
            .help("Wartezeit je Frequenz im Suchlauf")
            HStack(spacing: 6) {
                Button(controller.isDownloading ? "LADE …" : "LISTE LADEN") { controller.downloadList() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(controller.isDownloading)
                    .help("Aktuelle Funkfeuer-Liste von ourairports.com laden (gemeinfrei) und lokal ablegen")
                Text(controller.downloadMessage ?? "\(controller.database.count) Funkfeuer\(controller.database.isDownloaded ? " (geladen)" : " (Europa)")")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .lineLimit(1)
            }
            Text("190–535 kHz AM/CW/USB · 2× bestätigte Kennung")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
                .help("Das Funkgerät auf die Frequenz eines Funkfeuers (190 bis 535 kHz) stellen, AM mit 2 bis 3 kHz Bandbreite (bei unmoduliertem Träger CW oder USB: der Überlagerungston ist dann der Kennungston). Die Kennung (zwei bis drei Buchstaben, Morse) wird erst als bestätigt gezeigt, wenn sie zweimal gleich gelesen wurde, und mit der Liste verglichen. Liste: OurAirports, Frequenzen auf ganze kHz gerundet.")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            freqText = settings.manualKHz > 0 ? String(format: "%.1f", settings.manualKHz).replacingOccurrences(of: ".", with: ",") : ""
        }
    }

    private func commit() {
        let v = Double(freqText.replacingOccurrences(of: ",", with: ".")) ?? 0
        settings.manualKHz = (v >= 100 && v <= 1800) ? v : 0
        if settings.manualKHz == 0 { freqText = "" }
    }
}

// MARK: - Karte

struct NDBMapView: View {
    @ObservedObject var controller: NDBController
    @ObservedObject var home: HomeLocation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            MapPanel(content: controller.mapContent(now: ctx.date), home: home, selection: $controller.selection,
                     legend: "Funkfeuer im Umkreis · grün/rot = gehört, hell = eingestellte Frequenz")
        }
    }
}
