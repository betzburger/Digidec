// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

/// Karte des aktiven Moduls. Jedes Modul liefert nur seine Punkte; die Karte selbst ist `MapPanel`.
struct ModuleMapView: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        Group {
            switch state.activeModule {
            case .adsb:   ADSBMapView(controller: state.adsbController, settings: state.adsb, home: state.home)
            case .aprs:   APRSMapView(controller: state.aprsController, settings: state.aprs, home: state.home)
            case .acars:  ACARSMapView(controller: state.acarsController, home: state.home)
            case .ais:    AISMapView(controller: state.aisController, settings: state.ais, home: state.home)
            case .hfdl:   HFDLMapView(controller: state.hfdlController, home: state.home)
            case .sonde:  SondeMapView(controller: state.sondeController, home: state.home)
            case .ft8:    FT8MapView(controller: state.ft8Controller, home: state.home)
            case .ft4:    FT4MapView(controller: state.ft4Controller, home: state.home)
            case .wspr:   WSPRMapView(controller: state.wsprController, settings: state.wspr, home: state.home)
            case .dsc:    DSCMapView(controller: state.dscController, home: state.home)
            case .navtex: NavtexMapView(controller: state.navtexController, home: state.home)
            case .rtty:   RTTYMapView(controller: state.rttyController, presetID: state.rtty.presetID, home: state.home,
                                      showRawText: { revealRTTYStation($0) })
            case .cw:     TextCallMapView(model: state.cwController.textModel, mode: "CW", home: state.home)
            case .psk:    TextCallMapView(model: state.pskController.textModel, mode: "PSK", home: state.home)
            case .olivia: TextCallMapView(model: state.oliviaController.textModel, mode: "Olivia", home: state.home)
            case .mt63:   TextCallMapView(model: state.mt63Controller.textModel, mode: "MT63", home: state.home)
            case .mfsk:   TextCallMapView(model: state.mfskController.textModel, mode: state.mfsk.options.mode.family.title, home: state.home)
            case .skimmer: SkimmerMapView(controller: state.skimmerController, settings: state.skimmer, home: state.home)
            case .wefax:  FixedSiteMapView(sites: Transmitters.dwd("wefax", frequency: "\(state.wefax.station.label) kHz"), home: state.home,
                                           hint: "Wetterfax: Sendestelle des DWD")
            case .dcf77:  FixedSiteMapView(sites: Transmitters.dcf77(), home: state.home, hint: "DCF77: Zeitzeichensender")
            case .efr:    FixedSiteMapView(sites: Transmitters.efr(state.efr.station), home: state.home, hint: "EFR: Rundsteuersender")
            case .sstv, .ale, .pager, .tones, .hell, .packet, .dstar, .ysf, .dmr:
                Text("Dieses Modul hat keine Ortsdaten")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(state.activeModule)
    }
}

extension DecoderModuleInfo {
    /// Name der gewohnten Ansicht im Umschalter: Bild, Text, Liste oder Anzeige
    var mainViewName: String {
        switch self {
        case .wefax, .sstv, .hell: return "BILD"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63, .mfsk: return "TEXT"
        case .dcf77, .efr: return "ANZEIGE"
        case .aprs, .packet, .adsb, .acars, .ais, .dstar, .ysf, .dmr, .hfdl, .sonde, .ft8, .ft4, .wspr, .dsc, .ale, .pager, .tones, .skimmer: return "LISTE"
        }
    }

    var mainViewIcon: String {
        switch self {
        case .wefax, .sstv, .hell: return "photo"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63, .mfsk: return "text.alignleft"
        case .dcf77, .efr: return "gauge.with.dots.needle.33percent"
        case .aprs, .packet, .adsb, .acars, .ais, .dstar, .ysf, .dmr, .hfdl, .sonde, .ft8, .ft4, .wspr, .dsc, .ale, .pager, .tones, .skimmer: return "list.bullet"
        }
    }

