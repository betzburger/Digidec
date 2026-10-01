// Digidec offline: decodiert eine Aufnahme mit dem RTTY- oder CW-Kern (fldigi 4.2.13) und wertet sie aus.
// Aufruf über Tools/DecodeFile/decode_file.sh – Hilfe mit --help.
import Foundation
import AVFoundation

func usage() -> Never {
    print("""
    Aufruf: decode_file.sh <aufnahme.wav> [Optionen]

      --info <datei.json>   Einstellungen (Standard: <aufnahme>.json, von Digidec beim Aufnehmen geschrieben)
      --preset <id>         ham | dwd-kw | dwd-lw (statt Begleitdatei)
      --center <Hz>         NF-Mitte (statt Begleitdatei)
      --lsb                 Kehrlage (LSB) – Reverse wird wie in Digidec umgedreht
      --out <datei.txt>     decodierten Text speichern (Standard: <aufnahme>.digidec.txt)
      --loop ddk2           Auswertung gegen die bekannte DWD-Testschleife (DDK2/DDH7/DDK9)
      --compare <datei.txt> Übereinstimmung mit einem anderen Text (z. B. fldigi) messen
      --synop               SYNOP/SHIP/BUOY-Klartext zusätzlich nach <aufnahme>.synop.txt schreiben

      --cw                  CW statt RTTY (fldigi-CW-Empfänger); dazu --center <Ton-Hz> (Standard 700)
      --wpm <n>             CW-Startgeschwindigkeit (Standard 18, Nachführung ±10)
      --mf                  CW Matched Filter (Bandbreite 2 × WpM)

      --wefax               Wetterfax (fldigi-WEFAX-Empfänger); Bilder als PNG neben die Aufnahme
      --lpm <n>             WEFAX Zeilen je Minute (Standard 120)
      --shift <Hz>          WEFAX Hub (Standard 800, DWD 850); --center <Hz> NF-Mitte (Standard 1900)
      --nonstop             WEFAX ohne APT-Steuerung (ganze Aufnahme als ein Bild)
    """)
    exit(2)
}

// MARK: - Argumente

var args = Array(CommandLine.arguments.dropFirst())
guard let wavPath = args.first, !wavPath.hasPrefix("-") else { usage() }
args.removeFirst()
var infoPath: String?
var presetID: String?
var center: Double?
var lsb = false
var outPath: String?
var loop: String?
var comparePath: String?
var synopOut = false
var cwMode = false
var cwWPM = 18
var cwMF = false
var wefaxMode = false
var wefaxLPM = 120
var wefaxShift = 800
var wefaxNonStop = false
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String { guard !args.isEmpty else { usage() }; return args.removeFirst() }
    switch a {
    case "--info": infoPath = value()
    case "--preset": presetID = value()
    case "--center": center = Double(value())
    case "--lsb": lsb = true
    case "--out": outPath = value()
    case "--loop": loop = value()
    case "--compare": comparePath = value()
    case "--synop": synopOut = true
    case "--cw": cwMode = true
    case "--wpm": cwWPM = Int(value()) ?? 18
    case "--mf": cwMF = true
    case "--wefax": wefaxMode = true
    case "--lpm": wefaxLPM = Int(value()) ?? 120
    case "--shift": wefaxShift = Int(value()) ?? 800
    case "--nonstop": wefaxNonStop = true
    case "--help", "-h": usage()
    default: print("Unbekannte Option \(a)"); usage()
    }
}

let wavURL = URL(fileURLWithPath: wavPath)
let defaultInfo = wavURL.deletingPathExtension().appendingPathExtension("json")
let infoURL = infoPath.map { URL(fileURLWithPath: $0) } ?? defaultInfo

// MARK: - WEFAX

if wefaxMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: FldigiWefaxCore.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    var o = FldigiWefaxCore.Options()
    o.lpm = wefaxLPM
    o.shiftHz = wefaxShift
    o.centerHz = Int(center ?? 1900)
    print("WEFAX · IOC \(o.ioc) · \(o.lpm) LPM · Hub \(o.shiftHz) Hz · Mitte \(o.centerHz) Hz" + (wefaxNonStop ? " · Non-Stop" : ""))
    var images: [WefaxImage] = []
    let core = FldigiWefaxCore(options: o) { images.append($0) }
    if wefaxNonStop { core.setManual(true) }
    var lastState = FldigiWefaxCore.State.idle
    var samples = 0
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) {
            core.process($0)
            samples += $0.count
        }
        let st = core.status
        if st.state != lastState {
            print(String(format: "%7.1f s  %@  (Korrelation %.0f, S/N %.0f dB, Mitte %.0f Hz)",
                         Double(samples) / FldigiWefaxCore.sampleRate, st.state.label, st.metric, st.snrDB, st.centerHz))
            lastState = st.state
        }
    }
    if wefaxNonStop || core.status.state == .image { core.save() }   // laufendes Bild am Ende sichern
    let dir = wavURL.deletingLastPathComponent()
    for var img in images {
        img.name = wavURL.deletingPathExtension().lastPathComponent + "." + img.name
        if let url = try? WefaxController.writePNG(img, to: dir) {
            print("Bild \(img.width)×\(img.height) (\(img.endReasonGerman)) -> \(url.lastPathComponent)")
        }
    }
    if images.isEmpty { print("Kein Bild erkannt") }
    exit(0)
}

// MARK: - CW

if cwMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: FldigiCWCore.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    var o = FldigiCWCore.Options()
    o.speedWPM = cwWPM
    o.matchedFilter = cwMF
    let tone = center ?? 700
    print("CW · Ton \(Int(tone)) Hz · Start \(cwWPM) WpM" + (cwMF ? " · Matched Filter" : " · Filter \(o.bandwidthHz) Hz"))
    var cwText = ""
    var wpmSeen: [Double] = []
    let core = FldigiCWCore(options: o, centerHz: tone) { t, _ in cwText += t }
    let started = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { core.process($0) }
        if core.status.wpm > 0 { wpmSeen.append(core.status.wpm) }
    }
    let out = outPath.map { URL(fileURLWithPath: $0) } ?? wavURL.deletingPathExtension().appendingPathExtension("digidec.txt")
    try? cwText.write(to: out, atomically: true, encoding: .utf8)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "Decodiert: %.0f s Audio in %.2f s, %d Zeichen -> %@", duration, Date().timeIntervalSince(started),
                 cwText.count, out.lastPathComponent))
    if let lo = wpmSeen.min(), let hi = wpmSeen.max() {
        print(String(format: "Geschwindigkeit: %.0f … %.0f WpM, am Ende %.0f WpM", lo, hi, core.status.wpm))
    }
    print(cwText)
    if let comparePath, let other = try? String(contentsOfFile: comparePath, encoding: .utf8) {
        let a = Array(cwText.uppercased().filter { !$0.isWhitespace }), b = Array(other.uppercased().filter { !$0.isWhitespace })
        let d = levenshtein(a, b)
        print(String(format: "Vergleich mit %@: %d Abweichungen auf %d Zeichen (%.2f %%)", comparePath, d, max(a.count, b.count),
                     100 * Double(d) / Double(max(1, max(a.count, b.count)))))
    }
    exit(0)
}

// MARK: - Einstellungen

var parameters: RTTYParameters
var options = RTTYDecodeOptions()
var centerHz: Double
let dec = JSONDecoder()
dec.dateDecodingStrategy = .iso8601
if presetID == nil, let data = try? Data(contentsOf: infoURL), let info = try? dec.decode(RecordingInfo.self, from: data) {
    parameters = info.decoderParameters
    options = info.options
    centerHz = center ?? info.centerHz
    print("Einstellungen aus \(infoURL.lastPathComponent): \(info.presetID) · \(parameters.summary)"
          + " · Decoder-Reverse \(parameters.reverse) · Mitte \(Int(centerHz)) Hz")
} else {
    guard let preset = RTTYPreset.preset(id: presetID ?? "") else {
        print("Keine Begleitdatei gefunden – bitte --preset und --center angeben")
        usage()
    }
    parameters = preset.parameters
    parameters.reverse = parameters.reverse != lsb
    centerHz = center ?? 1000
    print("Einstellungen: \(preset.id) · \(parameters.summary) · Decoder-Reverse \(parameters.reverse) · Mitte \(Int(centerHz)) Hz")
}

// MARK: - Datei lesen, auf 8 kHz wandeln, decodieren

guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false) else {
    print("Datei nicht lesbar: \(wavPath)")
    exit(1)
}
let rate = file.processingFormat.sampleRate
let duration = Double(file.length) / rate
guard let src = SampleRateConverter(inputRate: rate, outputRate: FldigiRTTYCore.sampleRate) else { exit(1) }
var text = ""
var synopText = ""
var synop: SynopDecoder?
if synopOut {
    SynopDecoder.loadStations()
    synop = SynopDecoder { seg in
        synopText += seg.decoded ? RTTYController.displayDecoded(seg.text) : RTTYController.displayText(seg.text)
    }
}
let core = FldigiRTTYCore(parameters: parameters, options: RTTYDecoder.coreOptions(parameters, options), centerHz: centerHz) {
    text.append($0)
    synop?.feed($0)
}
let started = Date()
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
while true {
    buf.frameLength = 0
    try? file.read(into: buf, frameCount: 48_000)
    guard buf.frameLength > 0 else { break }
    src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { core.process($0) }
}
synop?.flush()
if synopOut {
    let url = wavURL.deletingPathExtension().appendingPathExtension("synop.txt")
    try? synopText.write(to: url, atomically: true, encoding: .utf8)
    print("SYNOP-Klartext -> \(url.lastPathComponent)")
}
let clean = RTTYController.displayText(text)
let out = outPath.map { URL(fileURLWithPath: $0) } ?? wavURL.deletingPathExtension().appendingPathExtension("digidec.txt")
try? clean.write(to: out, atomically: true, encoding: .utf8)
print(String(format: "Decodiert: %.0f s Audio (%.0f Hz) in %.2f s, %d Zeichen -> %@",
             duration, rate, Date().timeIntervalSince(started), clean.count, out.lastPathComponent))
print(String(format: "Mitte am Ende (AFC): %.1f Hz", core.status.centerHz))

// MARK: - Auswertung

func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var d = Array(0...b.count)
    for i in 1...a.count {
        var prev = d[0]
        d[0] = i
        for j in 1...b.count {
            let tmp = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
            prev = tmp
        }
    }
    return d[b.count]
}

/// Jede vollständige Zeile (ohne erste und letzte) gegen die nächstliegende bekannte Zeile der Testschleife
func loopScore(_ s: String, name: String) {
    let known = [String(repeating: "RY", count: 32),
                 "CQ CQ CQ DE DDK2 DDH7 DDK9",
                 "FREQUENCIES   4583 KHZ   7646 KHZ   10100.8 KHZ"].map { Array($0) }
    let lines = s.split(separator: "\n", omittingEmptySubsequences: true).map { Array($0.trimmingCharacters(in: .whitespaces)) }
    guard lines.count > 2 else { print("\(name): zu wenige Zeilen für die Auswertung"); return }
    var errors = 0, chars = 0, perfect = 0, used = 0
    for line in lines.dropFirst().dropLast() where !line.isEmpty {
        let best = known.map { (levenshtein(line, $0), $0.count) }.min { $0.0 < $1.0 }!
        // Zeilen, die gar nicht zur Schleife gehören (z. B. Wetterberichte), nicht werten
        guard Double(best.0) <= Double(best.1) * 0.5 else { continue }
        errors += best.0
        chars += best.1
        used += 1
        if best.0 == 0 { perfect += 1 }
    }
    guard chars > 0 else { print("\(name): keine Zeilen der Testschleife gefunden"); return }
    print(String(format: "%@: Testschleife %d Zeilen, %d fehlerfrei, Zeichenfehler %d von %d = %.2f %%",
                 name, used, perfect, errors, chars, 100 * Double(errors) / Double(chars)))
}

if loop == "ddk2" {
    loopScore(clean, name: "Digidec")
}
if let comparePath {
    guard let other = try? String(contentsOfFile: comparePath, encoding: .utf8) else {
        print("Vergleichsdatei nicht lesbar: \(comparePath)")
        exit(1)
    }
    let otherClean = RTTYController.displayText(other)
    if loop == "ddk2" { loopScore(otherClean, name: "Vergleich (\(URL(fileURLWithPath: comparePath).lastPathComponent))") }
    // Gesamtübereinstimmung: Zeichenfolgen ohne Zeilenumbrüche/Mehrfach-Leerzeichen
    func norm(_ t: String) -> [Character] {
        Array(t.replacingOccurrences(of: "\n", with: " ").split(separator: " ").joined(separator: " "))
    }
    let a = norm(clean), b = norm(otherClean)
    if max(a.count, b.count) > 60_000 {
        print("Texte zu lang für den Gesamtvergleich (\(a.count) / \(b.count) Zeichen)")
    } else {
        let d = levenshtein(a, b)
        print(String(format: "Abweichung Digidec ↔ Vergleich: %d Zeichen von %d / %d = %.2f %%",
                     d, a.count, b.count, 100 * Double(d) / Double(max(a.count, b.count, 1))))
    }
}
