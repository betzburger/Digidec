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

      --psk <modus>         PSK (fldigi-PSK-Empfänger): bpsk31 | bpsk63 | bpsk125 | bpsk250 | qpsk31 … qpsk250;
                            dazu --center <Träger-Hz> (Standard 1000); --noafc schaltet die Frequenznachführung ab, --rev kehrt QPSK um

      --olivia <kennung>    Olivia/Contestia (fldigi): olivia-8-500 | olivia-16-1000 | contestia-8-500 … (Töne-Bandbreite); --center <Mitte-Hz> (Standard 1500)
      --mfsk <kennung>      MFSK/DominoEX/Thor (fldigi): mfsk16 | mfsk32 | dominoex11 | thor16 | … (siehe DecoderModuleInfo.mfsk); --center <Mitte-Hz> (Standard 1500), --noafc
      --mt63 <kennung>      MT63 (fldigi): 500s | 500l | 1000s | 1000l | 2000s | 2000l (S = kurz, L = lang); --center <Mitte-Hz> (Standard 1500)

      --dsc                 DSC (ITU-R M.493, 100 Bd / 170 Hz); --center <Mitte-Hz> (Standard 1700), --noauto schaltet die Mittennachführung ab, --rev kehrt um
                            --vhf: UKW-Kanal 70 (FM-Audio, 1200 Bd, 1300/2100 Hz)

      --aprs                APRS/Packet-Radio (AFSK 1200 Bd, AX.25); Ausgabe je Paket als TNC2-Zeile mit Ort. --nofix schaltet die Ein-Bit-Reparatur ab,
                            --slicers <n> (Standard 7), --pre auto|off|on Vorverzerrung für de-emphasiertes Audio (Standard auto: beide Wege), --center <Mitte-Hz> (Standard 1700), --home <Locator> für Entfernungen

      --pager               Funkruf (POCSAG 512/1200/2400, FLEX): je Meldung eine Zeile; --rates 512,1200 schränkt die Baudraten ein
      --tones [normen]      DTMF und Selektivrufe (dtmf, zvei1, zvei2, zvei3, dzvei, pzvei, ccir, eea, eia), Normen durch Komma getrennt (Standard: dtmf,zvei1)

      --acars               ACARS (AM-Audio, MSK 2400 Bd): je Meldung eine Zeile; --channel <n> wählt bei Mehrkanaldateien den Kanal (ab 0)

      --ale                 ALE (MIL-STD-188-141, 8-FSK 125 Bd); --offset <Hz> Verstimmung der Töne (Standard 0), --minvotes <n> (Standard 36)

      --wefax               Wetterfax (fldigi-WEFAX-Empfänger); Bilder als PNG neben die Aufnahme
      --lpm <n>             WEFAX Zeilen je Minute (Standard 120)
      --shift <Hz>          WEFAX Hub (Standard 800, DWD 850); --center <Hz> NF-Mitte (Standard 1900)
      --nonstop             WEFAX ohne APT-Steuerung (ganze Aufnahme als ein Bild)

      --ft8                 FT8 (ft8mon); die Aufnahme beginnt am Zyklusbeginn, je 15 s ein Zyklus
      --budget <s>          FT8 Rechenzeit je Zyklus (Standard 3)
      --wsjtx <datei.txt>   FT8-Ergebnis mit WSJT-X-Decodes vergleichen (Trefferquote)
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
var pskModeID: String?
var oliviaID: String?
var mfskID: String?
var dscMode = false
var dscVHF = false
var aleMode = false
var acarsMode = false
var fileChannel = 0
var pagerMode = false
var pagerRates = POCSAG.rates
var tonesMode = false
var tonesList = "dtmf,zvei1"
var aprsMode = false
var aprsFix = true
var aprsSlicers = 7
var aprsPre = "auto"
var homeLocator = "JN49WS"
var aleOffset = 0.0
var aleVotes = 36
var dscAuto = true
var mt63ID: String?
var pskAFC = true
var pskReverse = false
var wefaxMode = false
var wefaxLPM = 120
var wefaxShift = 800
var wefaxNonStop = false
var ft8Mode = false
var ft8Budget = 3.0
var wsjtxPath: String?
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
    case "--psk": pskModeID = value()
    case "--olivia": oliviaID = value()
    case "--mfsk": mfskID = value()
    case "--dsc": dscMode = true
    case "--vhf": dscVHF = true
    case "--ale": aleMode = true
    case "--aprs": aprsMode = true
    case "--acars": acarsMode = true
    case "--channel": fileChannel = Int(value()) ?? 0
    case "--pager": pagerMode = true
    case "--rates": pagerRates = value().split(separator: ",").compactMap { Int($0) }
    case "--tones": tonesMode = true; if let v = args.first, !v.hasPrefix("-") { tonesList = v; args.removeFirst() }
    case "--nofix": aprsFix = false
    case "--slicers": aprsSlicers = Int(value()) ?? 7
    case "--pre": aprsPre = value()
    case "--home": homeLocator = value().uppercased()
    case "--offset": aleOffset = Double(value()) ?? 0
    case "--minvotes": aleVotes = Int(value()) ?? 36
    case "--noauto": dscAuto = false
    case "--mt63": mt63ID = value()
    case "--noafc": pskAFC = false
    case "--rev": pskReverse = true
    case "--wefax": wefaxMode = true
    case "--lpm": wefaxLPM = Int(value()) ?? 120
    case "--shift": wefaxShift = Int(value()) ?? 800
    case "--nonstop": wefaxNonStop = true
    case "--ft8": ft8Mode = true
    case "--budget": ft8Budget = Double(value()) ?? 3
    case "--wsjtx": wsjtxPath = value()
    case "--help", "-h": usage()
    default: print("Unbekannte Option \(a)"); usage()
    }
}

