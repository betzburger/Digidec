import SwiftUI

/// Karte des aktiven Moduls. Jedes Modul liefert nur seine Punkte; die Karte selbst ist `MapPanel`.
struct ModuleMapView: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        Group {
            switch state.activeModule {
            case .aprs:   APRSMapView(controller: state.aprsController, settings: state.aprs, home: state.home)
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
            case .wefax:  FixedSiteMapView(sites: Transmitters.dwd("wefax", frequency: "\(state.wefax.station.label) kHz"), home: state.home,
                                           hint: "Wetterfax: Sendestelle des DWD")
            case .dcf77:  FixedSiteMapView(sites: Transmitters.dcf77(), home: state.home, hint: "DCF77: Zeitzeichensender")
            case .efr:    FixedSiteMapView(sites: Transmitters.efr(state.efr.station), home: state.home, hint: "EFR: Rundsteuersender")
            case .sstv, .ale:
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
        case .wefax, .sstv: return "BILD"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63: return "TEXT"
        case .dcf77, .efr: return "ANZEIGE"
        case .aprs, .ft8, .ft4, .wspr, .dsc, .ale: return "LISTE"
        }
    }

    var mainViewIcon: String {
        switch self {
        case .wefax, .sstv: return "photo"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63: return "text.alignleft"
        case .dcf77, .efr: return "gauge.with.dots.needle.33percent"
        case .aprs, .ft8, .ft4, .wspr, .dsc, .ale: return "list.bullet"
        }
    }

    var mainViewHelp: String {
        switch self {
        case .wefax: return "Das empfangene Wetterfax-Bild"
        case .sstv: return "Das empfangene SSTV-Bild"
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63: return "Der empfangene Text"
        case .dcf77: return "Atomuhr, Zeitvergleich und Telegramm"
        case .efr: return "Rundsteuertelegramme"
        case .aprs, .ft8, .ft4, .wspr, .dsc, .ale: return "Die Liste der empfangenen Stationen und Meldungen"
        }
    }

    /// Hat das Modul eine Kartenanzeige?
    var hasMap: Bool {
        switch self {
        case .sstv, .ale: return false
        default: return true
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            MapPanel(content: content(now: ctx.date), home: home, selection: $selection,
                     legend: presetID.hasPrefix("dwd") ? "SYNOP und Sender" : "Rufzeichen")
        }
    }

    private func content(now: Date) -> MapContent {
        var content = controller.textModel.synop.content(home: home.point, now: now, transmitters: sites)
        let calls = HeardMapBuilder.content(controller.textModel.calls.heard, home: home.point, now: now, mode: "RTTY")
        content.markers += calls.markers
        content.lines += calls.lines
        content.emptyHint = "Noch keine SYNOP-Meldung oder kein Rufzeichen mit Ort empfangen"
        return content
    }

    private var sites: [TransmitterSite] {
        switch presetID {
        case "dwd-kw": return Transmitters.dwd("rtty", frequency: "DDK2 4583 kHz · DDK9 7646 kHz · DDH9 10100,8 kHz")
        case "dwd-lw": return Transmitters.dwd("rtty", frequency: "DDH47 147,3 kHz")
        default: return []
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
