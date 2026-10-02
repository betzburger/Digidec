// Digidec UI-Vorschau: rendert Karten offscreen als PNG (ohne App-Start, ohne Audio, ohne Mikrofon-Freigabe).
// Aufruf: Tools/UIPreview/render.sh <ausgabeordner>
import SwiftUI
import AppKit

@MainActor
func save<V: View>(_ view: V, width: CGFloat, name: String, dir: URL) {
    let r = ImageRenderer(content: view.frame(width: width).padding(10).background(RadioTheme.bgPanel)
        .environment(\.colorScheme, .dark))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("Fehler \(name)"); return }
    try? png.write(to: dir.appendingPathComponent(name + ".png"))
    print("\(name): \(Int(img.size.width))×\(Int(img.size.height))")
}

@MainActor
func run() {
    let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    let pipeline = AudioPipeline()
    let right: CGFloat = 330

    // CW
    let cw = CWSettingsStore()
    let cwc = CWController(pipeline: pipeline, settings: cw)
    save(VStack(spacing: 10) {
        CWTuningPanel(controller: cwc, settings: cw).radioCard(title: "Abstimmanzeige")
        CWSettingsPanel(settings: cw).radioCard(title: "CW")
    }, width: right, name: "cw_rechts", dir: dir)

    // WEFAX
    let schedState = DigidecState.shared
    let wf = WefaxSettingsStore()
    let wfc = WefaxController(pipeline: pipeline, settings: wf)
    save(VStack(spacing: 10) {
        WefaxTuningPanel(controller: wfc, settings: wf, schedule: schedState.wefaxSchedule, auto: schedState.autoRecorder).radioCard(title: "Abstimmanzeige")
        WefaxSettingsPanel(settings: wf).radioCard(title: "WEFAX")
        WefaxGallery(controller: wfc).radioCard(title: "Bilder")
    }, width: right, name: "wefax_rechts", dir: dir)
    save(WefaxImagePanel(controller: wfc, schedule: schedState.wefaxSchedule, auto: schedState.autoRecorder, openSchedule: {}).frame(height: 300).radioCard(title: "Wetterfax"), width: 700, name: "wefax_bild", dir: dir)

    // FT8
    let ft = FT8SettingsStore()
    let ftc = FT8Controller(pipeline: pipeline, settings: ft)
    save(VStack(spacing: 10) {
        FT8CyclePanel(controller: ftc, settings: ft).radioCard(title: "Zyklus · Rx-Frequenz")
        FT8SettingsPanel(settings: ft).radioCard(title: "FT8")
    }, width: right, name: "ft8_rechts", dir: dir)
    let start = Date(timeIntervalSince1970: 1_790_000_100)
    let sample: [(String, Int, Double, Double, Int)] = [
        ("CQ DL1ABC JN49", -8, 0.2, 612, 172), ("K3ZK IK2ZDT RR73", -14, 0.1, 1234, 168),
        ("CQ DX 9A7DA JN86", -19, 0.4, 2210, 151), ("DL1ABC W1JGM FN42", -21, 0.3, 1550, 150),
        ("TE9VBM 0T9FRX BE26", -24, 0.9, 870, 123)]
    let entries = sample.map { s in
        let d = FT8Decode(cycleStart: start, text: s.0, snrDB: s.1, dt: s.2, freqHz: s.3, correctBits: s.4, pass: 0)
        let dist = d.message.grid.flatMap { Maidenhead.distance(from: "JN49WS", to: $0) }
        return FT8Entry(decode: d, km: dist?.km, bearing: dist?.bearing, mentionsMe: s.0.contains("W1JGM"))
    }
    save(FT8Table(entries: entries, scrolls: false).background(RadioTheme.bgDeep).radioCard(title: "Bandaktivität"),
         width: 700, name: "ft8_tabelle", dir: dir)

    // PSK
    let ps = PSKSettingsStore()
    let psc = PSKController(pipeline: pipeline, settings: ps)
    save(VStack(spacing: 10) {
        PSKTuningPanel(controller: psc, settings: ps).radioCard(title: "Abstimmanzeige")
        PSKSettingsPanel(settings: ps).radioCard(title: "PSK")
    }, width: right, name: "psk_rechts", dir: dir)

    // ALE
    let al = ALESettingsStore()
    let alc = ALEController(pipeline: pipeline, settings: al)
    save(VStack(spacing: 10) {
        ALETuningPanel(controller: alc, settings: al).radioCard(title: "Abstimmanzeige")
        ALESettingsPanel(settings: al).radioCard(title: "ALE")
    }, width: right, name: "ale_rechts", dir: dir)
    func aleWords(_ list: [(ALEPreamble, String)]) -> [ALEWord] { list.enumerated().map { ALEWord(preamble: $1.0, chars: Array($1.1.utf8), unanimous: 48, golayErrors: 0, endSample: ($0 + 1) * 3136) } }
    let aleMsgs = [
        ALEMessage(receivedAt: Date(timeIntervalSince1970: 1_790_000_008), words: aleWords([(.tis, "SHA"), (.data, "EEN"), (.rep, "Q2@")]), offsetHz: 0),
        ALEMessage(receivedAt: Date(timeIntervalSince1970: 1_790_000_014), words: aleWords([(.to, "USM"), (.data, "ANQ"), (.rep, "7@@"), (.cmd, "~AM"), (.data, "WE "), (.rep, "ALS"), (.data, "O P")]), offsetHz: 0),
        ALEMessage(receivedAt: Date(timeIntervalSince1970: 1_790_000_027), words: aleWords([(.twas, "DL1"), (.data, "ABC")]), offsetHz: 0)]
    save(ALETable(messages: aleMsgs, scrolls: false).background(RadioTheme.bgDeep).radioCard(title: "ALE Aussendungen"), width: 760, name: "ale_tabelle", dir: dir)

    // DSC
    let ds = DSCSettingsStore()
    let dsc = DSCController(pipeline: pipeline, settings: ds)
    save(VStack(spacing: 10) {
        DSCTuningPanel(controller: dsc, settings: ds).radioCard(title: "Abstimmanzeige")
        DSCSettingsPanel(settings: ds).radioCard(title: "DSC")
    }, width: right, name: "dsc_rechts", dir: dir)
    let dscSamples: [[Int]] = [
        [112, 112, 25, 58, 5, 99, 70, 107, 4, 52, 60, 13, 7, 12, 52, 109, 127, 52, 127, 127],
        [120, 120, 32, 51, 42, 0, 0, 108, 0, 23, 71, 0, 0, 118, 126, 4, 10, 10, 4, 39, 30, 122, 54, 122, 122],
        [116, 116, 108, 0, 23, 71, 0, 0, 109, 126, 4, 12, 50, 4, 12, 50, 127, 36, 127, 127],
        [102, 102, 4, 40, 3, 5, 8, 108, 0, 22, 75, 40, 0, 109, 126, 2, 18, 20, 2, 18, 20, 127, 49, 127, 127]]
    let dscMessages = dscSamples.enumerated().map { i, s in
        DSCMessage.parse(symbols: s, receivedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 190), centerHz: 1700, eccOK: i != 3)
    }
    save(DSCTable(messages: dscMessages, scrolls: false).background(RadioTheme.bgDeep).radioCard(title: "DSC Rufe"), width: 760, name: "dsc_tabelle", dir: dir)

    // Olivia und MT63
    let ol = OliviaSettingsStore()
    let olc = OliviaController(pipeline: pipeline, settings: ol)
    let mt = MT63SettingsStore()
    let mtc = MT63Controller(pipeline: pipeline, settings: mt)
    save(VStack(spacing: 10) {
        OliviaTuningPanel(controller: olc, settings: ol).radioCard(title: "Abstimmanzeige")
        OliviaSettingsPanel(settings: ol).radioCard(title: "OLIVIA · CONTESTIA")
        MT63TuningPanel(controller: mtc, settings: mt).radioCard(title: "Abstimmanzeige")
        MT63SettingsPanel(settings: mt).radioCard(title: "MT63")
    }, width: right, name: "olivia_mt63_rechts", dir: dir)

    // MFSK, DominoEX, Thor
    let mf = MFSKSettingsStore()
    let mfc = MFSKController(pipeline: pipeline, settings: mf)
    save(VStack(spacing: 10) {
        MFSKTuningPanel(controller: mfc, settings: mf).radioCard(title: "Abstimmanzeige")
        MFSKSettingsPanel(settings: mf).radioCard(title: "MFSK · DOMINOEX · THOR")
    }, width: right, name: "mfsk_rechts", dir: dir)

    // WSPR
    let ws = WSPRSettingsStore()
    let wsc = WSPRController(pipeline: pipeline, settings: ws)
    save(VStack(spacing: 10) {
        WSPRCyclePanel(controller: wsc, settings: ws).radioCard(title: "Zyklus")
        WSPRSettingsPanel(settings: ws).radioCard(title: "WSPR")
    }, width: right, name: "wspr_rechts", dir: dir)
    let wsStart = Date(timeIntervalSince1970: 1_790_000_040)
    let wsSample: [(String, Int, Double, Double, Int)] = [
        ("ND6P DM04 30", -9, 1.1, 1446.3, 0), ("W5BIT EL09 17", -15, 0.1, 1460.4, 0),
        ("<PJ4/K1ABC> FN42UD 37", -21, 0.5, 1517.4, -1), ("DJ6OL JO52 37", -18, -1.9, 1529.8, 0), ("PJ4/K1ABC 37", -25, 0.7, 1594.4, 1)]
    let wsEntries = wsSample.map { s -> WSPREntry in
        let d = WSPRDecode(slotStart: wsStart, text: s.0, snrDB: s.1, dt: s.2, freqHz: s.3, drift: s.4, sync: 0.5, pass: 1)
        let dist = d.message.grid.flatMap { Maidenhead.distance(from: "JN49WS", to: $0) }
        return WSPREntry(decode: d, dxcc: d.message.isHashed ? nil : DXCCDatabase.shared.lookup(d.message.plainCall), km: dist?.km, bearing: dist?.bearing,
                         rfHz: 14_095_600 + s.3, mentionsMe: false)
    }
    save(WSPRTable(entries: wsEntries, scrolls: false).background(RadioTheme.bgDeep).radioCard(title: "WSPR Spots"), width: 700, name: "wspr_tabelle", dir: dir)

    // ACARS
    let ac = ACARSSettingsStore()
    let acc = ACARSController(pipeline: pipeline, settings: ac)
    acc.logEnabled = false
    func am(_ reg: String, _ flt: String?, _ label: String, _ text: String, down: Bool = true) -> ACARSMessage {
        ACARSMessage(time: Date(timeIntervalSince1970: 1_790_000_100), mode: "2", registration: reg, ack: "NAK", label: label, blockID: down ? "3" : "A", isDownlink: down,
                     messageNumber: down ? "M01A" : nil, flightID: flt, text: text, continues: false, parityErrors: 0, corrected: 0, levelDB: -12)
    }
    for m in [am("D-AIXC", "LH1234", "Q1", "EDDF08150822105511200000EHAM"), am("N123UA", "UA0099", "Q2", "KJFK1530"),
              am("D-AIPA", "LH0400", "H1", "- #M1AFPN/RP:DA:EDDF:AA:KJFK:F:N49.5W007.3"), am("D-AIXC", nil, "SA", "E3V", down: false),
              am("G-EUPT", "BA0904", "Q0", "")] { acc.ingest(m) }
    save(VStack(spacing: 10) {
        ACARSTuningPanel(controller: acc, settings: ac).radioCard(title: "Abstimmanzeige")
        ACARSSettingsPanel(settings: ac).radioCard(title: "ACARS")
    }, width: right, name: "acars_rechts", dir: dir)
    save(ACARSTable(messages: acc.messages, scrolls: false).background(RadioTheme.bgDeep).radioCard(title: "ACARS Meldungen"), width: 700, name: "acars_tabelle", dir: dir)

    // Funkruf und Töne
    let pg = PagerSettingsStore()
    let pgc = PagerController(pipeline: pipeline, settings: pg)
    pgc.logEnabled = false
    pgc.ingest(PagerMessage(time: Date(timeIntervalSince1970: 1_790_000_100), protocolName: "POCSAG 1200", address: 2504, function: 3, numeric: "", alpha: "DAPNET Rufzeichen DL1ABC Test"))
    pgc.ingest(PagerMessage(time: Date(timeIntervalSince1970: 1_790_000_103), protocolName: "FLEX 1600", address: 1523020, function: 5, numeric: "", alpha: "Passage Ambulance Wilhelminabrug Leiden", detail: "00.045 A K"))
    pgc.ingest(PagerMessage(time: Date(timeIntervalSince1970: 1_790_000_110), protocolName: "POCSAG 512", address: 273040, function: 0, numeric: "0123456789", alpha: "·dP2"))
    save(PagerTable(messages: pgc.messages, watched: [2504], scrolls: false).background(RadioTheme.bgDeep).radioCard(title: "Funkruf"), width: 700, name: "pager_tabelle", dir: dir)
    save(VStack(spacing: 10) {
        PagerTuningPanel(controller: pgc, settings: pg).radioCard(title: "Abstimmanzeige")
        PagerSettingsPanel(settings: pg).radioCard(title: "PAGER")
    }, width: right, name: "pager_rechts", dir: dir)

    // WEFAX-Sendeplan (Fenster)
    schedState.wefaxSchedule.selected = ["1636", "1800", "0430"]
    schedState.wefaxSchedule.autoEnabled = true
    schedState.rttySchedule.selected = ["1-0005", "2-0005", "2-0305"]
    schedState.rttySchedule.autoEnabled = true
    func tabFrame<V: View>(_ v: V) -> some View { v.padding(16).frame(width: 900).background(RadioTheme.bgPanel) }
    save(tabFrame(VStack(alignment: .leading, spacing: 10) {
        ScheduleNextLine(auto: schedState.autoRecorder)
        WefaxScheduleTab(store: schedState.wefaxSchedule, auto: schedState.autoRecorder, close: {}, scrolls: false)
    }), width: 900, name: "wefax_sendeplan", dir: dir)
    save(tabFrame(RttyScheduleTab(store: schedState.rttySchedule, auto: schedState.autoRecorder, close: {}, scrolls: false)), width: 900, name: "rtty_sendeplan", dir: dir)
    save(tabFrame(NavtexScheduleTab(store: schedState.navtexPlan, auto: schedState.autoRecorder, close: {}, scrolls: false)), width: 900, name: "navtex_sendeplan", dir: dir)
    // WEFAX-Bildeditor: synthetische „Karte“ mit weißem Rand in der Mitte (Naht)
    let ew = 900, eh = 560
    var epx = [UInt8](repeating: 255, count: ew * eh)
    for y in 0..<eh { for x in 0..<ew where !(380..<450).contains(x) {
        let line = (x + y / 2) % 97 < 2 || (x * 3 + y) % 211 < 2
        if line { epx[y * ew + x] = 40 }
    } }
    let eimg = WefaxImage(name: "wefax_20261001_123600_7880_ok.png", comments: "", width: ew, height: eh, pixels: epx, receivedAt: Date(), fileURL: nil)
    save(WefaxImageEditor(controller: wfc, image: eimg), width: 940, name: "wefax_editor", dir: dir)
    save(WefaxNextLine(store: schedState.wefaxSchedule, auto: schedState.autoRecorder).radioCard(title: "WEFAX"), width: 330, name: "wefax_naechste", dir: dir)
}

MainActor.assumeIsolated { run() }
