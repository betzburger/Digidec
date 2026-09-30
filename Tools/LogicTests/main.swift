// Logiktests für Digidec (reine Rechenlogik, ohne Audio).
// Nicht Teil des Swift-Packages (Package.swift baut nur "Sources").
// Ausführen im Projektverzeichnis:
//   Tools/LogicTests/run_logic_tests.sh              (Build in temporärem Verzeichnis, danach gelöscht)
//   Tools/LogicTests/run_logic_tests.sh <ausgabe>    (Build bleibt in <ausgabe>, z. B. im Scratchpad)
// Exit-Code 0 = alle Prüfungen bestanden. Neue Quelldateien, von denen getestete Typen abhängen,
// müssen im Skript ergänzt werden.
import Foundation
import AVFoundation

var failures = 0
var checks = 0
@MainActor func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !cond() {
        failures += 1
        print("FAIL (line \(line)): \(msg)")
    }
}

@MainActor func parse(_ s: String) -> Result<DecodeRequest, DecodeRequestError> {
    DecodeRequestParser.parse(URL(string: s)!)
}

// MARK: - URL-Schema: vollständiger Auftrag (Beispiel aus PLAN.md, Abschnitt 3.1)
do {
    let r = parse("digidec://decode?mode=rtty&preset=dwd-lw&source=pcr1500&rigctl=4532&device=VALHost2ch_UID&center=1000")
    check(r == .success(DecodeRequest(module: .rtty, presetID: "dwd-lw", source: "pcr1500",
                                      rigctlPort: 4532, deviceUID: "VALHost2ch_UID", centerHz: 1000)),
          "Vollständiger Auftrag, got \(r)")
    if case .success(let req) = r {
        check(req.sourceDisplayName == "PCR-1500 Commander", "Anzeigename PCR-1500")
    }
    if case .success(let req) = parse("digidec://decode?mode=rtty&source=ft991a&rigctl=4533") {
        check(req.sourceDisplayName == "FT-991A Commander", "Anzeigename FT-991A")
        check(req.rigctlPort == 4533, "Port FT-991A")
    } else {
        check(false, "FT-991A-Auftrag abgelehnt")
    }
}

// MARK: - URL-Schema: Standardwerte und Toleranz
do {
    // Ohne Preset: erstes Preset des Moduls (Amateurfunk)
    check(parse("digidec://decode?mode=rtty") == .success(DecodeRequest(module: .rtty, presetID: "ham")),
          "Standard-Preset ham")
    // Groß-/Kleinschreibung bei Schema, Aktion, Mode, Preset
    check(parse("DIGIDEC://Decode?mode=RTTY&preset=DWD-KW") == .success(DecodeRequest(module: .rtty, presetID: "dwd-kw")),
          "Groß-/Kleinschreibung")
    // Dezimalkomma bei der Mittenfrequenz
    if case .success(let req) = parse("digidec://decode?mode=rtty&center=1012,5") {
        check(req.centerHz == 1012.5, "Dezimalkomma center")
    } else {
        check(false, "Dezimalkomma abgelehnt")
    }
    // Leere Parameter gelten als nicht angegeben
    check(parse("digidec://decode?mode=rtty&preset=&device=") == .success(DecodeRequest(module: .rtty, presetID: "ham")),
          "Leere Parameter")
    // Geräte-UID mit Sonderzeichen (prozentkodiert)
    if case .success(let req) = parse("digidec://decode?mode=rtty&device=VAL%3AHost%202ch") {
        check(req.deviceUID == "VAL:Host 2ch", "Prozentkodierte UID, got \(String(describing: req.deviceUID))")
    } else {
        check(false, "Prozentkodierte UID abgelehnt")
    }
    // Alle RTTY-Presets aus PLAN.md 5.2 werden angenommen
    for p in ["ham", "dwd-kw", "dwd-lw", "custom"] {
        if case .success(let req) = parse("digidec://decode?mode=rtty&preset=\(p)") {
            check(req.presetID == p, "Preset \(p)")
        } else {
            check(false, "Preset \(p) abgelehnt")
        }
    }
}