    var mainViewHelp: String {
        switch self {
        case .wefax: return "Das empfangene Wetterfax-Bild"
        case .sstv: return "Das empfangene SSTV-Bild"
        case .hell: return "Das empfangene Hell-Bild (Schrift als Raster)"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63, .mfsk: return "Der empfangene Text"
        case .dcf77: return "Atomuhr, Zeitvergleich und Telegramm"
        case .efr: return "Rundsteuertelegramme"
        case .skimmer: return "Alle gehörten Signale mit Rufzeichen, Rauschabstand und Spots"
        case .sonde: return "Die empfangenen Radiosonden mit Höhe, Steigen, Messwerten und Entfernung"
        case .ais: return "Die empfangenen Schiffe mit Typ, Fahrt, Ziel und Entfernung; Doppelklick öffnet die Schiffsdaten"
        case .adsb: return "Die Flugzeuge mit Kennung, Höhe, Geschwindigkeit, Entfernung und Meldungsprotokoll"
        case .packet: return "Monitor, Stationen, Digipeater, Verbindungen, Nachrichten und Knoten"
        case .dmr: return "Beide Zeitschlitze mit Absender, Ziel und Farbcode, dazu der Verlauf der Gespräche mit Wiedergabe"
        case .ysf: return "Die gehörte Aussendung mit Rufzeichen, Ziel und Repeater, dazu der Verlauf mit Wiedergabe"
        case .dstar: return "Die gehörte Aussendung mit Rufzeichen, Repeater, Text und Position, dazu der Verlauf mit Wiedergabe"
        case .aprs, .acars, .hfdl, .ft8, .ft4, .wspr, .dsc, .ale, .pager, .tones: return "Die Liste der empfangenen Stationen und Meldungen"
        }
    }
}

// MARK: - APRS

private struct APRSMapView: View {
    @ObservedObject var controller: APRSController
    @ObservedObject var settings: APRSSettingsStore
    @ObservedObject var home: HomeLocation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { ctx in
            MapPanel(content: controller.mapContent(home: home.point, now: ctx.date), home: home, selection: $controller.selection,
                     legend: settings.mapHours > 0 ? "letzte \(Int(settings.mapHours)) h" : "alle")
        }
    }
}

// MARK: - ADS-B

private struct ADSBMapView: View {
    @ObservedObject var controller: ADSBController
    @ObservedObject var settings: ADSBSettingsStore
    @ObservedObject var home: HomeLocation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let selection = Binding<String?>(
            get: { controller.selection.map { "adsb-" + String(format: "%06X", $0) } },
            set: { id in
                // Ein Flughafen der Strecke lässt die Auswahl des Flugzeugs stehen
                if let id, id.hasPrefix("adsb-apt-") { return }
                controller.selection = id.flatMap { $0.hasPrefix("adsb-") ? UInt32($0.dropFirst(5), radix: 16) : nil }
            })
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            MapPanel(content: controller.mapContent(home: home.point, now: ctx.date), home: home, selection: selection,
                     legend: "Flugzeuge mit Weg · Farbe nach Höhe", detailAction: infoAction, keepZoomOnSelect: true)
        }
        .onChange(of: controller.selection) { _, icao in
            guard settings.openInfoOnClick, let icao else { return }
            controller.showInfo(for: icao)
            openWindow(id: "aircraft-info")
        }
    }

    /// Knopf in den Einzelheiten eines Flugzeugs: Fenster mit Foto, Typ, Betreiber und Strecke
    private var infoAction: MapDetailAction {
        MapDetailAction(title: "FLUGZEUGDATEN", help: "Foto, Typ, Betreiber und Strecke des Flugzeugs (aus dem Netz)", systemImage: "airplane",
                        applies: { $0.id.hasPrefix("adsb-") && !$0.id.hasPrefix("adsb-apt-") },
                        perform: { m in
                            guard let icao = UInt32(m.id.dropFirst(5), radix: 16) else { return }
                            controller.selection = icao
                            controller.showInfo(for: icao)
                            openWindow(id: "aircraft-info")
                        })
    }
}

// MARK: - ACARS

private struct ACARSMapView: View {
    @ObservedObject var controller: ACARSController
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            MapPanel(content: controller.mapContent(home: home.point, now: ctx.date), home: home, selection: $selection,
                     legend: "Flugzeuge mit Weg · Flughäfen aus OOOI")
        }
    }
}


// MARK: - AIS