let wavURL = URL(fileURLWithPath: wavPath)
let defaultInfo = wavURL.deletingPathExtension().appendingPathExtension("json")
let infoURL = infoPath.map { URL(fileURLWithPath: $0) } ?? defaultInfo

// MARK: - FT8

/// Meldung ohne Hash-Rufzeichen-Inhalt (wie ft8_lib utils/run_tests.py)
func ft8Key(_ text: String) -> String {
    text.split(separator: " ").prefix(3).map { $0.hasPrefix("<") ? "<...>" : String($0) }.joined(separator: " ")
}

if ft8Mode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: FT8Core.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    var all: [Float] = []
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { all += Array($0) }
    }
    var settings = FT8Core.Settings()
    settings.budgetSeconds = ft8Budget
    let perCycle = Int(FT8Core.cycleSeconds * FT8Core.sampleRate)
    var found: [FT8Decode] = []
    var start = 0
    repeat {
        let part = Array(all[start..<min(all.count, start + perCycle)])
        let t0 = Date()
        let list = FT8Core.decode(part, settings: settings)
        let label = String(format: "%5.0f s", Double(start) / FT8Core.sampleRate)
        print("Zyklus ab \(label): \(list.count) Decodes in " + String(format: "%.1f s", Date().timeIntervalSince(t0)))
        for d in list {
            print(String(format: "  %+4d %5.1f %5.0f  ", d.snrDB, d.dt, d.freqHz) + d.text + (d.isUncertain ? " ?" : ""))
        }
        found += list
        start += perCycle
    } while start + 10 * Int(FT8Core.sampleRate) < all.count
    if let wsjtxPath, let ref = try? String(contentsOfFile: wsjtxPath, encoding: .utf8) {
        // WSJT-X: „hhmmss snr dt freq ~  MELDUNG“
        let expected = Set(ref.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            return f.count > 5 ? ft8Key(f[5...].joined(separator: " ")) : nil
        })
        let got = Set(found.map { ft8Key($0.text) })
        let sure = Set(found.filter { !$0.isUncertain }.map { ft8Key($0.text) })
        print("WSJT-X: \(expected.count) · gefunden \(expected.intersection(got).count) · zusätzlich \(got.subtracting(expected).count)"
              + " (davon unsicher \(got.subtracting(expected).subtracting(sure).count))")
        print("FT8VERGLEICH \(expected.count) \(expected.intersection(got).count) \(got.subtracting(expected).count) \(got.subtracting(expected).subtracting(sure).count)")
    }
    exit(0)
}

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

