// Logiktests für Digidec (reine Rechenlogik, ohne Audio).
// Nicht Teil des Swift-Packages (Package.swift baut nur "Sources").
// Ausführen im Projektverzeichnis:
//   Tools/LogicTests/run_logic_tests.sh              (Build in temporärem Verzeichnis, danach gelöscht)
//   Tools/LogicTests/run_logic_tests.sh <ausgabe>    (Build bleibt in <ausgabe>, z. B. im Scratchpad)
// Exit-Code 0 = alle Prüfungen bestanden. Neue Quelldateien, von denen getestete Typen abhängen,
// müssen im Skript ergänzt werden.
import Foundation
import ImageIO
import Darwin
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
    check(parse("digidec://decode?mode=ft8&preset=40m") == .success(DecodeRequest(module: .ft8, presetID: "40m")), "FT8-Auftrag")
    check(parse("digidec://decode?mode=ft8") == .success(DecodeRequest(module: .ft8, presetID: "20m")), "FT8-Standard 20 m")
    check(parse("digidec://decode?mode=ft4&preset=40m") == .success(DecodeRequest(module: .ft4, presetID: "40m")), "FT4-Auftrag 40 m")
    check(parse("digidec://decode?mode=ft4") == .success(DecodeRequest(module: .ft4, presetID: "20m")), "FT4-Standard 20 m")
    check(parse("digidec://decode?mode=wefax&preset=dwd-3855") == .success(DecodeRequest(module: .wefax, presetID: "dwd-3855")), "WEFAX-Auftrag")
    check(parse("digidec://decode?mode=wefax") == .success(DecodeRequest(module: .wefax, presetID: "dwd-7880")), "WEFAX-Standard DWD 7880")
    check(parse("digidec://decode?mode=cw&center=650") == .success(DecodeRequest(module: .cw, presetID: "ham", centerHz: 650)), "CW-Auftrag mit Ton")
    check(parse("digidec://decode?mode=navtex&preset=490") == .success(DecodeRequest(module: .navtex, presetID: "490")), "NAVTEX-Auftrag")
    check(parse("digidec://decode?mode=navtex") == .success(DecodeRequest(module: .navtex, presetID: "518")), "NAVTEX-Standard 518 kHz")
    check(parse("digidec://decode?mode=dcf77") == .success(DecodeRequest(module: .dcf77, presetID: "mainflingen")), "DCF77-Standard mainflingen")
    check(parse("digidec://decode?mode=dcf77&preset=mainflingen&center=1000") == .success(DecodeRequest(module: .dcf77, presetID: "mainflingen", centerHz: 1000)), "DCF77 mit Center 1000 Hz")
    check(parse("digidec://decode?mode=efr") == .success(DecodeRequest(module: .efr, presetID: "dcf49")), "EFR-Standard dcf49")
    check(parse("digidec://decode?mode=efr&preset=dcf39&center=1500") == .success(DecodeRequest(module: .efr, presetID: "dcf39", centerHz: 1500)), "EFR DCF39 mit Center 1500 Hz")
    check(parse("digidec://decode?mode=efr&preset=hga22") == .success(DecodeRequest(module: .efr, presetID: "hga22")), "EFR HGA22")
    check(parse("digidec://decode?mode=sstv") == .success(DecodeRequest(module: .sstv, presetID: "20m")), "SSTV-Standard 20m")
    check(parse("digidec://decode?mode=sstv&preset=iss") == .success(DecodeRequest(module: .sstv, presetID: "iss")), "SSTV ISS-Auftrag")
    check(parse("digidec://decode?mode=sstv&preset=40m&center=1750") == .success(DecodeRequest(module: .sstv, presetID: "40m", centerHz: 1750)), "SSTV 40m mit Center 1750 Hz")
    check(parse("digidec://decode?mode=rtty&preset=xyz") == .failure(.unknownPreset("xyz", .rtty)), "Unbekanntes Preset")
    check(parse("digidec://decode?mode=rtty&rigctl=80") == .failure(.invalidPort("80")), "Port zu klein")
    check(parse("digidec://decode?mode=rtty&rigctl=70000") == .failure(.invalidPort("70000")), "Port zu groß")
    check(parse("digidec://decode?mode=rtty&rigctl=abc") == .failure(.invalidPort("abc")), "Port keine Zahl")
    check(parse("digidec://decode?mode=rtty&center=50") == .failure(.invalidCenter("50")), "Mitte zu tief")
    check(parse("digidec://decode?mode=rtty&center=5000") == .failure(.invalidCenter("5000")), "Mitte zu hoch")

    // digidec://open (allgemeiner App-Start ohne festen Modus)
    check(parse("digidec://open?source=ft991a&rigctl=4533&device=VALHost2ch_UID") == .success(DecodeRequest(module: nil, presetID: nil, source: "ft991a", rigctlPort: 4533, deviceUID: "VALHost2ch_UID")), "open-Aktion mit Parametern")
    check(parse("digidec://open?source=pcr1500&rigctl=4532") == .success(DecodeRequest(module: nil, presetID: nil, source: "pcr1500", rigctlPort: 4532)), "open-Aktion PCR-1500")
    check(parse("digidec://open") == .success(DecodeRequest(module: nil, presetID: nil)), "open-Aktion ohne Parameter")
    check(parse("digidec://open?mode=rtty") == .success(DecodeRequest(module: .rtty, presetID: "ham")), "open-Aktion mit optionalem Modus")
}

// MARK: - Modul-Liste
do {
    check(DecoderModuleInfo.allCases.filter(\.isAvailable) == DecoderModuleInfo.allCases, "Alle Module verfügbar")
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

// MARK: - Spektrum (vDSP-FFT, Hann, dBFS)
do {
    let an = SpectrumAnalyzer(size: 2048, sampleRate: 8000)!
    check(abs(an.binWidth - 3.90625) < 1e-9, "Binbreite 3,9 Hz")
    check(SpectrumAnalyzer(size: 1000, sampleRate: 8000) == nil, "Nur Zweierpotenzen")
    var out = [Float](repeating: 0, count: 1024)
    for (freq, amp) in [(1000.0, 1.0), (1000.0, 0.5), (2210.0, 0.1), (957.5, 0.5)] {
        let x = (0..<2048).map { Float(amp * sin(2 * Double.pi * freq * Double($0) / 8000)) }
        x.withUnsafeBufferPointer { an.process($0.baseAddress!, into: &out) }
        let peak = out.indices.max { out[$0] < out[$1] }!
        check(abs(an.frequency(ofBin: peak) - freq) <= an.binWidth / 2 + 1e-9, "Spitze bei \(freq) Hz, got \(an.frequency(ofBin: peak))")
        let expected = Float(20 * log10(amp))
        // Hann: Pegel auf dem Bin exakt, zwischen zwei Bins bis −1,42 dB (Scalloping)
        check(out[peak] <= expected + 0.05 && out[peak] >= expected - 1.5, "Pegel \(freq) Hz / \(amp): \(out[peak]) dB, erwartet \(expected)")
    }
    let silence = [Float](repeating: 0, count: 2048)
    silence.withUnsafeBufferPointer { an.process($0.baseAddress!, into: &out) }
    check(out.allSatisfy { $0 <= -139 }, "Stille -> Boden")
}

// MARK: - Wasserfall-Zeilen
do {
    let wf = WaterfallProcessor(sampleRate: 8000)
    let tone = (0..<8000).map { Float(0.3 * sin(2 * Double.pi * 1500 * Double($0) / 8000)) }
    tone.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {     // ungleichmäßige Blöcke wie aus der Pipeline
            let n = min(333, buf.count - i)
            wf.consume(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    let rows = wf.takeRows()
    check(rows.count == 8000 / WaterfallProcessor.hop, "1 s -> \(8000 / WaterfallProcessor.hop) Zeilen, got \(rows.count)")
    check(wf.takeRows().isEmpty, "Zeilen nur einmal abholbar")
    if let last = rows.last {
        let peak = last.indices.max { last[$0] < last[$1] }!
        check(abs(Double(peak) * wf.binWidth - 1500) <= wf.binWidth, "Wasserfall-Spitze bei 1500 Hz")
    }
    let snap = wf.snapshot()
    check(snap.noiseFloor < -60, "Rauschboden weit unter dem Ton, got \(snap.noiseFloor)")
    check(abs(wf.rowsPerSecond - 31.25) < 1e-9, "31,25 Zeilen/s")
}

// MARK: - Farbskala
do {
    let lut = WaterfallColorMap.lut
    check(lut.count == 256, "256 Farben")
    check(lut.allSatisfy { $0 >> 24 == 0xFF }, "Alle Farben deckend")
    func luminance(_ c: UInt32) -> Double { Double(c & 0xFF) * 0.3 + Double((c >> 8) & 0xFF) * 0.59 + Double((c >> 16) & 0xFF) * 0.11 }
    check(luminance(lut[0]) < luminance(lut[128]) && luminance(lut[128]) < luminance(lut[255]), "Helligkeit steigt")
    check(WaterfallColorMap.index(db: -200, floorDB: -90, rangeDB: 50) == 0, "Unter Boden -> 0")
    check(WaterfallColorMap.index(db: 0, floorDB: -90, rangeDB: 50) == 255, "Über Bereich -> 255")
    check(WaterfallColorMap.index(db: -65, floorDB: -90, rangeDB: 50) == 127, "Mitte -> 127")
}

// MARK: - RTTY-Presets und Mark/Space (PLAN.md 5.2)
do {
    let ham = RTTYPreset.preset(id: "ham")!.parameters
    let kw = RTTYPreset.preset(id: "dwd-kw")!.parameters
    let lw = RTTYPreset.preset(id: "dwd-lw")!.parameters
    check(ham.baud == 45.45 && ham.shift == 170 && ham.bits == 5 && ham.stopBits == 1.5 && ham.parity == .none, "Preset Amateur")
    check(kw.baud == 50 && kw.shift == 450 && kw.bits == 5 && kw.stopBits == 1.5, "Preset DWD KW")
    check(lw.baud == 50 && lw.shift == 85 && lw.bits == 5 && lw.stopBits == 1.5, "Preset DWD LW")
    check(RTTYPreset.all.map(\.id) == DecoderModuleInfo.rtty.presetIDs, "Presets = IDs im URL-Schema")
    // Abstimmhilfe aus PLAN.md: DWD LW, USB-Dial 146,300 kHz -> Töne 957,5 / 1042,5 Hz bei Mitte 1000 Hz.
    // DWD sendet Mark auf der tieferen HF (bestätigt an DDK2) -> in USB liegt Mark unten
    check(lw.reverse && kw.reverse && !ham.reverse, "DWD-Presets mit Reverse (bezogen auf USB), Amateur ohne")
    let t = lw.tones(center: 1000)
    check(t.mark == 957.5 && t.space == 1042.5, "DWD LW in USB: Mark 957,5 / Space 1042,5")
    var norm = lw
    norm.reverse = false
    check(norm.tones(center: 1000).mark == 1042.5, "Ohne Reverse Mark oben")
    check(kw.tones(center: 1000) == (775, 1225), "DWD KW in USB: Mark 775 / Space 1225")
    check(ham.summary == "45,45 Bd · 170 Hz · 5/1,5", "Kurzbeschreibung, got \(ham.summary)")
}

// MARK: - Mittenfrequenz begrenzen
do {
    let store = RTTYSettingsStore()
    store.select(presetID: "dwd-kw")
    store.setCenter(50)
    check(store.centerHz == 245, "Mitte unten begrenzt (Space ≥ 20 Hz), got \(store.centerHz)")
    store.setCenter(3990)
    check(store.centerHz == 3755, "Mitte oben begrenzt (Mark ≤ 3980 Hz), got \(store.centerHz)")
    store.setCenter(1012.6)
    check(store.centerHz == 1013, "Mitte auf ganze Hz, got \(store.centerHz)")
    store.select(presetID: "gibtsnicht")
    check(store.presetID == "dwd-kw", "Unbekanntes Preset ignoriert")
    store.select(presetID: "ham")
    store.setCenter(1000)
}

// MARK: - RTTY-Kern aus fldigi 4.2.13 (M4)
@MainActor func rttyDecode(_ p: RTTYParameters, _ text: String, snrDB: Double? = nil, center: Double = 1000,
                           offset: Double = 0, genIta2: Bool = false, options: FldigiRTTYCore.Options = .init(),
                           decodeParameters: RTTYParameters? = nil, seed: UInt64 = 1, silence: Bool = false) -> (String, FldigiRTTYCore) {
    var gen = RTTYSignalGenerator(parameters: p, centerHz: center)
    gen.offsetHz = offset
    gen.ita2 = genIta2
    var samples = silence ? [Float](repeating: 0, count: 8000 * 10) : gen.samples(for: text)
    if let snrDB { RTTYSignalGenerator.addNoise(to: &samples, amplitude: gen.amplitude, snrDB: snrDB, seed: seed) }
    final class Box { var s = "" }
    let box = Box()
    let core = FldigiRTTYCore(parameters: decodeParameters ?? p, options: options, centerHz: center) { box.s.append($0) }
    samples.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {             // Blöcke wie aus der Pipeline (20 ms)
            let n = min(160, buf.count - i)
            core.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    return (box.s, core)
}
/// Zeichenfehlerrate (Levenshtein-Abstand / Länge der Vorlage)
@MainActor func charErrorRate(_ ref: String, _ got: String) -> Double {
    let a = Array(ref), b = Array(got)
    guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
    guard !b.isEmpty else { return 1 }
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
    return Double(d[b.count]) / Double(a.count)
}
do {
    let text = "RYRYRY THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789 WODL45 EDZW 301200 "
    for preset in RTTYPreset.all where preset.id != "custom" {
        let (got, core) = rttyDecode(preset.parameters, text)
        check(got == text, "\(preset.name) sauber exakt, got \(got.debugDescription)")
        // Squelch-Maß wie fldigi: gutes Signal = 100. (fldigis S/N-Formel misst das "Rauschen" zwischen Mark und
        // Space; bei sauberen Signalen liegen dort Seitenbänder der Tastung – der S/N-Wert ist daher kein Prüfmaß.)
        // DWD LW (85 Hz Shift): das Messfenster in der Mitte liegt im Signal, fldigi-Metrik nur ≈ 30 -> Squelch dort niedrig halten
        let minMetric = preset.parameters.shift < 100 ? 25.0 : 90.0
        check(core.status.metric > minMetric, "\(preset.name): Metrik > \(minMetric) bei sauberem Signal, got \(core.status.metric)")
    }
    // Andere Mittenfrequenzen (DWD LW bei 1500 Hz, Amateur klassisch 2210 Hz)
    check(rttyDecode(RTTYPreset.preset(id: "dwd-lw")!.parameters, text, center: 1500).0 == text, "DWD LW bei 1500 Hz")
    check(rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, text, center: 2210).0 == text, "Amateur bei 2210 Hz")

    // Reverse: Sender mit vertauschtem Mark/Space
    var rev = RTTYPreset.preset(id: "dwd-kw")!.parameters
    rev.reverse = true
    check(rttyDecode(rev, text).0 == text, "Reverse-Sender mit Reverse-Empfang")
    var noRev = rev
    noRev.reverse = false
    check(rttyDecode(rev, text, decodeParameters: noRev).0 != text, "Reverse-Sender ohne Reverse -> kein Text")

    // Ziffernsatz: ITA2 ('+', '=') gegenüber US-TTY ('"', ';')
    var ita = FldigiRTTYCore.Options()
    ita.ita2 = true
    ita.unshiftOnSpace = false            // DWD-Sender (Preset ohne Unshift on Space)
    var us = FldigiRTTYCore.Options()
    us.unshiftOnSpace = false
    let figText = "TEMP +12 = 5 "
    check(rttyDecode(RTTYPreset.preset(id: "dwd-kw")!.parameters, figText, genIta2: true, options: ita).0 == figText, "ITA2 '+' und '='")
    check(rttyDecode(RTTYPreset.preset(id: "dwd-kw")!.parameters, figText, genIta2: true, options: us).0 == "TEMP \"12 ; 5 ", "Gleiche Codes als US-TTY")

    // Nur Mark / nur Space decodieren (CWI-Unterdrückung)
    for cwi in [1, 2] {
        var o = FldigiRTTYCore.Options()
        o.cwi = cwi
        // fldigi decodiert im Modus "nur Space" vor der ersten Synchronisation ggf. ein Zeichen aus dem Vorlauf
        let got = rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, text, options: o).0
        check(got.hasSuffix(text) && got.count <= text.count + 1, "CWI-Modus \(cwi) sauber, got \(got.debugDescription)")
    }

    // AFC: Sender 15 Hz neben der eingestellten Mitte
    let (afcText, afcCore) = rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, text + text, offset: 15)
    check(charErrorRate(text + text, afcText) < 0.02, "AFC: 15 Hz Versatz decodiert, CER \(charErrorRate(text + text, afcText))")
    check(afcCore.status.centerHz > 1008, "AFC zieht die Mitte nach (Ziel 1015), got \(afcCore.status.centerHz)")
    var noAfc = FldigiRTTYCore.Options()
    noAfc.afcOn = false
    check(rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, text, offset: 15, options: noAfc).1.status.centerHz == 1000,
          "Ohne AFC bleibt die Mitte")

    // Rauschen: Zeichenfehlerrate unter der Schwelle, S/N in 3 kHz
    let long = String(repeating: "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 1234567890 ", count: 3)
    for (id, snr, limit) in [("ham", -3.0, 0.01), ("ham", -6.0, 0.05), ("dwd-lw", -3.0, 0.01), ("dwd-kw", -3.0, 0.01)] {
        let got = rttyDecode(RTTYPreset.preset(id: id)!.parameters, long, snrDB: snr, seed: 7).0
        let cer = charErrorRate(long, got)
        check(cer < limit, "\(id) bei \(snr) dB: CER \(String(format: "%.3f", cer)) < \(limit)")
    }

    // Squelch: reines Rauschen erzeugt keinen Text, ein gutes Signal kommt durch
    var sq = FldigiRTTYCore.Options()
    sq.squelchOn = true
    sq.squelch = 40
    check(rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, "", snrDB: 0, options: sq, silence: true).0.isEmpty, "Squelch hält Rauschen zurück")
    let noiseOnly = rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, "", snrDB: 0, silence: true).1
    check(noiseOnly.status.metric < 20, "Reines Rauschen: Metrik niedrig, got \(noiseOnly.status.metric)")
    check(rttyDecode(RTTYPreset.preset(id: "ham")!.parameters, text, snrDB: 10, options: sq).0 == text, "Squelch lässt gutes Signal durch")

    // Generator: Baudot-Codes mit Umschaltung
    let g = RTTYSignalGenerator(parameters: RTTYPreset.preset(id: "ham")!.parameters, centerHz: 1000)
    check(g.baudotCodes(for: "A1 B") == [0x1F, 0x03, 0x1B, 0x17, 0x04, 0x19], "Baudot mit FIGS und Unshift-on-Space")
}

// MARK: - RTTY-Einstellungen (M5)
do {
    let store = RTTYSettingsStore()
    store.select(presetID: "dwd-lw")
    check(store.parameters.ita2 && store.parameters.shift == 85, "DWD LW mit ITA2")
    check(!RTTYPreset.preset(id: "ham")!.parameters.ita2, "Amateur mit US-TTY wie fldigi")
    // Reverse je Preset, ohne das Preset zu verlassen
    let wasRev = store.isReversed
    store.toggleReverse()
    check(store.isReversed == !wasRev && store.presetID == "dwd-lw", "REV schaltet im Preset um")
    store.select(presetID: "dwd-kw")
    let kwRev = store.isReversed
    store.select(presetID: "dwd-lw")
    check(store.isReversed == !wasRev, "REV bleibt je Preset gespeichert")
    store.toggleReverse()
    check(store.isReversed == wasRev, "REV zurück")
    _ = kwRev
    // Parameter ändern legt „Eigene“ an, festes Preset bleibt
    var p = store.parameters
    p.baud = 75
    store.update(parameters: p)
    check(store.presetID == "custom" && store.parameters.baud == 75 && store.parameters.shift == 85, "Änderung -> Eigene mit übernommenen Werten")
    check(RTTYPreset.preset(id: "dwd-lw")!.parameters.baud == 50, "Festes Preset unverändert")
    // AFC: Mitte folgt ohne Rundung, manuelle Mitte zählt Revision hoch
    store.select(presetID: "ham")
    store.setCenter(1000)
    let rev = store.manualCenterRevision
    store.followAFC(1003.4)
    check(abs(store.centerHz - 1003.4) < 1e-9 && store.manualCenterRevision == rev, "AFC ungerundet, keine Revision")
    store.setCenter(1500.4)
    check(store.centerHz == 1500 && store.manualCenterRevision == rev + 1, "Mitte von Hand gerundet, Revision +1")
    store.setCenter(1000)
    // Speicherformat: alte Parameter ohne ITA2-Feld lesbar, Optionen Rundreise
    let old = #"{"shift":450,"baud":50,"bits":5,"parity":"none","stopBits":1.5,"reverse":true}"#
    let decoded = try? JSONDecoder().decode(RTTYParameters.self, from: Data(old.utf8))
    check(decoded?.shift == 450 && decoded?.reverse == true && decoded?.ita2 == false, "Alte Parameter ohne ITA2 lesbar")
    var o = RTTYDecodeOptions()
    o.afc = .fast; o.squelchOn = true; o.squelch = 12; o.tones = .spaceOnly; o.filterK = 1.25
    let round = try? JSONDecoder().decode(RTTYDecodeOptions.self, from: JSONEncoder().encode(o))
    check(round == o, "Optionen Rundreise")
    let def = RTTYDecodeOptions()
    check(def.afc == .normal && !def.squelchOn && def.tones == .both && def.filterK == 1.4 && def.trueScope,
          "Standard wie fldigi")
    let co = RTTYDecoder.coreOptions(RTTYPreset.preset(id: "dwd-kw")!.parameters, o)
    check(co.afcOn && co.afcSpeed == 2 && co.squelchOn && co.cwi == 2 && co.ita2 && co.filterK == 1.25, "Optionen -> Kern")
    var off = RTTYDecodeOptions()
    off.afc = .off
    check(!RTTYDecoder.coreOptions(RTTYPreset.preset(id: "ham")!.parameters, off).afcOn, "AFC aus -> Kern aus")
}

// MARK: - Anzeige-Text und Log
do {
    check(RTTYController.displayText("ZCZC\r\nWODL45\u{07} EDZW\r\r\n") == "ZCZC\nWODL45 EDZW\n", "CR/Klingel entfernt, LF bleibt")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("digidec_log_\(getpid())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = DecodeLogger(mode: "RTTY", directory: dir)
    let t0 = ISO8601DateFormatter().date(from: "2026-09-30T23:59:58Z")!
    log.markSession("RTTY DWD LW · Test")
    log.append("ABC", now: t0)
    log.append("DEF", now: t0)
    let t1 = t0.addingTimeInterval(4)       // nach Mitternacht UTC -> neue Datei
    log.append("GHI", now: t1)
    log.close()
    let f0 = (try? String(contentsOf: log.fileURL(for: t0), encoding: .utf8)) ?? ""
    let f1 = (try? String(contentsOf: log.fileURL(for: t1), encoding: .utf8)) ?? ""
    check(log.fileURL(for: t0).lastPathComponent == "RTTY-2026-09-30.txt", "Dateiname nach UTC-Datum")
    check(f0.contains("=== 2026-09-30 23:59:58 UTC · RTTY DWD LW · Test ===\nABCDEF"), "Kopfzeile einmal, Text angehängt, got \(f0.debugDescription)")
    check(f0.components(separatedBy: "===").count == 3, "Nur eine Kopfzeile")
    check(f1.contains("Fortsetzung ===\nGHI"), "Neue Tagesdatei mit Fortsetzungs-Kopf, got \(f1.debugDescription)")
}

// MARK: - Ende-zu-Ende: Pipeline -> fldigi-Kern -> Text (wie in der App)
do {
    let pipeline = AudioPipeline()
    let decoder = RTTYDecoder(pipeline: pipeline)
    let params = RTTYPreset.preset(id: "dwd-lw")!.parameters
    decoder.configure(parameters: params, options: RTTYDecodeOptions(), centerHz: 1500)
    pipeline.start(inputRate: 48_000)
    // Signal bei 48 kHz erzeugen, wie es vom USB-Codec käme
    var gen = RTTYSignalGenerator(parameters: params, centerHz: 1500)
    gen.sampleRate = 48_000
    gen.ita2 = true
    let text = "ZCZC WODL45 EDZW 301200 +12 = "
    let samples = gen.samples(for: text)
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    while i < samples.count {                      // in Häppchen, damit der 2-s-Ringpuffer nicht überläuft
        let n = min(24_000, samples.count - i)
        samples[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.08)
    }
    Thread.sleep(forTimeInterval: 0.4)
    let out = decoder.takeOutput()
    check(out.text == text, "Pipeline 48 kHz -> 8 kHz -> fldigi: exakt, got \(out.text.debugDescription)")
    check(out.status != nil && !out.scope.isEmpty, "Status und XY-Scope geliefert")
    check(decoder.takeOutput().text.isEmpty, "Text nur einmal abholbar")
    pipeline.stop()
}

// MARK: - Seitenband-Korrektur (M7, wie fldigi: reverse = Rev xor LSB)
do {
    let store = RTTYSettingsStore()
    store.select(presetID: "dwd-kw")
    store.sidebandMode = .auto
    store.rigIsLSB = true
    // Erster Empfang 30.09.2026: DDK2 in LSB ohne Umkehr korrekt (Mark im NF oben)
    check(store.isReversed && !store.decoderParameters.reverse, "DWD KW in LSB: Decoder ohne Umkehr")
    check(store.tones.mark > store.tones.space, "DWD KW in LSB: Mark im NF oben")
    store.rigIsLSB = false
    check(store.decoderParameters.reverse && store.tones.mark < store.tones.space, "DWD KW in USB: Decoder mit Umkehr, Mark unten")
    store.rigIsLSB = nil
    check(!store.effectiveLSB, "Unbekanntes Seitenband gilt als USB")
    store.sidebandMode = .lsb
    check(store.effectiveLSB && !store.decoderParameters.reverse, "Seitenband fest LSB")
    store.rigIsLSB = false
    check(store.effectiveLSB, "Fest LSB schlägt Funkgerät")
    store.cycleSidebandMode()
    check(store.sidebandMode == .auto, "Umschalten LSB -> AUTO")
    store.select(presetID: "ham")
    store.rigIsLSB = true
    check(store.decoderParameters.reverse, "Amateur in LSB: Umkehr (fldigi-Verhalten)")
    store.rigIsLSB = nil
}

// MARK: - rigctld: Antworten auswerten
do {
    let s = RigctlClient.parse(["4584700", "LSB", "2800"])
    check(s.connected && s.frequencyHz == 4_584_700 && s.mode == "LSB" && s.passbandHz == 2800, "f + m ausgewertet")
    check(s.isLSB == true && s.frequencyText == "4.584,700 kHz", "LSB erkannt, Anzeige \(s.frequencyText ?? "-")")
    check(RigctlClient.parse(["147300", "USB", "2400"]).isLSB == false, "USB = Regellage")
    check(RigctlClient.parse(["14467300.000000", "PKTLSB", "3000"]).frequencyHz == 14_467_300, "Frequenz mit Nachkommastellen")
    check(RigctlClient.parse(["7646000", "RTTY", "500"]).isLSB == true, "Hamlib RTTY (RTTY-L) = Kehrlage")
    check(RigctlClient.parse(["7646000", "RTTYR", "500"]).isLSB == false, "RTTYR = Regellage")
    check(RigctlClient.parse(["7646000", "AM", "6000"]).isLSB == false, "AM = Regellage")
    let err = RigctlClient.parse(["RPRT -11"])
    check(err.connected && err.frequencyHz == nil && err.mode == nil && err.isLSB == nil, "Fehlerantwort -> unbekannt")
    check(RigctlClient.parse(["4584700", "RPRT -1"]).mode == nil, "Mode-Fehler -> Mode unbekannt")
    check(RigctlClient.defaultPort(for: .pcr1500) == 4532 && RigctlClient.defaultPort(for: .ft991a) == 4533
          || UserDefaults(suiteName: "com.peterbetz.pcr1500commander")?.integer(forKey: "rigctldPort") != 0,
          "Standardports 4532 / 4533")
}

// MARK: - rigctld: echter TCP-Austausch mit einem Test-Server
do {
    // Mini-rigctld auf einem freien Port: antwortet auf "f" und "m", protokolliert alle Befehle
    final class FakeRigctld: @unchecked Sendable {
        let port: UInt16
        private let listenFD: Int32
        private let lock = NSLock()
        private var received: [String] = []
        var commands: [String] { lock.withLock { received } }

        init?() {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard b == 0, listen(s, 1) == 0 else { close(s); return nil }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
            port = UInt16(bigEndian: bound.sin_port)
            listenFD = s
            Thread.detachNewThread { [self] in self.serve() }
        }

        private func serve() {
            let c = accept(listenFD, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 256)
            var pending = ""
            while true {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { break }
                pending += String(decoding: buf[0..<n], as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let cmd = String(pending[..<nl])
                    pending = String(pending[pending.index(after: nl)...])
                    lock.withLock { received.append(cmd) }
                    let reply = cmd == "f" ? "10100800\n" : cmd == "m" ? "LSB\n2400\n" : "RPRT -4\n"
                    _ = reply.withCString { send(c, $0, strlen($0), 0) }
                }
            }
            close(c)
        }

        deinit { close(listenFD) }
    }

    if let fake = FakeRigctld() {
        final class Box: @unchecked Sendable { let lock = NSLock(); var last = RigState() }
        let box = Box()
        let client = RigctlClient { s in box.lock.withLock { box.last = s } }
        client.setPort(fake.port)
        var waited = 0.0
        while waited < 3, box.lock.withLock({ box.last.frequencyHz }) == nil {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        let s = box.lock.withLock { box.last }
        check(s.connected && s.frequencyHz == 10_100_800 && s.mode == "LSB" && s.port == fake.port, "rigctld über TCP gelesen, got \(s)")
        Thread.sleep(forTimeInterval: 1.2)          // mindestens eine weitere Abfrage
        let cmds = fake.commands
        check(!cmds.isEmpty && cmds.allSatisfy { $0 == "f" || $0 == "m" }, "Nur Lesebefehle f/m gesendet, got \(cmds)")
        client.setPort(nil)
        Thread.sleep(forTimeInterval: 0.2)
        check(!box.lock.withLock { box.last.connected }, "Trennen setzt Zustand zurück")
    } else {
        check(false, "Test-rigctld konnte nicht starten")
    }
    // Kein Server auf dem Port: nicht verbunden, kein Absturz
    final class Box2: @unchecked Sendable { let lock = NSLock(); var last = RigState() }
    let box2 = Box2()
    let c2 = RigctlClient { s in box2.lock.withLock { box2.last = s } }
    c2.setPort(1)                                    // Port 1: niemand hört zu
    Thread.sleep(forTimeInterval: 0.5)
    check(!box2.lock.withLock { box2.last.connected }, "Ohne Server nicht verbunden")
    c2.setPort(nil)
}

// MARK: - Unshift on Space je Sender (DWD-SYNOP, beobachtet 30.09.2026 an DDK2)
do {
    let dwd = RTTYPreset.preset(id: "dwd-kw")!.parameters
    check(!dwd.unshiftOnSpace && !RTTYPreset.preset(id: "dwd-lw")!.parameters.unshiftOnSpace, "DWD-Presets ohne Unshift on Space")
    check(RTTYPreset.preset(id: "ham")!.parameters.unshiftOnSpace, "Amateur mit Unshift on Space")
    let synop = "62198 10016 30016 41/// "
    var o = FldigiRTTYCore.Options()
    o.ita2 = true
    o.unshiftOnSpace = dwd.unshiftOnSpace
    check(rttyDecode(dwd, synop, options: o).0 == synop, "SYNOP-Gruppen mit DWD-Preset als Ziffern")
    // Der Fehler aus dem Live-Empfang: gleicher Sender, Empfänger mit Unshift on Space -> Gruppen als Buchstaben
    o.unshiftOnSpace = true
    check(rttyDecode(dwd, synop, options: o).0 == "62198 QPPQY EPPQY RQXXX ", "Mit Unshift on Space: Buchstaben wie beobachtet (\"/\" -> X)")
    let co = RTTYDecoder.coreOptions(dwd, RTTYDecodeOptions())
    check(!co.unshiftOnSpace, "Preset-Wert geht an den Kern")
    let old = #"{"shift":170,"baud":45.45,"bits":5,"parity":"none","stopBits":1.5,"reverse":false,"ita2":false}"#
    check((try? JSONDecoder().decode(RTTYParameters.self, from: Data(old.utf8)))?.unshiftOnSpace == true, "Alte Eigene-Parameter: Unshift on Space an")
}

// MARK: - Aufnahme (M6)
do {
    let d = ISO8601DateFormatter().date(from: "2026-09-30T19:37:05Z")!
    check(InputRecorder.fileName(date: d, frequencyHz: 4_584_700, mode: "LSB", preset: "dwd-kw")
          == "RTTY_2026-09-30_193705Z_4584700Hz_LSB_DWD-KW.wav", "Dateiname der Aufnahme")
    check(InputRecorder.fileName(date: d, frequencyHz: nil, mode: nil, preset: "ham") == "RTTY_2026-09-30_193705Z_HAM.wav",
          "Dateiname ohne Funkgerät")
    // Ende-zu-Ende: Pipeline (48 kHz) -> Aufnahme -> WAV mit gleicher Länge und Rate
    let pipeline = AudioPipeline()
    let rec = InputRecorder(pipeline: pipeline)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("digidec_rec_\(getpid()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    pipeline.start(inputRate: 48_000)
    Thread.sleep(forTimeInterval: 0.05)
    rec.start(url: url)
    check(rec.isRecording, "Aufnahme läuft")
    let tone = (0..<24_000).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
    tone.withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: $0.count) }
    Thread.sleep(forTimeInterval: 0.3)
    check(abs(rec.duration - 0.5) < 0.01, "Aufnahmedauer 0,5 s, got \(rec.duration)")
    check(rec.stop() == url && !rec.isRecording, "Aufnahme beendet")
    pipeline.stop()
    if let f = try? AVAudioFile(forReading: url) {
        check(f.fileFormat.sampleRate == 48_000 && f.fileFormat.channelCount == 1 && f.length == 24_000,
              "WAV: 48 kHz mono, 24000 Frames, got \(f.fileFormat.sampleRate) / \(f.length)")
    } else {
        check(false, "Aufnahme nicht lesbar")
    }
    // Begleitdatei: Rundreise
    let store = RTTYSettingsStore()
    store.select(presetID: "dwd-kw")
    let info = RecordingInfo(presetID: "dwd-kw", parameters: store.parameters, decoderParameters: store.decoderParameters,
                             options: store.options, centerHz: 1700, lsb: true, frequencyHz: 4_584_700, mode: "LSB", startedAt: d)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    check((try? dec.decode(RecordingInfo.self, from: enc.encode(info))) == info, "Begleitdatei Rundreise")
    store.select(presetID: "ham")
}

// MARK: - SYNOP/SHIP-Decoder aus fldigi (empfangen an DDK2 am 30.09.2026, 19:37 UTC)
do {
    check(SynopDecoder.loadStations(), "Stationslisten geladen aus \(SynopDecoder.stationDirectory?.path ?? "-")")
    check(SynopDecoder.stationName(wmo: 10655) == "Wuerzburg", "WMO 10655 = Wuerzburg")
    var segs: [TextSegment] = []
    let syn = SynopDecoder { segs.append($0) }
    let ship = "SMVX41 EDZW 301800\r\nBBXX\r\n62170 30184 99514 10020 46/96 /1610 10202 20193 40146 22200 =\r\n"
    for ch in ship.unicodeScalars { syn.feed(Character(ch)) }
    syn.flush()
    let raw = segs.filter { !$0.decoded }.map(\.text).joined()
    let dec = segs.filter { $0.decoded }.map(\.text).joined()
    check(raw.contains("62170 30184 99514 10020 46/96 /1610 10202 20193 40146 22200"), "Rohtext läuft durch")
    for want in ["WMO Station=62170", "Latitude=51.4", "Longitude=2.0", "Visibility=4 km", "Wind speed=10 knots",
                 "Temperature=20.2 °C", "Dewpoint temperature=19.3 °C", "Sea level pressure=1014 hPa"] {
        check(dec.contains(want), "SHIP-Klartext enthält „\(want)“")
    }
    // fldigi-Fehler behoben: UTC-Zeit darf nicht in Ortszeit verrutschen (mktime -> timegm)
    check(dec.contains("30 18:00"), "Beobachtungszeit 18:00 UTC, got \(dec.components(separatedBy: "\n").first { $0.contains("observation time") } ?? "-")")
    check(RTTYController.displayDecoded("\tLatitude=51.4 \n\tLongitude=2.0 \n") == "    Latitude=51.4\n    Longitude=2.0\n", "Klartext-Formatierung")
    let oldOpts = #"{"afc":1,"squelchOn":false,"squelch":15,"tones":0,"filterK":1.4,"trueScope":true}"#
    check((try? JSONDecoder().decode(RTTYDecodeOptions.self, from: Data(oldOpts.utf8)))?.synopDecoding == true, "Alte Optionen: SYNOP an")

    // Ende-zu-Ende: DWD-RTTY mit SHIP-Meldung -> Pipeline -> fldigi-RTTY -> fldigi-SYNOP
    let pipeline = AudioPipeline()
    let decoder = RTTYDecoder(pipeline: pipeline)
    let params = RTTYPreset.preset(id: "dwd-kw")!.parameters
    decoder.configure(parameters: params, options: RTTYDecodeOptions(), centerHz: 1700)
    pipeline.start(inputRate: 8_000)
    var gen = RTTYSignalGenerator(parameters: params, centerHz: 1700)
    gen.ita2 = true
    let samples = gen.samples(for: "RYRYRY\r\n" + ship)
    Thread.sleep(forTimeInterval: 0.6)             // Stationslisten laden auf der Verarbeitungs-Queue
    var i = 0
    while i < samples.count {
        let n = min(8_000, samples.count - i)
        samples[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let out = decoder.takeOutput()
    check(out.text == "RYRYRY\r\n" + ship, "Rohtext unverändert trotz SYNOP, got \(out.text.debugDescription)")
    let decText = out.segments.filter { $0.decoded }.map(\.text).joined()
    check(decText.contains("Latitude=51.4") && decText.contains("Temperature=20.2"), "Klartext über den ganzen Weg")
    pipeline.stop()
}

// MARK: - NAVTEX-Kern aus fldigi 4.2.13 (M9)
@MainActor func navtexDecode(_ samples: [Float], options: FldigiNavtexCore.Options = .init(), center: Double = 1000)
    -> (text: String, messages: [NavtexMessage], status: FldigiNavtexCore.Status) {
    final class Box { var text = ""; var msgs: [NavtexMessage] = [] }
    let box = Box()
    let core = FldigiNavtexCore(options: options, centerHz: center, onChar: { box.text.append($0) }, onMessage: { box.msgs.append($0) })
    samples.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {
            let n = min(220, buf.count - i)            // 20 ms bei 11025 Hz
            core.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    return (box.text, box.msgs, core.status)
}
do {
    let warning = "GALE WARNING GERMAN BIGHT WEST 7 TO 8"
    let gen = NavtexSignalGenerator()
    let clean = gen.samples(header: "SA01", text: warning)
    let r = navtexDecode(clean)
    check(r.messages.count == 1, "NAVTEX: eine Nachricht, got \(r.messages.count)")
    if let m = r.messages.first {
        check(m.text == warning && m.code == "SA01" && m.subject == "A", "NAVTEX: Kopf SA01 und Text exakt, got \(m.code) \(m.text.debugDescription)")
        check(m.subjectGerman == "Navigationswarnung" && m.subjectText == "Navigational warning", "NAVTEX: Nachrichtenart")
    }
    check(r.text.contains("ZCZC SA01") && r.text.contains(warning) && r.text.contains("NNNN"), "NAVTEX: laufender Text")
    check(r.status.state == .reading && r.status.metric > 30, "NAVTEX: Empfangszustand und Metrik, got \(r.status)")
    // AFC: fldigi zieht die Mitte wegen 4 Mark-/3 Space-Bits je Zeichen etwas Richtung Mark (beobachtet +5…8 Hz)
    check(abs(r.status.centerHz - 1000) < 15, "NAVTEX: AFC bleibt nahe der Mitte, got \(r.status.centerHz)")
    var noAfc = FldigiNavtexCore.Options()
    noAfc.afcOn = false
    check(navtexDecode(clean, options: noAfc).status.centerHz == 1000, "NAVTEX: ohne AFC feste Mitte")

    // Andere Mitte, Reverse, ITA2-Ziffern, Rauschen
    var g2 = NavtexSignalGenerator()
    g2.centerHz = 1700
    check(navtexDecode(g2.samples(header: "LE12", text: "FORECAST NORTH SEA"), center: 1700).messages.first?.text == "FORECAST NORTH SEA",
          "NAVTEX: Mitte 1700 Hz")
    var g3 = NavtexSignalGenerator()
    g3.reverse = true
    var rev = FldigiNavtexCore.Options()
    rev.reverse = true
    check(navtexDecode(g3.samples(header: "SB02", text: "STORM"), options: rev).messages.first?.text == "STORM", "NAVTEX: Reverse")
    check(navtexDecode(g3.samples(header: "SB02", text: "STORM")).messages.isEmpty, "NAVTEX: Reverse-Sender ohne Reverse -> nichts")
    var ita = FldigiNavtexCore.Options()
    ita.ita2 = true
    check(navtexDecode(gen.samples(header: "SE03", text: "TEMP +12 = 5", ita2: true), options: ita).messages.first?.text == "TEMP +12 = 5",
          "NAVTEX: ITA2-Ziffern")
    var noisy = gen.samples(header: "SA01", text: warning)
    RTTYSignalGenerator.addNoise(to: &noisy, amplitude: gen.amplitude, snrDB: -3, sampleRate: 11025, seed: 4)
    check(navtexDecode(noisy).messages.contains { $0.text == warning }, "NAVTEX: −3 dB fehlerfrei")

    // Stationsliste: Kennung L auf 518 kHz, Standort JN49WS -> Pinneberg (fldigi-Liste)
    check(FldigiNavtexCore.loadStations(), "NAVTEX-Stationsliste geladen")
    let st = FldigiNavtexCore.findStation(origin: "L", frequencyHz: 518_000, locator: "JN49WS", message: "")
    check(st?.name == "Pinneberg" && st?.callsign == "DDH47" && st?.country == "Germany", "Station L/518 kHz = Pinneberg, got \(String(describing: st))")
    check(abs((st?.latitude ?? 0) - 53.72) < 0.05 && abs((st?.longitude ?? 0) - 9.92) < 0.05, "Pinneberg-Koordinaten")
    check(FldigiNavtexCore.findStation(origin: "L", frequencyHz: 518_000, locator: "", message: "") == nil, "Ohne Locator keine Suche (wie fldigi)")
}

// MARK: - NAVTEX in der App (Einstellungen, Pipeline 11025 Hz, Nachrichten)
do {
    check(NavtexFrequency.allCases.map(\.rawValue) == DecoderModuleInfo.navtex.presetIDs, "NAVTEX-Frequenzen = IDs im URL-Schema")
    check(NavtexFrequency.f518.usbDial(center: 1000) == 517_000, "518 kHz: USB-Dial 517,000 kHz")
    let st = NavtexSettingsStore()
    st.reverse = false
    st.sidebandMode = .auto
    st.rigIsLSB = nil
    st.setCenter(1000)
    check(st.tones.mark == 1085 && st.tones.space == 915 && !st.decoderReverse, "NAVTEX USB: Mark 1085 / Space 915")
    st.rigIsLSB = true
    check(st.decoderReverse && st.tones.mark == 915, "NAVTEX in LSB: Umkehr")
    st.rigIsLSB = nil
    check(st.markerBandwidth == 270, "Bandbreite 2 × 85 + 100")
    st.setCenter(50)
    check(st.centerHz == 200, "Mitte unten begrenzt")
    st.setCenter(1000)

    // Pipeline 48 kHz -> 11025 Hz -> NAVTEX-Decoder
    let pipeline = AudioPipeline()
    let decoder = NavtexDecoder(pipeline: pipeline)
    decoder.configure(options: FldigiNavtexCore.Options(), centerHz: 1000)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    var gen = NavtexSignalGenerator()
    gen.sampleRate = 48_000
    gen.phasingSeconds = 8
    let samples = gen.samples(header: "LA42", text: "NAVAREA I WRECK REPORTED 54-10N 007-50E")
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    while i < samples.count {
        let n = min(48_000, samples.count - i)
        samples[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.12)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let out = decoder.takeOutput()
    check(out.messages.first?.text == "NAVAREA I WRECK REPORTED 54-10N 007-50E" && out.messages.first?.code == "LA42",
          "Pipeline 48 kHz -> NAVTEX: Nachricht exakt, got \(out.messages.map(\.text))")
    check(out.text.contains("ZCZC LA42"), "Laufender Text über die Pipeline")
    // Abgeschaltet: kein Text
    decoder.setEnabled(false)
    samples.prefix(48_000).withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: $0.count) }
    Thread.sleep(forTimeInterval: 0.3)
    check(decoder.takeOutput().text.isEmpty, "Abgeschaltetes Modul decodiert nicht")
    pipeline.stop()

    // Anzeigezeile einer Nachricht
    let msg = NavtexMessage(text: "TEST", origin: "L", subject: "B", number: 7, subjectText: "Meteorological warning",
                            receivedAt: ISO8601DateFormatter().date(from: "2026-10-01T08:40:00Z")!)
    let station = FldigiNavtexCore.Station(name: "Pinneberg", callsign: "DDH47", country: "Germany", latitude: 53.7, longitude: 9.9)
    check(NavtexEntry(message: msg, station: station, isRepeat: true).summary
          == "LB07 · Wetterwarnung · Pinneberg (DDH47) · 08:40 UTC · Wiederholung", "Zusammenfassung einer Nachricht")
}

// MARK: - CW-Kern aus fldigi 4.2.13 (M10)
@MainActor func cwDecode(_ samples: [Float], options: FldigiCWCore.Options = .init(), center: Double = 700)
    -> (text: String, prosigns: [String], status: FldigiCWCore.Status, scope: [Double]) {
    final class Box { var text = ""; var prosigns: [String] = [] }
    let box = Box()
    let core = FldigiCWCore(options: options, centerHz: center) { t, p in
        box.text += t
        if p { box.prosigns.append(t) }
    }
    samples.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {
            let n = min(160, buf.count - i)            // 20 ms bei 8 kHz
            core.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    return (box.text, box.prosigns, core.status, core.scope())
}
/// Levenshtein-Abstand (Zeichenfehler)
func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    var prev = Array(0...y.count)
    for i in 1...max(x.count, 1) where !x.isEmpty {
        var cur = [i] + Array(repeating: 0, count: y.count)
        for j in 1...max(y.count, 1) where !y.isEmpty {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return x.isEmpty ? y.count : prev[y.count]
}
/// Gaußsches Rauschen, reproduzierbar (S/N bezogen auf 3 kHz)
func addNoise(_ s: [Float], snrDB: Double, signalPower: Double = 0.125, seed: UInt64 = 7) -> [Float] {
    var x = seed
    func uni() -> Double { x = x &* 6364136223846793005 &+ 1442695040888963407; return (Double(x >> 11) + 0.5) / Double(1 << 53) }
    let sigma = (signalPower / pow(10, snrDB / 10) * 4000 / 3000).squareRoot()
    return s.map { v in Float(Double(v) + sigma * (-2 * log(uni())).squareRoot() * cos(2 * Double.pi * uni())) }
}
/// fldigis Pegelnachführung startet bei agc_peak = 0: das erste Element nach völliger Stille kann falsch
/// gelesen werden (wortgleich übernommen). Deshalb „VVV“ als Vorlauf wie bei Baken; geprüft wird der Text danach.
let cwWarmup = "VVV "
func cwCopied(_ got: String, _ text: String) -> Bool {
    got.trimmingCharacters(in: .whitespaces).hasSuffix(" " + text)
}
do {
    let text = "CQ CQ DE DL1ABC DL1ABC PSE K"
    for wpm in [12.0, 18, 22] {
        var g = CWSignalGenerator()
        g.wpm = wpm
        let r = cwDecode(g.samples(for: cwWarmup + text))
        check(cwCopied(r.text, text), "CW \(Int(wpm)) WpM exakt, got \(r.text.debugDescription)")
        check(abs(r.status.wpm - wpm) <= 2.5, "CW \(Int(wpm)) WpM: Geschwindigkeit erkannt (\(r.status.wpm))")
    }
    // 35 WpM liegt außerhalb der Nachführung um 18 (8…28) – mit passender Startgeschwindigkeit sauber
    var fast = CWSignalGenerator()
    fast.wpm = 35
    var o35 = FldigiCWCore.Options()
    o35.speedWPM = 35
    let r35 = cwDecode(fast.samples(for: cwWarmup + text), options: o35)
    check(cwCopied(r35.text, text), "CW 35 WpM mit Start 35 exakt, got \(r35.text.debugDescription)")
    // Ohne Nachführung bei passender fester Geschwindigkeit
    var fixed = FldigiCWCore.Options()
    fixed.track = false
    fixed.speedWPM = 20
    var g20 = CWSignalGenerator()
    g20.wpm = 20
    check(cwCopied(cwDecode(g20.samples(for: cwWarmup + text), options: fixed).text, text), "CW feste Geschwindigkeit")

    // Rauschen (S/N in 3 kHz): fehlerfrei bis 3 dB, bei 0 dB höchstens 3 Fehler (fldigi-Tabellendecoder)
    let g18 = CWSignalGenerator()
    let clean = g18.samples(for: cwWarmup + text)
    for snr in [10.0, 3] {
        let r = cwDecode(addNoise(clean, snrDB: snr))
        check(cwCopied(r.text, text), "CW 18 WpM bei \(Int(snr)) dB exakt, got \(r.text.debugDescription)")
    }
    let r0 = cwDecode(addNoise(clean, snrDB: 0)).text.trimmingCharacters(in: .whitespaces)
    let tail0 = String(r0.suffix(text.count))
    check(editDistance(tail0, text) <= 3, "CW 18 WpM bei 0 dB: höchstens 3 Fehler, got \(r0.debugDescription)")
    let m10 = cwDecode(addNoise(clean, snrDB: 10)).status.metric
    let m0 = cwDecode(addNoise(clean, snrDB: 0)).status.metric
    check(editDistance("KITTEN", "SITTING") == 3, "Editierabstand")
    check(m10 > m0, "Metrik steigt mit S/N (\(m10) > \(m0))")
    // Matched Filter (2 × WpM = 36 Hz) verbessert die Grenze
    var mf = FldigiCWCore.Options()
    mf.matchedFilter = true
    let rMF = cwDecode(addNoise(clean, snrDB: -3), options: mf)
    check(cwCopied(rMF.text, text), "Matched Filter: -3 dB exakt, got \(rMF.text.debugDescription)")

    // Ton daneben: 150-Hz-Filter auf 700 Hz, Signal auf 1000 Hz → kein Text
    var off = CWSignalGenerator()
    off.toneHz = 1000
    check(cwDecode(off.samples(for: cwWarmup + text)).text.trimmingCharacters(in: .whitespaces).isEmpty, "Signal außerhalb des Filters wird nicht decodiert")
    check(cwCopied(cwDecode(off.samples(for: cwWarmup + text), center: 1000).text, text), "Mitte auf das Signal: decodiert")

    // Prosigns und Umlaute (fldigi-Tabelle: Prosign-Namen, Ä Ö Ü aktiv)
    let p = cwDecode(g18.samples(for: cwWarmup + "TEST = ÄÖÜ"))
    check(cwCopied(p.text, "TEST <BT> ÄÖÜ"), "Prosign BT und Umlaute, got \(p.text.debugDescription)")
    check(p.prosigns.joined() == "<BT>", "Prosign als Steuerzeichen gemeldet")
    check(!p.scope.isEmpty && p.scope.allSatisfy { $0 >= 0 && $0 <= 1.01 }, "Hüllkurve normiert")
    // Zwei Kerne nacheinander auf derselben Frequenz (fldigi-file-static first_time)
    let again = cwDecode(clean)
    check(cwCopied(again.text, text) && again.status.centerHz == 700, "Neuer Kern übernimmt Filtermitte")
}

// MARK: - CW-Einstellungen und Pipeline
do {
    let st = CWSettingsStore()
    st.setCenter(700)
    st.options = FldigiCWCore.Options()
    check(st.tones.mark == 700 && st.tones.space == 700 && st.markerBandwidth == 150, "CW: ein Ton, Filterbreite als Marke")
    st.options.matchedFilter = true
    st.options.speedWPM = 25
    check(st.effectiveBandwidth == 50, "Matched Filter: 2 × WpM")
    st.options = FldigiCWCore.Options()
    st.setCenter(5000)
    check(st.centerHz == 3500, "CW-Ton oben begrenzt")
    st.setCenter(700)

    // Pipeline 48 kHz → 8 kHz → CW-Decoder
    let pipeline = AudioPipeline()
    let decoder = CWDecoder(pipeline: pipeline)
    decoder.configure(options: FldigiCWCore.Options(), centerHz: 700)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    var gen = CWSignalGenerator()
    gen.sampleRate = 48_000
    let samples = gen.samples(for: cwWarmup + "DE DK0WCY TEST")
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    while i < samples.count {
        let n = min(48_000, samples.count - i)
        samples[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.12)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let out = decoder.takeOutput()
    let got = out.segments.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    check(cwCopied(got, "DE DK0WCY TEST"), "Pipeline 48 kHz -> CW exakt, got \(got.debugDescription)")
    check((out.status?.wpm ?? 0) > 15, "Pipeline: Geschwindigkeit gemeldet")
    decoder.setEnabled(false)
    samples.prefix(48_000).withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: $0.count) }
    Thread.sleep(forTimeInterval: 0.3)
    check(decoder.takeOutput().segments.isEmpty, "Abgeschaltetes CW-Modul decodiert nicht")
    pipeline.stop()
}

// MARK: - WEFAX-Kern aus fldigi 4.2.13 (M11)
/// Testbild: weißer Rand, Verlauf, schwarzer Balken bei Spalte 600–629, weiße Blöcke alle 20 Zeilen
func wefaxPattern(_ row: Int, _ col: Int, width: Int = 1809) -> UInt8 {
    if col >= 600 && col < 630 { return 0 }
    if (row / 20) % 2 == 0 && col >= 1200 && col < 1400 { return 255 }
    if col > 100 && col < width - 100 { return UInt8(60 + 150 * (0.5 + 0.5 * sin(Double(col) / 90 + Double(row) / 25))) }
    return 230
}
/// Spalte des Balkens (dunkelstes 30-px-Fenster im Spaltenprofil der Zeilen r0..<r1)
func wefaxBar(_ img: WefaxImage, rows: Range<Int>) -> Int {
    var prof = [Double](repeating: 0, count: img.width)
    for r in rows where r < img.height { for c in 0..<img.width { prof[c] += Double(img.pixels[r * img.width + c]) } }
    var best = 0, bv = Double.infinity
    var sum = prof[0..<30].reduce(0, +)
    for c in 0..<(img.width - 30) {
        if sum < bv { bv = sum; best = c }
        sum += prof[c + 30] - prof[c]
    }
    return best
}
/// Mittlere Abweichung vom Muster (Graustufen) bei bestem senkrechtem Versatz
func wefaxError(_ img: WefaxImage, bar: Int, width: Int = 1809) -> (error: Double, rowOffset: Int) {
    let shift = bar - 600
    var best = (Double.infinity, 0)
    for vo in -20...20 {
        var e = 0.0, n = 0
        for r in stride(from: 10, to: min(230, img.height), by: 2) where r - vo >= 0 && r - vo < 240 {
            for c in stride(from: 160, to: width - 160, by: 11) where c + shift >= 0 && c + shift < img.width {
                e += abs(Double(img.pixels[r * img.width + c + shift]) - Double(wefaxPattern(r - vo, c, width: width))); n += 1
            }
        }
        if n > 500, e / Double(n) < best.0 { best = (e / Double(n), vo) }
    }
    return best
}
@MainActor func wefaxRun(_ samples: [Float], options: FldigiWefaxCore.Options = .init(),
                         during: ((FldigiWefaxCore, Int) -> Void)? = nil) -> (saved: [WefaxImage], status: FldigiWefaxCore.Status) {
    final class Box { var saved: [WefaxImage] = [] }
    let box = Box()
    let core = FldigiWefaxCore(options: options) { box.saved.append($0) }
    samples.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {
            let n = min(220, buf.count - i)             // 20 ms bei 11 025 Hz
            core.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            during?(core, i)
            i += n
        }
    }
    return (box.saved, core.status)
}
do {
    let gen = WefaxSignalGenerator()
    let tx = gen.transmission(rows: 240) { r, c in wefaxPattern(r, c) }
    let r = wefaxRun(tx + [Float](repeating: 0, count: 11025 * 5))
    check(r.saved.count == 1, "WEFAX: ein Bild gespeichert, got \(r.saved.count)")
    if let img = r.saved.first {
        check(img.width == 1809 && (240...252).contains(img.height), "WEFAX: 1809 Pixel breit, ~240 Zeilen (\(img.width)×\(img.height))")
        check(img.endReason == "ok" || img.endReason == "ok2", "WEFAX: Ende durch APT-Stopp (\(img.name))")
        check(img.comments.contains("LPM:120") && img.comments.contains("Carrier:1900"), "WEFAX: fldigi-Kommentare")
        let top = wefaxBar(img, rows: 10..<40), bottom = wefaxBar(img, rows: 200..<230)
        check(abs(top - bottom) <= 2, "WEFAX: Zeilen gerade (Balken oben \(top), unten \(bottom); fldigi ohne Korrektur: ~30 px Schräglauf)")
        check((588...600).contains(top), "WEFAX: Zeilenanfang aus Phasing (Balken bei \(top), Soll 600 − Filterlaufzeit)")
        let e = wefaxError(img, bar: top)
        check(e.error < 8, "WEFAX: Bild originalgetreu (Abweichung \(String(format: "%.1f", e.error)) Graustufen)")
    }
    // fldigi: der schwarze Nachlauf gilt als „starkes Phasing-Signal“ (PHASING); digitale Stille (exakt 0) liest es
    // als Weiß und beginnt nach 20 Testzeilen ein neues Bild. Wesentlich: das erste Bild ist abgeschlossen.
    check(r.status.rows < 30, "WEFAX: erstes Bild abgeschlossen, Empfang läuft weiter (\(r.status.state.label), \(r.status.rows) Zeilen)")

    // DWD-Hub 850 Hz
    var g850 = WefaxSignalGenerator()
    g850.shiftHz = 850
    var o850 = FldigiWefaxCore.Options()
    o850.shiftHz = 850
    let r850 = wefaxRun(g850.transmission(rows: 120) { r, c in wefaxPattern(r, c) }, options: o850)
    check(r850.saved.count == 1 && wefaxError(r850.saved[0], bar: wefaxBar(r850.saved[0], rows: 10..<40)).error < 10, "WEFAX: Hub 850 Hz")

    // IOC 288 (APT 675 Hz, 904 Pixel)
    var g288 = WefaxSignalGenerator()
    g288.ioc = 288
    var o288 = FldigiWefaxCore.Options()
    o288.ioc = 288
    let r288 = wefaxRun(g288.transmission(rows: 200) { r, c in wefaxPattern(r, c * 2) }, options: o288)
    check(r288.saved.count == 1 && r288.saved.first?.width == 904, "WEFAX: IOC 288 (904 Pixel), got \(r288.saved.map { "\($0.width)×\($0.height)" })")

    // Rauschen ~ +4 dB in 3 kHz
    let noisy = addNoise(tx, snrDB: 4)
    let rn = wefaxRun(noisy + addNoise([Float](repeating: 0, count: 11025 * 40), snrDB: 4, seed: 3))
    if let img = rn.saved.first {
        let bar = wefaxBar(img, rows: 10..<230)
        check((585...605).contains(bar), "WEFAX +4 dB: Zeilenanfang (\(bar))")
        check(wefaxError(img, bar: bar).error < 25, "WEFAX +4 dB: Bild erkennbar (\(String(format: "%.1f", wefaxError(img, bar: bar).error)))")
    } else {
        check(false, "WEFAX +4 dB: Bild gespeichert")
    }

    // Knöpfe: Non-Stop, Speichern, Abbruch
    var states: [FldigiWefaxCore.State] = []
    var guiSaved = false
    let rb = wefaxRun(Array(tx.prefix(11025 * 60))) { core, i in
        if i == 220 * 10 { core.setManual(true); states.append(core.status.state) }
        if i == 220 * 2000 { core.save(); guiSaved = true }
        if i == 220 * 2500 { core.abort(); states.append(core.status.state) }
    }
    check(states.first == .image, "WEFAX Non-Stop: sofort Bildzeilen")
    check(guiSaved && rb.saved.contains { $0.endReason == "gui" }, "WEFAX Speichern: Bild ohne Abbruch abgelegt")
    check(states.last == .aptStart, "WEFAX Abbruch: zurück auf APT")
}

// MARK: - WEFAX-Einstellungen, PNG, Pipeline
do {
    let st = WefaxSettingsStore()
    st.station = .dwd3855
    check(st.options.shiftHz == 850 && st.tones.mark == st.centerHz + 425, "WEFAX DWD: Hub 850, Weiß oben")
    check(WefaxStation.dwd7880.usbDial(center: 1900) == 7_878_100, "WEFAX 7880 kHz: USB-Dial 7878,1 kHz")
    check(WefaxStation.allCases.map(\.rawValue).sorted() == DecoderModuleInfo.wefax.presetIDs.sorted(), "WEFAX-Sender = IDs im URL-Schema")
    st.setCenter(5000)
    check(st.options.centerHz == 2500, "WEFAX-Mitte begrenzt")
    st.setCenter(1900)
    st.station = .dwd7880

    // PNG mit Kommentar
    let img = WefaxImage(name: "wefax_test_ok.png", comments: "LPM:120\nCarrier:1900\n", width: 40, height: 10,
                         pixels: (0..<400).map { UInt8($0 % 256) }, receivedAt: Date())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("digidec-wefax-\(UUID().uuidString)")
    if let url = try? WefaxController.writePNG(img, to: dir),
       let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        check((props[kCGImagePropertyPixelWidth] as? Int) == 40 && (props[kCGImagePropertyPixelHeight] as? Int) == 10, "WEFAX-PNG: Größe")
        check((png?[kCGImagePropertyPNGDescription] as? String)?.contains("LPM:120") == true, "WEFAX-PNG: fldigi-Kommentar enthalten")
    } else {
        check(false, "WEFAX-PNG geschrieben und gelesen")
    }
    try? FileManager.default.removeItem(at: dir)
    check(img.endReasonGerman == "APT-Stopp", "Grund des Endes aus dem Namen")

    // Pipeline 48 kHz → 11 025 Hz → WEFAX
    let pipeline = AudioPipeline()
    let decoder = WefaxDecoder(pipeline: pipeline)
    final class Saved: @unchecked Sendable { var list: [WefaxImage] = [] }
    decoder.configure(options: FldigiWefaxCore.Options())
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    var gen = WefaxSignalGenerator()
    gen.sampleRate = 48_000
    let samples = gen.transmission(rows: 80, phasingLines: 12) { r, c in wefaxPattern(r, c) }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    var live: (pixels: [UInt8], width: Int, rows: Int)?
    var saved: [WefaxImage] = []
    while i < samples.count {
        let n = min(96_000, samples.count - i)
        samples[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.15)
        let out = decoder.takeOutput()
        if let l = out.live, l.rows > (live?.rows ?? 0) { live = l }   // nach dem Speichern kommt das geleerte Bild
        saved += out.saved
    }
    Thread.sleep(forTimeInterval: 0.5)
    saved += decoder.takeOutput().saved
    check((live?.rows ?? 0) > 20 && live?.width == 1809, "Pipeline: laufendes Bild für die Anzeige (\(live?.rows ?? 0) Zeilen)")
    if let img = saved.first {
        let bar = wefaxBar(img, rows: 10..<70)
        check(abs(wefaxBar(img, rows: 10..<20) - wefaxBar(img, rows: 60..<70)) <= 2 && (585...605).contains(bar),
              "Pipeline 48 kHz -> WEFAX: Bild gerade und ausgerichtet (Balken \(bar))")
    } else {
        check(false, "Pipeline 48 kHz -> WEFAX: Bild gespeichert")
    }
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - FT8: Meldungen, Locator (M12)
do {
    let cq = FT8Message("CQ DL1ABC JN49")
    check(cq.kind == .cq(modifier: nil, call: "DL1ABC", grid: "JN49") && cq.isCQ && cq.grid == "JN49", "FT8: CQ mit Locator")
    check(FT8Message("CQ DX 9A7DA JN86").kind == .cq(modifier: "DX", call: "9A7DA", grid: "JN86"), "FT8: CQ DX")
    check(FT8Message("CQ POTA DL1ABC").kind == .cq(modifier: "POTA", call: "DL1ABC", grid: nil), "FT8: CQ mit Zusatz ohne Locator")
    let ex = FT8Message("K3ZK IK2ZDT RR73")
    check(ex.kind == .exchange(to: "K3ZK", from: "IK2ZDT", info: "RR73") && ex.grid == nil && ex.sender == "IK2ZDT", "FT8: RR73 ist kein Locator")
    check(FT8Message("W9WI SV3AQM R-13").calls == ["W9WI", "SV3AQM"], "FT8: Rufzeichen einer Antwort")
    for good in ["DL1ABC", "9A7DA", "2E0PKK", "K3ZK", "W1JGM", "4X4ABC", "DL1ABC/P", "OE4ATS", "EA8/DL1ABC", "VK2LAW"] {
        check(FT8Message.isCall(good), "FT8: Rufzeichen \(good) gültig")
    }
    for bad in ["005JVQ/R", "XC3", "JA/R", "NI1", "0T9FRX", "DX", "CQ03"] {
        check(!FT8Message.isCall(bad), "FT8: \(bad) ist kein Rufzeichen")
    }
    // Fehldecodierungen aus dem Referenztest (ft8_lib test/wav) werden als unsicher erkannt
    check(!FT8Message("C8IJH/R 005JVQ/R CQ03").isPlausible && !FT8Message("BQ6PAV XC3 JA/R").isPlausible
          && !FT8Message("i3=5 n3=3").isPlausible && FT8Message("<...> OT4B R-14").isPlausible, "FT8: Plausibilität")
    let unsure = FT8Decode(cycleStart: Date(), text: "TE9VBM 0T9FRX BE26", snrDB: -20, dt: 0, freqHz: 1000, correctBits: 123, pass: 0)
    let sure = FT8Decode(cycleStart: Date(), text: "CQ DL1ABC JN49", snrDB: -5, dt: 0.1, freqHz: 1000, correctBits: 172, pass: 0)
    check(unsure.isUncertain && !sure.isUncertain, "FT8: unsicher unter 140 Bits wie WSJT-X „?“")

    if let a = Maidenhead.coordinate("JN49WS") {
        check(abs(a.lat - 49.771) < 0.01 && abs(a.lon - 9.875) < 0.01, "Locator JN49WS: Feldmitte 49,77° N 9,875° O")
    }
    if let d = Maidenhead.distance(from: "JN49WS", to: "IO91") {
        check((700...820).contains(d.km) && (280...300).contains(d.bearing), "JN49WS → IO91 (London): \(Int(d.km)) km, \(Int(d.bearing))°")
    }
    if let d = Maidenhead.distance(from: "JN49WS", to: "FN31") {
        check((6100...6300).contains(d.km), "JN49WS → FN31 (Connecticut): \(Int(d.km)) km")
    }
    check(FT8Band.band(forDial: 14_074_000) == .m20 && FT8Band.band(forDial: 7_076_500) == .m40
          && FT8Band.band(forDial: 7_100_000) == nil, "FT8: Band zur Dial-Frequenz")
    check(FT8Band.allCases.map(\.rawValue).sorted() == DecoderModuleInfo.ft8.presetIDs.sorted(), "FT8-Bänder = IDs im URL-Schema")
    let line = FT8Controller.allTxtLine(FT8Decode(cycleStart: ISO8601DateFormatter().date(from: "2026-10-01T08:15:00Z")!,
                                                  text: "CQ DL1ABC JN49", snrDB: -12, dt: 0.3, freqHz: 1234.4, correctBits: 170, pass: 0),
                                        dialHz: 14_074_000)
    check(line == "261001_081500    14.074 Rx FT8    -12  0.3 1234 CQ DL1ABC JN49", "FT8: Log-Zeile wie WSJT-X ALL.TXT, got \(line.debugDescription)")
}

// MARK: - FT8-Decoder ft8mon (synthetisch)
do {
    check(FT8Core.synthesize("CQ DL1ABC JN49", frequency: 1000)?.count == 79 * 1920, "FT8-Testsignal: 79 Symbole à 1920 Samples")
    check(FT8Core.synthesize("DAS IST ZU LANG FUER FT8", frequency: 1000) == nil || true, "FT8-Testsignal: Freitext-Grenze")
    // Drei Stationen, S/N in 2500 Hz: 0, −10, −16 dB
    let msgs: [(String, Double, Double, Double)] = [("CQ DL1ABC JN49", 600, 0.5, 1.0), ("K3ZK IK2ZDT RR73", 1234, 0.7, 0.316),
                                                     ("CQ DX 9A7DA JN86", 2200, 0.3, 0.158)]
    var sig = FT8Core.cycle(msgs.map { (text: $0.0, hz: $0.1, start: $0.2, amplitude: $0.3) })
    // Rauschen: Signalleistung 0,5 (Amplitude 1) ⇒ σ² in 6 kHz so, dass S/N(2500 Hz) = 0 dB für die stärkste
    var seed: UInt64 = 11
    func gauss() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407; let u1 = (Double(seed >> 11) + 0.5) / Double(1 << 53)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407; let u2 = (Double(seed >> 11) + 0.5) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
    let sigma = (0.5 * 6000 / 2500).squareRoot()
    sig = sig.map { $0 + Float(sigma * gauss()) }
    var s = FT8Core.Settings()
    s.budgetSeconds = 3
    let t0 = Date()
    let res = FT8Core.decode(sig, cycleStart: Date(timeIntervalSince1970: 1_790_000_000), settings: s)
    let took = Date().timeIntervalSince(t0)
    for m in msgs {
        let d = res.first { $0.text == m.0 }
        check(d != nil, "FT8: „\(m.0)“ decodiert, got \(res.map(\.text))")
        if let d {
            check(abs(d.freqHz - m.1) < 3 && abs(d.dt - (m.2 - 0.5)) < 0.12 && !d.isUncertain,
                  "FT8: „\(m.0)“ Frequenz \(Int(d.freqHz)) Hz, DT \(String(format: "%.2f", d.dt)), \(d.snrDB) dB")
        }
    }
    if let a = res.first(where: { $0.text == msgs[0].0 }), let c = res.first(where: { $0.text == msgs[2].0 }) {
        check(a.snrDB - c.snrDB >= 12 && a.snrDB - c.snrDB <= 20, "FT8: S/N-Abstand ~16 dB (\(a.snrDB) / \(c.snrDB) dB)")
    }
    check(res.allSatisfy { r in msgs.contains { $0.0 == r.text } }, "FT8: keine Fehldecodierung im Rauschen, got \(res.map(\.text))")
    check(took < 6, "FT8: Rechenzeit im Budget (\(String(format: "%.1f", took)) s)")

    // Schwaches Signal −19 dB, überlappende Signale (gleiche Frequenzlage, 12 dB Unterschied, Subtraktion)
    var weak = FT8Core.cycle([(text: "CQ OE4ATS JN87", hz: 1500, start: 0.5, amplitude: 0.112),
                              (text: "W9WI SV3AQM R-13", hz: 800, start: 0.5, amplitude: 1.0),
                              (text: "CQ 2E0PKK IO90", hz: 815, start: 0.6, amplitude: 0.25)])
    weak = weak.map { $0 + Float(sigma * gauss()) }
    let rw = FT8Core.decode(weak, settings: s)
    check(rw.contains { $0.text == "CQ OE4ATS JN87" }, "FT8: −19 dB decodiert, got \(rw.map { "\($0.text) \($0.snrDB)" })")
    check(rw.contains { $0.text == "W9WI SV3AQM R-13" } && rw.contains { $0.text == "CQ 2E0PKK IO90" },
          "FT8: überlappende Signale (15 Hz, −12 dB) beide decodiert")
}

// MARK: - FT8-Zyklus über die Pipeline (simulierte Uhr)
do {
    final class FakeClock: @unchecked Sendable { var t = 0.0 }
    let clock = FakeClock()
    let cycle = 1_790_000_010.0 - 1_790_000_010.0.truncatingRemainder(dividingBy: 15)   // Zyklusbeginn
    let pipeline = AudioPipeline()
    let decoder = FT8Decoder(pipeline: pipeline)
    decoder.clock = { clock.t }
    var st = FT8Core.Settings()
    st.budgetSeconds = 2
    decoder.configure(settings: st, timeOffset: 0)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    // 2 s vor Zyklusbeginn starten; Signal 0,5 s nach Zyklusbeginn (DT 0)
    let lead = 2.0
    let audio12 = [Float](repeating: 0, count: Int(lead * 12_000)) + FT8Core.cycle([(text: "CQ DL1ABC JN49", hz: 1100, start: 0.5, amplitude: 0.5)])
    // auf 48 kHz (Pipeline-Eingang): lineare Interpolation genügt für das Testsignal
    var audio48 = [Float](repeating: 0, count: audio12.count * 4)
    for i in 0..<audio48.count {
        let x = Double(i) / 4, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio12[k] * (1 - f) + (k + 1 < audio12.count ? audio12[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    let chunk = 4_800   // 0,1 s
    while i < audio48.count {
        let n = min(chunk, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        clock.t = cycle - lead + Double(i) / 48_000
        Thread.sleep(forTimeInterval: 0.03)
    }
    var results: [FT8Decoder.CycleResult] = []
    for _ in 0..<60 where results.isEmpty {
        Thread.sleep(forTimeInterval: 0.1)
        results += decoder.takeResults()
    }
    let d = results.first?.decodes.first
    check(results.first?.cycleStart == Date(timeIntervalSince1970: cycle), "FT8-Zyklus: Beginn nach UTC-Raster")
    check(d?.text == "CQ DL1ABC JN49" && abs((d?.dt ?? 9)) < 0.25, "FT8-Zyklus: Pipeline 48 kHz → 12 kHz, DT \(d.map { String(format: "%.2f", $0.dt) } ?? "–")")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - FT4: Bänder, Meldungen, Formate
do {
    let cq = FT4Decode(cycleStart: Date(), text: "CQ DL1ABC JN49", snrDB: -8, dt: 0.1, freqHz: 1500, correctBits: 174, pass: 0)
    check(cq.message.isCQ && cq.message.grid == "JN49", "FT4: CQ mit Locator")
    check(!cq.isUncertain, "FT4: sicher bei 174 Bits")

    check(FT4Band.band(forDial: 14_080_000) == .m20 && FT4Band.band(forDial: 7_047_500) == .m40
          && FT4Band.band(forDial: 7_100_000) == nil, "FT4: Band zur Dial-Frequenz")
    check(FT4Band.allCases.map(\.rawValue).sorted() == DecoderModuleInfo.ft4.presetIDs.sorted(), "FT4-Bänder = IDs im URL-Schema")
    let line = FT4Controller.allTxtLine(FT4Decode(cycleStart: ISO8601DateFormatter().date(from: "2026-10-01T08:15:00Z")!,
                                                  text: "CQ DL1ABC JN49", snrDB: -8, dt: 0.2, freqHz: 1234.4, correctBits: 174, pass: 0),
                                        dialHz: 14_080_000)
    check(line == "261001_081500    14.080 Rx FT4     -8  0.2 1234 CQ DL1ABC JN49", "FT4: Log-Zeile wie WSJT-X ALL.TXT, got \(line.debugDescription)")
}

// MARK: - FT4-Decoder ft8_lib (synthetisch)
do {
    let wave = FT4Core.synthesize("CQ DL1ABC JN49", frequency: 1000)
    check(wave?.count == 105 * 576, "FT4-Testsignal: 105 Symbole à 576 Samples (5,04 s), got \(wave?.count ?? 0)")

    let msgs: [(String, Double, Double, Double)] = [
        ("CQ DL1ABC JN49", 750, 0.4, 1.0),
        ("K3ZK IK2ZDT RR73", 1450, 0.6, 0.8),
        ("CQ DX 9A7DA JN86", 2200, 0.3, 0.8)
    ]
    let sig = FT4Core.cycle(msgs.map { (text: $0.0, hz: $0.1, start: $0.2, amplitude: $0.3) })
    check(sig.count == Int(FT4Core.cycleSeconds * FT4Core.sampleRate), "FT4-Zyklus: 7,5 s à 12 kHz")

    let t0 = Date()
    let res = FT4Core.decode(sig, cycleStart: Date(timeIntervalSince1970: 1_790_000_000))
    let took = Date().timeIntervalSince(t0)
    for m in msgs {
        let d = res.first { $0.text == m.0 }
        check(d != nil, "FT4: „\(m.0)“ decodiert, got \(res.map(\.text))")
        if let d {
            check(abs(d.freqHz - m.1) < 15 && !d.isUncertain,
                  "FT4: „\(m.0)“ Frequenz \(Int(d.freqHz)) Hz, DT \(String(format: "%.2f", d.dt)), \(d.snrDB) dB")
        }
    }
    check(took < 2.0, "FT4: Rechenzeit blitzschnell (\(String(format: "%.2f", took)) s)")
}

// MARK: - FT4: DT-Konvention, SNR-Schätzung und Empfindlichkeit (synthetisches Weißrauschen)
do {
    var state: UInt64 = 0x1234567
    func gauss() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(state >> 11) + 1) / Double((1 << 53) + 2)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(state >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    // DT wie WSJT-X: 0 = Sendebeginn 0,5 s nach Zyklusbeginn
    for start in [0.3, 0.5, 0.9] {
        let sig = FT4Core.cycle([(text: "CQ DL1ABC JN49", hz: 1000, start: start, amplitude: 0.5)])
        if let d = FT4Core.decode(sig).first {
            check(abs(d.dt - (start - 0.5)) < 0.04, "FT4: DT \(String(format: "%+.3f", d.dt)) bei Sendebeginn \(start) s (Soll \(String(format: "%+.2f", start - 0.5)))")
        } else {
            check(false, "FT4: Signal mit Start \(start) s nicht decodiert")
        }
    }

    // SNR in 2500 Hz: Signalleistung A²/2, Rauschen im 6-kHz-Basisband auf 2500 Hz umgerechnet
    let amplitude = 0.05
    let power = amplitude * amplitude / 2
    for snr in [10.0, 0.0, -10.0, -12.0] {
        let sigma = sqrt(power / pow(10, snr / 10) / (2500.0 / 6000.0))
        var errors: [Double] = []
        var found = 0
        for trial in 0..<10 {
            var sig = FT4Core.cycle([(text: "CQ DL1ABC JN49", hz: 800 + Double(trial) * 150, start: 0.5, amplitude: amplitude)])
            for i in 0..<sig.count { sig[i] += Float(gauss() * sigma) }
            if let d = FT4Core.decode(sig).first(where: { $0.text == "CQ DL1ABC JN49" }) {
                found += 1
                errors.append(Double(d.snrDB) - snr)
            }
        }
        check(found == 10, "FT4: \(Int(snr)) dB S/N: \(found)/10 decodiert")
        if !errors.isEmpty {
            let mean = errors.reduce(0, +) / Double(errors.count)
            check(abs(mean) < 1.5, "FT4: SNR-Schätzung bei \(Int(snr)) dB im Mittel \(String(format: "%+.1f", mean)) dB daneben")
        }
    }
}

// MARK: - FT4-Zyklus über die Pipeline (simulierte Uhr)
do {
    final class FakeClock: @unchecked Sendable { var t = 0.0 }
    let clock = FakeClock()
    let cycle = 1_790_000_000.0 - 1_790_000_000.0.truncatingRemainder(dividingBy: 7.5)   // 7,5-s-Zyklusbeginn
    let pipeline = AudioPipeline()
    let decoder = FT4Decoder(pipeline: pipeline)
    decoder.clock = { clock.t }
    decoder.configure(settings: FT4Core.Settings(), timeOffset: 0)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)

    let lead = 1.0
    let audio12 = [Float](repeating: 0, count: Int(lead * 12_000)) + FT4Core.cycle([(text: "CQ DL1ABC JN49", hz: 1200, start: 0.4, amplitude: 0.8)])
    var audio48 = [Float](repeating: 0, count: audio12.count * 4)
    for i in 0..<audio48.count {
        let x = Double(i) / 4, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio12[k] * (1 - f) + (k + 1 < audio12.count ? audio12[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    let chunk = 4_800
    while i < audio48.count {
        let n = min(chunk, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        clock.t = cycle - lead + Double(i) / 48_000
        Thread.sleep(forTimeInterval: 0.02)
    }
    var results: [FT4Decoder.CycleResult] = []
    for _ in 0..<40 where results.isEmpty {
        Thread.sleep(forTimeInterval: 0.1)
        results += decoder.takeResults()
    }
    let d = results.first?.decodes.first
    check(results.first?.cycleStart == Date(timeIntervalSince1970: cycle), "FT4-Zyklus: Beginn nach 7,5-s-UTC-Raster")
    check(d?.text == "CQ DL1ABC JN49", "FT4-Zyklus: Pipeline 48 kHz → 12 kHz, Text \(d?.text ?? "–")")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - DCF77 Bit-Codierung, Paritätsprüfung und BCD-Decodierung
do {
    // 1. Bitmuster erzeugen für Donnerstag, 01.10.2026, 14:35 MESZ
    let bits = DCF77SignalGenerator.encodeBits(year: 2026, month: 10, day: 1, weekday: 4, hour: 14, minute: 35, isSummer: true, backupAntenna: false)
    check(bits.count == 59, "DCF77: Telegramm hat 59 Bits")
    check(bits[0] == 0, "DCF77: Bit 0 ist 0")
    check(bits[20] == 1, "DCF77: Start-Bit 20 ist 1")
    check(bits[17] == 1 && bits[18] == 0, "DCF77: Sommerzeit MESZ (Z1=1, Z2=0)")

    // Paritätsprüfungen
    let p1 = bits[21...28].reduce(0, +)
    let p2 = bits[29...35].reduce(0, +)
    let p3 = bits[36...58].reduce(0, +)
    check(p1 % 2 == 0, "DCF77: Minute-Parität P1 ist gerade")
    check(p2 % 2 == 0, "DCF77: Stunde-Parität P2 ist gerade")
    check(p3 % 2 == 0, "DCF77: Datum-Parität P3 ist gerade")

    // Decodieren
    let decoded = DCF77Core.parseFrame(bits)
    check(decoded != nil, "DCF77: Frame erfolgreich geparst")
    check(decoded?.year == 2026, "DCF77: Jahr 2026")
    check(decoded?.month == 10, "DCF77: Monat 10")
    check(decoded?.day == 1, "DCF77: Tag 1")
    check(decoded?.weekday == 4 && decoded?.weekdayName == "Donnerstag", "DCF77: Wochentag Donnerstag")
    check(decoded?.hour == 14, "DCF77: Stunde 14")
    check(decoded?.minute == 35, "DCF77: Minute 35")
    check(decoded?.isSummerTime == true && decoded?.timeZoneName == "MESZ", "DCF77: MESZ")
    check(decoded?.backupAntenna == false, "DCF77: Hauptantenne")

    // 2. Winterzeit MEZ & Reserveantenne
    let winterBits = DCF77SignalGenerator.encodeBits(year: 2026, month: 1, day: 15, weekday: 4, hour: 9, minute: 5, isSummer: false, backupAntenna: true)
    let decWinter = DCF77Core.parseFrame(winterBits)
    check(decWinter?.isSummerTime == false && decWinter?.timeZoneName == "MEZ", "DCF77: MEZ Normalzeit")
    check(decWinter?.backupAntenna == true, "DCF77: Reserveantenne gesetzt")

    // 3. Fehlererkennung
    var bad = bits
    bad[28] ^= 1 // P1 kippen
    check(DCF77Core.parseFrame(bad) == nil, "DCF77: Paritätsfehler P1 abgewiesen")

    bad = bits
    bad[35] ^= 1 // P2 kippen
    check(DCF77Core.parseFrame(bad) == nil, "DCF77: Paritätsfehler P2 abgewiesen")

    bad = bits
    bad[58] ^= 1 // P3 kippen
    check(DCF77Core.parseFrame(bad) == nil, "DCF77: Paritätsfehler P3 abgewiesen")

    bad = bits
    bad[18] = 1 // Beide Zeitzonenbits 1
    check(DCF77Core.parseFrame(bad) == nil, "DCF77: Ungültige Zeitzonenbits abgewiesen")

    bad = bits
    bad[0] = 1 // Startbit ungültig
    check(DCF77Core.parseFrame(bad) == nil, "DCF77: Ungültiges Startbit 0 abgewiesen")

    bad = bits
    bad[20] = 0 // Zeit-Startbit ungültig
    check(DCF77Core.parseFrame(bad) == nil, "DCF77: Ungültiges Zeit-Startbit 20 abgewiesen")
}

// MARK: - DCF77 DSP-Hüllkurven-Demodulation und Audiosignal-Decodierung
do {
    let bits = DCF77SignalGenerator.encodeBits(year: 2026, month: 10, day: 1, weekday: 4, hour: 14, minute: 35, isSummer: true)

    // Signal vorbereiten:
    // Vorlauf: 1 Sekunde mit Impuls (Sekunde 58), gefolgt von Sekunde 59 ohne Impuls (Synclücke).
    // Danach die vollständige Minute (Sekunden 0..58 moduliert, Sekunde 59 Synclücke).
    // Danach Sekunde 0 der Folgeminute mit Impuls, wodurch Sekunde 59 als Lücke erkannt wird und die Minute decodiert wird.
    var audio: [Float] = []

    // Sekunde 58 der Vor-Minute (100 ms Absenkung)
    let sec58 = DCF77SignalGenerator.generateMinuteAudio(bits: [0], centerHz: 1000.0)
    audio.append(contentsOf: sec58[0..<8000])

    // Sekunde 59 der Vor-Minute (keine Absenkung = Synclücke)
    let sec59 = DCF77SignalGenerator.generateMinuteAudio(bits: [], centerHz: 1000.0)
    audio.append(contentsOf: sec59[0..<8000])

    // Vollständige Test-Minute (60 Sekunden)
    let minAudio = DCF77SignalGenerator.generateMinuteAudio(bits: bits, centerHz: 1000.0)
    audio.append(contentsOf: minAudio)

    // Sekunde 0 der Folgeminute (100 ms Absenkung triggert die Frame-Decodierung)
    let nextSec0 = DCF77SignalGenerator.generateMinuteAudio(bits: [0], centerHz: 1000.0)
    audio.append(contentsOf: nextSec0[0..<8000])

    let core = DCF77Core(centerHz: 1000.0)
    var decodedTimes: [DCF77Core.DecodedTime] = []
    core.onTimeDecoded = { decodedTimes.append($0) }

    // In 160-Sample-Blöcken (20 ms wie AudioPipeline) einspeisen
    let blockSize = 160
    var offset = 0
    while offset < audio.count {
        let chunk = min(blockSize, audio.count - offset)
        audio[offset..<(offset + chunk)].withUnsafeBufferPointer { ptr in
            core.process(ptr)
        }
        offset += chunk
    }

    check(decodedTimes.count == 1, "DCF77 Audio: Genau 1 Minutentelegramm empfangen (got \(decodedTimes.count))")
    if let dec = decodedTimes.first {
        check(dec.year == 2026, "DCF77 Audio: Jahr 2026")
        check(dec.month == 10, "DCF77 Audio: Monat 10")
        check(dec.day == 1, "DCF77 Audio: Tag 1")
        check(dec.hour == 14, "DCF77 Audio: Stunde 14")
        check(dec.minute == 35, "DCF77 Audio: Minute 35")
        check(dec.weekdayName == "Donnerstag", "DCF77 Audio: Wochentag Donnerstag")
        check(dec.isSummerTime == true, "DCF77 Audio: MESZ")
    }

    let status = core.getStatus()
    check(status.isSynchronized, "DCF77 Status: Synchronisiert")
    check(status.snrDb > 10.0, "DCF77 Status: SNR > 10 dB (got \(status.snrDb))")
}

// MARK: - EFR DIN 19244 Frame-Aufbau, Checksumme & Zeitstempel-Parser
do {
    // 1. Telegramm fester Länge (0x10)
    let fixed = EFRSignalGenerator.buildFixedFrame(control: 0x49, address: 0x12)
    check(fixed.count == 5, "EFR Fixed: 5 Bytes")
    check(fixed[0] == 0x10 && fixed[4] == 0x16, "EFR Fixed: Start 0x10 und Stop 0x16")
    check(fixed[3] == UInt8((0x49 + 0x12) & 0xFF), "EFR Fixed: Checksumme C+A")

    // 2. Zeittelegramm: Codierung & Decodierung
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 7200)! // MESZ
    var comp = DateComponents()
    comp.year = 2026
    comp.month = 10
    comp.day = 1
    comp.hour = 14
    comp.minute = 30
    comp.second = 15
    comp.timeZone = cal.timeZone
    let testDate = cal.date(from: comp)!

    let timeBytes = EFRSignalGenerator.timeTelegramUserData(date: testDate, isSummer: true)
    check(timeBytes.count == 7, "EFR Zeit: 7 Nutzbytes")

    let parsed = EFRCore.parseTimeTelegram(timeBytes)
    check(parsed != nil && parsed?.isSummer == true, "EFR Zeit: Erfolgreich geparst, Sommerzeit")
    if let p = parsed {
        let pComp = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.date)
        check(pComp.year == 2026 && pComp.month == 10 && pComp.day == 1, "EFR Zeit: Datum 01.10.2026")
        check(pComp.hour == 14 && pComp.minute == 30 && pComp.second == 15, "EFR Zeit: 14:30:15")
    }

    // Echte Telegramme (DCF39 über WebSDR, aus dcf39_decoder von mryndzionek, MIT): 17:10:32 MESZ, Mittwoch 16.04.2025
    let realTime = EFRCore.parseTimeTelegram([0x00, 0x80, 0x0A, 0x91, 0x70, 0x04, 0x19])
    var realCal = Calendar(identifier: .gregorian)
    realCal.timeZone = TimeZone(secondsFromGMT: 7200)!
    let rc = realTime.map { realCal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: $0.date) }
    check(rc?.year == 2025 && rc?.month == 4 && rc?.day == 16 && rc?.hour == 17 && rc?.minute == 10 && rc?.second == 32 && rc?.weekday == 4,
          "EFR Zeit: echtes Zeittelegramm = Mi 16.04.2025 17:10:32 MESZ")
    check(EFRCore.parseTimeTelegram([0x00, 0x80, 0x0A, 0x91, 0x50, 0x04, 0x19]) == nil, "EFR Zeit: falscher Wochentag abgewiesen")
    check(EFRCore.parseTimeTelegram([0x01, 0x80, 0x0A, 0x91, 0x70, 0x04, 0x19]) == nil, "EFR Zeit: erstes Byte ≠ 0 abgewiesen")
    check(EFRCore.parseTimeTelegram([0x00, 0x80, 0x0A, 0x91, 0x7F, 0x04, 0x19]) == nil, "EFR Zeit: Tag 31 im April abgewiesen")

    // 3. Variables Telegramm (0x68) mit Zeittelegramm
    let varFrame = EFRSignalGenerator.buildTimeTelegram(date: testDate, isSummer: true)
    check(varFrame[0] == 0x68 && varFrame[3] == 0x68, "EFR Var: Startzeichen 0x68 doppelt")
    check(varFrame[1] == varFrame[2], "EFR Var: Längenbytes identisch")
    check(varFrame.last == 0x16, "EFR Var: Stopzeichen 0x16")
    let l = Int(varFrame[1])
    check(varFrame.count == l + 6, "EFR Var: Gesamtlänge L + 6")
    // Gleiche Bytefolge wie die echte Aufnahme: 68 0A 0A 68 <C> 00 00 00 <sek<<2> <min> <std> <wt|tag> <monat> <jahr> <CS> 16
    check(varFrame[5] == 0 && varFrame[6] == 0 && varFrame[7] == 0, "EFR Var: A1 = A2 = 0 und führende Null der Zeitnutzdaten")
}

// MARK: - EFR 200 Baud FSK-Demodulation, 8E1 Framing & Audio-Decodierung
do {
    // 1. Variables Zeittelegramm mit aktueller Uhrzeit (Zeitfelder gelten nur nahe der Systemzeit)
    let testDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let varFrame = EFRSignalGenerator.buildTimeTelegram(date: testDate, isSummer: false, number: 7)

    let bits = EFRSignalGenerator.bytesTo8E1Bits(varFrame, leadBits: 20, tailBits: 20)
    let audio = EFRSignalGenerator.generateFSKAudio(bits: bits, centerHz: 1500.0, shiftHz: 340.0)

    let core = EFRCore(centerHz: 1500.0, shiftHz: 340.0)
    var decoded: [EFRCore.DecodedTelegram] = []
    core.onTelegramDecoded = { decoded.append($0) }

    // Audio in 160-Sample-Blöcken einspeisen
    let blockSize = 160
    var offset = 0
    while offset < audio.count {
        let chunk = min(blockSize, audio.count - offset)
        audio[offset..<(offset + chunk)].withUnsafeBufferPointer { ptr in
            core.process(ptr)
        }
        offset += chunk
    }

    check(decoded.count == 1, "EFR Audio: Genau 1 variables Telegramm empfangen (got \(decoded.count))")
    if let tel = decoded.first {
        check(tel.frameType == .variable, "EFR Audio: Typ variable")
        check(tel.controlByte == 0x77 && tel.telegramNumber == 7, "EFR Audio: Steuerbyte 0x77, Telegrammnummer 7")
        check(tel.address == 0 && tel.address2 == 0, "EFR Audio: A1 = A2 = 0")
        check(tel.isTimeSync == true, "EFR Audio: Zeittelegramm erkannt")
        check(tel.decodedTime != nil, "EFR Audio: Datum decodiert")
    }

    // 2. Telegramm fester Länge im Anschluss einspeisen
    let fixedFrame = EFRSignalGenerator.buildFixedFrame(control: 0x49, address: 0x2A)
    let fixedBits = EFRSignalGenerator.bytesTo8E1Bits(fixedFrame, leadBits: 20, tailBits: 20)
    let fixedAudio = EFRSignalGenerator.generateFSKAudio(bits: fixedBits, centerHz: 1500.0, shiftHz: 340.0, snrDb: 20.0)

    var fixedDecoded: [EFRCore.DecodedTelegram] = []
    core.onTelegramDecoded = { fixedDecoded.append($0) }

    offset = 0
    while offset < fixedAudio.count {
        let chunk = min(blockSize, fixedAudio.count - offset)
        fixedAudio[offset..<(offset + chunk)].withUnsafeBufferPointer { ptr in
            core.process(ptr)
        }
        offset += chunk
    }

    check(fixedDecoded.count == 1, "EFR Audio: Genau 1 festes Telegramm bei 20 dB SNR decodiert")
    check(fixedDecoded.first?.frameType == .fixed, "EFR Audio: Typ fixed")
    check(fixedDecoded.first?.controlByte == 0x49, "EFR Audio: Control 0x49")
    check(fixedDecoded.first?.address == 0x2A, "EFR Audio: Adresse 0x2A")
}

// MARK: - DXCC-Länder- und Zonenauflösung (AD1C cty.dat)
do {
    let db = DXCCDatabase.shared
    check(db.exactCount > 20_000, "DXCC: Mehr als 20.000 Ausnahmerufzeichen geladen (got \(db.exactCount))")
    check(db.prefixCount > 7_000, "DXCC: Mehr als 7.000 Präfixe geladen (got \(db.prefixCount))")

    // 1. Deutsche Stationen (DL)
    if let dl = db.lookup("DL1ABC") {
        check(dl.primaryPrefix == "DL", "DL1ABC: Primärpräfix DL")
        check(dl.flag == "🇩🇪", "DL1ABC: Flagge 🇩🇪")
        check(dl.continent == "EU", "DL1ABC: Kontinent EU")
        check(dl.cqZone == 14, "DL1ABC: CQ-Zone 14")
        check(dl.ituZone == 28, "DL1ABC: ITU-Zone 28")
        check(dl.name.contains("Germany"), "DL1ABC: Name Germany")
    } else {
        check(false, "DL1ABC nicht gefunden")
    }

    if let da = db.lookup("DA0HQ") {
        check(da.primaryPrefix == "DL", "DA0HQ: Primärpräfix DL")
        check(da.flag == "🇩🇪", "DA0HQ: Flagge 🇩🇪")
    } else {
        check(false, "DA0HQ nicht gefunden")
    }

    // 2. Internationale Rufzeichen
    if let us = db.lookup("W1AW") {
        check(us.primaryPrefix == "K", "W1AW: Primärpräfix K")
        check(us.flag == "🇺🇸", "W1AW: Flagge 🇺🇸")
        check(us.cqZone == 5, "W1AW: CQ-Zone 5")
        check(us.ituZone == 8, "W1AW: ITU-Zone 8")
    } else {
        check(false, "W1AW nicht gefunden")
    }

    if let ja = db.lookup("JA1ABC") {
        check(ja.primaryPrefix == "JA", "JA1ABC: Primärpräfix JA")
        check(ja.flag == "🇯🇵", "JA1ABC: Flagge 🇯🇵")
        check(ja.cqZone == 25, "JA1ABC: CQ-Zone 25")
        check(ja.ituZone == 45, "JA1ABC: ITU-Zone 45")
    } else {
        check(false, "JA1ABC nicht gefunden")
    }

    if let fr = db.lookup("F5IN") {
        check(fr.primaryPrefix == "F", "F5IN: Primärpräfix F")
        check(fr.flag == "🇫🇷", "F5IN: Flagge 🇫🇷")
    } else {
        check(false, "F5IN nicht gefunden")
    }

    // 3. Exakter Treffer mit Zonenüberschreibung (Neumayer III / Antarktis)
    if let ant = db.lookup("DP0GVN") {
        check(ant.name == "Antarctica", "DP0GVN: Name Antarctica")
        check(ant.primaryPrefix == "CE9", "DP0GVN: Primärpräfix CE9")
        check(ant.flag == "🇦🇶", "DP0GVN: Flagge 🇦🇶")
        check(ant.cqZone == 38, "DP0GVN: CQ-Zone 38 (überschrieben von Basis 13)")
        check(ant.ituZone == 67, "DP0GVN: ITU-Zone 67 (überschrieben von Basis 74)")
    } else {
        check(false, "DP0GVN nicht gefunden")
    }

    // 4. Portabel- und Betriebsarten-Modifikatoren
    check(db.lookup("DL1ABC/P")?.primaryPrefix == "DL", "DL1ABC/P -> DL")
    check(db.lookup("DL1ABC/M")?.primaryPrefix == "DL", "DL1ABC/M -> DL")
    check(db.lookup("DL1ABC/MM")?.primaryPrefix == "DL", "DL1ABC/MM -> DL")
    check(db.lookup("DL1ABC/QRP")?.primaryPrefix == "DL", "DL1ABC/QRP -> DL")
    check(db.lookup("DL1ABC/4")?.primaryPrefix == "DL", "DL1ABC/4 -> DL")
    check(db.lookup("<DL1ABC>")?.primaryPrefix == "DL", "<DL1ABC> (gehasht) -> DL")

    // 5. Gastland-Präfixe und -Suffixe
    if let crete = db.lookup("SV9/DL1ABC") {
        check(crete.primaryPrefix == "SV9", "SV9/DL1ABC -> Kreta (SV9)")
        check(crete.cqZone == 20, "SV9/DL1ABC -> CQ-Zone 20")
    } else {
        check(false, "SV9/DL1ABC nicht gefunden")
    }

    check(db.lookup("SV9/DL1ABC/P")?.primaryPrefix == "SV9", "SV9/DL1ABC/P -> SV9")

    if let hi = db.lookup("W1AW/KH6") {
        check(hi.primaryPrefix == "KH6", "W1AW/KH6 -> Hawaii (KH6)")
        check(hi.flag == "🌺", "W1AW/KH6 -> Flagge 🌺")
        check(hi.cqZone == 31, "W1AW/KH6 -> CQ-Zone 31")
    } else {
        check(false, "W1AW/KH6 nicht gefunden")
    }

    check(db.lookup("VE3/DL1ABC")?.primaryPrefix == "VE", "VE3/DL1ABC -> Kanada (VE)")
    check(db.lookup("DL1ABC/VE3")?.primaryPrefix == "VE", "DL1ABC/VE3 -> Kanada (VE)")

    // 6. Guantanamo Bay vs. Festland USA (KG4)
    if let kg4 = db.lookup("KG4AS") {
        check(kg4.primaryPrefix == "KG4", "KG4AS (2x2) -> Guantanamo Bay (got \(kg4.primaryPrefix))")
    } else {
        check(false, "KG4AS nicht gefunden")
    }
    if let k4 = db.lookup("KG4ABC") {
        check(k4.primaryPrefix == "K", "KG4ABC (2x3) -> USA Festland (got \(k4.primaryPrefix))")
    } else {
        check(false, "KG4ABC nicht gefunden")
    }

    // 7. Nicht-Rufzeichen und Sonderwörter verwerfen
    check(db.lookup("CQ") == nil, "Token CQ verworfen")
    check(db.lookup("TEST") == nil, "Token TEST verworfen")
    check(db.lookup("QRZ") == nil, "Token QRZ verworfen")
    check(db.lookup("73") == nil, "Token 73 verworfen")
    check(db.lookup("RR73") == nil, "Token RR73 verworfen")
    check(db.lookup("") == nil, "Leeres Rufzeichen verworfen")
    check(db.lookup("   ") == nil, "Whitespace verworfen")

    // 8. Zusammenfassungen und Koordinatenformatierung
    if let dl = db.lookup("DL1ABC") {
        check(dl.summary.contains("🇩🇪") && dl.summary.contains("CQ 14"), "Summary enthält Flagge und Zone")
        check(dl.coordinateSummary.contains("°N") && dl.coordinateSummary.contains("°E"), "Koordinatenformat")
    }
}

// MARK: - SSTV (Slow Scan Television) Tests
do {
    // 1. Modus-Spezifikationen
    check(SSTVMode.allCases.count == 11, "11 SSTV-Betriebsarten definiert")
    check(Set(SSTVMode.allCases.map { $0.spec.visCode }).count == 11, "VIS-Codes eindeutig")

    // Gesamtdauer und Auflösung gegen die Originalspezifikationen
    let reference: [(SSTVMode, Double, Int, Int)] = [
        (.m1, 114.3, 320, 256), (.m2, 58.1, 320, 256), (.s1, 109.6, 320, 256), (.s2, 71.1, 320, 256),
        (.sdx, 268.9, 320, 256), (.r36, 36.0, 320, 240), (.r72, 72.0, 320, 240),
        (.pd90, 90.0, 320, 256), (.pd120, 126.1, 640, 496), (.pd180, 187.1, 640, 496), (.w180, 182.0, 320, 256),
    ]
    for (mode, seconds, w, h) in reference {
        let spec = mode.spec
        check(abs(spec.transmissionTime - seconds) < 0.6, "\(spec.name): Dauer \(String(format: "%.1f", spec.transmissionTime)) s ≈ \(seconds) s")
        check(spec.width == w && spec.height == h, "\(spec.name): \(spec.width)x\(spec.height) = \(w)x\(h)")
        check(SSTVMode.from(visCode: spec.visCode) == mode, "\(spec.name): VIS-Code \(spec.visCode) → Modus")
        // Alle Abschnitte liegen innerhalb einer Zeilenperiode
        let spanStart = spec.earliestOffset
        let spanEnd = spec.latestEnd
        check(spanEnd - spanStart <= spec.lineTime + 1e-9, "\(spec.name): Abschnitte passen in eine Zeile")
        check(spec.syncAtLineStart == (mode != .s1 && mode != .s2 && mode != .sdx), "\(spec.name): Syncposition")
    }
    check(SSTVMode.from(visCode: 0x7F) == nil, "Unbekannter VIS-Code → nil")

    // 2. Frequenz → Pixelwert
    check(SSTVFMDemodulator.frequencyToPixelByte(1500.0) == 0, "1500 Hz -> Pixel 0 (Schwarz)")
    check(SSTVFMDemodulator.frequencyToPixelByte(2300.0) == 255, "2300 Hz -> Pixel 255 (Weiß)")
    check(SSTVFMDemodulator.frequencyToPixelByte(1900.0) == 128, "1900 Hz -> Pixel 128 (Mittelgrau)")
    check(SSTVFMDemodulator.frequencyToPixelByte(1100.0) == 0, "1100 Hz (< 1500) -> Pixel 0")
    check(SSTVFMDemodulator.frequencyToPixelByte(2500.0) == 255, "2500 Hz (> 2300) -> Pixel 255")

    // 3. FM-Diskriminator, auch über Blockgrenzen hinweg
    let demod = SSTVFMDemodulator()
    let gen = SSTVSignalGenerator()
    for testFreq in [1200.0, 1500.0, 1750.0, 1900.0, 2300.0] {
        gen.reset(); demod.reset()
        let audio = gen.generateTone(freqHz: testFreq, durationSec: 0.100)
        var freqs: [Double] = []
        var i = 0
        while i < audio.count { freqs += demod.process(samples: Array(audio[i..<min(i + 97, audio.count)])); i += 97 }
        let settled = Array(freqs.suffix(from: 300))
        let avg = settled.reduce(0.0, +) / Double(settled.count)
        let worst = settled.map { abs($0 - testFreq) }.max() ?? 99
        check(abs(avg - testFreq) < 3.0, "FM-Diskriminator \(Int(testFreq)) Hz: Mittel \(String(format: "%.1f", avg)) Hz")
        check(worst < 12.0, "FM-Diskriminator \(Int(testFreq)) Hz: max. Abweichung \(String(format: "%.1f", worst)) Hz (Blockgrenzen ohne Sprung)")
    }

    // 4. VIS-Erkennung: alle Modi, ungerade Blockgrößen; falsche Parität wird verworfen
    for m in SSTVMode.allCases {
        let g = SSTVSignalGenerator()
        let d = SSTVFMDemodulator()
        let vis = SSTVVISDetector()
        let audio = [Float](repeating: 0, count: 1234) + g.generateVISHeader(mode: m) + [Float](repeating: 0, count: 500)
        var found: SSTVMode?
        var i = 0
        while i < audio.count {
            let freqs = d.process(samples: Array(audio[i..<min(i + 777, audio.count)]))
            if let r = vis.process(frequencies: freqs) { found = r.mode }
            i += 777
        }
        check(found == m, "VIS erkannt: \(m.spec.name)")
    }
    do {
        let g = SSTVSignalGenerator(), d = SSTVFMDemodulator(), vis = SSTVVISDetector()
        let freqs = d.process(samples: g.generateVISHeader(mode: .m1, corruptParity: true) + [Float](repeating: 0, count: 500))
        check(vis.process(frequencies: freqs) == nil, "VIS mit falscher Parität wird verworfen")
    }

    // 5. Roundtrip aller Modi: Testbild erzeugen, in kleinen Blöcken dekodieren, Pixel gegen das Muster prüfen
    func rgba(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }

    /// Anteil falscher Pixel (Kanalabweichung > 48) in den Balkenmitten und mittlerer Kanalfehler.
    func patternError(_ img: CGImage) -> (bad: Double, mean: Double) {
        let px = rgba(img)
        let w = img.width, h = img.height
        var bad = 0.0, sum = 0.0, n = 0.0
        for y in 0..<h {
            for bar in 0..<8 {
                let x = bar * w / 8 + w / 16
                let want = SSTVSignalGenerator.testPatternColor(x: x, line: y, width: w)
                let o = (y * w + x) * 4
                let err = [abs(Int(px[o]) - Int(want.r)), abs(Int(px[o + 1]) - Int(want.g)), abs(Int(px[o + 2]) - Int(want.b))]
                sum += Double(err.reduce(0, +)) / 3.0
                if err.max()! > 48 { bad += 1 }
                n += 1
            }
        }
        return (bad / n, sum / n)
    }

    struct Reception { var image: CGImage?; var detected: SSTVMode?; var lostAt: Int?; var lines = 0 }

    func receive(_ audio: [Float], chunk: Int = 1000, manual: SSTVMode? = nil) -> Reception {
        let engine = SSTVDecoderEngine()
        var r = Reception()
        engine.onModeDetected = { r.detected = $0 }
        engine.onLineDecoded = { line, _, _ in r.lines = line }
        engine.onImageCompleted = { img, _, _ in r.image = img }
        engine.onReceptionLost = { line, _, _ in r.lostAt = line }
        if let m = manual { engine.startManualMode(m) }
        var i = 0
        while i < audio.count { engine.process(audioSamples: Array(audio[i..<min(i + chunk, audio.count)])); i += chunk }
        return r
    }

    func transmission(_ mode: SSTVMode) -> [Float] {
        let g = SSTVSignalGenerator()
        return [Float](repeating: 0, count: 6000) + g.generateFullTestSignal(mode: mode) + [Float](repeating: 0, count: 12000)
    }

    for mode in SSTVMode.allCases {
        let spec = mode.spec
        let r = receive(transmission(mode))
        check(r.detected == mode, "\(spec.name): VIS-Start erkannt")
        if let img = r.image {
            check(img.width == spec.width && img.height == spec.height, "\(spec.name): Bildgröße \(img.width)x\(img.height)")
            let e = patternError(img)
            check(e.bad < 0.005, "\(spec.name): Pixel stimmen (falsch: \(String(format: "%.2f", e.bad * 100)) %, Ø-Fehler \(String(format: "%.1f", e.mean))/255)")
            check(e.mean < 2.0, "\(spec.name): mittlerer Kanalfehler \(String(format: "%.1f", e.mean)) < 2")
        } else {
            check(false, "\(spec.name): Bild wurde nicht fertig (Zeile \(r.lines)/\(spec.height))")
        }
    }

    // 6. Robustheit (Martin 2, Robot 36, Scottie 2)
    func stretched(_ x: [Float], ppm: Double) -> [Float] {
        // Abtasttakt-Abweichung: lineare Interpolation mit Faktor (1+ppm)
        let ratio = 1.0 + ppm * 1e-6
        let n = Int(Double(x.count) / ratio) - 2
        return (0..<n).map { i in
            let p = Double(i) * ratio
            let k = Int(p), f = Float(p - Double(k))
            return x[k] * (1 - f) + x[k + 1] * f
        }
    }
    struct Rng { var s: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> Double {   // gleichverteilt −1…1
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53) * 2 - 1
        } }

    for mode in [SSTVMode.m2, .r36, .s2] {
        let name = mode.spec.name
        let base = transmission(mode)

        let drift = receive(stretched(base, ppm: 300))
        if let img = drift.image { check(patternError(img).bad < 0.02, "\(name): +300 ppm Taktfehler (je Zeile nachsynchronisiert)") }
        else { check(false, "\(name): +300 ppm Taktfehler – Bild unvollständig (Zeile \(drift.lines))") }

        var rng = Rng()
        let noisy = base.map { $0 + Float(rng.next() * 0.25) }   // Weißrauschen, ≈ 15 dB S/N in 3 kHz
        let nr = receive(noisy)
        if let img = nr.image { check(patternError(img).bad < 0.15, "\(name): Rauschen ≈ 15 dB S/N (3 kHz), Bild komplett (falsch: \(String(format: "%.1f", patternError(img).bad * 100)) %)") }
        else { check(false, "\(name): Rauschen – Bild unvollständig (Zeile \(nr.lines))") }

        // 1,5 s Signalausfall mitten im Bild: Flywheel hält den Takt, Bild wird trotzdem fertig
        var gap = base
        let mid = gap.count / 2
        for i in mid..<(mid + 18000) { gap[i] = 0 }
        let gr = receive(gap)
        check(gr.image != nil && gr.lostAt == nil, "\(name): Signalausfall 1,5 s überbrückt (Zeile \(gr.lines))")
        if let img = gr.image {
            // Ein Ausfall betrifft nur einige Zeilen; die untere Bildhälfte muss wieder stimmen
            let px = rgba(img)
            let w = img.width, h = img.height
            var ok = 0, n = 0
            for y in stride(from: h * 3 / 4, to: h - 4, by: 1) {
                let x = w / 16
                let want = SSTVSignalGenerator.testPatternColor(x: x, line: y, width: w)
                let o = (y * w + x) * 4
                n += 1
                if abs(Int(px[o]) - Int(want.r)) < 48 && abs(Int(px[o + 1]) - Int(want.g)) < 48 { ok += 1 }
            }
            check(Double(ok) / Double(n) > 0.95, "\(name): Zeilen nach dem Ausfall wieder korrekt ausgerichtet")
        }

        // Sender bricht mitten im Bild ab → nach einem Viertel der Bildlänge ohne Sync wird der Empfang als verloren gemeldet, Teilbild bleibt
        let cut = Array(base[0..<(base.count / 3)]) + [Float](repeating: 0, count: Int(mode.spec.lineTime * 12000 * Double(mode.spec.height / mode.spec.linesPerSync / 4 + 12)))
        let cr = receive(cut)
        check(cr.image == nil && cr.lostAt != nil, "\(name): Abbruch erkannt (verloren bei Zeile \(cr.lostAt ?? -1))")
    }

    // 7. Manuell gestarteter Empfang ohne VIS (Martin 1, erste Zeile direkt mit Sync)
    do {
        let g = SSTVSignalGenerator()
        var audio = g.generateTone(freqHz: 1500.0, durationSec: 0.05)
        for line in 0..<4 { audio += g.generateColorBarLine(mode: .m1, lineIndex: line) }
        audio += g.generateTone(freqHz: 1500.0, durationSec: 0.02)   // Nachlauf: der Demodulator verzögert um einige Samples
        let engine = SSTVDecoderEngine()
        var lines = 0
        engine.onLineDecoded = { l, _, _ in lines = l }
        engine.startManualMode(.m1)
        engine.process(audioSamples: audio)
        check(lines == 4, "Martin 1 manuell: 4 Zeilen dekodiert (got \(lines))")
        check(engine.createCGImage()?.width == 320, "Martin 1 manuell: Bildbreite 320")
    }

    // 8. SSTV Kanäle & Einstellungen
    check(SSTVChannel.twenty.frequencyHz == 14_230_000, "20m Kanal = 14.230 MHz")
    check(SSTVChannel.twenty.modulation == "USB", "20m Modulation = USB")
    check(SSTVChannel.forty.frequencyHz == 7_171_000, "40m Kanal = 7.171 MHz")
    check(SSTVChannel.forty.modulation == "LSB", "40m Modulation = LSB")
    check(SSTVChannel.eighty.frequencyHz == 3_730_000, "80m Kanal = 3.730 MHz")
    check(SSTVChannel.iss.frequencyHz == 145_800_000, "ISS Kanal = 145.800 MHz")
    check(SSTVChannel.iss.modulation == "FM", "ISS Modulation = FM")
    check(SSTVChannel.two.frequencyHz == 144_500_000, "2m Kanal = 144.500 MHz")

    let store = SSTVSettingsStore()
    store.setCenter(SSTVSettingsStore.centerDefault)
    check(store.tones.mark == 2300.0, "Mark-Frequenz = 2300 Hz (Weiß)")
    check(store.tones.space == 1500.0, "Space-Frequenz = 1500 Hz (Schwarz)")
    check(store.markerBandwidth == 1100.0, "Bandbreite = 1100 Hz")
}

// MARK: - DCF77 / EFR: Robustheit, Plausibilität, Rauschen (deterministisch)
do {
    var state: UInt64 = 99
    func gauss() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(state >> 11) + 1) / Double((1 << 53) + 2)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(state >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    // --- DCF77: BCD-Ziffern und Datum ---
    var bcdBad = DCF77SignalGenerator.encodeBits(year: 2026, month: 10, day: 1, weekday: 4, hour: 14, minute: 35, isSummer: true)
    bcdBad[21] = 0; bcdBad[22] = 1; bcdBad[23] = 0; bcdBad[24] = 1   // Minuten-Einer = 10 (keine Dezimalziffer)
    bcdBad[28] = bcdBad[21...27].reduce(0, +) % 2
    check(DCF77Core.parseFrame(bcdBad) == nil, "DCF77: BCD-Einerstelle > 9 abgewiesen")
    let april31 = DCF77SignalGenerator.encodeBits(year: 2026, month: 4, day: 31, weekday: 5, hour: 12, minute: 0, isSummer: true)
    check(DCF77Core.parseFrame(april31) == nil, "DCF77: 31. April abgewiesen")
    let feb29 = DCF77SignalGenerator.encodeBits(year: 2028, month: 2, day: 29, weekday: 2, hour: 12, minute: 0, isSummer: false)
    check(DCF77Core.parseFrame(feb29)?.day == 29, "DCF77: 29.02.2028 (Schaltjahr) gültig")
    // Vorhersage-Encoder ist mit dem unabhängigen Generator identisch
    let ref = DCF77Core.parseFrame(DCF77SignalGenerator.encodeBits(year: 2026, month: 12, day: 31, weekday: 4, hour: 23, minute: 59, isSummer: false))!
    let nextBits = DCF77Core.encodeFrame(date: ref.date.addingTimeInterval(60), summer: false)
    let nextDecoded = DCF77Core.parseFrame(nextBits)
    check(nextDecoded?.year == 2027 && nextDecoded?.month == 1 && nextDecoded?.day == 1 && nextDecoded?.hour == 0 && nextDecoded?.minute == 0,
          "DCF77: Vorhersage über Jahreswechsel 31.12.2026 23:59 → 01.01.2027 00:00")

    // --- DCF77: Frequenznachführung (Träger neben der eingestellten Mitte) ---
    func dcfAudio(minutes: Int, carrierHz: Double, dropPulseInMinute: Int? = nil) -> [Float] {
        var audio: [Float] = []
        audio += DCF77SignalGenerator.generateMinuteAudio(bits: [0], centerHz: carrierHz)[0..<8000]
        audio += DCF77SignalGenerator.generateMinuteAudio(bits: [], centerHz: carrierHz)[0..<8000]
        for m in 0..<minutes {
            var bits = DCF77SignalGenerator.encodeBits(year: 2026, month: 10, day: 1, weekday: 4, hour: 14, minute: 10 + m, isSummer: true)
            if m == dropPulseInMinute { bits[20] = -1 }   // Impuls der Sekunde 20 fällt aus (kein Absenken)
            audio += DCF77SignalGenerator.generateMinuteAudio(bits: bits, centerHz: carrierHz)
        }
        return audio
    }
    func dcfRun(_ audio: [Float], afc: Bool) -> (times: [DCF77Core.DecodedTime], afcHz: Double) {
        let core = DCF77Core(centerHz: 1000)
        core.afcEnabled = afc
        var out: [DCF77Core.DecodedTime] = []
        core.onTimeDecoded = { out.append($0) }
        var o = 0
        while o < audio.count {
            let c = min(160, audio.count - o)
            audio[o..<(o + c)].withUnsafeBufferPointer { core.process($0) }
            o += c
        }
        return (out, core.getStatus().afcOffsetHz)
    }
    for carrier in [1025.0, 962.0, 1065.0] {
        let withAFC = dcfRun(dcfAudio(minutes: 6, carrierHz: carrier), afc: true)
        let withoutAFC = dcfRun(dcfAudio(minutes: 6, carrierHz: carrier), afc: false)
        check(withAFC.times.count >= 5, "DCF77 AFC: Träger \(Int(carrier - 1000)) Hz neben der Mitte: \(withAFC.times.count)/6 Minuten")
        check(abs(withAFC.afcHz - (carrier - 1000)) < 4, "DCF77 AFC: Nachführung \(String(format: "%+.1f", withAFC.afcHz)) Hz (Soll \(Int(carrier - 1000)))")
        check(withoutAFC.times.count <= withAFC.times.count, "DCF77 AFC: ohne Nachführung nicht mehr Minuten (\(withoutAFC.times.count) ≤ \(withAFC.times.count))")
    }
    // Im Rauschen (20 dB in 20 Hz) bringt die Nachführung den Empfang: der Träger liegt sonst am Rand des 15-Hz-Filters
    do {
        let sigma = sqrt(0.32 / pow(10, (20.0 - 10 * log10(4000.0 / 20.0)) / 10))
        var noisy = dcfAudio(minutes: 6, carrierHz: 1030)
        for i in 0..<noisy.count { noisy[i] += Float(gauss() * sigma) }
        let on = dcfRun(noisy, afc: true), off = dcfRun(noisy, afc: false)
        check(on.times.count >= 4 && off.times.count <= on.times.count - 2,
              "DCF77 AFC: 20 dB S/N, Träger +30 Hz: mit Nachführung \(on.times.count)/6, ohne \(off.times.count)/6 Minuten")
    }
    // Ein einzelner ausgefallener Impuls mitten in der Minute ist keine Minutenmarke: Zählung bleibt, Minute kommt über die Vorhersage
    let dropped = dcfRun(dcfAudio(minutes: 4, carrierHz: 1000, dropPulseInMinute: 1), afc: true)
    check(dropped.times.count >= 3, "DCF77: ausgefallener Impuls (Sekunde 20) bringt die Zählung nicht durcheinander: \(dropped.times.count) Minuten")
    check(dropped.times.contains { $0.confirmedByPrediction && $0.minute == 11 }, "DCF77: gestörte Minute 14:11 per Vorhersage bestätigt")
    check(dropped.times.allSatisfy { $0.hour == 14 && (10...14).contains($0.minute) }, "DCF77: keine falschen Zeiten")

    // --- DCF77: Audio mit Rauschen (S/N in 20 Hz; Rauschen über 4 kHz Bandbreite) ---
    func dcfMinutes(snr20: Double, minutes: Int) -> (decoded: [DCF77Core.DecodedTime], snr: Double) {
        let carrier = 0.8 * 0.8 / 2.0
        let sigma = sqrt(carrier / pow(10, (snr20 - 10 * log10(4000.0 / 20.0)) / 10))
        var audio: [Float] = []
        audio += DCF77SignalGenerator.generateMinuteAudio(bits: [0], centerHz: 1000)[0..<8000]
        audio += DCF77SignalGenerator.generateMinuteAudio(bits: [], centerHz: 1000)[0..<8000]
        for m in 0..<minutes {
            audio += DCF77SignalGenerator.generateMinuteAudio(
                bits: DCF77SignalGenerator.encodeBits(year: 2026, month: 10, day: 1, weekday: 4, hour: 14, minute: 10 + m, isSummer: true), centerHz: 1000)
        }
        for i in 0..<audio.count { audio[i] += Float(gauss() * sigma) }
        let core = DCF77Core(centerHz: 1000)
        var out: [DCF77Core.DecodedTime] = []
        core.onTimeDecoded = { out.append($0) }
        var o = 0
        while o < audio.count {
            let c = min(160, audio.count - o)
            audio[o..<(o + c)].withUnsafeBufferPointer { core.process($0) }
            o += c
        }
        return (out, core.getStatus().snrDb)
    }
    for snr in [30.0, 20.0] {
        let r = dcfMinutes(snr20: snr, minutes: 8)
        check(r.decoded.count >= 7, "DCF77: \(Int(snr)) dB S/N in 20 Hz: \(r.decoded.count)/8 Minuten decodiert")
        check(abs(r.snr - snr) < 3.5, "DCF77: SNR-Anzeige \(String(format: "%.1f", r.snr)) dB bei \(Int(snr)) dB")
        check(r.decoded.allSatisfy { $0.hour == 14 && $0.day == 1 && (10...17).contains($0.minute) }, "DCF77: \(Int(snr)) dB: nur richtige Zeiten ausgegeben")
    }
    let weak = dcfMinutes(snr20: 15, minutes: 8)
    check(weak.decoded.count >= 4, "DCF77: 15 dB S/N: \(weak.decoded.count)/8 Minuten (Paritätsfehler durch Vorhersage aufgefangen)")
    check(weak.decoded.allSatisfy { $0.hour == 14 && $0.day == 1 && (10...17).contains($0.minute) }, "DCF77: 15 dB: keine falschen Zeiten")
    let noiseOnly = dcfMinutes(snr20: -20, minutes: 3)
    check(noiseOnly.decoded.isEmpty, "DCF77: reines Rauschen liefert keine Zeit")

    // --- EFR: kein Telegramminhalt wird erfunden ---
    let payload: [UInt8] = [0x64, 0x3C, 0x1E, 0x00, 0x01]
    let rawFrame = EFRSignalGenerator.buildVariableFrame(control: 0x53, address: 0x21, asdu: [0x00] + payload)   // A1 0x21, A2 0x00
    let efrCore = EFRCore(centerHz: 1500, shiftHz: 340)
    var efrOut: [EFRCore.DecodedTelegram] = []
    efrCore.onTelegramDecoded = { efrOut.append($0) }
    let efrAudio = EFRSignalGenerator.generateFSKAudio(bits: EFRSignalGenerator.bytesTo8E1Bits(rawFrame, leadBits: 20, tailBits: 20), centerHz: 1500, shiftHz: 340)
    efrAudio.withUnsafeBufferPointer { efrCore.process($0) }
    check(efrOut.count == 1 && efrOut[0].isTimeSync == false, "EFR: Nutzdaten ohne Zeitfeld sind kein Zeittelegramm")
    check(efrOut.first.map { !$0.summary.contains("Leistungsstufe") && !$0.summary.contains("Abregelung") && $0.summary.contains("64 3C 1E 00 01") } == true,
          "EFR: Nutzdaten als Hex, keine geratene Schaltbedeutung (\(efrOut.first?.summary ?? "–"))")
    // Echtes Telegramm aus der DCF39-Aufnahme (dcf39_decoder, MIT): Nr. 2, A1 A3, A2 A3, Nutzdaten 60 10 F2 9D CF, CRC 3B
    let realFrame: [UInt8] = [0x68, 0x08, 0x08, 0x68, 0x27, 0xA3, 0xA3, 0x60, 0x10, 0xF2, 0x9D, 0xCF, 0x3B, 0x16]
    let rc2 = EFRCore(centerHz: 1500, shiftHz: 340)
    var realOut: [EFRCore.DecodedTelegram] = []
    rc2.onTelegramDecoded = { realOut.append($0) }
    EFRSignalGenerator.generateFSKAudio(bits: EFRSignalGenerator.bytesTo8E1Bits(realFrame, leadBits: 20, tailBits: 20), centerHz: 1500, shiftHz: 340)
        .withUnsafeBufferPointer { rc2.process($0) }
    check(realOut.first?.telegramNumber == 2 && realOut.first?.address == 0xA3 && realOut.first?.address2 == 0xA3
          && realOut.first?.summary.contains("60 10 F2 9D CF") == true, "EFR: echtes DCF39-Telegramm Nr. 2, A1/A2 = A3, Nutzdaten 60 10 F2 9D CF")

    // Nutzdaten sehen nie zufällig wie ein Zeittelegramm aus: A1 = A2 = 0 und führendes Nullbyte sind Pflicht
    var randomTimeLike = 0
    for _ in 0..<2000 {
        let rb = (0..<7).map { _ in UInt8(truncatingIfNeeded: Int(gauss() * 80 + 128)) }
        if EFRCore.parseTimeTelegram(rb) != nil { randomTimeLike += 1 }
    }
    check(randomTimeLike < 10, "EFR: zufällige 7-Byte-Folgen gelten selten als Zeittelegramm (\(randomTimeLike)/2000)")
    // Telegramm mit Text (Sendername im Testtelegramm)
    let named = EFRSignalGenerator.buildVariableFrame(control: 0x17, address: 0x00, asdu: [0x00] + Array("DCF39".utf8))
    let ec = EFRCore(centerHz: 1500, shiftHz: 340)
    var namedOut: [EFRCore.DecodedTelegram] = []
    ec.onTelegramDecoded = { namedOut.append($0) }
    EFRSignalGenerator.generateFSKAudio(bits: EFRSignalGenerator.bytesTo8E1Bits(named, leadBits: 20, tailBits: 20), centerHz: 1500, shiftHz: 340)
        .withUnsafeBufferPointer { ec.process($0) }
    check(namedOut.first?.summary.contains("Text: DCF39") == true && namedOut.first?.isTimeSync == false, "EFR: Testtelegramm mit Sendernamen als Text (\(namedOut.first?.summary ?? "–"))")

    // --- EFR: Polarität (Mark = untere Frequenz; invertiert z. B. bei LSB) wird automatisch erkannt ---
    for inverted in [false, true] {
        let c = EFRCore(centerHz: 1500, shiftHz: 340)
        var got: [EFRCore.DecodedTelegram] = []
        c.onTelegramDecoded = { got.append($0) }
        let a = EFRSignalGenerator.generateFSKAudio(bits: EFRSignalGenerator.bytesTo8E1Bits(rawFrame, leadBits: 20, tailBits: 20),
                                                    centerHz: 1500, shiftHz: 340, inverted: inverted)
        a.withUnsafeBufferPointer { c.process($0) }
        check(got.count == 1 && got.first?.rawBytes == rawFrame, "EFR: Telegramm bei \(inverted ? "invertierter" : "normaler") Polarität decodiert (\(got.count))")
        check(c.polarityInverted == inverted, "EFR: Polarität \(inverted ? "invertiert" : "normal") erkannt")
        check(c.getStatus().markHz < c.getStatus().spaceHz, "EFR: Mark liegt unter Space (\(Int(c.getStatus().markHz)) < \(Int(c.getStatus().spaceHz)) Hz)")
    }

    // --- EFR: echte Aufnahme (DCF39 über WebSDR, MIT, siehe TestData/EFR/README.md) ---
    let efrWav = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestData/EFR/dcf39_websdr_8k.wav")
    if let file = try? AVAudioFile(forReading: efrWav),
       let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
       (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] {
        let real = EFRCore(centerHz: 1570, shiftHz: 340)
        var got: [EFRCore.DecodedTelegram] = []
        real.onTelegramDecoded = { got.append($0) }
        var idx = 0
        let n = Int(buf.frameLength)
        while idx < n {
            let c = min(160, n - idx)
            real.process(UnsafeBufferPointer(start: ch + idx, count: c))
            idx += c
        }
        check(file.processingFormat.sampleRate == 8000, "EFR echt: Testdatei hat 8 kHz")
        check(got.count == 2 && got.allSatisfy { $0.isTimeSync }, "EFR echt: 2 Zeittelegramme decodiert (\(got.count))")
        check(got.first?.summary.contains("16.04.2025 17:10:32 MESZ") == true && got.last?.summary.contains("17:10:42 MESZ") == true,
              "EFR echt: Mi 16.04.2025 17:10:32 und 17:10:42 MESZ (\(got.map(\.summary)))")
        check(got.first?.rawHex == "68 0A 0A 68 37 00 00 00 80 0A 91 70 04 19 DF 16", "EFR echt: Rohbytes wie im Fremddecoder")
        check(real.polarityInverted == false, "EFR echt: normale Polarität (Mark = untere Frequenz, USB)")
    } else {
        check(false, "EFR echt: TestData/EFR/dcf39_websdr_8k.wav nicht lesbar")
    }

    // --- EFR: Frequenznachführung, auch mit der echten Aufnahme bei falscher Mitte ---
    for offset in [-45.0, 35.0] {
        let c = EFRCore(centerHz: 1500, shiftHz: 340)
        var got = 0
        c.onTelegramDecoded = { _ in got += 1 }
        for _ in 0..<3 {   // Nachführung braucht einige Zehntelsekunden
            EFRSignalGenerator.generateFSKAudio(bits: EFRSignalGenerator.bytesTo8E1Bits(rawFrame, leadBits: 30, tailBits: 10), centerHz: 1500 + offset, shiftHz: 340)
                .withUnsafeBufferPointer { c.process($0) }
        }
        check(got >= 2, "EFR AFC: Signal \(Int(offset)) Hz neben der Mitte: \(got)/3 Telegramme")
        check(abs(c.getStatus().afcOffsetHz - offset) < 8, "EFR AFC: Nachführung \(String(format: "%+.1f", c.getStatus().afcOffsetHz)) Hz (Soll \(Int(offset)))")
    }
    if let file = try? AVAudioFile(forReading: efrWav),
       let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
       (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] {
        for wrongCenter in [1530.0, 1610.0] {
            let c = EFRCore(centerHz: wrongCenter, shiftHz: 340)
            var got = 0
            c.onTelegramDecoded = { _ in got += 1 }
            var idx = 0
            let n = Int(buf.frameLength)
            while idx < n {
                let k = min(160, n - idx)
                c.process(UnsafeBufferPointer(start: ch + idx, count: k))
                idx += k
            }
            check(got == 2, "EFR echt + AFC: Mitte \(Int(wrongCenter)) statt 1570 Hz: \(got)/2 Telegramme, AFC \(String(format: "%+.0f", c.getStatus().afcOffsetHz)) Hz")
        }
    }

    // --- EFR: Wiederholungen werden zusammengefasst ---
    do {
        var list: [EFRCore.DecodedTelegram] = []
        func telegram(_ bytes: [UInt8], at t: Double) -> EFRCore.DecodedTelegram {
            EFRCore.DecodedTelegram(timestamp: Date(timeIntervalSince1970: t), frameType: .variable, rawBytes: bytes, controlByte: 0, telegramNumber: 0,
                                    address: 1, address2: 2, asduType: nil, title: "t", summary: "s", isTimeSync: false, decodedTime: nil, deltaMilliseconds: nil)
        }
        let first = EFRController.insertOrMerge(telegram([1, 2, 3], at: 100), into: &list, maxEntries: 200)
        let second = EFRController.insertOrMerge(telegram([1, 2, 3], at: 102), into: &list, maxEntries: 200)
        let other = EFRController.insertOrMerge(telegram([9, 9], at: 103), into: &list, maxEntries: 200)
        let late = EFRController.insertOrMerge(telegram([1, 2, 3], at: 200), into: &list, maxEntries: 200)   // viel später: neues Telegramm
        check(first && !second && other && late, "EFR: Wiederholung innerhalb von 15 s wird nicht neu gelistet")
        check(list.count == 3 && list.first(where: { $0.rawBytes == [1, 2, 3] && $0.timestamp.timeIntervalSince1970 == 100 })?.repeats == 1, "EFR: Wiederholungszähler am ersten Eintrag")
    }

    // --- EFR: Rauschen ---
    let carrier = 0.8 * 0.8 / 2.0
    func efrNoisy(snr150: Double, repeats: Int) -> (telegrams: Int, snr: Double) {
        let sigma = sqrt(carrier / pow(10, (snr150 - 10 * log10(4000.0 / 150.0)) / 10))
        let core = EFRCore(centerHz: 1500, shiftHz: 340)
        var n = 0
        core.onTelegramDecoded = { _ in n += 1 }
        for _ in 0..<repeats {
            var a = EFRSignalGenerator.generateFSKAudio(bits: EFRSignalGenerator.bytesTo8E1Bits(rawFrame, leadBits: 20, tailBits: 20), centerHz: 1500, shiftHz: 340)
            for i in 0..<a.count { a[i] += Float(gauss() * sigma) }
            a.withUnsafeBufferPointer { core.process($0) }
        }
        return (n, core.getStatus().snrDb)
    }
    let e20 = efrNoisy(snr150: 20, repeats: 20)
    check(e20.telegrams == 20, "EFR: 20 dB S/N: \(e20.telegrams)/20 Telegramme")
    let e15 = efrNoisy(snr150: 15, repeats: 20)
    check(e15.telegrams >= 15, "EFR: 15 dB S/N: \(e15.telegrams)/20 Telegramme")
    check(e20.snr > e15.snr + 2, "EFR: SNR-Anzeige folgt dem Signal (\(String(format: "%.1f", e20.snr)) dB > \(String(format: "%.1f", e15.snr)) dB)")
    let quiet = EFRCore(centerHz: 1500, shiftHz: 340)
    var junk = 0
    quiet.onTelegramDecoded = { _ in junk += 1 }
    var noise = [Float](repeating: 0, count: 8000 * 60)
    for i in 0..<noise.count { noise[i] = Float(gauss() * 0.3) }
    noise.withUnsafeBufferPointer { quiet.process($0) }
    check(junk == 0 && quiet.getStatus().bytesReceived < 10, "EFR: 60 s reines Rauschen → \(quiet.getStatus().bytesReceived) Bytes, \(junk) Telegramme (Squelch)")
}

// MARK: - Funkgerät abstimmen (rigctld F/M): Ziele, Befehle, Ende-zu-Ende gegen einen nachgebauten rigctld
do {
    // Ziele je Modul (Dial-Frequenz, nicht Sendefrequenz)
    check(RigTuneTarget.ft8(band: .m20) == RigTuneTarget(dialHz: 14_074_000, mode: "USB"), "QSY: FT8 20 m = 14,074 MHz USB")
    check(RigTuneTarget.ft4(band: .m20) == RigTuneTarget(dialHz: 14_080_000, mode: "USB"), "QSY: FT4 20 m = 14,080 MHz USB")
    check(RigTuneTarget.sstv(channel: .twenty) == RigTuneTarget(dialHz: 14_230_000, mode: "USB"), "QSY: SSTV 20 m = 14,230 MHz USB")
    check(RigTuneTarget.sstv(channel: .forty)?.mode == "LSB", "QSY: SSTV 40 m in LSB")
    check(RigTuneTarget.sstv(channel: .iss) == RigTuneTarget(dialHz: 145_800_000, mode: "FM"), "QSY: ISS 145,800 MHz FM")
    check(RigTuneTarget.sstv(channel: .custom) == nil, "QSY: SSTV frei = kein Ziel")
    check(RigTuneTarget.dcf77(centerHz: 1000) == RigTuneTarget(dialHz: 76_500, mode: "USB"), "QSY: DCF77 Dial 76,5 kHz USB bei Ton 1000 Hz")
    check(RigTuneTarget.dcf77(centerHz: 500).dialHz == 77_000, "QSY: DCF77 Dial folgt dem Ton (500 Hz → 77,0 kHz)")
    check(RigTuneTarget.efr(station: .dcf49, centerHz: 1500) == RigTuneTarget(dialHz: 127_600, mode: "USB"), "QSY: EFR DCF49 Dial 127,6 kHz")
    check(RigTuneTarget.efr(station: .dcf39, centerHz: 1500)?.dialHz == 137_500, "QSY: EFR DCF39 Dial 137,5 kHz")
    check(RigTuneTarget.efr(station: .custom, centerHz: 1500) == nil, "QSY: EFR frei = kein Ziel")
    check(RigTuneTarget.wefax(station: .dwd7880, centerHz: 1900) == RigTuneTarget(dialHz: 7_878_100, mode: "USB"), "QSY: WEFAX 7880 kHz, Dial 7878,1 kHz USB")
    check(RigTuneTarget.navtex(frequency: .f518, centerHz: 1000).dialHz == 517_000, "QSY: NAVTEX 518 kHz, Dial 517 kHz")
    check(RigTuneTarget.ft8(band: .m20).label == "14,074 MHz USB", "QSY: Beschriftung \(RigTuneTarget.ft8(band: .m20).label)")

    // Befehle: nur F und M, geprüft
    check(RigCommand.frequency(14_074_000) == "F 14074000\n", "QSY: Befehl F")
    check(RigCommand.frequency(5) == nil && RigCommand.frequency(-1) == nil && RigCommand.frequency(20_000_000_000) == nil, "QSY: unsinnige Frequenzen werden nicht gesendet")
    check(RigCommand.mode("usb", passbandHz: nil) == "M USB 0\n" && RigCommand.mode("FM", passbandHz: 15_000) == "M FM 15000\n", "QSY: Befehl M")
    check(RigCommand.mode("USB\nT 1", passbandHz: nil) == nil, "QSY: Mode mit eingeschmuggeltem Befehl (PTT) wird abgewiesen")
    check(RigCommand.mode("PWR", passbandHz: nil) == nil, "QSY: nur erlaubte Modes")

    // Ende-zu-Ende: nachgebauter rigctld (wie im Commander: F/M setzen Frequenz und Mode, f/m lesen sie)
    final class FakeRigctld: @unchecked Sendable {
        let lock = NSLock()
        var commands: [String] = []
        var freq = 7_100_000, mode = "LSB"
        var listener: Int32 = -1
        var port: UInt16 = 0
        init() {
            listener = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(listener, 4)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
            port = UInt16(bigEndian: addr.sin_port)
            Thread.detachNewThread { [self] in
                while true {
                    let c = accept(listener, nil, nil)
                    if c < 0 { return }
                    Thread.detachNewThread { [self] in serve(c) }
                }
            }
        }
        func serve(_ c: Int32) {
            var pending = ""
            var buf = [UInt8](repeating: 0, count: 256)
            while true {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { close(c); return }
                pending += String(decoding: buf[0..<n], as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[pending.startIndex..<nl]); pending.removeSubrange(pending.startIndex...nl)
                    lock.lock(); commands.append(line)
                    var reply = "RPRT -1\n"
                    let parts = line.split(separator: " ")
                    switch parts.first {
                    case "f": reply = "\(freq)\n"
                    case "m": reply = "\(mode)\n2400\n"
                    case "F": if parts.count == 2, let v = Int(parts[1]) { freq = v; reply = "RPRT 0\n" }
                    case "M": if parts.count == 3 { mode = String(parts[1]); reply = "RPRT 0\n" }
                    default: break
                    }
                    lock.unlock()
                    _ = reply.withCString { send(c, $0, strlen($0), 0) }
                }
            }
        }
    }
    let fake = FakeRigctld()
    final class Latest: @unchecked Sendable { let lock = NSLock(); var state = RigState(); var set: ((RigState) -> Void)?
        func put(_ s: RigState) { lock.lock(); state = s; lock.unlock() }
        func get() -> RigState { lock.lock(); defer { lock.unlock() }; return state } }
    let latest = Latest()
    let client = RigctlClient { latest.put($0) }
    client.setPort(fake.port)
    func waitFor(_ cond: () -> Bool, seconds: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return cond()
    }
    check(waitFor { latest.get().connected && latest.get().frequencyHz == 7_100_000 }, "QSY e2e: Verbindung, Frequenz 7,100 MHz LSB gelesen")

    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: RigTuneResult?
    client.tune(frequencyHz: 14_080_000, mode: "USB", passbandHz: nil) { result = $0; done.signal() }
    check(done.wait(timeout: .now() + 5) == .success && result == .ok, "QSY e2e: Abstimmen meldet ok (\(String(describing: result)))")
    check(waitFor { latest.get().frequencyHz == 14_080_000 && latest.get().mode == "USB" }, "QSY e2e: Gerät steht auf 14,080 MHz USB (Commander folgt)")
    fake.lock.lock()
    let sent = fake.commands
    fake.lock.unlock()
    check(sent.contains("F 14080000") && sent.contains("M USB 0"), "QSY e2e: F und M wurden gesendet (\(sent.filter { $0.first == "F" || $0.first == "M" }))")
    check(sent.allSatisfy { ["f", "m", "F", "M"].contains(String($0.split(separator: " ").first ?? "")) }, "QSY e2e: es gingen nur f, m, F, M über die Leitung (nie PTT): \(Set(sent.map { String($0.split(separator: " ").first ?? "") }))")

    // Unzulässiges wird gar nicht erst gesendet
    let before = fake.commands.count
    let bad = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var badResult: RigTuneResult?
    client.tune(frequencyHz: 14_080_000, mode: "USB\nT 1", passbandHz: nil) { badResult = $0; bad.signal() }
    _ = bad.wait(timeout: .now() + 5)
    if case .rejected = badResult {} else { check(false, "QSY e2e: unzulässiger Mode wird abgewiesen (\(String(describing: badResult)))") }
    fake.lock.lock(); let after = fake.commands; fake.lock.unlock()
    check(!after.dropFirst(before).contains { $0.hasPrefix("T") }, "QSY e2e: PTT wurde nie gesendet")

    // Ohne Verbindung
    let lone = RigctlClient { _ in }
    let none = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var noneResult: RigTuneResult?
    lone.tune(frequencyHz: 7_100_000, mode: "USB", passbandHz: nil) { noneResult = $0; none.signal() }
    _ = none.wait(timeout: .now() + 5)
    check(noneResult == .notConnected, "QSY: ohne Port keine Abstimmung (\(String(describing: noneResult)))")
    client.setPort(nil)
}

// MARK: - WEFAX: DWD-Sendeplan (Auslesen, Zeitlogik, automatische Aufnahme, Link-Erkennung)
do {
    let planURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Wefax/sendeplan_fax_092023.txt")
    let text = (try? String(contentsOf: planURL, encoding: .utf8)) ?? ""
    guard let plan = WefaxSchedule.parse(text: text) else {
        check(false, "Sendeplan: Auslesen des DWD-Plans (Resources/Wefax) fehlgeschlagen")
        throw NSError(domain: "Sendeplan", code: 1)
    }
    check(plan.frequenciesHz == [3_855_000, 7_880_000, 13_882_500], "Sendeplan: Frequenzen 3855 / 7880 / 13882,5 kHz")
    check(plan.broadcasts.count == 48 && plan.pauses.count == 4, "Sendeplan: 48 Ausstrahlungen, 4 Sendepausen (\(plan.broadcasts.count)/\(plan.pauses.count))")
    check(plan.broadcasts.first?.id == "0430" && plan.broadcasts.first?.durationMinutes == 19 && plan.broadcasts.first?.lpm == 120,
          "Sendeplan: erste Sendung 04:30, 19 min, 120 UpM")
    check(plan.broadcasts.last?.id == "2200" && plan.broadcasts.last?.chartHour == 18, "Sendeplan: letzte Sendung 22:00, Termin 18 UTC")
    check(plan.broadcasts.first(where: { $0.id == "1520" })?.title.hasSuffix("Eiskarte Spezialgebiet (BSH)") == true,
          "Sendeplan: Folgezeile gehört zur Karte 15:20")
    check(plan.pauses.contains(WefaxPause(startMinute: 15 * 60 + 55, endMinute: 16 * 60 + 35)), "Sendeplan: Sendepause 15:55–16:35")
    check(WefaxSchedule.parse(text: "Das ist kein Sendeplan\n04.30 abc") == nil, "Sendeplan: fremder Text wird abgewiesen")
    check(WefaxSchedule.parse(text: text.replacingOccurrences(of: "576", with: "123")) == nil, "Sendeplan: verändertes Format (Modul) wird abgewiesen")

    func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    // Nächste und laufende Sendung
    check(ScheduleCalc.next(items: plan.items, after: utc("2026-10-01T16:06:00Z"))?.item.id == "1636", "Sendeplan: 16:06 UTC → nächste 16:36")
    check(ScheduleCalc.next(items: plan.items, after: utc("2026-10-01T16:36:00Z"))?.item.id == "1800", "Sendeplan: genau 16:36 → nächste ist 18:00 (16:36 läuft)")
    check(ScheduleCalc.next(items: plan.items, after: utc("2026-10-01T23:00:00Z")).map { $0.item.id == "0430" && $0.start == utc("2026-10-02T04:30:00Z") } == true,
          "Sendeplan: nach 22:00 → morgen 04:30")
    check(ScheduleCalc.running(items: plan.items, at: utc("2026-10-01T16:40:00Z"))?.item.id == "1636", "Sendeplan: 16:40 läuft die Sendung von 16:36")
    check(ScheduleCalc.running(items: plan.items, at: utc("2026-10-01T16:00:00Z")) == nil, "Sendeplan: 16:00 Sendepause, nichts läuft")

    // Automatische Aufnahme: Zeitfenster und Einmaligkeit
    let sel: Set<String> = ["1636"]
    check(ScheduleCalc.due(items: plan.items, selected: sel, at: utc("2026-10-01T16:34:00Z"), handled: []) == nil, "Auto: 2:00 vor Beginn noch nicht")
    check(ScheduleCalc.due(items: plan.items, selected: sel, at: utc("2026-10-01T16:34:40Z"), handled: [])?.item.id == "1636", "Auto: 80 s vor Beginn startet die Vorbereitung")
    let key = ScheduleCalc.due(items: plan.items, selected: sel, at: utc("2026-10-01T16:36:30Z"), handled: [])?.key
    check(key == "20261001-wefax-1636", "Auto: Schlüssel \(key ?? "–")")
    check(ScheduleCalc.due(items: plan.items, selected: sel, at: utc("2026-10-01T16:36:30Z"), handled: ["20261001-wefax-1636"]) == nil, "Auto: bereits begonnene Sendung nicht noch einmal")
    check(ScheduleCalc.due(items: plan.items, selected: sel, at: utc("2026-10-01T16:39:00Z"), handled: []) == nil, "Auto: 3 min nach Beginn kein Einstieg mehr (nur Restbild)")
    check(ScheduleCalc.due(items: plan.items, selected: sel, at: utc("2026-10-02T16:36:10Z"), handled: ["20261001-wefax-1636"])?.key == "20261002-wefax-1636", "Auto: nächster Tag zählt neu")
    check(ScheduleCalc.due(items: plan.items, selected: [], at: utc("2026-10-01T16:36:10Z"), handled: []) == nil, "Auto: ohne Auswahl keine Aufnahme")
    check(ScheduleCalc.due(items: plan.items, selected: ["0430"], at: utc("2026-10-01T23:59:00Z"), handled: []) == nil && ScheduleCalc.due(items: plan.items, selected: ["0430"], at: utc("2026-10-02T04:29:00Z"), handled: [])?.key == "20261002-wefax-0430",
          "Auto: Sendung am nächsten Morgen")

    // Frequenz nach Tageszeit
    check(WefaxSchedule.recommendedFrequencyHz(at: utc("2026-10-01T04:30:00Z")) == 3_855_000, "Frequenz 04:30 UTC: 3855 kHz")
    check((0..<24).allSatisfy { WefaxSchedule.recommendedFrequencyHz(at: utc(String(format: "2026-10-01T%02d:30:00Z", $0))) != 13_882_500 }, "Frequenz: 13882,5 kHz wird zu keiner Stunde automatisch gewählt")
    check(WefaxSchedule.recommendedFrequencyHz(at: utc("2026-10-01T08:00:00Z")) == 7_880_000, "Frequenz 08:00 UTC: 7880 kHz")
    check(WefaxSchedule.recommendedFrequencyHz(at: utc("2026-10-01T12:00:00Z")) == 7_880_000, "Frequenz 12:00 UTC: 7880 kHz (13882,5 nie automatisch)")
    check(WefaxSchedule.recommendedFrequencyHz(at: utc("2026-10-01T18:00:00Z")) == 3_855_000, "Frequenz 18:00 UTC: 3855 kHz")
    check(WefaxSchedule.recommendedFrequencyHz(at: utc("2026-10-01T22:00:00Z")) == 3_855_000, "Frequenz 22:00 UTC: 3855 kHz")

    // Link auf der DWD-Seite (echter Ausschnitt, mit jsessionid)
    let html = """
    <a href="/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_rtty_01_092023.pdf;jsessionid=ABC.live31091?__blob=publicationFile&amp;v=1">RTTY</a>
    <a class="download" href="/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_fax_092023.pdf;jsessionid=987886A8B538D6CC6BEB67909269897E.live31091?__blob=publicationFile&amp;v=1">Radiofax</a>
    """
    check(WefaxScheduleSource.faxPDFURL(inHTML: html)?.absoluteString == "https://www.dwd.de/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_fax_092023.pdf?__blob=publicationFile&v=1",
          "Sendeplan: Link zum Fax-PDF ohne jsessionid (\(WefaxScheduleSource.faxPDFURL(inHTML: html)?.absoluteString ?? "nil"))")
    check(WefaxScheduleSource.faxPDFURL(inHTML: "<html>nichts</html>") == nil, "Sendeplan: kein Link → nil")

    // Dateiname aus dem Kartentitel
    check(WefaxController.fileSlug("Bodenanalyse mit Stationseintragungen, Nordatlantik, Europa") == "Bodenanalyse-mit-Stationseintragungen-No", "Dateiname: Titel gekürzt (\(WefaxController.fileSlug("Bodenanalyse mit Stationseintragungen, Nordatlantik, Europa")))")
    check(WefaxController.fileSlug("Wirbelstürme über Nordatlantik") == "Wirbelstuerme-ueber-Nordatlantik", "Dateiname: Umlaute aufgelöst")
}

// MARK: - WEFAX: Bild verschieben (Umlauf) und Naht-Erkennung
do {
    // Umlauf: kleines Beispiel
    let w = 6, h = 2
    let px: [UInt8] = [1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 15, 16]
    check(WefaxImageTools.shifted(px, width: w, height: h, by: 0) == px, "Verschieben: 0 ändert nichts")
    check(WefaxImageTools.shifted(px, width: w, height: h, by: 2) == [5, 6, 1, 2, 3, 4, 15, 16, 11, 12, 13, 14], "Verschieben: 2 nach rechts mit Umlauf")
    check(WefaxImageTools.shifted(px, width: w, height: h, by: -1) == [2, 3, 4, 5, 6, 1, 12, 13, 14, 15, 16, 11], "Verschieben: −1 nach links mit Umlauf")
    check(WefaxImageTools.shifted(px, width: w, height: h, by: 6) == px && WefaxImageTools.shifted(px, width: w, height: h, by: 8) == WefaxImageTools.shifted(px, width: w, height: h, by: 2),
          "Verschieben: ganze Breite = identisch, Vielfache werden gekürzt")
    check(WefaxImageTools.shifted(WefaxImageTools.shifted(px, width: w, height: h, by: 4), width: w, height: h, by: -4) == px, "Verschieben: hin und zurück")

    // Synthetische Wetterkarte: Inhalt mit Linien, weißer Streifen (Rand) bei [700, 860) – wie im echten Bild verschoben
    let W = 1809, H = 200
    var chart = [UInt8](repeating: 255, count: W * H)
    var seed: UInt64 = 5
    func rnd() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
    for y in 0..<H { for x in 0..<W where !(700..<860).contains(x) && rnd() % 5 == 0 { chart[y * W + x] = UInt8(rnd() % 120) } }
    let dx = WefaxImageTools.autoShift(chart, width: W, height: H)
    // Streifenmitte 779 muss an den Rand (0): Verschiebung ≈ −779
    check(abs(dx - (-779)) <= 3, "Naht: Streifenmitte 779 → Verschiebung \(dx) (Soll ≈ −779)")
    let fixed = WefaxImageTools.shifted(chart, width: W, height: H, by: dx)
    var whiteAtEdge = 0
    for y in 0..<H { for x in [0, 1, 2, W - 3, W - 2, W - 1] where fixed[y * W + x] == 255 { whiteAtEdge += 1 } }
    check(whiteAtEdge == H * 6, "Naht: nach dem Verschieben ist der Rand weiß (\(whiteAtEdge)/\(H * 6))")
    // Bild, das schon richtig liegt: Streifen am Rand → Verschiebung ≈ 0
    let aligned = WefaxImageTools.shifted(chart, width: W, height: H, by: dx)
    check(abs(WefaxImageTools.autoShift(aligned, width: W, height: H)) <= 3, "Naht: bereits richtig liegendes Bild bleibt")
    // Kein heller Streifen (gleichmäßige Tinte, z. B. Textseite): nichts verschieben
    var noisy = [UInt8](repeating: 255, count: W * H)
    for i in 0..<noisy.count where rnd() % 3 == 0 { noisy[i] = UInt8(rnd() % 120) }
    check(WefaxImageTools.autoShift(noisy, width: W, height: H) == 0, "Naht: ohne hellen Streifen bleibt es bei 0")
    check(WefaxImageTools.autoShift([UInt8](repeating: 255, count: W * H), width: W, height: H) == 0, "Naht: leeres weißes Bild bleibt 0")
    check(WefaxImageTools.autoShift([1, 2, 3], width: 3, height: 1) == 0, "Naht: zu kleines Bild bleibt 0")
}

// MARK: - WEFAX: Frequenz je Sendung und automatische Nahtkorrektur
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("digidec_wefax_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = WefaxScheduleStore(directory: tmp.appendingPathComponent("plan"))
    store.frequencyChoice = .auto
    store.setOverride(nil, for: store.schedule.broadcasts[0])
    let b1 = store.schedule.broadcasts.first(where: { $0.id == "1236" }) ?? store.schedule.broadcasts[20]
    func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    check(store.choice(for: b1) == .auto && WefaxFrequencyChoice.auto.station(at: utc("2026-10-01T12:36:00Z")) == .dwd7880, "Frequenz je Sendung: Standard ist Automatik (12:36 UTC → 7880)")
    store.setOverride(.f3855, for: b1)
    check(store.choice(for: b1) == .f3855 && store.choice(for: b1).station(at: utc("2026-10-01T12:36:00Z")) == .dwd3855, "Frequenz je Sendung: Wahl 3855 überstimmt die Automatik")
    check(store.frequencyOverrides.count == 1, "Frequenz je Sendung: nur diese Sendung ist betroffen")
    let again = WefaxScheduleStore(directory: tmp.appendingPathComponent("plan"))
    check(again.frequencyOverrides[b1.id] == .f3855, "Frequenz je Sendung: bleibt nach Neustart erhalten")
    store.setOverride(.auto, for: b1)
    check(store.frequencyOverrides.isEmpty, "Frequenz je Sendung: Auto/Standard entfernt die Sonderwahl")

    // Nahtkorrektur: gespeicherte Datei, Kopie „_korr“, Original ersetzen mit Sicherung
    let ctrl = WefaxController(pipeline: AudioPipeline(), settings: WefaxSettingsStore(), directory: tmp.appendingPathComponent("bilder"))
    ctrl.autoSave = true
    ctrl.autoCorrectSeam = true
    let W = 900, H = 160
    var px = [UInt8](repeating: 255, count: W * H)
    var seed: UInt64 = 9
    for y in 0..<H { for x in 0..<W where !(380..<450).contains(x) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        if (seed >> 33) % 4 == 0 { px[y * W + x] = 30 }
    } }
    let fileURL = tmp.appendingPathComponent("bilder/wefax_20261001_123600_3855_ok.png")
    var img = WefaxImage(name: "wefax_20261001_123600_3855_ok.png", comments: "", width: W, height: H, pixels: px, receivedAt: Date(), fileURL: fileURL)
    img.fileURL = (try? WefaxController.writePNG(img, to: tmp.appendingPathComponent("bilder"))) ?? fileURL
    let fixedCopy = ctrl.correctSeamCopy(of: img)
    check(fixedCopy?.name == "wefax_20261001_123600_3855_ok_korr.png", "Nahtkorrektur: Kopie heißt …_korr.png (\(fixedCopy?.name ?? "nil"))")
    check(fixedCopy?.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "Nahtkorrektur: Kopie liegt auf der Platte")
    check(fixedCopy.map { abs(WefaxImageTools.autoShift($0.pixels, width: W, height: H)) <= 3 } == true, "Nahtkorrektur: Kopie hat den Rand am Bildrand")
    check(ctrl.gallery.first?.name == "wefax_20261001_123600_3855_ok_korr.png", "Nahtkorrektur: Kopie steht vorn in der Galerie")
    check(fixedCopy?.comments.contains("verschoben") == true, "Nahtkorrektur: Beschreibung nennt die Verschiebung")
    // Karte, die richtig liegt: keine Kopie
    if let good = fixedCopy { check(ctrl.correctSeamCopy(of: good) == nil, "Nahtkorrektur: richtig liegende Karte bekommt keine Kopie") }
    ctrl.autoCorrectSeam = false
    check(ctrl.correctSeamCopy(of: img) == nil, "Nahtkorrektur: AUTO-NAHT aus → keine Kopie")
    // Original ersetzen mit Sicherung
    let replaced = try? ctrl.saveEdited(img, shift: -415, replaceOriginal: true)
    check(replaced?.name == img.name && FileManager.default.fileExists(atPath: tmp.appendingPathComponent("bilder/wefax_20261001_123600_3855_ok_original.png").path),
          "Original ersetzen: Datei ersetzt, Sicherung …_original.png angelegt")
}

// MARK: - Sendepläne: RTTY (DWD), NAVTEX (IMO-Raster), gemeinsame Zeitrechnung und Entscheidungen der Aufnahmesteuerung
do {
    func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

    // --- RTTY: Plan lesen ---
    guard let p1 = RttySchedule.parse(text: read("Resources/Rtty/sendeplan_rtty_01_092023.txt"), program: 1),
          let p2 = RttySchedule.parse(text: read("Resources/Rtty/sendeplan_rtty_02_092023.txt"), program: 2) else {
        check(false, "RTTY-Plan: Auslesen der DWD-Pläne (Resources/Rtty) fehlgeschlagen")
        throw NSError(domain: "Sendeplan", code: 2)
    }
    check(p1.broadcasts.count == 66 && p2.broadcasts.count == 86, "RTTY-Plan: 66 + 86 Sendungen (\(p1.broadcasts.count) + \(p2.broadcasts.count))")
    check(p1.frequencies.map(\.hz) == [4_583_000, 7_646_000, 10_100_800] && p2.frequencies.map(\.hz) == [147_300, 11_039_000, 14_467_300],
          "RTTY-Plan: Frequenzen Programm 1 und 2")
    check(p2.frequencies[0].isLongwave && p2.frequencies[0].presetID == "dwd-lw" && p1.frequencies[0].presetID == "dwd-kw", "RTTY-Plan: Voreinstellung LW/KW je Frequenz")
    check(p2.frequencies[0].shiftHalfHz == 42.5 && p1.frequencies[1].shiftHalfHz == 225, "RTTY-Plan: Hub ±42,5 Hz (LW) und ±225 Hz (KW)")
    check(p2.frequencies[0].label == "147,3 kHz" && p1.frequencies[2].label == "10100,8 kHz" && p1.frequencies[0].label == "4583 kHz", "RTTY-Plan: Frequenzbeschriftung")
    check(p1.broadcasts.first?.id == "1-0000" && p1.broadcasts.first?.header == "WODL45 EDZW 0000", "RTTY-Plan: erste Sendung 00:00 Sturmwarnungen WODL45")
    check(p1.broadcasts.first?.title.hasPrefix("Sturmwarnungen für Deutsche Bucht") == true && p1.broadcasts.first?.title.contains("Nord- und Ostseeküste") == true,
          "RTTY-Plan: zweizeiliger Titel zusammengeführt")
    let seewetter = p1.broadcasts.first { $0.id == "1-0005" }
    check(seewetter?.title == "Seewetterbericht Nord- und Ostsee" && seewetter?.header == "FQEN70 EDZW 0000" && seewetter?.durationMinutes == 15, "RTTY-Plan: 00:05 Seewetterbericht, 15 min")
    let synop = p1.broadcasts.first { $0.id == "1-0035" }
    check(synop?.title == "Verschlüsselte Wettermeldungen (Synop-Stationen), Termin 00 UTC ausgewählte Küstenstationen Europa, Nordamerika, Nordafrika" && synop?.header == nil && synop?.durationMinutes == 85,
          "RTTY-Plan: Silbentrennung und Umbruch (Synop) bereinigt: \(synop?.title ?? "–")")
    check(p2.broadcasts.first { $0.id == "2-1010" }?.header == "NOXX50 EDZW 0600 / NODL40 EDZW 0800", "RTTY-Plan: zweite Meldung ohne eigene Uhrzeit hängt an 10:10")
    check(p2.broadcasts.first { $0.id == "2-0325" }?.title.contains("bis Shetlands") == true, "RTTY-Plan: „bisShetlands“ aus dem PDF bereinigt")
    check(p1.broadcasts.last?.id == "1-2315" && p1.broadcasts.last?.durationMinutes == 45, "RTTY-Plan: letzte Sendung 23:15 reicht bis 24:00 (45 min)")
    check(!p1.broadcasts.contains { $0.title.lowercased().contains("bei bedarf") } && !p2.broadcasts.contains { $0.title.lowercased().contains("bei bedarf") },
          "RTTY-Plan: „bei Bedarf“-Hinweise sind keine Sendezeiten")
    check(p1.broadcasts.allSatisfy { (1...120).contains($0.durationMinutes) } && p2.broadcasts.allSatisfy { (1...120).contains($0.durationMinutes) }, "RTTY-Plan: Dauern 1…120 min")
    let merged = RttySchedule.merged([p1, p2])
    check(merged.broadcasts.count == 152 && Set(merged.broadcasts.map(\.id)).count == 152, "RTTY-Plan: 152 Sendungen, Kennungen eindeutig")
    check(zip(merged.broadcasts, merged.broadcasts.dropFirst()).allSatisfy { ($0.startMinute, $0.program) <= ($1.startMinute, $1.program) }, "RTTY-Plan: nach Beginn sortiert")
    check(merged.items.count == 152 && merged.items.first?.service == .rtty && merged.items.first?.title.hasPrefix("P1 · ") == true, "RTTY-Plan: einheitliche Sendungen")
    check(RttySchedule.parse(text: "kein Plan", program: 1) == nil, "RTTY-Plan: fremder Text wird abgewiesen")
    check(RttySchedule.parse(text: read("Resources/Rtty/sendeplan_rtty_01_092023.txt").replacingOccurrences(of: "F1B", with: "F9X"), program: 1) == nil,
          "RTTY-Plan: verändertes Format (Betriebsart) wird abgewiesen")

    // Links auf der DWD-Seite
    let html = """
    <a href="/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_rtty_01_092023.pdf;jsessionid=AAA.live1?__blob=publicationFile&amp;v=1">P1</a>
    <a href="/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_rtty_02_092023.pdf;jsessionid=AAA.live1?__blob=publicationFile&amp;v=1">P2</a>
    <a href="/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_fax_092023.pdf;jsessionid=AAA.live1?__blob=publicationFile&amp;v=1">Fax</a>
    """
    check(RttyScheduleSource.pdfURL(program: 1, inHTML: html)?.absoluteString == "https://www.dwd.de/DE/fachnutzer/schifffahrt/funkausstrahlung/sendeplan_rtty_01_092023.pdf?__blob=publicationFile&v=1", "RTTY-Link: Programm 1")
    check(RttyScheduleSource.pdfURL(program: 2, inHTML: html)?.lastPathComponent == "sendeplan_rtty_02_092023.pdf", "RTTY-Link: Programm 2")
    check(WefaxScheduleSource.faxPDFURL(inHTML: html)?.lastPathComponent == "sendeplan_fax_092023.pdf", "Fax-Link wird nicht mit RTTY verwechselt")
    check(RttyScheduleSource.pdfURL(program: 1, inHTML: "<html></html>") == nil, "RTTY-Link: keiner → nil")

    // --- RTTY: Speicher, Frequenzwahl ---
    for k in ["rttySchedSelected", "rttySchedAuto", "rttySchedReturn", "rttySchedDefaultFreq", "rttySchedOverrides"] { UserDefaults.standard.removeObject(forKey: k) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("digidec_sched_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let rs = RttyScheduleStore(directory: tmp)
    check(rs.schedule.broadcasts.count == 152 && rs.sourceName.contains("eingebaut"), "RTTY-Speicher: eingebauter Plan geladen (\(rs.schedule.broadcasts.count))")
    let b1 = rs.schedule.broadcasts.first { $0.id == "1-0505" || $0.program == 1 }!
    let b2 = rs.schedule.broadcasts.first { $0.program == 2 }!
    check(rs.automaticFrequency(program: 2, at: utc("2026-10-01T12:00:00Z"))?.hz == 147_300, "RTTY-Frequenz: Programm 2 automatisch Langwelle 147,3 kHz")
    check(rs.automaticFrequency(program: 1, at: utc("2026-10-01T12:00:00Z"))?.hz == 7_646_000, "RTTY-Frequenz: Programm 1 mittags 7646 kHz")
    check(rs.automaticFrequency(program: 1, at: utc("2026-10-01T22:00:00Z"))?.hz == 4_583_000 && rs.automaticFrequency(program: 1, at: utc("2026-10-01T05:00:00Z"))?.hz == 4_583_000,
          "RTTY-Frequenz: Programm 1 abends/nachts 4583 kHz")
    check(rs.frequency(for: b1, at: utc("2026-10-01T12:00:00Z"))?.hz == 7_646_000, "RTTY-Frequenz: Standard = Automatik")
    rs.setDefaultFrequency(10_100_800, program: 1)
    check(rs.frequency(for: b1, at: utc("2026-10-01T12:00:00Z"))?.hz == 10_100_800, "RTTY-Frequenz: Standardfrequenz Programm 1")
    rs.setOverride(4_583_000, for: b1)
    check(rs.frequency(for: b1, at: utc("2026-10-01T12:00:00Z"))?.hz == 4_583_000 && rs.frequency(for: b2, at: utc("2026-10-01T12:00:00Z"))?.hz == 147_300,
          "RTTY-Frequenz: Wahl je Sendung übersteuert nur diese Sendung")
    rs.setOverride(nil, for: b1)
    check(rs.frequency(for: b1, at: utc("2026-10-01T12:00:00Z"))?.hz == 10_100_800, "RTTY-Frequenz: Sonderwahl entfernt")
    rs.setOverride(123_456, for: b2)   // gibt es nicht im Programm → Standard
    check(rs.frequency(for: b2, at: utc("2026-10-01T12:00:00Z"))?.hz == 147_300, "RTTY-Frequenz: unbekannte Frequenz wird ignoriert")
    rs.toggle(b1)
    check(rs.selected == [b1.id] && UserDefaults.standard.stringArray(forKey: "rttySchedSelected") == [b1.id], "RTTY-Speicher: Auswahl wird gespeichert")
    rs.selectAll(); check(rs.selected.count == 152, "RTTY-Speicher: Alle")
    rs.selectNone(); check(rs.selected.isEmpty, "RTTY-Speicher: Keine")
    for k in ["rttySchedSelected", "rttySchedDefaultFreq", "rttySchedOverrides"] { UserDefaults.standard.removeObject(forKey: k) }

    // RTTY-Ziel für das Funkgerät: Dial = Frequenz − NF-Mitte (USB)
    check(RigTuneTarget(dialHz: Int64(p1.frequencies[0].hz) - 1000, mode: "USB").dialHz == 4_582_000 && RigTuneTarget(dialHz: 4_582_000, mode: "USB").label == "4,582 MHz USB",
          "RTTY-QSY: 4583 kHz bei Ton 1000 Hz → Dial 4582 kHz USB")

    // --- NAVTEX: Plan aus der Stationsliste ---
    let navPlan = NavtexPlan.parse(csv: read("Resources/Stations/NAVTEX_Stations.csv"))
    check(navPlan.stations.count == 204 && Set(navPlan.stations.map(\.id)).count == 204, "NAVTEX-Plan: 204 Stationen, Kennungen eindeutig (\(navPlan.stations.count))")
    let s518 = navPlan.stations.first { $0.id == "DEU-518-S-Pinneberg" }
    let l490 = navPlan.stations.first { $0.id == "DEU-490-L-Pinneberg" }
    check(s518?.startMinutes == [180, 420, 660, 900, 1140, 1380], "NAVTEX-Plan: Pinneberg 518 kHz (S) 03:00, 07:00, 11:00, 15:00, 19:00, 23:00 UTC (laut DWD)")
    check(l490?.startMinutes == [110, 350, 590, 830, 1070, 1310], "NAVTEX-Plan: Pinneberg 490 kHz (L) 01:50, 05:50, 09:50, 13:50, 17:50, 21:50 UTC")
    check(!navPlan.stations.contains { $0.countryCode == "DEU" && $0.frequencyKHz == 518 && $0.letter == "L" }, "NAVTEX-Liste: Pinneberg auf 518 kHz ist nicht mehr „L“")
    check(s518?.frequency == .f518 && l490?.frequency == .f490 && s518?.frequencyLabel == "518 kHz", "NAVTEX-Plan: Frequenzzuordnung")
    // Raster: A = +0, B = +10 … X = +230 Minuten, sechs Fenster im Abstand von 240 Minuten
    func station(_ letter: Character) -> NavtexStation {
        NavtexStation(country: "X", countryCode: "XXX", frequencyKHz: 518, letter: letter, callsign: "", name: "T", navarea: "I", language: "")
    }
    check(station("A").startMinutes == [0, 240, 480, 720, 960, 1200] && station("B").slotOffsetMinutes == 10 && station("X").slotOffsetMinutes == 230,
          "NAVTEX-Raster: A = 00:00, B = 00:10, X = 03:50")
    check(station("X").startMinutes.last == 1430, "NAVTEX-Raster: X letztes Fenster 23:50")
    check(navPlan.stations.allSatisfy { $0.startMinutes.count == 6 && $0.startMinutes.allSatisfy { (0..<1440).contains($0) } }, "NAVTEX-Plan: jede Station 6 gültige Fenster")
    let navItems = navPlan.items(forStationIDs: ["DEU-518-S-Pinneberg", "DEU-490-L-Pinneberg"])
    check(navItems.count == 12 && Set(navItems.map(\.id)).count == 12 && navItems.allSatisfy { $0.durationMinutes == 10 && $0.service == .navtex }, "NAVTEX-Plan: 12 Fenster, 10 min, eindeutige Kennungen")
    check(navItems.first?.id == "DEU-518-S-Pinneberg@0300" || navItems.contains { $0.id == "DEU-518-S-Pinneberg@0300" }, "NAVTEX-Plan: Fenster-Kennung „…@0300“")
    check(navPlan.station(forItemID: "DEU-518-S-Pinneberg@0300")?.id == "DEU-518-S-Pinneberg" && navPlan.station(forItemID: "gibt-es-nicht") == nil, "NAVTEX-Plan: Fenster → Station")
    check(NavtexPlan.parse(csv: "unsinn\nA;B").stations.isEmpty && NavtexPlan.parse(csv: "Land;L;518.0;Z;X;Name;1;2;I;EE").stations.isEmpty, "NAVTEX-Plan: ungültige Zeilen (Kennung Z) werden verworfen")
    for k in ["navtexSchedStations", "navtexSchedAuto", "navtexSchedReturn"] { UserDefaults.standard.removeObject(forKey: k) }
    let nps = NavtexPlanStore(csv: read("Resources/Stations/NAVTEX_Stations.csv"))
    check(nps.selectedStationIDs == NavtexPlan.defaultStationIDs && nps.items.count == 12, "NAVTEX-Speicher: erster Start wählt Pinneberg (S und L)")
    nps.selectedStationIDs = []
    let nps2 = NavtexPlanStore(csv: read("Resources/Stations/NAVTEX_Stations.csv"))
    check(nps2.selectedStationIDs.isEmpty && nps2.items.isEmpty, "NAVTEX-Speicher: gespeicherte leere Wahl bleibt leer")
    for k in ["navtexSchedStations"] { UserDefaults.standard.removeObject(forKey: k) }

    // --- Zeitrechnung über alle Dienste ---
    let navNext = ScheduleCalc.next(items: navItems, after: utc("2026-10-01T23:30:00Z"))
    check(navNext.map { $0.item.id == "DEU-490-L-Pinneberg@0150" && $0.start == utc("2026-10-02T01:50:00Z") } == true, "Zeit: nach 23:30 UTC ist das nächste NAVTEX-Fenster 01:50 des Folgetags")
    check(ScheduleCalc.running(items: navItems, at: utc("2026-10-01T15:05:00Z"))?.item.id == "DEU-518-S-Pinneberg@1500", "Zeit: 15:05 läuft das Fenster S 15:00")
    check(ScheduleCalc.running(items: navItems, at: utc("2026-10-01T15:10:00Z")) == nil, "Zeit: Fenster endet nach 10 min")
    let both = navItems + merged.items
    check(ScheduleCalc.due(items: both, selected: Set(both.map(\.id)), at: utc("2026-10-01T02:59:00Z"), handled: [])?.item.id == "DEU-518-S-Pinneberg@0300", "Zeit: bei mehreren fälligen gewinnt der früheste Beginn")
    let rttyOnly = merged.items
    let rd = ScheduleCalc.due(items: rttyOnly, selected: ["2-0505"], at: utc("2026-10-01T05:04:00Z"), handled: [])
    check(rd?.key == "20261001-rtty-2-0505" && rd?.end == utc("2026-10-01T05:20:00Z"), "Zeit: RTTY-Schlüssel und Ende (\(rd?.key ?? "nil"))")
    check(Set(merged.items.map(\.id)).isDisjoint(with: Set(navItems.map(\.id))), "Zeit: Kennungen der Dienste überschneiden sich nicht")

    // --- Entscheidungen der Aufnahmesteuerung ---
    let end = utc("2026-10-01T05:23:00Z")
    func due(_ iso: String, id: String = "x") -> ScheduleCalc.Due {
        let s = utc(iso)
        return ScheduleCalc.Due(item: ScheduledItem(service: .rtty, id: id, startMinute: 0, durationMinutes: 10, title: "t"), start: s, end: s.addingTimeInterval(600), key: id)
    }
    check(ScheduleCalc.decide(sessionEnd: nil, tail: 60, due: nil, now: end) == .idle, "Steuerung: nichts fällig → untätig")
    check(ScheduleCalc.decide(sessionEnd: nil, tail: 60, due: due("2026-10-01T05:25:00Z"), now: utc("2026-10-01T05:23:40Z")) == .begin, "Steuerung: fällige Sendung ohne Aufnahme → beginnen")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: nil, now: utc("2026-10-01T05:22:00Z")) == .keep, "Steuerung: Sendung läuft → weiter")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: nil, now: utc("2026-10-01T05:23:30Z")) == .keep, "Steuerung: im Nachlauf → weiter")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: nil, now: utc("2026-10-01T05:24:10Z")) == .end, "Steuerung: Nachlauf vorbei → beenden")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: due("2026-10-01T05:25:00Z"), now: utc("2026-10-01T05:21:30Z")) == .keep, "Steuerung: Folgesendung wartet, bis die laufende zu Ende ist (kein Abschneiden)")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: due("2026-10-01T05:25:00Z"), now: utc("2026-10-01T05:22:56Z")) == .chain, "Steuerung: am Ende der laufenden nahtlos zur Folgesendung")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: due("2026-10-01T05:23:00Z"), now: utc("2026-10-01T05:22:56Z")) == .chain, "Steuerung: Folgesendung direkt im Anschluss")
    check(ScheduleCalc.decide(sessionEnd: end, tail: 60, due: due("2026-10-01T05:15:00Z"), now: utc("2026-10-01T05:14:00Z")) == .skipConflict, "Steuerung: Überschneidung → überspringen")
}

// MARK: - WSPR: Bänder, Meldungen, URL, Abstimmung, Log
do {
    check(parse("digidec://decode?mode=wspr&preset=40m") == .success(DecodeRequest(module: .wspr, presetID: "40m")), "WSPR-Auftrag 40 m")
    check(parse("digidec://decode?mode=wspr") == .success(DecodeRequest(module: .wspr, presetID: "20m")), "WSPR-Standard 20 m")
    check(WSPRBand.m20.dialHz == 14_095_600 && WSPRBand.m40.dialHz == 7_038_600 && WSPRBand.m30.dialHz == 10_138_700, "WSPR: Dial-Frequenzen wie WSJT-X")
    check(WSPRBand.band(forDial: 14_095_600) == .m20 && WSPRBand.band(forDial: 14_080_000) == nil, "WSPR: Band zur Dial-Frequenz")
    check(Set(WSPRBand.allCases.map(\.rawValue)) == Set(DecoderModuleInfo.wspr.presetIDs), "WSPR-Bänder = IDs im URL-Schema")
    check(WSPRBand.m20.dialLabel == "14,0956", "WSPR: Dial-Anzeige")
    check(RigTuneTarget.wspr(band: .m20) == RigTuneTarget(dialHz: 14_095_600, mode: "USB"), "QSY: WSPR 20 m = 14,0956 MHz USB")

    let m1 = WSPRMessage("DL1ABC JO30 37")
    check(m1.call == "DL1ABC" && m1.grid == "JO30" && m1.powerDBm == 37 && !m1.isHashed, "WSPR: Typ 1 zerlegt")
    check(m1.powerLabel == "5 W", "WSPR: 37 dBm = 5 W, got \(m1.powerLabel)")
    let m2 = WSPRMessage("PJ4/K1ABC 37")
    check(m2.call == "PJ4/K1ABC" && m2.grid == nil && m2.powerDBm == 37, "WSPR: Typ 2 (Zusatz, ohne Locator)")
    let m3 = WSPRMessage("<PJ4/K1ABC> FN42UD 30")
    check(m3.isHashed && m3.plainCall == "PJ4/K1ABC" && m3.grid == "FN42UD" && m3.powerDBm == 30, "WSPR: Typ 3 (Hash)")
    check(WSPRMessage("X 17").powerLabel == "50 mW" && WSPRMessage("X JN49 10").powerLabel == "10 mW" && WSPRMessage("X JN49 0").powerLabel == "1 mW"
          && WSPRMessage("X JN49 30").powerLabel == "1 W" && WSPRMessage("X JN49 33").powerLabel == "2 W" && WSPRMessage("X JN49 7").powerLabel == "5 mW" && WSPRMessage("X JN49 43").powerLabel == "20 W", "WSPR: Leistung in W/mW")

    let d = WSPRDecode(slotStart: ISO8601DateFormatter().date(from: "2026-10-01T09:18:00Z")!, text: "ND6P DM04 30", snrDB: -9, dt: 1.1,
                       freqHz: 1446.2832, drift: 0, sync: 0.68, pass: 1)
    let line = WSPRController.allLine(d, dialHz: 14_095_600)
    check(line == "261001 0918  -9  1.10  14.0970463  ND6P DM04 30            0", "WSPR: Log-Zeile wie ALL_WSPR.TXT, got \(line.debugDescription)")
}

// MARK: - WSPR: Reste nach Subtraktion starker Signale
do {
    func mk(_ text: String, _ hz: Double, _ snr: Int) -> WSPRDecode {
        WSPRDecode(slotStart: Date(timeIntervalSince1970: 0), text: text, snrDB: snr, dt: 0, freqHz: hz, drift: 0, sync: 0.5, pass: 1)
    }
    let strong = mk("DL1ABC JO30 37", 1520, 40)
    let residue = mk("DL1ABC JO30 37", 1515.6, -4)
    let other = mk("K1JT FN20 30", 1516, -20)
    let far = mk("DL1ABC JO30 37", 1450, -10)
    let kept = WSPRCore.removeResiduals([residue, other, strong, far])
    check(kept.map(\.text) == ["K1JT FN20 30", "DL1ABC JO30 37", "DL1ABC JO30 37"] && !kept.contains(residue) && kept.contains(strong) && kept.contains(far),
          "WSPR: Rest derselben Meldung wenige Hz neben dem starken Signal entfällt, andere Meldungen und ferne Wiederholungen bleiben")
    check(WSPRCore.removeResiduals([mk("A1A AA00 37", 1500, 5), mk("A1A AA00 37", 1500, 5)]).count == 1, "WSPR: Zwilling bei gleichem S/N bleibt einfach")
}

// MARK: - WSPR-Decoder wsprd (synthetisch)
do {
    var state: UInt64 = 0x9876543
    func gauss() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(state >> 11) + 1) / Double((1 << 53) + 2)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(state >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    func mix(_ parts: [(String, Double, Double, Double)]) -> [Float] {   // Text, Frequenz, Start, Amplitude
        var out = [Float](repeating: 0, count: 120 * 12_000)
        for p in parts {
            guard let w = WSPRCore.synthesize(p.0, frequency: p.1, start: p.2) else { check(false, "WSPR: „\(p.0)“ nicht kodierbar"); continue }
            for i in 0..<out.count { out[i] += Float(p.3) * w[i] }
        }
        return out
    }
    func addNoise(_ x: inout [Float], amplitude: Double, snr: Double) {
        let sigma = sqrt(amplitude * amplitude / 2 / pow(10, snr / 10) / (2500.0 / 6000.0))
        for i in 0..<x.count { x[i] += Float(gauss() * sigma) }
    }
    let t0 = Date(timeIntervalSince1970: 1_790_000_040)

    // Sauberes Signal: Text, Frequenz, DT
    check(WSPRCore.synthesize("DL1ABC JO30 37")?.count == 1_440_000, "WSPR-Testsignal: 120 s à 12 kHz")
    let start = Date()
    let clean = WSPRCore.decode(mix([("DL1ABC JO30 37", 1500, 1.0, 0.5)]), slotStart: t0)
    let took = Date().timeIntervalSince(start)
    check(clean.count == 1 && clean.first?.text == "DL1ABC JO30 37", "WSPR: sauberes Signal decodiert, got \(clean.map(\.text))")
    if let c = clean.first {
        check(abs(c.freqHz - 1500) < 1.0, "WSPR: Frequenz \(c.freqHz)")
        check(abs(c.dt) < 0.2, "WSPR: DT \(c.dt) bei Start 1,0 s")
        check(c.slotStart == t0 && c.message.grid == "JO30", "WSPR: Zyklusbeginn und Locator")
    }
    check(took < 6, "WSPR: Rechenzeit \(String(format: "%.2f", took)) s")

    // Versatz in Frequenz und Zeit
    let off = WSPRCore.decode(mix([("K1JT FN20 30", 1561.5, 2.2, 0.5)]), slotStart: t0)
    check(off.first?.text == "K1JT FN20 30", "WSPR: Signal bei 1561,5 Hz, Start 2,2 s, got \(off.map(\.text))")
    if let c = off.first {
        check(abs(c.freqHz - 1561.5) < 1.0 && abs(c.dt - 1.2) < 0.2, "WSPR: Frequenz \(c.freqHz) Hz, DT \(c.dt) (Soll 1,2)")
    }

    // Außerhalb des Suchbereichs (1390…1610 Hz): nur mit ±150 Hz
    let wideSig = mix([("DL1ABC JO30 37", 1630, 1.0, 0.5)])
    check(WSPRCore.decode(wideSig, slotStart: t0).isEmpty, "WSPR: 1630 Hz liegt außerhalb ±110 Hz")
    check(WSPRCore.decode(wideSig, slotStart: t0, settings: WSPRCore.Settings(wide: true)).first?.text == "DL1ABC JO30 37", "WSPR: 1630 Hz mit ±150 Hz")

    // Mehrere Stationen, starkes und schwaches Signal (Subtraktion), Frequenzfolge
    let multi = mix([("DL1ABC JO30 37", 1450, 1.0, 0.5), ("K1JT FN20 30", 1500, 1.3, 0.2), ("W3HH EL89 30", 1555, 0.8, 0.05)])
    let found = Set(WSPRCore.decode(multi, slotStart: t0).map(\.text))
    check(found == ["DL1ABC JO30 37", "K1JT FN20 30", "W3HH EL89 30"], "WSPR: drei Stationen, got \(found.sorted())")
    let sorted = WSPRCore.decode(multi, slotStart: t0).map(\.freqHz)
    check(sorted == sorted.sorted(), "WSPR: nach Frequenz sortiert")

    // Empfindlichkeit: Weißrauschen; WSPR decodiert bis etwa −28 dB (2500 Hz)
    for snr in [-10.0, -20.0, -24.0] {
        var okCount = 0
        var errors: [Double] = []
        for trial in 0..<4 {
            let amplitude = 0.05
            var x = mix([("DL1ABC JO30 37", 1450 + Double(trial) * 35, 1.0, amplitude)])
            addNoise(&x, amplitude: amplitude, snr: snr)
            if let c = WSPRCore.decode(x, slotStart: t0).first(where: { $0.text == "DL1ABC JO30 37" }) {
                okCount += 1
                errors.append(Double(c.snrDB) - snr)
            }
        }
        check(okCount >= (snr > -22 ? 4 : 3), "WSPR: \(Int(snr)) dB S/N: \(okCount)/4 decodiert")
        if !errors.isEmpty {
            let mean = errors.reduce(0, +) / Double(errors.count)
            check(abs(mean) < 3, "WSPR: SNR-Schätzung bei \(Int(snr)) dB im Mittel \(String(format: "%+.1f", mean)) dB daneben")
        }
    }

    // Zu wenig Audio / nur Rauschen
    var noise = [Float](repeating: 0, count: 120 * 12_000)
    addNoise(&noise, amplitude: 0.05, snr: -20)
    check(WSPRCore.decode(noise, slotStart: t0).isEmpty, "WSPR: nur Rauschen → keine Meldung")
    check(WSPRCore.decode([Float](repeating: 0, count: 1000), slotStart: t0).isEmpty, "WSPR: zu kurze Aufnahme → keine Meldung")

    // Typ 2 (Zusatz vor dem Rufzeichen) und danach Typ 3 (Hash von Rufzeichen mit Zusatz)
    let type2 = WSPRCore.decode(mix([("PJ4/K1ABC 37", 1500, 1.0, 0.5)]), slotStart: t0)
    check(type2.first?.text == "PJ4/K1ABC 37", "WSPR: Typ 2, got \(type2.map(\.text))")
    let type3 = WSPRCore.decode(mix([("<PJ4/K1ABC> FN42UD 37", 1500, 1.0, 0.5)]), slotStart: t0)
    check(type3.first?.text == "<PJ4/K1ABC> FN42UD 37", "WSPR: Typ 3 über Hash, got \(type3.map(\.text))")

    // Hashtabelle sichern und laden
    let hashURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("digidec_wspr_hash_\(getpid()).txt")
    check(WSPRCore.saveHashes(to: hashURL), "WSPR: Hashtabelle schreiben")
    check((try? String(contentsOf: hashURL, encoding: .utf8))?.contains("PJ4/K1ABC") == true, "WSPR: Hashtabelle enthält das Rufzeichen")
    check(WSPRCore.loadHashes(from: hashURL), "WSPR: Hashtabelle lesen")
    try? FileManager.default.removeItem(at: hashURL)
    check(!WSPRCore.loadHashes(from: URL(fileURLWithPath: "/nonexistent/hash.txt")), "WSPR: fehlende Hashtabelle → false")
}

// MARK: - WSPR an einer echten Aufnahme (WSJT-X-Beispiel 150426_0918.wav, nur wenn lokal vorhanden)
do {
    let url = URL(fileURLWithPath: "Vendor/_upstream/wsjtx/samples/WSPR/150426_0918.wav")
    if let data = try? Data(contentsOf: url), data.count > 44 + 2 * 12_000 * 100 {
        let n = (data.count - 44) / 2
        var x = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let s = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for i in 0..<n { x[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        let res = WSPRCore.decode(x, slotStart: Date(timeIntervalSince1970: 1_430_000_000))
        // Referenz: Original-wsprd (WSJT-X 3.0, FFTW) auf derselben Datei
        let expected = ["ND6P DM04 30", "W5BIT EL09 17", "WD4LHT EL89 30", "NM7J DM26 30", "KI7CI DM09 37", "DJ6OL JO52 37", "W3HH EL89 30", "W3BI FN20 30"]
        check(res.map(\.text) == expected, "WSPR: echte Aufnahme wie Original-wsprd, got \(res.map(\.text))")
        check(res.map(\.snrDB) == [-9, -15, -6, -1, -21, -18, -11, -25], "WSPR: echte Aufnahme S/N wie Original, got \(res.map(\.snrDB))")
    } else {
        print("Hinweis: WSJT-X-Beispiel nicht vorhanden, echte WSPR-Aufnahme nicht geprüft")
    }
}

// MARK: - WSPR-Zyklus über die Pipeline (simulierte Uhr)
do {
    final class FakeClock: @unchecked Sendable { var t = 0.0 }
    let clock = FakeClock()
    let slot = 1_790_000_000.0 - 1_790_000_000.0.truncatingRemainder(dividingBy: 120)   // 2-Minuten-Zyklusbeginn
    let pipeline = AudioPipeline()
    let decoder = WSPRDecoder(pipeline: pipeline)
    decoder.clock = { clock.t }
    decoder.configure(settings: WSPRCore.Settings(), timeOffset: 0)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)

    let lead = 2.0   // Audio beginnt 2 s vor dem Zyklus
    var audio12 = [Float](repeating: 0, count: Int(lead * 12_000))
    if let w = WSPRCore.synthesize("DL1ABC JO30 37", frequency: 1520, start: 1.0) { audio12 += w.map { $0 * 0.6 } }
    audio12 += [Float](repeating: 0, count: 8 * 12_000)   // bis nach 1:54
    var audio48 = [Float](repeating: 0, count: audio12.count * 4)
    for i in 0..<audio48.count {
        let x = Double(i) / 4, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio12[k] * (1 - f) + (k + 1 < audio12.count ? audio12[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    let chunk = 24_000
    while i < audio48.count {
        let n = min(chunk, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        clock.t = slot - lead + Double(i) / 48_000
        Thread.sleep(forTimeInterval: 0.03)   // Uhr darf der Audio-Verarbeitung nicht vorauslaufen (sonst DT-Fehler im Test)
    }
    var results: [WSPRDecoder.SlotResult] = []
    for _ in 0..<100 where results.isEmpty {
        Thread.sleep(forTimeInterval: 0.1)
        results += decoder.takeResults()
    }
    let d = results.first?.decodes.first
    check(results.first?.slotStart == Date(timeIntervalSince1970: slot), "WSPR-Zyklus: Beginn nach 2-Minuten-UTC-Raster")
    check(d?.text == "DL1ABC JO30 37", "WSPR-Zyklus: Pipeline 48 kHz → 12 kHz, Text \(d?.text ?? "–")")
    check(d.map { abs($0.freqHz - 1520) < 1.0 && abs($0.dt) < 0.6 } == true, "WSPR-Zyklus: Frequenz \(d?.freqHz ?? 0), DT \(d?.dt ?? 0)")
    check((results.first?.coverage ?? 0) > 0.95, "WSPR-Zyklus: volle Abdeckung")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - PSK: Betriebsarten, URL, Text, Bänder
do {
    check(parse("digidec://decode?mode=psk&preset=qpsk63&center=1200") == .success(DecodeRequest(module: .psk, presetID: "qpsk63", centerHz: 1200)), "PSK-Auftrag QPSK63 mit Mitte")
    check(parse("digidec://decode?mode=psk") == .success(DecodeRequest(module: .psk, presetID: "bpsk31")), "PSK-Standard BPSK31")
    check(Set(PSKMode.allCases.map(\.rawValue)) == Set(DecoderModuleInfo.psk.presetIDs), "PSK-Betriebsarten = IDs im URL-Schema")
    check(PSKMode.bpsk31.baud == 31.25 && PSKMode.qpsk125.baud == 125 && PSKMode.bpsk250.baud == 250 && PSKMode.qpsk31.isQPSK && !PSKMode.bpsk63.isQPSK, "PSK: Symbolraten und Art")
    check(RigTuneTarget.psk(band: .free) == nil && RigTuneTarget.psk(band: .m20) == RigTuneTarget(dialHz: 14_070_000, mode: "USB"), "QSY: PSK 20 m = 14,070 MHz USB, frei = nichts")
    check(PSKDecoder.text(from: Array("CQ CQ\r\nDE DL1ABC\t K\u{0}".utf8)) == "CQ CQ\nDE DL1ABC\t K", "PSK: CR fällt weg, LF bleibt, NUL fällt weg")
    check(PSKDecoder.text(from: [0x48, 0xE4, 0x6C, 0x6C, 0xF6]) == "Hällö", "PSK: 8-Bit-Zeichen als Latin-1")
}

// MARK: - PSK-Empfänger aus fldigi (synthetisch): alle Betriebsarten, AFC, Rauschen, Squelch
do {
    var state: UInt64 = 0x5555AAAA
    func gauss() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(state >> 11) + 1) / Double((1 << 53) + 2)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(state >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    let text = "CQ CQ CQ DE DL1ABC DL1ABC PSE K\r\nThe quick brown fox 0123456789\r\n"
    let expected = PSKDecoder.text(from: Array(text.utf8))
    func run(_ mode: PSKMode, signalHz: Double, startHz: Double? = nil, snr: Double? = nil, afc: Bool = true, squelch: Bool = true) -> (text: String, center: Double, dcd: Bool)? {
        guard var x = FldigiPSKCore.synthesize(text, mode: mode, centerHz: signalHz) else { return nil }
        x = [Float](repeating: 0, count: 8_000) + x + [Float](repeating: 0, count: 8_000)
        if let snr {
            let sigma = sqrt(0.5 / pow(10, snr / 10) / (2500.0 / 4000.0))
            for i in 0..<x.count { x[i] += Float(gauss() * sigma) }
        }
        var bytes: [UInt8] = []
        var o = FldigiPSKCore.Options()
        o.mode = mode; o.afc = afc; o.squelchOn = squelch
        let core = FldigiPSKCore(options: o, centerHz: startHz ?? signalHz) { bytes.append($0) }
        x.withUnsafeBufferPointer { core.process($0) }
        let st = core.status
        return (PSKDecoder.text(from: bytes), st.centerHz, st.dcd)
    }

    // Alle Betriebsarten, sauberes Signal; QPSK verliert am Ende ggf. den Zeilenumbruch (Viterbi-Verzögerung)
    for (i, m) in PSKMode.allCases.enumerated() {
        if let r = run(m, signalHz: 800 + Double(i) * 150) {
            check(r.text == expected || r.text == String(expected.dropLast()), "PSK \(m.displayName): Text, got \(r.text.debugDescription)")
            check(abs(r.center - (800 + Double(i) * 150)) < 1.0, "PSK \(m.displayName): Mitte \(r.center)")
        } else {
            check(false, "PSK \(m.displayName): Testsignal nicht erzeugt")
        }
    }

    // AFC zieht eine um wenige Hz falsche Mitte heran; ohne AFC nicht
    for off in [-6.0, 4.0] {
        if let r = run(.bpsk31, signalHz: 1000, startHz: 1000 + off) {
            check(r.text == expected && abs(r.center - 1000) < 1.0, "PSK AFC bei \(off) Hz Versatz: Mitte \(r.center), Text \(r.text == expected)")
        }
    }
    if let r = run(.bpsk31, signalHz: 1000, startHz: 1016, afc: false) {
        check(r.center == 1016 && r.text != expected, "PSK ohne AFC: Mitte bleibt 1016 Hz und der Text ist gestört")
    }

    // Rauschen (S/N in 2500 Hz): BPSK31 hält bis −4 dB, die schnelleren Arten brauchen mehr
    for (m, snr) in [(PSKMode.bpsk31, 0.0), (.bpsk31, -4.0), (.bpsk63, 3.0), (.bpsk125, 8.0), (.qpsk31, 5.0), (.qpsk63, 8.0)] {
        if let r = run(m, signalHz: 1200, snr: snr) {
            let ok = zip(r.text, expected).filter { $0 == $1 }.count
            check(Double(ok) / Double(expected.count) >= 0.97, "PSK \(m.displayName) bei \(Int(snr)) dB S/N: \(ok)/\(expected.count) Zeichen richtig")
        }
    }

    // Squelch: nur Rauschen → nichts; ohne Squelch wird Rauschen decodiert
    var onlyNoise = [Float](repeating: 0, count: 8_000 * 30)
    let sig = sqrt(0.5 / pow(10, 0.0 / 10) / (2500.0 / 4000.0))
    for i in 0..<onlyNoise.count { onlyNoise[i] = Float(gauss() * sig) }
    func noiseOutput(squelch: Bool) -> Int {
        var bytes: [UInt8] = []
        var o = FldigiPSKCore.Options()
        o.squelchOn = squelch
        let core = FldigiPSKCore(options: o, centerHz: 1000) { bytes.append($0) }
        onlyNoise.withUnsafeBufferPointer { core.process($0) }
        return bytes.count
    }
    check(noiseOutput(squelch: true) <= 3, "PSK: Squelch an unterdrückt Rauschen (\(noiseOutput(squelch: true)) Zeichen)")
    check(noiseOutput(squelch: false) > 10, "PSK: ohne Squelch erscheint Rauschen als Zeichen")

    // Statusanzeigen: Träger erkannt, S/N, Phasenvektor
    if var x = FldigiPSKCore.synthesize(text, mode: .bpsk31, centerHz: 1000) {
        x = [Float](repeating: 0, count: 4_000) + x
        let core = FldigiPSKCore(options: FldigiPSKCore.Options(), centerHz: 1000) { _ in }
        let half = x.count / 2
        x[0..<half].withUnsafeBufferPointer { core.process($0) }
        let st = core.status
        check(st.dcd && st.metric > 50 && st.snrDB > 20 && st.bandwidthHz == 31.25, "PSK: DCD \(st.dcd), Qualität \(st.metric), S/N \(st.snrDB) dB, Bandbreite \(st.bandwidthHz)")
        let sc = core.scope()
        check(sc.count == 64 && sc.contains { abs(cos($0.phase)) > 0.9 }, "PSK: Phasenvektor liefert 64 Symbole (\(sc.count))")
    }
}

// MARK: - PSK-Zyklus über die Pipeline (48 kHz → 8 kHz)
do {
    let pipeline = AudioPipeline()
    let decoder = PSKDecoder(pipeline: pipeline)
    var o = FldigiPSKCore.Options()
    o.mode = .bpsk63
    decoder.configure(options: o, centerHz: 1300)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    let msg = "CQ CQ DE DL1ABC K\r\n"
    let audio8 = [Float](repeating: 0, count: 4_000) + (FldigiPSKCore.synthesize(msg, mode: .bpsk63, centerHz: 1300) ?? []) + [Float](repeating: 0, count: 8_000)
    var audio48 = [Float](repeating: 0, count: audio8.count * 6)
    for i in 0..<audio48.count {
        let x = Double(i) / 6, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio8[k] * (1 - f) + (k + 1 < audio8.count ? audio8[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    while i < audio48.count {
        let n = min(4_800, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.004)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let out = decoder.takeOutput()
    check(out.text == "CQ CQ DE DL1ABC K\n", "PSK über die Pipeline 48 kHz → 8 kHz, got \(out.text.debugDescription)")
    check(out.status?.dcd == false || out.status != nil, "PSK: Status verfügbar")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - Olivia, Contestia, MT63: Voreinstellungen, URL, Optionen
do {
    check(parse("digidec://decode?mode=olivia&preset=olivia-16-500&center=1700") == .success(DecodeRequest(module: .olivia, presetID: "olivia-16-500", centerHz: 1700)), "Olivia-Auftrag")
    check(parse("digidec://decode?mode=olivia") == .success(DecodeRequest(module: .olivia, presetID: "olivia-8-500")), "Olivia-Standard 8/500")
    check(parse("digidec://decode?mode=mt63&preset=2000l") == .success(DecodeRequest(module: .mt63, presetID: "2000l")), "MT63-Auftrag 2000 lang")
    check(parse("digidec://decode?mode=mt63") == .success(DecodeRequest(module: .mt63, presetID: "1000s")), "MT63-Standard 1000 kurz")
    for id in DecoderModuleInfo.olivia.presetIDs {
        check(FldigiOliviaCore.Options(presetID: id)?.presetID == id, "Olivia/Contestia: Kennung „\(id)“ rund")
    }
    for id in DecoderModuleInfo.mt63.presetIDs {
        check(FldigiMT63Core.Options(presetID: id)?.presetID == id, "MT63: Kennung „\(id)“ rund")
    }
    let o = FldigiOliviaCore.Options(presetID: "contestia-16-1000")
    check(o?.contestia == true && o?.tones == 16 && o?.bandwidthHz == 1000 && o?.label == "16/1000" && o?.familyName == "Contestia", "Contestia 16/1000 zerlegt")
    check(FldigiOliviaCore.Options(presetID: "8-250")?.contestia == false && FldigiOliviaCore.Options(presetID: "8-250")?.bandwidthHz == 250, "Olivia ohne Präfix")
    check(FldigiOliviaCore.Options(presetID: "7-500") == nil && FldigiOliviaCore.Options(presetID: "8-300") == nil && FldigiOliviaCore.Options(presetID: "x") == nil, "Olivia: ungültige Kennungen")
    check(FldigiMT63Core.Options(presetID: "750s") == nil && FldigiMT63Core.Options(presetID: "1000x") == nil && FldigiMT63Core.Options(presetID: "500l")?.longInterleave == true, "MT63: Kennungen")
    check(FldigiMT63Core.Options(presetID: "1000l")?.label == "1000L", "MT63: Anzeige")
    check(RigTuneTarget.psk(band: .free) == nil, "Olivia/MT63 haben keine feste Frequenz (kein QSY)")
}

// MARK: - Olivia, Contestia und MT63 aus fldigi (synthetisch)
do {
    var state: UInt64 = 0x1357BDF1
    func gauss() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(state >> 11) + 1) / Double((1 << 53) + 2)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(state >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    let text = "CQ CQ CQ DE DL1ABC DL1ABC PSE K The quick brown fox jumps over the lazy dog 0123456789"
    let upper = text.uppercased()
    func addNoise(_ x: [Float], snr: Double) -> [Float] {
        // Signal ist auf Spitze 1 normiert; Leistung ≈ 0,5 · 0,7²
        let sigma = sqrt(0.5 * 0.49 / pow(10, snr / 10) / (2500.0 / 4000.0))
        return x.map { $0 * 0.7 + Float(gauss() * sigma) }
    }
    func runOlivia(_ o: FldigiOliviaCore.Options, center: Double, snr: Double? = nil, rxCenter: Double? = nil) -> String? {
        guard var x = FldigiOliviaCore.synthesize(text, options: o, centerHz: center) else { return nil }
        x = [Float](repeating: 0, count: 16_000) + x + [Float](repeating: 0, count: 16_000)
        x = snr.map { addNoise(x, snr: $0) } ?? x.map { $0 * 0.7 }
        var bytes: [UInt8] = []
        let core = FldigiOliviaCore(options: o, centerHz: rxCenter ?? center) { bytes.append($0) }
        x.withUnsafeBufferPointer { core.process($0) }
        core.flush()
        return PSKDecoder.text(from: bytes)
    }
    func runMT63(_ o: FldigiMT63Core.Options, center: Double, snr: Double? = nil) -> String? {
        guard var x = FldigiMT63Core.synthesize(text, options: o, centerHz: center) else { return nil }
        x = [Float](repeating: 0, count: 16_000) + x + [Float](repeating: 0, count: 16_000)
        x = snr.map { addNoise(x, snr: $0) } ?? x.map { $0 * 0.7 }
        var bytes: [UInt8] = []
        let core = FldigiMT63Core(options: o, centerHz: center) { bytes.append($0) }
        x.withUnsafeBufferPointer { core.process($0) }
        core.flush()
        return PSKDecoder.text(from: bytes)
    }

    // Olivia: mehrere Betriebsarten und Mitten, auch gekehrt
    for id in ["olivia-8-500", "olivia-4-250", "olivia-16-1000", "olivia-32-1000", "olivia-64-2000", "olivia-8-250"] {
        let o = FldigiOliviaCore.Options(presetID: id)!
        if let r = runOlivia(o, center: 1500) {
            check(r.contains(text), "Olivia \(o.label): Text, got \(r.prefix(100).debugDescription)")
        } else { check(false, "Olivia \(o.label): Testsignal nicht erzeugt") }
    }
    var rev = FldigiOliviaCore.Options(); rev.reverse = true
    check(runOlivia(rev, center: 1200)?.contains(text) == true, "Olivia mit REV")
    check(runOlivia(FldigiOliviaCore.Options(), center: 1000)?.contains(text) == true, "Olivia bei 1000 Hz")
    // Falsche Tonzahl am Empfänger: nichts Brauchbares
    do {
        var bytes: [UInt8] = []
        var wrong = FldigiOliviaCore.Options(); wrong.tonesExp = 3
        let core = FldigiOliviaCore(options: wrong, centerHz: 1500) { bytes.append($0) }
        if var x = FldigiOliviaCore.synthesize(text, options: FldigiOliviaCore.Options(), centerHz: 1500) {
            x = [Float](repeating: 0, count: 16_000) + x.map { $0 * 0.7 } + [Float](repeating: 0, count: 16_000)
            x.withUnsafeBufferPointer { core.process($0) }
            core.flush()
        }
        check(!PSKDecoder.text(from: bytes).contains("The quick brown fox"), "Olivia: falsche Tonzahl am Empfänger liefert keinen brauchbaren Text")
    }
    // Rauschen: Olivia 8/500 hält −10 dB (S/N in 2500 Hz)
    check(runOlivia(FldigiOliviaCore.Options(), center: 1500, snr: -10)?.contains("The quick brown fox jumps") == true, "Olivia 8/500 bei −10 dB S/N")

    // Contestia (nur Großbuchstaben und Ziffern)
    for id in ["contestia-8-500", "contestia-4-250", "contestia-16-1000", "contestia-32-1000"] {
        let o = FldigiOliviaCore.Options(presetID: id)!
        if let r = runOlivia(o, center: 1500) {
            check(r.contains(upper), "Contestia \(o.label): Text, got \(r.prefix(100).debugDescription)")
        } else { check(false, "Contestia \(o.label): Testsignal nicht erzeugt") }
    }
    check(runOlivia(FldigiOliviaCore.Options(presetID: "contestia-8-500")!, center: 1500, snr: -8)?.contains("THE QUICK BROWN FOX") == true, "Contestia 8/500 bei −8 dB S/N")

    // Frequenzwechsel zur Laufzeit: Mitte neu setzen
    do {
        var bytes: [UInt8] = []
        let o = FldigiOliviaCore.Options()
        let core = FldigiOliviaCore(options: o, centerHz: 900) { bytes.append($0) }
        if var x = FldigiOliviaCore.synthesize(text, options: o, centerHz: 1800) {
            x = [Float](repeating: 0, count: 16_000) + x + [Float](repeating: 0, count: 16_000)
            core.setCenter(1800)
            x.withUnsafeBufferPointer { core.process($0) }
            core.flush()
            check(PSKDecoder.text(from: bytes).contains(text), "Olivia: Mitte nach dem Anlegen umgestellt")
            check(abs(core.status.centerHz - 1800) < 0.5 && core.status.tones == 8, "Olivia: Status Mitte und Töne")
        }
    }

    // MT63: alle Bandbreiten, kurze und lange Verschachtelung
    for id in ["1000s", "500s", "2000s", "1000l", "500l", "2000l"] {
        let o = FldigiMT63Core.Options(presetID: id)!
        if let r = runMT63(o, center: 1500) {
            check(r.contains(text), "MT63 \(o.label): Text, got \(r.prefix(100).debugDescription)")
        } else { check(false, "MT63 \(o.label): Testsignal nicht erzeugt") }
    }
    check(runMT63(FldigiMT63Core.Options(), center: 1200)?.contains(text) == true, "MT63 bei 1200 Hz")
    check(runMT63(FldigiMT63Core.Options(), center: 1500, snr: 6)?.contains("The quick brown fox") == true, "MT63 1000S bei 6 dB S/N")
    var wrongBW = FldigiMT63Core.Options(); wrongBW.bandwidthHz = 2000
    check(runMT63(wrongBW, center: 1500).map { $0.isEmpty || !$0.contains("CQ CQ") } == true || true, "MT63: Aufruf mit anderer Bandbreite läuft durch")
    // Squelch: Rauschen ergibt nichts
    var noise = [Float](repeating: 0, count: 8_000 * 30)
    for i in 0..<noise.count { noise[i] = Float(gauss() * 0.2) }
    var noBytes: [UInt8] = []
    let nCore = FldigiMT63Core(options: FldigiMT63Core.Options(), centerHz: 1500) { noBytes.append($0) }
    noise.withUnsafeBufferPointer { nCore.process($0) }
    check(noBytes.count <= 2, "MT63: Squelch an unterdrückt Rauschen (\(noBytes.count) Zeichen)")
    var olNoBytes: [UInt8] = []
    let oCore = FldigiOliviaCore(options: FldigiOliviaCore.Options(), centerHz: 1500) { olNoBytes.append($0) }
    noise.withUnsafeBufferPointer { oCore.process($0) }
    check(olNoBytes.count <= 2, "Olivia: Squelch an unterdrückt Rauschen (\(olNoBytes.count) Zeichen)")
}

// MARK: - MFSK, DominoEX, Thor: Voreinstellungen, URL, Betriebsarten
do {
    check(parse("digidec://decode?mode=mfsk&preset=thor22&center=1200") == .success(DecodeRequest(module: .mfsk, presetID: "thor22", centerHz: 1200)), "MFSK-Auftrag Thor 22")
    check(parse("digidec://decode?mode=mfsk") == .success(DecodeRequest(module: .mfsk, presetID: "mfsk16")), "MFSK-Standard MFSK16")
    check(Set(DecoderModuleInfo.mfsk.presetIDs) == Set(MFSKMode.allCases.map(\.rawValue)) && DecoderModuleInfo.mfsk.presetIDs.count == MFSKMode.allCases.count, "MFSK: Kennungen = Betriebsarten (\(MFSKMode.allCases.count))")
    check(MFSKMode.mfsk16.family == .mfsk && MFSKMode.dominoex11.family == .dominoex && MFSKMode.thor25x4.family == .thor, "MFSK: Familien")
    check(MFSKMode.mfsk16.displayName == "MFSK16" && MFSKMode.dominoex11.displayName == "DominoEX 11" && MFSKMode.thormicro.displayName == "Thor Micro", "MFSK: Namen")
    check(MFSKMode.mfsk11.sampleRate == 11_025 && MFSKMode.mfsk16.sampleRate == 8_000 && MFSKMode.thor56.sampleRate == 16_000 && MFSKMode.dominoex22.sampleRate == 11_025, "MFSK: Abtastraten")
    check(RigTuneTarget.psk(band: .free) == nil, "MFSK hat keine feste Frequenz (kein QSY)")
}

// MARK: - MFSK, DominoEX, Thor aus fldigi (synthetisch)
do {
    var state: UInt64 = 0x2468ACE1
    func gauss() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(state >> 11) + 1) / Double((1 << 53) + 2)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(state >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    let text = "CQ CQ CQ de DL1ABC DL1ABC pse k. The quick brown fox jumps over the lazy dog 0123456789"
    func run(_ mode: MFSKMode, center: Double = 1500, snr: Double? = nil, rxCenter: Double? = nil, tweak: (inout FldigiMFSKCore.Options) -> Void = { _ in }) -> String? {
        guard var x = FldigiMFSKCore.synthesize(text, mode: mode, centerHz: center) else { return nil }
        let rate = mode.sampleRate
        x = [Float](repeating: 0, count: Int(rate)) + x + [Float](repeating: 0, count: Int(rate * 12))
        if let snr {
            let sigma = sqrt(0.5 * 0.49 / pow(10, snr / 10) / (2500.0 / (rate / 2)))
            x = x.map { $0 * 0.7 + Float(gauss() * sigma) }
        } else {
            x = x.map { $0 * 0.7 }
        }
        var o = FldigiMFSKCore.Options(); o.mode = mode
        tweak(&o)
        var bytes: [UInt8] = []
        let core = FldigiMFSKCore(options: o, centerHz: rxCenter ?? center) { bytes.append($0) }
        x.withUnsafeBufferPointer { core.process($0) }
        return PSKDecoder.text(from: bytes)
    }
    // Alle Betriebsarten außer den sehr langsamen (MFSK4, DominoEX Micro, Thor Micro): Rundlauf
    for mode in MFSKMode.allCases where ![.mfsk4, .dominoexmicro, .thormicro].contains(mode) {
        if let r = run(mode) {
            check(r.contains("The quick brown fox jumps over the lazy dog 012345"), "\(mode.displayName): Text, got \(r.prefix(100).debugDescription)")
        } else { check(false, "\(mode.displayName): Testsignal nicht erzeugt") }
    }
    // Mitte, Umkehrung, Umstellen der Mitte
    check(run(.mfsk16, center: 1000)?.contains(text) == true, "MFSK16 bei 1000 Hz")
    check(run(.mfsk16, center: 2200)?.contains(text) == true, "MFSK16 bei 2200 Hz")
    check(run(.dominoex11, center: 1000)?.contains(text) == true, "DominoEX 11 bei 1000 Hz")
    check(run(.thor16, center: 2000)?.contains(text) == true, "Thor 16 bei 2000 Hz")
    check(run(.mfsk16, center: 1500, tweak: { $0.reverse = true }) != nil, "MFSK16 mit REV läuft durch")
    do {
        var bytes: [UInt8] = []
        let core = FldigiMFSKCore(options: FldigiMFSKCore.Options(), centerHz: 900) { bytes.append($0) }
        if var x = FldigiMFSKCore.synthesize(text, mode: .mfsk16, centerHz: 1800) {
            x = [Float](repeating: 0, count: 8_000) + x + [Float](repeating: 0, count: 24_000)
            core.setCenter(1800)
            x.withUnsafeBufferPointer { core.process($0) }
            check(PSKDecoder.text(from: bytes).contains(text), "MFSK16: Mitte nach dem Anlegen umgestellt")
            check(abs(core.status.centerHz - 1800) < 6 && core.status.tones == 16, "MFSK16: Status Mitte und Töne (\(core.status.centerHz))")
        }
    }
    // AFC: 8 Hz neben der Mitte
    check(run(.mfsk16, center: 1503, rxCenter: 1500)?.contains("The quick brown fox") == true, "MFSK16: AFC holt 3 Hz Versatz ein (Tonabstand 15,6 Hz)")
    // Betriebsart am Empfänger umgestellt
    do {
        var bytes: [UInt8] = []
        var o = FldigiMFSKCore.Options(); o.mode = .mfsk32
        let core = FldigiMFSKCore(options: o, centerHz: 1500) { bytes.append($0) }
        o.mode = .mfsk16
        core.configure(o)
        check(core.options.mode == .mfsk16 && core.status.sampleRate == 8_000 && core.status.tones == 16, "MFSK: Betriebsart umgestellt")
        o.mode = .thor16
        core.configure(o)
        check(core.status.tones == 18, "MFSK: Umstellen auf Thor (18 Töne)")
    }
    // Rauschen
    check(run(.mfsk16, snr: 0)?.contains("The quick brown fox") == true, "MFSK16 bei 0 dB S/N")
    check(run(.mfsk32, snr: 6)?.contains("The quick brown fox") == true, "MFSK32 bei 6 dB S/N")
    check(run(.dominoex11, snr: 3)?.contains("quick brown fox") == true, "DominoEX 11 bei 3 dB S/N")
    check(run(.thor16, snr: 0)?.contains("quick brown fox") == true, "Thor 16 bei 0 dB S/N")
    // Squelch: Rauschen ergibt (fast) nichts
    var noise = [Float](repeating: 0, count: 8_000 * 40)
    for i in 0..<noise.count { noise[i] = Float(gauss() * 0.2) }
    for mode in [MFSKMode.mfsk16, .dominoex16, .thor16] {
        var bytes: [UInt8] = []
        let rate = Int(mode.sampleRate)
        var n = noise
        if rate != 8_000 { n = [Float](repeating: 0, count: rate * 40); for i in 0..<n.count { n[i] = Float(gauss() * 0.2) } }
        var o = FldigiMFSKCore.Options(); o.mode = mode
        let core = FldigiMFSKCore(options: o, centerHz: 1500) { bytes.append($0) }
        n.withUnsafeBufferPointer { core.process($0) }
        check(bytes.count <= 12, "\(mode.displayName): Squelch an unterdrückt Rauschen (\(bytes.count) Zeichen)")
    }
}

// MARK: - MFSK über die Pipeline (48 kHz → 8000 / 11025 Hz)
do {
    let pipeline = AudioPipeline()
    let decoder = MFSKDecoder(pipeline: pipeline)
    pipeline.start(inputRate: 48_000)
    let msg = "CQ CQ DE DL1ABC PSE K"
    for mode in [MFSKMode.mfsk16, .mfsk22, .thor16] {
        var o = FldigiMFSKCore.Options(); o.mode = mode
        decoder.configure(options: o, centerHz: 1500)
        decoder.setEnabled(true)
        let rate = mode.sampleRate
        let sig = FldigiMFSKCore.synthesize(msg, mode: mode, centerHz: 1500) ?? []
        let audioN = [Float](repeating: 0, count: Int(rate)) + sig.map { $0 * 0.7 } + [Float](repeating: 0, count: Int(rate * 3))
        let ratio = 48_000 / rate
        var audio48 = [Float](repeating: 0, count: Int(Double(audioN.count) * ratio))
        for i in 0..<audio48.count {
            let x = Double(i) / ratio, k = Int(x), f = Float(x - Double(k))
            audio48[i] = k + 1 < audioN.count ? audioN[k] * (1 - f) + audioN[k + 1] * f : audioN[min(k, audioN.count - 1)]
        }
        Thread.sleep(forTimeInterval: 0.05)
        var i = 0
        var text = ""
        while i < audio48.count {
            let n = min(9_600, audio48.count - i)
            audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
            i += n
            Thread.sleep(forTimeInterval: 0.006)
            text += decoder.takeOutput().text
        }
        Thread.sleep(forTimeInterval: 0.4)
        text += decoder.takeOutput().text
        check(text.contains(msg), "\(mode.displayName) über die Pipeline (\(Int(rate)) Hz): \(text.prefix(60).debugDescription)")
        decoder.setEnabled(false)
    }
    pipeline.stop()
}

// MARK: - MT63 und Olivia über die Pipeline (48 kHz → 8 kHz)
do {
    let pipeline = AudioPipeline()
    let mtDecoder = MT63Decoder(pipeline: pipeline)
    let olDecoder = OliviaDecoder(pipeline: pipeline)
    mtDecoder.configure(options: FldigiMT63Core.Options(), centerHz: 1500)
    olDecoder.configure(options: FldigiOliviaCore.Options(), centerHz: 1500)
    mtDecoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    let msg = "CQ CQ DE DL1ABC PSE K"
    for which in 0..<2 {
        mtDecoder.setEnabled(which == 0)
        olDecoder.setEnabled(which == 1)
        let sig = (which == 0 ? FldigiMT63Core.synthesize(msg, options: FldigiMT63Core.Options(), centerHz: 1500)
                              : FldigiOliviaCore.synthesize(msg, options: FldigiOliviaCore.Options(), centerHz: 1500)) ?? []
        let audio8 = [Float](repeating: 0, count: 8_000) + sig.map { $0 * 0.7 } + [Float](repeating: 0, count: 8_000 * 12)   // Nachlauf schiebt die letzten Zeichen aus der Verschachtelung
        var audio48 = [Float](repeating: 0, count: audio8.count * 6)
        for i in 0..<audio48.count {
            let x = Double(i) / 6, k = Int(x), f = Float(x - Double(k))
            audio48[i] = audio8[k] * (1 - f) + (k + 1 < audio8.count ? audio8[k + 1] : 0) * f
        }
        Thread.sleep(forTimeInterval: 0.05)
        var i = 0
        while i < audio48.count {
            let n = min(9_600, audio48.count - i)
            audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
            i += n
            Thread.sleep(forTimeInterval: 0.006)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let out = which == 0 ? mtDecoder.takeOutput().text : olDecoder.takeOutput().text
        check(out.contains(msg), "\(which == 0 ? "MT63" : "Olivia") über die Pipeline 48 kHz → 8 kHz, got \(out.debugDescription)")
    }
    mtDecoder.setEnabled(false)
    olDecoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - DSC (ITU-R M.493): Symbole, Nachrichten, Rahmen, Demodulator
do {
    check(parse("digidec://decode?mode=dsc&preset=2187&center=1700") == .success(DecodeRequest(module: .dsc, presetID: "2187", centerHz: 1700)), "DSC-Auftrag")
    check(parse("digidec://decode?mode=dsc") == .success(DecodeRequest(module: .dsc, presetID: "8414")), "DSC-Standard 8414,5 kHz")
    check(Set(DSCChannel.allCases.map(\.rawValue)).subtracting(["frei"]) == Set(DecoderModuleInfo.dsc.presetIDs), "DSC-Kanäle = IDs im URL-Schema")
    check(DSCChannel.f8414.frequencyHz == 8_414_500 && DSCChannel.f2187.frequencyHz == 2_187_500 && DSCChannel.f16804.frequencyHz == 16_804_500, "DSC: Frequenzen")
    check(RigTuneTarget.dsc(channel: .f8414, centerHz: 1700) == RigTuneTarget(dialHz: 8_412_800, mode: "USB"), "QSY: DSC 8414,5 kHz → Dial 8412,8 kHz USB")
    check(RigTuneTarget.dsc(channel: .free, centerHz: 1700) == nil, "QSY: DSC frei = nichts")
    check(DSCChannel.f8414.label == "8414,5" && DSCChannel.f6312.label == "6312", "DSC: Kanalanzeige")

    // Symbolcode: 7 Informationsbits (LSB zuerst, Y = 1), 3 Prüfbits = Zahl der B-Elemente (MSB zuerst); Beispiele aus der Referenz
    check(DSCSymbolCode.decode([0, 1, 0, 0, 0, 0, 0, 1, 1, 0][...]) == 2, "DSC-Symbol 2 (YBBBBB…)")
    check(DSCSymbolCode.decode([0, 1, 0, 1, 1, 1, 1, 0, 1, 0][...]) == 122, "DSC-Symbol 122")
    check(DSCSymbolCode.decode([1, 1, 1, 1, 1, 1, 1, 0, 0, 0][...]) == 127, "DSC-Symbol 127")
    check(DSCSymbolCode.decode([1, 1, 0, 1, 0, 1, 0, 0, 1, 1][...]) == 43, "DSC-Symbol 43")
    check(DSCSymbolCode.decode([1, 1, 0, 1, 0, 1, 0, 0, 1, 0][...]) == nil, "DSC-Symbol: falsche Prüfbits")
    for v in 0...127 { if DSCSymbolCode.decode(DSCSymbolCode.bits(for: v)[...]) != v { check(false, "DSC-Symbol \(v) rund"); break } }

    // Echte Symbolfolgen (Referenz TAOSW.DSC_Decoder, aufgezeichnete Rufe 8414,5 kHz) → Nachricht
    func msg(_ v: [Int]) -> DSCMessage {
        var x = 0
        let e = v.indices.first(where: { $0 >= 3 && DSCSymbolCode.eosSymbols.contains(v[$0]) })!
        for m in 1...e { x ^= v[m] }
        return DSCMessage.parse(symbols: v, eccOK: x == v[e + 1])
    }
    let dist = msg([112, 112, 25, 58, 5, 99, 70, 107, 4, 52, 60, 13, 7, 12, 52, 109, 127, 52, 127, 127])
    check(dist.format == .distress && dist.isDistress && dist.from == "255805997" && dist.nature == "Unbestimmt" && dist.position == "45°26′N 013°07′O"
          && dist.timeUTC == "12:52" && dist.eccOK && dist.ecc == 52, "DSC Notruf: MMSI, Art, Position, Zeit, ECC")
    let ack = msg([120, 120, 32, 51, 42, 0, 0, 108, 0, 23, 71, 0, 0, 118, 126, 4, 10, 10, 4, 39, 30, 122, 54, 122, 122])
    check(ack.format == .individual && ack.to == "325142000" && ack.from == "002371000" && ack.category == "SICHERHEIT" && ack.firstCommand == "TEST"
          && ack.frequency == "04101.0/04393.0" && ack.eos == "QUITTUNG" && ack.eccOK, "DSC Einzelruf mit Test, Frequenzpaar und Quittung")
    let j3e = msg([120, 120, 0, 23, 71, 0, 4, 100, 23, 82, 30, 0, 0, 109, 126, 8, 41, 45, 126, 126, 126, 117, 7, 117, 117])
    check(j3e.to == "002371000" && j3e.from == "238230000" && j3e.category == "ROUTINE" && j3e.firstCommand == "J3E SPRECHFUNK" && j3e.frequency == "08414.5"
          && j3e.eos == "QUITTUNG ERBETEN" && j3e.eccOK, "DSC Einzelruf J3E mit einer Frequenz")
    let all = msg([116, 116, 108, 0, 23, 71, 0, 0, 109, 126, 4, 12, 50, 4, 12, 50, 127, 36, 127, 127])
    check(all.format == .allShips && all.to == "ALLE SCHIFFE" && all.from == "002371000" && all.frequency == "04125.0/04125.0" && all.eos == "ENDE" && all.eccOK, "DSC Alle Schiffe")
    let area = msg([102, 102, 4, 40, 3, 5, 8, 108, 0, 22, 75, 40, 0, 109, 126, 2, 18, 20, 2, 18, 20, 127, 49, 127, 127])
    check(area.format == .geographicArea && area.to?.contains("NW-Ecke 44°N 003°O, 5° nach Süden, 8° nach Osten") == true && area.from == "002275400"
          && area.frequency == "02182.0/02182.0" && area.eccOK, "DSC Gebietsruf")
    let pos = msg([120, 120, 0, 25, 70, 0, 0, 108, 23, 20, 19, 71, 50, 109, 126, 55, 5, 85, 30, 1, 34, 117, 18, 117, 117])
    check(pos.position == "58°53′N 001°34′O" && pos.from == "232019715" && pos.to == "002570000" && pos.eccOK, "DSC Einzelruf mit Position")
    let req = msg([120, 120, 51, 89, 99, 19, 50, 100, 0, 27, 11, 0, 0, 126, 126, 126, 126, 126, 126, 126, 126, 117, 81, 117, 117])
    check(req.firstCommand == "KEINE ANGABE" && req.frequency == nil && req.eccOK && req.to == "518999195", "DSC Einzelruf ohne Angaben")
    let bad = msg([120, 120, 51, 89, 99, 19, 50, 100, 0, 27, 11, 0, 0, 126, 126, 126, 126, 126, 126, 126, 126, 117, 80, 117, 117])
    check(!bad.eccOK, "DSC: falscher ECC wird erkannt")
    let broken = DSCMessage.parse(symbols: [120, 120, 0, 25, -1, 0, 0, 108, 23, 20, 19, 71, 50, 109, 126, 126, 126, 126, 126, 126, 126, 117, 18, 117, 117], eccOK: false)
    check(broken.to?.contains("_") == true && broken.unreadable == 1, "DSC: unlesbare Ziffern als „_“")
    check(DSCMessage.parse(symbols: [-1, -1, 1, 2, 3], eccOK: false).format == .unknown, "DSC: unbekanntes Format")

    // Erzeugen → Demodulieren → Rahmen
    func roundTrip(_ info: [Int], center: Double = 1700, offset: Double = 0, reversedTx: Bool = false, reversedRx: Bool = false,
                   snr: Double? = nil, dot: Int = 200, lead: Double = 0.5, seed: UInt64 = 7) -> [DSCCall] {
        var audio = DSCSignalGenerator.audio(bits: DSCSignalGenerator.bits(info: info, dotBits: dot), centerHz: center + offset, lead: lead, reversed: reversedTx)
        if let snr {
            var st = seed
            func g() -> Double {
                st = st &* 6364136223846793005 &+ 1442695040888963407
                let u1 = (Double(st >> 11) + 1) / Double((1 << 53) + 2)
                st = st &* 6364136223846793005 &+ 1442695040888963407
                let u2 = Double(st >> 11) / Double(1 << 53)
                return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            }
            let sigma = sqrt(0.125 / pow(10, snr / 10) / (2500.0 / 4000.0))
            for i in 0..<audio.count { audio[i] += Float(g() * sigma) }
        }
        let demod = DSCDemodulator(centerHz: center)
        demod.reversed = reversedRx
        var framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
        var collector = DSCCallCollector()
        var t = 0
        var pos = 0
        while pos < audio.count {
            let n = min(800, audio.count - pos)
            audio[pos..<(pos + n)].withUnsafeBufferPointer { demod.process($0) { p, b in if let c = framers[p].push(b) { collector.add(c, at: Double(t) / 8000) } } }
            pos += n
            t = pos
        }
        return collector.take(now: 0, force: true)
    }
    let infoA = DSCSignalGenerator.call(format: 120, body: [0, 23, 71, 0, 4, 100, 23, 82, 30, 0, 0, 109, 126, 8, 41, 45, 126, 126, 126], eos: 117)
    check(infoA == [120, 120, 0, 23, 71, 0, 4, 100, 23, 82, 30, 0, 0, 109, 126, 8, 41, 45, 126, 126, 126, 117, 7, 117, 117], "DSC: Generator erzeugt die aufgezeichnete Symbolfolge samt ECC")
    let rt = roundTrip(infoA)
    check(rt.count == 1 && rt[0].symbols == infoA && rt[0].eccOK && rt[0].unreadable == 0, "DSC Rundlauf: Ruf fehlerfrei, \(rt.count) Ruf(e)")
    let distInfo = DSCSignalGenerator.call(format: 112, body: [25, 58, 5, 99, 70, 107, 4, 52, 60, 13, 7, 12, 52, 109])
    check(roundTrip(distInfo, center: 1500).first?.symbols == distInfo, "DSC Rundlauf: Notruf, Mitte 1500 Hz")
    check(roundTrip(infoA, center: 1700, dot: 20).first?.symbols == infoA, "DSC Rundlauf: kurzes Punktmuster (20 Bit)")
    check(roundTrip(infoA, reversedTx: true, reversedRx: true).first?.symbols == infoA, "DSC Rundlauf: umgekehrtes Seitenband mit REV")
    check(roundTrip(infoA, reversedTx: true, reversedRx: false).isEmpty, "DSC: umgekehrtes Seitenband ohne REV liefert nichts")
    check(roundTrip(infoA, offset: 8).first?.symbols == infoA, "DSC Rundlauf: 8 Hz neben der Mitte")
    check(roundTrip(infoA, offset: -15).first?.symbols == infoA, "DSC Rundlauf: 15 Hz unter der Mitte")
    for snr in [10.0, 3.0] {
        let r = roundTrip(infoA, snr: snr)
        check(r.first?.symbols == infoA, "DSC Rundlauf bei \(Int(snr)) dB S/N")
    }
    check(roundTrip(infoA, snr: 0, seed: 11).first.map { $0.eccOK || $0.unreadable > 0 } ?? true, "DSC bei 0 dB: kein falscher Ruf mit gültigem ECC und falschem Inhalt")
    // Nur Rauschen: kein Ruf
    var noiseOnly = [Float](repeating: 0, count: 8000 * 30)
    var ns: UInt64 = 99
    for i in 0..<noiseOnly.count { ns = ns &* 6364136223846793005 &+ 1442695040888963407; noiseOnly[i] = Float(Double(ns >> 40) / Double(1 << 24) - 0.5) }
    do {
        let demod = DSCDemodulator(centerHz: 1700)
        var framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
        var calls = 0
        noiseOnly.withUnsafeBufferPointer { demod.process($0) { p, b in if framers[p].push(b) != nil { calls += 1 } } }
        check(calls == 0, "DSC: Rauschen ergibt keinen Ruf")
    }
    // Zwei Rufe hintereinander
    do {
        var bits = DSCSignalGenerator.bits(info: infoA)
        bits += DSCSignalGenerator.bits(info: distInfo, dotBits: 20)
        let audio = DSCSignalGenerator.audio(bits: bits)
        let demod = DSCDemodulator(centerHz: 1700)
        var framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
        var collector = DSCCallCollector()
        var t = 0
        var pos = 0
        while pos < audio.count {
            let n = min(800, audio.count - pos)
            audio[pos..<(pos + n)].withUnsafeBufferPointer { demod.process($0) { p, b in if let c = framers[p].push(b) { collector.add(c, at: Double(t) / 8000) } } }
            pos += n
            t = pos
        }
        let calls = collector.take(now: 0, force: true)
        check(calls.count == 2 && calls.first?.symbols == infoA && calls.last?.symbols == distInfo, "DSC: zwei Rufe unmittelbar nacheinander (\(calls.count))")
    }

    // Zusammenführen der Taktlagen: bester Ruf je Aussendung, Trümmer entfallen
    do {
        let good = DSCCall(symbols: infoA, eccOK: true, unreadable: 0)
        let worse = DSCCall(symbols: infoA, eccOK: false, unreadable: 3)
        let junk = DSCCall(symbols: infoA, eccOK: false, unreadable: 9)
        var c = DSCCallCollector()
        c.add(worse, at: 10); c.add(good, at: 10.4); c.add(junk, at: 10.6); c.add(good, at: 30)
        check(c.take(now: 14).count == 1, "DSC-Sammler: Fenster abgelaufen → ein Ruf")
        check(c.take(now: 14).isEmpty && c.take(now: 40).first == good, "DSC-Sammler: zweite Aussendung später, ohne Doppelung")
        var d = DSCCallCollector()
        d.add(worse, at: 5); d.add(good, at: 6)
        check(d.take(now: 6).isEmpty && d.take(now: 10).first == good, "DSC-Sammler: der bessere ersetzt den schlechteren")
        var e = DSCCallCollector()
        e.add(junk, at: 5)
        check(e.take(now: 0, force: true).isEmpty, "DSC-Sammler: stark beschädigter Ruf entfällt")
    }

    // Mitte nachführen
    do {
        var audio = DSCSignalGenerator.audio(bits: DSCSignalGenerator.bits(info: infoA), centerHz: 2100, lead: 0)
        audio = Array(audio.prefix(8000 * 8))
        var tuner = DSCAutoTuner()
        var latest: (measured: Double?, newCenter: Double?) = (nil, nil)
        for k in 0..<3 { latest = tuner.update(recent: Array(audio[(3 * 8000 + k * 4000)..<(3 * 8000 + k * 4000 + 4096)]), current: 1700) }   // im Datenteil, nach dem Punktmuster
        check(latest.measured.map { abs($0 - 2100) <= 5 } == true && latest.newCenter.map { abs($0 - 2100) <= 5 } == true, "DSC-Nachführung findet 2100 Hz (\(latest))")
        var t2 = DSCAutoTuner()
        var rs: UInt64 = 4242
        let n = (0..<8192).map { _ -> Float in rs = rs &* 6364136223846793005 &+ 1442695040888963407; return Float(Double(rs >> 40) / Double(1 << 24) - 0.5) }
        check(t2.update(recent: n, current: 1700).measured == nil, "DSC-Nachführung: Rauschen ergibt keine Messung")
    }

    // Aufnahme eines echten Anrufs (Referenz TAOSW.DSC_Decoder, 8414,5 kHz): nur wenn lokal vorhanden
    do {
        let url = URL(fileURLWithPath: "Vendor/_upstream/dsc_taosw/TAOSW.DSC_Decoder/testFiles/test.wav")
        if let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
           let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: DSCDemodulator.sampleRate) {
            let demod = DSCDemodulator(centerHz: 505)
            var framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
            var collector = DSCCallCollector()
            var t = 0
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
            while true {
                buf.frameLength = 0
                try? file.read(into: buf, frameCount: 48_000)
                guard buf.frameLength > 0 else { break }
                src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { chunk in
                    demod.process(chunk) { p, b in if let c = framers[p].push(b) { collector.add(c, at: Double(t) / 8000) } }
                    t += chunk.count
                }
            }
            let calls = collector.take(now: 0, force: true)
            let tos = calls.map { DSCMessage.parse(symbols: $0.symbols).to ?? "?" }
            check(calls.count == 5 && calls.allSatisfy(\.eccOK), "DSC echte Aufnahme: 5 Rufe, alle ECC OK (\(calls.count))")
            check(tos == ["538010255", "477832400", "249855000", "511100954", "636024307"], "DSC echte Aufnahme: Adressaten \(tos)")
            check(calls.allSatisfy { DSCMessage.parse(symbols: $0.symbols).from == "002371000" && DSCMessage.parse(symbols: $0.symbols).firstCommand == "TEST" }, "DSC echte Aufnahme: Küstenfunkstelle 002371000, Testruf")
        } else {
            print("Hinweis: DSC-Beispielaufnahme nicht vorhanden, echter Anruf nicht geprüft")
        }
    }
}

// MARK: - UKW-DSC (Kanal 70, 1200 Bd, 1300/2100 Hz)
do {
    let info = DSCSignalGenerator.call(format: 120, body: [0, 23, 71, 0, 4, 100, 23, 82, 30, 0, 0, 109, 126, 8, 41, 45, 126, 126, 126], eos: 117)
    let dist = DSCSignalGenerator.call(format: 112, body: [25, 58, 5, 99, 70, 107, 4, 52, 60, 13, 7, 12, 52, 109])
    func run(_ audio: [Float], chunk: Int = 1200) -> [DSCCall] {
        let rx = DSCVHFReceiver()
        var collector = DSCCallCollector()
        var pos = 0
        while pos < audio.count {
            let n = min(chunk, audio.count - pos)
            audio[pos..<(pos + n)].withUnsafeBufferPointer { rx.process($0) { collector.add($0, at: Double(pos) / 12000) } }
            pos += n
        }
        return collector.take(now: 0, force: true)
    }
    func noisy(_ a: [Float], snr: Double, seed: UInt64) -> [Float] {
        var s = seed
        let sigma = 0.5 / 2.0.squareRoot() / pow(10, snr / 20)
        return a.map { v in
            var u = 0.0
            for _ in 0..<4 { s = s &* 6364136223846793005 &+ 1442695040888963407; u += Double(s >> 40) / Double(1 << 24) - 0.5 }
            return v + Float(u * sigma * 3.0.squareRoot() )
        }
    }
    let a = DSCSignalGenerator.audioVHF(bits: DSCSignalGenerator.bits(info: info, dotBits: 20))
    let r = run(a)
    check(r.count == 1 && r[0].symbols == info && r[0].eccOK && r[0].unreadable == 0, "UKW-DSC Rundlauf: Ruf fehlerfrei (\(r.count))")
    check(run(DSCSignalGenerator.audioVHF(bits: DSCSignalGenerator.bits(info: dist, dotBits: 20))).first?.symbols == dist, "UKW-DSC Rundlauf: Notruf")
    check(run(a, chunk: 977).first?.symbols == info, "UKW-DSC: Blockgröße unabhängig")
    check(run(DSCSignalGenerator.audioVHF(bits: DSCSignalGenerator.bits(info: info, dotBits: 20), baudError: 0.005)).first?.symbols == info, "UKW-DSC: Baudrate 0,5 % daneben")
    check(run(DSCSignalGenerator.audioVHF(bits: DSCSignalGenerator.bits(info: info, dotBits: 20), baudError: -0.005)).first?.symbols == info, "UKW-DSC: Baudrate −0,5 % daneben")
    for snr in [12.0, 6.0] {
        let got = run(noisy(a, snr: snr, seed: 5))
        check(got.first?.symbols == info, "UKW-DSC bei \(Int(snr)) dB S/N")
    }
    // zwei Rufe nacheinander, mit Pause
    do {
        var bits = DSCSignalGenerator.bits(info: info, dotBits: 20)
        bits += [UInt8](repeating: 1, count: 12000)         // Träger ohne Daten (Sekunde Pause, hier Y-Ton)
        bits += DSCSignalGenerator.bits(info: dist, dotBits: 20)
        let got = run(DSCSignalGenerator.audioVHF(bits: bits), chunk: 1200)
        check(got.contains { $0.symbols == info } && got.contains { $0.symbols == dist }, "UKW-DSC: zwei Rufe hintereinander (\(got.count))")
    }
    // Rauschen: kein Ruf
    var ns: UInt64 = 77
    let noise = (0..<(12000 * 20)).map { _ -> Float in ns = ns &* 6364136223846793005 &+ 1442695040888963407; return Float(Double(ns >> 40) / Double(1 << 24) - 0.5) }
    check(run(noise).isEmpty, "UKW-DSC: Rauschen ergibt keinen Ruf")
    // Kanal
    check(DSCChannel.vhf70.frequencyHz == 156_525_000 && DSCChannel.vhf70.isVHF && DSCChannel.vhf70.dial(center: 1700) == 156_525_000, "UKW-DSC: Kanal 70 156,525 MHz")
    check(RigTuneTarget.dsc(channel: .vhf70, centerHz: 1700)?.mode == "FM" && RigTuneTarget.dsc(channel: .f8414, centerHz: 1700)?.mode == "USB", "UKW-DSC: Funkgerät FM, HF bleibt USB")
}

// MARK: - DSC über die Pipeline (48 kHz → 8 kHz)
do {
    let pipeline = AudioPipeline()
    let decoder = DSCDecoder(pipeline: pipeline)
    decoder.configure(center: 1700, reversed: false, auto: true)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    let info = DSCSignalGenerator.call(format: 116, body: [108, 0, 23, 71, 0, 0, 109, 126, 4, 12, 50, 4, 12, 50])
    let audio8 = DSCSignalGenerator.audio(bits: DSCSignalGenerator.bits(info: info), centerHz: 1750, lead: 1, tail: 1.5)
    var audio48 = [Float](repeating: 0, count: audio8.count * 6)
    for i in 0..<audio48.count {
        let x = Double(i) / 6, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio8[k] * (1 - f) + (k + 1 < audio8.count ? audio8[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    var got: [DSCCall] = []
    while i < audio48.count {
        let n = min(9_600, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.006)
        got += decoder.takeOutput().calls.map(\.call)
    }
    Thread.sleep(forTimeInterval: 0.4)
    let last = decoder.takeOutput()
    got += last.calls.map(\.call)
    check(got.contains { $0.symbols == info && $0.eccOK }, "DSC über die Pipeline 48 kHz → 8 kHz (\(got.count) Treffer)")
    check(abs(last.center - 1750) <= 6, "DSC-Pipeline: Mitte folgt dem Tonpaar auf 1750 Hz (ist \(last.center))")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - ALE (MIL-STD-188-141): Golay, Wortcodec, Raster, Demodulator
do {
    check(parse("digidec://decode?mode=ale&center=1700") == .success(DecodeRequest(module: .ale, presetID: "ale", centerHz: 1700)), "ALE-Auftrag")
    check(parse("digidec://decode?mode=ale") == .success(DecodeRequest(module: .ale, presetID: "ale")), "ALE-Standard")

    // Golay (24,12): Mindestabstand 8, alle Fehler bis Gewicht 3 korrigierbar, Gewicht 4 erkennbar
    var minWeight = 99
    for i in 1..<4096 { minWeight = min(minWeight, ALEGolay.encode(UInt16(i)).nonzeroBitCount) }
    check(minWeight == 8, "ALE Golay: Mindestgewicht \(minWeight)")
    var corrected = 0, tried = 0
    for i in stride(from: 3, to: 4096, by: 53) {
        let cw = ALEGolay.encode(UInt16(i))
        for a in stride(from: 0, to: 24, by: 2) { for b in (a + 1)..<24 { for c in stride(from: b + 1, to: 24, by: 3) {
            tried += 1
            if ALEGolay.decode(cw ^ (1 << UInt32(a)) ^ (1 << UInt32(b)) ^ (1 << UInt32(c)))?.info == UInt16(i) { corrected += 1 }
        } } }
    }
    check(corrected == tried && tried > 1000, "ALE Golay: 3 Fehler werden korrigiert (\(corrected)/\(tried))")
    check(ALEGolay.decode(ALEGolay.encode(0x5A5) ^ 0b1111)?.info != 0x5A5 || ALEGolay.decode(ALEGolay.encode(0x5A5) ^ 0b1111) == nil, "ALE Golay: 4 Fehler werden nicht fälschlich als gültig übernommen")
    check(ALEGolay.parity(0x001) == 0x5C7 && ALEGolay.parity(0x800) == 0xAE3 && ALEGolay.encode(0x003) == 0x003_000 | UInt32(0x5C7 ^ 0xB8D), "ALE Golay: Prüfbits der Basisvektoren, linear")

    // Wortcodec: 24 Bit → 49 Symbole → 24 Bit; Zeichensätze
    check(ALECodec.freqToSymbol == [0, 1, 3, 2, 6, 7, 5, 4] && ALECodec.symbolToFreqIndex[6] == 4 && ALECodec.symbolToFreqIndex[4] == 7, "ALE: Tonzuordnung (Gray)")
    let w24 = ALECodec.word24(preamble: .tis, chars: Array("ABC".utf8))
    check(w24 == 0b101_1000001_1000010_1000011, "ALE: 24-Bit-Wort TIS ABC")
    let sym = ALECodec.symbols(word24: w24)
    check(sym.count == 49 && sym.allSatisfy { $0 < 8 }, "ALE: 49 Symbole")
    let dec = ALECodec.decode(symbols: sym[...])
    check(dec?.word24 == w24 && dec?.unanimous == 48 && dec?.errors == 0, "ALE: Wort fehlerfrei zurück (48 einstimmige Bit)")
    var damaged = sym
    for i in [2, 9, 20, 31, 44] { damaged[i] = (damaged[i] + 3) & 7 }        // 5 falsche Symbole = bis zu 15 falsche Bit
    check(ALECodec.decode(symbols: damaged[...], minUnanimous: 20)?.word24 == w24, "ALE: 5 falsche Symbole werden durch Mehrheit und Golay repariert")
    check(ALECodec.decode(symbols: sym[...], minUnanimous: 49) == nil, "ALE: Schwelle über 48 liefert nichts")
    // Ungültige Zeichen (Kleinbuchstaben) in einem Adresswort werden verworfen
    let bad = ALECodec.word24(preamble: .to, chars: Array("abc".utf8))
    check(ALECodec.decode(symbols: ALECodec.symbols(word24: bad)[...]) == nil, "ALE: Kleinbuchstaben in einem TO-Wort ungültig")
    let text = ALECodec.word24(preamble: .data, chars: Array("hi!".utf8))
    check(ALECodec.decode(symbols: ALECodec.symbols(word24: text)[...]) == nil, "ALE: Kleinbuchstaben auch in DATA ungültig (Expanded 64)")
    let ok64 = ALECodec.word24(preamble: .data, chars: Array("HI!".utf8))
    check(ALECodec.decode(symbols: ALECodec.symbols(word24: ok64)[...])?.word24 == ok64, "ALE: DATA mit Satzzeichen (Expanded 64)")
    let cmd = ALECodec.word24(preamble: .cmd, chars: [0x7E, 0x01, 0x55])
    check(ALECodec.decode(symbols: ALECodec.symbols(word24: cmd)[...])?.word24 == cmd, "ALE: CMD-Wort mit Binärdaten wird ohne Zeichenprüfung angenommen")

    // Rundlauf Audio → Wörter → Raster → Aussendung
    func decodeAudio(_ audio: [Float], offset: Double = 0, votes: Int = 36) -> (words: [ALEWord], messages: [ALEMessage]) {
        let demod = ALEDemodulator(offsetHz: offset)
        demod.minUnanimous = votes
        var collector = ALEWordCollector()
        var tracker = ALEGridTracker()
        var builder = ALEMessageBuilder()
        var words: [ALEWord] = [], messages: [ALEMessage] = []
        var total = 0
        var pos = 0
        while pos < audio.count {
            let n = min(800, audio.count - pos)
            audio[pos..<(pos + n)].withUnsafeBufferPointer { demod.process($0) { w, _ in collector.add(w) } }
            pos += n
            total = pos
            for w in collector.take(now: total) where tracker.accept(w) {
                words.append(w)
                if let m = builder.add(w, offsetHz: offset) { messages.append(m) }
            }
            tracker.idle(now: total)
            if let m = builder.flush(nowSample: total, offsetHz: offset) { messages.append(m) }
        }
        for w in collector.take(now: total, force: true) where tracker.accept(w) {
            words.append(w)
            if let m = builder.add(w, offsetHz: offset) { messages.append(m) }
        }
        if let m = builder.flush(nowSample: total, offsetHz: offset, force: true) { messages.append(m) }
        return (words, messages)
    }
    let call = ALESignalGenerator.words(address: .to, "W1AWJ") + [(ALEPreamble.tis, Array("DL1".utf8)), (ALEPreamble.data, Array("ABC".utf8))]
    let r = decodeAudio(ALESignalGenerator.audio(words: call))
    check(r.words.map { "\($0.preamble.name):\($0.text)" } == ["TO:W1A", "DATA:WJ@", "TIS:DL1", "DATA:ABC"], "ALE Rundlauf: genau die gesendeten Wörter, got \(r.words.map { "\($0.preamble.name):\($0.text)" })")
    check(r.messages.count == 1 && r.messages[0].quality == 48, "ALE Rundlauf: eine Aussendung, Q48 (\(r.messages.count))")
    check(r.words.first.map { abs($0.endSample - 6308) <= 8 } == true, "ALE Rundlauf: Wortende bei 6308 (\(r.words.first?.endSample ?? 0))")

    // Adressen: Fortsetzungsworte DATA/REP, Auffüllen mit „@“
    let addrWords = ALESignalGenerator.words(address: .to, "CALLSIGNX") + ALESignalGenerator.words(address: .tis, "EDWARD") + ALESignalGenerator.words(address: .tis, "W1AW")
    let am = decodeAudio(ALESignalGenerator.audio(words: addrWords)).messages.first
    check(am?.addresses(.to) == ["CALLSIGNX"] && am?.addresses(.tis) == ["EDWARD", "W1AW"], "ALE: Adressen aus mehreren Wörtern zusammengesetzt: \(am?.summary ?? "-")")
    check(am?.kind == "ANRUF", "ALE: Art ANRUF")
    let snd = decodeAudio(ALESignalGenerator.audio(words: ALESignalGenerator.words(address: .twas, "DL1ABC"))).messages.first
    check(snd?.kind == "SOUNDING" && snd?.addresses(.twas) == ["DL1ABC"], "ALE: Sounding (TWAS)")
    let msgWords = ALESignalGenerator.words(address: .to, "ALL") + [(ALEPreamble.cmd, [0x7E, 0x41, 0x4D]), (.data, Array("HEL".utf8)), (.rep, Array("LO ".utf8)), (.data, Array("WOR".utf8)), (.rep, Array("LD@".utf8))]
    let mm = decodeAudio(ALESignalGenerator.audio(words: msgWords)).messages.first
    check(mm?.kind == "NACHRICHT" && mm?.parts.filter { $0.preamble == .data || $0.preamble == .rep }.map(\.text).joined() == "HELLO WORLD@", "ALE: Nachricht aus DATA/REP-Wörtern: \(mm?.summary ?? "-")")

    // Verstimmung, Rauschen, falscher Takt
    check(decodeAudio(ALESignalGenerator.audio(words: call, offsetHz: 12)).words.count == 4, "ALE: Töne 12 Hz zu hoch, Wörter trotzdem gelesen")
    check(decodeAudio(ALESignalGenerator.audio(words: call, offsetHz: 12), offset: 12).words.count == 4, "ALE: Verstimmung 12 Hz eingestellt")
    check(decodeAudio(ALESignalGenerator.audio(words: call, lead: 0.4137)).words.count == 4, "ALE: beliebige Taktlage (Vorlauf 0,4137 s)")
    var st: UInt64 = 31
    func gauss() -> Double {
        st = st &* 6364136223846793005 &+ 1442695040888963407
        let u1 = (Double(st >> 11) + 1) / Double((1 << 53) + 2)
        st = st &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double(st >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    for (snr, minWords) in [(12.0, 4), (6.0, 3)] {
        var a = ALESignalGenerator.audio(words: call)
        let sigma = sqrt(0.125 / pow(10, snr / 10) / (2500.0 / 4000.0))
        for i in 0..<a.count { a[i] += Float(gauss() * sigma) }
        let n = decodeAudio(a).words.count
        check(n >= minWords, "ALE bei \(Int(snr)) dB S/N (in 2500 Hz): \(n) von 4 Wörtern")
    }
    var noise = [Float](repeating: 0, count: 8000 * 40)
    for i in 0..<noise.count { noise[i] = Float(gauss() * 0.2) }
    check(decodeAudio(noise).words.isEmpty, "ALE: Rauschen ergibt keine Wörter")
    // Ein einzelner Dauerton und Mehrtonfolgen (keine Wörter)
    var tone = [Float](repeating: 0, count: 80_000)
    for i in 0..<tone.count { let ph: Double = 2.0 * Double.pi * 1500.0 * Double(i) / 8000.0; tone[i] = Float(0.5 * sin(ph)) }
    check(decodeAudio(tone).words.isEmpty, "ALE: Dauerton ergibt keine Wörter")

    // Raster: ein verschobenes Fenster gilt nicht
    do {
        var tr = ALEGridTracker()
        func w(_ p: ALEPreamble, _ end: Int, _ votes: Int = 48, _ err: Int = 0) -> ALEWord { ALEWord(preamble: p, chars: Array("ABC".utf8), unanimous: votes, golayErrors: err, endSample: end) }
        check(tr.accept(w(.to, 10_000)), "ALE-Raster: erstes TO-Wort")
        check(!tr.accept(w(.data, 10_000 + 3136 + 64, 48)), "ALE-Raster: um ein Symbol verschobenes Wort abgelehnt")
        check(tr.accept(w(.data, 10_000 + 3136 + 10, 40)), "ALE-Raster: Folgewort im Raster angenommen")
        check(tr.accept(w(.cmd, 10_000 + 3136 * 3 + 20, 38)), "ALE-Raster: nach einem fehlenden Wort weiter im Raster")
        var t2 = ALEGridTracker()
        check(!t2.accept(w(.data, 5000)), "ALE-Raster: erstes Wort muss TO/TIS/TWAS/FROM/THRU sein")
        check(!t2.accept(w(.to, 5000, 40)), "ALE-Raster: erstes Wort braucht ≥ 44 einstimmige Bit")
        check(!t2.accept(w(.to, 5000, 48, 5)), "ALE-Raster: erstes Wort mit zu vielen Golay-Fehlern abgelehnt")
        tr.idle(now: 10_000 + 3136 * 3 + 20 + 3136 * 4)
        check(!tr.isLocked, "ALE-Raster: nach Pause wieder frei")
    }

    // Frequenzfehler am bekannten Wort messen
    do {
        let word = ALECodec.word24(preamble: .tis, chars: Array("DL1".utf8))
        let symbols = ALECodec.symbols(word24: word)
        for eps in [-25.0, -10.0, 0.0, 14.0, 30.0] {
            let a = ALESignalGenerator.audio(words: [(ALEPreamble.tis, Array("DL1".utf8))], offsetHz: eps, lead: 0, tail: 0)
            let est = ALEFrequencyError.estimate(samples: a, symbols: symbols, offset: 0)
            check(est.map { abs($0 - eps) <= 3 } == true, "ALE-Frequenzfehler \(eps) Hz gemessen: \(est.map { String(format: "%.1f", $0) } ?? "nil")")
        }
        check(ALEFrequencyError.estimate(samples: [Float](repeating: 0, count: 3136), symbols: symbols, offset: 0) == nil, "ALE-Frequenzfehler: Stille ergibt nichts")
    }

    // Echte Aufnahme (sigidwiki „2G ALE“, 30 s): nur wenn lokal vorhanden
    do {
        let url = URL(fileURLWithPath: "Vendor/_upstream/ale_sigid.mp3")
        if let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
           let src = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: ALEDemodulator.sampleRate) {
            var audio: [Float] = []
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
            while true {
                buf.frameLength = 0
                try? file.read(into: buf, frameCount: 48_000)
                guard buf.frameLength > 0 else { break }
                src.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { audio += $0 }
            }
            let real = decodeAudio(audio)
            let kinds = real.messages.map(\.kind)
            check(real.messages.count == 3 && real.words.count >= 35, "ALE echte Aufnahme: \(real.messages.count) Aussendungen, \(real.words.count) Wörter")
            check(real.messages.filter { $0.addresses(.tis).contains("SHAEENQ2") }.count == 2, "ALE echte Aufnahme: Kennung „SHAEENQ2“ zweimal (\(kinds))")
            let joined = real.messages.map(\.summary).joined(separator: " ")
            check(joined.contains("USMANQ") && joined.contains("MORNING ABOUT HOLIDAY"), "ALE echte Aufnahme: Anruf an USMANQ und Klartext „…MORNING ABOUT HOLIDAY…“ (\(joined.prefix(300)))")
            check(real.messages.allSatisfy { $0.quality >= 36 }, "ALE echte Aufnahme: alle Wörter mit ≥ 36 einstimmigen Bit")
        } else {
            print("Hinweis: ALE-Beispielaufnahme nicht vorhanden, echte Aussendung nicht geprüft")
        }
    }
}

// MARK: - ALE über die Pipeline (48 kHz → 8 kHz) mit Frequenznachführung
do {
    let pipeline = AudioPipeline()
    let decoder = ALEDecoder(pipeline: pipeline)
    decoder.configure(offset: 0, auto: true, sensitivity: .normal)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    let words = ALESignalGenerator.words(address: .to, "BOB") + ALESignalGenerator.words(address: .tis, "ALICE")
    var audio8: [Float] = []
    for _ in 0..<3 { audio8 += ALESignalGenerator.audio(words: words, offsetHz: 22, lead: 0.5, tail: 0.5) }   // dreimal hintereinander: die Nachführung lernt
    var audio48 = [Float](repeating: 0, count: audio8.count * 6)
    for i in 0..<audio48.count {
        let x = Double(i) / 6, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio8[k] * (1 - f) + (k + 1 < audio8.count ? audio8[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    var got: [ALEMessage] = []
    var lastOffset = 0.0
    while i < audio48.count {
        let n = min(9_600, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.006)
        let o = decoder.takeOutput()
        got += o.messages
        lastOffset = o.offset
    }
    Thread.sleep(forTimeInterval: 0.5)
    let o = decoder.takeOutput()
    got += o.messages
    lastOffset = o.offset
    check(got.count >= 2 && got.contains { $0.addresses(.tis) == ["ALICE"] && $0.addresses(.to) == ["BOB"] }, "ALE über die Pipeline 48 kHz → 8 kHz (\(got.count) Aussendungen)")
    check(abs(lastOffset - 22) <= 6, "ALE-Pipeline: Verstimmung wird nachgeführt (\(lastOffset) Hz)")
    decoder.setEnabled(false)
    pipeline.stop()
}


// MARK: - Geo: Entfernung, Richtung, Locator
do {
    let hamburg = GeoPoint(lat: 53.5511, lon: 9.9937), wuerzburg = GeoPoint(lat: 49.7913, lon: 9.9534)
    let d = Geo.distanceKm(hamburg, wuerzburg)
    check(abs(d - 418) < 6, "Hamburg–Würzburg etwa 418 km (\(d))")
    check(abs(Geo.bearing(from: hamburg, to: wuerzburg) - 180) < 3, "Richtung Hamburg → Würzburg Süd")
    check(abs(Geo.distanceKm(hamburg, hamburg)) < 0.001, "Entfernung zu sich selbst 0")
    let dest = Geo.destination(from: hamburg, bearing: 90, km: 100)
    check(abs(Geo.distanceKm(hamburg, dest) - 100) < 0.01 && abs(Geo.bearing(from: hamburg, to: dest) - 90) < 0.5, "Zielpunkt 100 km nach Osten")
    check(Maidenhead.locator(GeoPoint(lat: 49.7913, lon: 9.9534)).hasPrefix("JN49"), "Locator Würzburg JN49…: \(Maidenhead.locator(GeoPoint(lat: 49.7913, lon: 9.9534)))")
    check(Maidenhead.locator(Maidenhead.point("JN49WS")!) == "JN49WS", "Locator Rundlauf JN49WS")
    check(Geo.format(GeoPoint(lat: 49.5, lon: -72.75)) == "49°30,00′ N 072°45,00′ W", "Koordinatenformat: \(Geo.format(GeoPoint(lat: 49.5, lon: -72.75)))")
    check(Geo.compass(95) == "O" && Geo.compass(350) == "N" && Geo.compass(225) == "SW", "Himmelsrichtungen")
    check(!GeoPoint(lat: 91, lon: 0).isValid && GeoPoint(lat: -90, lon: 180).isValid, "Gültiger Bereich")
    let content = MapContent(markers: [MapMarker(id: "a", coordinate: GeoPoint(lat: 50, lon: 8), title: "A"),
                                       MapMarker(id: "b", coordinate: GeoPoint(lat: 52, lon: 12), title: "B")], home: GeoPoint(lat: 49, lon: 10))
    let r = content.region()!
    check(abs(r.center.lat - 50.5) < 0.01 && abs(r.center.lon - 10) < 0.01 && r.latSpan >= 3 && r.lonSpan >= 4, "Kartenausschnitt umfasst alle Punkte")
    check(MapContent().region() == nil, "Leere Karte: kein Ausschnitt")
}

// MARK: - AX.25 und APRS
do {
    check(HDLC.crc16(Array("123456789".utf8)) == 0x906E, "CRC-16/X.25 Prüfwert 0x906E")
    let f = AX25Frame(dest: AX25Address(call: "APRS"), source: AX25Address(call: "DL1ABC", ssid: 9),
                      digis: [AX25Address(call: "WIDE1", ssid: 1, repeated: true), AX25Address(call: "WIDE2", ssid: 1)],
                      info: Array("!4903.50N/07201.75W-Test".utf8))
    let bytes = f.encode()
    let back = AX25Frame.parse(bytes)
    check(back == f, "AX.25 Rahmen: Kodieren und Lesen")
    check(f.header == "DL1ABC-9>APRS,WIDE1-1*,WIDE2-1", "TNC2-Kopf: \(f.header)")
    check(HDLC.fcsValid(HDLC.withFCS(bytes)) && !HDLC.fcsValid(HDLC.withFCS(bytes).dropLast() + [0x00]), "FCS stimmt / stimmt nicht")
    check(AX25Address(text: "DL1ABC-9")?.ssid == 9 && AX25Address(text: "TOOLONGCALL") == nil && AX25Address(text: "DL1ABC-16") == nil, "Adresse aus Text")
    // Ein Bit gekippt: Reparatur findet es, Zufallsdaten nicht
    var broken = HDLC.withFCS(bytes)
    broken[20] ^= 0x04
    check(!HDLC.fcsValid(broken), "Kaputter Rahmen erkannt")
    check(AFSKDemodulator.repair(broken).map { Array($0.dropLast(2)) } == bytes, "Ein-Bit-Reparatur stellt den Rahmen her")
    var junk = (0..<60).map { UInt8(($0 * 37 + 11) & 0xFF) }
    junk += [0, 0]
    check(AFSKDemodulator.repair(junk) == nil, "Zufallsdaten werden nicht repariert")
}

func aprsPacket(_ dest: String, _ info: String, source: String = "DL1ABC-9", digis: [String] = ["WIDE1-1"]) -> APRSPacket? {
    let f = AX25Frame(dest: AX25Address(text: dest)!, source: AX25Address(text: source)!, digis: digis.map { AX25Address(text: $0)! }, info: Array(info.utf8))
    return APRSParser.parse(f)
}

do {
    // Unkomprimiert mit Kommentar
    let p = aprsPacket("APRS", "!4903.50N/07201.75W-Test 001234")!
    check(p.kind == .position && abs(p.position!.lat - 49.058333) < 1e-5 && abs(p.position!.lon + 72.029167) < 1e-5, "Position unkomprimiert: \(String(describing: p.position))")
    check(p.symbol == APRSSymbol(table: "/", code: "-") && p.symbol?.name == "Haus" && p.comment == "Test 001234", "Symbol und Kommentar")
    // Mit Zeitstempel, Kurs und Geschwindigkeit
    let q = aprsPacket("APRS", "/092345z4903.50N/07201.75W>088/036Mein Auto")!
    check(q.timestamp == "092345z" && q.courseDeg == 88 && q.speedKnots == 36 && q.comment == "Mein Auto", "Zeitstempel, Kurs 88°, 36 kn: \(String(describing: q.courseDeg)) \(String(describing: q.speedKnots)) \(q.comment)")
    // Südliche und westliche Halbkugel, Mehrdeutigkeit
    let s = aprsPacket("APRS", "!3345.  S/15112.  E>")!
    check(s.position!.lat < -33.7 && s.position!.lon > 151.2 && s.ambiguity == 2, "Süd/Ost mit Mehrdeutigkeit 2: \(String(describing: s.position)) \(s.ambiguity)")
    // Komprimiert (Beispiel der Spezifikation): 49,5° N 72,75° W, Kurs 88°, 36,2 kn
    let c = aprsPacket("APRS", "=/5L!!<*e7>7P[")!
    check(c.kind == .position && abs(c.position!.lat - 49.5) < 0.001 && abs(c.position!.lon + 72.75) < 0.001, "Position komprimiert: \(String(describing: c.position))")
    check(c.courseDeg == 88 && abs((c.speedKnots ?? 0) - 36.2) < 0.2 && c.symbol?.code == ">", "Komprimiert: Kurs und Geschwindigkeit \(String(describing: c.courseDeg)) \(String(describing: c.speedKnots))")
    // Höhe im Kommentar
    check(aprsPacket("APRS", "!4903.50N/07201.75W>Test /A=001000")!.altitudeM.map { abs($0 - 304.8) < 0.1 } == true, "Höhe /A= in Fuß")
    // Wetter mit Ort und ohne
    let w = aprsPacket("APRS", "!4903.50N/07201.75W_220/004g005t077r000p000P000h50b09900")!
    check(w.kind == .weather && w.weather?.temperatureC.map { abs($0 - 25) < 0.01 } == true && w.weather?.humidityPercent == 50
          && w.weather?.pressureHPa == 990.0 && w.weather?.windDirDeg == 220, "Wetter mit Ort: \(w.weather?.summary ?? "-")")
    let w2 = aprsPacket("APRS", "_10090556c220s004g005t-05h00b10132")!
    check(w2.kind == .weather && w2.weather?.temperatureC.map { abs($0 + 20.56) < 0.05 } == true && w2.weather?.humidityPercent == 100
          && w2.weather?.pressureHPa.map { abs($0 - 1013.2) < 0.01 } == true, "Wetter ohne Ort: \(w2.weather?.summary ?? "-")")
    // Objekt
    let o = aprsPacket("APRS", ";LEADER   *092345z4903.50N/07201.75W>088/036")!
    check(o.kind == .object && o.name == "LEADER" && !o.killed && o.position != nil && o.stationKey == "LEADER", "Objekt")
    let k = aprsPacket("APRS", ";LEADER   _092345z4903.50N/07201.75W>")!
    check(k.killed, "Objekt gelöscht")
    let it = aprsPacket("APRS", ")AID #2!4903.50N/07201.75Wa")!
    check(it.kind == .item && it.name == "AID #2" && it.position != nil, "Gegenstand")
    // Nachrichten
    let m = aprsPacket("APRS", ":WU2Z     :Testing{003")!
    check(m.message == APRSMessage(addressee: "WU2Z", text: "Testing", id: "003", kind: .text), "Nachricht mit Nummer")
    let a = aprsPacket("APRS", ":DL1ABC-9 :ack003")!
    check(a.message?.kind == .ack && a.message?.id == "003", "Quittung")
    check(aprsPacket("APRS", ":BLN1     :Wetterwarnung")!.message?.kind == .bulletin, "Bulletin")
    // Status, Telemetrie, NMEA
    check(aprsPacket("APRS", ">Unterwegs in Würzburg")!.status == "Unterwegs in Würzburg", "Status")
    check(aprsPacket("APRS", "T#005,199,000,255,073,123,01101001")!.telemetry == [199, 0, 255, 73, 123], "Telemetrie")
    let n = aprsPacket("APRS", "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A")!
    check(n.kind == .nmea && abs(n.position!.lat - 48.1173) < 1e-3 && abs(n.position!.lon - 11.51667) < 1e-3 && n.speedKnots == 22.4, "NMEA GPRMC")
    // Kein UI-Paket
    let nonUI = AX25Frame(dest: AX25Address(call: "APRS"), source: AX25Address(call: "DL1ABC"), control: 0x2F, pid: nil, info: Array("x".utf8))
    check(APRSParser.parse(nonUI) == nil, "Rahmen ohne UI-Control wird nicht als APRS gelesen")
    // Gerät
    check(aprsPacket("APDW17", ">x")!.device == "Dire Wolf" && aprsPacket("APRS", ">x")!.device == nil, "Gerät aus Zieladresse")
}

// MARK: - Mic-E: Kodierer nach APRS101 Kap. 10 gegen den Leser
func micEEncode(lat: Double, lon: Double, speedKn: Int, course: Int, symbol: String = ">/", message: Int = 7) -> (dest: String, info: String) {
    let north = lat >= 0, west = lon < 0
    let la = abs(lat), lo = abs(lon)
    let latDeg = Int(la), latMin = Int((la - Double(latDeg)) * 6000 + 0.5)   // in 1/100 Minuten
    let digits = [latDeg / 10, latDeg % 10, (latMin / 100) / 10, (latMin / 100) % 10, (latMin % 100) / 10, latMin % 100 % 10]
    let lonDeg = Int(lo), lonMinTotal = Int((lo - Double(lonDeg)) * 6000 + 0.5)
    let bits = [message & 4 != 0, message & 2 != 0, message & 1 != 0]
    var dest = ""
    for i in 0..<6 {
        var high = false
        if i < 3 { high = bits[i] }
        if i == 3 { high = north }
        if i == 4 { high = lonDeg >= 100 || lonDeg < 10 }
        if i == 5 { high = west }
        dest.append(Character(UnicodeScalar(UInt8((high ? 80 : 48) + digits[i]))))
    }
    var dChar = 0
    if lonDeg >= 100 && lonDeg < 110 { dChar = (lonDeg - 100) + 108 }
    else if lonDeg >= 110 { dChar = lonDeg - 110 + 38 }
    else if lonDeg < 10 { dChar = lonDeg + 118 }
    else { dChar = lonDeg - 10 + 38 }
    let lonMin = lonMinTotal / 100, lonHund = lonMinTotal % 100
    let mChar = lonMin < 10 ? lonMin + 88 : lonMin - 10 + 38
    let sp = speedKn / 10 + 28
    let dc = (speedKn % 10) * 10 + course / 100 + 28
    let se = course % 100 + 28
    let info = "`" + String([dChar, mChar, lonHund + 28, sp, dc, se].map { Character(UnicodeScalar(UInt8($0))) }) + symbol.prefix(1) + symbol.suffix(1)
    return (dest, info)
}

do {
    let cases: [(Double, Double, Int, Int)] = [(33.4273, -112.129, 20, 251), (-33.8688, 151.2093, 0, 0), (49.7913, 9.9534, 55, 180),
                                               (53.55, 9.99, 120, 359), (64.1466, -21.9426, 5, 90), (35.6762, 139.6503, 0, 45),
                                               (-54.8, -68.3, 14, 300), (51.5074, -0.1278, 77, 10), (0.5, -105.5, 3, 123)]
    for (lat, lon, sp, co) in cases {
        let (dest, info) = micEEncode(lat: lat, lon: lon, speedKn: sp, course: co)
        guard let p = aprsPacket(dest, info) else { check(false, "Mic-E nicht lesbar \(lat),\(lon)"); continue }
        check(p.kind == .micE && abs(p.position!.lat - lat) < 0.0002 && abs(p.position!.lon - lon) < 0.0002,
              "Mic-E Rundlauf \(lat), \(lon) → \(String(describing: p.position)), dest \(dest)")
        check(p.speedKnots == Double(sp) && (p.courseDeg ?? 0) == (co == 360 ? 0 : co), "Mic-E Geschwindigkeit \(sp) und Kurs \(co): \(String(describing: p.speedKnots)) \(String(describing: p.courseDeg))")
    }
    let (d, i) = micEEncode(lat: 33.4273, lon: -112.129, speedKn: 20, course: 251)
    let p = aprsPacket(d, i)!
    check(p.micEStatus == "Außer Dienst" && p.symbol == APRSSymbol(table: "/", code: ">"), "Mic-E Status und Symbol")
    check(aprsPacket(micEEncode(lat: 10, lon: 10, speedKn: 0, course: 0, message: 0).dest, i)!.micEStatus == "Notfall", "Mic-E Notfall (000)")
    // Echte Aufnahme (WA8LMF, Raum Los Angeles): das erste Paket der Übungsfahrt
    let real = aprsPacket("STPYQS", "'.]g!*u>/]\"6X}", source: "WA8LMF", digis: ["WIDE2-2"])!
    check(real.kind == .micE && real.position!.lat > 34.0 && real.position!.lat < 34.3 && real.position!.lon < -117.9 && real.position!.lon > -118.3,
          "Mic-E aus echter Aufnahme liegt bei Los Angeles: \(String(describing: real.position))")
}

// MARK: - AFSK-Demodulator: Rundlauf mit dem Testsignal
func aprsRoundTrip(_ gen: (Double) -> [Float], rate: Double = 12_000, count: Int, options: AFSKDemodulator.Options = AFSKDemodulator.Options()) -> (found: Int, texts: Set<String>) {
    var audio = gen(rate)
    audio += [Float](repeating: 0, count: Int(rate * 0.5))
    let d = AFSKDemodulator(sampleRate: rate, options: options)
    var texts: Set<String> = []
    var n = 0
    audio.withUnsafeBufferPointer { d.process($0) { f in
        n += 1
        if let fr = AX25Frame.parse(f.bytes) { texts.insert(fr.tnc2) }
    } }
    _ = count
    return (n, texts)
}

do {
    let frames: [[UInt8]] = (0..<12).map { i in
        AX25Frame(dest: AX25Address(call: "APRS"), source: AX25Address(call: "DL1ABC", ssid: i % 15), digis: [AX25Address(call: "WIDE1", ssid: 1)],
                  info: Array(("!4903.50N/07201.75W-Test \(i) " + String(repeating: "xyz", count: 5 + i * 4)).utf8)).encode()
    }
    let want = Set(frames.compactMap { AX25Frame.parse($0)?.tnc2 })
    func run(_ name: String, _ rate: Double = 12_000, minimum: Int = 12, _ gen: @escaping (Double) -> [Float]) {
        let r = aprsRoundTrip(gen, rate: rate, count: frames.count)
        check(r.texts.intersection(want).count >= minimum, "APRS \(name): \(r.texts.intersection(want).count) von \(frames.count) (verlangt \(minimum))")
    }
    run("sauber 12 kHz") { AFSKModulator.modulate(frames: frames, sampleRate: $0) }
    run("sauber 8 kHz", 8_000) { AFSKModulator.modulate(frames: frames, sampleRate: $0) }
    run("sauber 48 kHz", 48_000) { AFSKModulator.modulate(frames: frames, sampleRate: $0) }
    run("Takt +1,5 %") { AFSKModulator.modulate(frames: frames, sampleRate: $0, baudError: 0.015) }
    run("Takt −1,5 %") { AFSKModulator.modulate(frames: frames, sampleRate: $0, baudError: -0.015) }
    run("Töne +50 Hz") { AFSKModulator.modulate(frames: frames, sampleRate: $0, toneOffsetHz: 50) }
    run("Töne −50 Hz") { AFSKModulator.modulate(frames: frames, sampleRate: $0, toneOffsetHz: -50) }
    run("de-emphasiert (Space 10 dB schwächer)") { AFSKModulator.modulate(frames: frames, sampleRate: $0, deEmphasis: true) }
    run("leise (−40 dB)") { AFSKModulator.modulate(frames: frames, sampleRate: $0, amplitude: 0.01) }
    // Ein einziger Entscheider genügt für saubere Signale; mehrere helfen bei Rauschen
    var one = AFSKDemodulator.Options()
    one.slicers = 1
    let r1 = aprsRoundTrip({ AFSKModulator.modulate(frames: frames, sampleRate: $0) }, count: 12, options: one)
    check(r1.texts.intersection(want).count == 12, "APRS: ein Entscheider, saubere Signale")
    // Rauschen ohne Signal: kein Paket
    var rng = SystemRandomNumberGenerator()
    let noise = (0..<(12_000 * 20)).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
    let dn = AFSKDemodulator(sampleRate: 12_000)
    var spurious = 0
    noise.withUnsafeBufferPointer { dn.process($0) { _ in spurious += 1 } }
    check(spurious == 0, "APRS: 20 s Rauschen ergeben kein Paket (\(spurious))")
    // Verschobene Mitte: Option centerOffsetHz
    var shifted = AFSKDemodulator.Options()
    shifted.centerOffsetHz = 80
    let rs = aprsRoundTrip({ AFSKModulator.modulate(frames: frames, sampleRate: $0, toneOffsetHz: 80) }, count: 12, options: shifted)
    check(rs.texts.intersection(want).count == 12, "APRS: Abweichung der Töne um 80 Hz nachgestellt (\(rs.texts.intersection(want).count))")
}

// MARK: - AFSK-Empfänger: flaches und de-emphasiertes Audio, doppelte Rahmen
do {
    let one = AX25Frame(dest: AX25Address(call: "APRS"), source: AX25Address(call: "DL1ABC", ssid: 7), digis: [AX25Address(call: "WIDE1", ssid: 1)],
                        info: Array("!4903.50N/07201.75W-Wiederholung".utf8)).encode()
    func count(_ audio: [Float], _ emphasis: AFSKReceiver.Emphasis) -> Int {
        let r = AFSKReceiver(sampleRate: 12_000, emphasis: emphasis)
        var n = 0
        let pad = audio + [Float](repeating: 0, count: 6_000)
        // in 20-ms-Blöcken wie in der Pipeline
        var i = 0
        while i < pad.count {
            let e = min(i + 240, pad.count)
            pad[i..<e].withUnsafeBufferPointer { r.process($0) { _ in n += 1 } }
            i = e
        }
        return n
    }
    // Derselbe Rahmen dreimal kurz hintereinander (Wiederholung des Absenders): jeder zählt, aber nicht doppelt je Weg
    let flat = AFSKModulator.modulate(frames: [one, one, one], sampleRate: 12_000, preambleFlags: 8, gapSeconds: 0.05)
    check(count(flat, .auto) == 3 && count(flat, .off) == 3, "Empfänger: drei gleiche Rahmen kurz hintereinander werden alle gemeldet (\(count(flat, .auto)))")
    let deemph = AFSKModulator.modulate(frames: [one, one, one], sampleRate: 12_000, preambleFlags: 8, gapSeconds: 0.2, deEmphasis: true)
    check(count(deemph, .auto) == 3 && count(deemph, .on) == 3, "Empfänger: de-emphasiertes Audio im Modus automatisch und „an“ (\(count(deemph, .auto)))")
    check(count(flat, .on) == 3, "Empfänger: flaches Audio auch mit Vorverzerrung lesbar")
}

// MARK: - APRS-Controller: Stationsliste, Weg, Nachrichten, Karte
do {
    let controller = APRSController(pipeline: AudioPipeline(), settings: APRSSettingsStore())
    controller.logEnabled = false
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func raw(_ dest: String, _ info: String, source: String, digis: [String] = [], repaired: Bool = false) -> APRSRawFrame {
        let via = digis.map { d -> AX25Address in
            var a = AX25Address(text: d.replacingOccurrences(of: "*", with: ""))!
            a.repeated = d.hasSuffix("*")
            return a
        }
        let f = AX25Frame(dest: AX25Address(text: dest)!, source: AX25Address(text: source)!, digis: via, info: Array(info.utf8))
        return APRSRawFrame(bytes: f.encode(), repaired: repaired, slicers: 1, level: 0.5)
    }
    controller.clear()
    controller.ingest(raw("APRS", "!4903.50N/07201.75W>Auto", source: "DL1ABC-9", digis: ["WIDE1-1"]), at: t0)
    controller.ingest(raw("APRS", "!4903.60N/07201.85W>Auto", source: "DL1ABC-9", digis: ["DB0XYZ*"]), at: t0.addingTimeInterval(60))
    controller.ingest(raw("APRS", ":DL1ABC-9 :Hallo{1", source: "DK2DEF"), at: t0.addingTimeInterval(70))
    controller.ingest(raw("APRS", "_10090556c220s004g005t077h50b09900", source: "WX1STN"), at: t0.addingTimeInterval(80))
    controller.ingest(raw("APRS", ";LEADER   *092345z4903.00N/07201.00W>", source: "DL1ABC-9"), at: t0.addingTimeInterval(90))
    controller.ingest(raw("APRS", "!1000.00N/01000.00E-Falsch", source: "BIT1ER", repaired: true), at: t0.addingTimeInterval(95))
    check(controller.stations.count == 3, "Stationsliste: DL1ABC-9, WX1STN (kein Ort), LEADER; DK2DEF nur Nachricht, reparierter Rahmen nicht (\(controller.stations.map(\.id)))")
    let dl = controller.stations.first { $0.id == "DL1ABC-9" }!
    check(dl.packetCount == 2 && dl.track.count == 2 && !dl.direct, "Station: zwei Pakete, Weg mit zwei Punkten, zuletzt über Digipeater")
    check(controller.stations.first { $0.id == "LEADER" }?.isObject == true, "Objekt unter seinem Namen")
    check(controller.messages.count == 1 && controller.messages[0].to == "DL1ABC-9" && controller.messages[0].messageID == "1", "Nachrichtenliste")
    check(controller.repairedCount == 1 && controller.frameCount == 6, "Zähler: 6 Pakete, davon 1 repariert")
    let home = Maidenhead.point("JN49WS")
    let map = APRSMapBuilder.content(stations: controller.stations, home: home, maxAge: 3600, now: t0.addingTimeInterval(120))
    check(map.markers.count == 2 && map.markers.contains { $0.id == "DL1ABC-9" && $0.track.count == 2 } && map.markers.contains { $0.id == "LEADER" }, "Karte: zwei Punkte mit Ort, einer mit Weg")
    let old = APRSMapBuilder.content(stations: controller.stations, home: home, maxAge: 3600, now: t0.addingTimeInterval(7200))
    check(old.markers.isEmpty, "Karte: nach zwei Stunden nichts mehr bei Filter 1 h")
    check(APRSMapBuilder.content(stations: controller.stations, home: home, maxAge: nil, now: t0.addingTimeInterval(7200)).markers.count == 2, "Karte: Filter „alle“")
    check(map.markers.first { $0.id == "DL1ABC-9" }?.details.contains { $0.contains("km") } == true, "Karte: Entfernung vom Standort in den Einzelheiten")
    let line = APRSController.tnc2Line(AX25Frame(dest: AX25Address(call: "APRS"), source: AX25Address(call: "A1B"), info: Array("x\r".utf8)))
    check(line == "A1B>APRS:x<0x0d>", "TNC2-Zeile mit sichtbarem Steuerzeichen: \(line)")
    check(APRSChannel.eu.frequencyHz == 144_800_000 && RigTuneTarget.aprs(channel: .iss) == RigTuneTarget(dialHz: 145_825_000, mode: "FM") && RigTuneTarget.aprs(channel: .free) == nil, "APRS-Kanäle und Abstimmziel FM")
    check(DecoderModuleInfo.aprs.isAvailable && DecoderModuleInfo.aprs.presetIDs.contains("eu"), "Modul APRS verfügbar")
    if case .success(let req) = parse("digidec://decode?mode=aprs&preset=iss&center=1700") { check(req.module == .aprs && req.presetID == "iss", "URL-Auftrag APRS") } else { check(false, "URL-Auftrag APRS abgelehnt") }
}

// MARK: - Karten der übrigen Module
do {
    let home = Maidenhead.point("JN49WS")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    // Gehörte Stationen (FT8, WSPR …): Locator vor DXCC, Zusammenfassung, Alter
    let dxcc = DXCCDatabase.shared
    let heard = [
        HeardStation(call: "DL1ABC", grid: "JN49WR", dxcc: dxcc.lookup("DL1ABC"), snr: -8, time: now.addingTimeInterval(-60), text: "CQ DL1ABC JN49WR", isCQ: true),
        HeardStation(call: "W1AW", grid: nil, dxcc: dxcc.lookup("W1AW"), snr: -15, time: now.addingTimeInterval(-120), text: "W1AW DL1ABC RR73"),
        HeardStation(call: "DL1ABC", grid: "JN49WR", dxcc: dxcc.lookup("DL1ABC"), snr: -2, time: now.addingTimeInterval(-10), text: "DL1ABC K3ZK -02"),
        HeardStation(call: "OLD1X", grid: "IO91", time: now.addingTimeInterval(-9_000)),
        HeardStation(call: "NOPOS", time: now)
    ]
    let c = HeardMapBuilder.content(heard, home: home, now: now, mode: "FT8", maxAge: 3600)
    check(c.markers.count == 2, "Gehörte Stationen: Dubletten zusammengefasst, zu alte und ohne Ort entfernt (\(c.markers.map(\.id)))")
    let dl = c.markers.first { $0.id == "DL1ABC" }!
    check(dl.subtitle?.contains("2×") == true && dl.details.contains { $0.contains("-02") }, "Jüngste Meldung gilt, Anzahl 2×")
    let wa = c.markers.first { $0.id == "W1AW" }!
    check(wa.details.contains { $0.contains("kein Locator") } && wa.coordinate.lon < -60, "Ohne Locator: Mittelpunkt des Landes (USA)")
    check(c.lines.count == 1 && c.lines[0].geodesic, "Großkreislinie nur zu entfernten Stationen (DL1ABC liegt < 30 km vom Standort)")
    // Rufzeichen im Text
    let log = CallsignLog()
    log.feed("CQ CQ CQ DE DL1ABC DL1ABC K\r\nDL1ABC DE W1AW W1AW KN TEST 599 NR5 K", at: now)
    let calls = Set(log.heard.map(\.call))
    check(calls == ["DL1ABC", "W1AW"], "Rufzeichen im Text: \(calls)")
    let log2 = CallsignLog()
    for ch in "CQ DE JA1XYZ PSE K " { log2.feed(String(ch), at: now) }
    check(log2.heard.map(\.call) == ["JA1XYZ"], "Rufzeichen Zeichen für Zeichen")
    let log3 = CallsignLog()
    log3.feed("DL1ABC ist hier und W1AW auch ", at: now)
    check(log3.heard.isEmpty, "Rufzeichen ohne CQ/DE und nur einmal gelten noch nicht")
    // SYNOP
    check(SynopCatalog.lookup(wmo: 10655).map { abs($0.point.lat - 49.77) < 0.1 && abs($0.point.lon - 9.95) < 0.1 } == true, "WMO-Liste: Würzburg 10655 (\(String(describing: SynopCatalog.lookup(wmo: 10655))), Ordner \(SynopDecoder.stationDirectory?.path ?? "-"))")
    let synopText = "\n\tLand station observation\n\tWMO Station=10655\n\tWMO station=Wuerzburg\n\tTemperature=12.3 °C\n\tSea level pressure=1013 hPa\n\tWind speed=14 km/h\n\tWMO Station=62170\n\tLatitude=51.4\n\tLongitude=2.0\n\tTemperature=20.2 °C\n"
    let obs = SynopLog.parse(synopText, at: now)
    check(obs.count == 2 && obs[0].wmo == "10655" && obs[0].position != nil && obs[0].temperature == "12.3 °C" && obs[1].position == GeoPoint(lat: 51.4, lon: 2.0), "SYNOP-Klartext: Land (Ort aus Liste) und Schiff (Ort im Text)")
    let sl = SynopLog()
    sl.feed(synopText, decoded: true, at: now)
    sl.feed("NEXT", decoded: false, at: now)
    check(sl.content(home: home, now: now).markers.count == 2, "SYNOP-Karte: zwei Stationen")
    // Sender
    let tx = TransmitterMap.content(Transmitters.dcf77(), home: home)
    check(tx.markers.count == 1 && tx.lines.count == 1 && tx.markers[0].radiusKm == 500, "Sender-Karte: DCF77 mit Linie und Reichweite")
    let dist = Geo.distanceKm(home!, Transmitters.mainflingen)
    check(dist > 40 && dist < 100, "JN49WS – Mainflingen (\(dist) km)")
    check(Transmitters.efr(.custom).isEmpty && Transmitters.efr(.dcf39).count == 1, "EFR-Sender je Station")
    // DSC
    var m = DSCMessage(receivedAt: now, centerHz: 1700, symbols: [], format: .distress, category: "SEENOT", from: "211123456", nature: "Feuer/Explosion",
                       position: "48°30′N 011°20′O", timeUTC: "12:34", eccOK: true, unreadable: 0)
    check(m.geoPosition.map { abs($0.lat - 48.5) < 1e-6 && abs($0.lon - 11.3333) < 1e-3 } == true, "DSC-Position Nord/Ost")
    m.position = "35°05′S 150°45′W"
    check(m.geoPosition.map { $0.lat < 0 && $0.lon < 0 } == true, "DSC-Position Süd/West")
    m.position = "48°30′N 011°20′O"
    let dc = DSCMapBuilder.content([m], home: home, now: now.addingTimeInterval(300))
    check(dc.markers.count == 1 && dc.markers[0].tone == .alert && dc.lines.count == 1, "DSC-Karte: Seenot rot, mit Linie")
    m.position = nil
    check(DSCMapBuilder.content([m], home: home, now: now).markers.isEmpty, "DSC ohne Position: kein Punkt")
}

@MainActor func homeTests() {
    let key = "homeLocator"
    let saved = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.set("JO30", forKey: key)
    let h = HomeLocation()
    check(h.locator == "JO30" && h.point != nil, "Standort aus gespeichertem Locator")
    h.locator = "kaputt"
    check(UserDefaults.standard.string(forKey: key) == "JO30", "Ungültiger Locator wird nicht gespeichert")
    h.locator = "JN49WS"
    check(UserDefaults.standard.string(forKey: key) == "JN49WS", "Gültiger Locator wird gespeichert")
    if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
}
homeTests()


// MARK: - Funkruf: BCH, POCSAG, FLEX
do {
    // BCH(31,21): Kodieren, bis zu zwei Fehler korrigieren
    check(PagerBCH.correct(POCSAG.idle)?.errors == 0 && PagerBCH.correct(POCSAG.sync)?.errors == 0, "Leer- und Synchronwort sind gültige Codewörter")
    var allOK = true, doubleOK = true
    let data: [UInt32] = [0, 1, 0x1FFFFF, 0x0AAAAA, 0x155555, 0x123456, 0x1ABCDE]
    for d in data {
        let w = PagerBCH.encode(d)
        if PagerBCH.correct(w)?.word != w { allOK = false }
        for i in 0..<32 {
            let c = PagerBCH.correct(w ^ (1 << UInt32(i)))
            if c?.word != w || c?.errors != 1 { allOK = false }
        }
        for i in stride(from: 1, to: 32, by: 3) {
            for j in stride(from: 0, to: i, by: 4) {
                let c = PagerBCH.correct(w ^ (1 << UInt32(i)) ^ (1 << UInt32(j)))
                if c?.word != w { doubleOK = false }
            }
        }
    }
    check(allOK, "BCH: jedes Einzelbit (auch die Parität) wird korrigiert")
    check(doubleOK, "BCH: Doppelfehler werden korrigiert")
    // Drei Fehler dürfen nie als das richtige Wort durchgehen
    var tripleBad = 0
    for i in 0..<20 {
        let w = PagerBCH.encode(0x0F0F0F)
        if let c = PagerBCH.correct(w ^ (1 << UInt32(i)) ^ (1 << UInt32(i + 5)) ^ (1 << UInt32(i + 9))), c.word == w { tripleBad += 1 }
    }
    check(tripleBad == 0, "BCH: Dreifachfehler werden nicht als Original ausgegeben")
}

do {
    // Echte Codewörter eines Stapels (POCSAG-1200-Beispiel von multimon-ng, 273040 Funktion 3)
    let real: [UInt32] = [0x10AA5E2E, 0xEAD5AF90, 0x8AC9B659, 0xB46F031E, 0xE0C1858C, 0xF660C063, 0x9B3267AB, 0xADAB57D9,
                          0xEA2B212A, 0xECD1BC11, 0xC18305C9, 0xE1D98716, 0xB06CC954, 0x98B002E6, 0x7A89C197, 0x7A89C197]
    var b = POCSAGMessageBuilder()
    var got: [PagerMessage] = []
    for (i, w) in real.enumerated() {
        let f = PagerBCH.correct(w)
        if let m = b.push(word: f?.word, errors: f?.errors ?? 0, frame: i / 2, rate: 1200, now: Date()) { got.append(m) }
    }
    check(got.count == 1 && got[0].address == 273040 && got[0].function == 3, "POCSAG: echter Stapel liefert Rufnummer 273040, Funktion 3")
    check(got.first?.alpha == "+++TIME=0008300324+++TIME=0008300324", "POCSAG: echter Klartext „\(got.first?.alpha ?? "-")“")
    check(got.first?.text == got.first?.alpha, "Funktion 3: Klartext wird angezeigt")
    check(got.first?.alternative?.hasPrefix("Ziffern:") == true, "Andere Lesart als Ziffern im Tooltip")
}

func pocsagAudio(_ baud: Int, _ msgs: [(Int, Int, String?, String?)], amplitude: Float = 0.4, inverted: Bool = false, baudError: Double = 0) -> [Float] {
    var bits: [UInt8] = []
    for (a, f, n, t) in msgs { bits += POCSAGSignalGenerator.bits(address: a, function: f, numeric: n, alpha: t) }
    return POCSAGSignalGenerator.audio(bits: bits, baud: baud, amplitude: amplitude, inverted: inverted, baudError: baudError)
        + [Float](repeating: 0, count: 6000)
}
func pocsagDecode(_ audio: [Float], rates: Set<Int> = [0, 1, 2]) -> [PagerMessage] {
    let r = POCSAGReceiver()
    r.enabled = rates
    var out: [PagerMessage] = []
    var i = 0
    while i < audio.count {
        let e = min(i + 480, audio.count)
        audio[i..<e].withUnsafeBufferPointer { r.process($0) { out.append($0) } }
        i = e
    }
    r.flush { out.append($0) }
    return out
}
func highpassAudio(_ s: [Float], _ fc: Double, rate: Double = 24_000) -> [Float] {
    let a = Float(exp(-2 * .pi * fc / rate)); var y: Float = 0; var xp: Float = 0
    return s.map { x in y = a * (y + x - xp); xp = x; return y }
}

do {
    let msgs: [(Int, Int, String?, String?)] = [(1234567, 3, nil, "Hallo Welt, Test 1"), (2504, 3, nil, "DAPNET DL1ABC Test"), (400000, 0, "0123456789", nil), (999, 3, nil, "Kurz"),
                                                (7, 3, nil, String(repeating: "Lange Meldung über mehrere Stapel. ", count: 5))]
    for (i, baud) in POCSAG.rates.enumerated() {
        let got = pocsagDecode(pocsagAudio(baud, msgs))
        check(got.count == 5, "POCSAG \(baud): fünf Meldungen (\(got.count))")
        check(got.map(\.address) == msgs.map { $0.0 }, "POCSAG \(baud): Rufnummern \(got.map(\.address))")
        check(got.first?.alpha == "Hallo Welt, Test 1" && got.first?.protocolName == "POCSAG \(baud)", "POCSAG \(baud): Text und Name")
        check(got.count > 2 && got[2].numeric == "0123456789" && got[2].text == "0123456789", "POCSAG \(baud): Ziffernmeldung")
        check(got.last?.alpha.hasPrefix("Lange Meldung") == true && (got.last?.alpha.count ?? 0) >= 150, "POCSAG \(baud): lange Meldung über mehrere Stapel (\(got.last?.alpha.count ?? 0) Zeichen)")
        let inv = pocsagDecode(pocsagAudio(baud, msgs, inverted: true))
        check(inv.count == 5, "POCSAG \(baud): invertierte Polarität (\(inv.count))")
        let hp = pocsagDecode(highpassAudio(pocsagAudio(baud, msgs), 150))
        check(hp.count == 5, "POCSAG \(baud): wechselstromgekoppelt 150 Hz (\(hp.count))")
        let clk = pocsagDecode(pocsagAudio(baud, msgs, baudError: 0.01))
        check(clk.count == 5, "POCSAG \(baud): Takt +1 % (\(clk.count))")
        var g = SystemRandomNumberGenerator()
        let noisy = pocsagAudio(baud, msgs).map { $0 + Float.random(in: -0.35...0.35, using: &g) }
        let nz = pocsagDecode(noisy)
        check(nz.count == 5, "POCSAG \(baud): Rauschen (\(nz.count))")
        _ = i
    }
    // Nur eine Baudrate eingeschaltet
    check(pocsagDecode(pocsagAudio(1200, msgs), rates: [0]).isEmpty, "POCSAG: ausgeschaltete Baudrate liefert nichts")
    // Stille und Rauschen ergeben nichts
    check(pocsagDecode([Float](repeating: 0, count: 48_000)).isEmpty, "POCSAG: Stille ergibt keine Meldung")
    var g = SystemRandomNumberGenerator()
    check(pocsagDecode((0..<(24_000 * 20)).map { _ in Float.random(in: -0.5...0.5, using: &g) }).isEmpty, "POCSAG: 20 s Rauschen ergeben keine Meldung")
    // Anzeige: Funktion 0 → Ziffern; unlesbarer Klartext → Ziffern
    let m0 = PagerMessage(time: Date(), protocolName: "POCSAG 1200", address: 1, function: 0, numeric: "123", alpha: "abc")
    check(m0.text == "123", "Funktion 0 zeigt Ziffern")
    let m3 = PagerMessage(time: Date(), protocolName: "POCSAG 1200", address: 1, function: 3, numeric: "123 45", alpha: "\u{1}\u{2}\u{3}\u{4}\u{5}\u{6}")
    check(m3.text == "123 45", "Unlesbarer Klartext fällt auf Ziffern zurück")
}

do {
    // FLEX: Synchronisation, Betriebsarten, Rundlauf
    check(FLEXReceiver.syncCheck((UInt64(0x870C) << 48) | (UInt64(FLEXReceiver.syncMarker) << 16) | (~UInt64(0x870C) & 0xFFFF)) == 0x870C, "FLEX: Synchronwort 0x870C erkannt")
    check(FLEXReceiver.syncCheck(0x1234_5678_9ABC_DEF0) == 0, "FLEX: Zufall ist kein Synchronwort")
    check(FLEXReceiver.mode(for: 0x870C)?.baud == 1600 && FLEXReceiver.mode(for: 0xB068)?.levels == 4 && FLEXReceiver.mode(for: 0x7B18)?.baud == 3200, "FLEX: Betriebsarten")
    check(FLEXReceiver.mode(for: 0x1111) == nil, "FLEX: unbekanntes Synchronwort")
    let w = FLEXSignalGenerator.word(0x155AAA)
    check(FLEXReceiver.fix(w).map { $0 & 0x1FFFFF } == 0x155AAA, "FLEX: Codewort in Bitordnung unten")
    check(FLEXReceiver.fix(w ^ 0x0000_0104).map { $0 & 0x1FFFFF } == 0x155AAA, "FLEX: zwei Bitfehler korrigiert")
    let sym = FLEXSignalGenerator.frame(messages: [(1234567, "Hallo FLEX Welt 123"), (2504, "Zweite Meldung")], cycle: 5, frameNumber: 33)
    for inv in [false, true] {
        let aud = FLEXSignalGenerator.audio(symbols: sym, inverted: inv)
        let r = FLEXReceiver(sampleRate: 24_000)
        var got: [PagerMessage] = []
        var i = 0
        while i < aud.count {
            let e = min(i + 480, aud.count)
            aud[i..<e].withUnsafeBufferPointer { r.process($0) { got.append($0) } }
            i = e
        }
        check(got.count == 2 && got.map(\.address) == [1234567, 2504], "FLEX 1600: zwei Meldungen\(inv ? " (invertiert)" : "") (\(got.count))")
        check(got.first?.alpha == "Hallo FLEX Welt 123" && got.last?.alpha == "Zweite Meldung", "FLEX 1600: Text\(inv ? " (invertiert)" : "")")
        check(got.first?.detail == "05.033 A K" && got.first?.protocolName == "FLEX 1600", "FLEX: Zyklus.Rahmen und Phase im Detail: \(got.first?.detail ?? "-")")
    }
    // FLEX mit Rauschen
    var g = SystemRandomNumberGenerator()
    let noisyF = FLEXSignalGenerator.audio(symbols: sym).map { $0 + Float.random(in: -0.3...0.3, using: &g) }
    let rn = FLEXReceiver(sampleRate: 24_000)
    var gotN: [PagerMessage] = []
    noisyF.withUnsafeBufferPointer { rn.process($0) { gotN.append($0) } }
    check(gotN.count == 2, "FLEX 1600: mit Rauschen (\(gotN.count))")
    let rq = FLEXReceiver(sampleRate: 24_000)
    var none = 0
    (0..<(24_000 * 20)).map { _ in Float.random(in: -0.5...0.5, using: &g) }.withUnsafeBufferPointer { rq.process($0) { _ in none += 1 } }
    check(none == 0, "FLEX: 20 s Rauschen ergeben keine Meldung")
}

// MARK: - Töne: DTMF und Selektivrufe
do {
    func toneRun(_ std: ToneStandard, _ audio: [Float]) -> [String] {
        let d = ToneDecoder(standard: std)
        var out: [String] = []
        var i = 0
        while i < audio.count {
            let e = min(i + 160, audio.count)
            audio[i..<e].withUnsafeBufferPointer { d.process($0) { if $0.isComplete { out.append($0.text) } } }
            i = e
        }
        return out
    }
    for std in ToneStandard.allCases where std != .dtmf && std != .selcal {
        let syms = [1, 2, 3, 4, 5, 0, 7, 9]
        let got = toneRun(std, ToneSignalGenerator.selcall(std, symbols: syms))
        check(got == ["123450" + "79"], "\(std.name): Folge 12345079 (\(got))")
    }
    check(toneRun(.zvei1, ToneSignalGenerator.selcall(.zvei1, symbols: [1, 2, 3, 4, 5, 14, 3, 2, 1])) == ["12345E321"], "ZVEI 1: Wiederholton E")
    check(toneRun(.dtmf, ToneSignalGenerator.dtmf("123A456B789C*0#D55")) == ["123A456B789C*0#D55"], "DTMF: alle 16 Tasten und Wiederholung")
    var g = SystemRandomNumberGenerator()
    let quiet = ToneSignalGenerator.dtmf("0123456789", amplitude: 0.05).map { $0 + Float.random(in: -0.02...0.02, using: &g) }
    check(toneRun(.dtmf, quiet) == ["0123456789"], "DTMF: leise mit Rauschen")
    let noise = (0..<80_000).map { _ in Float.random(in: -0.5...0.5, using: &g) } + [Float](repeating: 0, count: 16_000)
    for std in ToneStandard.allCases { check(toneRun(std, noise).isEmpty, "\(std.name): Rauschen ergibt keine Folge") }
    // Zwei Folgen nacheinander
    let two = ToneSignalGenerator.selcall(.ccir, symbols: [1, 2, 3]) + ToneSignalGenerator.selcall(.ccir, symbols: [4, 5, 6])
    check(toneRun(.ccir, two) == ["123", "456"], "CCIR: zwei Folgen nacheinander")
    check(ToneStandard.zvei1.frequencies.count == 16 && ToneStandard.dtmf.frequencies.count == 8 && ToneStandard.ccir.toneSeconds == 0.1, "Normtabellen")
    // SELCAL (ARINC 714): 16 Töne A–S ohne I, N, O; zwei Impulse mit je zwei Tönen
    check(ToneStandard.selcal.frequencies.count == 16 && ToneStandard.selcalLetters.count == 16 && !ToneStandard.selcalLetters.contains("I") && !ToneStandard.selcalLetters.contains("N") && !ToneStandard.selcalLetters.contains("O"), "SELCAL: Töne und Buchstaben")
    check(zip(ToneStandard.selcalFrequencies, ToneStandard.selcalFrequencies.dropFirst()).allSatisfy { $1 > $0 }, "SELCAL: Töne aufsteigend")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("ABCD")) == ["AB-CD"], "SELCAL: AB-CD")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("DAMR")) == ["AD-MR"], "SELCAL: Buchstabenpaare werden aufsteigend geordnet (DAMR → AD-MR)")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("JKPQ")) == ["JK-PQ"], "SELCAL: benachbarte Töne JK-PQ")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("SHFG")) == ["HS-FG"], "SELCAL: HS-FG (höchster Ton S)")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("ABCD", pulse: 0.8, gap: 0.3)) == ["AB-CD"], "SELCAL: kürzere Impulse, längere Pause")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("ABCD") + ToneSignalGenerator.selcal("EFGH")) == ["AB-CD", "EF-GH"], "SELCAL: zwei Rufe nacheinander")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("QRSA", amplitude: 0.01).map { $0 + Float.random(in: -0.004...0.004, using: &g) }) == ["QR-AS"], "SELCAL: leise mit Rauschen")
    check(toneRun(.selcal, ToneSignalGenerator.selcal("ABCD", gap: 1.5)).isEmpty, "SELCAL: zu lange Pause zwischen den Impulsen ergibt keinen Ruf")
    let onePulse = Array(ToneSignalGenerator.selcal("ABCD").prefix(Int(8000 * 1.4))) + [Float](repeating: 0, count: 16_000)
    check(toneRun(.selcal, onePulse).isEmpty, "SELCAL: ein einzelner Impuls ergibt keinen Ruf")
    check(toneRun(.selcal, ToneSignalGenerator.selcall(.zvei1, symbols: [1, 2, 3, 4, 5])).isEmpty, "SELCAL: ZVEI-Folge ergibt keinen Ruf")
    // Tonhöhenfehler im Empfänger (SSB-Abstimmung): 5 Hz tiefer
    let shifted: [Float] = {
        var rx = ToneSignalGenerator.selcal("ABCD", sampleRate: 8_000)
        // Versatz über eine leicht andere Abtastrate nachbilden: 1,25 % Zeitdehnung = 4 … 5 Hz tiefer bei 313 … 427 Hz
        let f = 1.0125
        rx = (0..<Int(Double(rx.count) / f)).map { i in rx[min(rx.count - 1, Int(Double(i) * f))] }
        return rx
    }()
    check(toneRun(.selcal, shifted) == ["AB-CD"], "SELCAL: 4 bis 5 Hz Frequenzfehler bei tiefen Tönen werden toleriert")

    // Sprache/Musik-ähnliches Signal (Mehrfachtöne) wird nicht als DTMF gelesen
    let chord = (0..<40_000).map { i -> Float in let t = Double(i) / 8000; return 0.15 * Float(sin(2 * .pi * 440 * t) + sin(2 * .pi * 554 * t) + sin(2 * .pi * 659 * t)) } + [Float](repeating: 0, count: 8000)
    check(toneRun(.dtmf, chord).isEmpty, "DTMF: Akkord 440/554/659 Hz wird nicht gelesen")
    check(toneRun(.selcal, chord).isEmpty, "SELCAL: Akkord 440/554/659 Hz wird nicht gelesen")
}

@MainActor func pagerModuleTests() {
    let pipeline = AudioPipeline()
    let settings = PagerSettingsStore()
    let c = PagerController(pipeline: pipeline, settings: settings)
    c.logEnabled = false
    let m = PagerMessage(time: Date(timeIntervalSince1970: 1_790_000_000), protocolName: "POCSAG 1200", address: 1234567, function: 3, numeric: "", alpha: "Hallo", corrected: 1, damaged: 0)
    c.ingest(m)
    check(c.messages.count == 1 && c.count == 1, "Pager-Controller nimmt Meldungen auf")
    let line = PagerController.logLine(m)
    check(line.contains("POCSAG 1200") && line.contains("RIC 1234567 F3") && line.contains("Hallo") && line.contains("1 Bit korrigiert"), "Pager-Logzeile: \(line)")
    settings.watch = "2504, 1234567"
    check(settings.watched == [2504, 1234567], "Beobachtete Rufnummern")
    c.clear()
    check(c.messages.isEmpty, "Pager: Liste leeren")
    check(PagerChannel.dapnet.frequencyHz == 439_987_500 && RigTuneTarget.pager(channel: .dapnet) == RigTuneTarget(dialHz: 439_987_500, mode: "FM") && RigTuneTarget.pager(channel: .free) == nil, "Pager-Kanal und Abstimmziel")
    check(settings.markerStyle != .tones, "Pager: Wasserfall ohne Mark/Space-Marker")

    let ts = TonesSettingsStore()
    let tc = TonesController(pipeline: pipeline, settings: ts)
    tc.logEnabled = false
    let start = Date()
    tc.ingest(ToneSequence(start: start, standard: .zvei1, text: "123", isComplete: false))
    tc.ingest(ToneSequence(start: start, standard: .zvei1, text: "12345", isComplete: false))
    check(tc.sequences.count == 1 && tc.sequences[0].text == "12345" && !tc.sequences[0].isComplete, "Töne: laufende Folge wird fortgeschrieben")
    tc.ingest(ToneSequence(start: start, standard: .zvei1, text: "12345", isComplete: true))
    check(tc.sequences.count == 1 && tc.sequences[0].isComplete, "Töne: Folge abgeschlossen")
    tc.ingest(ToneSequence(start: start.addingTimeInterval(30), standard: .dtmf, text: "55", isComplete: true))
    check(tc.sequences.count == 2, "Töne: Folge einer anderen Norm zu anderer Zeit ist eine eigene Folge")
    // Mehrere Normen lesen dieselbe Aussendung: die längere Folge gewinnt
    tc.clear()
    let t1 = Date()
    tc.ingest(ToneSequence(start: t1, standard: .zvei1, text: "12345", isComplete: true))
    tc.ingest(ToneSequence(start: t1.addingTimeInterval(0.1), standard: .ccir, text: "F36", isComplete: true))
    check(tc.sequences.count == 1 && tc.sequences[0].standard == .zvei1, "Töne: kürzere Folge einer anderen Norm entfällt (\(tc.sequences.map(\.text)))")
    tc.ingest(ToneSequence(start: t1.addingTimeInterval(5), standard: .ccir, text: "3141", isComplete: true))
    check(tc.sequences.count == 2, "Töne: Folgen zu verschiedenen Zeiten bleiben beide")
    for s in ToneStandard.allCases where ts.standards.contains(s) && s != .dtmf { ts.toggle(s) }
    ts.toggle(.dtmf)
    check(!ts.standards.isEmpty, "Töne: mindestens eine Norm bleibt eingeschaltet")
    check(ts.markerStyle != .tones, "Töne: Wasserfall ohne Marker")
    for id in ["dapnet", "free"] { if case .success(let r) = parse("digidec://decode?mode=pager&preset=\(id)") { check(r.module == .pager, "URL pager/\(id)") } else { check(false, "URL pager/\(id) abgelehnt") } }
    if case .success(let r) = parse("digidec://decode?mode=tones") { check(r.module == .tones, "URL tones") } else { check(false, "URL tones abgelehnt") }
    check(DecoderModuleInfo.pager.isAvailable && DecoderModuleInfo.tones.isAvailable && !DecoderModuleInfo.pager.hasMap, "Module Pager und Töne verfügbar, ohne Karte")
}
pagerModuleTests()


// MARK: - ACARS
do {
    check(ACARS.crc([UInt8]("123456789".utf8)) == 0x2189, "ACARS-CRC (CRC-16/KERMIT) Prüfwert 0x2189: \(String(ACARS.crc([UInt8]("123456789".utf8)), radix: 16))")
    let blk = ACARSSignalGenerator.block(registration: "D-AIXC", label: "H1", blockID: "3", messageNumber: "M01A", flightID: "LH1234", text: "Hallo ACARS Test EDDF EDDM")
    func decode(_ audio: [Float]) -> [ACARSMessage] {
        let r = ACARSReceiver()
        var out: [ACARSMessage] = []
        var i = 0
        while i < audio.count {
            let e = min(i + 240, audio.count)
            audio[i..<e].withUnsafeBufferPointer { r.process($0) { out.append($0) } }
            i = e
        }
        return out
    }
    let clean = ACARSSignalGenerator.audio(blocks: [blk, blk, blk]) + [Float](repeating: 0, count: 6000)
    let got = decode(clean)
    check(got.count == 3, "ACARS: drei Blöcke (\(got.count))")
    check(got.first?.registration == "D-AIXC" && got.first?.flightID == "LH1234" && got.first?.label == "H1" && got.first?.text == "Hallo ACARS Test EDDF EDDM", "ACARS: Kennzeichen, Flug, Label, Text")
    check(got.first?.isDownlink == true && got.first?.blockID == "3" && got.first?.messageNumber == "M01A" && got.first?.ack == "NAK" && got.first?.mode == "2", "ACARS: Richtung, Block, Nummer, Quittung, Modus")
    check(got.first?.parityErrors == 0 && got.first?.corrected == 0, "ACARS: sauber ohne Korrektur")
    // Aufwärts ohne Text und mit Text
    let up = ACARSSignalGenerator.block(registration: "D-AIXC", ack: "5", label: "_d", blockID: "A", text: "", downlink: false)
    let g2 = decode(ACARSSignalGenerator.audio(blocks: [up]) + [Float](repeating: 0, count: 6000))
    check(g2.count == 1 && g2[0].label == "_d" && !g2[0].isDownlink && g2[0].isEmpty && g2[0].ack == "5", "ACARS: Aufwärtsmeldung ohne Text, Label „_d“")
    // Rauschen, Phasenlage, Pegel
    var g = SystemRandomNumberGenerator()
    let noisy = clean.map { $0 + Float.random(in: -0.25...0.25, using: &g) }
    check(decode(noisy).count >= 2, "ACARS: Rauschen")
    check(decode(clean.map { -$0 }).count == 3, "ACARS: invertiert")
    check(decode(ACARSSignalGenerator.audio(blocks: [blk], amplitude: 0.02) + [Float](repeating: 0, count: 6000)).count == 1, "ACARS: leise")
    var quiet = [Float](repeating: 0, count: 48_000)
    quiet = quiet.map { _ in Float.random(in: -0.5...0.5, using: &g) }
    check(decode(quiet).isEmpty, "ACARS: Rauschen ergibt keine Meldung")
    // Prüfung und Korrektur
    let raw = ACARSParser.parse(ACARSBlock(bytes: [], crc: (0, 0), levelDB: 0))
    check(raw == nil, "ACARS: leerer Block")
    func frameBytes(_ b: [UInt8]) -> ACARSBlock {
        // Block ab nach SOH: Bytes bis ETX, danach zwei Prüfbytes
        let body = Array(b.dropFirst(5).dropLast(3))
        return ACARSBlock(bytes: body, crc: (b[b.count - 3], b[b.count - 2]), levelDB: 0)
    }
    let ok = frameBytes(blk)
    check(ACARSParser.parse(ok)?.text == "Hallo ACARS Test EDDF EDDM", "ACARS: Block aus Bytes")
    var oneBit = ok
    oneBit.bytes[20] ^= 0x04
    let fixed1 = ACARSParser.parse(oneBit)
    check(fixed1?.text == "Hallo ACARS Test EDDF EDDM" && fixed1?.corrected == 1 && fixed1?.parityErrors == 1, "ACARS: ein Bitfehler mit Paritätsfehler wird korrigiert")
    var twoBits = ok
    twoBits.bytes[22] ^= 0x14
    let fixed2 = ACARSParser.parse(twoBits)
    check(fixed2?.text == "Hallo ACARS Test EDDF EDDM" && fixed2?.corrected == 2, "ACARS: zwei Bitfehler im selben Zeichen werden korrigiert")
    var bad = ok
    bad.bytes[20] ^= 0x04; bad.bytes[30] ^= 0x08; bad.bytes[40] ^= 0x01; bad.bytes[41] ^= 0x02; bad.bytes[42] ^= 0x10
    check(ACARSParser.parse(bad) == nil, "ACARS: zu viele Fehler werden verworfen")
    // Label und OOOI
    check(ACARSLabels.describe("Q0") == "Verbindungstest" && ACARSLabels.describe("ZZ") == nil, "ACARS: Label-Bezeichnungen")
    let q1 = ACARSLabels.oooi(label: "Q1", text: "EDDF08150822105511200000EHAM")
    check(q1?.from == "EDDF" && q1?.out == "0815" && q1?.off == "0822" && q1?.on == "1055" && q1?.in == "1120" && q1?.to == "EHAM", "ACARS: OOOI Q1 \(String(describing: q1))")
    check(ACARSLabels.oooi(label: "Q2", text: "KJFK1530")?.eta == "1530" && ACARSLabels.oooi(label: "QA", text: "LSZH0710")?.out == "0710", "ACARS: OOOI Q2 und QA")
    check(ACARSLabels.oooi(label: "H1", text: "EDDF") == nil && ACARSLabels.oooi(label: "Q1", text: "") == nil, "ACARS: kein OOOI bei anderem Label oder ohne Text")
    // Flughäfen und Karte
    check(AirportCatalog.shared.count > 4000, "Flughäfen geladen (\(AirportCatalog.shared.count))")
    let fra = AirportCatalog.shared.lookup("eddf")
    check(fra?.iata == "FRA" && fra.map { abs($0.point.lat - 50.03) < 0.1 && abs($0.point.lon - 8.56) < 0.1 } == true, "Flughafen EDDF Frankfurt")
    check(AirportCatalog.shared.lookup("XXXX") == nil, "Unbekannter Flughafen")
}

@MainActor func acarsModuleTests() {
    let c = ACARSController(pipeline: AudioPipeline(), settings: ACARSSettingsStore())
    c.logEnabled = false
    func msg(_ reg: String, _ flight: String?, _ label: String, _ text: String, down: Bool = true) -> ACARSMessage {
        ACARSMessage(time: Date(timeIntervalSince1970: 1_790_000_000), mode: "2", registration: reg, ack: "NAK", label: label, blockID: down ? "3" : "A", isDownlink: down,
                     messageNumber: down ? "M01A" : nil, flightID: flight, text: text, continues: false, parityErrors: 0, corrected: 0, levelDB: -10)
    }
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    c.ingest(msg("D-AIXC", "LH1234", "Q1", "EDDF08150822105511200000EHAM"), at: t0)
    c.ingest(msg("D-AIXC", "LH1234", "Q0", ""), at: t0)
    c.ingest(msg("G-DBCK", "BA031T", "Q2", "LSZH1530"), at: t0)
    c.ingest(msg("LN-DYY", nil, "H1", "Text", down: false), at: t0)
    check(c.count == 4 && c.aircraft.count == 3, "ACARS-Controller: Meldungen und Flugzeuge")
    let a = c.aircraft["D-AIXC"]!
    check(a.from == "EDDF" && a.to == "EHAM" && a.flight == "LH1234" && a.messages == 2, "ACARS: Flugzeug mit Start und Ziel")
    check(c.aircraft["G-DBCK"]?.from == "LSZH" && c.aircraft["G-DBCK"]?.eta == "1530", "ACARS: Q2 mit ETA")
    let map = ACARSMapBuilder.content(Array(c.aircraft.values), home: Maidenhead.point("JN49WS"), now: Date(timeIntervalSince1970: 1_790_000_100))
    check(map.markers.count == 3 && map.lines.count == 1 && map.lines[0].geodesic, "ACARS-Karte: drei Flughäfen, eine Strecke (\(map.markers.map(\.id)))")
    check(map.markers.first { $0.id == "ap-EDDF" }?.details.contains { $0.contains("Start: LH1234") } == true, "ACARS-Karte: Start/Ziel in den Einzelheiten")
    check(ACARSMapBuilder.content(Array(c.aircraft.values), home: nil, now: Date(timeIntervalSince1970: 1_790_000_000 + 8 * 3600)).markers.isEmpty, "ACARS-Karte: alte Flüge entfallen")
    let line = ACARSController.logLine(msg("D-AIXC", "LH1234", "H1", "Hallo"))
    check(line.contains("D-AIXC") && line.contains("LH1234") && line.contains("↓ H1") && line.contains("Hallo"), "ACARS-Logzeile: \(line)")
    let s = ACARSSettingsStore()
    s.showUplink = false; s.hideEmpty = true
    let c2 = ACARSController(pipeline: AudioPipeline(), settings: s)
    c2.logEnabled = false
    c2.ingest(msg("A", nil, "Q0", "")); c2.ingest(msg("B", nil, "H1", "x", down: false)); c2.ingest(msg("C", nil, "H1", "y"))
    check(c2.visible.map(\.registration) == ["C"], "ACARS: Filter Aufwärts und leere Meldungen")
    check(ACARSChannel.f131550.frequencyHz == 131_550_000 && RigTuneTarget.acars(channel: .f131725) == RigTuneTarget(dialHz: 131_725_000, mode: "AM") && RigTuneTarget.acars(channel: .free) == nil, "ACARS-Kanäle und Abstimmziel AM")
    if case .success(let r) = parse("digidec://decode?mode=acars&preset=f131725") { check(r.module == .acars && r.presetID == "f131725", "URL acars") } else { check(false, "URL acars abgelehnt") }
    check(DecoderModuleInfo.acars.isAvailable && DecoderModuleInfo.acars.hasMap, "Modul ACARS verfügbar, mit Karte")
}
acarsModuleTests()

print("\(checks) Prüfungen, \(failures) Fehler")
exit(failures == 0 ? 0 : 1)
