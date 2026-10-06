// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Sonden: Liste und Einzelheiten

struct SondeMainPanel: View {
    @ObservedObject var controller: SondeController
    @ObservedObject var settings: SondeSettingsStore
    @ObservedObject var home: HomeLocation

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.toggleRecording()
                } label: {
                    Label(controller.isRecording ? Self.duration(controller.recordingDuration) : "REC",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "waveform.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.isRecording))
                .foregroundColor(controller.isRecording ? RadioTheme.ledRed : nil)
                .help("Eingangssignal als WAV aufnehmen (Quell-Abtastrate): zur Fehlersuche, später mit decode_file.sh --sonde nachdecodierbar. Ordner: ~/Documents/Digidec/Recordings")
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Flugdaten in Tagesdatei schreiben (CSV: Zeit, Seriennummer, Rahmen, Position, Höhe, Geschwindigkeit, Messwerte): \(controller.logger.fileURL().path)")
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
            SondeTable(controller: controller, home: home)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
            SondeDetail(controller: controller, home: home)
        }
    }

    private var summary: String {
        if controller.flights.isEmpty { return "Warten auf Sonden (\(settings.frequencyText), FM \(settings.filterKHz) kHz)" }
        let air = controller.flights.filter { [.ascent, .descent].contains($0.phase(now: Date())) }.count
        return "\(controller.flights.count) Sonden · \(air) in der Luft · \(controller.stats.frames) Rahmen"
    }

    static func duration(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct SondeTable: View {
    @ObservedObject var controller: SondeController
    @ObservedObject var home: HomeLocation

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("").frame(width: 10)
                Text("Sonde").frame(width: 84, alignment: .leading)
                Text("Phase").frame(width: 70, alignment: .leading)
                Text("Höhe m").frame(width: 58, alignment: .trailing)
                Text("m/s").frame(width: 42, alignment: .trailing)
                Text("km").frame(width: 46, alignment: .trailing)
                Text("Peil.").frame(width: 38, alignment: .trailing)
                Text("°C").frame(width: 42, alignment: .trailing)
                Text("%rF").frame(width: 34, alignment: .trailing)
                Text("MHz").frame(width: 62, alignment: .trailing)
                Text("vor").frame(width: 44, alignment: .trailing)
                Text("").frame(maxWidth: .infinity)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if controller.flights.isEmpty {
                        Text("Noch keine Sonde empfangen. Radiosonden senden zwischen 400 und 406 MHz jede Sekunde ein Telegramm; sie starten meist gegen 11 und 23 UTC (zwei Termine vor 00 und 12 UTC). Funkgerät auf FM mit 15-kHz-Filter, Rauschsperre offen.")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textMuted)
                            .padding(.top, 3)
                    }
                    ForEach(controller.flights) { f in row(f, now: now) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private func row(_ f: SondeFlight, now: Date) -> some View {
        let selected = controller.selection == f.serial
        let age = max(0, now.timeIntervalSince(f.lastHeard))
        let phase = f.phase(now: now)
        let color: Color = age > 600 ? RadioTheme.textMuted : phase == .descent ? RadioTheme.vfdAmber : phase == .ascent ? RadioTheme.vfdGreen : RadioTheme.vfdCyan
        var km = "–", bearing = "–"
        if let p = f.point, let h = home.point {
            km = String(format: "%.0f", Geo.distanceKm(h, p))
            bearing = String(format: "%.0f°", Geo.bearing(from: h, to: p))
        }
        return HStack(spacing: 8) {
            Circle().fill(age < 5 ? RadioTheme.vfdGreen : RadioTheme.bgPanel)
                .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                .frame(width: 8, height: 8).frame(width: 10)
            Text(f.serial).frame(width: 84, alignment: .leading).fontWeight(.bold)
            Text(phase.label).frame(width: 70, alignment: .leading)
            Text(f.latest.altitude.map { String(format: "%.0f", $0) } ?? "–").frame(width: 58, alignment: .trailing)
            Text(f.latest.climb.map { String(format: "%+.1f", $0).replacingOccurrences(of: ".", with: ",") } ?? "–").frame(width: 42, alignment: .trailing)
            Text(km).frame(width: 46, alignment: .trailing)
            Text(bearing).frame(width: 38, alignment: .trailing)
            Text(f.latest.temperature.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") } ?? "–").frame(width: 42, alignment: .trailing)
            Text(f.latest.humidity.map { String(format: "%.0f", $0) } ?? "–").frame(width: 34, alignment: .trailing)
            Text(f.frequencyKHz.map { String(format: "%.3f", Double($0) / 1000).replacingOccurrences(of: ".", with: ",") } ?? "–").frame(width: 62, alignment: .trailing)
            Text(SondeMapBuilder.ageText(age)).frame(width: 44, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .padding(.vertical, 1)
        .background(selected ? color.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { controller.selection = selected ? nil : f.serial }
    }
}

/// Gewählte Sonde: alle Messwerte, Wegpunkte, Höhenverlauf; Koordinaten zum Weitergeben
struct SondeDetail: View {
    @ObservedObject var controller: SondeController
    @ObservedObject var home: HomeLocation

    var body: some View {
        if let id = controller.selection, let f = controller.flights.first(where: { $0.serial == id }) {
            let now = Date()
            let phase = f.phase(now: now)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(f.serial)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Text((f.model ?? "RS41") + " · " + phase.label)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                    Spacer()
                    if let p = f.point {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(format: "%.5f, %.5f", p.lat, p.lon), forType: .string)
                        } label: {
                            Label("KOORDINATEN", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                        .help("Position der Sonde (Breite, Länge in Grad) in die Zwischenablage kopieren")
                        Button {
                            if let url = URL(string: String(format: "https://maps.apple.com/?ll=%.5f,%.5f&q=Sonde%%20%@", p.lat, p.lon, f.serial)) { NSWorkspace.shared.open(url) }
                        } label: {
                            Label("KARTEN", systemImage: "map")
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                        .help("Position in der Karten-App öffnen (für die Anfahrt)")
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines(f, now: now, phase: phase).enumerated()), id: \.offset) { _, l in
                            Text(l)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.vfdGreen)
                        }
                    }
                    SondeProfile(track: f.track)
                        .frame(height: 74)
                        .frame(maxWidth: .infinity)
                        .background(RadioTheme.bgDeep)
                        .cornerRadius(5)
                        .help("Höhe über der Zeit")
                }
            }
            .padding(6)
            .background(RadioTheme.bgDeep.opacity(0.5))
            .cornerRadius(6)
        }
    }

    private func lines(_ f: SondeFlight, now: Date, phase: SondePhase) -> [String] {
        func n(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0).replacingOccurrences(of: ".", with: ",") } ?? "–" }
        var out: [String] = []
        if let p = f.point { out.append(Geo.format(p)) }
        out.append("Höhe \(n(f.latest.altitude, "%.0f")) m · höchste \(n(f.maxAltitude > -999 ? f.maxAltitude : nil, "%.0f")) m")
        out.append("\((f.latest.climb ?? 0) >= 0 ? "Steigen" : "Sinken") \(n(f.latest.climb.map { abs($0) }, "%.1f")) m/s · Wind \(n(f.latest.speed.map { $0 * 3.6 }, "%.0f")) km/h")
        if let p = f.point, let h = home.point {
            var s = "\(Geo.formatKm(Geo.distanceKm(h, p))) \(Geo.compass(Geo.bearing(from: h, to: p))) (\(Int(Geo.bearing(from: h, to: p).rounded()))°)"
            if phase == .ascent || phase == .descent, let a = f.latest.altitude {
                s += String(format: " · Elev. etwa %.1f°", SondeMapBuilder.elevation(from: h, to: p, altitude: a, homeAltitude: f.launchAltitude ?? 0)).replacingOccurrences(of: ".", with: ",")
            }
            out.append(s)
        }
        out.append("T \(n(f.latest.temperature, "%.1f")) °C · rF \(n(f.latest.humidity, "%.0f")) % · P \(n(f.latest.pressure, "%.1f")) hPa")
        out.append("Batterie \(n(f.latest.battery, "%.1f")) V · Satelliten \(f.latest.satellites.map(String.init) ?? "–") · \(f.frames) Rahmen")
        if let land = SondeLanding.predict(f, now: now) {
            var s = "Landung etwa in \(Int((land.seconds / 60).rounded())) min bei \(Geo.format(land.point))"
            if let h = home.point { s += " · \(Geo.formatKm(Geo.distanceKm(h, land.point))) \(Geo.compass(Geo.bearing(from: h, to: land.point)))" }
            out.append(s)
        }
        if f.hasBurst { out.append("Ballon geplatzt in \(n(f.maxAltitude, "%.0f")) m") }
        if let kc = f.latest.killCountdown { out.append("Abschaltzähler \(kc / 60) min") }
        return out
    }
}