// MARK: - PSK

if let pskModeID {
    guard let mode = PSKMode(rawValue: pskModeID.lowercased()) else {
        print("Unbekannte PSK-Betriebsart: \(pskModeID)")
        exit(1)
    }
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: FldigiPSKCore.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    var o = FldigiPSKCore.Options()
    o.mode = mode
    o.afc = pskAFC
    o.reverse = pskReverse
    let carrier = center ?? 1000
    print("PSK · \(mode.displayName) · Träger \(Int(carrier)) Hz" + (pskAFC ? " · AFC" : " · AFC aus") + (pskReverse ? " · REV" : ""))
    var bytes: [UInt8] = []
    let core = FldigiPSKCore(options: o, centerHz: carrier) { bytes.append($0) }
    let started = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    var peakSNR = 0.0
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { core.process($0) }
        peakSNR = max(peakSNR, core.status.snrDB)
    }
    let pskText = PSKDecoder.text(from: bytes)
    let out = outPath.map { URL(fileURLWithPath: $0) } ?? wavURL.deletingPathExtension().appendingPathExtension("digidec.txt")
    try? pskText.write(to: out, atomically: true, encoding: .utf8)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "Decodiert: %.0f s Audio in %.2f s, %d Zeichen -> %@", duration, Date().timeIntervalSince(started), pskText.count, out.lastPathComponent))
    print(String(format: "Träger am Ende %.1f Hz, bestes S/N %.0f dB", core.status.centerHz, peakSNR))
    print(pskText)
    if let comparePath, let other = try? String(contentsOfFile: comparePath, encoding: .utf8) {
        let a = Array(pskText.filter { !$0.isWhitespace }), b = Array(other.filter { !$0.isWhitespace })
        let d = levenshtein(a, b)
        print(String(format: "Vergleich mit %@: %d Abweichungen auf %d Zeichen (%.2f %%)", comparePath, d, max(a.count, b.count),
                     100 * Double(d) / Double(max(1, max(a.count, b.count)))))
    }
    exit(0)
}

// MARK: - ACARS

if acarsMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: ACARSDecoder.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    let ch = min(max(0, fileChannel), Int(file.processingFormat.channelCount) - 1)
    print("ACARS · Kanal \(ch) von \(file.processingFormat.channelCount)")
    let rx = ACARSReceiver(sampleRate: ACARSDecoder.sampleRate)
    var n = 0, samples = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![ch], count: Int(buf.frameLength))) { chunk in
            rx.process(chunk) { m in
                n += 1
                print(String(format: "%7.2f s  ", Double(samples) / ACARSDecoder.sampleRate) + ACARSController.logLine(m))
            }
            samples += chunk.count
        }
    }
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.1f s Audio in %.2f s: %d Meldungen", dur, Date().timeIntervalSince(began), n))
    exit(0)
}

// MARK: - Funkruf

if pagerMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: PagerDecoder.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    print("Funkruf · POCSAG \(pagerRates.map(String.init).joined(separator: "/")) · FLEX")
    let rx = POCSAGReceiver(sampleRate: PagerDecoder.sampleRate)
    rx.enabled = Set(pagerRates.compactMap { POCSAG.rates.firstIndex(of: $0) })
    let flexRx = FLEXReceiver(sampleRate: PagerDecoder.sampleRate)
    var n = 0, samples = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    func show(_ m: PagerMessage) {
        n += 1
        print(String(format: "%7.1f s  ", Double(samples) / PagerDecoder.sampleRate) + PagerController.logLine(m))
    }
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
            rx.process(chunk, emit: show)
            flexRx.process(chunk, emit: show)
            samples += chunk.count
        }
    }
    rx.flush(emit: show)
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.0f s Audio in %.2f s: %d Meldungen", dur, Date().timeIntervalSince(began), n))
    exit(0)
}

