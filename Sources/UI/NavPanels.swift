// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

private let navHeaderFont = Font.system(size: 9, weight: .bold, design: .monospaced)

// MARK: - Hauptbereich: Messwerte

struct NavMainPanel: View {
    @ObservedObject var controller: NavController
    @ObservedObject var settings: NavSettingsStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(statusLine)
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
                .help("Eingangssignal als WAV aufnehmen (Quell-Abtastrate): zur Fehlersuche und Eichung. Ordner: ~/Documents/Digidec/Recordings")
                Button { controller.logEnabled.toggle() } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Kennungen und alle 30 s die Messwerte in die Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    let target = controller.lastRecording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? controller.logger.fileURL()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: { Image(systemName: "folder") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Letzte Aufnahme (sonst die Log-Datei) im Finder zeigen")
                Button { controller.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Verlauf leeren")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch controller.mode {
                    case .vor: vorBlock
                    case .ils: ilsBlock
                    case .none: waitingBlock
                    }
                    identBlock
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
    }

    private var statusLine: String {
        switch controller.mode {
        case .vor: return "VOR · Peilung \(NavFormat.bearingText(controller.bearing ?? 0))" + (controller.ident.isEmpty ? "" : " · \(controller.ident)")
        case .ils: return "ILS \(settings.ilsKind.title) · DDM \(String(format: "%+.3f", controller.ils?.ddm ?? 0))" + (controller.ident.isEmpty ? "" : " · \(controller.ident)")
        case .none: return "Warten auf VOR oder ILS (AM-Audio, 48 kHz)"
        }
    }