/// Höhe über der Zeit
struct SondeProfile: View {
    let track: [SondeFix]

    var body: some View {
        Canvas { ctx, size in
            guard track.count > 2, let t0 = track.first?.time, let t1 = track.last?.time, t1 > t0 else { return }
            let alts = track.map(\.altitude)
            let lo = alts.min() ?? 0, hi = max(alts.max() ?? 1, lo + 100)
            let span = t1.timeIntervalSince(t0)
            var path = Path()
            let stride = max(1, track.count / 400)
            for (i, fix) in track.enumerated() where i % stride == 0 || i == track.count - 1 {
                let x = 4 + (size.width - 8) * CGFloat(fix.time.timeIntervalSince(t0) / span)
                let y = size.height - 4 - (size.height - 8) * CGFloat((fix.altitude - lo) / (hi - lo))
                if path.isEmpty { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(RadioTheme.vfdCyan), lineWidth: 1.5)
            ctx.draw(Text(String(format: "%.0f m", hi)).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim),
                     at: CGPoint(x: 6, y: 7), anchor: .leading)
        }
    }
}

// MARK: - Sonden: Abstimmanzeige und Einstellungen

struct SondeTuningPanel: View {
    @ObservedObject var controller: SondeController
    @ObservedObject var settings: SondeSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SONDE")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("RS41 · 4800 Bd")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            PagerLevelBar(level: controller.level)
                .frame(height: 8)
                .help("Signalpegel des Datenstroms")
            HStack {
                readout("FREQUENZ", settings.frequencyText)
                Spacer()
                readout("RAHMEN", "\(controller.stats.frames)")
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
                    .foregroundColor(controller.inputDB < SondeDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
                    .help("Effektivpegel des Audios (Vollaussteuerung = 0 dBFS). Brauchbar sind etwa −40 … −10 dBFS.")
            }
            if !d.advice.isEmpty {
                Text(d.advice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if st.headers > 0 {
                Text("Rahmen \(st.frames) · Teile \(st.partial) · verloren \(st.failed) · korrigierte Bytes \(st.corrected)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .help("Rahmen: Reed-Solomon-Prüfung bestanden. Teile: Prüfung gescheitert, aber Datenblöcke mit gültiger Prüfsumme. Verloren: sicherer Rahmenkopf, aber kein lesbarer Rahmen.")
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

struct SondeSettingsPanel: View {
    @ObservedObject var controller: SondeController
    @ObservedObject var settings: SondeSettingsStore
    @ObservedObject var home: HomeLocation
    @ObservedObject var plan: SondePlanStore
    @ObservedObject var scanner: SondeScanner
    @State private var text = ""
    @FocusState private var editing: Bool

    private struct Station: Identifiable {
        let ranked: SondePlan.Ranked
        let kHz: Int
        var id: String { ranked.id }
    }

    /// RS41-Startorte im Umkreis mit bekannter Frequenz, nächste zuerst (Frequenz: eigene Wahl vor Eintrag der Liste)
    private var stations: [Station] {
        guard let point = home.point else { return [] }
        var out: [Station] = []
        for r in SondePlan.nearby(plan.sites, home: point, radiusKm: Double(plan.radiusKm)) {
            if let kHz = plan.frequencyKHz(for: r.site) { out.append(Station(ranked: r, kHz: kHz)) }
            if out.count >= 12 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stationButtons
            scanSection
            Text("FREQUENZ")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            HStack(spacing: 4) {
                step("−100", -100)
                step("−10", -10)
                TextField("403,000", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 4)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(4)
                    .focused($editing)
                    .onSubmit { commit() }
                    .help("Frequenz in MHz (400 … 406), Eingabe mit Return bestätigen. Sonden senden im Raster von 10 kHz.")
                step("+10", 10)
                step("+100", 100)
            }
            if !controller.heardFrequencies.isEmpty {
                HStack(spacing: 4) {
                    Text("GEHÖRT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    ForEach(controller.heardFrequencies, id: \.self) { f in
                        Button(String(format: "%.3f", Double(f) / 1000).replacingOccurrences(of: ".", with: ",")) { settings.frequencyKHz = f }
                            .buttonStyle(ModeButtonStyle(isSelected: settings.frequencyKHz == f))
                    }
                }
            }
            HStack(spacing: 6) {
                label("FILTER")
                ForEach([15, 50], id: \.self) { w in
                    Button("\(w) kHz") { settings.filterKHz = w }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.filterKHz == w))
                        .help(w == 15 ? "Schmaler ZF-Filter: weniger Rauschen, empfohlen für RS41" : "Breiter Filter: unempfindlicher, verträgt aber eine Sonde, die um mehrere kHz neben der Frequenz liegt")
                }
            }
            HStack(spacing: 6) {
                label("BEHALTEN")
                Stepper(value: $settings.keepHours, in: 1...48, step: 1) {
                    Text("\(Int(settings.keepHours)) h")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                .help("Wie lange eine Sonde nach ihrem letzten Rahmen in der Liste und auf der Karte bleibt")
            }
            Text("Das Funkgerät steht in FM (nicht USB) auf der Sondenfrequenz; QSY AUTO stellt Frequenz und Filter ein. Der Decoder liest das Diskriminator-Audio (die 4800-Baud-Töne) und kommt auch mit De-Emphase, Hochpass und Sprachband zurecht. Eine Antenne für 70 cm genügt; in Flughöhe reicht die Sichtverbindung über mehrere hundert Kilometer.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
        .onAppear { text = Self.display(settings.frequencyKHz) }
        .onChange(of: settings.frequencyKHz) { _, v in if !editing { text = Self.display(v) } }
    }

    /// Tasten mit den Startorten der Umgebung und ihrer Frequenz: ein Klick stellt Digidec (und mit QSY AUTO das Funkgerät über den Commander) um
    @ViewBuilder
    private var stationButtons: some View {
        let list = stations
        label("STATIONEN")
        if list.isEmpty {
            Text(plan.sites.isEmpty ? "Keine Startortliste – im Sendeplan (Reiter SONDE) AKTUALISIEREN."
                                    : "Keine Station mit bekannter Frequenz im Umkreis von \(plan.radiusKm) km.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2), spacing: 4) {
                ForEach(list) { s in
                    Button { settings.frequencyKHz = s.kHz } label: {
                        VStack(spacing: 1) {
                            Text(verbatim: s.ranked.site.shortName)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(verbatim: Self.mhz(s.kHz))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)
                        }
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.frequencyKHz == s.kHz))
                    .help("\(s.ranked.site.name) · \(Geo.formatKm(s.ranked.km)) \(Geo.compass(s.ranked.bearing)) · \(SondeSettingsStore.text(s.kHz))\nStellt die Sondenfrequenz ein; mit QSY AUTO folgt das Funkgerät über den Commander.")
                }
            }
        }
    }

    /// Suchlauf: Funkgerät Frequenz für Frequenz abstimmen, bis ein Rahmen lesbar ist (braucht QSY AUTO)
    @ViewBuilder
    private var scanSection: some View {
        HStack(spacing: 6) {
            label("SUCHLAUF")
            if scanner.isScanning {
                Button {
                    scanner.stop()
                } label: {
                    Label("STOP \(scanner.done + 1)/\(scanner.total)", systemImage: "stop.circle.fill")
                }
                .buttonStyle(ModeButtonStyle(isSelected: true))
                .foregroundColor(RadioTheme.ledRed)
                .help("Suchlauf abbrechen; die vorherige Frequenz wird wieder eingestellt")
            } else {
                Button("BEKANNTE") { scanner.start(.known) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Frequenzen der Startorte in der Umgebung und schon gehörte durchsuchen (etwa \(scanner.estimatedMinutes(.known)) min). Braucht QSY AUTO und die Verbindung zum Commander.")
                Button("BAND") { scanner.start(.band) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Ganzes Sondenband 400 … 406 MHz durchsuchen (etwa \(scanner.estimatedMinutes(.band)) min). Braucht QSY AUTO und die Verbindung zum Commander.")
            }
        }
        if let m = scanner.message, scanner.status != .idle {
            Text(m)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(scanColor)
                .lineLimit(2)
        }
    }

    private var scanColor: Color {
        switch scanner.status {
        case .idle: return RadioTheme.textDim
        case .scanning: return RadioTheme.vfdAmber
        case .found: return RadioTheme.vfdGreen
        case .notFound, .failed: return RadioTheme.ledYellow
        }
    }

    private static func mhz(_ kHz: Int) -> String {
        String(format: "%.3f", Double(kHz) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    private func commit() {
        if let v = SondeSettingsStore.parse(text) { settings.frequencyKHz = v }
        text = Self.display(settings.frequencyKHz)
    }

    private func step(_ title: String, _ delta: Int) -> some View {
        Button(title) {
            let v = settings.frequencyKHz + delta
            if SondeSettingsStore.frequencyRange.contains(v) { settings.frequencyKHz = v }
        }
        .buttonStyle(ModeButtonStyle(isSelected: false))
        .help("Frequenz um \(abs(delta)) kHz \(delta < 0 ? "senken" : "erhöhen")")
    }

    private static func display(_ kHz: Int) -> String {
        String(format: "%.3f", Double(kHz) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }
}
