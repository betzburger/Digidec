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
        WefaxTuningPanel(controller: wfc, settings: wf, schedule: schedState.wefaxSchedule, auto: schedState.wefaxAuto).radioCard(title: "Abstimmanzeige")
        WefaxSettingsPanel(settings: wf).radioCard(title: "WEFAX")
        WefaxGallery(controller: wfc).radioCard(title: "Bilder")
    }, width: right, name: "wefax_rechts", dir: dir)
    save(WefaxImagePanel(controller: wfc, schedule: schedState.wefaxSchedule, auto: schedState.wefaxAuto).frame(height: 300).radioCard(title: "Wetterfax"), width: 700, name: "wefax_bild", dir: dir)

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

    // WEFAX-Sendeplan (Fenster)
    schedState.wefaxSchedule.selected = ["1636", "1800", "0430"]
    schedState.wefaxSchedule.autoEnabled = true
    save(WefaxScheduleSheet(store: schedState.wefaxSchedule, auto: schedState.wefaxAuto, scrolls: false), width: 820, name: "wefax_sendeplan", dir: dir)
    // WEFAX-Bildeditor: synthetische „Karte“ mit weißem Rand in der Mitte (Naht)
    let ew = 900, eh = 560
    var epx = [UInt8](repeating: 255, count: ew * eh)
    for y in 0..<eh { for x in 0..<ew where !(380..<450).contains(x) {
        let line = (x + y / 2) % 97 < 2 || (x * 3 + y) % 211 < 2
        if line { epx[y * ew + x] = 40 }
    } }
    let eimg = WefaxImage(name: "wefax_20261001_123600_7880_ok.png", comments: "", width: ew, height: eh, pixels: epx, receivedAt: Date(), fileURL: nil)
    save(WefaxImageEditor(controller: wfc, image: eimg), width: 940, name: "wefax_editor", dir: dir)
    save(WefaxNextLine(store: schedState.wefaxSchedule, auto: schedState.wefaxAuto).radioCard(title: "WEFAX"), width: 330, name: "wefax_naechste", dir: dir)
}

MainActor.assumeIsolated { run() }