private struct AISMapView: View {
    @ObservedObject var controller: AISController
    @ObservedObject var settings: AISSettingsStore
    @ObservedObject var home: HomeLocation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { ctx in
            MapPanel(content: controller.mapContent(home: home.point, now: ctx.date), home: home, selection: $controller.selection,
                     legend: "Schiffe mit Kurs und Weg · Klick öffnet die Schiffsdaten", accessory: AnyView(infoButton), keepZoomOnSelect: true)
        }
        .onChange(of: controller.selection) { _, id in
            guard settings.openInfoOnClick, let id, let mmsi = AISMapBuilder.mmsi(fromID: id) else { return }
            controller.showInfo(for: mmsi)
            openWindow(id: "ship-info")
        }
    }

    @ViewBuilder
    private var infoButton: some View {
        if let mmsi = controller.selectedMMSI {
            Button {
                controller.showInfo(for: mmsi)
                openWindow(id: "ship-info")
            } label: {
                Label("SCHIFFSDATEN", systemImage: "info.circle")
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
            .help("Fenster mit Foto, Baujahr und technischen Daten des gewählten Schiffs")
        }
    }
}

// MARK: - HFDL


private struct HFDLMapView: View {
    @ObservedObject var controller: HFDLController
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            MapPanel(content: controller.mapContent(home: home.point, now: ctx.date), home: home, selection: $selection,
                     legend: "Flugzeuge mit Weg · Bodenstationen (grün hinterlegt: kürzlich gehört)")
        }
    }
}

// MARK: - Sonden

private struct SondeMapView: View {
    @ObservedObject var controller: SondeController
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            MapPanel(content: controller.mapContent(home: home.point, now: ctx.date), home: home, selection: $selection,
                     legend: "Sonden mit Weg · Landeprognose grob")
        }
    }
}

// MARK: - FT8, FT4, WSPR

private struct FT8MapView: View {
    @ObservedObject var controller: FT8Controller
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let heard: [HeardStation] = controller.entries.compactMap { e in
                let d = e.decode, m = d.message
                guard !d.isUncertain, let call = m.sender, !FT8Message.isHashed(call) else { return nil }
                return HeardStation(call: call, grid: m.grid, dxcc: e.dxcc, snr: d.snrDB, time: d.cycleStart, text: d.text,
                                    isCQ: m.isCQ, mentionsMe: e.mentionsMe)
            }
            MapPanel(content: HeardMapBuilder.content(heard, home: home.point, now: ctx.date, mode: "FT8", maxAge: 3600), home: home,
                     selection: $selection, legend: "letzte Stunde")
        }
    }
}

private struct FT4MapView: View {
    @ObservedObject var controller: FT4Controller
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let heard: [HeardStation] = controller.entries.compactMap { e in
                let d = e.decode, m = d.message
                guard !d.isUncertain, let call = m.sender, !FT8Message.isHashed(call) else { return nil }
                return HeardStation(call: call, grid: m.grid, dxcc: e.dxcc, snr: d.snrDB, time: d.cycleStart, text: d.text,
                                    isCQ: m.isCQ, mentionsMe: e.mentionsMe)
            }
            MapPanel(content: HeardMapBuilder.content(heard, home: home.point, now: ctx.date, mode: "FT4", maxAge: 3600), home: home,
                     selection: $selection, legend: "letzte Stunde")
        }
    }
}

private struct WSPRMapView: View {
    @ObservedObject var controller: WSPRController
    @ObservedObject var settings: WSPRSettingsStore
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let heard: [HeardStation] = controller.entries.compactMap { e in
                let m = e.decode.message
                guard !m.isHashed, !m.call.isEmpty else { return nil }
                return HeardStation(call: m.call, grid: m.grid, dxcc: e.dxcc, snr: e.decode.snrDB, time: e.decode.slotStart, text: e.decode.text,
                                    mentionsMe: e.mentionsMe, rfHz: e.rfHz, powerDBm: m.powerDBm)
            }
            MapPanel(content: HeardMapBuilder.content(heard, home: home.point, now: ctx.date, mode: "WSPR", maxAge: 6 * 3600), home: home,
                     selection: $selection, legend: "letzte 6 h")
        }
    }
}

// MARK: - DSC, NAVTEX

private struct DSCMapView: View {
    @ObservedObject var controller: DSCController
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            MapPanel(content: DSCMapBuilder.content(controller.messages, home: home.point, now: ctx.date), home: home, selection: $selection)
        }
    }
}

private struct NavtexMapView: View {
    @ObservedObject var controller: NavtexController
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            MapPanel(content: NavtexMapBuilder.content(controller.entries, home: home.point, now: ctx.date), home: home, selection: $selection,
                     legend: "Kreis: etwa 250 sm")
        }
    }
}