// MARK: - URL-Schema: Fehlerfälle
do {
    check(parse("http://decode?mode=rtty") == .failure(.wrongScheme("http")), "Falsches Schema")
    check(parse("digidec://start?mode=rtty") == .failure(.unknownAction("start")), "Falsche Aktion")
    check(parse("digidec://decode") == .failure(.missingMode), "Mode fehlt")
    check(parse("digidec://decode?mode=pactor") == .failure(.unknownMode("pactor")), "Unbekannter Mode")
    check(parse("digidec://decode?mode=navtex") == .failure(.moduleNotAvailable(.navtex)), "Geplantes Modul")
    check(parse("digidec://decode?mode=rtty&preset=xyz") == .failure(.unknownPreset("xyz", .rtty)), "Unbekanntes Preset")
    check(parse("digidec://decode?mode=rtty&rigctl=80") == .failure(.invalidPort("80")), "Port zu klein")
    check(parse("digidec://decode?mode=rtty&rigctl=70000") == .failure(.invalidPort("70000")), "Port zu groß")
    check(parse("digidec://decode?mode=rtty&rigctl=abc") == .failure(.invalidPort("abc")), "Port keine Zahl")
    check(parse("digidec://decode?mode=rtty&center=50") == .failure(.invalidCenter("50")), "Mitte zu tief")
    check(parse("digidec://decode?mode=rtty&center=5000") == .failure(.invalidCenter("5000")), "Mitte zu hoch")
}

// MARK: - Modul-Liste
do {
    check(DecoderModuleInfo.allCases.filter(\.isAvailable) == [.rtty], "Nur RTTY verfügbar (M1)")
    for m in DecoderModuleInfo.allCases where m.isAvailable {
        check(!m.presetIDs.isEmpty, "\(m.displayName): verfügbares Modul braucht Presets")
    }
}


// MARK: - Audio: Ringpuffer
do {
    let rb = FloatRingBuffer(capacity: 8)
    var src: [Float] = [1, 2, 3, 4, 5]
    var dst = [Float](repeating: 0, count: 8)
    rb.write(src, count: 5)
    check(rb.available == 5, "Ring: 5 verfügbar")
    check(rb.read(into: &dst, maxCount: 3) == 3 && Array(dst[0..<3]) == [1, 2, 3], "Ring: erste 3 gelesen")
    src = [6, 7, 8, 9, 10, 11]           // Umlauf über das Ende
    rb.write(src, count: 6)
    check(rb.available == 8 && rb.droppedSamples == 0, "Ring: voll ohne Verlust")
    rb.write([12, 13], count: 2)          // Überlauf: älteste (4, 5) fallen weg
    check(rb.droppedSamples == 2, "Ring: 2 verworfen, got \(rb.droppedSamples)")
    check(rb.read(into: &dst, maxCount: 8) == 8 && dst == [6, 7, 8, 9, 10, 11, 12, 13], "Ring: neueste 8 in Reihenfolge, got \(dst)")
    check(rb.read(into: &dst, maxCount: 8) == 0, "Ring: leer")
    let big = (0..<20).map(Float.init)    // Block größer als Kapazität
    rb.write(big, count: 20)
    check(rb.read(into: &dst, maxCount: 8) == 8 && dst == Array(big[12..<20]), "Ring: übergroßer Block behält Ende")
}

// MARK: - Audio: Kanalwahl
do {
    let inter: [Float] = [1, 10, 2, 20, 3, 30]   // L, R verschachtelt
    var out = [Float](repeating: 0, count: 3)
    ChannelMode.extract(interleaved: inter, frames: 3, channels: 2, mode: .left, into: &out)
    check(out == [1, 2, 3], "Kanal L, got \(out)")
    ChannelMode.extract(interleaved: inter, frames: 3, channels: 2, mode: .right, into: &out)
    check(out == [10, 20, 30], "Kanal R, got \(out)")
    ChannelMode.extract(interleaved: inter, frames: 3, channels: 2, mode: .mix, into: &out)
    check(out == [5.5, 11, 16.5], "Kanal L+R, got \(out)")
    ChannelMode.extract(interleaved: [7, 8, 9], frames: 3, channels: 1, mode: .right, into: &out)
    check(out == [7, 8, 9], "Mono-Eingang unverändert")
    let l: [Float] = [1, 2], r: [Float] = [3, 6]
    var o2 = [Float](repeating: 0, count: 2)
    l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
        ChannelMode.extract(planar: [lp.baseAddress!, rp.baseAddress!], frames: 2, mode: .mix, into: &o2)
    } }
    check(o2 == [2, 4], "Planar L+R, got \(o2)")
}

// MARK: - Audio: Pegel
do {
    check(AudioLevel.dB(1) == 0, "0 dBFS")
    check(abs(AudioLevel.dB(0.5) - -6.0206) < 0.001, "-6 dBFS")
    check(AudioLevel.dB(0) == AudioLevel.floorDB, "Stille = Boden")
    let acc = LevelAccumulator()
    let sine = (0..<4800).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
    sine.withUnsafeBufferPointer { acc.add($0) }
    let lv = acc.take()
    check(abs(lv.peakDB - -6.02) < 0.05, "Sinus 0,5: Spitze -6 dB, got \(lv.peakDB)")
    check(abs(lv.rmsDB - -9.03) < 0.05, "Sinus 0,5: Effektivwert -9 dB, got \(lv.rmsDB)")
    check(acc.take() == .silence, "Nach take zurückgesetzt")
}

