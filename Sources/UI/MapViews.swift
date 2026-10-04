import SwiftUI

/// Karte des aktiven Moduls. Jedes Modul liefert nur seine Punkte; die Karte selbst ist `MapPanel`.
struct ModuleMapView: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        Group {
            switch state.activeModule {
            case .aprs:   APRSMapView(controller: state.aprsController, settings: state.aprs, home: state.home)
            case .acars:  ACARSMapView(controller: state.acarsController, home: state.home)
            case .hfdl:   HFDLMapView(controller: state.hfdlController, home: state.home)
            case .sonde:  SondeMapView(controller: state.sondeController, home: state.home)
            case .ft8:    FT8MapView(controller: state.ft8Controller, home: state.home)
            case .ft4:    FT4MapView(controller: state.ft4Controller, home: state.home)
            case .wspr:   WSPRMapView(controller: state.wsprController, settings: state.wspr, home: state.home)
            case .dsc:    DSCMapView(controller: state.dscController, home: state.home)
            case .navtex: NavtexMapView(controller: state.navtexController, home: state.home)
            case .rtty:   RTTYMapView(controller: state.rttyController, presetID: state.rtty.presetID, home: state.home)
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
            case .sstv, .ale, .pager, .tones, .hell:
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
        case .aprs, .acars, .hfdl, .sonde, .ft8, .ft4, .wspr, .dsc, .ale, .pager, .tones, .skimmer: return "LISTE"
        }
    }

    var mainViewIcon: String {
        switch self {
        case .wefax, .sstv, .hell: return "photo"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63, .mfsk: return "text.alignleft"
        case .dcf77, .efr: return "gauge.with.dots.needle.33percent"
        case .aprs, .acars, .hfdl, .sonde, .ft8, .ft4, .wspr, .dsc, .ale, .pager, .tones, .skimmer: return "list.bullet"
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

// MARK: - RTTY (SYNOP) und Text-Betriebsarten (Rufzeichen)

private struct RTTYMapView: View {
    let controller: RTTYController
    let presetID: String
    @ObservedObject var home: HomeLocation
    @State private var selection: String?
    @AppStorage("synopLayer") private var layerRaw = SynopLog.Layer.symbol.rawValue

    private var layer: SynopLog.Layer { SynopLog.Layer(rawValue: layerRaw) ?? .symbol }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            MapPanel(content: content(now: ctx.date), home: home, selection: $selection,
                     legend: presetID.hasPrefix("dwd") ? "SYNOP und Sender" : "Rufzeichen",
                     accessory: presetID.hasPrefix("dwd") ? AnyView(layerPicker) : nil)
        }
    }

    private var layerPicker: some View {
        Picker("", selection: $layerRaw) {
            ForEach(SynopLog.Layer.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 330)
        .help("Was die Karte zeigt: Wetterstationen als Symbol oder Messwert (Temperatur, Druck, Wind, Sicht) oder SEE: Seegebiete, Warnungen, Hochs, Tiefs, Fronten")
    }

    private func content(now: Date) -> MapContent {
        var content = layer == .sea
            ? controller.textModel.sea.content(home: home.point, now: now, transmitters: sites)
            : controller.textModel.synop.content(home: home.point, now: now, transmitters: sites, layer: layer)
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