extension ModuleMapView {
    /// Von der Karte zur Rohmeldung im RTTY-Empfangstext springen. Ist die Textansicht ausgeblendet (nur Karte), wird BEIDE
    /// eingeschaltet. Rückgabe: gefunden (oder wird nach dem Einblenden gesucht).
    @MainActor
    func revealRTTYStation(_ id: String) -> Bool {
        let model = state.rttyController.textModel
        if model.reveal(station: id) { return true }
        guard state.mapLayout(.rtty) == .map else { return false }
        state.setMapLayout(.split, for: .rtty)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            _ = model.reveal(station: id)
        }
        return true
    }
}

// MARK: - RTTY (SYNOP) und Text-Betriebsarten (Rufzeichen)

private struct RTTYMapView: View {
    let controller: RTTYController
    let presetID: String
    @ObservedObject var home: HomeLocation
    /// Springt zur Rohmeldung der Station im Empfangstext (Kennung); false = nicht im Text gefunden
    let showRawText: (String) -> Bool
    @State private var selection: String?
    @State private var showExtremes = false
    @State private var rawNote: String?
    @AppStorage("synopLayer") private var layerRaw = SynopLog.Layer.symbol.rawValue
    /// Abstand der Isobaren in hPa (0 = aus), Temperaturverteilung als Farbfläche
    @AppStorage("synopIsobarStep") private var isobarStep = 0
    @AppStorage("synopTempField") private var tempField = false

