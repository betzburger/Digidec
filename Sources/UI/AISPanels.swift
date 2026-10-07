// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Schiffsliste

struct AISMainPanel: View {
    @ObservedObject var controller: AISController
    @ObservedObject var settings: AISSettingsStore
    @ObservedObject var home: HomeLocation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                filterButton("SCHIFFE", on: $settings.showShips, help: "Schiffe und Boote (Klasse A und B) in Liste und Karte zeigen")
                filterButton("SEEZEICHEN", on: $settings.showAids, help: "Tonnen, Leuchttürme und andere Seezeichen mit AIS (Nachricht 21)")
                filterButton("STATIONEN", on: $settings.showBase, help: "Küstenstationen (AIS-Basisstationen, Nachricht 4)")
                filterButton("GEBIETE", on: $settings.showAreas, help: "Gebietsmeldungen der Verkehrszentralen: Sperrgebiete, Warnungen, Seenot, Hinweise (Binärtelegramm 1/22 und 1/23); in der Karte als Fläche oder Linie")
                Button {
                    controller.toggleRecording()
                } label: {
                    Label(controller.isRecording ? SondeMainPanel.duration(controller.recordingDuration) : "REC",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "waveform.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.isRecording))
                .foregroundColor(controller.isRecording ? RadioTheme.ledRed : nil)
                .help("Eingangssignal als WAV aufnehmen (Quell-Abtastrate): zur Fehlersuche, nachdecodierbar mit Tools/AISBench/ais_bench.sh. Ordner: ~/Documents/Digidec/Recordings")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Alle Meldungen als NMEA-Sätze (!AIVDM) in eine Tagesdatei schreiben, z. B. für OpenCPN: \(controller.logger.fileURL().path)")
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
                .help("Liste leeren (Log bleibt)")
            }
            AISTable(controller: controller, settings: settings, home: home, open: open)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
            AISDetail(controller: controller, home: home, open: open)
        }
    }

    private func filterButton(_ title: String, on: Binding<Bool>, help: String) -> some View {
        Button(title) { on.wrappedValue.toggle() }
            .buttonStyle(ModeButtonStyle(isSelected: on.wrappedValue))
            .help(help)
    }

    private func open(_ mmsi: UInt32) {
        controller.showInfo(for: mmsi)
        openWindow(id: "ship-info")
    }

    private var summary: String {
        if controller.ships.isEmpty { return "Warten auf AIS (\(settings.channel.label) MHz, FM)" }
        let moving = controller.ships.filter { $0.isMoving && $0.kind != .aid && $0.kind != .base }.count
        let ships = controller.ships.filter { $0.kind != .aid && $0.kind != .base }.count
        return "\(ships) Schiffe · \(moving) in Fahrt · \(controller.perMinute) Meldungen/min"
    }
}

struct AISTable: View {
    @ObservedObject var controller: AISController
    @ObservedObject var settings: AISSettingsStore
    @ObservedObject var home: HomeLocation
    let open: (UInt32) -> Void