// MARK: - Töne

if tonesMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: AudioPipeline.decoderSampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    let standards = tonesList.split(separator: ",").compactMap { ToneStandard(rawValue: String($0)) }
    print("Töne · " + standards.map(\.name).joined(separator: ", "))
    let decoders = standards.map { ToneDecoder(standard: $0) }
    var n = 0, samples = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
            for d in decoders {
                d.process(chunk) { s in
                    if s.isComplete { n += 1; print(String(format: "%7.1f s  %@  %@", Double(samples) / AudioPipeline.decoderSampleRate, s.standard.name, s.text)) }
                }
            }
            samples += chunk.count
        }
    }
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.0f s Audio in %.2f s: %d Tonfolgen", dur, Date().timeIntervalSince(began), n))
    exit(0)
}

// MARK: - APRS

if aprsMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: APRSDecoder.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    var options = AFSKDemodulator.Options()
    options.slicers = aprsSlicers
    options.repairBits = aprsFix
    options.centerOffsetHz = (center ?? 1700) - 1700
    print("APRS · AFSK 1200 Bd · \(aprsSlicers) Entscheider" + (aprsFix ? " · Bitkorrektur" : "") + " · Audio \(aprsPre)")
    let demod = AFSKReceiver(sampleRate: APRSDecoder.sampleRate, options: options, emphasis: AFSKReceiver.Emphasis(rawValue: aprsPre) ?? .auto)
    let home = Maidenhead.point(homeLocator)
    var packets = 0, repaired = 0, withPosition = 0
    var stations: [String: Int] = [:]
    var samples = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
            demod.process(chunk) { raw in
                guard let frame = AX25Frame.parse(raw.bytes) else { return }
                packets += 1
                if raw.repaired { repaired += 1 }
                stations[frame.source.text, default: 0] += 1
                var line = String(format: "%7.1f s  ", Double(samples) / APRSDecoder.sampleRate) + (raw.repaired ? "~ " : "  ") + APRSController.tnc2Line(frame)
                if let p = APRSParser.parse(frame), let pos = p.position {
                    withPosition += 1
                    line += "\n            ↳ \(p.kind.rawValue) \(Geo.format(pos))"
                    if let h = home { line += String(format: " · %.0f km", Geo.distanceKm(h, pos)) }
                    if let s = p.symbol { line += " · \(s.name)" }
                    if let w = p.weather { line += " · \(w.summary)" }
                }
                print(line)
            }
            samples += chunk.count
        }
    }
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.0f s Audio in %.2f s: %d Pakete (%d repariert) von %d Stationen, %d mit Ort", dur, Date().timeIntervalSince(began), packets, repaired, stations.count, withPosition))
    exit(0)
}

// MARK: - ALE

if aleMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: ALEDemodulator.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    print("ALE · Verstimmung \(aleOffset) Hz · mindestens \(aleVotes) einstimmige Bit")
    let demod = ALEDemodulator(offsetHz: aleOffset)
    demod.minUnanimous = aleVotes
    var collector = ALEWordCollector()
    var tracker = ALEGridTracker()
    var builder = ALEMessageBuilder()
    var messages: [(Double, ALEMessage)] = []
    var accepted = 0, candidates = 0
    var total = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    func handle(_ words: [ALEWord]) {
        for w in words where tracker.accept(w) {
            accepted += 1
            if let m = builder.add(w, offsetHz: demod.offsetHz) { messages.append((Double(m.words.first!.endSample) / 8000, m)) }
        }
    }
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
            demod.process(chunk) { w, _ in candidates += 1; collector.add(w) }
            total += chunk.count
            handle(collector.take(now: total))
            tracker.idle(now: total)
            if let m = builder.flush(nowSample: total, offsetHz: demod.offsetHz) { messages.append((Double(m.words.first!.endSample) / 8000, m)) }
        }
    }
    handle(collector.take(now: total, force: true))
    if let m = builder.flush(nowSample: total + 100_000, offsetHz: demod.offsetHz, force: true) { messages.append((Double(m.words.first!.endSample) / 8000, m)) }
    for (t, m) in messages {
        print(String(format: "%6.1f s  %@  Q%d  ", t, m.kind.padding(toLength: 9, withPad: " ", startingAt: 0), m.quality) + m.summary)
    }
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.0f s Audio in %.2f s: %d Aussendungen, %d Wörter (%d Kandidaten)", dur, Date().timeIntervalSince(began), messages.count, accepted, candidates))
    exit(0)
}