    private var layer: SynopLog.Layer { SynopLog.Layer(rawValue: layerRaw) ?? .symbol }
    private var overlay: SynopOverlayOptions { SynopOverlayOptions(isobarStepHPa: isobarStep, temperatureField: tempField) }
    private var isWeatherPreset: Bool { presetID.hasPrefix("dwd") }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            MapPanel(content: content(now: ctx.date), home: home, selection: $selection,
                     legend: isWeatherPreset ? "SYNOP und Sender" : "Rufzeichen",
                     accessory: isWeatherPreset ? AnyView(controls) : nil,
                     detailAction: isWeatherPreset ? rawAction : nil,
                     snapshotName: isWeatherPreset ? "RTTY-" + layer.title : "RTTY")
        }
    }

    /// „IM TEXT“ in der Auswahl einer Wetterstation: zur empfangenen Rohmeldung springen
    private var rawAction: MapDetailAction {
        MapDetailAction(title: "IM TEXT", help: "Zur empfangenen Rohmeldung im Empfangstext springen und sie markieren",
                        systemImage: "text.alignleft",
                        applies: { $0.id.hasPrefix("synop-") },
                        perform: { marker in
                            if !showRawText(String(marker.id.dropFirst("synop-".count))) { flashRawNote() }
                        })
    }

    private func flashRawNote() {
        let text = "Rohmeldung nicht im Text (Textfilter an oder Text gelöscht)"
        rawNote = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if rawNote == text { rawNote = nil }
        }
    }

    private var controls: some View {
        HStack(spacing: 5) {
            layerPicker
            Picker("", selection: $isobarStep) {
                Text("ISOBAREN AUS").tag(0)
                Text("ISOBAREN 2 hPa").tag(2)
                Text("ISOBAREN 4 hPa").tag(4)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)
            .disabled(layer == .sea)
            .help("Linien gleichen Luftdrucks auf Meereshöhe, aus den Stationen berechnet (mindestens 5 Stationen). Dazu H und T an den Zentren.")
            Button("T-FLÄCHE") { tempField.toggle() }
                .buttonStyle(ModeButtonStyle(isSelected: tempField))
                .disabled(layer == .sea)
                .help("Temperaturverteilung als Farbfläche, aus den Stationen berechnet (mindestens 5 Stationen)")
            Button {
                showExtremes.toggle()
            } label: {
                Label("EXTREME", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(ModeButtonStyle(isSelected: showExtremes))
            .disabled(!SynopLog.Layer.measured.contains(layer))
            .help("Höchste und niedrigste Werte der gewählten Ebene")
            .popover(isPresented: $showExtremes) { extremesView }
            if let rawNote {
                Text(rawNote)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RadioTheme.bgDeep.opacity(0.85))
                    .cornerRadius(4)
            }
        }
    }

    private var layerPicker: some View {
        Picker("", selection: $layerRaw) {
            ForEach(SynopLog.Layer.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 105)
        .help("Was die Karte zeigt: Wetterstationen als Symbol oder Messwert (Temperatur, Druck, Wind, Sicht, Feuchte, Niederschlag) oder SEE: Seegebiete, Warnungen, Hochs, Tiefs, Fronten")
    }

    /// Rangliste der höchsten und niedrigsten Werte; ein Klick wählt die Station auf der Karte
    private var extremesView: some View {
        let result = controller.textModel.synop.extremes(layer: layer)
        return VStack(alignment: .leading, spacing: 6) {
            Text(result.map { "\($0.layer.quantity.uppercased()) · \($0.stations) Stationen" } ?? layer.quantity.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            if let result {
                extremeList("HÖCHSTE", result.highest, tint: RadioTheme.ledRed)
                if !result.lowest.isEmpty { extremeList("NIEDRIGSTE", result.lowest, tint: RadioTheme.vfdCyan) }
            } else {
                Text("Noch keine Station mit diesem Messwert und Ort")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
        .padding(12)
        .frame(minWidth: 270, alignment: .leading)
        .background(RadioTheme.bgCard)
    }

    private func extremeList(_ title: String, _ entries: [SynopExtremeEntry], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(tint)
            ForEach(entries) { e in
                Button {
                    selection = e.id
                    showExtremes = false
                } label: {
                    HStack(spacing: 8) {
                        Text(e.text)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textBright)
                            .frame(width: 84, alignment: .trailing)
                        Text(e.name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .help("Station auf der Karte wählen")
            }
        }
    }

    private func content(now: Date) -> MapContent {
        var content = layer == .sea
            ? controller.textModel.sea.content(home: home.point, now: now, transmitters: sites)
            : controller.textModel.synop.content(home: home.point, now: now, transmitters: sites, layer: layer, overlay: overlay)
        if layer != .sea {
            content.markers += controller.textModel.sea.pointMarkers(home: home.point, layer: layer)
        }
        let calls = HeardMapBuilder.content(controller.textModel.calls.heard, home: home.point, now: now, mode: "RTTY")
        content.markers += calls.markers
        content.lines += calls.lines
        if layer != .sea && content.markers.isEmpty {
            content.emptyHint = "Noch keine SYNOP-Meldung, Punktvorhersage oder kein Rufzeichen mit Ort empfangen"
        }
        return content
    }

    private var sites: [TransmitterSite] {
        switch presetID {
        case "dwd-kw": return Transmitters.dwd("rtty", frequency: "DDK2 4583 kHz · DDH7 7646 kHz · DDK9 10100,8 kHz · DDH9 11039 kHz · DDH8 14467,3 kHz")
        case "dwd-lw": return Transmitters.dwd("rtty", frequency: "DDH47 147,3 kHz")
        default: return []
        }
    }
}

private struct SkimmerMapView: View {
    @ObservedObject var controller: SkimmerController
    @ObservedObject var settings: SkimmerSettingsStore
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            MapPanel(content: HeardMapBuilder.content(controller.heard, home: home.point, now: ctx.date, mode: settings.mode.name,
                                                      emptyHint: "Noch kein Rufzeichen gehört (nach CQ oder DE, oder mehrfach)"),
                     home: home, selection: $selection, legend: "gehörte Rufzeichen (Gebiet, nicht genauer Ort)")
        }
    }
}

private struct TextCallMapView: View {
    let model: ReceiveTextModel
    let mode: String
    @ObservedObject var home: HomeLocation
    @State private var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            MapPanel(content: HeardMapBuilder.content(model.calls.heard, home: home.point, now: ctx.date, mode: mode,
                                                      emptyHint: "Noch kein Rufzeichen im Text erkannt (nach CQ oder DE, oder mehrfach)"),
                     home: home, selection: $selection, legend: "Rufzeichen im Text")
        }
    }
}

// MARK: - Feste Sender

private struct FixedSiteMapView: View {
    let sites: [TransmitterSite]
    @ObservedObject var home: HomeLocation
    let hint: String
    @State private var selection: String?

    var body: some View {
        MapPanel(content: TransmitterMap.content(sites, home: home.point), home: home, selection: $selection, legend: hint)
    }
}