    private var vorBlock: some View {
        let v = controller.vor
        let bearing = controller.bearing ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RADIAL (VON DER STATION)").font(navHeaderFont).foregroundColor(RadioTheme.textDim)
                    Text(NavFormat.bearingText(bearing))
                        .font(.system(size: 44, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("KURS ZUR STATION").font(navHeaderFont).foregroundColor(RadioTheme.textDim)
                    Text(NavFormat.bearingText((bearing + 180).truncatingRemainder(dividingBy: 360)))
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                Spacer()
            }
            HStack(spacing: 22) {
                readout("HUB", String(format: "%.0f Hz", v?.deviationHz ?? 0), help: "Frequenzhub des 9960-Hz-Hilfsträgers (Soll 480 Hz)")
                readout("KOHÄRENZ", String(format: "%.2f", v?.coherence ?? 0), help: "Gleichmäßigkeit des Phasenunterschieds über eine Sekunde (1 = stabil)")
                readout("30 HZ", String(format: "%.1f %%", (v?.variableLevel ?? 0) * 100), help: "Amplitude des variablen 30-Hz-Tons im Audio (Vollaussteuerung = 100 %)")
                readout("HILFSTRÄGER", String(format: "%.0f dB", v?.subcarrierDB ?? 0), help: "Leistung des 9960-Hz-Hilfsträgers (gefiltert)")
                readout("ROH", NavFormat.bearingText(v?.bearing ?? 0), help: "Gemessener Winkel vor der Eichung")
            }
            if abs(settings.bearingOffset) > 0.05 {
                Text("Eichung \(String(format: "%+.1f", settings.bearingOffset).replacingOccurrences(of: ".", with: ","))° aktiv")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            } else {
                Text("Ungeeicht: die Empfangskette (Filter im SDR-Programm) und die Stationsausrichtung verschieben den Winkel. Auf einem bekannten Radial EICHEN drücken.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
    }

    private var ilsBlock: some View {
        let i = controller.ils
        let ddm = i?.ddm ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DDM (90 − 150 HZ)").font(navHeaderFont).foregroundColor(RadioTheme.textDim)
                    Text(String(format: "%+.3f", ddm).replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 44, weight: .black, design: .monospaced))
                        .foregroundColor(abs(ddm) < 0.0025 ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ABLAGE").font(navHeaderFont).foregroundColor(RadioTheme.textDim)
                    Text(String(format: "%+.1f", controller.ilsDeflection * 2.5).replacingOccurrences(of: ".", with: ",") + " Punkte")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                Spacer()
            }
            Text(NavFormat.ilsAdvice(ddm: ddm, kind: settings.ilsKind))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdGreen)
            HStack(spacing: 22) {
                readout("90 HZ", String(format: "%.2f", (i?.level90 ?? 0) * 100), help: "Amplitude des 90-Hz-Tons im Audio (Vollaussteuerung = 100)")
                readout("150 HZ", String(format: "%.2f", (i?.level150 ?? 0) * 100), help: "Amplitude des 150-Hz-Tons im Audio (Vollaussteuerung = 100)")
                readout("SUMME", String(format: "%.2f", (i?.depth ?? 0) * 100), help: "Beide Töne zusammen entsprechen 40 % Modulation (Soll)")
            }
            Text("Der DDM ist aus dem Verhältnis der beiden Töne gerechnet und bezieht sich auf 40 % Gesamtmodulation. Der AGC des SDR-Programms ändert das Verhältnis nicht. 2,5 Punkte = Vollausschlag (\(String(format: "%.3f", settings.ilsKind.fullScaleDDM).replacingOccurrences(of: ".", with: ",")) DDM).")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private var waitingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Warten auf VOR oder ILS")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text("Im SDR-Programm die Frequenz einer VOR-Station (108 bis 117,95 MHz), eines Landekurssenders (108,1 bis 111,95 MHz, ungerade Zehntel) oder eines Gleitwegsenders (328,6 bis 335,4 MHz) einstellen, Betriebsart AM, Bandbreite mindestens 25 kHz, Audio 48 kHz an Digidec.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private var identBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().background(RadioTheme.borderSubtle)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("KENNUNG").font(navHeaderFont).foregroundColor(RadioTheme.textDim)
                Text(controller.ident.isEmpty ? "–" : controller.ident)
                    .font(.system(size: 26, weight: .black, design: .monospaced))
                    .foregroundColor(controller.identConfirmed ? RadioTheme.vfdGreen : RadioTheme.vfdAmber)
                    .help(controller.identConfirmed ? "Zweimal gleich gelesen" : "Einmal gelesen, noch nicht bestätigt")
                if !controller.ident.isEmpty {
                    Text(controller.identConfirmed ? "bestätigt" : "noch nicht bestätigt")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                }
                Spacer()
                Text(controller.identHistory.suffix(6).reversed().joined(separator: "  "))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            Text("Die Kennung (Morse, 1020 Hz) kommt etwa alle 30 Sekunden. Ein VOR sendet drei Buchstaben, ein ILS ein „I“ mit drei Buchstaben.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private func readout(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(label)).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
        }
        .help(help)
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Empfang (statt Wasserfall): Kompass, Verlauf, Ablage

struct NavScopePanel: View {
    @ObservedObject var controller: NavController
    @ObservedObject var settings: NavSettingsStore

    var body: some View {
        HStack(spacing: 14) {
            NavCompass(bearing: controller.mode == .vor ? controller.bearing : nil, ident: controller.ident)
                .frame(width: 210)
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.mode == .ils ? "ABLAGE (DDM)" : "PEILUNG")
                    .font(navHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                NavHistoryChart(values: controller.mode == .ils ? controller.ddmHistory.map(\.1) : controller.bearingHistory.map(\.1),
                                range: controller.mode == .ils ? -settings.ilsKind.fullScaleDDM * 1.5 ... settings.ilsKind.fullScaleDDM * 1.5 : 0 ... 360,
                                wraps: controller.mode != .ils)
                    .frame(maxHeight: .infinity)
                Text("KENNUNG (1020 HZ)")
                    .font(navHeaderFont)
                    .foregroundColor(RadioTheme.textDim)
                ADSBRateChart(values: controller.identEnvelope.map { $0 * 1000 })
                    .frame(height: 42)
            }
            .frame(maxWidth: .infinity)
            NavDeviation(deflection: controller.mode == .ils ? controller.ilsDeflection : nil, kind: settings.ilsKind)
                .frame(width: 150)
        }
        .padding(8)
    }
}

/// Kompassrose mit Nadel auf dem Radial der Station
struct NavCompass: View {
    let bearing: Double?
    let ident: String

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = side / 2 - 14
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(RadioTheme.borderSubtle), lineWidth: 1.5)
            for deg in stride(from: 0, to: 360, by: 10) {
                let a = Double(deg) * .pi / 180
                let long = deg % 30 == 0
                var p = Path()
                p.move(to: CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r))
                p.addLine(to: CGPoint(x: c.x + sin(a) * (r - (long ? 9 : 5)), y: c.y - cos(a) * (r - (long ? 9 : 5))))
                ctx.stroke(p, with: .color(RadioTheme.textDim), lineWidth: long ? 1.2 : 0.7)
                if deg % 90 == 0 {
                    let label = ["N", "O", "S", "W"][deg / 90]
                    ctx.draw(Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim),
                             at: CGPoint(x: c.x + sin(a) * (r + 8), y: c.y - cos(a) * (r + 8)))
                }
            }
            if let b = bearing {
                let a = b * .pi / 180
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: CGPoint(x: c.x + sin(a) * (r - 4), y: c.y - cos(a) * (r - 4)))
                ctx.stroke(needle, with: .color(RadioTheme.vfdGreen), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + sin(a) * (r - 4) - 4, y: c.y - cos(a) * (r - 4) - 4, width: 8, height: 8)), with: .color(RadioTheme.vfdGreen))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(RadioTheme.textDim))
            ctx.draw(Text(bearing.map { String(format: "%.0f°", $0) } ?? "–")
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundColor(bearing == nil ? RadioTheme.textMuted : RadioTheme.vfdGreen),
                     at: CGPoint(x: c.x, y: c.y + r * 0.45))
            if !ident.isEmpty {
                ctx.draw(Text(ident).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan),
                         at: CGPoint(x: c.x, y: c.y - r * 0.45))
            }
        }
    }
}