// MARK: - DSC

if dscMode && dscVHF {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: DSCVHFReceiver.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    print("DSC · UKW Kanal 70 · 1200 Bd")
    let rx = DSCVHFReceiver()
    var collector = DSCCallCollector()
    var samples = 0
    var raw = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
            rx.process(chunk) { c in raw += 1; collector.add(c, at: Double(samples) / DSCVHFReceiver.sampleRate) }
            samples += chunk.count
        }
    }
    var lines = 0
    for c in collector.take(now: 0, force: true) {
        let m = DSCMessage.parse(symbols: c.symbols, centerHz: 0, eccOK: c.eccOK)
        print(DSCController.logLine(m, dial: nil).replacingOccurrences(of: DSCController.utc.string(from: m.receivedAt), with: "          "))
        lines += 1
    }
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.0f s Audio in %.2f s: %d Rufe (%d Roh-Treffer)", dur, Date().timeIntervalSince(began), lines, raw))
    exit(0)
}

if dscMode {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: DSCDemodulator.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    let start = center ?? 1700
    print("DSC · Mitte \(Int(start)) Hz" + (dscAuto ? " (Nachführung)" : "") + (pskReverse ? " · REV" : ""))
    let demod = DSCDemodulator(centerHz: start)
    demod.reversed = pskReverse
    var framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
    var calls: [(Double, DSCCall)] = []
    let seconds = 0.0
    var samples = 0
    let began = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    var lockedAt: [Double] = []
    var tuner = DSCAutoTuner()
    var recent: [Float] = []
    var sinceTune = 0
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
            demod.process(chunk) { phase, bit in
                if let c = framers[phase].push(bit) { calls.append((seconds + Double(samples) / DSCDemodulator.sampleRate, c)) }
            }
            samples += chunk.count
            recent.append(contentsOf: chunk)
            if recent.count > DSCAutoTuner.blockSize { recent.removeFirst(recent.count - DSCAutoTuner.blockSize) }
            sinceTune += chunk.count
            if sinceTune >= 8000 {
                sinceTune = 0
                let r = tuner.update(recent: recent, current: demod.centerHz)
                if dscAuto, let c = r.newCenter { demod.centerHz = c }
            }
            if framers.contains(where: { $0.isLocked }), lockedAt.last.map({ Double(samples) / DSCDemodulator.sampleRate - $0 > 1 }) ?? true {
                lockedAt.append(Double(samples) / DSCDemodulator.sampleRate)
            }
        }
    }
    var collector = DSCCallCollector()
    for (t, c) in calls { collector.add(c, at: t) }
    var lines = 0
    var last = Set<String>()
    for c in collector.take(now: 0, force: true) {
        let key = c.symbols.map(String.init).joined(separator: ",")
        _ = last.insert(key)
        let m = DSCMessage.parse(symbols: c.symbols, centerHz: demod.centerHz, eccOK: c.eccOK)
        print(DSCController.logLine(m, dial: nil).replacingOccurrences(of: DSCController.utc.string(from: m.receivedAt), with: "          "))
        lines += 1
    }
    let dur = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "%.0f s Audio in %.2f s: %d Rufe (%d Roh-Treffer), Rahmen eingerastet %d mal, Mitte am Ende %.0f Hz", dur, Date().timeIntervalSince(began), lines, calls.count, lockedAt.count, demod.centerHz))
    exit(0)
}

// MARK: - MFSK, DominoEX, Thor