// MARK: - Audio: Abtastratenwandler 48 kHz -> 8 kHz
@MainActor func resample(freq: Double, seconds: Double = 1.0, block: Int = 960, rate: Double = 48000) -> [Float] {
    let conv = SampleRateConverter(inputRate: rate, outputRate: 8000)!
    let n = Int(rate * seconds)
    let input = (0..<n).map { Float(0.5 * sin(2 * Double.pi * freq * Double($0) / rate)) }
    var out: [Float] = []
    var i = 0
    while i < n {                                  // in Blöcken wie die Pipeline
        let len = min(block, n - i)
        input[i..<(i + len)].withUnsafeBufferPointer { conv.process($0) { out.append(contentsOf: $0) } }
        i += len
    }
    return out
}
@MainActor func rms(_ x: ArraySlice<Float>) -> Double {
    (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
}
do {
    let out = resample(freq: 1000)
    check(out.count > 7950 && out.count <= 8000, "SRC: ~8000 Samples aus 1 s, got \(out.count)")
    // Kein Sample darf verloren gehen: 1 s mehr Eingang = genau 8000 Samples mehr, bei jeder Blockgröße bitgleich
    // (AVAudioConverter verlor hier je nach Blockgröße Samples, deshalb eigener Wandler)
    for block in [997, 4800, 9600] {
        let a = resample(freq: 1000, block: block), b = resample(freq: 1000, seconds: 2, block: block)
        check(a == out, "SRC: Blockgröße \(block) bitgleich")
        check(b.count - a.count == 8000, "SRC: Blockgröße \(block) exakt 8000/s, got \(b.count - a.count)")
    }
    let x441 = resample(freq: 1000, rate: 44100), y441 = resample(freq: 1000, seconds: 2, rate: 44100)
    check(y441.count - x441.count == 8000, "SRC: 44,1 kHz exakt 8000/s, got \(y441.count - x441.count)")
    let steady = out[1000..<7000]
    check(abs(rms(steady) - 0.3536) < 0.01, "SRC: 1 kHz Pegel erhalten, rms \(rms(steady))")
    var crossings = 0
    for k in steady.indices.dropFirst() where (steady[k - 1] < 0) != (steady[k] < 0) { crossings += 1 }
    let freq = Double(crossings) / 2 / (Double(steady.count) / 8000)
    check(abs(freq - 1000) < 5, "SRC: Frequenz 1 kHz erhalten, got \(freq)")
    // 6 kHz liegt über der neuen Nyquist-Grenze (4 kHz) und muss weggefiltert sein, sonst Spiegelung auf 2 kHz
    let alias = resample(freq: 6000)
    let dBalias = 20 * log10(max(rms(alias[1000..<7000]), 1e-9) / 0.3536)
    check(dBalias < -60, "SRC: 6 kHz um mehr als 60 dB gedämpft, got \(dBalias) dB")
    check(SampleRateConverter(inputRate: 8000, outputRate: 8000) != nil, "SRC: gleiche Rate erlaubt")
}

// MARK: - Audio: Pipeline Ende-zu-Ende (Ringpuffer -> Wandler -> Senke)
do {
    let pipeline = AudioPipeline()
    final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
    let counter = Counter()
    pipeline.addSink { buf in counter.lock.withLock { counter.n += buf.count } }
    pipeline.start(inputRate: 48000)
    Thread.sleep(forTimeInterval: 0.05)
    let block = [Float](repeating: 0.1, count: 24000)   // 0,5 s
    pipeline.ring.write(block, count: block.count)
    Thread.sleep(forTimeInterval: 0.3)
    let got = counter.lock.withLock { counter.n }
    check(got > 3950 && got <= 4000, "Pipeline: 0,5 s bei 48 kHz -> ~4000 Samples bei 8 kHz, got \(got)")
    check(pipeline.deliveredSampleCount == got, "Pipeline: Zähler stimmt")
    check(pipeline.level.take().peakDB > -21, "Pipeline: Pegel gemessen")
    pipeline.stop()
}

// MARK: - Audio: Funkgeräte-Codec über den eingebauten USB-Hub finden (unabhängig vom Port)
do {
    typealias L = RadioCodecLocator
    check(L.parentHubLocation(0x03114320) == 0x03114300, "Hub von 0x03114320")
    check(L.parentHubLocation(0x03114310) == 0x03114300, "Hub von 0x03114310")
    check(L.parentHubLocation(0x03112100) == 0x03112000, "Hub von 0x03112100")
    check(L.locationFromCodecUID("AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:3114310:2") == 0x03114310, "Position aus Codec-UID")
    check(L.locationFromCodecUID("com.val.VALDriver.device") == nil, "Virtuelles Gerät hat keine USB-Position")
    check(L.locationFromCodecUID("BlackHole16ch_UID") == nil, "BlackHole hat keine USB-Position")
    check(L.locationFromPortName("/dev/cu.usbserial-3114320") == 0x03114320, "Position aus Portname")
    check(L.locationFromPortName("/dev/cu.Bluetooth-Incoming-Port") == nil, "Bluetooth-Port ohne Position")

    let dev = { (id: String, name: String) in
        AudioInputDevice(id: id, name: name, inputChannels: 2, nominalSampleRate: 48000,
                         isVirtualCable: AudioDeviceSelection.isVirtualCable(name: name))
    }
    // Stand am Mac des Nutzers (30.09.2026) plus ein angeschlossener FT-991A
    let pcrCodec = dev("AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:3114310:2", "USB Audio CODEC")
    let ftCodec  = dev("AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:3112200:2", "USB Audio CODEC")
    let via      = dev("AppleUSBAudioEngine:VIA Technologies Inc.:USB Audio Device:3113000:2", "USB Audio Device")
    let val      = dev("com.val.VALDriver.device", "VALHost 2ch")
    let bh       = dev("BlackHole16ch_UID", "BlackHole 16ch")
    let devices = [via, ftCodec, bh, pcrCodec, val]
    let pcrPort = USBSerialPortInfo(path: "/dev/cu.usbserial-3114320", usbSerialNumber: "IC-PCR1500 2301040",
                                    usbProductName: "CP2101 USB to UART Bridge Controller", idProduct: 0xEA60, usbLocationID: 0x03114320)
    let ftPort0 = USBSerialPortInfo(path: "/dev/cu.usbserial-01A22C9D0", usbSerialNumber: "01A22C9D",
                                    usbProductName: "CP2105 Dual USB to UART Bridge Controller", idProduct: 0xEA70, usbLocationID: 0x03112100)
    let prolific = USBSerialPortInfo(path: "/dev/cu.PL2303G-USBtoUART311410", usbSerialNumber: "A=BBk19B617",
                                     usbProductName: "USB-Serial Controller", idProduct: 0x23A3, usbLocationID: 0x03114100)
    let ports = [prolific, ftPort0, pcrPort]

    check(L.codec(of: .pcr1500, devices: devices, ports: ports) == pcrCodec, "PCR-1500: Codec am selben Hub")
    check(L.codec(of: .ft991a, devices: devices, ports: ports) == ftCodec, "FT-991A: Codec am selben Hub, nicht der des PCR")
    check(L.codec(of: .pcr1500, devices: devices, ports: [prolific, ftPort0]) == nil, "PCR-1500 ohne Port -> nicht angeschlossen")
    check(L.codec(of: .ft991a, devices: [via, pcrCodec, val], ports: ports) == nil, "FT-991A ohne Codec -> nicht angeschlossen")
    check(L.radio(owning: pcrCodec, devices: devices, ports: ports) == .pcr1500, "Codec gehört zum PCR-1500")
    check(L.radio(owning: via, devices: devices, ports: ports) == nil, "VIA-Karte gehört zu keinem Funkgerät")

    // PCR-1500 an einen anderen Port umgesteckt: neue Positionen, neue UID
    let movedCodec = dev("AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:1223410:2", "USB Audio CODEC")
    let movedPort = USBSerialPortInfo(path: "/dev/cu.usbserial-1223420", usbSerialNumber: "IC-PCR1500 2301040",
                                      usbProductName: nil, idProduct: 0xEA60, usbLocationID: 0x01223420)
    let movedDevices = [via, ftCodec, movedCodec, val]
    check(L.codec(of: .pcr1500, devices: movedDevices, ports: [ftPort0, movedPort]) == movedCodec, "PCR-1500 nach Umstecken wiedergefunden")
    // Ohne IORegistry-Position: aus dem Portnamen
    let noLoc = USBSerialPortInfo(path: "/dev/cu.usbserial-1223420", usbSerialNumber: "IC-PCR1500 2301040",
                                  usbProductName: nil, idProduct: nil, usbLocationID: nil)
    check(L.codec(of: .pcr1500, devices: movedDevices, ports: [noLoc]) == movedCodec, "Position aus Portname als Rückfall")

    // Auswahl auflösen
    typealias S = AudioDeviceSelection
    check(S.resolve(.radio(.pcr1500), devices: devices, ports: ports) == ResolvedInput(device: pcrCodec, radio: .pcr1500), "Wahl PCR-1500")
    check(S.resolve(.radio(.pcr1500), devices: movedDevices, ports: [movedPort]) == ResolvedInput(device: movedCodec, radio: .pcr1500),
          "Gespeicherte Wahl PCR-1500 übersteht Umstecken")
    check(S.resolve(.radio(.pcr1500), devices: [via, val], ports: []) == nil, "PCR-1500 fehlt -> kein Ausweichen auf andere Quelle")
    check(S.resolve(.radio(.pcr1500), uidHint: pcrCodec.id, devices: devices, ports: []) == ResolvedInput(device: pcrCodec, radio: .pcr1500),
          "UID aus dem Auftrag hat Vorrang")
    check(S.resolve(.radio(.pcr1500), uidHint: "veraltet", devices: devices, ports: ports) == ResolvedInput(device: pcrCodec, radio: .pcr1500),
          "Veraltete UID aus dem Auftrag -> Hub-Suche")
    check(S.resolve(.device(uid: val.id), devices: devices, ports: ports) == ResolvedInput(device: val, radio: nil), "Wahl VALHost 2ch")
    check(S.resolve(.device(uid: "weg"), devices: devices, ports: ports) == nil, "Gewähltes Gerät fehlt")
    check(S.resolve(nil, devices: devices, ports: ports) == ResolvedInput(device: pcrCodec, radio: .pcr1500), "Standard: PCR-1500 vor FT-991A")
    check(S.resolve(nil, devices: devices, ports: [ftPort0]) == ResolvedInput(device: ftCodec, radio: .ft991a), "Standard: FT-991A, wenn allein")
    check(S.resolve(nil, devices: [via, bh, val], ports: []) == ResolvedInput(device: val, radio: nil), "Standard ohne Funkgerät: VALHost 2ch")
    check(S.resolve(nil, devices: [via, bh], ports: []) == ResolvedInput(device: bh, radio: nil), "Ohne VALHost: erstes virtuelles Kabel")
    check(S.resolve(nil, devices: [via], ports: []) == ResolvedInput(device: via, radio: nil), "Nur Hardware: erstes Gerät")
    check(S.resolve(nil, devices: [], ports: []) == nil, "Keine Geräte")
    check(S.selection(for: pcrCodec, devices: devices, ports: ports) == .radio(.pcr1500), "Codec im Menü -> als Funkgerät gespeichert")
    check(S.selection(for: val, devices: devices, ports: ports) == .device(uid: val.id), "VALHost im Menü -> als Gerät gespeichert")
    for sel in [InputSelection.radio(.pcr1500), .radio(.ft991a), .device(uid: "AppleUSBAudioEngine:x:y:3113000:2")] {
        check(InputSelection(storageValue: sel.storageValue) == sel, "Speicherformat \(sel.storageValue)")
    }
    check(InputSelection(storageValue: "radio:ic7300") == nil, "Unbekanntes Funkgerät im Speicher")
    check(!S.isVirtualCable(name: "Mac mini-Lautsprecher"), "Lautsprecher nicht virtuell")
    check(RadioSource(requestSource: "PCR1500") == .pcr1500 && RadioSource(requestSource: "wsjtx") == nil, "Quelle aus Auftrag")
}

// MARK: - Audio: Datei öffnen
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("digidec_test_\(getpid()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 11025.0,
                                   AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    do {
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 22050)!
        buf.frameLength = 22050
        for k in 0..<22050 { buf.floatChannelData![0][k] = Float(0.3 * sin(Double(k) * 0.5)) }
        try f.write(from: buf)
    } catch {
        check(false, "Test-WAV schreiben: \(error)")
    }
    if let src = try? WAVFileSource(url: url) {
        check(src.sampleRate == 11025 && src.channelCount == 1 && src.frameCount == 22050, "WAV: Format erkannt")
        check(abs(src.duration - 2.0) < 1e-9, "WAV: Dauer 2 s")
    } else {
        check(false, "WAV: öffnen fehlgeschlagen")
    }
    check((try? WAVFileSource(url: URL(fileURLWithPath: "/nicht/da.wav"))) == nil, "WAV: fehlende Datei -> Fehler")
}

print("\(checks) Prüfungen, \(failures) Fehler")
exit(failures == 0 ? 0 : 1)