/// Verlauf eines Messwerts (Peilung als Punkte, damit der Sprung 359° → 0° keine Linie quer zieht)
struct NavHistoryChart: View {
    let values: [Double]
    let range: ClosedRange<Double>
    let wraps: Bool

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RadioTheme.bgDeep))
            for f in [0.25, 0.5, 0.75] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height * f))
                p.addLine(to: CGPoint(x: size.width, y: size.height * f))
                ctx.stroke(p, with: .color(RadioTheme.borderSubtle.opacity(0.6)), lineWidth: 0.5)
            }
            for (i, v) in range.lowerBound.isFinite ? [(0.0, range.lowerBound), (1.0, range.upperBound)] : [] {
                ctx.draw(Text(String(format: wraps ? "%.0f" : "%.2f", v)).font(.system(size: 8, design: .monospaced)).foregroundColor(RadioTheme.textDim),
                         at: CGPoint(x: 16, y: size.height * (1 - i) + (i == 0 ? -6 : 7)))
            }
            guard !values.isEmpty else { return }
            let step = size.width / 239
            let offset = size.width - step * Double(values.count - 1)
            let span = range.upperBound - range.lowerBound
            var previous: CGPoint?
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: offset + step * Double(i), y: size.height * (1 - min(1, max(0, (v - range.lowerBound) / span))))
                if wraps {
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3)), with: .color(RadioTheme.vfdGreen))
                } else {
                    if let p = previous {
                        var line = Path(); line.move(to: p); line.addLine(to: pt)
                        ctx.stroke(line, with: .color(RadioTheme.vfdGreen), lineWidth: 1.5)
                    }
                    previous = pt
                }
            }
        }
        .cornerRadius(4)
    }
}

/// Ablageanzeige (Kreuzzeiger) für den ILS: der Strich bewegt sich zur Seite, auf der geflogen werden muss
struct NavDeviation: View {
    let deflection: Double?
    let kind: ILSKind

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let half = min(size.width, size.height) / 2 - 12
            ctx.stroke(Path(roundedRect: CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half), cornerRadius: 6), with: .color(RadioTheme.borderSubtle), lineWidth: 1.2)
            guard let d = deflection else {
                ctx.draw(Text("kein ILS").font(.system(size: 10, design: .monospaced)).foregroundColor(RadioTheme.textMuted), at: c)
                return
            }
            for k in -2...2 {
                let off = Double(k) / 2.5 * half
                let p: CGPoint = kind == .localizer ? CGPoint(x: c.x + off, y: c.y) : CGPoint(x: c.x, y: c.y + off)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(k == 0 ? RadioTheme.vfdGreen : RadioTheme.textDim))
            }
            // 90 Hz stärker: Landekurs → Flugzeug links → Zeiger nach rechts (Nadel wandert zur Mittellinie hin: Flug nach rechts); Gleitweg → zu hoch → Zeiger nach unten
            let off = max(-1.2, min(1.2, d)) * half
            var needle = Path()
            if kind == .localizer {
                needle.move(to: CGPoint(x: c.x + off, y: c.y - half + 8)); needle.addLine(to: CGPoint(x: c.x + off, y: c.y + half - 8))
            } else {
                needle.move(to: CGPoint(x: c.x - half + 8, y: c.y + off)); needle.addLine(to: CGPoint(x: c.x + half - 8, y: c.y + off))
            }
            ctx.stroke(needle, with: .color(RadioTheme.vfdAmber), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.draw(Text(kind.title).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim), at: CGPoint(x: c.x, y: size.height - 4))
        }
    }
}