if let id = mfskID {
    guard let mode = MFSKMode(rawValue: id) else { print("Unbekannte MFSK-Kennung: \(id)"); exit(1) }
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: mode.sampleRate) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    let carrier = center ?? 1500
    var o = FldigiMFSKCore.Options()
    o.mode = mode
    o.afc = pskAFC
    print("\(mode.displayName) · Mitte \(Int(carrier)) Hz · \(Int(mode.bandwidthHz)) Hz breit")
    var bytes: [UInt8] = []
    let core = FldigiMFSKCore(options: o, centerHz: carrier) { bytes.append($0) }
    let started = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { core.process($0) }
    }
    let text = PSKDecoder.text(from: bytes)
    let out = outPath.map { URL(fileURLWithPath: $0) } ?? wavURL.deletingPathExtension().appendingPathExtension("digidec.txt")
    try? text.write(to: out, atomically: true, encoding: .utf8)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let s = core.status
    print(String(format: "Decodiert: %.0f s Audio in %.2f s, %d Zeichen -> %@", duration, Date().timeIntervalSince(started), text.count, out.lastPathComponent))
    print(String(format: "Mitte am Ende %.1f Hz, Metrik %.0f", s.centerHz, s.metric))
    print(text)
    exit(0)
}

// MARK: - Olivia, Contestia, MT63

if oliviaID != nil || mt63ID != nil {
    guard let file = try? AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: 8_000) else {
        print("Datei nicht lesbar: \(wavPath)")
        exit(1)
    }
    let carrier = center ?? 1500
    var bytes: [UInt8] = []
    var process: (UnsafeBufferPointer<Float>) -> Void = { _ in }
    var finish: () -> Void = {}
    var summary: () -> String = { "" }
    var oCore: FldigiOliviaCore?
    var mCore: FldigiMT63Core?
    if let id = oliviaID {
        guard let o = FldigiOliviaCore.Options(presetID: id) else { print("Unbekannte Olivia-Kennung: \(id)"); exit(1) }
        print("\(o.familyName.uppercased()) \(o.label) · Mitte \(Int(carrier)) Hz")
        let c = FldigiOliviaCore(options: o, centerHz: carrier) { bytes.append($0) }
        oCore = c
        process = { c.process($0) }
        finish = { c.flush() }
        summary = { let s = c.status; return String(format: "Mitte %.1f Hz, S/N %.1f, Abweichung %+.1f Hz", s.centerHz, s.snr, s.freqOffsetHz) }
    } else if let id = mt63ID {
        guard let o = FldigiMT63Core.Options(presetID: id) else { print("Unbekannte MT63-Kennung: \(id)"); exit(1) }
        print("MT63 \(o.label) · Mitte \(Int(carrier)) Hz")
        let c = FldigiMT63Core(options: o, centerHz: carrier) { bytes.append($0) }
        mCore = c
        process = { c.process($0) }
        finish = { c.flush() }
        summary = { let s = c.status; return String(format: "Mitte %.1f Hz, S/N %.1f, Abweichung %+.1f Hz", s.centerHz, s.snr, s.freqOffsetHz) }
    }
    _ = oCore; _ = mCore
    let started = Date()
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? file.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { process($0) }
    }
    finish()
    let text = PSKDecoder.text(from: bytes)
    let out = outPath.map { URL(fileURLWithPath: $0) } ?? wavURL.deletingPathExtension().appendingPathExtension("digidec.txt")
    try? text.write(to: out, atomically: true, encoding: .utf8)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "Decodiert: %.0f s Audio in %.2f s, %d Zeichen -> %@", duration, Date().timeIntervalSince(started), text.count, out.lastPathComponent))
    print(summary())
    print(text)
    if let comparePath, let other = try? String(contentsOfFile: comparePath, encoding: .utf8) {
        let a = Array(text.filter { !$0.isWhitespace }), b = Array(other.filter { !$0.isWhitespace })
        let d = levenshtein(a, b)
        print(String(format: "Vergleich mit %@: %d Abweichungen auf %d Zeichen (%.2f %%)", comparePath, d, max(a.count, b.count),
                     100 * Double(d) / Double(max(1, max(a.count, b.count)))))
    }
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