    private var visible: [AISVessel] {
        controller.ships.filter { v in
            switch v.kind {
            case .aid: return settings.showAids
            case .base: return settings.showBase
            default: return settings.showShips
            }
        }
    }

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("").frame(width: 10)
                Text("Name").frame(width: 168, alignment: .leading)
                Text("MMSI").frame(width: 78, alignment: .leading)
                Text("Typ").frame(width: 78, alignment: .leading)
                Text("kn").frame(width: 34, alignment: .trailing)
                Text("Kurs").frame(width: 38, alignment: .trailing)
                Text("Länge").frame(width: 40, alignment: .trailing)
                Text("Ziel").frame(width: 112, alignment: .leading)
                Text("km").frame(width: 42, alignment: .trailing)
                Text("Peil.").frame(width: 38, alignment: .trailing)
                Text("vor").frame(width: 40, alignment: .trailing)
                Text("").frame(maxWidth: .infinity)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text("Noch kein AIS-Signal empfangen. Schiffe senden alle 2 bis 30 Sekunden (je nach Fahrt) auf 161,975 und 162,025 MHz; die Reichweite ist Sichtweite (typisch 20 bis 40 sm). Funkgerät oder SDR-Programm auf FM mit mindestens 15 kHz Bandbreite, Audio ohne Rauschsperre und ohne Sprachfilter, Ausgabe auf die virtuelle Soundkarte (VALHost).")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textMuted)
                            .padding(.top, 3)
                    }
                    ForEach(visible.prefix(400)) { v in row(v, now: now) }
                    if settings.showAreas && !controller.areas.isEmpty {
                        Text("GEBIETSMELDUNGEN (\(controller.areas.count))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(controller.areas.prefix(100)) { a in areaRow(a, now: now) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }


    private func areaRow(_ a: AISAreaNotice, now: Date) -> some View {
        let id = AISMapBuilder.areaID(a)
        let selected = controller.selection == id
        let color: Color = a.category == .distress || a.category == .restricted ? RadioTheme.ledRed : a.category == .environment ? Color(red: 0.45, green: 0.72, blue: 1.0) : RadioTheme.vfdAmber
        var km = ""
        if let p = a.points.first, let h = home.point { km = String(format: "%.0f km", Geo.distanceKm(h, p)) }
        return HStack(spacing: 8) {
            Image(systemName: a.category == .distress ? "lifepreserver.fill" : "exclamationmark.triangle.fill").font(.system(size: 9)).frame(width: 10)
            Text(a.title).fontWeight(.bold).lineLimit(1)
            if let t = a.displayText { Text(t).foregroundColor(RadioTheme.textMuted).lineLimit(1) }
            Spacer(minLength: 0)
            Text(km).foregroundColor(RadioTheme.textMuted)
            Text(AISFormat.age(max(0, now.timeIntervalSince(a.receivedAt)))).frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .padding(.vertical, 1)
        .background(selected ? color.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { controller.selection = selected ? nil : id }
        .help("Ein Klick wählt die Meldung (Karte zoomt hin und zeigt Einzelheiten)")
    }

    private func row(_ v: AISVessel, now: Date) -> some View {
        let id = AISMapBuilder.id(v.mmsi)
        let selected = controller.selection == id
        let age = max(0, now.timeIntervalSince(v.lastHeard))
        let distress = DigidecState.shared.distressCall(mmsi: v.mmsi)
        let color: Color = distress != nil ? RadioTheme.ledRed : age > 600 && v.kind != .aid && v.kind != .base ? RadioTheme.textMuted : v.kind == .sart ? RadioTheme.ledRed : v.isMoving ? RadioTheme.vfdGreen : RadioTheme.vfdCyan
        var km = "–", bearing = "–"
        if let p = v.point, let h = home.point {
            km = String(format: "%.1f", Geo.distanceKm(h, p)).replacingOccurrences(of: ".", with: ",")
            bearing = String(format: "%.0f°", Geo.bearing(from: h, to: p))
        }
        let flag = AISCountry.flag(ofMMSI: v.mmsi)
        let typeText: String
        switch v.kind {
        case .aid: typeText = v.meteo != nil ? "Wetter" : v.atonType.map { AISAtonType.text($0) } ?? "Seezeichen"
        case .base: typeText = v.meteo != nil ? "Wetter" : "Küstenstation"
        case .aircraft: typeText = "Flugzeug"
        case .sart: typeText = "NOTSENDER"
        default: typeText = v.shipType.map(AISShipType.short) ?? (v.kind == .shipB ? "Klasse B" : "?")
        }
        return HStack(spacing: 8) {
            Circle().fill(age < 5 ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                .frame(width: 8, height: 8).frame(width: 10)
            Text((distress != nil ? "⚠ SEENOT " : "") + (flag.isEmpty ? "" : flag + " ") + v.displayName).frame(width: 168, alignment: .leading).fontWeight(.bold).lineLimit(1)
                .help(distress.map { "DSC-Seenotruf von dieser MMSI gehört (\(DSCController.utc.string(from: $0.receivedAt)) UTC): \($0.summary)" } ?? "")
            Text(AISFormat.mmsiText(v.mmsi)).frame(width: 78, alignment: .leading)
            Text(typeText).frame(width: 78, alignment: .leading).lineLimit(1)
            Text(v.sog.map { AISFormat.decimal($0, 1) } ?? "–").frame(width: 34, alignment: .trailing)
            Text(v.cog.map { String(format: "%.0f°", $0) } ?? "–").frame(width: 38, alignment: .trailing)
            Text(v.length.map { "\($0)" } ?? "–").frame(width: 40, alignment: .trailing)
            Text(v.destination ?? v.meteo.map(\.summary) ?? v.waterLevels?.summary ?? v.inland.map { "ENI \($0.eni)" } ?? (v.navStatus.map { AISNavStatus.short($0) } ?? "–"))
                .frame(width: 112, alignment: .leading).lineLimit(1)
            Text(km).frame(width: 42, alignment: .trailing)
            Text(bearing).frame(width: 38, alignment: .trailing)
            Text(AISFormat.age(age)).frame(width: 40, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .padding(.vertical, 1)
        .background(selected ? color.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            controller.selection = id
            open(v.mmsi)
        }
        .onTapGesture { controller.selection = selected ? nil : id }
        .help("Ein Klick wählt das Schiff, ein Doppelklick öffnet das Fenster mit den Schiffsdaten")
    }
}

/// Gewähltes Schiff: Zusammenfassung und Knöpfe
struct AISDetail: View {
    @ObservedObject var controller: AISController
    @ObservedObject var home: HomeLocation
    let open: (UInt32) -> Void

    var body: some View {
        if let a = controller.selectedArea {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(AISMapBuilder.areaDetails(a, home: home.point, now: Date()).enumerated()), id: \.offset) { i, l in
                    Text(l)
                        .font(.system(size: i == 0 ? 12 : 10, weight: i == 0 ? .bold : .medium, design: .monospaced))
                        .foregroundColor(i == 0 ? RadioTheme.vfdAmber : RadioTheme.vfdGreen)
                        .lineLimit(2)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RadioTheme.bgDeep.opacity(0.5))
            .cornerRadius(6)
        } else if let v = controller.selectedVessel {
            let now = Date()
            let age = max(0, now.timeIntervalSince(v.lastHeard))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(AISCountry.flag(ofMMSI: v.mmsi) + " " + v.displayName)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Text(v.shipType.map(AISShipType.text) ?? v.kind.title)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                    Spacer()
                    Button {
                        open(v.mmsi)
                    } label: {
                        Label("SCHIFFSDATEN", systemImage: "info.circle")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Fenster mit Foto, Baujahr und technischen Daten aus dem Netz (Wikidata, Wikimedia Commons)")
                    if let p = v.point {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(format: "%.5f, %.5f", p.lat, p.lon), forType: .string)
                        } label: {
                            Label("KOORDINATEN", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                        .help("Position (Breite, Länge in Grad) in die Zwischenablage kopieren")
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(AISMapBuilder.details(v, home: home.point, age: age).enumerated()), id: \.offset) { _, l in
                        Text(l)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdGreen)
                            .lineLimit(1)
                    }
                }
            }
            .padding(6)
            .background(RadioTheme.bgDeep.opacity(0.5))
            .cornerRadius(6)
        }
    }
}

// MARK: - Abstimmanzeige

struct AISTuningPanel: View {
    @ObservedObject var controller: AISController
    @ObservedObject var settings: AISSettingsStore
    @ObservedObject var home: HomeLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("AIS")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("GMSK · 9600 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            if controller.channelInfo.count == 2 {
                ForEach(controller.channelInfo, id: \.letter) { c in
                    HStack(spacing: 6) {
                        Text("KANAL \(String(c.letter))")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .frame(width: 52, alignment: .leading)
                        PagerLevelBar(level: c.level)
                            .frame(height: 8)
                        Text("\(c.stats.frames)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(c.inputDB < AISDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.vfdCyan)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help("Signalpegel und Zahl der gelesenen Rahmen auf Kanal \(String(c.letter)) (\(c.letter == "A" ? "161,975" : "162,025") MHz)")
                }
            } else {
                PagerLevelBar(level: controller.level)
                    .frame(height: 8)
                    .help("Signalpegel des Datenstroms")
            }
            HStack {
                readout("KANAL", settings.channel.title)
                Spacer()
                readout("MELDUNGEN", "\(controller.messageCount)")
            }
            diagnosisView
        }
    }

    private var diagnosisView: some View {
        let d = controller.diagnosis
        let color: Color = d.severity == .ok ? RadioTheme.vfdGreen : d.severity == .waiting ? RadioTheme.vfdAmber : RadioTheme.ledRed
        let st = controller.stats
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
                    .foregroundColor(controller.inputDB < AISDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios (Vollaussteuerung = 0 dBFS). Brauchbar sind etwa −30 … −8 dBFS; bei Dauerrauschen höher.")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if st.bursts > 0 || st.frames > 0 {
                Text("Rahmen \(st.frames) · davon korrigiert \(st.rescued) · unlesbar \(st.failed)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .help("Rahmen: Prüfsumme (CRC-16) bestanden. Korrigiert: erst nach Anpassen von Takt, Schwelle oder Umkehren eines unsicheren Bits lesbar. Unlesbar: sicherer Burst-Anfang, aber kein gültiger Rahmen.")
            }
            if let f = controller.farthest {
                let name = controller.vessel(f.mmsi)?.displayName ?? AISFormat.mmsiText(f.mmsi)
                Text("Weitester Empfang: \(name) in \(Geo.formatKm(f.km)) (\(AISFormat.seaMiles(km: f.km)))")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(2)
            }
            if !controller.binaryCounts.isEmpty {
                Text("Binär: " + controller.binaryCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(2)
                    .help("Binärtelegramme (Typ 6 und 8) nach Gebietskennung/Funktion: 1/31 und 1/11 Wetter und Gewässer, 200/10 Binnenschiff, 200/24 Pegel, 1/17 Ziele der Verkehrszentrale, 1/29 und 1/30 Text")
            }
            if !controller.typeCounts.isEmpty {
                Text("Typen: " + controller.typeCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(3)
                    .help("Zahl der Meldungen je AIS-Nachrichtentyp: 1–3 Position Klasse A, 5 Stammdaten, 18/19 Klasse B, 24 Klasse-B-Stammdaten, 21 Seezeichen, 4 Küstenstation")
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

// MARK: - Einstellungen

struct AISSettingsPanel: View {
    @ObservedObject var settings: AISSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach([AISChannel.a, .b, .both]) { c in
                    Button { settings.channel = c } label: {
                        VStack(spacing: 1) {
                            Text(verbatim: c.title)
                            Text(verbatim: c.isDual ? "L = A · R = B" : c.label + " MHz").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.channel == c))
                    .help(c.detail + (c.isDual ? ". Zwei Empfänger im SDR-Programm, Kanal A ganz nach links, Kanal B ganz nach rechts (Pan/Balance); Eingang „L“ oder „R“ spielt keine Rolle." : ". Mit QSY AUTO stellt Digidec das Funkgerät über den Commander in FM auf diese Frequenz."))
                }
            }
            if settings.channel.isDual {
                HStack(spacing: 6) {
                    Button { settings.swapChannels.toggle() } label: {
                        Label(settings.swapChannels ? "LINKS B · RECHTS A" : "LINKS A · RECHTS B", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.swapChannels))
                    .help("Vertauscht die Zuordnung der Audiokanäle zu den AIS-Kanälen (Standard: links 161,975 MHz = A, rechts 162,025 MHz = B)")
                }
            }
            HStack(spacing: 6) {
                label("BEHALTEN")
                Stepper(value: $settings.keepMinutes, in: 5...1440, step: settings.keepMinutes < 60 ? 5 : 30) {
                    Text(settings.keepMinutes < 90 ? "\(Int(settings.keepMinutes)) min" : String(format: "%.1f h", settings.keepMinutes / 60).replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                .help("Wie lange ein Schiff nach seiner letzten Meldung in Liste und Karte bleibt (Seezeichen und Küstenstationen mindestens 6 Stunden)")
            }
            HStack(spacing: 6) {
                Button("INFO BEI KLICK") { settings.openInfoOnClick.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.openInfoOnClick))
                    .help("Ein Klick auf ein Schiff in der Karte öffnet das Fenster mit den Schiffsdaten")
                Button("NETZ-SUCHE") { settings.webLookup.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.webLookup))
                    .help("Beim Öffnen der Schiffsdaten automatisch im Netz suchen (Wikidata, Wikimedia Commons, Wikipedia). Dabei gehen MMSI, IMO-Nummer, Rufzeichen und Name des Schiffs an diese Dienste. Aus: erst auf Knopfdruck im Fenster.")
            }
            Text("Digidec liest das Diskriminator-Audio eines FM-Empfängers (SDR-Programm → VALHost oder Funkgerät). Zwei AIS-Kanäle gibt es: A+B hört beide zugleich (zwei Empfänger im SDR-Programm, A links, B rechts, bei einer Stereoquelle), sonst ein Kanal nach dem anderen. Einstellung im SDR-Programm: FM-Bandbreite 15 … 25 kHz, Audio mindestens 6 kHz breit, ohne De-Emphase, Rauschsperre offen. Antenne: Marine-Antenne oder 2-m-Antenne mit freier Sicht zum Wasser.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }
}

// MARK: - Fenster „Schiffsdaten“

@MainActor
final class ShipInfoModel: ObservableObject {
    @Published var info: ShipWebInfo?
    @Published var loading = false
    private var loadedKey: ShipQuery?

    func load(_ q: ShipQuery, force: Bool = false) {
        if !force, loadedKey == q, info != nil { return }
        loadedKey = q
        loading = true
        if !force { info = nil }
        Task {
            let result = await ShipInfoService.shared.lookup(q, useCache: !force)
            await MainActor.run {
                guard self.loadedKey == q else { return }
                self.info = result
                self.loading = false
            }
        }
    }

    func reset() {
        loadedKey = nil
        info = nil
        loading = false
    }
}

struct ShipInfoWindow: View {
    @ObservedObject var controller: AISController
    @ObservedObject var settings: AISSettingsStore
    @ObservedObject var home: HomeLocation
    @StateObject private var model = ShipInfoModel()

    var body: some View {
        ZStack {
            RadioTheme.bgPanel.ignoresSafeArea()
            if let mmsi = controller.infoMMSI, let v = controller.vessel(mmsi) {
                content(v)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "ferry").font(.system(size: 34)).foregroundColor(RadioTheme.textDim)
                    Text(controller.infoMMSI == nil ? "Ein Schiff in der Karte oder Liste anklicken." : "Das Schiff ist nicht mehr in der Liste.")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    /// Nur Schiffe werden im Netz gesucht, nicht Seezeichen, Küstenstationen und Notsender
    private static func isShip(_ v: AISVessel) -> Bool {
        v.kind == .shipA || v.kind == .shipB || v.kind == .craft
    }

    private func query(_ v: AISVessel) -> ShipQuery {
        ShipQuery(mmsi: v.mmsi, imo: v.imo, callsign: v.callsign, name: v.name)
    }

    @ViewBuilder
    private func content(_ v: AISVessel) -> some View {
        let q = query(v)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(v)
                if Self.isShip(v) { photo(v) }
                if let e = model.info?.extract {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(RadioTheme.textBright)
                            .fixedSize(horizontal: false, vertical: true)
                        if let s = model.info?.extractSource {
                            Text(s).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RadioTheme.bgDeep.opacity(0.6))
                    .cornerRadius(6)
                }
                if Self.isShip(v) { webFacts }
                aisFacts(v)
                binaryFacts(v)
                if Self.isShip(v) { links(q) }
                if Self.isShip(v) { footer(q) }
            }
            .padding(14)
        }
        .task(id: q) {
            if settings.webLookup && Self.isShip(v) { model.load(q) } else { model.reset() }
        }
    }

    // MARK: Kopf und Foto

    private func header(_ v: AISVessel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AISCountry.flag(ofMMSI: v.mmsi)).font(.system(size: 26))
                Text(v.displayName)
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .lineLimit(2)
            }
            Text([v.shipType.map(AISShipType.text) ?? v.kind.title, AISCountry.name(ofMMSI: v.mmsi)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
            HStack(spacing: 6) {
                chip("MMSI " + AISFormat.mmsiText(v.mmsi))
                if let i = v.imo { chip("IMO \(i)") }
                if let c = v.callsign { chip(c) }
            }
        }
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.vfdAmber)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RadioTheme.borderSubtle, lineWidth: 1))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func photo(_ v: AISVessel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(RadioTheme.bgDeep)
                if let s = model.info?.imageURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .failure: placeholder("Foto konnte nicht geladen werden")
                        default: ProgressView().controlSize(.small)
                        }
                    }
                } else if model.loading {
                    ProgressView("Suche im Netz …").controlSize(.small).font(.system(size: 10, design: .monospaced))
                } else {
                    placeholder(settings.webLookup ? "Kein Foto gefunden" : "Netz-Suche ist aus")
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RadioTheme.borderSubtle, lineWidth: 1))
            if let credit = model.info?.imageCredit ?? model.info?.imageSource, model.info?.imageURL != nil {
                HStack(spacing: 4) {
                    Text("Foto: \(credit)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .lineLimit(2)
                    if let p = model.info?.imagePageURL, let u = URL(string: p) {
                        Link("Quelle", destination: u).font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "ferry.fill").font(.system(size: 40)).foregroundColor(RadioTheme.textDim)
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
        }
    }

    // MARK: Daten

    @ViewBuilder
    private var webFacts: some View {
        if let info = model.info, !info.facts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("AUS DEM NETZ" + (info.title.map { " · " + $0 } ?? ""))
                if let desc = info.summary {
                    Text(desc).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
                }
                if let how = info.matchedBy, how.contains("unsicher") {
                    Text("Gefunden über den Namen – kann ein anderes Schiff gleichen Namens sein.")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.ledYellow)
                }
                table(info.facts.map { ($0.label, $0.value) })
                HStack(spacing: 10) {
                    if let w = info.wikidataURL, let u = URL(string: w) { Link("Wikidata", destination: u) }
                    if let w = info.wikipediaURL, let u = URL(string: w) { Link("Wikipedia", destination: u) }
                    Text("Gefunden über: \(info.matchedBy ?? "–")").foregroundColor(RadioTheme.textDim)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
        } else if model.loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Suche in Wikidata und Wikimedia Commons …").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
            }
        } else if let info = model.info {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle("AUS DEM NETZ")
                ForEach(info.notes, id: \.self) { n in
                    Text(n).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Text("Wikidata kennt vor allem große Handelsschiffe, Fähren, Kreuzfahrt- und Museumsschiffe. Mehr steht in den Datenbanken unten.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !settings.webLookup {
            Button("IM NETZ SUCHEN") { if let id = controller.infoMMSI, let v = controller.vessel(id) { model.load(query(v)) } }
                .buttonStyle(ModeButtonStyle(isSelected: false))
        }
    }

    private func aisFacts(_ v: AISVessel) -> some View {
        var rows: [(String, String)] = []
        if v.kind == .aid {
            if let t = v.atonType { rows.append(("Art", AISAtonType.text(t) + (v.offPosition ? " (außer Position!)" : ""))) }
        } else {
            if let t = v.shipType { rows.append(("Schiffstyp (AIS)", AISShipType.text(t))) }
            if let l = v.length { rows.append(("Länge · Breite", "\(l) m" + (v.beam.map { " · \($0) m" } ?? ""))) }
            if let d = v.draught { rows.append(("Tiefgang", AISFormat.decimal(d) + " m")) }
        }
        if let n = v.navStatus, v.kind == .shipA { rows.append(("Status", AISNavStatus.text(n))) }
        if let s = v.sog { rows.append(("Fahrt", AISFormat.decimal(s) + " kn" + (v.cog.map { " · Kurs \(Int($0.rounded()))°" } ?? "") + (v.heading.map { " · Steven \($0)°" } ?? ""))) }
        if let d = v.destination { rows.append(("Ziel", d + (v.etaText.map { " · ETA \($0)" } ?? ""))) }
        if let p = v.point { rows.append(("Position", Geo.format(p))) }
        if let p = v.point, let h = home.point {
            let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
            rows.append(("Entfernung", "\(Geo.formatKm(km)) · \(AISFormat.seaMiles(km: km)) · \(Geo.compass(b)) \(Int(b.rounded()))°"))
        }
        if let m = v.motherMMSI { rows.append(("Mutterschiff", AISFormat.mmsiText(m))) }
        if let t = v.lastText { rows.append(("Letzter Text", t)) }
        rows.append(("Empfang", "\(v.messages) Meldungen · seit \(Self.time.string(from: v.firstHeard)) · zuletzt \(Self.time.string(from: v.lastHeard))"))
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("AUS DEM AIS-SIGNAL (LIVE)")
            table(rows)
        }
    }


    /// Telegramme mit Wetter, Binnenschiff-Daten, Pegelständen und Warnungen
    private func binaryRows(_ v: AISVessel) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let w = v.meteo {
            if let d = w.day, let h = w.hour, let m = w.minute { rows.append(("Messung", String(format: "Tag %d, %02d:%02d UTC", d, h, m))) }
            for (i, l) in w.lines.enumerated() { rows.append((i == 0 ? "Wetter · Gewässer" : "", l)) }
        }
        if let i = v.inland {
            rows.append(("Binnenschiff", "ENI \(i.eni) (europäische Schiffsnummer)"))
            rows.append(("Fahrzeugart", i.shipTypeText))
            if let l = i.length { rows.append(("Länge · Breite", String(format: "%.1f m", l).replacingOccurrences(of: ".", with: ",") + (i.beam.map { String(format: " · %.1f m", $0).replacingOccurrences(of: ".", with: ",") } ?? ""))) }
            if let h = i.hazardText { rows.append(("Gefahrgut", h)) }
            if let l = i.loadedText { rows.append(("Ladung", l)) }
            if let d = i.draught { rows.append(("Tiefgang", String(format: "%.2f m", d).replacingOccurrences(of: ".", with: ","))) }
        }
        if let w = v.waterLevels { rows.append(("Pegel (" + w.country + ")", w.summary)) }
        if let e = v.emma { rows.append(("Warnung", e.text)) }
        if let s = v.trafficSignal { for (i, l) in s.lines.enumerated() { rows.append((i == 0 ? "Signalstelle" : "", l)) } }
        if let m = v.monitoring { for (i, l) in m.lines.enumerated() { rows.append((i == 0 ? "Überwachung" : "", l)) } }
        if let e = v.extended { for (i, l) in e.lines.enumerated() { rows.append((i == 0 ? "Reisedaten (erweitert)" : "", l)) } }
        if let p = v.persons { rows.append(("Personen", p.text)) }
        if let o = v.otherBinary { rows.append(("Binärtelegramm", o + " (nicht ausgewertet)")) }
        return rows
    }

    @ViewBuilder
    private func binaryFacts(_ v: AISVessel) -> some View {
        let rows = binaryRows(v)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("BINÄRTELEGRAMME")
                table(rows)
            }
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func table(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.0)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .frame(width: 130, alignment: .leading)
                    Text(r.1)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgDeep.opacity(0.6))
        .cornerRadius(6)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .tracking(1.2)
    }

    // MARK: Verweise und Fuß

    private func links(_ q: ShipQuery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("MEHR IM NETZ (IM BROWSER)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(ShipLinks.links(for: q)) { l in
                    Button {
                        NSWorkspace.shared.open(l.url)
                    } label: {
                        Label(l.title, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help(l.detail + " – öffnet " + (l.url.host ?? ""))
                }
            }
        }
    }

    private func footer(_ q: ShipQuery) -> some View {
        HStack(spacing: 8) {
            Button {
                model.load(q, force: true)
            } label: {
                Label("NEU ABFRAGEN", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
            .disabled(model.loading)
            .help("Zwischenspeicher übergehen und Wikidata und Wikimedia Commons neu fragen")
            Text("Daten: Wikidata (CC0), Fotos: Wikimedia Commons (Lizenz siehe Foto), Texte: Wikipedia (CC BY-SA). Abfrage nur mit MMSI, IMO, Rufzeichen und Name.")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