// MARK: - Abstimmanzeige

struct NavTuningPanel: View {
    @ObservedObject var controller: NavController
    @ObservedObject var settings: NavSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("VOR / ILS")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text("AM-Audio · 48 kHz")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            HStack(spacing: 10) {
                led("VOR", on: controller.mode == .vor, color: RadioTheme.vfdGreen)
                led("ILS", on: controller.mode == .ils, color: RadioTheme.vfdCyan)
                led("KENNUNG", on: controller.identLevel > 0.0005 && controller.identLevel > 0, color: RadioTheme.vfdAmber)
            }
            PagerLevelBar(level: min(1, max(0, (controller.inputDB + 60) / 60)) * 0.5)
                .frame(height: 8)
                .help("Pegel des Audios am Eingang")
            diagnosisView
        }
    }

    private var diagnosisView: some View {
        let d = controller.diagnosis
        let color: Color = d.ok ? RadioTheme.vfdGreen : controller.inputDB < NavDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.vfdAmber
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
                    .foregroundColor(controller.inputDB < NavDiagnosis.silenceDB ? RadioTheme.ledRed : RadioTheme.textMuted)
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
}

// MARK: - Einstellungen

struct NavSettingsPanel: View {
    @ObservedObject var controller: NavController
    @ObservedObject var settings: NavSettingsStore
    @State private var known = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ILS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                ForEach(ILSKind.allCases) { k in
                    Button(k.title) { settings.ilsKind = k }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.ilsKind == k))
                        .lineLimit(1)
                        .fixedSize()
                        .help(k == .localizer ? "Landekurssender (108,1 bis 111,95 MHz): 90 Hz überwiegt links der Mittellinie" : "Gleitwegsender (328,6 bis 335,4 MHz): 90 Hz überwiegt über dem Gleitpfad")
                }
            }
            HStack(spacing: 6) {
                Text("EICHUNG")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Button("−") { settings.bearingOffset = ((settings.bearingOffset - 1).rounded() + 540).truncatingRemainder(dividingBy: 360) - 180 }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                Text(String(format: "%+.1f°", settings.bearingOffset).replacingOccurrences(of: ".", with: ","))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(minWidth: 56)
                Button("+") { settings.bearingOffset = ((settings.bearingOffset + 1).rounded() + 540).truncatingRemainder(dividingBy: 360) - 180 }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                Button("0") { settings.bearingOffset = 0 }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Eichung löschen")
            }
            HStack(spacing: 6) {
                Text("RADIAL")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                TextField("bekanntes Radial (°)", text: $known)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 130)
                Button("EICHEN") {
                    if let v = Double(known.replacingOccurrences(of: ",", with: ".")), (0...360).contains(v) { controller.calibrate(knownBearing: v) }
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Auf einem Standort mit bekanntem Radial (z. B. aus einer Karte oder dem Flugzeug-Kompass): setzt die Eichung so, dass die Anzeige dem eingegebenen Radial entspricht")
            }
            Text("Eingang: AM-demoduliertes Audio mit 48 kHz. VOR: Bandbreite mindestens 25 kHz (der Hilfsträger liegt bei 9960 Hz). Die Peilung ist die Phase zwischen dem 30-Hz-Ton in der AM und dem 30-Hz-Ton auf dem FM-Hilfsträger; sie hängt von den Filtern des SDR-Programms ab und ist darum zu eichen. ILS: nur das Verhältnis 90 zu 150 Hz zählt. Nicht unterstützt: Doppler-VOR-Besonderheiten, Sprachausgabe der Station, DME.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
