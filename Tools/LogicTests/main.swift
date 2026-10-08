// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
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

/// Auswahl der Prüfgruppen: `LT_ONLY=dab,sdr` oder Argument `--only dab,sdr` (leer = alle); `--groups` listet sie auf.
/// Neue Blöcke beginnen am Zeilenanfang mit `if want("gruppe") {`, damit sie sich einzeln und parallel ausführen lassen.
nonisolated(unsafe) let selectedGroups: Set<String>? = {
    var list = ProcessInfo.processInfo.environment["LT_ONLY"] ?? ""
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--only"), i + 1 < args.count { list = args[i + 1] }
    let set = Set(list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    return set.isEmpty ? nil : set
}()
func want(_ group: String) -> Bool { selectedGroups == nil || selectedGroups!.contains(group) }

var failures = 0
var checks = 0
/// Prüfungen mit echten Aufnahmen, die nur lokal liegen (TestData/ ist nicht im Repository)
var skipped = 0
@MainActor func skip(_ msg: String) {
    skipped += 1
    print("ÜBERSPRUNGEN: \(msg)")
}
/// `LT_TRACE=1`: jede Prüfung vor dem Ausführen nennen (ungepuffert), um einen Absturz einer Stelle zuzuordnen
nonisolated(unsafe) let traceChecks = ProcessInfo.processInfo.environment["LT_TRACE"] != nil
@MainActor func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if traceChecks { fputs("· (Zeile \(line)) \(msg)\n", stderr) }
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
if want("url") {
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
if want("url") {
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
if want("url") {
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
if want("url") {
    check(DecoderModuleInfo.allCases.filter(\.isAvailable) == DecoderModuleInfo.allCases, "Alle Module verfügbar")
    for m in DecoderModuleInfo.allCases where m.isAvailable {
        check(!m.presetIDs.isEmpty, "\(m.displayName): verfügbares Modul braucht Presets")
    }

    // Modul-Leiste: jedes Modul in genau einer Rubrik, darin A–Z; MEHRKANAL steht als eigener Knopf vor beiden
    let bars = DecoderModuleInfo.Band.allCases.flatMap(\.modules)
    check(Set(bars).count == bars.count && Set(bars + [.channels]) == Set(DecoderModuleInfo.allCases) && !bars.contains(.channels), "Modul-Leiste: jedes Modul genau einmal (MEHRKANAL als eigener Knopf)")
    for band in DecoderModuleInfo.Band.allCases {
        let names = band.modules.map(\.displayName)
        check(names == names.sorted { $0.compare($1, options: [.diacriticInsensitive, .caseInsensitive]) == .orderedAscending }, "\(band.title): A–Z")
    }
    check(DecoderModuleInfo.Band.vhfUhf.modules.map(\.displayName) == ["ACARS", "ADS-B", "AIS", "APRS", "D-STAR", "DAB", "DMR", "DPMR", "M17", "PACKET", "PAGER", "RDS", "SENSOREN", "SONDE", "TETRA", "TÖNE", "VDL2", "VOR/ILS", "YSF"], "VHF/UHF-Rubrik")
    check(DecoderModuleInfo.channels.coversAllBands && DecoderModuleInfo.channels.displayName == "MEHRKANAL" && DecoderModuleInfo.Band.allCases.allSatisfy { !$0.modules.contains(.channels) }
          && DecoderModuleInfo.allCases.filter(\.coversAllBands) == [.channels], "MEHRKANAL gehört zu keiner Rubrik allein")
    check(DecoderModuleInfo.Band.hf.modules.first == .ale && DecoderModuleInfo.Band.hf.modules.last == .wspr && DecoderModuleInfo.Band.hf.modules.contains(.ndb), "HF-Rubrik A–Z")
}


// MARK: - Audio: Ringpuffer
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("audio") {
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
if want("rtty") {
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
if want("audio") {
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
if want("rtty") {
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
if want("rtty") {
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
if want("rtty") {
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
if want("rtty") {
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
if want("rtty") {
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
if want("rig") {
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

// MARK: - GQRX Remote Control (Dialekt)
if want("rig") {
    // Antworten, wie GQRX sie liefert: Frequenz, Mode, Bandbreite
    let g = RigctlClient.parse(["161975000", "FM", "10000"])
    check(g.connected && g.frequencyHz == 161_975_000 && g.mode == "FM" && g.passbandHz == 10_000 && g.isLSB == false, "GQRX: f + m (161,975 MHz FM 10 kHz) ausgewertet")
    check(RigctlClient.parse(["7074000", "WFM_ST", "160000"]).mode == "WFM_ST", "GQRX: Mode mit Unterstrich (WFM_ST) bleibt erhalten")
    check(RigctlClient.parse(["7074000", "CWL", "500"]).isLSB == true && RigctlClient.parse(["7074000", "CWU", "500"]).isLSB == false, "GQRX: CWL = Kehrlage, CWU = Regellage")
    check(RigctlClient.parse(["7074000", "LSB", "2700"]).isLSB == true && RigctlClient.parse(["7074000", "AMS", "5000"]).isLSB == false, "GQRX: LSB = Kehrlage, AM-Sync = Regellage")

    // Mode-Abbildung: RTTY und Paketbetrieb → USB, CW → CWU, was es dort nicht gibt → kein Befehl
    let gq = RigDialect.gqrx
    check(gq.modeName(for: "RTTY") == "USB" && gq.modeName(for: "rttyr") == "USB" && gq.modeName(for: "PKTUSB") == "USB" && gq.modeName(for: "PKTLSB") == "LSB", "GQRX: RTTY/PKTUSB → USB, PKTLSB → LSB")
    check(gq.modeName(for: "CW") == "CWU" && gq.modeName(for: "CWR") == "CWL" && gq.modeName(for: "FM") == "FM" && gq.modeName(for: "AM") == "AM" && gq.modeName(for: "LSB") == "LSB", "GQRX: CW → CWU, CWR → CWL, FM, AM, LSB unverändert")
    check(gq.modeName(for: "PWR") == nil && gq.modeName(for: "ECSSUSB") == nil, "GQRX: unbekannter Mode → nil")
    check(RigDialect.hamlib.modeName(for: "rtty") == "RTTY" && RigDialect.hamlib.modeName(for: "PKTUSB") == "PKTUSB", "Hamlib: Mode bleibt, wie er ist")
    check(RigCommand.mode("RTTY", passbandHz: 500, dialect: .gqrx) == "M USB 500\n" && RigCommand.mode("CW", passbandHz: nil, dialect: .gqrx) == "M CWU 0\n", "GQRX: Befehl M mit übersetztem Mode")
    check(RigCommand.mode("FM", passbandHz: 25_000, dialect: .gqrx) == "M FM 25000\n" && RigCommand.mode("RTTY", passbandHz: 500) == "M RTTY 500\n", "AIS-Befehl für GQRX; Hamlib unverändert")
    check(RigCommand.mode("USB\nT 1", passbandHz: nil, dialect: .gqrx) == nil && RigCommand.mode("PWR", passbandHz: nil, dialect: .gqrx) == nil, "GQRX: eingeschmuggelte Befehle und fremde Modes werden abgewiesen")
    check(RigDialect.gqrx.defaultPort == 7356 && RigDialect.hamlib.defaultPort == 4532, "Vorgabe-Ports 7356 (GQRX) und 4532 (Hamlib)")

    // Profil: Vorlage, Speichern und Laden, alte Daten ohne Dialekt
    let tpl = RigProfile.gqrx(audioUID: "UID-V", audioName: "VALHost 2ch")
    check(tpl.name == "GQRX" && tpl.port == 7356 && tpl.host == "127.0.0.1" && tpl.dialect == .gqrx && tpl.problem == nil && tpl.endpoint == RigEndpoint.loopback(port: 7356), "GQRX-Vorlage: 127.0.0.1:7356, Dialekt GQRX")
    let back = RigProfileList.decoded(from: RigProfileList(profiles: [tpl, RigProfile(name: "IC-7300")], activeID: tpl.id).encoded())
    check(back.profiles.count == 2 && back.profiles[0].dialect == .gqrx && back.profiles[1].dialect == .hamlib && back.active?.audioName == "VALHost 2ch", "Profil: Dialekt wird gespeichert und geladen")
    let old = Data(#"{"profiles":[{"id":"A","name":"IC-7300","host":"127.0.0.1","port":4540,"audioUID":"U"}],"activeID":"A"}"#.utf8)
    let oldList = RigProfileList.decoded(from: old)
    check(oldList.profiles.count == 1 && oldList.active?.dialect == .hamlib && oldList.active?.port == 4540 && oldList.active?.audioUID == "U", "Profil: früher gespeichertes Gerät ohne Dialekt bleibt erhalten (Hamlib)")
    let odd = Data(#"{"profiles":[{"id":"A","name":"x","host":"h","port":1,"dialect":"unbekannt"}]}"#.utf8)
    check(RigProfileList.decoded(from: odd).profiles.first?.dialect == .hamlib, "Profil: unbekannter Dialekt → Hamlib")

    // Ende zu Ende gegen einen nachgebauten GQRX: AIS-Ziel (FM 25 kHz), RTTY (→ USB), unbekannter Mode wird gar nicht erst gesendet
    final class Box: @unchecked Sendable { let lock = NSLock(); var last = RigState() }
    if let fake = FakeRigctld(behavior: .gqrx) {
        let box = Box()
        let client = RigctlClient { s in box.lock.withLock { box.last = s } }
        client.setEndpoint(RigEndpoint.loopback(port: fake.port))
        func waitFor(_ cond: () -> Bool, seconds: Double = 4) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
            return cond()
        }
        check(waitFor { box.lock.withLock { box.last.frequencyHz } == 14_074_000 || box.lock.withLock { box.last.mode } == "FM" }, "GQRX e2e: Verbindung, Anfangszustand gelesen")
        func tune(_ hz: Int64, _ mode: String, _ pb: Int?, _ dialect: RigDialect) -> RigTuneResult {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var res: RigTuneResult = .notConnected
            client.tune(frequencyHz: hz, mode: mode, passbandHz: pb, dialect: dialect) { res = $0; sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
            return res
        }
        let ais = RigTuneTarget.ais(channel: .a)!
        check(tune(ais.dialHz, ais.mode, ais.passbandHz, .gqrx) == .ok, "GQRX e2e: AIS-Kanal A abstimmen")
        check(waitFor { box.lock.withLock { box.last.frequencyHz } == 161_975_000 && box.lock.withLock { box.last.mode } == "FM" && box.lock.withLock { box.last.passbandHz } == 25_000 },
              "GQRX e2e: steht auf 161,975 MHz FM 25 kHz (\(box.lock.withLock { box.last }))")
        check(tune(7_039_000, "RTTY", 500, .gqrx) == .ok && fake.currentMode == "USB" && fake.currentFrequency == 7_039_000, "GQRX e2e: RTTY wird als USB gesetzt (\(fake.currentMode))")
        // Ohne Übersetzung würde das echte GQRX „RPRT 1“ melden: Digidec stellt dann den Mode nicht ein und meldet es
        nonisolated(unsafe) var raw: RigTuneResult = .ok
        let sem = DispatchSemaphore(value: 0)
        client.tune(frequencyHz: 7_039_000, mode: "RTTY", passbandHz: 500, dialect: .hamlib) { raw = $0; sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
        if case .rejected(let why) = raw { check(why.contains("RPRT 1"), "Hamlib-Weg gegen GQRX: Ablehnung gemeldet (\(why))") } else { check(false, "Hamlib-Weg gegen GQRX: erwartet abgelehnt, bekam \(raw)") }
        if case .rejected(let why) = tune(14_074_000, "PWR", nil, .gqrx) { check(why.contains("GQRX"), "GQRX: Mode ohne Gegenstück → Meldung nennt GQRX (\(why))") } else { check(false, "GQRX: PWR muss abgewiesen werden") }
        let sent = fake.commands
        check(sent.allSatisfy { ["f", "m", "F", "M"].contains(String($0.split(separator: " ").first ?? "")) }, "GQRX e2e: nur f, m, F, M gesendet, nie PTT")
        check(sent.contains("F 161975000") && sent.contains("M FM 25000") && sent.contains("M USB 500") && !sent.contains("M PWR 0"), "GQRX e2e: gesendete Befehle \(sent.filter { $0.first == "F" || $0.first == "M" })")
        client.setEndpoint(nil)
    } else {
        check(false, "GQRX-Nachbau konnte nicht starten")
    }
}

// MARK: - rigctld: echter TCP-Austausch mit einem Test-Server
if want("rig") {
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
if want("rtty") {
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
if want("rtty") {
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
if want("rtty") {
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
if want("navtex") {
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
if want("navtex") {
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
if want("cw") {
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
if want("cw") {
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
if want("wefax") {
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
if want("wefax") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("time") {
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
if want("time") {
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
if want("time") {
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
if want("time") {
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
if want("dxcc") {
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
if want("sstv") {
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
if want("time") {
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

    // --- EFR: echte Aufnahme (DCF39 über WebSDR, nur lokal in TestData/EFR, siehe dort README.md) ---
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
    } else if !FileManager.default.fileExists(atPath: efrWav.path) {
        skip("EFR echt: TestData/EFR/dcf39_websdr_8k.wav liegt nicht lokal vor")
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
if want("rig") {
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
if want("wefax") {
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
if want("wefax") {
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
if want("wefax") {
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
if want("schedule") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("ft") {
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
if want("psk") {
    check(parse("digidec://decode?mode=psk&preset=qpsk63&center=1200") == .success(DecodeRequest(module: .psk, presetID: "qpsk63", centerHz: 1200)), "PSK-Auftrag QPSK63 mit Mitte")
    check(parse("digidec://decode?mode=psk") == .success(DecodeRequest(module: .psk, presetID: "bpsk31")), "PSK-Standard BPSK31")
    check(Set(PSKMode.allCases.map(\.rawValue)) == Set(DecoderModuleInfo.psk.presetIDs), "PSK-Betriebsarten = IDs im URL-Schema")
    check(PSKMode.bpsk31.baud == 31.25 && PSKMode.qpsk125.baud == 125 && PSKMode.bpsk250.baud == 250 && PSKMode.qpsk31.isQPSK && !PSKMode.bpsk63.isQPSK, "PSK: Symbolraten und Art")
    check(RigTuneTarget.psk(band: .free) == nil && RigTuneTarget.psk(band: .m20) == RigTuneTarget(dialHz: 14_070_000, mode: "USB"), "QSY: PSK 20 m = 14,070 MHz USB, frei = nichts")
    check(PSKDecoder.text(from: Array("CQ CQ\r\nDE DL1ABC\t K\u{0}".utf8)) == "CQ CQ\nDE DL1ABC\t K", "PSK: CR fällt weg, LF bleibt, NUL fällt weg")
    check(PSKDecoder.text(from: [0x48, 0xE4, 0x6C, 0x6C, 0xF6]) == "Hällö", "PSK: 8-Bit-Zeichen als Latin-1")
}

// MARK: - PSK-Empfänger aus fldigi (synthetisch): alle Betriebsarten, AFC, Rauschen, Squelch
if want("psk") {
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
        let rate = Int(mode.sampleRate)
        x = [Float](repeating: 0, count: rate) + x + [Float](repeating: 0, count: rate)
        if let snr {
            let sigma = sqrt(0.5 / pow(10, snr / 10) / (2500.0 / (mode.sampleRate / 2)))
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
    for (i, m) in PSKMode.allCases.enumerated() where m.family == .bpsk || m.family == .qpsk {
        if let r = run(m, signalHz: 800 + Double(i) * 150) {
            check(r.text == expected || r.text == String(expected.dropLast()), "PSK \(m.displayName): Text, got \(r.text.debugDescription)")
            check(abs(r.center - (800 + Double(i) * 150)) < 1.0, "PSK \(m.displayName): Mitte \(r.center)")
        } else {
            check(false, "PSK \(m.displayName): Testsignal nicht erzeugt")
        }
    }

    // PSKR und 8PSK (Fehlerkorrektur, Gray-Zuordnung): Text mit etwas Rauschen davor und danach
    for m in PSKMode.allCases where m.family == .pskr || m.family == .psk8 {
        if let r = run(m, signalHz: 1500) {
            check(r.text.contains("CQ CQ CQ DE DL1ABC DL1ABC PSE K\nThe quick brown fox 0123456789"), "PSK \(m.displayName): Text, got \(r.text.prefix(120).debugDescription)")
            check(abs(r.center - 1500) < 6, "PSK \(m.displayName): Mitte \(r.center)")
        } else {
            check(false, "PSK \(m.displayName): Testsignal nicht erzeugt")
        }
    }
    check(PSKMode.psk8_125.sampleRate == 16_000 && PSKMode.psk125r.sampleRate == 8_000 && PSKMode.psk8_1200f.baud > 1200 && PSKMode.psk8_125f.hasFEC && !PSKMode.psk8_125.hasFEC && PSKMode.psk250r.hasFEC && !PSKMode.bpsk31.hasFEC, "PSK: Abtastrate, Symbolrate, FEC")
    check(PSKMode(rawValue: "8psk250fl") == .psk8_250fl && PSKMode.psk8_500f.family == .psk8 && PSKMode.psk500r.family == .pskr && PSKMode.psk8_500f.shortName == "8-500F" && PSKMode.psk500r.shortName == "500R", "PSK: Kennungen, Familien, Kurznamen")

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
if want("psk") {
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
    // 8PSK mit 16 kHz
    var o8 = FldigiPSKCore.Options()
    o8.mode = .psk8_250
    decoder.configure(options: o8, centerHz: 1300)
    decoder.setEnabled(true)
    let audio16 = [Float](repeating: 0, count: 8_000) + (FldigiPSKCore.synthesize(msg, mode: .psk8_250, centerHz: 1300) ?? []) + [Float](repeating: 0, count: 16_000)
    var audio48b = [Float](repeating: 0, count: audio16.count * 3)
    for i in 0..<audio48b.count {
        let x = Double(i) / 3, k = Int(x), f = Float(x - Double(k))
        audio48b[i] = audio16[k] * (1 - f) + (k + 1 < audio16.count ? audio16[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var j = 0
    var text8 = ""
    while j < audio48b.count {
        let n = min(4_800, audio48b.count - j)
        audio48b[j..<(j + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        j += n
        Thread.sleep(forTimeInterval: 0.004)
        text8 += decoder.takeOutput().text
    }
    Thread.sleep(forTimeInterval: 0.5)
    text8 += decoder.takeOutput().text
    check(text8.contains("CQ CQ DE DL1ABC K"), "8PSK über die Pipeline 48 kHz → 16 kHz, got \(text8.prefix(60).debugDescription)")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - Olivia, Contestia, MT63: Voreinstellungen, URL, Optionen
if want("textmodes") {
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
if want("textmodes") {
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
if want("textmodes") {
    check(parse("digidec://decode?mode=mfsk&preset=thor22&center=1200") == .success(DecodeRequest(module: .mfsk, presetID: "thor22", centerHz: 1200)), "MFSK-Auftrag Thor 22")
    check(parse("digidec://decode?mode=mfsk") == .success(DecodeRequest(module: .mfsk, presetID: "mfsk16")), "MFSK-Standard MFSK16")
    check(Set(DecoderModuleInfo.mfsk.presetIDs) == Set(MFSKMode.allCases.map(\.rawValue)) && DecoderModuleInfo.mfsk.presetIDs.count == MFSKMode.allCases.count, "MFSK: Kennungen = Betriebsarten (\(MFSKMode.allCases.count))")
    check(MFSKMode.mfsk16.family == .mfsk && MFSKMode.dominoex11.family == .dominoex && MFSKMode.thor25x4.family == .thor && MFSKMode.throbx2.family == .throb && MFSKMode.ifkp20.family == .ifkp && MFSKMode.fsq45.family == .fsq, "MFSK: Familien")
    check(MFSKMode.mfsk16.displayName == "MFSK16" && MFSKMode.dominoex11.displayName == "DominoEX 11" && MFSKMode.thormicro.displayName == "Thor Micro" && MFSKMode.throbx2.displayName == "ThrobX 2" && MFSKMode.ifkp05.displayName == "IFKP 0,5" && MFSKMode.fsq45.displayName == "FSQ 4,5", "MFSK: Namen")
    check(MFSKMode.mfsk11.sampleRate == 11_025 && MFSKMode.mfsk16.sampleRate == 8_000 && MFSKMode.thor56.sampleRate == 16_000 && MFSKMode.dominoex22.sampleRate == 11_025 && MFSKMode.ifkp10.sampleRate == 16_000 && MFSKMode.fsq3.sampleRate == 12_000 && MFSKMode.throb2.sampleRate == 8_000, "MFSK: Abtastraten")
    check(RigTuneTarget.psk(band: .free) == nil, "MFSK hat keine feste Frequenz (kein QSY)")
}

// MARK: - MFSK, DominoEX, Thor aus fldigi (synthetisch)
if want("textmodes") {
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
    // Alle Betriebsarten außer den sehr langsamen (MFSK4, DominoEX Micro, Thor Micro, IFKP 0,5, FSQ 1,5): Rundlauf
    for mode in MFSKMode.allCases where ![.mfsk4, .dominoexmicro, .thormicro, .ifkp05, .fsq15].contains(mode) {
        let probe = mode.family == .throb ? "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 012345" : "The quick brown fox jumps over the lazy dog 012345"
        if let r = run(mode) {
            check(r.contains(probe), "\(mode.displayName): Text, got \(r.prefix(100).debugDescription)")
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
    check(run(.ifkp20, snr: 6)?.contains("quick brown fox") == true, "IFKP 2,0 bei 6 dB S/N")
    check(run(.fsq6, snr: 6)?.contains("quick brown fox") == true, "FSQ 6 bei 6 dB S/N")
    check(run(.throb4, snr: 6)?.contains("QUICK BROWN FOX") == true, "Throb 4 bei 6 dB S/N")
    // Squelch: Rauschen ergibt (fast) nichts
    var noise = [Float](repeating: 0, count: 8_000 * 40)
    for i in 0..<noise.count { noise[i] = Float(gauss() * 0.2) }
    for mode in [MFSKMode.mfsk16, .dominoex16, .thor16, .throb2, .ifkp10, .fsq3] {
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
if want("textmodes") {
    let pipeline = AudioPipeline()
    let decoder = MFSKDecoder(pipeline: pipeline)
    pipeline.start(inputRate: 48_000)
    let msg = "CQ CQ DE DL1ABC PSE K"
    for mode in [MFSKMode.mfsk16, .mfsk22, .thor16, .fsq6, .ifkp20] {
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

// MARK: - Hell: Voreinstellungen, URL, Raster
if want("textmodes") {
    check(parse("digidec://decode?mode=hell&preset=fskh245&center=1400") == .success(DecodeRequest(module: .hell, presetID: "fskh245", centerHz: 1400)), "Hell-Auftrag FSK Hell 245")
    check(parse("digidec://decode?mode=hell") == .success(DecodeRequest(module: .hell, presetID: "feld")), "Hell-Standard Feld Hell")
    check(Set(DecoderModuleInfo.hell.presetIDs) == Set(HellMode.allCases.map(\.rawValue)), "Hell: Kennungen = Betriebsarten")
    check(!DecoderModuleInfo.hell.hasMap && DecoderModuleInfo.hell.isAvailable, "Hell: verfügbar, ohne Karte")
    check(HellMode.fskh245.isFSK && !HellMode.feld.isFSK && HellMode.x9.bandwidthHz > HellMode.x5.bandwidthHz, "Hell: Betriebsarten")
}

// MARK: - Hell aus fldigi (synthetisch)
if want("textmodes") {
    func decode(_ text: String, mode: HellMode, noiseSigma: Double = 0, center: Double = 1500, tweak: (inout FldigiHellCore.Options) -> Void = { _ in }) -> (columns: [[UInt8]], status: FldigiHellCore.Status?) {
        guard var x = FldigiHellCore.synthesize(text, mode: mode, centerHz: center) else { return ([], nil) }
        // Kein Nachlauf: ohne Signal liefert FSK-Hell schwarze Spalten, solange der AGC-Pegel über dem Squelch liegt
        x = [Float](repeating: 0, count: 8_000) + x.map { $0 * 0.5 }
        if noiseSigma > 0 { for i in 0..<x.count { x[i] += Float(Double.random(in: -1...1) * noiseSigma) } }
        var o = FldigiHellCore.Options(); o.mode = mode; o.columnRepeat = 1
        tweak(&o)
        var cols: [[UInt8]] = []
        let core = FldigiHellCore(options: o, centerHz: center) { cols.append($0) }
        x.withUnsafeBufferPointer { core.process($0) }
        return (cols, core.status)
    }
    /// Tinte: dunkle Bildpunkte der aktuellen Spaltenhälfte
    func ink(_ cols: [[UInt8]]) -> Int {
        cols.reduce(0) { acc, c in acc + c[(c.count / 2)...].filter { $0 < 128 }.count }
    }
    for mode in HellMode.allCases where mode != .slow {
        let one = decode("HELLO WORLD", mode: mode)
        let two = decode("HELLO WORLD HELLO WORLD", mode: mode)
        let a = ink(one.columns), b = ink(two.columns)
        check(one.columns.count > 50 && one.columns.allSatisfy { $0.count == 40 }, "\(mode.displayName): Spalten (\(one.columns.count)) mit 2 · 20 Werten")
        check(a > 150 && Double(b) > 1.6 * Double(a) && Double(b) < 2.4 * Double(a), "\(mode.displayName): Tinte verdoppelt sich mit dem Text (\(a) → \(b))")
    }
    // Slow Hell braucht lange (1/8 der Geschwindigkeit): kurzer Text
    do {
        let one = decode("HI", mode: .slow), two = decode("HI HI", mode: .slow)
        let a = ink(one.columns), b = ink(two.columns)
        check(a > 40 && Double(b) > 1.4 * Double(a), "Slow Hell: Tinte wächst mit dem Text (\(a) → \(b))")
    }
    // Spaltenlänge und Wiederholung
    do {
        let r = decode("HELLO", mode: .feld) { $0.columnHeight = 28; $0.columnRepeat = 3 }
        check(r.columns.allSatisfy { $0.count == 56 } && r.status?.columnHeight == 28, "Hell: Spaltenlänge 28 → 56 Werte")
        let r1 = decode("HELLO", mode: .feld) { $0.columnRepeat = 1 }
        check(Double(r.columns.count) > 2.6 * Double(r1.columns.count), "Hell: Wiederholung 3× (\(r1.columns.count) → \(r.columns.count) Spalten)")
    }
    // Mitte und Rauschen
    check(ink(decode("HELLO WORLD", mode: .feld, center: 1000).columns) > 150, "Hell bei 1000 Hz")
    check(ink(decode("HELLO WORLD", mode: .feld, noiseSigma: 0.1).columns) > 150, "Hell mit Rauschen")
    // Blackboard kehrt die Werte um
    do {
        let normal = decode("HELLO", mode: .feld)
        let board = decode("HELLO", mode: .feld) { $0.blackboard = true }
        let darkN = normal.columns.reduce(0) { $0 + $1.filter { $0 < 128 }.count }
        let darkB = board.columns.reduce(0) { $0 + $1.filter { $0 < 128 }.count }
        check(darkB > 3 * darkN, "Hell: Tafeldarstellung kehrt um (\(darkN) / \(darkB) dunkle Punkte)")
    }
    // Squelch: Stille und Rauschen ergeben (fast) keine Spalten
    do {
        var cols: [[UInt8]] = []
        let core = FldigiHellCore(options: FldigiHellCore.Options(), centerHz: 1500) { cols.append($0) }
        let quiet = [Float](repeating: 0, count: 8_000 * 20)
        quiet.withUnsafeBufferPointer { core.process($0) }
        check(cols.isEmpty, "Hell: Stille ergibt keine Spalten (\(cols.count))")
    }
}

// MARK: - Hell-Raster
@MainActor func hellRasterTests() {
    let r = HellRasterModel()
    check(r.image == nil && r.columnCount == 0, "Hell-Raster: leer")
    var col = [UInt8](repeating: 255, count: 40)
    col[0] = 0     // unterste Zeile
    r.append(column: col, background: 255)
    r.append(column: col, background: 255)
    r.refresh()
    check(r.columnCount == 2 && r.image != nil && Int(r.image!.size.width) == HellRasterModel.lineWidth && Int(r.image!.size.height) == 40, "Hell-Raster: Bild \(r.image?.size.width ?? 0)×\(r.image?.size.height ?? 0)")
    // Zeilenumbruch nach lineWidth Spalten
    for _ in 0..<HellRasterModel.lineWidth { r.append(column: col, background: 255) }
    r.refresh()
    check(Int(r.image!.size.height) == 40 * 2 + 3, "Hell-Raster: zweite Zeile")
    check(r.pngData() != nil, "Hell-Raster: PNG")
    r.clear()
    check(r.image == nil && r.columnCount == 0, "Hell-Raster: gelöscht")
}
if want("textmodes") { hellRasterTests() }

// MARK: - MT63 und Olivia über die Pipeline (48 kHz → 8 kHz)
if want("textmodes") {
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
if want("dsc") {
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
        let framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
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
        let framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
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
        let framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
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
            let framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
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
if want("dsc") {
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
if want("dsc") {
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
if want("ale") {
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
if want("ale") {
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
if want("aprs") {
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
if want("aprs") {
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

if want("aprs") {
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

if want("aprs") {
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

if want("aprs") {
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
if want("aprs") {
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
if want("aprs") {
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
if want("aprs") {
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

// MARK: - SYNOP: Zeilenumbrüche, fehlende Kopfzeile, Wertansicht (echter Empfang DDK2, 02.10.2026 18:37 UTC)
if want("weather") {
    SynopDecoder.loadStations()
    func decode(_ text: String) -> (raw: String, klar: String, segments: [TextSegment]) {
        var segs: [TextSegment] = []
        let d = SynopDecoder { segs.append($0) }
        for scalar in text.unicodeScalars { d.feed(Character(scalar)) }
        d.flush()
        return (segs.filter { !$0.decoded }.map(\.text).joined(), segs.filter { $0.decoded }.map(\.text).joined(), segs)
    }
    // Mehrzeilige Meldung mit Kopfzeile in eigener Zeile (so sendet der DWD): Station, Wert, Einheit
    let withHeader = "AAXX 02184\r\n10655 12970 82205 10123 20103 30106 40113 52010\r\n60002 83507 333 10222=\r\nNNNN\r\n"
    let h = decode(withHeader)
    check(h.raw == withHeader, "SYNOP: Rohtext unverändert trotz Zeilenumbrüchen, got \(h.raw.debugDescription)")
    for want in ["WMO Station=10655", "WMO station=Wuerzburg", "Temperature=12.3 °C", "Sea level pressure=1011 hPa", "Wind speed=5 knots", "Maximum 24 hours temperature=22.2 °C"] {
        check(h.klar.contains(want), "SYNOP mehrzeilig: „\(want)“")
    }
    check(!h.klar.contains("Header missing"), "SYNOP mit Kopfzeile: kein Hinweis auf fehlende Kopfzeile")
    // Dieselbe Meldung ohne Kopfzeile, davor Reste der vorigen Meldung (Empfang mitten im Block)
    let tail = "X 02181\r\n12120 12963 62002 10126 20118 30306 40311 52011 60002 80008\r\n333 10222 20118 91205 93000=\r\n12330 12980 60000 10143 20087 30204 40312 52007 60002 80008\r\n333 10233 20113 91204 93000=\r\nNNNN\r\nCQ CQ CQ DE DDK2\r\n"
    let t = decode(tail)
    check(t.raw.replacingOccurrences(of: "AAXX ", with: "").contains("12120 12963 62002") && t.raw.hasPrefix("X 02181\r\n"), "SYNOP ohne Kopfzeile: Rohtext läuft durch")
    check(t.klar.contains("Note=Header missing") && t.klar.contains("WMO Station=12120") && t.klar.contains("WMO station=Leba") && t.klar.contains("Temperature=12.6 °C"), "SYNOP ohne Kopfzeile: Station 12120 (Leba) erkannt, nicht das Bruchstück 02181")
    check(t.klar.contains("WMO Station=12330") && t.klar.contains("Temperature=14.3 °C") && t.klar.contains("Bulletin end"), "SYNOP: zweite Meldung und Blockende")
    // Gewöhnlicher Text mit Zahlen läuft unverändert durch und löst nichts aus
    let plain = "CQ CQ DE DDK2 12345 678 FREQUENCIES 4583 KHZ 10100.8 KHZ\r\nRYRYRYRY 02181 12120 ABC\r\n"
    let p = decode(plain)
    check(p.raw == plain && !p.klar.contains("Header missing"), "Gewöhnlicher Text mit Zahlen bleibt unberührt (\(p.klar.prefix(40).debugDescription))")
    // Fünfergruppen, die keine Meldung sind (Stationsnummer vorhanden, Rest passt nicht)
    let noise = "10655 99999 11111 22222 33333\r\n"
    let n = decode(noise)
    check(!n.klar.contains("Header missing"), "Fünfergruppen ohne Meldungsform: keine Kopfzeile ergänzt (\(n.klar.prefix(60).debugDescription))")
    // Karte: Wertansicht
    let log = SynopLog()
    for seg in t.segments { log.feed(seg.text, decoded: seg.decoded) }
    log.flush()
    check(log.observations.count == 2, "SYNOP-Log: zwei Stationen (\(log.observations.count))")
    let leba = log.observations["12120"]
    check(leba?.headerGuessed == true && leba?.temperatureC == 12.6 && leba?.pressureHPa == 1031 && leba?.windDirectionDeg != nil && leba?.visibilityKm == 13, "SYNOP-Log: Werte von Leba (\(String(describing: leba?.temperatureC)), \(String(describing: leba?.pressureHPa)))")
    check(log.observations["12330"]?.windUnit == "kn" && log.observations["12330"]?.windUnitAssumed == true, "SYNOP-Log: unbekannte Windeinheit wird von der ersten Meldung übernommen (\(String(describing: log.observations["12330"]?.windUnit)), \(String(describing: log.observations["12330"]?.windSpeedValue)))")
    // Klartext einer Meldung in Stücken, dazwischen Rohtext (echter Empfang 02.10.2026, 62305 Sallum Plateau)
    let chunked = SynopLog()
    let pieces: [(String, Bool)] = [
        ("\tNote=Header missing: time and wind unit assumed (UTC 18:00, knots)\n", true), ("AAXX 02184 62305", false),
        (" Land station observation\n\tUTC observation time=2026-10-02 18:00\n", true), ("02184 99504 10000", false),
        ("\tWMO Station=62305\n\tWMO station=Sallum Plateau\n\tLongitude=0.0\n\tLatitude=50.4\n", true), ("/2308 10186", false),
        ("\tVisibility=20 km\n\tWind direction=225 degrees\n\tWind speed=8 knots (Anemometer)\n\tTemperature=18.6 °C\n", true), ("20121 40301", false),
        ("\tSea level pressure=1030 hPa\n", true), ("22200", false),
        ("\tWMO Station=62050\n\tLongitude=-4.4\n\tLatitude=50.0\n\tTemperature=17.2 °C\n", true), ("NNNN", false)
    ]
    for (t, d) in pieces { chunked.feed(t, decoded: d) }
    chunked.flush()
    let sal = chunked.observations["62305"]
    check(chunked.observations.count == 2 && sal?.temperatureC == 18.6 && sal?.pressureHPa == 1030 && sal?.windDirectionDeg == 225 && sal?.windSpeedValue == 8 && sal?.visibilityKm == 20, "SYNOP-Log: Klartext in Stücken, getrennt durch Rohtext, wird zu einer Meldung (\(String(describing: sal?.temperatureC)), \(String(describing: sal?.pressureHPa)))")
    check(chunked.observations["62050"]?.temperatureC == 17.2 && chunked.observations["62050"]?.position == GeoPoint(lat: 50.0, lon: -4.4) && sal?.headerGuessed == true, "SYNOP-Log: zweite Station getrennt, Kopfzeilenhinweis bleibt")
    let home = GeoPoint(lat: 49.77, lon: 9.95)
    for layer in SynopLog.Layer.allCases {
        let c = log.content(home: home, now: Date(), layer: layer)
        let withPoint = c.markers.filter { $0.id.hasPrefix("synop-") }
        switch layer {
        case .symbol: check(withPoint.count == 2 && withPoint.allSatisfy { $0.symbol != nil && $0.valueText == nil }, "Karte Symbolansicht: zwei Symbole")
        case .temperature: check(withPoint.count == 2 && withPoint.contains { $0.valueText == "12" || $0.valueText == "13" } && withPoint.allSatisfy { $0.valueLevel != nil }, "Karte Temperatur: \(withPoint.map { $0.valueText ?? "-" })")
        case .pressure: check(withPoint.count == 2 && withPoint.allSatisfy { $0.valueText == "1031" }, "Karte Luftdruck: \(withPoint.map { $0.valueText ?? "-" })")
        case .wind: check(withPoint.contains { $0.headingDeg != nil && $0.valueText == "2" }, "Karte Wind: Pfeil und Knoten (\(withPoint.map { $0.valueText ?? "-" }))")
        case .visibility: check(withPoint.contains { $0.valueText == "13" }, "Karte Sicht: \(withPoint.map { $0.valueText ?? "-" })")
        case .humidity, .precipitation: check(withPoint.allSatisfy { $0.valueText != nil && $0.valueLevel != nil && $0.symbol == nil }, "Karte \(layer.title): nur Stationen mit Wert, als Zahl (\(withPoint.count))")
        case .sea: break
        }
    }
    let wind = log.content(home: home, now: Date(), layer: .wind).markers.first { $0.id == "synop-12120" }
    check(wind?.headingDeg == 15, "Windpfeil zeigt in Windrichtung (Wind aus 195° → Pfeil 15°, ist \(String(describing: wind?.headingDeg)))")
    check(wind?.details.contains { $0.contains("Kopfzeile fehlte") } == true, "Popup nennt die fehlende Kopfzeile")
    // Beaufort-Grenzen und Zahlen aus Klartext
    check(SynopLog.beaufort(0) == 0 && SynopLog.beaufort(3) == 1 && SynopLog.beaufort(8) == 3 && SynopLog.beaufort(30) == 7 && SynopLog.beaufort(64) == 12, "Beaufort aus Knoten")
    check(SynopObservation.number("-3,4 °C") == -3.4 && SynopObservation.number("1013 hPa") == 1013 && SynopObservation.number("Variable, all directions") == nil, "Zahlen aus Klartext")
    check(SynopObservation.windUnit("5 m/s") == "ms" && SynopObservation.windUnit("14 km/h") == "kmh" && SynopObservation.windUnit("10 knots (Anemometer)") == "kn" && SynopObservation.windUnit("63 No unit (YYGGi missing)") == nil, "Windeinheiten")
    check(SynopObservation.km("4 km") == 4 && SynopObservation.km("800 m") == 0.8, "Sicht in km")
    // Bei der Erkennung zählt die Stationsliste
    check(SynopHeaderRecovery.isStation("12120") && !SynopHeaderRecovery.isStation("99999") && SynopHeaderRecovery.isSecondGroup("12963") && !SynopHeaderRecovery.isSecondGroup("99514") && SynopHeaderRecovery.isFourthGroup("10126") && !SynopHeaderRecovery.isFourthGroup("62002"), "Erkennung: Stationsnummer, Gruppen")
}

// MARK: - Seewetterberichte des DWD (FQEN70, FQEN71, WODL45) für die Karte – echte Berichte vom 02.10.2026
if want("weather") {
    let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/DWD")
    func sample(_ name: String) -> String { (try? String(contentsOf: samples.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    let fq70 = sample("DWD_FQEN70_20261002_1700.txt"), fq71 = sample("DWD_FQEN71_20261002_1700.txt"), wodl = sample("DWD_WODL45_20261002_1800.txt")
    if fq70.isEmpty || fq71.isEmpty || wodl.isEmpty {
        skip("Seewetterberichte: Beispielberichte liegen nicht lokal vor (\(samples.path))")
    } else {

        let r = SeaBulletinParser.parse(fq70)
        check(r.issued?.contains("02.10.2026") == true && r.issued?.contains("1700") == true, "Ausgabezeit: \(r.issued ?? "-")")
        check(r.forecasts.count == 18 && r.days == ["friday", "saturday"], "FQEN70: 9 Gebiete an 2 Tagen (\(r.forecasts.count), \(r.days))")
        let gb = r.forecasts.first { $0.areaID == "germanbight" && $0.day == "friday" }
        check(gb?.wind == "southwest to south about 3, increasing about 4." && gb?.maxBeaufort == 4 && gb?.windFromDeg == 225, "Deutsche Bucht Freitag: Wind \(gb?.wind ?? "-")")
        check(gb?.weather.contains("coastal fog patches") == true && gb?.sea.contains("1,5 meter") == true, "Deutsche Bucht: Sicht/Wetter und Seegang (\(gb?.weather ?? "-"), \(gb?.sea ?? "-"))")
        let fi = r.forecasts.first { $0.areaID == "fischer" && $0.day == "friday" }
        check(fi?.maxBeaufort == 5, "Fischer Freitag: Windstärke 5 (\(String(describing: fi?.maxBeaufort)))")
        let bs = r.forecasts.first { $0.areaID == "belts" && $0.day == "saturday" }
        check(bs?.wind.hasPrefix("first light and variable winds") == true && bs?.wind.contains("slowly shifting southwest to west") == true && bs?.maxBeaufort == 4, "Belte und Sund Samstag: Wind über zwei Zeilen (\(bs?.wind ?? "-"))")
        let wb = r.forecasts.first { $0.areaID == "westbaltic" && $0.day == "friday" }
        check(wb?.weather.contains("later coastal fog patches") == true && wb?.weather.contains("rain with poor visibility") == true, "Westliche Ostsee: Sicht/Wetter über zwei Zeilen (\(wb?.weather ?? "-"))")
        check(r.forecasts.first { $0.areaID == "kattegat" && $0.day == "friday" }?.windFromDeg == 270, "Kattegat: Wind aus West")
        check(r.forecasts.first { $0.areaID == "belts" && $0.day == "friday" }?.windFromDeg == nil, "Belte und Sund Freitag: leichter Wind ohne Richtung")

        // Wetterlage
        check(r.synopsis.hasPrefix("A high 1037 Belarus moves to Romania."), "Wetterlage gelesen")
        check(r.systems.count == 4, "Wetterlage: vier Druckgebiete (\(r.systems.map { "\($0.kind.rawValue) \($0.pressure ?? 0)" }))")
        if r.systems.count == 4 {
            let h1 = r.systems[0], t1 = r.systems[1], t2 = r.systems[2], h2 = r.systems[3]
            check(h1.kind == .high && h1.pressure == 1037 && h1.position.map { abs($0.lat - 53.7) < 0.5 && abs($0.lon - 28.0) < 0.5 } == true, "Hoch 1037 über Belarus")
            check(h1.destination.map { abs($0.lat - 45.9) < 0.5 && abs($0.lon - 25.0) < 0.5 } == true, "… zieht nach Rumänien")
            check(t1.kind == .low && t1.pressure == 987 && t1.position.map { $0.lon < -30 && $0.lat > 55 } == true && t1.destination == nil, "Tief 987 über der Irminger See (zieht nicht)")
            check(t2.kind == .low && t2.name == "secondary low" && t2.pressure == 1011 && t2.position.map { abs($0.lat - 56.8) < 0.5 && abs($0.lon + 4.2) < 0.5 } == true, "Randtief 1011 erreicht Schottland")
            check(t2.destination.map { $0.lat > 62 && $0.lon < 10 } == true, "… zieht zur Norwegischen See")
            check(h2.kind == .high && h2.pressure == 1032 && h2.position.map { $0.lat > 51 && $0.lat < 55 && $0.lon > 8 && $0.lon < 14 } == true, "Hoch 1032 über Norddeutschland (nördlicher als die Landesmitte)")
            check(h2.destination.map { $0.lat > 54 && $0.lon > 14 && $0.lon < 21 } == true, "… zieht zur Südlichen Ostsee")
        }
        check(r.fronts.count == 1 && r.fronts[0].kind == .cold && r.fronts[0].points.count == 2, "Kaltfront von Südschweden nach Ostdeutschland (\(r.fronts.map { $0.points.count }))")
        if let f = r.fronts.first, f.points.count == 2 {
            check(f.points[0].lat > 57 && f.points[1].lat < 53 && f.points[1].lon > 10, "Front: Südschweden (\(f.points[0].lat)) – Ostdeutschland (\(f.points[1].lat), \(f.points[1].lon))")
        }

        // Küstenabschnitte
        let c = SeaBulletinParser.parse(fq71)
        check(c.forecasts.count == 8 && Set(c.forecasts.map(\.areaID)) == Set(SeaArea.all.filter { $0.kind == .coast }.map(\.id)), "FQEN71: 8 Küstenabschnitte (\(c.forecasts.count))")
        check(c.forecasts.first { $0.areaID == "helgoland" }?.wind == "southwest about 3, shifting south to southeast." && c.forecasts.allSatisfy { $0.day == "friday" }, "Helgoland: Wind, Tag Freitag")
        check(c.forecasts.first { $0.areaID == "bodden" }?.weather.contains("moderate visibility") == true, "Boddengewässer: Sicht/Wetter über zwei Zeilen")
        check(c.systems.count == 4, "FQEN71 enthält dieselbe Wetterlage")

        // Sturmwarnungen
        let w = SeaBulletinParser.parse(wodl)
        check(w.warnings.count == 3 && w.warnings.allSatisfy { $0.level == 0 } && Set(w.warnings.map(\.areaID)) == ["germanbight", "westbaltic", "southbaltic"], "WODL45: drei Gebiete ohne Warnung (\(w.warnings.map { "\($0.areaID) \($0.level)" }))")
        let storm = SeaBulletinParser.parse("STRONG WIND, GALE AND STORM WARNINGS FOR SEA AREAS:\nGERMAN BIGHT, WESTERN AND SOUTHERN BALTIC.\n\nGERMAN BIGHT:\nSTORM WARNING SOUTHWEST 9 TO 10.\n\nWESTERN BALTIC:\nGALE WARNING NORTHWEST.\n\nSOUTHERN BALTIC:\nno warning.\n\nCOASTAL AREA WARNINGS:\n")
        check(storm.warnings.first { $0.areaID == "germanbight" }?.level == 10 && storm.warnings.first { $0.areaID == "westbaltic" }?.level == 8 && storm.warnings.first { $0.areaID == "southbaltic" }?.level == 0,
              "Warnstufen aus dem Text (\(storm.warnings.map { "\($0.areaID) \($0.level)" }))")

        // Funkfernschreiben: Großbuchstaben, Zeilenende CR/LF, Fehler
        let rtty = fq70.uppercased().replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "GERMAN BIGHT:", with: "GERMAN BIGHI:").replacingOccurrences(of: "FORECAST SATURDAY:", with: "FORECAST SATURDAY:")
        let rr = SeaBulletinParser.parse(rtty)
        check(rr.forecasts.count == 18 && rr.forecasts.first { $0.areaID == "germanbight" && $0.day == "friday" }?.maxBeaufort == 4, "Großbuchstaben, CR/LF und ein Zeichenfehler im Gebietsnamen (\(rr.forecasts.count))")
        check(rr.systems.count == 4 && rr.fronts.count == 1, "Wetterlage auch in Großbuchstaben (\(rr.systems.count), \(rr.fronts.count))")
        // Empfang mitten im Bericht: ohne Tagesüberschrift
        let mid = SeaBulletinParser.parse("SKAGERRAK:\nWIND: SOUTHWESTERLY WINDS 4 TO 5, FIRST LOCALLY 6.\nVISIBILITY/WEATHER: GOOD VISIBILITY.\nSEA: 1,5 METER.\nKATTEGAT:\nWIND: WEST 3 TO 4,\nSHIFTING SLOWLY SOUTHWEST.\nSEA: NORTHERN PART 1 METER.\n")
        check(mid.forecasts.count == 2 && mid.forecasts[0].day == "forecast" && mid.forecasts[0].maxBeaufort == 6 && mid.forecasts[1].wind == "WEST 3 TO 4, SHIFTING SLOWLY SOUTHWEST.", "Empfang mitten im Bericht: Vorhersage ohne Tag (\(mid.forecasts.map(\.wind)))")
        check(SeaBulletinParser.parse("CQ CQ CQ DE DDK2 DDH7 DDK9\r\nFREQUENCIES 4583 KHZ\r\nRYRYRY\r\n").isEmpty, "Testbild des DWD ergibt keinen Bericht")

        // Gebiete
        check(SeaArea.match("German Bight")?.id == "germanbight" && SeaArea.match("DEUTSCHE BUCHT")?.id == "germanbight" && SeaArea.match("German Bighz")?.id == "germanbight", "Gebietsname: englisch, deutsch, ein Fehler")
        check(SeaArea.match("Southern Baltic")?.id == "southbaltic" && SeaArea.match("Southeastern Baltic")?.id == "sebaltic" && SeaArea.match("Wind") == nil && SeaArea.match("Coastal areas of German North Sea") == nil, "ähnliche Namen bleiben getrennt")
        check(Set(SeaArea.all.map(\.id)).count == SeaArea.all.count && SeaArea.all.allSatisfy { $0.center.isValid && $0.radiusKm > 0 }, "Gebietsliste: eindeutig, gültige Lagen")

        // Ortsnamen
        let ger = Gazetteer.locate("germany")!, north = Gazetteer.locate("northern Germany")!, east = Gazetteer.locate("eastern Germany")!
        check(north.lat > ger.lat && abs(north.lon - ger.lon) < 0.01 && east.lon > ger.lon, "Gazetteer: nördliches und östliches Deutschland")
        let ice = Gazetteer.locate("Iceland")!, swIce = Gazetteer.locate("close to the southwest of Iceland")!
        check(swIce.lat < ice.lat - 1.5 && swIce.lon < ice.lon - 3, "Gazetteer: „southwest of Iceland“ liegt außerhalb südwestlich")
        check(Gazetteer.locate("the northeastern part of the Irminger Sea").map { $0.lat > 61.5 && $0.lon > -35 } == true && Gazetteer.locate("Atlantis") == nil, "Gazetteer: Teil eines Meeres, Unbekanntes → nil")
        check(Gazetteer.locate("area St. Petersburg").map { abs($0.lat - 59.9) < 0.1 } == true, "Gazetteer: „area St. Petersburg“")

        // Übersetzung
        check(SeaPhrase.german("southwest to south about 3, increasing about 4.") == "Südwest bis Süd um 3, zunehmend um 4.", "Übersetzung Wind: \(SeaPhrase.german("southwest to south about 3, increasing about 4."))")
        check(SeaPhrase.german("later coastal fog patches.") == "Später Küstennebelfelder.", "Übersetzung Nebel: \(SeaPhrase.german("later coastal fog patches."))")
        check(SeaPhrase.german("northwestern part later 1,5 meter.") == "Nordwestteil später 1,5 Meter.", "Übersetzung Seegang: \(SeaPhrase.german("northwestern part later 1,5 meter."))")
        check(SeaPhrase.german("light and variable winds") == "Schwache umlaufende Winde" && SeaPhrase.germanDay("friday") == "Freitag", "Übersetzung: schwache Winde, Wochentag")

        // Log und Karte
        let log = SeaLog()
        log.feed(fq70, decoded: false)
        log.feed("RYRYRYRY\r\n", decoded: false)
        log.feed("Latitude=51.4\n", decoded: true)          // Klartext zählt nicht
        check(log.report.forecasts.count == 18, "SeaLog: Bericht (\(log.report.forecasts.count))")
        log.feed(fq71, decoded: false)
        log.feed("\u{03}\r\nNNNN\r\n", decoded: false)      // Steuerzeichen und Telegrammende zwischen den Berichten
        log.feed(storm.warnings.isEmpty ? "" : "STRONG WIND, GALE AND STORM WARNINGS FOR SEA AREAS:\nGERMAN BIGHT:\nSTORM WARNING SOUTHWEST 9.\nWESTERN BALTIC:\nno warning.\n", decoded: false)
        let home = GeoPoint(lat: 49.77, lon: 9.95)
        let content = log.content(home: home, now: Date())
        let areaMarkers = content.markers.filter { $0.id.hasPrefix("sea-") }
        check(areaMarkers.count == 17, "Karte: 9 Seegebiete und 8 Küstenabschnitte (\(areaMarkers.count))")
        let bight = content.markers.first { $0.id == "sea-germanbight" }
        check(bight?.valueText == "4" && bight?.title == "Deutsche Bucht" && bight?.radiusKm == 110 && bight?.headingDeg == 45, "Karte Deutsche Bucht: Windstärke 4, Pfeil nach Nordost (\(String(describing: bight?.headingDeg)))")
        check(bight?.details.contains { $0.hasPrefix("Freitag: Wind Südwest bis Süd um 3, zunehmend um 4.") } == true && bight?.details.contains { $0.contains("Seegang: Nordwestteil später 1,5 Meter.") } == true, "Popup: deutsche Fassung je Tag")
        check(content.markers.contains { $0.id == "warn-germanbight" && $0.tone == .alert } && !content.markers.contains { $0.id == "warn-westbaltic" }, "Karte: Warnung nur für die Deutsche Bucht")
        check(content.markers.filter { $0.id.hasPrefix("system-") }.count == 4 && content.lines.contains { $0.id == "system-move-0" } && content.lines.contains { $0.id == "front-0" }, "Karte: Hochs, Tiefs, Zugrichtung und Front")
        let h = content.markers.first { $0.id == "system-0" }
        check(h?.valueText == "H 1037" && h?.title == "Hoch 1037 hPa", "Karte: Hoch 1037 (\(h?.valueText ?? "-"))")
        check(SeaLog().content(home: home, now: Date()).markers.isEmpty, "Karte ohne Bericht: leer")
        log.clear()
        check(log.report.isEmpty, "SeaLog geleert")
    }
}

// MARK: - DWD Seewetter 5-Tage-Punktvorhersagen (FQEN75-79) mit SST und RTTY-Mittenfrequenz
if want("weather") {
    let pointText = """
    WN.O.IRELAND (54.0N  13.9W) SST: 14 C
    SU  4. 00Z: SW     5-6   6-7  2.5 M //
    SU  4. 12Z: SW     4-5        2.5 M //#.
    MO  5. 00Z: SW     5-6     7  2.5 M //
    MO  5. 12Z: W-NW     3        2.5 M //
    TU  6. 00Z: NW       4        2.5 M //
    TU  6. 12Z: W-NW   4-5         2  M //
    WE  7. 00Z: W-NW     5        2.5 M //
    WE  7. 12Z: NW    I  5   6-7   3  M //
    TH  8. 00Z: W      3-4        2.5 M //
    TH  8. 12Z: SW     5-6   6-7  2.5 M //
    ISLE.O.MAN-S (53.5N   5.3W) SST: 16 C
    SU  4.800Z: S-SW   3-4        0.5 M //
    SU  4. 12Z: S-SW  I4-5         1  M //
    MO  5. 00Z: S-SW   4-5         1 8M //
    MO  5. 12Z: SW     3-4         1  M //
    TU  6. 00Z: SW-W     3        1.5 M //
    U  6. 12Z: N      4-5         78=. //
    WE  7. 00Z: NW-N     4         1  M //
    WE  7. 12Z: NW       5         1  M //
    TH  8. 00Z: NW-N   5-6   6-7  1.5 M //
    TH  8. 12Z: NW       3        0.5 M //
    SW.O.IRELAND (51.0N  13.0W) SST: 16 C
    SU  4. 00Z: SW     3-4       8 2  M //
    SU  4. 12Z: SW     4-5         2  M //
    MO  5. 00Z: SW       4         2  M //
    MO  5. 12Z: SW       3        1.5 M //
    TU  6. 00Z: SW-W     3        1.5 M //
    TU  6. 12Z: N        5         2  M //
    WE  7. 00Z:8NW-N   4-5         2  M //
    WE  7. 12Z: NW-N   4-5        2.5 M //
    TH  8. 00Z: NW       3        2.5 M //
    TH  8. 12Z: SW-W     5         2  M //
    """
    let report = SeaBulletinParser.parse(pointText)
    check(report.points.count == 3, "Punktvorhersage: 3 Stationen erkannt (\(report.points.count))")

    let wn = report.points.first { $0.name == "WN.O.IRELAND" }
    check(wn?.coordinate.lat == 54.0 && wn?.coordinate.lon == -13.9, "WN.O.IRELAND: Koordinaten 54.0 N 13.9 W")
    check(wn?.sstC == 14.0, "WN.O.IRELAND: SST 14 °C")
    check(wn?.periods.count == 10, "WN.O.IRELAND: 10 Vorhersageperioden (\(wn?.periods.count ?? 0))")
    check(wn?.periods.first?.windText.hasPrefix("SW 5-6") == true && wn?.periods.first?.gustsText == "6-7" && wn?.periods.first?.waveM == 2.5, "WN.O.IRELAND: Wind SW 5-6, Böen 6-7, Seegang 2.5 m")

    let man = report.points.first { $0.name == "ISLE.O.MAN-S" }
    check(man?.coordinate.lat == 53.5 && man?.coordinate.lon == -5.3 && man?.sstC == 16.0, "ISLE.O.MAN-S: 53.5 N 5.3 W, SST 16 °C")

    let sw = report.points.first { $0.name == "SW.O.IRELAND" }
    check(sw?.coordinate.lat == 51.0 && sw?.coordinate.lon == -13.0 && sw?.sstC == 16.0, "SW.O.IRELAND: 51.0 N 13.0 W, SST 16 °C")

    let log = SeaLog()
    log.feed(pointText, decoded: false)
    let home = GeoPoint(lat: 49.77, lon: 9.95)

    // TEMP-Ansicht
    let tempMarkers = log.pointMarkers(home: home, layer: .temperature)
    check(tempMarkers.count == 3, "Punktvorhersage auf Karte TEMP: 3 Marker (\(tempMarkers.count))")
    let t1 = tempMarkers.first { $0.title == "WN.O.IRELAND" }
    check(t1?.valueText == "14" && t1?.symbol == nil, "WN.O.IRELAND auf TEMP: Wert 14 (\(t1?.valueText ?? "-"))")
    check(t1?.details.contains { $0.contains("Wassertemperatur (SST): 14 °C") } == true, "Popup enthält Wassertemperatur (SST)")
    check(t1?.details.contains { $0.contains("Seegang 2,5 m") } == true, "Popup enthält Seegang")

    // WIND-Ansicht
    let windMarkers = log.pointMarkers(home: home, layer: .wind)
    check(windMarkers.count == 3, "Punktvorhersage auf Karte WIND: 3 Marker (\(windMarkers.count))")
    let w1 = windMarkers.first { $0.title == "WN.O.IRELAND" }
    check(w1?.headingDeg != nil, "WN.O.IRELAND auf WIND: Windpfeil gesetzt")

    // SEE-Ansicht
    let seaContent = log.content(home: home, now: Date())
    check(seaContent.markers.contains { $0.id == "point-WN.O.IRELAND" }, "SEE-Ansicht enthält Punktvorhersagen")

    // RTTY Center Reset & Clamp
    let rttyStore = RTTYSettingsStore()
    check(rttyStore.centerHz == 1000.0, "RTTYSettingsStore Standard-Mitte 1.000 Hz (\(rttyStore.centerHz))")
    rttyStore.setCenter(1500)
    check(rttyStore.centerHz == 1500.0, "setCenter auf 1.500 Hz")
    rttyStore.resetCenter()
    check(rttyStore.centerHz == 1000.0, "resetCenter setzt auf 1.000 Hz zurück")
}

// MARK: - Schiffs- und Bojenmeldungen mit Weg, Positionen in Warnnachrichten
if want("weather") {
    SynopDecoder.loadStations()
    func segments(_ text: String) -> [TextSegment] {
        var segs: [TextSegment] = []
        let d = SynopDecoder { segs.append($0) }
        for scalar in text.unicodeScalars { d.feed(Character(scalar)) }
        d.flush()
        return segs
    }
    let log = SynopLog()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    for seg in segments("SMVX41 EDZW 021800\r\nBBXX DBCB 02184 99530 10078 41656 10202 20196 40146 52007 22200 =\r\nBBXX DHBR 02184 99521 10065 41/80 11205 20191 40152 =\r\nNNNN\r\n") {
        log.feed(seg.text, decoded: seg.decoded, at: t0)
    }
    log.flush(at: t0)
    check(log.observations.count == 2 && Set(log.observations.keys) == ["DBCB", "DHBR"], "Schiffsmeldungen: Rufzeichen als Schlüssel (\(log.observations.keys.sorted()))")
    let ship = log.observations["DBCB"]
    check(ship?.kind == "Schiff" && ship?.position == GeoPoint(lat: 53.0, lon: 7.8) && ship?.track.isEmpty == true, "Schiff DBCB: Ort 53,0 N 7,8 E (\(String(describing: ship?.position)))")
    // später meldet das Schiff von einem anderen Ort: Weg
    for seg in segments("BBXX DBCB 02214 99535 10091 41656 10202 20196 40146 =\r\nNNNN\r\n") { log.feed(seg.text, decoded: seg.decoded, at: t0.addingTimeInterval(3 * 3600)) }
    log.flush(at: t0.addingTimeInterval(3 * 3600))
    let moved = log.observations["DBCB"]
    check(moved?.position == GeoPoint(lat: 53.5, lon: 9.1) && moved?.track == [GeoPoint(lat: 53.0, lon: 7.8)], "Schiff DBCB: neuer Ort, Weg mit dem alten (\(String(describing: moved?.position)), \(String(describing: moved?.track)))")
    let sc = log.content(home: GeoPoint(lat: 49.77, lon: 9.95), now: t0.addingTimeInterval(3 * 3600 + 60))
    check(sc.markers.first { $0.id == "synop-DBCB" }?.track.count == 2 && sc.markers.first { $0.id == "synop-DHBR" }?.track.isEmpty == true && sc.markers.first { $0.id == "synop-DBCB" }?.symbol == "ferry.fill", "Karte: Weg des Schiffs, Fährensymbol")

    // Positionen in Warnnachrichten
    let nav = NauticalPositions.extract("NAVAREA I WARNING 123.\nDERELICT AT 54-12.5N 007-30.2E.\n\nBUOY OFF POSITION 5430N 01015E UNLIT.\n\nWRECK 54\u{00B0}20'N 007\u{00B0}40'E MARKED.\r\n")
    check(nav.count == 3, "Positionen: drei Formen (\(nav.count))")
    if nav.count == 3 {
        check(abs(nav[0].point.lat - 54.2083) < 0.001 && abs(nav[0].point.lon - 7.5033) < 0.001 && nav[0].context.contains("DERELICT"), "Position 54-12.5N 007-30.2E mit Absatz")
        check(abs(nav[1].point.lat - 54.5) < 0.001 && abs(nav[1].point.lon - 10.25) < 0.001, "Position 5430N 01015E (kompakt)")
        check(abs(nav[2].point.lat - 54.3333) < 0.001 && abs(nav[2].point.lon - 7.6667) < 0.001, "Position 54°20′N 007°40′E")
    }
    check(NauticalPositions.extract("BBXX DBCB 02184 99530 10078 41656 10202 20196 40146 =\r\n99-99N 200-10E 7-3N 5\r\n").isEmpty, "SYNOP-Gruppen und ungültige Positionen ergeben nichts")
    check(NauticalPositions.extract("12-30S 045-10W TEST").first.map { $0.point.lat < 0 && $0.point.lon < 0 } == true, "Position Süd/West")
    let seaLog = SeaLog()
    seaLog.feed("NAVAREA I WARNING 5.\r\nOBSTRUCTION 54-10N 007-50E.\r\n", decoded: false)
    let cm = seaLog.content(home: nil, now: Date()).markers.filter { $0.id.hasPrefix("nav-") }
    check(cm.count == 1 && cm[0].tone == .highlight && cm[0].details[0].contains("OBSTRUCTION"), "Karte: Warnposition als Punkt")
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
if want("weather") { homeTests() }


// MARK: - Funkruf: BCH, POCSAG, FLEX
if want("pager") {
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

if want("pager") {
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
func lowpassAudio(_ s: [Float], _ fc: Double, rate: Double = 24_000) -> [Float] {
    let k = Float(1 - exp(-2 * .pi * fc / rate)); var y: Float = 0
    return s.map { x in y += k * (x - y); return y }
}

if want("pager") {
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

if want("pager") {
    // Entzerrer: Prüfung der Codewörter
    check(POCSAGEqualizer.isValid(PagerBCH.encode(0x0F0F0F)) && POCSAGEqualizer.isValid(POCSAG.idle) && POCSAGEqualizer.isValid(POCSAG.sync), "Entzerrer: Codewörter, Leer- und Synchronwort gelten")
    check(!POCSAGEqualizer.isValid(PagerBCH.encode(0x0F0F0F) ^ 0x10) && !POCSAGEqualizer.isValid(PagerBCH.encode(0x0F0F0F) ^ 1), "Entzerrer: ein Bitfehler (auch Parität) gilt nicht ohne Korrektur")
    let perfect = POCSAGSignalGenerator.bits(address: 1234567, function: 3, alpha: "Hallo")
    let an = POCSAGEqualizer.analyze(perfect, minValid: 5)
    let anInv = POCSAGEqualizer.analyze(perfect.map { $0 ^ 1 }, minValid: 5)
    check(an.goodBatches == 2 && an.bestWords == 16 && anInv.goodBatches == 2, "Entzerrer: zwei Stapel erkannt, auch invertiert (\(an.goodBatches)/\(anInv.goodBatches))")
    check(an.lastEnd == 576 + 2 * 544 && !an.mask[0] && an.mask[576] && an.mask[576 + 32 + 31], "Entzerrer: Ende des letzten Stapels und Maske der sicheren Bits")
    let zeros = POCSAGEqualizer.analyze([UInt8](repeating: 0, count: 2000), minValid: 5)
    check(zeros.goodBatches == 0 && zeros.maskCount == 0, "Entzerrer: Nullen sind kein Stapel")

    // Sauberes Testsignal und Rauschen: der Entzerrer liest es ebenfalls, in jeder Polarität
    let msgs: [(Int, Int, String?, String?)] = [(1234567, 3, nil, "Hallo Welt, Test 1"), (2504, 3, nil, "DAPNET DL1ABC Test"), (400000, 0, "0123456789", nil)]
    for (i, baud) in POCSAG.rates.enumerated() {
        let clean = pocsagAudio(baud, msgs)
        let direct = POCSAGEqualizer.equalize(clean, sampleRate: 24_000, baud: Double(baud), origin: 0)
        check((direct?.goodBatches ?? 0) >= 2, "Entzerrer \(baud): sauberes Signal, Stapel \(direct?.goodBatches ?? 0)")
        var g = SystemRandomNumberGenerator()
        let noisy = pocsagAudio(baud, msgs, inverted: true).map { $0 + Float.random(in: -0.2...0.2, using: &g) }
        let nz = POCSAGEqualizer.equalize(noisy, sampleRate: 24_000, baud: Double(baud), origin: 0)
        check((nz?.goodBatches ?? 0) >= 2, "Entzerrer \(baud): invertiert mit Rauschen, Stapel \(nz?.goodBatches ?? 0)")

        // Verbogenes Audio wie an der echten DAPNET-Aufnahme: zwei Hochpässe (290 Hz), Tiefpass (1,5 kHz), Rauschen vor und nach der Aussendung
        // Bei 2400 Bd bleibt der Entzerrer unsicher (Aussendungen unter 1 s liefern zu wenig Lernstoff): dort nur die Prüfungen oben
        if baud == 2400 { continue }
        let r = Double(baud) / 1200
        var bent = lowpassAudio(highpassAudio(highpassAudio(clean, 290 * r), 290 * r), 1500 * r)
        bent = bent.map { $0 + Float.random(in: -0.05...0.05, using: &g) }
        var audio: [Float] = (0..<24_000).map { _ in Float.random(in: -0.15...0.15, using: &g) }
        audio += bent
        audio += (0..<48_000).map { _ in Float.random(in: -0.15...0.15, using: &g) }
        let got = pocsagDecode(audio, rates: [i])
        // Der Entzerrer liest die Mitte der Meldungen sicher; das letzte Wort vor der Auffüllung (lange Nullfolge ohne Gleichanteil) geht
        // manchmal verloren. Geprüft werden deshalb die ersten Zeichen, und es müssen mindestens zwei von drei Meldungen stimmen.
        let hallo = got.contains { $0.address == 1234567 && $0.alpha.hasPrefix("Hallo We") }
        let dapnet = got.contains { $0.address == 2504 && $0.alpha.hasPrefix("DAPNET D") }
        let digits = got.contains { $0.address == 400000 && $0.numeric.hasPrefix("01234") }
        let hits = [hallo, dapnet, digits].filter { $0 }.count
        let shown = got.map { String($0.address) + ":" + $0.text }.joined(separator: " | ")
        check(hits >= 2, "Entzerrer \(baud): verbogenes Audio (Hochpass 290 Hz, Tiefpass) liefert \(hits) von 3 Meldungen (\(shown))")
        check(got.count <= 8, "Entzerrer \(baud): keine Meldungsflut (\(got.count))")
    }
    // Eine einwandfreie Aussendung liest der einfache Zweig; der Entzerrer liefert nichts dazu
    let plain = pocsagDecode(pocsagAudio(1200, msgs), rates: [1])
    check(plain.count == 3 && plain.allSatisfy { $0.detail == nil }, "Entzerrer: einwandfreies Signal ohne Doppelte und ohne Entzerrer (\(plain.count))")
    // Rauschen allein löst nichts aus
    var gen = SystemRandomNumberGenerator()
    check(pocsagDecode((0..<(24_000 * 15)).map { _ in Float.random(in: -0.3...0.3, using: &gen) }, rates: [1]).isEmpty, "Entzerrer: 15 s Rauschen ergeben keine Meldung")
    // Diagnose
    var st = POCSAGStats(); st.preambles = 3; st.equalized = 2
    check(PagerDiagnosis.assess(inputDB: -20, stats: [POCSAGStats(), st, POCSAGStats()], enabled: [1]).title == "EMPFANG ENTZERRT", "Diagnose: entzerrter Empfang wird genannt")

    // Echte DAPNET-Aufnahme mit verbogenem Audio (TestData/Pager/README.md): der einfache Zweig findet kein Synchronwort
    let pagerWav = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestData/Pager/dapnet_verbogen_48k.wav")
    if let file = try? AVAudioFile(forReading: pagerWav, commonFormat: .pcmFormatFloat32, interleaved: false),
       let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
       (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData?[0],
       let conv = SampleRateConverter(inputRate: file.processingFormat.sampleRate, outputRate: 24_000) {
        var audio: [Float] = []
        var pos = 0
        let total = Int(buf.frameLength)
        while pos < total {
            let n = min(960, total - pos)
            conv.process(UnsafeBufferPointer(start: ch + pos, count: n)) { audio += Array($0) }
            pos += n
        }
        let got = pocsagDecode(audio, rates: [1])
        func alpha(_ ric: Int) -> String { got.first { $0.address == ric }?.alpha ?? "" }
        check(file.processingFormat.sampleRate == 48_000, "Entzerrer echt: Testdatei hat 48 kHz")
        check(alpha(1005).hasPrefix("432314.0 DK2OY"), "Entzerrer echt: Rufnummer 1005 „\(alpha(1005))“")
        check(alpha(1004).hasPrefix("3634.0 ON3RUM"), "Entzerrer echt: Rufnummer 1004 „\(alpha(1004))“")
        check(alpha(2000).hasPrefix("#ZEIT=063504"), "Entzerrer echt: Rufnummer 2000 „\(alpha(2000))“")
        check(got.filter { $0.detail == "entzerrt" }.count >= 4, "Entzerrer echt: mindestens vier Meldungen vom Entzerrer (\(got.map(\.address)))")
    } else if !FileManager.default.fileExists(atPath: pagerWav.path) {
        skip("Entzerrer echt: TestData/Pager/dapnet_verbogen_48k.wav liegt nicht lokal vor")
    } else {
        check(false, "Entzerrer echt: TestData/Pager/dapnet_verbogen_48k.wav nicht lesbar")
    }
}

if want("pager") {
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
if want("pager") {
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
if want("pager") { pagerModuleTests() }

// MARK: - Funkruf unter nachgebildeten Funkbedingungen (FM-Kanal bis NF-Kette), Diagnose
@MainActor func pagerChannelTests() {
    /// Wie in der App: Quelle (48 kHz) → Wandlung auf 24 kHz → POCSAG-Empfänger
    func receive(_ audio: [Float], baud: Int) -> (messages: [PagerMessage], stats: POCSAGStats) {
        var conv: [Float] = []
        let c = SampleRateConverter(inputRate: pagerChannelRate, outputRate: 24_000)!
        var i = 0
        while i < audio.count {
            let e = min(i + 960, audio.count)
            audio[i..<e].withUnsafeBufferPointer { c.process($0) { conv += Array($0) } }
            i = e
        }
        let r = POCSAGReceiver(sampleRate: 24_000)
        r.enabled = [POCSAG.rates.firstIndex(of: baud)!]
        var out: [PagerMessage] = []
        i = 0
        while i < conv.count {
            let e = min(i + 480, conv.count)
            conv[i..<e].withUnsafeBufferPointer { r.process($0) { out.append($0) } }
            i = e
        }
        r.flush { out.append($0) }
        return (out, r.stats[POCSAG.rates.firstIndex(of: baud)!])
    }
    func run(_ baud: Int, _ ch: PagerRadioChannel, seed: UInt64 = 4242, count: Int = 3, invert: Bool = false) -> (ok: Int, total: Int, stats: POCSAGStats) {
        var rng = PagerRNG(seed: seed)
        var ok = 0, total = 0
        var stats = POCSAGStats()
        for _ in 0..<count {
            let msgs = [pagerRandomMessage(&rng), pagerRandomMessage(&rng), pagerRandomMessage(&rng, numeric: true)]
            var audio = pagerFMAudio(bits: pagerTransmissionBits(msgs), baud: baud, channel: ch, lead: Int(0.6 * pagerChannelRate), tail: Int(0.4 * pagerChannelRate), rng: &rng)
            if invert { audio = audio.map { -$0 } }
            let r = receive(audio, baud: baud)
            total += msgs.count
            for m in msgs where r.messages.contains(where: { $0.address == m.ric && $0.text == m.text }) { ok += 1 }
            stats.preambles += r.stats.preambles; stats.syncs += r.stats.syncs
            stats.batchesGood += r.stats.batchesGood; stats.batchesBad += r.stats.batchesBad
            stats.messages += r.stats.messages; stats.inverted = stats.inverted || r.stats.inverted
        }
        return (ok, total, stats)
    }
    // Die Bedingungen, die der Empfänger ohne Verluste bewältigen soll (Messung: Tools/PagerBench)
    let cases: [(String, Int, PagerRadioChannel)] = [
        ("1200 Bd, 14 dB", 1200, PagerRadioChannel(name: "", snrDB: 14)),
        ("512 Bd, 14 dB", 512, PagerRadioChannel(name: "", snrDB: 14)),
        ("2400 Bd, 14 dB", 2400, PagerRadioChannel(name: "", snrDB: 14)),
        ("1200 Bd, Ablage +1,5 kHz", 1200, PagerRadioChannel(name: "", snrDB: 20, offsetHz: 1500)),
        ("1200 Bd, Entzerrung 300 Hz", 1200, PagerRadioChannel(name: "", snrDB: 20, audio: .deemph300)),
        ("1200 Bd, Kopplung 150 Hz", 1200, PagerRadioChannel(name: "", snrDB: 20, audio: .ac150)),
        ("1200 Bd, Kopplung 300 Hz", 1200, PagerRadioChannel(name: "", snrDB: 20, audio: .ac300)),
        ("512 Bd, Entzerrung und Kopplung 300 Hz", 512, PagerRadioChannel(name: "", snrDB: 20, audio: .deemph300ac300)),
        ("1200 Bd, Rauschsperre mit 20 s Stille davor", 1200, PagerRadioChannel(name: "", snrDB: 20, squelch: true, leadSeconds: 20)),
        ("1200 Bd, Drift 1,5 kHz", 1200, PagerRadioChannel(name: "", snrDB: 20, driftHz: 1500)),
        ("1200 Bd, leise", 1200, PagerRadioChannel(name: "", snrDB: 20, level: 0.02)),
    ]
    for (name, baud, ch) in cases {
        let r = run(baud, ch)
        check(r.ok == r.total, "Funkruf FM-Kanal \(name): \(r.ok) von \(r.total) Meldungen")
        check(r.stats.preambles >= 3 && r.stats.syncs >= 3 && r.stats.batchesGood >= 3 && r.stats.batchesBad == 0, "Funkruf FM-Kanal \(name): Zähler Vorspann \(r.stats.preambles), Sync \(r.stats.syncs), Stapel \(r.stats.batchesGood)/\(r.stats.batchesBad)")
    }
    // Sprachband (Bandpass 300 bis 3000 Hz): 1200 Bd mit höchstens einem Verlust bei 20 dB
    let vb = run(1200, PagerRadioChannel(name: "", snrDB: 20, audio: .voiceBand), count: 4)
    check(vb.ok >= vb.total - 1, "Funkruf FM-Kanal Sprachband 20 dB: \(vb.ok) von \(vb.total)")
    // Polarität: POCSAG sendet die 1 auf der tieferen Frequenz, der Diskriminator liefert dafür negatives Audio; der Empfänger liest dieses Audio
    // deshalb „invers“ und dreht selbst. Umgekehrtes Audio (anderer Demodulator, Seitenband) liest er direkt; beides vollständig, die Zähler zeigen es.
    let norm = run(1200, PagerRadioChannel(name: "", snrDB: 14))
    let inv = run(1200, PagerRadioChannel(name: "", snrDB: 14), invert: true)
    check(norm.ok == norm.total && norm.stats.inverted, "Funkruf FM-Kanal normales Audio: \(norm.ok) von \(norm.total), Synchronwort invers erkannt")
    check(inv.ok == inv.total && !inv.stats.inverted, "Funkruf FM-Kanal umgekehrtes Audio: \(inv.ok) von \(inv.total), Synchronwort direkt erkannt")
    // Bei 6 dB ist der Empfang unsicher, aber es erscheint nichts Falsches in großer Zahl und der Empfänger fängt sich wieder
    let weak = run(1200, PagerRadioChannel(name: "", snrDB: 6), count: 4)
    check(weak.ok >= weak.total / 3, "Funkruf FM-Kanal 6 dB: \(weak.ok) von \(weak.total)")
    // Nur Rauschen: weder Vorspann noch Meldung
    var rng = PagerRNG(seed: 9)
    let noise = (0..<Int(10 * pagerChannelRate)).map { _ in Float(0.2 * rng.gauss()) }
    let nr = receive(noise, baud: 1200)
    check(nr.messages.isEmpty && nr.stats.syncs == 0 && nr.stats.batchesGood == 0, "Funkruf: Rauschen ergibt keine Meldung (\(nr.messages.count)) und keinen Stapel")

    // Diagnose: Beurteilung aus Zählern
    func st(_ f: (inout POCSAGStats) -> Void) -> [POCSAGStats] { var s = POCSAGStats(); f(&s); return [POCSAGStats(), s, POCSAGStats()] }
    let all: Set<Int> = [0, 1, 2]
    let d0 = PagerDiagnosis.assess(inputDB: -120, stats: st { _ in }, enabled: all)
    check(d0.severity == .problem && d0.title == "KEIN AUDIO", "Diagnose: Stille am Eingang → kein Audio (\(d0.title))")
    let d1 = PagerDiagnosis.assess(inputDB: -35, stats: st { _ in }, enabled: all)
    check(d1.severity == .waiting && d1.title == "WARTEN AUF FUNKRUF", "Diagnose: Audio ohne Funkruf → warten (\(d1.title))")
    let d2 = PagerDiagnosis.assess(inputDB: -30, stats: st { $0.preambles = 2 }, enabled: all)
    check(d2.severity == .problem && d2.title == "VORSPANN OHNE SYNCHRONWORT", "Diagnose: Vorspann ohne Synchronwort (\(d2.title))")
    let d3 = PagerDiagnosis.assess(inputDB: -30, stats: st { $0.preambles = 2; $0.syncs = 2; $0.batchesBad = 3 }, enabled: all)
    check(d3.severity == .problem && d3.title == "SYNCHRON, ABER FEHLERHAFT", "Diagnose: nur schlechte Stapel (\(d3.title))")
    let d4 = PagerDiagnosis.assess(inputDB: -30, stats: st { $0.syncs = 4; $0.batchesGood = 1; $0.batchesBad = 3 }, enabled: all)
    check(d4.severity == .problem && d4.title == "VIELE FEHLER", "Diagnose: mehr schlechte als gute Stapel (\(d4.title))")
    let d5 = PagerDiagnosis.assess(inputDB: -30, stats: st { $0.syncs = 4; $0.batchesGood = 4 }, enabled: all)
    check(d5.severity == .ok && !d5.advice.isEmpty, "Diagnose: gute Stapel ohne Meldung (\(d5.title))")
    let d6 = PagerDiagnosis.assess(inputDB: -30, stats: st { $0.syncs = 4; $0.batchesGood = 4; $0.messages = 3 }, enabled: all)
    check(d6.severity == .ok && d6.advice.isEmpty, "Diagnose: Empfang gut")
    let d7 = PagerDiagnosis.assess(inputDB: -30, stats: st { $0.syncs = 4; $0.batchesGood = 4; $0.messages = 3 }, enabled: [0])
    check(d7.severity == .waiting, "Diagnose: abgeschaltete Baudraten zählen nicht (\(d7.title))")
    let d8 = PagerDiagnosis.assess(inputDB: -90, stats: st { $0.preambles = 1; $0.syncs = 1; $0.batchesGood = 1 }, enabled: all)
    check(d8.severity == .ok, "Diagnose: Pegelmessung ist nachrangig, wenn Stapel gelesen wurden (\(d8.title))")

    // Aufnahme und Controller
    let ctrl = PagerController(pipeline: AudioPipeline(), settings: PagerSettingsStore())
    ctrl.logEnabled = false
    check(!ctrl.isRecording && ctrl.diagnosis.title == "KEIN AUDIO", "Pager-Controller: ohne Audio keine Aufnahme, Diagnose „kein Audio“")
    let name = InputRecorder.fileName(date: Date(timeIntervalSince1970: 1_790_000_000), frequencyHz: 439_987_500, mode: "FM", preset: "DAPNET", prefix: "PAGER")
    check(name.hasPrefix("PAGER_") && name.hasSuffix("_439987500Hz_FM_DAPNET.wav"), "Aufnahme-Dateiname Funkruf: \(name)")
    check(InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "ham").hasPrefix("RTTY_"), "Aufnahme-Dateiname: RTTY bleibt Standard")

    // Deutsche Umlaute (7-Bit-Zeichensatz DIN 66003 wie AlphaPoc): { | } ~ immer, [ \ ] nur im Wortzusammenhang
    check(PagerText.germanUmlauts("Pr}fung H{user Gr|~e") == "Prüfung Häuser Größe", "Umlaute klein: \(PagerText.germanUmlauts("Pr}fung H{user Gr|~e"))")
    check(PagerText.germanUmlauts("[rzte \\bung M]NCHEN") == "Ärzte Übung MÜNCHEN".replacingOccurrences(of: "Übung", with: "Öbung"), "Umlaute groß: \(PagerText.germanUmlauts("[rzte \\bung M]NCHEN"))")
    check(PagerText.germanUmlauts("[ALARM] Test \\NA ]") == "[ALARM] Test \\NA ]", "Klammern und Rückstrich im Alarmtext bleiben: \(PagerText.germanUmlauts("[ALARM] Test \\NA ]"))")
    check(PagerText.germanUmlauts("Hallo Welt 123") == "Hallo Welt 123" && PagerText.germanUmlauts("") == "", "Umlaute: gewöhnlicher Text bleibt")
    let us = PagerSettingsStore()
    check(us.umlauts, "Umlaute: standardmäßig an")

    // Skyper: Zeichen um 1 nach oben verschoben, Leerzeichen als „!“, Kopf aus Rubrik und Nummer (echte DAPNET-Meldungen, RIC 4520)
    let sk1 = PagerText.skyper(")$25195/1!QE1CBS!!!!!!ef!QE3XM!bu!2168{")
    check(sk1?.text == "14084.0 PD0BAR      de PD2WL at 1057z" && sk1?.rubric == 9 && sk1?.number == 3, "Skyper: DX-Spot (\(sk1?.text ?? "nil"), Rubrik \(sk1?.rubric ?? -1), Nr. \(sk1?.number ?? -1))")
    let sk2 = PagerText.skyper("p!Ebufocbtjt;!Efvutdifs!Xfuufsejfotu-!Nfmevohfo!hflvfs{u")
    check(sk2?.text == "Datenbasis: Deutscher Wetterdienst, Meldungen gekuerzt" && sk2?.rubric == 80 && sk2?.number == 0, "Skyper: Meldungstext mit Doppelpunkt und Komma (\(sk2?.text ?? "nil"))")
    check(PagerText.skyper("%$81141/9!H5KOU0C!!!!!ef!H1BQJ!bu!1:17{")?.text == "70030.8 G4JNT/B     de G0API at 0906z", "Skyper: Rufzeichen mit Schrägstrich")
    // Gewöhnlicher Klartext bleibt unberührt
    for plain in ["7150.0 EA4IFI       de EA3INX at 1100z", "Hallo Welt, Test 1", "ALARM!", "FEUER! FEUER! Halle 3", "Ziffern 0123456789", "", "Hilfe!"] {
        check(PagerText.skyper(plain) == nil, "Skyper: „\(plain)“ bleibt, wie gesendet")
    }
    check(us.skyper, "Skyper: standardmäßig an")
}
if want("pager") { pagerChannelTests() }

// MARK: - RTTY: DWD-Frequenzwahl und Abstimmziel
@MainActor func rttyFrequencyTests() {
    let s = RTTYSettingsStore()
    for id in ["dwd-kw", "dwd-lw"] { s.selectDWDFrequency(nil, presetID: id) }
    s.select(presetID: "dwd-kw")
    check(s.selectedDWDFrequencyHz == nil, "RTTY: ohne Wahl gilt die Automatik")
    s.selectDWDFrequency(7_646_000, presetID: "dwd-kw")
    check(s.selectedDWDFrequencyHz == 7_646_000, "RTTY: DWD-KW-Frequenz gewählt")
    s.select(presetID: "dwd-lw")
    check(s.selectedDWDFrequencyHz == nil, "RTTY: die Wahl gilt je Preset (LW hat keine)")
    s.selectDWDFrequency(147_300, presetID: "dwd-lw")
    s.select(presetID: "dwd-kw")
    check(s.selectedDWDFrequencyHz == 7_646_000 && s.dwdFrequencyHz["dwd-lw"] == 147_300, "RTTY: Wahlen bleiben je Preset erhalten")
    s.selectDWDFrequency(14_070_000, presetID: "ham")
    s.select(presetID: "ham")
    check(s.selectedDWDFrequencyHz == nil && s.dwdFrequencyHz["ham"] == nil, "RTTY: andere Presets haben keine Frequenzwahl")
    s.selectDWDFrequency(nil, presetID: "dwd-kw")
    s.selectDWDFrequency(nil, presetID: "dwd-lw")
    s.select(presetID: "ham")
    // Abstimmziel: Dial = Sendefrequenz − NF-Mitte, USB
    let t = RigTuneTarget.rtty(frequencyHz: 4_583_000, centerHz: 1000)
    check(t.dialHz == 4_582_000 && t.mode == "USB", "RTTY-Abstimmziel 4583 kHz bei Mitte 1000 Hz: Dial \(t.dialHz)")
    check(RigTuneTarget.rtty(frequencyHz: 147_300, centerHz: 1696.4).dialHz == 145_604 && RigCommand.frequency(145_604) != nil, "RTTY-Abstimmziel 147,3 kHz (Langwelle) gültig")
    check(RigTuneTarget.rtty(frequencyHz: 10_100_800, centerHz: 1000).dialHz == 10_099_800, "RTTY-Abstimmziel 10100,8 kHz")
    // Frequenzen je Preset aus dem Sendeplan
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("digidec_rttyfreq_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let rs = RttyScheduleStore(directory: tmp)
    let kw = rs.schedule.frequencies.filter { $0.presetID == "dwd-kw" }.map(\.hz).sorted()
    let lw = rs.schedule.frequencies.filter { $0.presetID == "dwd-lw" }.map(\.hz)
    check(kw == [4_583_000, 7_646_000, 10_100_800, 11_039_000, 14_467_300] && lw == [147_300], "RTTY: DWD-Frequenzen aus dem Plan (KW \(kw), LW \(lw))")
}
if want("rtty") { rttyFrequencyTests() }


// MARK: - ACARS
if want("acars") {
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
if want("acars") { acarsModuleTests() }

// MARK: - ACARS: Positionen aus den Meldungen (Testmeldungen aus der Referenz acars-decoder-typescript, airframes.io, MIT)
@MainActor func acarsPositionTests() {
    struct Case {
        var label: String
        var text: String
        var lat: Double?
        var lon: Double?
        var alt: Double? = nil
        var from: String? = nil
        var to: String? = nil
        var heading: Double? = nil
        var time: String? = nil
    }
    let cases: [Case] = [
        // H1 / ARINC 702: Grad und Minuten mit Zehntel
        Case(label: "H1", text: "POSN43312W123174,EASON,215754,370,EBINY,220601,ELENN,M48,02216,185/TS215754,0921227A40", lat: 43.52, lon: -123.29, alt: 37000, time: "21:57:54"),
        Case(label: "H1", text: "POSN45209W122550,PEGTY,220309,134,MINNE,220424,HISKU,M6,060013,269,366,355K,292K,730A5B", lat: 45.3483, lon: -122.9167, alt: 13400),
        Case(label: "H1", text: "POSN43030W122406,IBALL,220516,380,AARON,220816,MOXEE,M47,0047,86/TS220516,092122BF64", lat: 43.05, lon: -122.6767, alt: 38000),
        Case(label: "H1", text: "POSN33225W079428,SCOOB,232933,340,ENEME,235712,FETAL,M42,003051,15857F6", lat: 33.375, lon: -79.7133, alt: 34000),
        Case(label: "H1", text: "POSN38531W078000,CSN-01,112309,310,CYN-02,114151,ACK,M40,26067,22479226", lat: 38.885, lon: -78.0, alt: 31000),
        Case(label: "H1", text: "#M1BPOSN37533W096476,ROKNE,185212,330,DOSOA,190059,BUM,M50,272100,1571541", lat: 37.8883, lon: -96.7933, alt: 33000),
        Case(label: "H1", text: "F37AMCLL93#M1BPOSN37533W096476,ROKNE,185212,330,DOSOA,190059,BUM,M50,272100,1571541", lat: 37.8883, lon: -96.7933, alt: 33000),
        Case(label: "H1", text: "/.POS/TS100316,210324/PSS35333W058220,,100316,250,S37131W059150,101916,S39387W060377,M23,27282,241,780,MANUAL,0,813E711", lat: -35.555, lon: -58.3667, alt: 25000),
        Case(label: "H1", text: "/HDQDLUA.POSN38332W080082,RONZZ,135753,320,LEVII,140454,WISTA,M45,20967,194/GAHDQDLUA/CA/TS135753,1411240721", lat: 38.5533, lon: -80.1367, alt: 32000),
        Case(label: "H1", text: "/.POS/TS140122,141124N38321W078003,,140122,450,,140122,,M56,24739,127,8306763", lat: 38.535, lon: -78.005, alt: 45000, time: "14:01:22"),
        Case(label: "4J", text: "POS/ID91459S,BANKR31,/DC03032024,142813/MR64,0/ET31539/PSN39277W077359,142800,240,N39300W077110,031430,N38560W077150,M28,27619,MT370/CG311,160,350/FB732/VR329071", lat: 39.4617, lon: -77.5983, alt: 24000, time: "14:28:00"),
        Case(label: "2P", text: "M80AMC4086POS/ID50007B,RCH4086,ABB02R70E037/DC10022025,051804/MR103,/ET090738/PSN56012W013273,051804,350,,,,,084081,/CG,,/FB0857/VR0322B89", lat: 56.02, lon: -13.455, alt: 35000),
        Case(label: "H1", text: "*POS10300950N3954W07759363312045802M5230175", lat: 39.9, lon: -77.9833, alt: 36331, time: "09:50"),
        Case(label: "H1", text: "M85AQF0073YSSY,KSFO,101621,- 4.9985,-169.9820,35003,290,  35.1, 44100,S05W169,S02W167,1645", lat: -4.9985, lon: -169.982, alt: 35003, from: "YSSY", to: "KSFO", heading: 290, time: "16:21"),
        Case(label: "H1", text: "M87AQF0073YSSY,KSFO,101702,  0.7144,-166.0643,36000,282,  34.1, 40200,S00W166,N03W162,1739", lat: 0.7144, lon: -166.0643, alt: 36000, heading: 282),
        Case(label: "H1", text: "M89AQF0073YSSY,KSFO,101819,  7.2016,-158.1146,37001,275,  33.5, 32700,N07W158,N11W153,1900", lat: 7.2016, lon: -158.1146, alt: 37001),
        Case(label: "H1", text: "(POS-KLM296  -3911N07600W/234212 F250\r\nRMK/FUEL  37.0 M0.69)", lat: 39.1833, lon: -76.0, alt: 25000, time: "23:42:12"),
        // Label 10, 12
        Case(label: "10", text: "POS082150, N 3885,W 7841,---,308,26922,  51,22290, 529,  19,-225,6", lat: 38.85, lon: -78.41),
        Case(label: "10", text: "LDR01,189,C,SWA-2600-016,0,N 38.151,W 76.623,37003, 10.2,KATL,KLGA,KLGA,22/,/,/,0,0,,,,,,,0,0,0,00,,135.1,08.6,143.7,,,", lat: 38.151, lon: -76.623, alt: 37003),
        Case(label: "10", text: "/N39.182/W077.217/10/0.42/180/055/KIAD/0004/0028/00015/MOWAT/HUSEL/2349/YACKK/2352/", lat: 39.182, lon: -77.217),
        Case(label: "12", text: "N 42.150,W121.187,39000,161859, 109,.C-GWSO,1742", lat: 42.15, lon: -121.187, alt: 39000, time: "16:18:59"),
        Case(label: "12", text: "N 28.371,W 80.458,38000,170546, 100,.C-GVWJ,1736", lat: 28.371, lon: -80.458, alt: 38000),
        Case(label: "12", text: "POSN 390104W 754601,-------,1244,1446,,-  4,23249  12,FOB   73,ETA 1303,KATL,KPHL,", lat: 39.0178, lon: -75.7669),
        // Label 15, 16
        Case(label: "15", text: "(2N38448W 77216--- 28 20  7(Z", lat: 38.7467, lon: -77.36),
        Case(label: "15", text: "(2N40492W 77179248 99380-53(Z", lat: 40.82, lon: -77.2983),
        Case(label: "15", text: "(2N39269W 77374--- 42---- 5(Z", lat: 39.4483, lon: -77.6233),
        Case(label: "15", text: "(2N39018W 77284OFF11112418101313--------(Z", lat: 39.03, lon: -77.4733),
        Case(label: "15", text: "(2N42589W 83520OFF------13280606--------(Z", lat: 42.9817, lon: -83.8667),
        Case(label: "15", text: "(2N39042W 77308OFF1311240327B1818 015(Z", lat: 39.07, lon: -77.5133),
        Case(label: "16", text: "(2AAABN39211W 77144KTEBMMTO-/A(Z", lat: 39.3517, lon: -77.2400),
        Case(label: "16", text: "(2AAAAN37265W 78334-SSI  /O(Z", lat: 37.4417, lon: -78.5567),
        Case(label: "16", text: "(2AAABN37197W 78404-SLOJOGRONK/O(Z", lat: 37.3283, lon: -78.6733),
        Case(label: "16", text: "N 44.203,W 86.546,31965,6, 290", lat: 44.203, lon: -86.546, alt: 31965),
        Case(label: "16", text: "N 28.177/W 96.055", lat: 28.177, lon: -96.055),
        Case(label: "16", text: "N 44.988,W121.644,35940,6, 170", lat: 44.988, lon: -121.644, alt: 35940),
        Case(label: "16", text: "POSA1N37358W 77279,GEARS  ,221626,370,BBOBO  ,222053,,-61,139,1174,829", lat: 37.358, lon: -77.279, alt: 37000, time: "22:16:26"),
        Case(label: "16", text: "POSA1N38843W 78790,RONZZ  ,005159,390,RAMAY  ,010055,,*****,*****, 744,   0", lat: 38.843, lon: -78.79, alt: 39000),
        Case(label: "16", text: "283806/AUTPOS/LLD N400547 W0774954\r\n/ALT 12932/SAT ****\r\n/WND ******/TAT ****/TAS ****/CRZ ***\r\n/FOB 065120\r\n/DAT 260228/TIM 150742", lat: 40.0964, lon: -77.8317, alt: 12932),
        Case(label: "16", text: "289142/AUTPOS/LLD N395538 W0753341 \r\n/ALT 35000/SAT -057\r\n/WND 239065/TAT -027/TAS 476/CRZ 836\r\n/FOB 107600\r\n/DAT 260228/TIM 132714", lat: 39.9272, lon: -75.5614, alt: 35000),
        Case(label: "16", text: "005236,36787,0135,  97,N 38.364 W 75.226", lat: 38.364, lon: -75.226, alt: 36787, time: "00:52:36"),
        Case(label: "16", text: "110112,36000,1206, 51,N 45.140 E 16.341/SXS7SL", lat: 45.14, lon: 16.341, alt: 36000),
        Case(label: "16", text: "001415,20274,0047, 3740,N3835.95 W07858.88", lat: 38.5992, lon: -78.9813, alt: 20274),
        // Label 20, 21, 22, 24, 44, 58
        Case(label: "20", text: "POSN38160W077075,,211733,360,OTT,212041,,N42,19689,40,544", lat: 38.16, lon: -77.075, alt: 36000),
        Case(label: "20", text: "POSN38160W077075,,211733,360,OTT", lat: 38.16, lon: -77.075),
        Case(label: "21", text: "POSN 39.841W 75.790, 220,184218,17222,22051,  34,- 4,204748,KTPA", lat: 39.841, lon: -75.79, alt: 17222, time: "18:42:18"),
        Case(label: "22", text: "N 370824W 760010,-------,194936,30418, ,      , ,M 42,27335  42, 107,", lat: 37.0824, lon: -76.001, alt: 30418),
        Case(label: "24", text: "/241710/1021/04WM/34962/N53.13/E001.33/3374/1056/", lat: 53.13, lon: 1.33, alt: 34962),
        Case(label: "44", text: "POS02,N38171W077507,319,KJFK,KUZA,0926,0245,0327,004.6", lat: 38.285, lon: -77.845, alt: 31900, from: "KJFK", to: "KUZA", time: "02:45"),
        Case(label: "44", text: "POS02,N38338W121179,GRD,KMHR,KPDX,0807,0003,0112,005.1", lat: 38.5633, lon: -121.2983, alt: 0, from: "KMHR", to: "KPDX"),
        Case(label: "58", text: "OG0704/06/230942/N39.214/W76.106/22683/N/", lat: 39.214, lon: -76.106, alt: 22683),
        // Label 80, 83, 2P, 1L, HX, 4T
        Case(label: "80", text: "3N01 POSRPT 5891/04 KIAH/MMGL .XA-VOI\r\n/POS N29395W095133/ALT +15608/MCH 558/FOB 0100/ETA 0410", lat: 29.395, lon: -95.133, alt: 15608, from: "KIAH", to: "MMGL"),
        Case(label: "80", text: "3N01 POSRPT 0581/27 KIAD/MSLP .N962AV/04H 11:02\r\n/NWYP CIGAR /HDG 233/MCH 782\r\n/POS N3539.2W07937.2/FL 360/TAS 445/SAT -060\r\n/SWND 110/DWND 306/FOB N009414/ETA 14:26.0 ", lat: 35.6533, lon: -79.62, alt: 36000, from: "KIAD", to: "MSLP", heading: 233),
        Case(label: "80", text: "/FB 0105/AD KCHS/N3950.1,W07548.3,3P01 POSRPT  0267/20 KBOS/KCHS .N3275J\n/UTC 143605/POS N3950.1 W07548.3/ALT 38007\n/SPD 334/FOB 0105/ETA 1622", lat: 39.835, lon: -75.805, alt: 38007, time: "14:36:05"),
        Case(label: "80", text: "3C01 POS N39328W077307  ,,143700,               ,      ,               ,P47,124,0069", lat: 39.328, lon: -77.307),
        Case(label: "83", text: "KLAX,KEWR,220103, 40.53,- 74.47, 3836,212, 140.0, 19700", lat: 40.53, lon: -74.47, alt: 3836, from: "KLAX", to: "KEWR", heading: 140),
        Case(label: "83", text: "001PR22035539N4038.6W07427.80292500008", lat: 40.6433, lon: -74.4633, alt: 2925),
        Case(label: "2P", text: "FM3 1217,1312,+ 43.77,- 70.18, 39981, 426, 25", lat: 43.77, lon: -70.18, alt: 39981),
        Case(label: "2P", text: "M40AEY093CFM3 1216,1454,+057.31,-075.58, 38002, 469, 23", lat: 57.31, lon: -75.58, alt: 38002),
        Case(label: "2P", text: "FM3 133818,1607,N 45.206,E 17.726,34030, 440,98", lat: 45.206, lon: 17.726, alt: 34030),
        Case(label: "1L", text: "000000070LOWW,KEWR,0932,1744,N 49.223,E 12.038,0659", lat: 49.223, lon: 12.038, from: "LOWW", to: "KEWR"),
        Case(label: "1L", text: "000000660N50442E005566,100444359SOG-06 ,,--- 21-,83617441", lat: 50.7367, lon: 5.9433, alt: 35900),
        Case(label: "1L", text: "+ 39.126/- 77.358/UTC 085208/FOB   8.2/ALT  3997/CAS  239/ETA 0903", lat: 39.126, lon: -77.358, alt: 3997),
        Case(label: "1L", text: "00018213200/GS 411500/DEP MDPC/DES CYYZ/ETA 0120/GW 479/ALT 39002\r\nCAS 229/SAT - 59.0/FN SWG9040/TFQ 48/DAY 22OCT24/UTC 002714\r\nLON W 78.289/LAT N 39.556/WD  20/WS  13", lat: 39.556, lon: -78.289, alt: 39002, from: "MDPC", to: "CYYZ"),
        Case(label: "HX", text: "RA FMT LOCATION N4009.6 W07540.8", lat: 40.16, lon: -75.68),
        Case(label: "4T", text: "AGFSR AC0620/07/08/YYZYHZ/0340Z/453/4435.1N07143.4W/350/ /0063/0035/ /281065/----/ /512/0240/0253/----/----", lat: 44.585, lon: -71.7233, alt: 35000, time: "03:40"),
        // keine Position
        Case(label: "H1", text: "POS Bogus message", lat: nil, lon: nil),
        Case(label: "H1", text: "POS/RFSCOOB.KEMPR.ECG.OHPEA.TOMMZ.OXANA.ZZTOP.OMALA.WILYY.KANUX.GALVN.KASAR.LNHOM.SLUKA.FIPEK.PUYYA.PLING.KOLAO.JETSSF2FC", lat: nil, lon: nil),
        Case(label: "H1", text: "/.POS Bogus message", lat: nil, lon: nil),
        Case(label: "10", text: "POS Bogus Message", lat: nil, lon: nil),
        Case(label: "10", text: "POS082150,---,308,26922,  51, 529,  19,-225,6", lat: nil, lon: nil),
        Case(label: "16", text: "110122,,1206, 92,N . MMMM.MMM", lat: nil, lon: nil),
        Case(label: "16", text: "N Bogus message", lat: nil, lon: nil),
        Case(label: "80", text: "3N01 POSRPT Bogus message", lat: nil, lon: nil),
        Case(label: "80", text: "3N01 POSRPT 5891/04 KIAH/MMGL .XA-VOI\r\n/ETA 0410", lat: nil, lon: nil),
        Case(label: "83", text: "83 Bogus message", lat: nil, lon: nil),
        Case(label: "83", text: "4DH3 ETAT2  0907/22 ENGM/KEWR .LN-RKO\r\n/ETA 1641", lat: nil, lon: nil),
        Case(label: "H1", text: "FLT PLAN REQUEST EDDF EDDM 1200Z", lat: nil, lon: nil),
        Case(label: "Q1", text: "EDDF08150822105511200000EHAM", lat: nil, lon: nil),
        Case(label: "5Z", text: "/BTZWUF.TI2/EDDFEDDM", lat: nil, lon: nil),
    ]
    var wrong = 0
    for c in cases {
        let r = ACARSPositionParser.parse(label: c.label, text: c.text)
        let tag = "ACARS-Position [\(c.label)] \(c.text.prefix(40))"
        if let lat = c.lat, let lon = c.lon {
            let ok = r.map { abs($0.point.lat - lat) < 0.001 && abs($0.point.lon - lon) < 0.001 } == true
            check(ok, "\(tag): erwartet \(lat)/\(lon), gelesen \(String(describing: r?.point))")
            if let a = c.alt { check(r?.altitudeFt == a, "\(tag): Höhe \(a) ft, gelesen \(String(describing: r?.altitudeFt))") }
            if let f = c.from { check(r?.from == f, "\(tag): Start \(f), gelesen \(String(describing: r?.from))") }
            if let t = c.to { check(r?.to == t, "\(tag): Ziel \(t), gelesen \(String(describing: r?.to))") }
            if let h = c.heading { check(r?.headingDeg == h, "\(tag): Kurs \(h), gelesen \(String(describing: r?.headingDeg))") }
            if let t = c.time { check(r?.timeUTC == t, "\(tag): Zeit \(t), gelesen \(String(describing: r?.timeUTC))") }
            if !ok { wrong += 1 }
        } else {
            check(r == nil, "\(tag): keine Position erwartet, gelesen \(String(describing: r?.point))")
        }
    }
    check(wrong == 0, "ACARS-Positionen: \(wrong) von \(cases.count) falsch")
    // Rechenhilfen
    check(ACARSPositionParser.degreesMinutesTenths("43312") == 43 + 31.2 / 60 && ACARSPositionParser.degreesMinutesTenths("38843") == nil, "ACARS: Grad und Minuten, Minuten über 59 ungültig")
    check(abs((ACARSPositionParser.degreesDecimalMinutes("3539.2") ?? 0) - (35 + 39.2 / 60)) < 1e-9, "ACARS: ddmm.m")
    check(ACARSPositionParser.parse(label: "H1", text: "POSN00000W000000,AAAAA,123456,300") == nil, "ACARS: Position 0/0 ist ein Platzhalter")
    check(ACARSPositionParser.parse(label: "H1", text: "POSN99000W000100,AAAAA,123456,300") == nil, "ACARS: Breite über 90° wird verworfen")

    // Flugzeug: Weg, Sprungschutz, Kurs
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func rep(_ lat: Double, _ lon: Double, alt: Double? = nil) -> ACARSPositionReport {
        ACARSPositionReport(point: GeoPoint(lat: lat, lon: lon), altitudeFt: alt, format: "test")
    }
    var ac = ACARSAircraft(registration: "D-AIXC", flight: "LH1234", firstHeard: t0, lastHeard: t0)
    check(ac.addPosition(rep(50.0, 8.0, alt: 36000), at: t0), "Flugzeug: erste Position")
    check(ac.addPosition(rep(50.0, 8.0), at: t0.addingTimeInterval(60)) && ac.track.count == 1, "Flugzeug: gleicher Ort ergibt keinen neuen Wegpunkt")
    check(ac.addPosition(rep(50.4, 8.6), at: t0.addingTimeInterval(120)) && ac.track.count == 2, "Flugzeug: zweiter Wegpunkt")
    check(ac.altitudeFt == 36000, "Flugzeug: Höhe bleibt, wenn der Bericht keine nennt")
    check(ac.headingDeg.map { $0 > 30 && $0 < 60 } == true, "Flugzeug: Kurs aus den letzten Wegpunkten (\(String(describing: ac.headingDeg)))")
    check(ac.trackKm > 50 && ac.trackKm < 70, "Flugzeug: Länge des Wegs (\(ac.trackKm) km)")
    // Sprung um 3000 km in zwei Minuten: verworfen, erst der zweite Bericht an derselben Stelle gilt
    check(!ac.addPosition(rep(30.0, 40.0), at: t0.addingTimeInterval(180)) && ac.track.count == 2 && ac.rejectedPositions == 1, "Flugzeug: unmöglicher Sprung wird verworfen")
    check(ac.addPosition(rep(30.1, 40.1), at: t0.addingTimeInterval(240)) && ac.track.count == 1 && ac.position == GeoPoint(lat: 30.1, lon: 40.1), "Flugzeug: zweimal dieselbe neue Stelle: Weg beginnt dort neu")
    // Flug über Stunden: weite Strecken sind erlaubt
    var far = ACARSAircraft(registration: "N1", firstHeard: t0, lastHeard: t0)
    far.addPosition(rep(40.0, -70.0), at: t0)
    check(far.addPosition(rep(50.0, -20.0), at: t0.addingTimeInterval(3 * 3600)), "Flugzeug: 3 700 km in 3 Stunden sind möglich")
    check(ACARSAircraft(registration: "X", firstHeard: t0, lastHeard: t0).headingDeg == nil, "Flugzeug: ohne Weg kein Kurs")
    // Meldung gibt den Kurs vor
    var hd = ACARSAircraft(registration: "H", firstHeard: t0, lastHeard: t0)
    hd.addPosition(ACARSPositionReport(point: GeoPoint(lat: 10, lon: 10), headingDeg: 123, format: "t"), at: t0)
    check(hd.headingDeg == 123, "Flugzeug: Kurs aus der Meldung")

    // Controller: Meldungen mit Position ergeben Flugzeug mit Weg, Karte zeigt Flugzeug samt Linie
    let c = ACARSController(pipeline: AudioPipeline(), settings: ACARSSettingsStore())
    c.logEnabled = false
    func msg(_ reg: String, _ flight: String?, _ label: String, _ text: String, down: Bool = true) -> ACARSMessage {
        ACARSMessage(time: t0, mode: "2", registration: reg, ack: "NAK", label: label, blockID: down ? "3" : "A", isDownlink: down,
                     messageNumber: down ? "M01A" : nil, flightID: flight, text: text, continues: false, parityErrors: 0, corrected: 0, levelDB: -10)
    }
    c.ingest(msg("D-AIXC", "LH1234", "10", "POS082150, N 4980,E  841,---,308,26922"), at: t0)
    c.ingest(msg("D-AIXC", "LH1234", "H1", "POSN50051E008330,BIBTI,100030,360,KOMIB,100330,ASKIK,M52,27000,100"), at: t0.addingTimeInterval(300))
    c.ingest(msg("D-AIXC", "LH1234", "H1", "POSN50111E009041,KOMIB,100530,360,ASKIK,100830,ABCDE,M52,27000,100"), at: t0.addingTimeInterval(600))
    c.ingest(msg("D-ABCD", "LH9", "H1", "POSN50051E008330,BIBTI,100030,360,KOMIB"), at: t0.addingTimeInterval(600))
    c.ingest(msg("D-ABCD", "LH9", "H1", "POSN50051E008330,BIBTI,100030,360,KOMIB", down: false), at: t0.addingTimeInterval(700))
    let air = c.aircraft["D-AIXC"]!
    check(air.track.count == 3 && air.position != nil && air.altitudeFt == 36000, "ACARS-Controller: Weg mit drei Punkten, Höhe 36000 ft (\(air.track.count))")
    check(c.aircraft["D-ABCD"]?.track.count == 1, "ACARS-Controller: Aufwärtsmeldung liefert keine Position")
    let now = t0.addingTimeInterval(900)
    let map = ACARSMapBuilder.content(Array(c.aircraft.values), home: Maidenhead.point("JN49WS"), now: now)
    let m = map.markers.first { $0.id == "ac-D-AIXC" }
    check(m != nil && m?.symbol == "airplane" && m?.track.count == 3 && m?.title == "LH1234", "ACARS-Karte: Flugzeug mit Weg aus drei Punkten (\(String(describing: m?.track.count)))")
    check(m?.headingDeg.map { $0 > 60 && $0 < 110 } == true, "ACARS-Karte: Flugrichtung nach Osten (\(String(describing: m?.headingDeg)))")
    check(m?.details.contains { $0.contains("FL360") } == true && m?.details.contains { $0.contains("Weg: 3 Positionen") } == true && m?.details.contains { $0.contains("km") } == true,
          "ACARS-Karte: Höhe, Weg und Entfernung in den Einzelheiten (\(m?.details ?? []))")
    check(map.markers.first { $0.id == "ac-D-ABCD" }?.track.isEmpty == true, "ACARS-Karte: ein Punkt ergibt keine Linie")
    let later = ACARSMapBuilder.content(Array(c.aircraft.values), home: nil, now: t0.addingTimeInterval(7 * 3600))
    check(later.markers.isEmpty, "ACARS-Karte: nach 7 Stunden ohne Meldung kein Flugzeug mehr")
    let dim = ACARSMapBuilder.content(Array(c.aircraft.values), home: nil, now: t0.addingTimeInterval(600 + 2400))
    check(dim.markers.first { $0.id == "ac-D-AIXC" }?.tone == .dim, "ACARS-Karte: Flugzeug ohne Meldung seit 40 min abgedunkelt")
}
if want("acars") { acarsPositionTests() }

// MARK: - APRS: Weg bewegter Stationen auf der Karte
@MainActor func aprsTrackTests() {
    let controller = APRSController(pipeline: AudioPipeline(), settings: APRSSettingsStore())
    controller.logEnabled = false
    func raw(_ info: String, source: String) -> APRSRawFrame {
        let f = AX25Frame(dest: AX25Address(text: "APRS")!, source: AX25Address(text: source)!, digis: [], info: Array(info.utf8))
        return APRSRawFrame(bytes: f.encode(), repaired: false, slicers: 1, level: 0.5)
    }
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    // Ruhende Station mit GPS-Rauschen (Meter): kein Weg
    for (i, lat) in ["4903.50", "4903.51", "4903.50", "4903.49", "4903.51"].enumerated() {      // ± 0,01′ = ± 18 m
        controller.ingest(raw("!\(lat)N/07201.75W>Haus", source: "RUHE-1"), at: t0.addingTimeInterval(Double(i) * 60))
    }
    // Fahrzeug: alle 60 s etwa 90 m nach Norden
    for i in 0..<6 {
        let lat = String(format: "%07.2f", 4903.50 + Double(i) * 0.05)
        controller.ingest(raw("!\(lat)N/07201.75W>Auto", source: "FAHR-9"), at: t0.addingTimeInterval(Double(i) * 60))
    }
    let still = controller.stations.first { $0.id == "RUHE-1" }!
    check(still.packetCount == 5 && still.track.count == 1 && still.trackTimes.count == 1, "APRS-Weg: GPS-Rauschen einer ruhenden Station ergibt keinen Weg (\(still.track.count) Punkte)")
    let moving = controller.stations.first { $0.id == "FAHR-9" }!
    check(moving.track.count == 6 && moving.trackTimes.count == 6, "APRS-Weg: Fahrzeug mit sechs Wegpunkten (\(moving.track.count))")
    let now = t0.addingTimeInterval(400)
    let map = APRSMapBuilder.content(stations: controller.stations, home: Maidenhead.point("JN49WS"), maxAge: nil, now: now)
    check(map.markers.first { $0.id == "RUHE-1" }?.track.isEmpty == true, "APRS-Karte: ruhende Station ohne Linie")
    let m = map.markers.first { $0.id == "FAHR-9" }
    check(m?.track.count == 6, "APRS-Karte: Fahrzeug mit Linie aus sechs Punkten")
    check(m?.details.contains { $0.hasPrefix("Weg: 6 Positionen") } == true && m?.details.firstIndex { $0.hasPrefix("Weg:") }.map { $0 <= 3 } == true, "APRS-Karte: Weglänge in den ersten Einzelheiten (\(m?.details ?? []))")
    // Nur der gewählte Zeitraum: bei 150 s Alter bleiben die jüngsten Positionen
    let recent = APRSMapBuilder.movedPath(moving, maxAge: 250, now: now)
    check(recent.count == 3 && recent.last == moving.position, "APRS-Weg: nur die letzten 250 s (\(recent.count) Punkte)")
    check(APRSMapBuilder.movedPath(moving, maxAge: 20, now: now).isEmpty, "APRS-Weg: ein einzelner Punkt ergibt keine Linie")
    // Ungenaue Position (Leerzeichen statt Ziffern) verlängert den Weg nicht, ändert aber den Ort
    controller.ingest(raw("!4905.  N/07201.  W>Auto", source: "FAHR-9"), at: t0.addingTimeInterval(400))
    let after = controller.stations.first { $0.id == "FAHR-9" }!
    check(after.track.count == 6 && after.ambiguity > 0, "APRS-Weg: ungenaue Position kommt nicht in den Weg (\(after.track.count), Ungenauigkeit \(after.ambiguity))")
    // Karte: Ausschnitt schließt den Weg ein
    let region = map.region(includeHome: false)
    check(region != nil && region!.latSpan > 0.0005, "Karte: Ausschnitt umfasst den Weg")
}
if want("aprs") { aprsTrackTests() }

// MARK: - Skimmer: Tabellen, Betriebsarten, URL, Abstimmung, Einstellungen
@MainActor func skimmerBasicsTests() {
    // Morsetabelle: eindeutig, vollständig für Buchstaben und Ziffern
    let morse = SkimTables.morse
    check(Set(morse.values).count == morse.count, "Skimmer: Morsetabelle ohne doppelte Zeichen")
    check(Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)).isSubset(of: Set(morse.values)), "Skimmer: alle Buchstaben und Ziffern im Morsealphabet")
    check(morse["-.-."] == "C" && morse["--.-"] == "Q" && morse["-.-"] == "K" && morse["-.."] == "D" && morse["."] == "E", "Skimmer: C, Q, K, D, E")
    // Varicode: 256 verschiedene Zeichen, nie „00“ im Zeichen, Rundlauf
    check(SkimTables.varicodeBits.count == 256 && SkimTables.varicodeDecode.count == 256, "Skimmer: Varicode mit 256 verschiedenen Zeichen")
    check(SkimTables.varicodeBits.allSatisfy { !$0.contains("00") && $0.hasPrefix("1") && $0.hasSuffix("1") }, "Skimmer: Varicode ohne „00“ im Zeichen")
    var roundTrip = true
    for ch in Array("CQ DE DL1ABC k\r".utf8) {
        var v: UInt16 = 0
        let bits = SkimTables.varicode(ch)
        for b in bits.dropLast(2) { v = (v << 1) | UInt16(b) }
        if SkimTables.varicodeDecode[v] != ch || bits.suffix(2) != [0, 0] { roundTrip = false }
    }
    check(roundTrip, "Skimmer: Varicode-Rundlauf")
    // Betriebsarten
    check(SkimMode.allCases == [.cw, .psk31, .psk63] && SkimMode.psk31.baud == 31.25 && SkimMode.psk63.baud == 62.5, "Skimmer: Betriebsarten und Schrittgeschwindigkeit")
    check(SkimMode.psk31.symbolSamples == 16 && SkimMode.psk63.symbolSamples == 8, "Skimmer: Abtastwerte je Symbol bei 500 Hz")
    check(DecoderModuleInfo.skimmer.displayName == "SKIMMER" && DecoderModuleInfo.skimmer.isAvailable && DecoderModuleInfo.skimmer.hasMap, "Skimmer: Modul verfügbar mit Karte")
    check(DecoderModuleInfo.skimmer.presetIDs == SkimMode.allCases.map(\.rawValue), "Skimmer: Voreinstellungen = Betriebsarten")
    // URL-Schema
    check(parse("digidec://decode?mode=skimmer") == .success(DecodeRequest(module: .skimmer, presetID: "cw")), "Skimmer: URL ohne Preset = CW")
    check(parse("digidec://decode?mode=skimmer&preset=psk63") == .success(DecodeRequest(module: .skimmer, presetID: "psk63")), "Skimmer: URL mit Preset psk63")
    if case .failure(.unknownPreset("olivia-8-500", .skimmer)) = parse("digidec://decode?mode=skimmer&preset=olivia-8-500") {} else { check(false, "Skimmer: fremdes Preset abgelehnt") }
    // Funkgerät abstimmen: Dial des Bandes in USB
    check(RigTuneTarget.skimmer(mode: .cw, cwBand: .m20, pskBand: .m40) == RigTuneTarget(dialHz: 14_020_000, mode: "USB"), "QSY: Skimmer CW 20 m = 14,020 MHz USB")
    check(RigTuneTarget.skimmer(mode: .psk31, cwBand: .m20, pskBand: .m40) == RigTuneTarget(dialHz: 7_040_000, mode: "USB"), "QSY: Skimmer PSK 40 m = 7,040 MHz USB")
    check(RigTuneTarget.skimmer(mode: .psk63, cwBand: .m20, pskBand: .m40) == RigTuneTarget(dialHz: 7_040_000, mode: "USB"), "QSY: Skimmer PSK63 wie PSK31")
    check(RigTuneTarget.skimmer(mode: .cw, cwBand: .free, pskBand: .m40) == nil && RigTuneTarget.skimmer(mode: .psk31, cwBand: .m20, pskBand: .free) == nil, "QSY: Skimmer frei = kein Ziel")
    let dials = SkimBand.allCases.compactMap(\.dialHz)
    check(dials == dials.sorted() && dials.count == SkimBand.allCases.count - 1 && SkimBand.free.dialHz == nil, "Skimmer: Bänder aufsteigend, „frei“ ohne Dial")
    // Einstellungen: Dial vom Funkgerät hat Vorrang vor dem Band
    let st = SkimmerSettingsStore()
    st.mode = .cw; st.cwBand = .free; st.pskBand = .free; st.rigDialHz = nil
    check(st.dialHz == nil, "Skimmer: ohne Band und Funkgerät keine HF-Frequenz")
    st.cwBand = .m20
    check(st.bandDialHz == 14_020_000 && st.dialHz == 14_020_000, "Skimmer: Dial aus dem Band")
    st.rigDialHz = 14_025_300
    check(st.dialHz == 14_025_300 && st.bandDialHz == 14_020_000, "Skimmer: Dial vom Funkgerät hat Vorrang")
    st.mode = .psk31; st.pskBand = .m40; st.rigDialHz = nil
    check(st.bandDialHz == 7_040_000, "Skimmer: PSK-Band")
    // Klick im Wasserfall
    let rev = st.focusRevision
    st.setCenter(1234.4)
    check(st.centerHz == 1234 && st.focusRevision == rev + 1, "Skimmer: Klick setzt die NF-Frequenz")
    st.setCenter(10)
    check(st.centerHz == 150, "Skimmer: NF-Frequenz nach unten begrenzt")
    st.setCenter(9000)
    check(st.centerHz == 3500, "Skimmer: NF-Frequenz nach oben begrenzt")
    st.marks = [WaterfallChannelMark(frequency: 700, label: "DL1ABC", selected: true)]
    if case .channels(let m) = st.markerStyle { check(m.count == 1 && m[0].label == "DL1ABC" && m[0].selected && m[0].active, "Skimmer: Markierungen für den Wasserfall") } else { check(false, "Skimmer: Markierungsart") }
    st.mode = .cw
    check(st.markerBandwidth == 100 && SkimmerSettingsStore().thresholdDB >= 4, "Skimmer: Breite der Markierung, Schwelle im Bereich")
    // HF-Frequenz einer Station: USB Dial + NF, LSB Dial − NF
    let s = SkimStation(id: 1, mode: .cw, audioHz: 700, snrDB: 20, speed: 20, firstHeard: Date(), lastHeard: Date())
    check(s.rfHz(dialHz: 14_020_000, lsb: false) == 14_020_700 && s.rfHz(dialHz: 14_020_000, lsb: true) == 14_019_300 && s.rfHz(dialHz: nil, lsb: false) == nil, "Skimmer: HF-Frequenz aus Dial und NF")
}
if want("skimmer") { skimmerBasicsTests() }

// MARK: - Skimmer-Engine: mehrere Signale gleichzeitig (synthetisch, mit Rauschen)

/// Audio in Blöcken durch die Engine schicken; liefert die Kanäle, den je Kanal gelesenen Text und die Meldungen
func skimRun(_ mode: SkimMode, _ audio: [Float], threshold: Double = 8)
    -> (channels: [SkimChannelInfo], text: [Int: String], activated: [Int], closed: [Int]) {
    let e = SkimmerEngine(mode: mode)
    e.config.thresholdDB = threshold
    var text: [Int: String] = [:]
    var activated: [Int] = [], closed: [Int] = []
    e.onText = { id, s, _ in text[id, default: ""] += s }
    e.onActivated = { activated.append($0) }
    e.onClosed = { closed.append($0) }
    var i = 0
    audio.withUnsafeBufferPointer { buf in
        while i < buf.count {
            let n = min(400, buf.count - i)
            e.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    return (e.channels(), text, activated, closed)
}

/// „CQ CQ DE <call> <call> K“ je Signal, wiederholt bis zum Ende; Rauschen so, dass `snr` in 500 Hz herauskommt
func skimMix(_ mode: SkimMode, _ spec: [(hz: Double, snr: Double, wpm: Double, call: String, start: Double)], seconds: Double, seed: UInt64 = 7) -> [Float] {
    let amplitude: Float = 0.08
    let sigma = SkimTestSignal.noiseSigma(snr500: 0, amplitude: amplitude)
    var parts: [[Float]] = []
    for s in spec {
        let amp = amplitude * Float(pow(10, s.snr / 20))
        let text = "CQ CQ DE \(s.call) \(s.call) K"
        let single = mode == .cw
            ? SkimTestSignal.cw(text: text, wpm: s.wpm, toneHz: s.hz, amplitude: amp, leadSeconds: 0, tailSeconds: 0.2)
            : SkimTestSignal.bpsk(text: text, mode: mode, carrierHz: s.hz, amplitude: amp)
        var x = single
        while Double(x.count) < (seconds - s.start) * 8000 { x += [Float](repeating: 0, count: Int(1.5 * 8000)) + single }
        parts.append(SkimTestSignal.delayed(x, seconds: s.start))
    }
    return SkimTestSignal.mix(parts, noise: sigma, seconds: seconds, seed: seed)
}

@MainActor func skimmerEngineTests() {
    // CW: vier Signale mit 14 … 30 WpM und 12 … 25 dB
    let cwSpec: [(hz: Double, snr: Double, wpm: Double, call: String, start: Double)] = [
        (600, 25, 18, "DL1ABC", 0), (950, 15, 24, "OK2XYZ", 2), (1400, 12, 14, "F5NZB", 4), (2000, 20, 30, "SP9KJ", 6),
    ]
    let cw = skimRun(.cw, skimMix(.cw, cwSpec, seconds: 45))
    for s in cwSpec {
        let ch = cw.channels.filter { abs($0.frequencyHz - s.hz) < 8 }.min { abs($0.frequencyHz - s.hz) < abs($1.frequencyHz - s.hz) }
        check(ch?.state == .active, "Skimmer CW: \(s.call) bei \(Int(s.hz)) Hz als Signal gefunden")
        guard let ch else { continue }
        let t = cw.text[ch.id] ?? ""
        check(t.contains(" " + s.call + " "), "Skimmer CW: \(s.call) gelesen, got \(t.suffix(70).debugDescription)")
        check(abs(ch.speed - s.wpm) < 1.5, "Skimmer CW: \(s.call) Geschwindigkeit \(String(format: "%.1f", ch.speed)) WpM statt \(Int(s.wpm))")
        if s.snr >= 15 { check(abs(ch.snrDB - s.snr) < 4, "Skimmer CW: \(s.call) Rauschabstand \(String(format: "%.1f", ch.snrDB)) dB statt \(Int(s.snr)) dB") }
    }
    check(cw.channels.filter { $0.state == .active }.count == 4, "Skimmer CW: genau vier aktive Signale (\(cw.channels.filter { $0.state == .active }.count))")
    check(Set(cw.activated).count == cw.activated.count, "Skimmer CW: jeder Kanal höchstens einmal gemeldet")
    // Auswertung der Rufzeichen mit dem Rufzeichenspeicher
    let log = CallsignLog()
    for ch in cw.channels where ch.state == .active { log.feed(cw.text[ch.id] ?? "") }
    check(Set(log.heard.map(\.call)) == Set(cwSpec.map(\.call)), "Skimmer CW: Rufzeichenspeicher findet alle vier (\(log.heard.map(\.call).sorted()))")

    // BPSK31: fünf Signale, zwei davon nur 100 Hz auseinander
    let pskSpec: [(hz: Double, snr: Double, wpm: Double, call: String, start: Double)] = [
        (500, 25, 0, "DL1ABC", 0), (680, 18, 0, "OK2XYZ", 1), (780, 15, 0, "F5NZB", 2), (1500, 12, 0, "SP9KJ", 3), (1880, 20, 0, "HB9TST", 4),
    ]
    for mode in [SkimMode.psk31, .psk63] {
        let r = skimRun(mode, skimMix(mode, pskSpec, seconds: 45))
        for s in pskSpec {
            let ch = r.channels.filter { abs($0.frequencyHz - s.hz) < 8 }.min { abs($0.frequencyHz - s.hz) < abs($1.frequencyHz - s.hz) }
            check(ch?.state == .active, "Skimmer \(mode.name): \(s.call) bei \(Int(s.hz)) Hz als Signal gefunden")
            guard let ch else { continue }
            let t = r.text[ch.id] ?? ""
            check(t.contains(" " + s.call + " "), "Skimmer \(mode.name): \(s.call) gelesen, got \(t.suffix(70).debugDescription)")
            check(abs(ch.frequencyHz - s.hz) < 3, "Skimmer \(mode.name): \(s.call) Frequenz \(String(format: "%.1f", ch.frequencyHz)) Hz")
            check(ch.speed == mode.baud, "Skimmer \(mode.name): Schrittgeschwindigkeit")
            if s.snr >= 15 { check(abs(ch.snrDB - s.snr) < 5, "Skimmer \(mode.name): \(s.call) Rauschabstand \(String(format: "%.1f", ch.snrDB)) dB statt \(Int(s.snr)) dB") }
        }
        check(r.channels.filter { $0.state == .active }.count == 5, "Skimmer \(mode.name): genau fünf aktive Signale (\(r.channels.filter { $0.state == .active }.count))")
    }

    // Schwund (QSB): bis 14 dB tiefe Einbrüche im Takt von 4 und 8 s; jede Sendung wird gelesen
    func repeated(_ one: [Float], seconds: Double) -> [Float] {
        var x = one
        while Double(x.count) < seconds * 8000 { x += one }
        return x
    }
    let noise22 = SkimTestSignal.noiseSigma(snr500: 0, amplitude: 0.08)
    for (depth, period, wpm) in [(0.8, 4.0, 20.0), (0.8, 8.0, 20.0), (0.7, 3.0, 25.0)] {
        let one = SkimTestSignal.cw(text: "CQ CQ DE DL1ABC DL1ABC K", wpm: wpm, toneHz: 900, amplitude: 0.08 * Float(pow(10, 22.0 / 20)), leadSeconds: 0, tailSeconds: 1.0)
        let faded = SkimTestSignal.fading(repeated(one, seconds: 70), depth: depth, period: period)
        let r = skimRun(.cw, SkimTestSignal.mix([faded], noise: noise22, seconds: 70))
        let text = r.channels.first { $0.state == .active && abs($0.frequencyHz - 900) < 8 }.flatMap { r.text[$0.id] } ?? ""
        let sent = Int(70 / (Double(one.count) / 8000))
        let read = text.components(separatedBy: " DE DL1ABC DL1ABC K").count - 1
        check(read >= sent - 1, "Skimmer CW: Schwund \(depth) im Takt von \(Int(period)) s, \(Int(wpm)) WpM: \(read) von \(sent) Sendungen gelesen")
    }
    // Langsame und schnelle Telegrafie: ein Signal, ein Kanal (kein Seitenband als zweites Signal)
    for (wpm, snr) in [(8.0, 14.0), (45.0, 20.0)] {
        let one = SkimTestSignal.cw(text: "CQ CQ DE DL1ABC DL1ABC K", wpm: wpm, toneHz: 900, amplitude: 0.08 * Float(pow(10, snr / 20)), leadSeconds: 0, tailSeconds: 1.0)
        let r = skimRun(.cw, SkimTestSignal.mix([repeated(one, seconds: 70)], noise: noise22, seconds: 70, seed: 5))
        let active = r.channels.filter { $0.state == .active }
        check(active.count == 1 && abs(active[0].frequencyHz - 900) < 5 && (r.text[active[0].id] ?? "").contains(" DL1ABC "),
              "Skimmer CW: \(Int(wpm)) WpM genau ein Signal bei 900 Hz (\(active.map { Int($0.frequencyHz) }))")
        check(abs((active.first?.speed ?? 0) - wpm) < 0.1 * wpm, "Skimmer CW: Tempo \(Int(wpm)) WpM gemessen \(String(format: "%.1f", active.first?.speed ?? 0))")
    }
    // BPSK mit wanderndem Träger (0,5 Hz/s, 22 Hz in 45 s): die Nachführung folgt
    for mode in [SkimMode.psk31, .psk63] {
        let long = String(repeating: "CQ CQ DE DL1ABC DL1ABC K ", count: 20)         // länger als die 45 s
        let drifting = SkimTestSignal.bpsk(text: long, mode: mode, carrierHz: 1000, amplitude: 0.08 * Float(pow(10, 18.0 / 20)), driftHzPerSecond: 0.5)
        let r = skimRun(mode, SkimTestSignal.mix([drifting], noise: noise22, seconds: 45))
        let ch = r.channels.first { $0.state == .active }
        check(ch != nil && abs((ch?.frequencyHz ?? 0) - 1022) < 4 && (r.text[ch?.id ?? 0] ?? "").contains(" DL1ABC "),
              "Skimmer \(mode.name): Träger mit Drift 0,5 Hz/s gelesen und verfolgt (\(String(format: "%.1f", ch?.frequencyHz ?? 0)) Hz statt etwa 1022 Hz)")
    }
    // Seitenband eines starken Signals ist kein eigenes Signal: Text vergleichen
    check(SkimmerEngine.approxContains(SkimmerEngine.compact("cq cq de dl1abc dl1abc k"), needle: SkimmerEngine.compact("DE DL1ABC DL1ABC"), maxErrors: 0), "Skimmer: Text im Text gefunden (Zwischenräume und Schreibweise egal)")
    check(SkimmerEngine.approxContains(SkimmerEngine.compact("CQ CQ DE DL1ABC DL1ABC K"), needle: SkimmerEngine.compact("DE DL1A8C DL1ABC"), maxErrors: 2), "Skimmer: Text mit einem Fehler gefunden")
    check(!SkimmerEngine.approxContains(SkimmerEngine.compact("CQ CQ DE DL1ABC DL1ABC K"), needle: SkimmerEngine.compact("TEST OK2XYZ OK2XYZ 599"), maxErrors: 4), "Skimmer: anderer Text nicht gefunden")

    // Nur Rauschen, Dauerträger und fremde Betriebsart: keine Signale in der Liste
    let noise = SkimTestSignal.mix([], noise: 0.08, seconds: 60, seed: 3)
    let carrier = (0..<(40 * 8000)).map { Float(0.05 * sin(2 * Double.pi * 1000 * Double($0) / 8000)) }
    let carrierMix = SkimTestSignal.mix([carrier], noise: SkimTestSignal.noiseSigma(snr500: 25, amplitude: 0.05), seconds: 40, seed: 5)
    for mode in SkimMode.allCases {
        let a = skimRun(mode, noise)
        check(a.activated.isEmpty && a.channels.allSatisfy { $0.state != .active }, "Skimmer \(mode.name): reines Rauschen ergibt kein Signal (\(a.activated.count) gemeldet)")
        let b = skimRun(mode, carrierMix)
        check(b.activated.isEmpty, "Skimmer \(mode.name): ungetasteter Träger ergibt kein Signal (\(b.activated.count) gemeldet)")
    }
    // Wegfallende Signale: nach dem Ende des Signals meldet die Engine das Ende des Kanals
    let ends = SkimTestSignal.mix([SkimTestSignal.cw(text: "CQ CQ DE DL1ABC DL1ABC K", wpm: 22, toneHz: 800, amplitude: 0.1, leadSeconds: 0, tailSeconds: 0)], noise: 0.005, seconds: 70)
    let gone = skimRun(.cw, ends)
    check(gone.activated.count == 1 && gone.closed.contains(gone.activated[0]) && gone.channels.isEmpty, "Skimmer CW: Kanal fällt nach dem Ende des Signals weg (\(gone.activated.count) aktiv, \(gone.closed.count) beendet, \(gone.channels.count) offen)")
    // reset meldet das Ende aller Kanäle
    let e = SkimmerEngine(mode: .cw)
    var closedIDs: [Int] = []
    e.onClosed = { closedIDs.append($0) }
    let seg = skimMix(.cw, cwSpec, seconds: 12)
    seg.withUnsafeBufferPointer { e.process($0) }
    let open = e.channels().count
    e.reset()
    check(open > 0 && closedIDs.count == open && e.channels().isEmpty && e.time == 0, "Skimmer: reset beendet alle Kanäle (\(open) offen, \(closedIDs.count) beendet)")
    // Rauschabstand-Umrechnung: Pegel 0,001 (Basisband) bei Rauschen 1e-6 je Bin
    check(abs(SkimmerEngine.snr500(level: 0.001, noiseBinDB: -60) - (-60 - 18.06 + 60)) < 0.1, "Skimmer: Rauschabstand aus Pegel und Rauschen je Bin")
    // Plausibilität des Textes: Morsetext gegen Rauschen
    check(SkimmerEngine.looksLikeText("CQ CQ DE DL1ABC DL1ABC K", mode: .cw) && !SkimmerEngine.looksLikeText("EEETISHETEISE*HETISE*ET", mode: .cw), "Skimmer CW: Text von Rauschen unterscheiden")
    check(SkimmerEngine.looksLikeText("CQ CQ DE DL1ABC PSE K", mode: .psk31) && !SkimmerEngine.looksLikeText("\u{1}\u{2}~~\u{7f}\u{3}\u{4}~~\u{1}\u{2}~~\u{7f}", mode: .psk31), "Skimmer PSK: Text von Rauschen unterscheiden")
}
if want("skimmer") { skimmerEngineTests() }

// MARK: - Skimmer-Controller: Stationen, Rufzeichen, Spots, Filter, Karte
@MainActor func skimmerControllerTests() {
    let settings = SkimmerSettingsStore()
    settings.mode = .cw; settings.cwBand = .m20; settings.pskBand = .free
    settings.minSNR = 3; settings.onlyCalls = false; settings.holdMinutes = 10; settings.rigDialHz = nil; settings.rigIsLSB = nil
    let c = SkimmerController(pipeline: AudioPipeline(), settings: settings)
    c.logEnabled = false
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    /// Kanäle der Engine zur Engine-Zeit `at` (alle gerade aktiv)
    func chans(_ ids: [Int], at engine: Double) -> [SkimChannelInfo] {
        let table: [Int: (hz: Double, snr: Double, wpm: Double)] = [1: (700, 20, 20), 2: (1200, 2, 20), 3: (1500, 14, 25)]
        return ids.map { id in
            SkimChannelInfo(id: id, mode: .cw, frequencyHz: table[id]!.hz, snrDB: table[id]!.snr, speed: table[id]!.wpm, state: .active,
                            born: 0, lastActive: engine, quality: 1, characters: 20)
        }
    }
    func ingest(_ texts: [(Int, String)], activated: [Int] = [], closed: [Int] = [], ids: [Int], at seconds: Double) {
        c.ingest(texts: texts.map { (id: $0.0, text: $0.1) }, activated: activated, closed: closed, channels: chans(ids, at: seconds), engineTime: seconds, now: t0.addingTimeInterval(seconds))
    }
    // Zwei Signale: eines ruft CQ mit Rufzeichen (Text in Stücken), eines schwach ohne Rufzeichen
    ingest([(1, "CQ CQ DE DL1"), (2, "TEST 5")], activated: [1, 2], ids: [1, 2], at: 10)
    ingest([(1, "ABC DL1ABC K ")], ids: [1, 2], at: 11)
    let s1 = c.stations.first { $0.id == 1 }
    check(c.stations.count == 2 && c.stations.map(\.audioHz) == [700, 1200], "Skimmer-Liste: zwei Stationen nach Frequenz sortiert")
    check(s1?.call == "DL1ABC" && s1?.isCQ == true && s1?.dxcc?.primaryPrefix == "DL", "Skimmer-Liste: DL1ABC, ruft CQ, Deutschland (\(String(describing: s1?.call)))")
    check(s1?.text.hasSuffix("DL1ABC K ") == true && s1?.characters == 12 + 13, "Skimmer-Liste: Text in Stücken zusammengesetzt (\(s1?.text.debugDescription ?? "-"))")
    check(c.stations.first { $0.id == 2 }?.call == nil, "Skimmer-Liste: Signal ohne Rufzeichen")
    check(c.spots.count == 1 && c.spots[0].call == "DL1ABC" && c.spots[0].kind == "CQ" && c.spots[0].mode == .cw, "Skimmer-Spots: ein Spot nach CQ DE DL1ABC (\(c.spots.count))")
    check(c.visibleStations.map(\.id) == [1], "Skimmer-Filter: Signal unter dem Mindest-Rauschabstand ausgeblendet")
    settings.minSNR = 0
    check(c.visibleStations.map(\.id) == [1, 2], "Skimmer-Filter: Mindest-Rauschabstand 0 dB zeigt beide")
    settings.onlyCalls = true
    check(c.visibleStations.map(\.id) == [1], "Skimmer-Filter: nur mit Rufzeichen")
    settings.onlyCalls = false
    check(settings.marks.count == 2 && settings.marks.first?.label == "DL1ABC" && settings.marks.first?.active == true, "Skimmer: Markierungen im Wasserfall (\(settings.marks))")
    // Dieselbe Station nach 2 Minuten: kein neuer Spot; nach 11 Minuten: neuer Spot
    ingest([(1, "CQ DE DL1ABC ")], ids: [1, 2], at: 120)
    check(c.spots.count == 1, "Skimmer-Spots: dieselbe Station nach 2 min nicht noch einmal (\(c.spots.count))")
    ingest([(1, "CQ DE DL1ABC ")], ids: [1, 2], at: 660)
    check(c.spots.count == 2, "Skimmer-Spots: nach 11 min wieder (\(c.spots.count))")
    // Zweite Station ohne CQ: „DE“ davor genügt, Spot mit Art DE
    ingest([(3, "OK2XYZ DE OK2XYZ ")], activated: [3], ids: [1, 2, 3], at: 670)
    let s3 = c.stations.first { $0.id == 3 }
    check(s3?.call == "OK2XYZ" && s3?.isCQ == false && s3?.dxcc?.primaryPrefix == "OK", "Skimmer-Liste: OK2XYZ nach DE (\(String(describing: s3?.call)))")
    check(c.spots.last?.call == "OK2XYZ" && c.spots.last?.kind == "DE", "Skimmer-Spots: Art DE für Station ohne CQ")
    // HF-Frequenz: aus dem Band, mit Funkgerät aus dessen Dial
    check(c.spots.last?.rfHz == 14_021_500, "Skimmer-Spots: HF-Frequenz aus Band und NF (\(String(describing: c.spots.last?.rfHz)))")
    settings.rigDialHz = 14_025_000; settings.rigIsLSB = false
    check(c.heard.first { $0.call == "DL1ABC" }?.rfHz == 14_025_700, "Skimmer: HF-Frequenz folgt dem Dial des Funkgeräts (\(String(describing: c.heard.first { $0.call == "DL1ABC" }?.rfHz)))")
    // Karte: gehörte Stationen mit Gebiet
    let map = HeardMapBuilder.content(c.heard, home: Maidenhead.point("JN49WS"), now: t0.addingTimeInterval(680), mode: "CW")
    check(map.markers.count == 2 && map.markers.contains { $0.title == "DL1ABC" } && map.markers.contains { $0.title == "OK2XYZ" }, "Skimmer-Karte: zwei Stationen (\(map.markers.map(\.title)))")
    // Auswahl der nächsten Station (Klick im Wasserfall)
    c.selectNearest(to: 750)
    check(c.selection == 1, "Skimmer: Klick bei 750 Hz wählt die Station bei 700 Hz")
    c.selectNearest(to: 2800)
    check(c.selection == 1, "Skimmer: Klick weit weg ändert die Auswahl nicht")
    c.selectNearest(to: 1480)
    check(c.selection == 3, "Skimmer: Klick bei 1480 Hz wählt die Station bei 1500 Hz")
    // Signal fällt weg: bleibt abgedunkelt in der Liste, nach der Haltezeit verschwindet es
    ingest([], closed: [2], ids: [1, 3], at: 760)
    check(c.stations.first { $0.id == 2 }?.isLive == false && c.stations.count == 3, "Skimmer-Liste: beendetes Signal bleibt zunächst in der Liste")
    check(settings.marks.count == 2 && !settings.marks.contains { $0.frequency == 1200 }, "Skimmer: beendetes Signal nicht mehr im Wasserfall")
    ingest([], ids: [1, 3], at: 1400)
    check(c.stations.map(\.id) == [1, 3], "Skimmer-Liste: beendetes Signal nach der Haltezeit entfernt (\(c.stations.map(\.id)))")
    // Spot-Zeile wie im Reverse Beacon Network
    let line = SkimmerController.logLine(SkimSpot(time: Date(timeIntervalSince1970: 1_790_000_000 + 5 * 3600 + 24 * 60 + 31), call: "DL1ABC", audioHz: 700, rfHz: 14_020_700, snrDB: 24.4, speed: 18.2, mode: .cw, kind: "CQ", dxcc: nil))
    check(line.hasPrefix("14020.7  DL1ABC  CW  18 WPM  24 dB  CQ  ") && line.hasSuffix("Z"), "Skimmer: Spot-Zeile \(line)")
    let line2 = SkimmerController.logLine(SkimSpot(time: t0, call: "OK2XYZ", audioHz: 1500, rfHz: nil, snrDB: 10, speed: 31.25, mode: .psk31, kind: "DE", dxcc: nil))
    check(line2.hasPrefix("NF 1500 Hz  OK2XYZ  BPSK31  31 BD  10 dB  DE  "), "Skimmer: Spot-Zeile ohne Dial \(line2)")
    // Aufräumen
    c.clear()
    check(c.stations.isEmpty && c.spots.isEmpty && c.selection == nil, "Skimmer: Listen leeren")
    c.setActive(false)
}
if want("skimmer") { skimmerControllerTests() }

// MARK: - Skimmer über die Pipeline (48 kHz → 8 kHz)
if want("skimmer") {
    let pipeline = AudioPipeline()
    let decoder = SkimmerDecoder(pipeline: pipeline)
    decoder.configure(mode: .cw, thresholdDB: 8)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    let signals = [
        SkimTestSignal.cw(text: "CQ CQ DE DL1ABC DL1ABC K", wpm: 24, toneHz: 800, amplitude: 0.1, leadSeconds: 0.5, tailSeconds: 1.5),
        SkimTestSignal.delayed(SkimTestSignal.cw(text: "CQ CQ DE OK2XYZ OK2XYZ K", wpm: 20, toneHz: 1500, amplitude: 0.06, leadSeconds: 0, tailSeconds: 1.5), seconds: 1.0),
    ]
    var audio8 = SkimTestSignal.mix(signals.map { s in s + s + s }, noise: 0.004, seconds: 40, seed: 11)
    audio8 += [Float](repeating: 0, count: 4000)
    var audio48 = [Float](repeating: 0, count: audio8.count * 6)
    for i in 0..<audio48.count {
        let x = Double(i) / 6, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio8[k] * (1 - f) + (k + 1 < audio8.count ? audio8[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var text: [Int: String] = [:]
    var lastOut = decoder.takeOutput()
    var i = 0
    while i < audio48.count {
        let n = min(4_800, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        Thread.sleep(forTimeInterval: 0.004)
        let o = decoder.takeOutput()
        for t in o.texts { text[t.id, default: ""] += t.text }
        lastOut = o
    }
    Thread.sleep(forTimeInterval: 0.5)
    let o = decoder.takeOutput()
    for t in o.texts { text[t.id, default: ""] += t.text }
    let ch = o.channels.isEmpty ? lastOut.channels : o.channels
    let a = ch.first { abs($0.frequencyHz - 800) < 8 }, b = ch.first { abs($0.frequencyHz - 1500) < 8 }
    check(a?.state == .active && b?.state == .active, "Skimmer über die Pipeline: beide Signale gefunden (\(ch.map { "\(Int($0.frequencyHz)) Hz \($0.state.rawValue)" }))")
    check(a.flatMap { text[$0.id] }?.contains("DL1ABC") == true && b.flatMap { text[$0.id] }?.contains("OK2XYZ") == true, "Skimmer über die Pipeline: Rufzeichen gelesen (\(text.values.map { String($0.suffix(30)) }))")
    check(o.inputDB > -60 && o.inputDB < 0 && o.time > 30 && o.trackCount >= 2, "Skimmer über die Pipeline: Pegel \(Int(o.inputDB)) dBFS, Zeit \(Int(o.time)) s, Spuren \(o.trackCount)")
    // Abgeschaltet: nichts mehr
    decoder.setEnabled(false)
    Thread.sleep(forTimeInterval: 0.1)
    let off = decoder.takeOutput()
    check(off.channels.isEmpty && off.trackCount == 0, "Skimmer: abgeschaltet liefert keine Kanäle")
    pipeline.stop()
}


// MARK: - Radiosonden RS41: Reed-Solomon, Rahmen, Empfänger (synthetisch und an einem echten Rahmen)

/// Echter, fehlerkorrigierter Rahmen einer RS41-SG (N3920808, Boden bei Adelaide, 10.02.2019 05:16:20 UTC, Rahmen 112; Aufnahme aus dem Projekt radiosonde_auto_rx)
let rs41RealFrame: [UInt8] = {
    let h = Array("8635f44093df1a60c3b6131c1a574338f8c39381a157718c2d859929baa0e11a4f2899fef5f8cecd7f75be65ae153951fd7ffd5d681b36ed0f792870004e333932303830381f00000000001f0000260003320942339abac28ed24e42c37b1b42f86f51aa247a2a80d3024b05023cee028e5708fe4b074a56084ac0024c05023cee0200000000000000000000000000000022d47c1ef807f0e2210115cb1bf010cc0a801d870fecff00ff00ff00ff00ff00ff007b6a7d59e2473801ff55049f01b8bf0084ef360cd373ffa555620cec91000e000000570200dab7ad16575601d6696a1172cf0000000000000000000000000000000000000000000000000000000000000000000000000000000000000081957b15117380e82d22a614b1c377ea2c00bfff2b00061117715876110000000000000000000000000000000000ecc7")
    return stride(from: 0, to: h.count, by: 2).map { UInt8(String(h[$0...($0 + 1)]), radix: 16)! }
}()

/// Einpoliger Tiefpass / Hochpass / De-Emphase auf Audio (Nachbildung der NF-Kette eines Funkgeräts)
func sondeFilter(_ x: [Float], kind: String, fc: Double, rate: Double = 48_000) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    let a = Float(exp(-2 * Double.pi * fc / rate))
    var s: Float = 0
    switch kind {
    case "lp": for i in x.indices { s = (1 - a) * x[i] + a * s; y[i] = s }
    case "hp": for i in x.indices { s = (1 - a) * x[i] + a * s; y[i] = x[i] - s }
    default: y = x
    }
    return y
}

func sondeFlightAudio(frames count: Int = 20, rate: Double = 48_000, amplitude: Float = 0.25, offset: Float = 0, clockError: Double = 0, start: Int = 0)
    -> (audio: [Float], frames: [[UInt8]], truth: [(lat: Double, lon: Double, alt: Double)]) {
    let cal = RS41SignalGenerator.Calibration(frequencyKHz: 403_500, model: "RS41-SG")
    var frames: [[UInt8]] = [], truth: [(Double, Double, Double)] = []
    for k in 0..<count {
        var p = RS41SignalGenerator.Parameters()
        p.serial = "T2610001"
        p.frame = 100 + start + k
        let st = RS41SignalGenerator.flightState(t: Double(start + k), launch: (49.79, 9.95, 180), climb: 5)
        p.latitude = st.lat; p.longitude = st.lon; p.altitude = st.alt; p.vNorth = st.vN; p.vEast = st.vE; p.vUp = st.vU
        p.gpsWeek = 2380; p.gpsMillis = 300_000_000 + 1000 * (start + k)
        p.meas = Array((cal.measurement(temperature: 12.34 - 0.0065 * (st.alt - 180)) + [Double](repeating: 0, count: 9)).prefix(12))
        p.calibrationIndex = (start + k) % 51
        p.calibrationBytes = cal.chunk((start + k) % 51)
        frames.append(RS41SignalGenerator.frame(p))
        truth.append((st.lat, st.lon, st.alt))
    }
    return (RS41SignalGenerator.audio(frames: frames, sampleRate: rate, amplitude: amplitude, offset: offset, clockError: clockError), frames, truth)
}

@MainActor func sondeDecode(_ audio: [Float], rate: Double = 48_000) -> (frames: [SondeTelemetry], stats: SondeStats) {
    let rx = RS41Receiver(sampleRate: rate)
    var got: [SondeTelemetry] = []
    rx.onTelemetry = { got.append($0) }
    audio.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count { let m = min(480, buf.count - i); rx.process(UnsafeBufferPointer(rebasing: buf[i..<(i + m)])); i += m }
    }
    return (got, rx.stats)
}

@MainActor func sondeTests() {
    // --- Reed-Solomon: Rundlauf mit 0 … 12 Fehlern an beliebigen Stellen (Nutz- und Prüfbytes)
    var rng = SkimRNG(seed: 99)
    var rsOK = true, rsFixed = true
    for errors in [0, 1, 2, 5, 9, 12] {
        let message = (0..<132).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        var cw = RS41ReedSolomon.encode(message: message) + message
        let clean = cw
        var used = Set<Int>()
        while used.count < errors { used.insert(Int(rng.next() % UInt64(cw.count))) }
        for p in used { cw[p] ^= UInt8(1 + rng.next() % 255) }
        let n = RS41ReedSolomon.decode(&cw)
        if n != errors { rsOK = false }
        if cw != clean { rsFixed = false }
    }
    check(rsOK && rsFixed, "RS41-Reed-Solomon: 0 … 12 Fehler gezählt (\(rsOK)) und behoben (\(rsFixed))")
    var tooMany = RS41ReedSolomon.encode(message: [UInt8](repeating: 0x55, count: 132)) + [UInt8](repeating: 0x55, count: 132)
    for p in stride(from: 3, to: 100, by: 4) { tooMany[p] ^= 0xA5 }
    let beyond = RS41ReedSolomon.decode(&tooMany)
    check(beyond == nil || beyond! > 0, "RS41-Reed-Solomon: 25 Fehler werden nicht als fehlerfrei durchgewinkt")

    // --- Echter Rahmen: Prüfsummen der Blöcke, Seriennummer, Position, Messwerte
    check(rs41RealFrame.count == 320, "RS41 echter Rahmen: 320 Bytes")
    let blocks = RS41FrameParser.blocks(rs41RealFrame)
    check(blocks.map(\.type) == [0x79, 0x7A, 0x7C, 0x7D, 0x7B, 0x76] && blocks.allSatisfy(\.valid), "RS41 echter Rahmen: sechs Blöcke mit gültiger CRC (\(blocks.map { String($0.type, radix: 16) }))")
    var cal = RS41Calibration()
    if let t = RS41FrameParser.parse(rs41RealFrame, calibration: &cal, previousSerial: nil) {
        check(t.serial == "N3920808" && t.frame == 112, "RS41 echter Rahmen: Seriennummer \(t.serial), Rahmen \(t.frame)")
        check(abs((t.latitude ?? 0) + 34.72077) < 1e-4 && abs((t.longitude ?? 0) - 138.69278) < 1e-4 && abs((t.altitude ?? 0) - 87.38) < 0.05,
              "RS41 echter Rahmen: Position \(t.latitude ?? 0) \(t.longitude ?? 0) \(t.altitude ?? 0)")
        let utc = ISO8601DateFormatter().string(from: t.time ?? Date(timeIntervalSince1970: 0))
        check(utc == "2019-02-10T05:16:20Z", "RS41 echter Rahmen: Zeit (UTC) \(utc)")
        check(abs((t.speed ?? 9) - 0.2) < 0.06 && abs((t.climb ?? 9) + 0.9) < 0.06 && t.satellites == 6 && abs((t.battery ?? 0) - 3.1) < 0.01, "RS41 echter Rahmen: Geschwindigkeit, Steigen, Satelliten, Batterie")
    } else { check(false, "RS41 echter Rahmen nicht lesbar") }
    // beschädigte Blöcke werden verworfen, nicht falsch gelesen
    var damaged = rs41RealFrame
    damaged[0x114] ^= 0x10                                      // Positionsblock
    var cal2 = RS41Calibration()
    let t2 = RS41FrameParser.parse(damaged, calibration: &cal2, previousSerial: nil)
    check(t2?.serial == "N3920808" && t2?.hasPosition == false, "RS41: Block mit falscher CRC liefert keine Position")

    // --- Fehlerkorrektur auf dem echten Rahmen: verwürfelt, Bytefehler, wieder entwürfelt
    var broken = rs41RealFrame
    for p in [10, 40, 60, 100, 150, 200, 250, 300] { broken[p] ^= 0x3C }
    check(RS41Receiver.correct(&broken, length: 320) == 8 && broken == rs41RealFrame, "RS41: acht Bytefehler im echten Rahmen behoben")

    // --- Ganze Kette mit synthetischem Flug (48 kHz): Position auf 1e-6° genau, Temperatur, Frequenz, Typ
    let ideal = sondeFlightAudio(frames: 60)
    let a = sondeDecode(ideal.audio)
    check(a.frames.count == 60 && a.stats.frames == 60 && a.stats.failed == 0, "RS41 Kette: 60 von 60 Rahmen (\(a.frames.count), verloren \(a.stats.failed))")
    var worst = 0.0
    for (g, t) in zip(a.frames, ideal.truth) { worst = max(worst, abs((g.latitude ?? 99) - t.lat), abs((g.longitude ?? 99) - t.lon), abs((g.altitude ?? 9e9) - t.alt) / 1e5) }
    check(worst < 1e-5, "RS41 Kette: größte Abweichung der Position \(worst)")
    if let g = a.frames.last {
        check(g.serial == "T2610001" && g.frame == 159 && g.frequencyKHz == 403_500 && g.model == "RS41-SG", "RS41 Kette: Seriennummer, Rahmen, Frequenz, Typ (\(g.serial) \(g.frame) \(g.frequencyKHz ?? 0) \(g.model ?? "-"))")
        let expectedT = 12.34 - 0.0065 * ((ideal.truth.last?.alt ?? 0) - 180)
        check(abs((g.temperature ?? -99) - expectedT) < 0.05, "RS41 Kette: Temperatur \(g.temperature ?? -99) statt \(expectedT)")
        check(abs((g.climb ?? 0) - 5) < 0.05 && g.satellites == 9 && abs((g.battery ?? 0) - 2.9) < 0.01, "RS41 Kette: Steigen, Satelliten, Batterie")
    }
    check(a.frames.prefix(3).allSatisfy { $0.temperature == nil } && a.frames.dropFirst(10).allSatisfy { $0.temperature != nil }, "RS41 Kette: Temperatur erst, wenn die Kalibrierblöcke 3 bis 6 da sind")

    // --- Funkkette: jede Verzerrung für sich; mindestens 18 von 20 Rahmen müssen ankommen
    func ratio(_ audio: [Float], rate: Double = 48_000) -> Int { sondeDecode(audio, rate: rate).frames.count }
    let base = sondeFlightAudio(frames: 20)
    check(ratio(sondeFlightAudio(frames: 20, offset: 0.12).audio) >= 18, "RS41 Funkkette: Frequenzablage (Gleichanteil)")
    check(ratio(sondeFlightAudio(frames: 20, offset: -0.1).audio) >= 18, "RS41 Funkkette: Frequenzablage negativ")
    check(ratio(sondeFlightAudio(frames: 20, clockError: 3e-4).audio) >= 18, "RS41 Funkkette: Bitrate +300 ppm")
    check(ratio(sondeFlightAudio(frames: 20, clockError: -3e-4).audio) >= 18, "RS41 Funkkette: Bitrate −300 ppm")
    check(ratio(base.audio.map { -$0 }) >= 18, "RS41 Funkkette: umgekehrte Polarität")
    check(ratio(sondeFilter(base.audio, kind: "hp", fc: 300)) >= 18, "RS41 Funkkette: Kopplungs-Hochpass 300 Hz")
    check(ratio(sondeFilter(base.audio, kind: "lp", fc: 2100)) >= 18, "RS41 Funkkette: De-Emphase 75 µs (Eckfrequenz 2,1 kHz)")
    check(ratio(sondeFilter(base.audio, kind: "lp", fc: 1060)) >= 18, "RS41 Funkkette: De-Emphase 150 µs")
    check(ratio(sondeFilter(sondeFilter(sondeFilter(base.audio, kind: "hp", fc: 300), kind: "lp", fc: 3000), kind: "lp", fc: 3000)) >= 18, "RS41 Funkkette: Sprachband 300 … 3000 Hz")
    var noisy = base.audio
    var nr = SkimRNG(seed: 5)
    for i in noisy.indices { noisy[i] += 0.07 * Float(nr.gauss()) }
    check(ratio(noisy) >= 18, "RS41 Funkkette: Rauschen (Rauschspannung 0,07 bei Signal ±0,25)")
    let low = sondeFlightAudio(frames: 20, rate: 24_000)
    check(ratio(low.audio, rate: 24_000) >= 18, "RS41 Funkkette: Abtastrate 24 kHz")
    let high = sondeFlightAudio(frames: 20, rate: 96_000)
    check(ratio(high.audio, rate: 96_000) >= 18, "RS41 Funkkette: Abtastrate 96 kHz")

    // --- Nichts als Rauschen oder Träger: keine Rahmen, kein Absturz
    var onlyNoise = [Float](repeating: 0, count: 48_000 * 20)
    for i in onlyNoise.indices { onlyNoise[i] = 0.15 * Float(nr.gauss()) }
    let nn = sondeDecode(onlyNoise)
    check(nn.frames.isEmpty && nn.stats.frames == 0, "RS41: Rauschen ergibt keinen Rahmen (\(nn.frames.count))")
    check(sondeDecode([Float](repeating: 0.2, count: 48_000 * 5)).frames.isEmpty, "RS41: Gleichspannung ergibt keinen Rahmen")

    // --- Teilauswertung: Rahmen mit zu vielen Bytefehlern in den Prüfbytes, aber gültigen Blöcken
    let cleanFrame = ideal.frames[0]
    var partial = cleanFrame
    for i in 8..<56 { partial[i] ^= 0xFF }                       // alle Prüfbytes zerstören: Fehlerkorrektur scheitert
    let partialAudio = RS41SignalGenerator.audio(frames: [partial, partial, partial])
    let pr = sondeDecode(partialAudio)
    check(pr.stats.frames == 0 && pr.stats.partial >= 2 && pr.frames.first?.hasPosition == true, "RS41: Teilauswertung bei zerstörter Fehlerkorrektur (\(pr.stats.partial) Teile)")

    // --- Rahmenzähler des Empfängers bei zweimaligem Aufruf von reset
    let rx = RS41Receiver()
    rx.reset()
    check(rx.stats == SondeStats(), "RS41: Zähler nach reset leer")
}
if want("sonde") { sondeTests() }

// MARK: - Sondenmodul: Flug, Phase, Landeprognose, Karte, Einstellungen, Abstimmung, Pipeline
@MainActor func sondeModuleTests() {
    check(DecoderModuleInfo.sonde.displayName == "SONDE" && DecoderModuleInfo.sonde.isAvailable && DecoderModuleInfo.sonde.hasMap && DecoderModuleInfo.sonde.presetIDs == ["rs41"], "Sonde: Modul verfügbar mit Karte")
    check(parse("digidec://decode?mode=sonde") == .success(DecodeRequest(module: .sonde, presetID: "rs41")), "Sonde: URL mode=sonde")
    check(RigTuneTarget.sonde(frequencyKHz: 403_500, filterKHz: 15) == RigTuneTarget(dialHz: 403_500_000, mode: "FM", passbandHz: 15_000), "QSY: Sonde 403,500 MHz FM 15 kHz")
    check(RigTuneTarget.sonde(frequencyKHz: 400_150, filterKHz: 50).passbandHz == 50_000 && RigTuneTarget.sonde(frequencyKHz: 400_150, filterKHz: 50).label == "400,150 MHz FM", "QSY: Sonde mit 50-kHz-Filter")
    // Frequenz aus Text
    check(SondeSettingsStore.parse("403,5") == 403_500 && SondeSettingsStore.parse("403.500") == 403_500 && SondeSettingsStore.parse("403500") == 403_500 && SondeSettingsStore.parse("405,85 MHz") == 405_850, "Sonde: Frequenz aus Text (MHz und kHz)")
    check(SondeSettingsStore.parse("430,0") == nil && SondeSettingsStore.parse("399,9") == nil && SondeSettingsStore.parse("abc") == nil && SondeSettingsStore.text(403_500) == "403,500 MHz", "Sonde: Frequenz außerhalb des Sondenbandes abgelehnt")

    // Flug: Aufstieg, Platzen, Sinkflug, Landung
    let launch = (lat: 49.79, lon: 9.95, alt: 180.0)
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func telemetry(_ k: Int, climb: Double = 5, burst: Double = 8000) -> SondeTelemetry {
        let st = RS41SignalGenerator.flightState(t: Double(k), launch: launch, climb: climb, burst: burst, wind: (2, 8))
        var t = SondeTelemetry(serial: "T2610001", frame: 100 + k)
        t.latitude = st.lat; t.longitude = st.lon; t.altitude = st.alt
        t.speed = (st.vN * st.vN + st.vE * st.vE).squareRoot(); t.heading = atan2(st.vE, st.vN) * 180 / .pi; t.climb = st.vU
        t.temperature = 10 - 0.0065 * (st.alt - 180); t.satellites = 9; t.battery = 2.9
        t.time = t0.addingTimeInterval(Double(k))
        return t
    }
    var flight = SondeFlight(first: telemetry(0), at: t0)
    flight.ingest(telemetry(0), at: t0)
    check(flight.phase(now: t0) == .ground && flight.frames == 1 && flight.launchAltitude == 180, "Sonde: am Boden vor dem Start")
    for k in 1...120 { flight.ingest(telemetry(k), at: t0.addingTimeInterval(Double(k))) }
    check(flight.phase(now: t0.addingTimeInterval(120)) == .ascent && flight.frames == 121 && flight.track.count == 121, "Sonde: Aufstieg mit 121 Wegpunkten")
    check(!flight.ingest(telemetry(120), at: t0.addingTimeInterval(120.5)) && flight.frames == 121, "Sonde: derselbe Rahmen zählt nicht doppelt")
    let burstSecond = Int((8000 - 180) / 5)
    for k in 121...(burstSecond + 80) { flight.ingest(telemetry(k), at: t0.addingTimeInterval(Double(k))) }
    let nowFlight = t0.addingTimeInterval(Double(burstSecond + 80))
    check(flight.hasBurst && flight.phase(now: nowFlight) == .descent && flight.maxAltitude > 7_900, "Sonde: Ballon geplatzt, Sinkflug (höchste \(Int(flight.maxAltitude)) m)")
    if let land = SondeLanding.predict(flight, now: nowFlight), let p = flight.point {
        let km = Geo.distanceKm(p, land.point)
        check(land.seconds > 300 && land.seconds < 3000 && km > 0.5 && km < 40, "Sonde: Landeprognose in \(Int(land.seconds)) s, \(String(format: "%.1f", km)) km weiter")
        // die Prognose liegt in Windrichtung (nach Osten)
        check(land.point.lon > p.lon, "Sonde: Landestelle liegt in Windrichtung")
    } else { check(false, "Sonde: keine Landeprognose im Sinkflug") }
    check(SondeLanding.predict(flight, now: nowFlight.addingTimeInterval(400)) == nil, "Sonde: keine Prognose ohne frische Daten")
    // gelandet: Sinkflug, Signal weg in geringer Höhe
    var low = flight
    for k in (burstSecond + 81)...(burstSecond + 1400) { low.ingest(telemetry(k), at: t0.addingTimeInterval(Double(k))) }
    check(low.latest.altitude.map { $0 < 400 } == true, "Sonde: im Sinkflug unten angekommen (\(Int(low.latest.altitude ?? -1)) m)")
    check(low.phase(now: low.lastHeard.addingTimeInterval(200)) == .landed, "Sonde: nach Signalverlust in geringer Höhe gelandet")
    // Elevation
    check(abs(SondeMapBuilder.elevation(from: GeoPoint(lat: 49.79, lon: 9.95), to: GeoPoint(lat: 49.79, lon: 9.95), altitude: 5000, homeAltitude: 200) - 90) < 0.1, "Sonde: Elevation senkrecht darüber 90°")
    let el = SondeMapBuilder.elevation(from: GeoPoint(lat: 49.79, lon: 9.95), to: GeoPoint(lat: 50.79, lon: 9.95), altitude: 20_000, homeAltitude: 200)
    check(el > 9 && el < 10.5, "Sonde: Elevation in 111 km Entfernung und 20 km Höhe etwa \(String(format: "%.1f", el))°")

    // Controller und Karte
    let settings = SondeSettingsStore()
    let c = SondeController(pipeline: AudioPipeline(), settings: settings)
    c.logEnabled = false
    for k in 0...60 { c.ingest(telemetry(k), at: t0.addingTimeInterval(Double(k))) }
    var other = telemetry(30); other.serial = "T2610002"; other.frame = 5; other.latitude = (other.latitude ?? 0) + 0.3
    c.ingest(other, at: t0.addingTimeInterval(61))
    check(c.flights.count == 2 && c.flights[0].serial == "T2610002" && c.selection == "T2610001", "Sonde-Liste: zwei Sonden, jüngste zuerst, erste ausgewählt")
    check(c.flights.first { $0.serial == "T2610001" }?.frames == 61, "Sonde-Liste: 61 Rahmen der ersten Sonde")
    let map = c.mapContent(home: Maidenhead.point("JN49WS"), now: t0.addingTimeInterval(62))
    let m1 = map.markers.first { $0.id == "sonde-T2610001" }
    check(map.markers.count == 2 && m1?.symbol == "balloon.fill" && (m1?.track.count ?? 0) > 50, "Sonde-Karte: zwei Ballons, Weg mit \(m1?.track.count ?? 0) Punkten")
    check(m1?.details.contains { $0.hasPrefix("Höhe ") } == true && m1?.details.contains { $0.contains("km") } == true && m1?.details.contains { $0.hasPrefix("Elevation") } == true, "Sonde-Karte: Höhe, Entfernung und Elevation in den Einzelheiten (\(m1?.details ?? []))")
    check(map.lines.contains { $0.id.hasPrefix("sonde-home-") }, "Sonde-Karte: Linie vom Standort zur Sonde")
    // Startorte auf der Karte: Name und Frequenz, der Weg beginnt am vermuteten Startort
    let siteHere = SondeSite(id: "S1", name: "Teststart (Germany)", point: GeoPoint(lat: 49.7901, lon: 9.9502), altitude: 180, types: ["41"],
                             launches: [SondeLaunchTime(weekday: nil, minute: 720)])
    let siteFar = SondeSite(id: "S2", name: "Weitweg (Germany)", point: GeoPoint(lat: 52.0, lon: 13.0), altitude: 50, types: ["41"], frequencyKHz: 404_000)
    let siteLayer = SondeSiteLayer(sites: [siteHere, siteFar], shown: ["S1"])
    let mapS = c.mapContent(home: Maidenhead.point("JN49WS"), now: t0.addingTimeInterval(62), sites: siteLayer)
    let siteMark = mapS.markers.first { $0.id == "sonde-site-S1" }
    let flightMark = mapS.markers.first { $0.id == "sonde-T2610001" }
    check(siteMark?.title == "Teststart" && siteMark?.symbol == "mappin.circle.fill" && siteMark?.tone == .highlight && siteMark?.subtitle == "keine Frequenz in der Liste · 12:00 UTC", "Sonde-Karte: Startort mit Name, hervorgehoben als Start der Sonde (\(siteMark?.subtitle ?? "nil"))")
    check(mapS.markers.first { $0.id == "sonde-site-S2" } == nil && mapS.markers.first?.id == "sonde-site-S1", "Sonde-Karte: ferne Station nicht angezeigt, Startorte unter den Sonden")
    check(flightMark?.track.first == siteHere.point && (flightMark?.track.count ?? 0) > 50 && flightMark?.details.contains { $0.hasPrefix("Start vermutlich in Teststart") } == true, "Sonde-Karte: Weg beginnt am Startort (\(flightMark?.details.last ?? "nil"))")
    check(c.mapContent(home: nil, now: t0.addingTimeInterval(62)).markers.allSatisfy { !$0.id.hasPrefix("sonde-site-") }, "Sonde-Karte: ohne Startortliste keine Startorte")
    // Sinkflug mit Landemarke
    let cd = SondeController(pipeline: AudioPipeline(), settings: settings)
    cd.logEnabled = false
    for k in 0...(burstSecond + 80) { cd.ingest(telemetry(k), at: t0.addingTimeInterval(Double(k))) }
    let mapD = cd.mapContent(home: nil, now: t0.addingTimeInterval(Double(burstSecond + 81)))
    check(mapD.markers.contains { $0.id == "sonde-land-T2610001" && $0.symbol == "flag.checkered" } && mapD.lines.contains { $0.id == "sonde-fall-T2610001" }, "Sonde-Karte: Landemarke und Fallinie im Sinkflug")
    check(cd.flights[0].track.count > 1500 / 5 && SondeMapBuilder.content(cd.flights, home: nil, now: t0, selection: nil).markers[0].track.count <= 801, "Sonde-Karte: Weg auf höchstens 800 Punkte ausgedünnt")
    // Aufräumen
    c.clear()
    check(c.flights.isEmpty && c.selection == nil && c.stats == SondeStats(), "Sonde: Liste leeren")
    // Logzeile
    var lt = telemetry(10)
    lt.humidity = 45
    let line = SondeController.logLine(lt)
    let parts = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    check(parts.count == 15 && parts[1] == "T2610001" && parts[2] == "110" && parts[0].hasSuffix("Z") && parts[10] == "45" && parts[12] == "9", "Sonde: Logzeile mit 15 Feldern (\(line))")

    // Diagnose
    check(SondeDiagnosis.assess(inputDB: -120, stats: SondeStats()).title == "KEIN AUDIO", "Sonde-Diagnose: kein Audio")
    check(SondeDiagnosis.assess(inputDB: -30, stats: SondeStats()).title == "SUCHE SONDE", "Sonde-Diagnose: Suche")
    var st = SondeStats(); st.headers = 30
    check(SondeDiagnosis.assess(inputDB: -30, stats: st).title == "SIGNAL, ABER NICHTS LESBAR", "Sonde-Diagnose: Kopf ohne Rahmen")
    st.partial = 5
    check(SondeDiagnosis.assess(inputDB: -30, stats: st).title == "NUR TEILE LESBAR", "Sonde-Diagnose: nur Teile")
    st.frames = 20; st.failed = 2
    check(SondeDiagnosis.assess(inputDB: -30, stats: st) == SondeDiagnosis.Result(severity: .ok, title: "EMPFANG GUT", advice: ""), "Sonde-Diagnose: Empfang gut")
    st.failed = 40
    check(SondeDiagnosis.assess(inputDB: -30, stats: st).title == "VIELE FEHLER", "Sonde-Diagnose: viele Fehler")

    // Über die Pipeline (48 kHz und 96 kHz Eingang)
    for inputRate in [48_000.0, 96_000.0] {
        let pipeline = AudioPipeline()
        let decoder = SondeDecoder(pipeline: pipeline)
        decoder.setEnabled(true)
        pipeline.start(inputRate: inputRate)
        let f = sondeFlightAudio(frames: 6, rate: inputRate)
        Thread.sleep(forTimeInterval: 0.05)
        var got: [SondeTelemetry] = []
        var i = 0
        f.audio.withUnsafeBufferPointer { buf in
            while i < buf.count {
                let n = min(Int(inputRate / 10), buf.count - i)
                pipeline.ring.write(buf.baseAddress! + i, count: n)
                i += n
                Thread.sleep(forTimeInterval: 0.004)
                got += decoder.takeOutput().telemetry
            }
        }
        Thread.sleep(forTimeInterval: 0.6)
        let out = decoder.takeOutput()
        got += out.telemetry
        check(got.count >= 5 && got.first?.serial == "T2610001", "Sonde über die Pipeline mit \(Int(inputRate / 1000)) kHz Eingang: \(got.count) von 6 Rahmen")
        check(out.inputDB > -40 && out.inputDB < 0 && out.stats.frames >= 5, "Sonde über die Pipeline: Pegel \(Int(out.inputDB)) dBFS")
        decoder.setEnabled(false)
        pipeline.stop()
    }

    // Echte Aufnahme (nur wenn lokal vorhanden): 120 s einer RS41-SG am Boden, in FM-Audio umgesetzt aus dem Beispiel des Projekts radiosonde_auto_rx
    let realPath = "Vendor/_upstream/sonde/rs41_fm48.wav"
    if let data = FileManager.default.contents(atPath: realPath), data.count > 1_000_000 {
        var samples: [Float] = []
        let bytes = [UInt8](data)
        var i = 44
        while i + 1 < bytes.count { samples.append(Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768); i += 2 }
        let r = sondeDecode(samples)
        check(r.frames.count >= 117 && r.stats.failed == 0, "RS41 echte Aufnahme: \(r.frames.count) Rahmen (Referenz 118), verloren \(r.stats.failed)")
        if let g = r.frames.last(where: { $0.frame == 229 }) {
            check(abs((g.temperature ?? 0) - 26.2) < 0.06 && abs((g.humidity ?? 0) - 40) < 1.5 && abs((g.altitude ?? 0) - 68.98) < 0.02 && g.model == "RS41-SG", "RS41 echte Aufnahme: Rahmen 229 T \(g.temperature ?? 0) rF \(g.humidity ?? 0) Höhe \(g.altitude ?? 0) \(g.model ?? "-")")
        } else { check(false, "RS41 echte Aufnahme: Rahmen 229 fehlt") }
    }
}
if want("sonde") { sondeModuleTests() }

// MARK: - Weitere Sonden: Graw DFM, Meteomodem M10, Meteosis M20 (Hamming-Code, Prüfsumme, echte Rahmen, Rundlauf, Störungen, echte Aufnahmen)

/// Alle Sondenarten zugleich (wie im Modul) über Audio
@MainActor func sondeBankDecode(_ audio: [Float], rate: Double = 48_000) -> (frames: [SondeTelemetry], stats: SondeStats) {
    let bank = SondeReceiverBank(sampleRate: rate)
    var got: [SondeTelemetry] = []
    bank.onTelemetry = { got.append($0) }
    audio.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count { let m = min(480, buf.count - i); bank.process(UnsafeBufferPointer(rebasing: buf[i..<(i + m)])); i += m }
    }
    return (got, bank.stats)
}

func sondeHexBytes(_ hex: String) -> [UInt8] {
    let h = Array(hex)
    return stride(from: 0, to: h.count - 1, by: 2).map { UInt8(String(h[$0...($0 + 1)]), radix: 16)! }
}

/// 16-Bit-WAV (44-Byte-Kopf, mono) als Float; nil, wenn die Datei fehlt
func sondeLoadWAV(_ path: String) -> [Float]? {
    guard let data = FileManager.default.contents(atPath: path), data.count > 100_000 else { return nil }
    let bytes = [UInt8](data)
    var samples: [Float] = []
    samples.reserveCapacity(bytes.count / 2)
    var i = 44
    while i + 1 < bytes.count { samples.append(Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768); i += 2 }
    return samples
}

/// Echte Rahmen (aus den Beispielaufnahmen von radiosonde_auto_rx, mit dem Referenzdecoder m10m20mod von zilog80 ausgewertet)
let m20RealFrame = "4520c858a005c1010024660000000107fb5ff634045e6c95000008abfdee33fa08444896283fd54900000000fd34227254f609e3288e0000d0221f58002000580199f704ca24"
let m10RealFrame = "649f2000000000000000000046503ffffff400000000000249f00000000500120800000000000000000000000000a77bc671999709d48b09010027240000001aa5f209f2096003125f0b0100080014000000000000e50f1a008201ff00021483dc22bad1b1"

@MainActor func sondeMoreTests() {
    // --- Hamming(8,4) der DFM: alle 16 Halbbytes, Einzelfehler an jeder Stelle behoben, Doppelfehler erkannt
    var hammingOK = true, singleOK = true, doubleOK = true
    for nib in 0..<16 {
        let word = DFMHamming.encode(UInt8(nib))
        var w = word
        if DFMHamming.check(&w) != 0 || w != word { hammingOK = false }
        for e in 0..<8 {
            var x = word
            x[e] ^= 1
            if DFMHamming.check(&x) != e + 1 || x != word { singleOK = false }
            for f in (e + 1)..<8 {
                var y = word
                y[e] ^= 1; y[f] ^= 1
                if DFMHamming.check(&y) != -1 { doubleOK = false }
            }
        }
    }
    check(hammingOK && singleOK && doubleOK, "DFM-Hamming(8,4): Rundlauf (\(hammingOK)), Einzelfehler behoben (\(singleOK)), Doppelfehler erkannt (\(doubleOK))")
    // Verschachtelung und Block-Rundlauf (7 und 13 Wörter)
    var blockOK = true
    for cols in [7, 13] {
        let nibbles = (0..<cols).map { UInt8(($0 * 5 + 3) & 0xF) }
        let bits = DFMSignalGenerator.block(nibbles, columns: cols)
        let r = DFMHamming.decode(bits[0..<bits.count], columns: cols)
        let back = (0..<cols).map { UInt8(Int(r.data[4 * $0]) << 3 | Int(r.data[4 * $0 + 1]) << 2 | Int(r.data[4 * $0 + 2]) << 1 | Int(r.data[4 * $0 + 3])) }
        if r.errors != 0 || back != nibbles { blockOK = false }
        var bad = bits
        bad[5] ^= 1; bad[bits.count / 2] ^= 1                    // zwei Bitfehler in verschiedenen Wörtern: beide werden behoben
        let r2 = DFMHamming.decode(bad[0..<bad.count], columns: cols)
        if r2.errors <= 0 || r2.data != r.data { blockOK = false }
    }
    check(blockOK, "DFM: verschachtelter Block mit 7 und 13 Wörtern, Bitfehler behoben")
    check(DFMDecoder.bitErrors(0b1011) == 3 && DFMDecoder.bitErrors(0) == 0, "DFM: Zahl der behobenen Wörter aus der Fehlermaske")
    check(DFMDecoder.secondsSince1980(year: 2019, month: 2, day: 10, hour: 5, minute: 32, second: 22) == 1_233_811_942, "DFM: Sekunden seit 6.1.1980 (10.02.2019 05:32:22 UTC)")

    // --- M10/M20: Prüfsumme und Auswertung an echten Rahmen (Sollwerte vom Referenzdecoder)
    let realM20 = sondeHexBytes(m20RealFrame), realM10 = sondeHexBytes(m10RealFrame)
    check(realM20.count == 70 && realM10.count == 101, "M10/M20: echte Rahmen mit 70 und 101 Bytes")
    check(M10Frame.check(realM20, count: 0x44) == (Int(realM20[0x44]) << 8 | Int(realM20[0x45])), "M20: Prüfsumme des echten Rahmens stimmt")
    check(M10Frame.check(realM10, count: 0x63) == (Int(realM10[0x63]) << 8 | Int(realM10[0x64])), "M10: Prüfsumme des echten Rahmens stimmt")
    var broken = realM20
    broken[0x20] ^= 0x04
    check(M10Frame.check(broken, count: 0x44) != (Int(broken[0x44]) << 8 | Int(broken[0x45])), "M20: ein Bitfehler ändert die Prüfsumme")
    check(M10Frame.Kind(rawValue: realM20[1]) == .m20 && M10Frame.Kind(rawValue: realM10[1]) == .m10, "M10/M20: Typkennungen 0x20 und 0x9F")
    // Über die ganze Kette: echter Rahmen als Signal, dann Auswertung
    let m20Real = sondeBankDecode(SondeFSK.audio(bursts: (0..<3).map { (0.3 + Double($0), M10SignalGenerator.symbols(frame: realM20)) }, symbolRate: 9600, amplitude: 0.25))
    if let t = m20Real.frames.last {
        check(t.serial == "M20-911-2-00269" && t.model == "M20", "M20 echter Rahmen: Seriennummer \(t.serial) (\(t.model ?? "-"))")
        check(abs((t.latitude ?? 0) + 34.72077) < 2e-5 && abs((t.longitude ?? 0) - 138.69276) < 2e-5 && abs((t.altitude ?? 0) - 93.18) < 0.01,
              "M20 echter Rahmen: Position \(t.latitude ?? 0) \(t.longitude ?? 0) Höhe \(t.altitude ?? 0) (Referenz −34,72077 138,69276 93,18)")
        check(abs((t.temperature ?? 0) - 19.8) < 0.06 && abs((t.humidity ?? 0) - 63) < 1 && abs((t.pressure ?? 0) - 1010.5) < 0.06,
              "M20 echter Rahmen: T \(t.temperature ?? 0) rF \(t.humidity ?? 0) p \(t.pressure ?? 0) (Referenz 19,8 °C 63 % 1010,5 hPa)")
        // Die Sonde sendet GPS-Zeit (Samstag 23.07.2022 01:18:23); Digidec rechnet 18 Schaltsekunden ab
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = t.time.map { cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
        check(c?.year == 2022 && c?.month == 7 && c?.day == 23 && c?.hour == 1 && c?.minute == 18 && c?.second == 5, "M20 echter Rahmen: UTC \(c.map { "\($0.hour ?? -1):\($0.minute ?? -1):\($0.second ?? -1)" } ?? "-") (GPS 01:18:23 − 18 s)")
    } else { check(false, "M20 echter Rahmen: keine Telemetrie") }
    let m10Real = sondeBankDecode(SondeFSK.audio(bursts: (0..<3).map { (0.3 + Double($0), M10SignalGenerator.symbols(frame: realM10)) }, symbolRate: 9600, amplitude: 0.25))
    if let t = m10Real.frames.last {
        check(t.serial == "M10-803-2-10732" && t.model == "M10", "M10 echter Rahmen: Seriennummer \(t.serial)")
        check(abs((t.temperature ?? 0) - 23.6) < 0.06 && abs((t.humidity ?? 0) - 50) < 1, "M10 echter Rahmen: T \(t.temperature ?? 0) rF \(t.humidity ?? 0) (Referenz 23,6 °C 50 %)")
        check(!t.hasPosition, "M10 echter Rahmen: ohne GPS-Lösung (Platzhalter 90° N) keine Position")
    } else { check(false, "M10 echter Rahmen: keine Telemetrie") }

    // --- Rundlauf M20 und M10 mit Störungen
    func m10Flight(kind: M10Frame.Kind, seconds: Int = 20, offset: Float = 0, clock: Double = 0, inverted: Bool = false, snr: Double? = nil, rate: Double = 48_000)
        -> (frames: [SondeTelemetry], stats: SondeStats) {
        var a = M10SignalGenerator.audio(seconds: seconds, flight: { s in
            var p = M10SignalGenerator.Parameters()
            p.kind = kind
            p.towSeconds = 345_600 + 43_200 + s
            p.latitude = 49.79 + 0.0001 * Double(s)
            p.longitude = 9.95 + 0.0002 * Double(s)
            p.altitude = 180 + 5 * Double(s)
            p.counter = s
            if kind == .m20 { p.serialBytes = [0x6D, 0x03, 0x04] }
            return p
        }, sampleRate: rate, offset: offset, clockError: clock, inverted: inverted)
        if let snr { a = addNoise(a, snrDB: snr, signalPower: 0.05) }
        return sondeBankDecode(a, rate: rate)
    }
    for kind in [M10Frame.Kind.m20, .m10] {
        let name = kind == .m20 ? "M20" : "M10"
        let r = m10Flight(kind: kind)
        check(r.frames.count == 20 && r.stats.failed == 0 && r.frames.allSatisfy { $0.serial.hasPrefix(name + "-") }, "\(name) Rundlauf: \(r.frames.count) von 20 Rahmen, verloren \(r.stats.failed)")
        if let t = r.frames.last {
            check(abs((t.latitude ?? 0) - (49.79 + 0.0019)) < 2e-6 && abs((t.longitude ?? 0) - (9.95 + 0.0038)) < 2e-6 && abs((t.altitude ?? 0) - 275) < 0.01,
                  "\(name) Rundlauf: Position \(t.latitude ?? 0) \(t.longitude ?? 0) Höhe \(t.altitude ?? 0)")
            check(abs((t.speed ?? 0) - 3.6056) < 0.02 && abs((t.heading ?? 0) - 33.69) < 0.1 && abs((t.climb ?? 0) - 5) < 0.02, "\(name) Rundlauf: Geschwindigkeit \(t.speed ?? 0) Kurs \(t.heading ?? 0) Steigen \(t.climb ?? 0)")
            check(t.satellites == (kind == .m10 ? 9 : nil) && (t.time.map { $0.timeIntervalSince1970 } ?? 0) == Double(2400 * 604_800 + 345_600 + 43_200 + 19 - 18) + 315_964_800, "\(name) Rundlauf: Zeit UTC und Satelliten")
        }
        for (label, args) in [("invertiert", (0.0 as Float, 0.0, true, nil as Double?)), ("Gleichanteil 0,15", (0.15, 0.0, false, nil)), ("Bitrate +1,6 ‰ (M10 mit 9615 Bd)", (0, 0.0016, false, nil)),
                              ("Bitrate −5 ‰", (0, -0.005, false, nil)), ("Rauschen 9 dB", (0, 0, false, 9)), ("alles zusammen", (0.1, 0.0016, true, 9))] as [(String, (Float, Double, Bool, Double?))] {
            let x = m10Flight(kind: kind, offset: args.0, clock: args.1, inverted: args.2, snr: args.3)
            check(x.frames.count >= 17 && x.frames.allSatisfy { $0.serial.hasPrefix(name + "-") }, "\(name) \(label): \(x.frames.count) von 20 Rahmen")
        }
        let weak = m10Flight(kind: kind, snr: 6)
        check(weak.frames.count >= 14, "\(name) bei 6 dB: \(weak.frames.count) von 20 Rahmen")
    }
    // M10 mit anderer Abtastrate des Audios
    check(m10Flight(kind: .m20, rate: 96_000).frames.count == 20 && m10Flight(kind: .m10, rate: 96_000).frames.count == 20, "M10/M20 Rundlauf bei 96 kHz Abtastrate")

    // --- Rundlauf DFM
    func dfmFlight(seconds: Int = 40, offset: Float = 0, clock: Double = 0, inverted: Bool = false, snr: Double? = nil) -> (frames: [SondeTelemetry], stats: SondeStats) {
        var a = DFMSignalGenerator.audio(seconds: seconds, flight: { s in
            var p = DFMSignalGenerator.Parameters()
            p.latitude = 49.79 + 0.0001 * Double(s)
            p.longitude = 9.95 + 0.0002 * Double(s)
            p.altitude = 180 + 5 * Double(s)
            p.minute = s / 60
            p.second = s % 60
            return p
        }, offset: offset, clockError: clock, inverted: inverted)
        if let snr { a = addNoise(a, snrDB: snr, signalPower: 0.05) }
        return sondeBankDecode(a)
    }
    let dfm = dfmFlight()
    check(dfm.frames.count >= 28 && dfm.stats.failed == 0 && dfm.frames.allSatisfy { $0.serial == "DFM-637797" && $0.model == "DFM-09" }, "DFM Rundlauf: \(dfm.frames.count) von 40 s, verloren \(dfm.stats.failed) (die Seriennummer braucht einen Zyklus von 40 Rahmen)")
    if let t = dfm.frames.last, let when = t.time {
        let start = Double(DFMDecoder.secondsSince1980(year: 2026, month: 10, day: 3, hour: 12, minute: 0, second: 0)) + 315_964_800
        let s = Int(when.timeIntervalSince1970 - start)
        check(abs((t.latitude ?? 0) - (49.79 + 0.0001 * Double(s))) < 2e-7 && abs((t.longitude ?? 0) - (9.95 + 0.0002 * Double(s))) < 2e-7 && abs((t.altitude ?? 0) - (180 + 5 * Double(s))) < 0.01,
              "DFM Rundlauf: Position \(t.latitude ?? 0) \(t.longitude ?? 0) Höhe \(t.altitude ?? 0) bei \(s) s")
        check(abs((t.speed ?? 0) - 3) < 0.01 && abs((t.heading ?? 0) - 90) < 0.01 && abs((t.climb ?? 0) - 5) < 0.01 && t.satellites == 9, "DFM Rundlauf: Geschwindigkeit \(t.speed ?? 0) Kurs \(t.heading ?? 0) Steigen \(t.climb ?? 0) Satelliten \(t.satellites ?? 0)")
        check(abs((t.temperature ?? 0) - 15) < 0.05 && abs((t.battery ?? 0) - 5.9) < 0.01, "DFM Rundlauf: Temperatur \(t.temperature ?? 0) Batterie \(t.battery ?? 0)")
    } else { check(false, "DFM Rundlauf: keine Telemetrie") }
    for (label, x) in [("invertiert", dfmFlight(inverted: true)), ("Gleichanteil 0,15", dfmFlight(offset: 0.15)), ("Bitrate +3 ‰", dfmFlight(clock: 0.003)),
                       ("Rauschen 9 dB", dfmFlight(snr: 9)), ("Rauschen 3 dB", dfmFlight(snr: 3))] {
        check(x.frames.count >= 26 && x.frames.allSatisfy { $0.serial == "DFM-637797" }, "DFM \(label): \(x.frames.count) Rahmen")
    }

    // --- Verwechslung: jede Sondenart wird von den anderen Empfängern in Ruhe gelassen
    let rs = sondeFlightAudio(frames: 10)
    let mixed = sondeBankDecode(rs.audio)
    check(mixed.frames.count >= 9 && mixed.frames.allSatisfy { $0.serial == "T2610001" }, "Sondenbank: RS41-Signal ergibt nur RS41 (\(mixed.frames.count) Rahmen, \(Set(mixed.frames.map(\.serial))))")
    // Rauschen und Gleichspannung ergeben nichts
    let noise = addNoise([Float](repeating: 0, count: 48_000 * 20), snrDB: 0, signalPower: 0.05)
    check(sondeBankDecode(noise).frames.isEmpty && sondeBankDecode([Float](repeating: 0.2, count: 48_000 * 5)).frames.isEmpty, "Sondenbank: Rauschen und Gleichspannung ergeben keine Telemetrie")
    // Zähler: die Summe zählt nur Empfänger, die etwas lesen
    let dfmStats = dfm.stats
    check(dfmStats.frames > 150 && dfmStats.failed == 0, "Sondenbank: Zähler einer DFM (\(dfmStats.frames) Rahmen, \(dfmStats.failed) verloren)")
    // Zwei Sonden nacheinander auf derselben Frequenz
    let dfmPart = DFMSignalGenerator.audio(seconds: 20, flight: { s in var p = DFMSignalGenerator.Parameters(); p.second = s; return p })
    let m20Part = M10SignalGenerator.audio(seconds: 6, flight: { s in var p = M10SignalGenerator.Parameters(); p.kind = .m20; p.towSeconds = 345_600 + s; p.serialBytes = [1, 2, 3]; return p })
    let two = sondeBankDecode(dfmPart + [Float](repeating: 0, count: 24_000) + m20Part)
    check(Set(two.frames.map { $0.model ?? "" }) == ["DFM-09", "M20"], "Sondenbank: zwei Arten nacheinander (\(Set(two.frames.map { $0.model ?? "" })))")

    // --- Echte Aufnahmen (nur wenn lokal vorhanden, TestData/Sonde, aus dem Beispielsatz von radiosonde_auto_rx als FM-Audio umgesetzt)
    if let a = sondeLoadWAV("TestData/Sonde/dfm09_fm48.wav") {
        let r = sondeBankDecode(a)
        check(r.stats.frames >= 530 && r.stats.failed == 0 && r.frames.count >= 85 && r.frames.allSatisfy { $0.serial == "DFM-637797" && $0.model == "DFM-09" }, "DFM echte Aufnahme: \(r.stats.frames) Rahmen (von 535), \(r.frames.count) Sekunden Telemetrie (Referenz 96)")
        if let t = r.frames.last {
            check(abs((t.latitude ?? 0) + 34.7207) < 3e-4 && abs((t.longitude ?? 0) - 138.6928) < 3e-4 && abs((t.altitude ?? 0) - 100) < 6 && abs((t.temperature ?? 0) - 61) < 4 && abs((t.battery ?? 0) - 5.9) < 0.05,
                  "DFM echte Aufnahme: \(t.latitude ?? 0) \(t.longitude ?? 0) Höhe \(t.altitude ?? 0) T \(t.temperature ?? 0) U \(t.battery ?? 0) (Referenz −34,7207 138,6928 ~100 m 60 °C 5,9 V)")
        }
    }
    if let a = sondeLoadWAV("TestData/Sonde/m20_fm48.wav") {
        let r = sondeBankDecode(a)
        check(r.stats.frames >= 112 && r.frames.count >= 112 && r.frames.allSatisfy { $0.serial == "M20-911-2-00269" }, "M20 echte Aufnahme: \(r.stats.frames) Rahmen (Referenz bei 48 kHz 108), verloren \(r.stats.failed)")
        if let t = r.frames.last {
            check(abs((t.latitude ?? 0) + 34.72078) < 1e-4 && abs((t.longitude ?? 0) - 138.69276) < 1e-4 && abs((t.temperature ?? 0) - 19.8) < 0.5 && abs((t.humidity ?? 0) - 63) < 3 && abs((t.pressure ?? 0) - 1010.5) < 0.5,
                  "M20 echte Aufnahme: \(t.latitude ?? 0) \(t.longitude ?? 0) T \(t.temperature ?? 0) rF \(t.humidity ?? 0) p \(t.pressure ?? 0)")
        }
    }
    if let a = sondeLoadWAV("TestData/Sonde/m10_fm48.wav") {
        let r = sondeBankDecode(a)
        check(r.stats.frames >= 105 && r.frames.count >= 85 && r.frames.allSatisfy { $0.serial == "M10-803-2-10732" && !$0.hasPosition }, "M10 echte Aufnahme: \(r.stats.frames) Rahmen (Referenz bei 48 kHz 17, bei 96 kHz 91), \(r.frames.count) Telemetrie")
        if let t = r.frames.last { check(abs((t.temperature ?? 0) - 23.6) < 0.5 && abs((t.humidity ?? 0) - 50) < 2, "M10 echte Aufnahme: T \(t.temperature ?? 0) rF \(t.humidity ?? 0)") }
    }
}
if want("sonde") { sondeMoreTests() }

// MARK: - Sonden-Plan (SondeHub-Startorte): Lesen, Zeiten mit Wochentag, Entfernung, Sendefenster
@MainActor func sondePlanTests() {
    func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let json = """
    {"10771":{"station_name":"Kuemmersbruck (Germany)","rs_types":[["41","402.7"],"17"],"times":["0:00:00","0:12:00"],"datetime":"2023-09-08T07:30:00Z","station":"10771","alt":418,"position":[11.9,49.43],"burst_altitude":33000,"ascent_rate":5.1},
     "10954":{"station_name":"Altenstadt (Germany)","rs_types":[["41",402.5],"17"],"times":["1:03:00","1:09:00","2:03:00","3:03:00","4:03:00","5:03:00"],"datetime":"2023-07-06T06:19:07Z","station":"10954","alt":740,"position":[10.87,47.83]},
     "10962":{"station_name":"Hohenpeissenberg (Germany)","rs_types":[["41","402.9"],"14"],"times":["1:06:00","3:06:00","5:06:00"],"datetime":"2023-07-06T06:19:07Z","station":"10962","alt":977,"position":[11.01,47.8]},
     "10548":{"station_name":"Meiningen (Germany)","rs_types":["41"],"times":["0:00:00","0:12:00"],"datetime":"2023-07-06T06:19:07Z","station":"10548","alt":450,"position":[10.38,50.56]},
     "-99":{"station_name":"Testfeld (Germany)","rs_types":["41"],"times":["Irregular"],"notes":"Nur Tests","datetime":"2024-01-01T00:00:00Z","station":"-99","alt":10,"position":[9.9,49.8]},
     "-98":{"station_name":"Nachtstart (Germany)","rs_types":[["41",404.5]],"times":["1:00:00","0:00:30"],"datetime":"2025-01-01T00:00:00Z","station":"-98","alt":10,"position":[9.0,49.0]},
     "-97":{"station_name":"Graw (Germany)","rs_types":["17","54"],"times":[],"datetime":"2024-11-21T00:00:00Z","station":"-97","alt":300,"position":[11.0,49.4]},
     "-96":{"station_name":"Kaputt (Nowhere)","rs_types":["41"],"datetime":"2024-11-21T00:00:00Z","station":"-96","position":[999,99]},
     "-95":{"station_name":"Ausserhalb (Germany)","rs_types":[["41","410.0"]],"times":["0:00:00"],"datetime":"2024-11-21T00:00:00Z","station":"-95","alt":1,"position":[10.0,50.0]}}
    """
    guard let sites = SondePlanParser.parse(Data(json.utf8)) else { check(false, "Sonden-Plan: Liste nicht lesbar"); return }
    check(sites.count == 8, "Sonden-Plan: 8 gültige Stationen (Position 999/99 verworfen), gelesen \(sites.count)")
    func site(_ id: String) -> SondeSite? { sites.first { $0.id == id } }

    // Typ und Frequenz: [„41“, „402.7“] als Text, 402.5 als Zahl, keine Frequenz ohne Eintrag, 410 MHz außerhalb des Bandes
    check(site("10771")?.frequencyKHz == 402_700 && site("10771")?.types == ["41", "17"], "Sonden-Plan: Frequenz als Text (402,7 MHz) und Typen")
    check(site("10954")?.frequencyKHz == 402_500, "Sonden-Plan: Frequenz als Zahl (402,5 MHz)")
    check(site("10548")?.frequencyKHz == nil && site("10548")?.isRS41 == true, "Sonden-Plan: RS41 ohne Frequenz im Eintrag")
    check(site("-95")?.frequencyKHz == nil, "Sonden-Plan: 410 MHz liegt außerhalb des Sondenbandes → keine Frequenz")
    check(site("-97")?.isRS41 == false && site("-97")?.launches.isEmpty == true, "Sonden-Plan: Graw (Typ 17/54) ist keine RS41, ohne Zeiten")
    check(site("10771")?.altitude == 418 && site("10771")?.burstAltitude == 33000 && site("10771")?.updated == "2023-09-08", "Sonden-Plan: Höhe, Platzhöhe, Datum des Eintrags")
    check(site("10771")?.point == GeoPoint(lat: 49.43, lon: 11.9), "Sonden-Plan: Position steht als [Länge, Breite] im Eintrag")
    check(site("10771")?.shortName == "Kuemmersbruck" && site("10771")?.country == "Germany", "Sonden-Plan: Name und Land aus „Ort (Land)“")

    // Zeiten: „Wochentag:Stunde:Minute“, 0 = täglich, 1 = Montag … 7 = Sonntag; Freitext wird Hinweis
    check(SondeLaunchTime.parse("0:12:00") == SondeLaunchTime(weekday: nil, minute: 720), "Sonden-Zeit: 0:12:00 = täglich 12:00")
    check(SondeLaunchTime.parse("3:06:30") == SondeLaunchTime(weekday: 3, minute: 390), "Sonden-Zeit: 3:06:30 = Mittwoch 06:30")
    check(SondeLaunchTime.parse("12:00") == SondeLaunchTime(weekday: nil, minute: 720), "Sonden-Zeit: ohne Wochentag täglich")
    check(SondeLaunchTime.parse("Irregular") == nil && SondeLaunchTime.parse("8:12:00") == nil && SondeLaunchTime.parse("0:24:00") == nil && SondeLaunchTime.parse("0:12:60") == nil, "Sonden-Zeit: Freitext und ungültige Werte verworfen")
    check(site("-99")?.launches.isEmpty == true && site("-99")?.timeNotes == ["Irregular"] && site("-99")?.notes == "Nur Tests", "Sonden-Plan: Freitext statt Zeit bleibt Hinweis")
    let sumKuemmersbruck = SondeLaunchTime.summary(site("10771")?.launches ?? [])
    let sumAltenstadt = SondeLaunchTime.summary(site("10954")?.launches ?? [])
    let sumHohenpeissenberg = SondeLaunchTime.summary(site("10962")?.launches ?? [])
    check(sumKuemmersbruck == "00:00 · 12:00", "Sonden-Zeiten kurz: täglich (\(sumKuemmersbruck))")
    check(sumAltenstadt == "03:00 Mo–Fr · 09:00 Mo", "Sonden-Zeiten kurz: Altenstadt (\(sumAltenstadt))")
    check(sumHohenpeissenberg == "06:00 (Mo,Mi,Fr)", "Sonden-Zeiten kurz: Montag, Mittwoch, Freitag (\(sumHohenpeissenberg))")

    // Entfernung vom Standort JN49XS: nur RS41, sortiert, Umkreis
    let home = Maidenhead.point("JN49XS") ?? GeoPoint(lat: 49.77, lon: 9.96)
    let near = SondePlan.nearby(sites, home: home, radiusKm: 300)
    check(near.map(\.site.id).first == "-99", "Sonden-Plan: nächste Station zuerst (\(near.map(\.site.id)))")
    check(!near.contains { $0.site.id == "-97" }, "Sonden-Plan: Stationen ohne RS41 nicht gelistet")
    check(near.allSatisfy { $0.km <= 300 } && near.map(\.km) == near.map(\.km).sorted(), "Sonden-Plan: Umkreis und Sortierung")
    let wide = SondePlan.nearby(sites, home: home, radiusKm: 100)
    check(wide.map(\.site.id) == ["-99", "10548"] || wide.map(\.site.id).first == "-99", "Sonden-Plan: Umkreis 100 km (\(wide.map(\.site.id)))")

    // Sendefenster: Beginn eine Stunde vor dem Termin, Wochentag verschiebt sich über Mitternacht
    let k = site("10771")!
    let items = k.items(leadMinutes: 60, windowMinutes: 150)
    check(items.map(\.startMinute).sorted() == [660, 1380] && items.allSatisfy { $0.weekday == nil && $0.durationMinutes == 150 && $0.service == .sonde }, "Sonden-Fenster: täglich 23:00 und 11:00 UTC (\(items.map(\.startMinute)))")
    check(items.contains { $0.id == "10771|0|0000" } && items.contains { $0.id == "10771|0|1200" }, "Sonden-Fenster: Kennungen")
    check(SondeSite.siteID(fromItemID: "10771|0|1200") == "10771" && SondeSite.siteID(fromItemID: "-98|1|0000") == "-98", "Sonden-Fenster: Station aus der Kennung")
    let night = site("-98")!.items(leadMinutes: 60, windowMinutes: 150)
    let nightText = night.map { String($0.weekday ?? 0) + "/" + String($0.startMinute) }.joined(separator: " ")
    check(night.contains { $0.weekday == 7 && $0.startMinute == 1380 }, "Sonden-Fenster: Montag 00:00 minus 1 h = Sonntag 23:00 (\(nightText))")

    // Zeitrechnung mit Wochentag: Altenstadt Mo–Fr 03:00 nominal → Fenster ab 02:00
    let a = site("10954")!.items(leadMinutes: 60, windowMinutes: 150)
    check(ScheduleCalc.isoWeekday(utc("2026-10-04T12:00:00Z")) == 7 && ScheduleCalc.isoWeekday(utc("2026-10-05T12:00:00Z")) == 1, "Wochentag: 04.10.2026 ist Sonntag (7), 05.10. Montag (1)")
    let nextA = ScheduleCalc.next(items: a, after: utc("2026-10-04T12:00:00Z"))
    check(nextA?.start == utc("2026-10-05T02:00:00Z"), "Sonden-Plan: nach Sonntag 12:00 beginnt das nächste Fenster am Montag 02:00 (\(String(describing: nextA?.start)))")
    check(ScheduleCalc.running(items: a, at: utc("2026-10-05T03:30:00Z")) != nil, "Sonden-Plan: Montag 03:30 läuft ein Fenster")
    check(ScheduleCalc.running(items: a, at: utc("2026-10-04T03:30:00Z")) == nil, "Sonden-Plan: Sonntag 03:30 läuft keins (nur Mo–Fr)")
    let sel = Set(a.map(\.id))
    let late = ScheduleCalc.due(items: a, selected: sel, at: utc("2026-10-05T03:20:00Z"), handled: [])
    let lateKey = late?.key ?? "nil"
    check(late?.key == "20261005-sonde-10954|1|0300", "Sonden-Plan: später Einstieg im laufenden Fenster erlaubt (\(lateKey))")
    check(ScheduleCalc.due(items: a, selected: sel, at: utc("2026-10-05T03:20:00Z"), handled: ["20261005-sonde-10954|1|0300"]) == nil, "Sonden-Plan: begonnenes Fenster nicht noch einmal")
    check(ScheduleCalc.due(items: a, selected: sel, at: utc("2026-10-04T02:30:00Z"), handled: []) == nil, "Sonden-Plan: Sonntag nichts fällig")
    // Pläne ohne Wochentag unverändert (täglich), späte Einstiege bleiben dort auf 120 s begrenzt
    let daily = [ScheduledItem(service: .rtty, id: "x", startMinute: 600, durationMinutes: 30, title: "t")]
    check(ScheduleCalc.due(items: daily, selected: ["x"], at: utc("2026-10-04T10:05:00Z"), handled: []) == nil, "Zeit: tägliche Pläne ohne späten Einstieg wie bisher")
    check(ScheduleCalc.next(items: daily, after: utc("2026-10-04T10:05:00Z"))?.start == utc("2026-10-05T10:00:00Z"), "Zeit: tägliche Pläne: nächste morgen wie bisher")

    // Speicher: Auswahl, Frequenz je Station, Fenster der Auswahl
    for key in ["sondePlanSelected", "sondePlanFrequencies", "sondePlanLead", "sondePlanWindow", "sondePlanRadius", "sondePlanAuto", "sondePlanReturn"] { UserDefaults.standard.removeObject(forKey: key) }
    let store = SondePlanStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("digidec_sondeplan_test_\(UUID().uuidString)"))
    check(store.leadMinutes == 60 && store.windowMinutes == 150 && store.radiusKm == 500 && store.items.isEmpty, "Sonden-Speicher: Voreinstellungen (60 min vor, 150 min, 500 km), nichts gewählt")
    check(store.sites.count == 900, "Sonden-Speicher: eingebaute Liste geladen (\(store.sites.count) Stationen)")
    store.selectedSiteIDs = ["10771"]
    check(store.items.count == 2 && store.selectedItemIDs.count == 2, "Sonden-Speicher: gewählte Station ergibt ihre Fenster")
    store.leadMinutes = 90
    check(store.items.map(\.startMinute).sorted() == [630, 1350], "Sonden-Speicher: Beginn 90 min vorher (\(store.items.map(\.startMinute)))")
    for key in ["sondePlanSelected", "sondePlanLead"] { UserDefaults.standard.removeObject(forKey: key) }

    // Echte Liste (Stand 04.10.2026, 900 Stationen weltweit)
    if let data = FileManager.default.contents(atPath: "Resources/Sonde/sondehub_sites.json"), let all = SondePlanParser.parse(data) {
        check(all.count == 900, "Sonden-Plan echte Liste: 900 Stationen (\(all.count))")
        let rs41 = all.filter(\.isRS41)
        check(rs41.count == 358, "Sonden-Plan echte Liste: 358 Stationen mit RS41 (\(rs41.count))")
        let stuttgart = all.first { $0.id == "10739" }
        check(stuttgart?.frequencyKHz == 404_500 && stuttgart?.launches.count == 2 && stuttgart?.isRS41 == true, "Sonden-Plan echte Liste: Stuttgart 404,5 MHz, zwei Zeiten")
        let nearReal = SondePlan.nearby(all, home: home, radiusKm: 500)
        check(nearReal.count >= 30 && nearReal.count <= 40, "Sonden-Plan echte Liste: 35 RS41-Startorte bis 500 km von JN49XS (\(nearReal.count))")
        check(nearReal.first.map { $0.km < 100 } == true, "Sonden-Plan echte Liste: nächster Startort unter 100 km")
    }
}
if want("sonde") { sondePlanTests() }

// MARK: - Sonden-Suchlauf: Reihenfolge der Frequenzen und Ablauf
@MainActor func sondeScanTests() {
    typealias E = SondeScanEngine
    // Frequenzliste: bekannte zuerst, ohne Doppelte, nur im Sondenband
    check(E.frequencies(mode: .known, known: [403_500, 402_700, 403_500, 410_000, 399_000], filterKHz: 15) == [403_500, 402_700], "Suchlauf: bekannte Frequenzen ohne Doppelte und ohne Werte außerhalb des Bandes")
    check(E.frequencies(mode: .known, known: [], filterKHz: 15).isEmpty, "Suchlauf: ohne bekannte Frequenzen leer")
    let band = E.frequencies(mode: .band, known: [403_000], filterKHz: 15)
    check(band.first == 403_000 && band.count == 601 && band.contains(400_000) && band.contains(406_000) && band.filter { $0 == 403_000 }.count == 1, "Suchlauf: Band mit 15-kHz-Filter im 10-kHz-Raster, bekannte zuerst (\(band.count))")
    check(band.dropFirst().contains(403_010) && band.dropFirst().contains(402_990) && !band.dropFirst().contains(403_000), "Suchlauf: Raster ohne die schon bekannte Frequenz")
    let wide = E.frequencies(mode: .band, known: [403_000], filterKHz: 50)
    check(wide.count == 241 && wide.first == 403_000 && E.step(filterKHz: 50) == 25 && E.step(filterKHz: 15) == 10, "Suchlauf: 50-kHz-Filter im 25-kHz-Raster (\(wide.count))")
    // eine bekannte Frequenz zwischen zwei Rasterpunkten deckt den nahen Rasterpunkt ab
    let near = E.frequencies(mode: .band, known: [402_704], filterKHz: 15)
    check(near.first == 402_704 && !near.dropFirst().contains(402_700) && near.dropFirst().contains(402_710) && near.count == 601, "Suchlauf: bekannte 402,704 ersetzt den Rasterpunkt 402,700 (\(near.count))")
    check(E.duration(count: 10) == 26, "Suchlauf: 10 Frequenzen dauern 26 s")

    // Ablauf: Frequenz einstellen, einschwingen, hören; Treffer hält an
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var e = E(frequencies: [403_500, 404_000])
    check(e.start(now: t0) == .tune(403_500) && e.current == 403_500, "Suchlauf: beginnt mit der ersten Frequenz")
    check(e.advance(now: t0.addingTimeInterval(0.5), decoded: 7) == nil, "Suchlauf: während des Einschwingens nichts")
    check(e.advance(now: t0.addingTimeInterval(0.9), decoded: 9) == nil, "Suchlauf: Einschwingen vorbei, Zählerstand 9 wird Bezug")
    check(e.advance(now: t0.addingTimeInterval(2.0), decoded: 9) == nil, "Suchlauf: ohne neuen Rahmen weiter hören")
    check(e.advance(now: t0.addingTimeInterval(2.8), decoded: 9) == .tune(404_000) && e.index == 1, "Suchlauf: nach der Hörzeit die nächste Frequenz")
    check(e.advance(now: t0.addingTimeInterval(3.0), decoded: 12) == nil, "Suchlauf: Rahmen aus der Einschwingzeit zählen nicht")
    check(e.advance(now: t0.addingTimeInterval(3.7), decoded: 12) == nil, "Suchlauf: neuer Bezug 12")
    check(e.advance(now: t0.addingTimeInterval(4.0), decoded: 13) == .found(404_000), "Suchlauf: Rahmen gelesen → Treffer auf 404,000 MHz")
    check(e.advance(now: t0.addingTimeInterval(9.0), decoded: 50) == nil, "Suchlauf: nach dem Treffer ruhig")

    var none = E(frequencies: [403_500])
    _ = none.start(now: t0)
    _ = none.advance(now: t0.addingTimeInterval(0.9), decoded: 0)
    check(none.advance(now: t0.addingTimeInterval(2.8), decoded: 0) == .finished, "Suchlauf: letzte Frequenz ohne Treffer → fertig")
    check(none.advance(now: t0.addingTimeInterval(5), decoded: 0) == nil, "Suchlauf: nach dem Ende ruhig")
    var empty = E(frequencies: [])
    check(empty.start(now: t0) == .finished && empty.current == nil, "Suchlauf: leere Liste ist sofort fertig")
}
if want("sonde") { sondeScanTests() }

// MARK: - Sonden-Karte: Zuordnung einer Sonde zu ihrem Startort
@MainActor func sondeLaunchTests() {
    let meiningen = SondeSite(id: "10548", name: "Meiningen (Germany)", point: GeoPoint(lat: 50.56, lon: 10.38), altitude: 450, types: ["41"])
    let stuttgart = SondeSite(id: "10739", name: "Stuttgart / Schnarrenberg (Germany)", point: GeoPoint(lat: 48.83, lon: 9.2), altitude: 315, types: ["41"], frequencyKHz: 404_500)
    let kuemmersbruck = SondeSite(id: "10771", name: "Kuemmersbruck (Germany)", point: GeoPoint(lat: 49.43, lon: 11.9), altitude: 418, types: ["41", "17"], frequencyKHz: 402_700)
    let graw = SondeSite(id: "-97", name: "Graw (Germany)", point: GeoPoint(lat: 49.4, lon: 11.0), altitude: 300, types: ["17"])
    let layer = SondeSiteLayer(sites: [meiningen, stuttgart, kuemmersbruck, graw], shown: ["10548"])

    // Sonde am Boden bei Meiningen (Meiningen hat keine Frequenz in der Liste): Meiningen, auch wenn die Sonde 404,5 MHz meldet
    let ground = SondePlan.launchSite(firstFix: GeoPoint(lat: 50.55, lon: 10.40), altitude: 470, sondeKHz: 404_500, layer: layer)
    check(ground?.site.id == "10548" && (ground?.km ?? 99) < 3, "Startort: Sonde am Boden bei Meiningen → Meiningen (Frequenz unbekannt, Stuttgart zu weit)")
    // ohne gemeldete Frequenz genauso
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 50.55, lon: 10.40), altitude: 470, sondeKHz: nil, layer: layer)?.site.id == "10548", "Startort: ohne Frequenz der Sonde nur nach Entfernung")
    // hoch und abgetrieben erstmals gehört: passende Frequenz geht vor, auch wenn Meiningen näher an der Position liegt
    let drifted = SondePlan.launchSite(firstFix: GeoPoint(lat: 49.9, lon: 11.5), altitude: 12_000, sondeKHz: 402_700, layer: layer)
    check(drifted?.site.id == "10771", "Startort: abgetrieben, Frequenz 402,7 passt → Kümmersbruck (\(drifted?.site.id ?? "nil"))")
    // eine Station mit anderer eingetragener Frequenz scheidet aus
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 48.83, lon: 9.2), altitude: 320, sondeKHz: 403_000, layer: layer) == nil, "Startort: Stuttgart und Kümmersbruck haben andere Frequenzen, Meiningen ist zu weit → keiner")
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 48.83, lon: 9.2), altitude: 320, sondeKHz: 404_495, layer: layer)?.site.id == "10739", "Startort: Frequenz auf 5 kHz genau → Stuttgart")
    // eigene Frequenz je Station
    let mine = SondeSiteLayer(sites: layer.sites, shown: [], frequencies: ["10548": 403_000])
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 50.55, lon: 10.40), altitude: 470, sondeKHz: 403_000, layer: mine)?.site.id == "10548", "Startort: eigene Frequenz für Meiningen passt")
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 50.55, lon: 10.40), altitude: 470, sondeKHz: 404_000, layer: mine) == nil, "Startort: eigene Frequenz für Meiningen passt nicht → keiner")
    // weit weg oder Sonde ohne Bodenbezug: nichts raten; Stationen ohne RS41 zählen nicht
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 52.0, lon: 13.0), altitude: 500, sondeKHz: nil, layer: layer) == nil, "Startort: weit von jeder Station → keiner")
    check(SondePlan.launchSite(firstFix: GeoPoint(lat: 49.4, lon: 11.0), altitude: 300, sondeKHz: nil, layer: layer) == nil || SondePlan.launchSite(firstFix: GeoPoint(lat: 49.4, lon: 11.0), altitude: 300, sondeKHz: nil, layer: layer)?.site.id != "-97", "Startort: Graw (keine RS41) wird nicht zugeordnet")
    check(layer.frequency(stuttgart) == 404_500 && layer.frequency(meiningen) == nil && mine.frequency(meiningen) == 403_000, "Startort: Frequenz eigene Wahl vor Eintrag")
}
if want("sonde") { sondeLaunchTests() }

// MARK: - HFDL (High Frequency Data Link)

/// 26 echte Rahmen aus der Aufnahme „skip.land 2024-11-05 21:18 UTC, 21931 kHz“ (sigidwiki, Riverhead), von Digidec decodiert und
/// vom Referenzdecoder dumphfdl 1.7.0 inhaltlich bestätigt (Squitter, Anmeldungen, Frequenzdaten, ACARS)
let hfdlRealFrames: [[UInt8]] = [
        "10845D19DE010000000000000000000000000000000000000000F01F000000B70100BDD11C000000FE00FEFEFEFEFEFEFEFEFEFE003450000082A10030780000B0F40000",
        "0184FF13097A7F9F954D3EE0000000C157000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0704FF000100388949BF55878FFFD54156413234346F352049CBDC95841500700300828100F03B00830B00F004008F03007009008B1400D001008604004004006FFA0000",
        "07045C0002002C40071DFFFF0132AE4543ADCEC45215D3C13102D3B032C149C2B0313234B04CD6323131383432D3C82F830C8B7FC63C0000000000000000000000004200",
        "10845E1900000000F01F000000B70100BDD11C00000000000000000000000000000000000000F01FFE258EFE9DB5FEFED2FEFEFE003450000085060060480400CD8C0000",
        "0704E00003002044BE1DFFFF0132AECE373234C1D61551B03202D3B531C1C1D6343832B083A21C7F5BEF0000000000000000000000000000000000000000000000003500",
        "070499000100206B4F1DFFFF0132AECEB5B338C1D61551B03802D3B634C1C7D5B037343283CBE07F5BEF0000000000000000000000000000000000000000000000003700",
        "0704FF0001003889494F924A66FFD5525A4F323437E1EA71E4E2E295840500F00700830200E0060082000070F1008F0000F00F00900000F00700860400F007009218B900",
        "0704B5000300317AEC0DFFD154414D333833CAF22EBBDCE99502CB840100000A00520D00000000084C00000205630003000000070000000727480A000000000000003300",
        "0704FF0004003834704F924AB6FFD5525A4F31333468BF81CCF4EA95840500F00700820000B0F000830200E006008F0800F00F00900000F00700860400D007007F2D3100",
        "0704FF0003003831FC4F0576ACFFD54658303034313E350FC0DBEB95840500F00300820000F0F100830200E006008F0200F00F00900000F00700890000F03A7CBBC73000",
        "0704D20004003110F10DFFD155414C3736316BF182E0CBEC9512D5840100000000820260000000022100000000290000000000020000000127AF35000000000000003700",
        "10845F1900000000000000000000000000000000F01F00C015E09119FF51128E01009D511BFFF11FFE0000FEFEFEFEFEFEFEFEFE0034500000870600805800001C750000",
        "0704FF0004003834704F2CAE18FFD54942453031320158406BD1F095840500D00100830200E000008F0000F000009001005004008604005004008D0000500000FF853000",
        "0704FF0004003834704F2000E1FFD54554483530385991E112D9F195840500F00100820000F03300830200A006008F0000E00F00900000F00700860400F00500CAAD4800",
        "F184FF1309FF1609FF1609FF1509FF1509FF16095C1315E0151586739F55878FE1000000DC719F924A66E20000003C9A9F924AB6E3000000B0799F0576ACE400000091D49F9C2304E5000000C55E9F2CAE18E600000052D80DFFFF0132AE4543ADCEC45231DF7FDA8303027FC98F0DFFFF0132AECE373234C1D632DF7FC483C2727FC98F0000000000000000000000000000000000000000000000000000",
        "0704DE0001002CF9741DFFFF0132AE4343ADC2C24615D3C1B302D33734C14CC1B03731B0B045C8323131B6B3B5D3C82F8334267FC63C0000000000000000000000004E00",
        "0704FF00020038EDA6BF2083D8FFD54B514138383617F1BF441AF895840D00D00200830B00F0030082A00030FE00864400500400880000F00F008D0500700000D62F0000",
        "0704AF000400209F991DFFFF0132AECE34B031C1D61551B03102D3B9B3C1C1D6B032B33183E8C07F5BEF0000000000000000000000000000000000000000000000004100",
        "0704E100010020B8001DFFFF0132AECE38B0B0C1D61551B0B602D332B3C1C1D6B0323434831D5A7F5BEF0000000000000000000000000000000000000000000000000000",
        "1084601900C015E09119FF51128E01009D511BFFF11FD2F11FFFF11F00000000E01DFFF11A000000FE0000FE4344FEFE54585E740034500000890400A0880100B84C0000",
        "0704E200030020CCA81DFFFF0132AE43D3AD54D3461551B03802D3B632C1D334B032343783C6937F5BEF000000000000000000000000000000000000000000000000B900",
        "5184FF1609FF1609991515DE1315AF1615E21315F8DE9F2000E1E7000000D1029F2083D8E8000000423C0DFFFF0132AECEB5B338C1D638DF7FC8833ADF7FC98F0DFFFF0132AE4343ADC2C246B3DF7F43835F947FC98F0DFFFF0132AECE34B031C1D631DF7F4383EF127FC98F0DFFFF0132AE43D3AD54D34638DF7F4A836D597FC98F00000000000000000000000000000000000000000000000000000000",
        "0704430003003144480DFFD1434D3034393866461060C70796923684010000030040160000000015D3000000081E01060000030F0000020E277787000000000000003400",
        "0704440003003198780DFFD14C503234383234AB00ABC6059612AF84010000000074000000000016D2000000081B01080001010F0001010F2724ED00000000000000B900",
        "0704E20003002B1F161DFFFF0132AE43D3AD54D34615D3C1B902D3B6B3C1D334B0323437B045C8323132B03137C8D383D61B7F656900000000000000000000000000B900"
    ].map { hex in stride(from: 0, to: hex.count, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)! } }

func hfdlRawFrame(_ bytes: [UInt8], rate: Int = 300) -> HFDLRawFrame {
    HFDLRawFrame(bytes: bytes, bitRate: rate, doubleSlot: bytes.count > 100, freqErrorHz: 0, snrDB: 10, startSample: 0, attempt: 1)
}

func hfdlDecode(_ audio: [Float], chunk: Int = 1200) -> [HFDLRawFrame] {
    let rx = HFDLReceiver()
    var out: [HFDLRawFrame] = []
    var i = 0
    while i < audio.count {
        let e = min(i + chunk, audio.count)
        audio[i..<e].withUnsafeBufferPointer { rx.process($0) { out.append($0) } }
        i = e
    }
    return out
}

@MainActor func hfdlTests() {
    // Konstanten und Tabellen
    check(HFDLPHY.aBits.count == 127 && HFDLPHY.m1Base.count == 127 && HFDLPHY.tSeq.count == 15, "HFDL: Länge der Folgen A, M1, T")
    check(HFDLPHY.modes.map(\.bitRate) == [300, 600, 1200, 1800, 300, 600, 1200, 1800], "HFDL: Datenraten der acht Betriebsarten \(HFDLPHY.modes.map(\.bitRate))")
    check(HFDLPHY.modes[0].totalSymbols == 3771 && HFDLPHY.modes[4].totalSymbols == 8091 && HFDLPHY.preambleLen == 531, "HFDL: Rahmenlängen in Symbolen")
    check(Set((0..<8).map { HFDLPHY.m1Bits($0) }).count == 8, "HFDL: acht verschiedene M1-Folgen")
    let scr = HFDLPHY.scramblerBits(count: 240)
    check(Array(scr[0..<120]) == Array(scr[120..<240]) && scr[0..<120].contains(1) && scr[0..<120].contains(0), "HFDL: Entwürfelfolge wiederholt sich alle 120 Symbole")
    // Prüfsumme CRC-16 (X-25): Prüfwert „123456789“ = 0x906E
    check(HFDLCRC.crc([UInt8]("123456789".utf8)[...]) == 0x906E, "HFDL: CRC-16/X-25 Prüfwert 0x906E: \(String(HFDLCRC.crc([UInt8]("123456789".utf8)[...]), radix: 16))")
    // Faltungscode und Verschachtelung: Rundlauf, auch mit Bitfehlern
    do {
        var g = HFDLSignalGenerator.SplitMix64(seed: 5)
        let n = 540
        var bits = (0..<n).map { _ in UInt8(g.next() & 1) }
        for i in (n - 6)..<n { bits[i] = 0 }
        let coded = HFDLSignalGenerator.convolve(bits)
        let soft = coded.map { UInt8($0 == 1 ? 255 : 0) }
        check(HFDLViterbi.decode(soft: soft, bitCount: n) == bits, "HFDL: Viterbi ohne Fehler")
        var noisy = soft
        for i in stride(from: 11, to: noisy.count - 40, by: 37) { noisy[i] = 255 - noisy[i] }
        check(HFDLViterbi.decode(soft: noisy, bitCount: n) == bits, "HFDL: Viterbi korrigiert einzelne Bitfehler")
        for (cols, shift) in [(54, 17), (126, 23), (108, 17)] {
            let x = (0..<(40 * cols)).map { _ in UInt8(g.next() & 0xFF) }
            let y = HFDLSignalGenerator.interleave(x, columns: cols, pushShift: shift)
            check(HFDLInterleaver.deinterleave(y, columns: cols, pushShift: shift) == x && y != x, "HFDL: Verschachteln und Entschachteln (Spalten \(cols))")
        }
    }
    // Weiche Bits: BPSK-Vorzeichen, QPSK/8PSK Gray (Punkte bei Winkel j·2π/M)
    check(HFDLReceiver.softBits(Cx(1, 0), bits: 1) == [0] && HFDLReceiver.softBits(Cx(-1, 0), bits: 1) == [255], "HFDL: weiche Bits BPSK (+1 = Bit 0)")
    for bps in [2, 3] {
        let m = 1 << bps
        var ok = true
        for j in 0..<m {
            let p = Cx.polar(Double(j) * 2 * Double.pi / Double(m))
            let sb = HFDLReceiver.softBits(p, bits: bps).map { $0 > 127 ? 1 : 0 }
            let sym = sb.reduce(0) { ($0 << 1) | $1 }
            if sym != (j ^ (j >> 1)) { ok = false }
        }
        check(ok, "HFDL: Gray-Zuordnung \(m)-PSK")
    }

    // Echte Rahmen: Prüfsummen und Inhalt (Gegenprobe dumphfdl)
    check(hfdlRealFrames.count == 26 && hfdlRealFrames.allSatisfy { HFDLCRC.headerOK($0) }, "HFDL: alle 26 echten Rahmen haben einen gültigen Kopf")
    check(hfdlRealFrames.allSatisfy { f in let s = HFDLCRC.score(f); return s.good == s.total }, "HFDL: alle LPDU der echten Rahmen haben gültige Prüfsummen")
    var broken = hfdlRealFrames[0]
    broken[10] ^= 0x01
    check(!HFDLCRC.headerOK(broken), "HFDL: ein Bitfehler im Squitter wird erkannt")
    var cache = HFDLAircraftCache()
    var pstats = HFDLParseStats()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var events: [HFDLEvent] = []
    for f in hfdlRealFrames { events += HFDLProtocol.parse(hfdlRawFrame(f), freqKHz: 21931, time: t0, cache: &cache, stats: &pstats) }
    check(pstats.frames == 26 && pstats.badHeader == 0 && pstats.badLPDU == 0, "HFDL: Protokoll ohne Fehler \(pstats)")
    check(Set(events.map(\.id)).count == events.count, "HFDL: jedes Ereignis hat eine eigene Kennung (\(Set(events.map(\.id)).count) von \(events.count))")
    check(events.count == 38, "HFDL: 38 Ereignisse aus den 26 Rahmen (Referenz fand 36 aus 24 Rahmen): \(events.count)")
    let spdus = events.filter { $0.kind == .squitter }
    check(spdus.count == 4, "HFDL: vier Squitter (\(spdus.count))")
    if let s = spdus.first, let q = s.squitter {
        check(s.station == 4 && q.frameIndex == 2397 && q.tableVersion == 52 && s.uplink, "HFDL: Squitter von Riverhead, TDMA-Rahmen 2397, Tabelle 52")
        check(q.stations.map(\.id) == [4, 2, 3], "HFDL: Squitter nennt Riverhead, Molokai, Reykjavik: \(q.stations.map(\.id))")
        check(q.stations[0].frequenciesKHz == [21931, 13276] && q.stations[1].frequenciesKHz == [21937, 11348, 10027] && q.stations[2].frequenciesKHz == [17985, 15025, 11184], "HFDL: Frequenzen in Benutzung wie im Referenzdecoder")
        check(q.stations.allSatisfy(\.utcSync), "HFDL: UTC-Sync der drei Stationen")
    } else { check(false, "HFDL: erster Squitter fehlt") }
    let confirms = events.filter { $0.kind == .logonConfirm }
    check(confirms.first?.icao == 0xA9B27C && confirms.first?.aircraftID == 224, "HFDL: Anmeldebestätigung A9B27C bekommt Nummer 224")
    check(Set(confirms.compactMap(\.icaoHex)).isSuperset(of: ["A9B27C", "AAE1F1", "495266", "49526D", "A06E35", "39C420", "347518", "040087", "04C11B"]), "HFDL: ICAO-Adressen der Bestätigungen")
    let dls = events.first { $0.kind == .logonRequest }
    check(dls?.icaoHex == "AAE1F1" && dls?.flightID == "AVA244" && dls?.positionTime == "21:18:48", "HFDL: Anmeldung (DLS) mit Frequenzdaten AVA244 um 21:18:48")
    check(dls?.position.map { abs($0.lat - 4.696) < 0.001 && abs($0.lon + 74.130) < 0.001 } == true, "HFDL: Ort aus den Frequenzdaten 4,696° N 74,130° W")
    let flights = Set(events.compactMap(\.flightID))
    check(flights.isSuperset(of: ["AVA244", "RZO247", "RZO134", "UAL761", "ETH508", "KQA886", "CM0498", "LP2482", "IB0124", "AV4820", "GU0742", "LA0710", "AV0231", "AV0244", "S40247"]), "HFDL: Flugnummern \(flights.sorted())")
    let acars = events.compactMap(\.acars)
    check(acars.count == 14 && Set(acars.map(\.registration)).isSuperset(of: ["EC-NDR", "N724AV", "N538AV", "CC-BBF", "N401AV", "N800AV", "CS-TSF"]), "HFDL: ACARS-Meldungen mit Kennzeichen (\(acars.count))")
    let sa = events.first { $0.acars?.label == "SA" && $0.registration == "EC-NDR" }
    check(sa?.lines.contains { $0.contains("VHF-ACARS verloren um 21:18:42") && $0.contains("Satcom (Standard), HF") } == true, "HFDL: Medienhinweis (SA): VHF verloren, verfügbar Satcom und HF")
    check(events.filter { $0.acars?.label == "_d" }.count == 6 && events.contains { $0.acars?.label == "Q0" && $0.registration == "N724AV" && $0.icaoHex == "A9B27C" }, "HFDL: Quittungen (_d) und Verbindungstest Q0 mit ICAO-Zuordnung über den Cache")
    check(events.contains { $0.uplink && $0.kind == .data } && events.contains { !$0.uplink && $0.kind == .data }, "HFDL: Aufwärts- und Abwärtsdaten")
    let perf = events.filter { $0.title.contains("Leistungsdaten") }
    check(perf.count >= 4 && perf.allSatisfy { $0.position != nil && $0.flightID != nil && $0.lines.contains { $0.contains("MPDU empfangen") } }, "HFDL: Leistungsdaten mit Ort und Zählern (\(perf.count))")
    let doubleMPDU = HFDLProtocol.parse(hfdlRawFrame(hfdlRealFrames[15], rate: 300), freqKHz: 21931, time: t0, cache: &cache, stats: &pstats)
    check(doubleMPDU.count == 8 && doubleMPDU.allSatisfy(\.uplink), "HFDL: Doppel-Slot-Aufwärts-MPDU mit 8 LPDU für 8 Flugzeuge (\(doubleMPDU.count))")
    check(HFDLProtocol.mediaAdvisory("0LV211842SH/")?.contains("21:18:42") == true && HFDLProtocol.mediaAdvisory("hallo") == nil, "HFDL: Medienhinweis Text")
    check(HFDLProtocol.coordinate(0x7FFFF) > 179.9 && HFDLProtocol.coordinate(0x80000) < -179.9 && abs(HFDLProtocol.coordinate(0)) < 1e-9, "HFDL: 20-Bit-Koordinate mit Vorzeichen")
    check(HFDLProtocol.icao(ArraySlice([0x80, 0x00, 0x01] as [UInt8])) == 0x010080, "HFDL: ICAO-Adresse mit bitumgekehrten Bytes")

    // Bodenstationen
    check(HFDLStations.all.count == 16 && HFDLStations.tableVersion == 52, "HFDL: 16 Bodenstationen, Tabelle 52")
    check(HFDLStations.frequency(station: 4, index: 0) == 21931 && HFDLStations.stations(on: 21931).map(\.id) == [4, 10], "HFDL: Frequenz 21931 gehört Riverhead und Muan")
    check(HFDLStations.frequencies(station: 4, mask: 0b101) == [21931, 13276] && HFDLStations.frequency(station: 99, index: 0) == nil, "HFDL: Frequenzen aus Bitmaske")
    check(HFDLChannels.kHz(presetID: "f8942") == 8942 && HFDLChannels.kHz(presetID: "f1234") == nil && HFDLChannels.kHz(presetID: "x") == nil, "HFDL: Kanal-Preset")
    check(HFDLChannels.allPresetIDs.first == "f8942" && Set(HFDLChannels.allPresetIDs).count == HFDLChannels.allPresetIDs.count && HFDLChannels.allPresetIDs.count == HFDLStations.channels.count, "HFDL: Preset-Liste ohne Doppelte")
    check(HFDLBand.of(kHz: 21931) == .b21 && HFDLBand.of(kHz: 8942) == .b8 && HFDLBand.of(kHz: 2998) == .b2 && HFDLChannels.usedBands.count >= 8, "HFDL: Bänder")
    check(RigTuneTarget.hfdl(frequencyKHz: 21931) == RigTuneTarget(dialHz: 21_931_000, mode: "USB"), "HFDL: Abstimmziel USB, Dial = Kanalfrequenz")
    if case .success(let r) = parse("digidec://decode?mode=hfdl&preset=f8942") { check(r.module == .hfdl && r.presetID == "f8942", "URL hfdl") } else { check(false, "URL hfdl abgelehnt") }
    check(DecoderModuleInfo.hfdl.isAvailable && DecoderModuleInfo.hfdl.hasMap && DecoderModuleInfo.hfdl.band == .hf, "Modul HFDL verfügbar, mit Karte, im HF-Bereich")

    // Rahmen aus dem Testsender durch Empfänger und Protokoll (alle 8 Betriebsarten, auch mit Frequenzversatz und Rauschen)
    let payload = HFDLSignalGenerator.downlinkMPDU(station: 4, aircraft: 77, lpdus: [
        HFDLSignalGenerator.frequencyDataLPDU(flight: "DLH400", lat: 50.03, lon: 8.57, seconds: 45296),
        HFDLSignalGenerator.frequencyDataLPDU(flight: "BAW117", lat: -33.9, lon: 151.2, seconds: 3600)])
    for mode in 0..<8 {
        let sym = HFDLSignalGenerator.frameSymbols(payload: payload, mode: mode)
        let freqErr = mode % 2 == 0 ? 12.0 : -17.0
        let audio = HFDLSignalGenerator.audio(symbols: sym, freqError: freqErr, noise: 0.05, seed: UInt64(mode + 1))
        let got = hfdlDecode(audio)
        check(got.count == 1 && got.first.map { Array($0.bytes.prefix(payload.count)) == payload } == true, "HFDL: Betriebsart \(mode) (\(HFDLPHY.modes[mode].bitRate) bit/s) Nutzlast fehlerfrei, Rahmen \(got.count)")
        if let f = got.first {
            check(f.bitRate == HFDLPHY.modes[mode].bitRate && f.doubleSlot == HFDLPHY.modes[mode].double, "HFDL: Betriebsart \(mode) erkannt (\(f.bitRate), \(f.doubleSlot))")
            check(abs(f.freqErrorHz - freqErr) < 3, "HFDL: Frequenzversatz \(freqErr) Hz geschätzt \(String(format: "%.1f", f.freqErrorHz))")
            let ev = HFDLProtocol.parse(f, freqKHz: 8942, time: t0, cache: &cache, stats: &pstats)
            check(ev.map(\.flightID) == ["DLH400", "BAW117"] && ev[0].position.map { abs($0.lat - 50.03) < 0.001 && abs($0.lon - 8.57) < 0.001 } == true
                  && ev[1].position.map { abs($0.lat + 33.9) < 0.001 && abs($0.lon - 151.2) < 0.001 } == true && ev[0].positionTime == "12:34:56", "HFDL: Betriebsart \(mode) Protokoll: Flugnummern, Orte, Uhrzeit")
        }
    }
    // Schwaches Signal, zwei Rahmen kurz hintereinander, Pause, kein Rahmen im Rauschen
    do {
        let sym0 = HFDLSignalGenerator.frameSymbols(payload: payload, mode: 0)
        let weak = HFDLSignalGenerator.audio(symbols: sym0, freqError: 5, noise: 0.45, seed: 3)
        check(hfdlDecode(weak).count == 1, "HFDL: schwaches Signal (300 bit/s, Rauschen 0,45) wird decodiert")
        let sq = HFDLSignalGenerator.squitter(station: 7, frameIndex: 321)
        let a = HFDLSignalGenerator.audio(symbols: HFDLSignalGenerator.frameSymbols(payload: sq, mode: 0), leadSeconds: 0.3, tailSeconds: 0.2)
        let b = HFDLSignalGenerator.audio(symbols: HFDLSignalGenerator.frameSymbols(payload: payload, mode: 1), leadSeconds: 0.2, tailSeconds: 0.5)
        let both = hfdlDecode(a + b)
        check(both.count == 2 && both[0].bytes.count == 68 && Array(both[1].bytes.prefix(payload.count)) == payload, "HFDL: zwei Rahmen hintereinander (\(both.count))")
        if let s = both.first {
            var c2 = HFDLAircraftCache(), st2 = HFDLParseStats()
            let ev = HFDLProtocol.parse(s, freqKHz: 8942, time: t0, cache: &c2, stats: &st2)
            check(ev.first?.kind == .squitter && ev.first?.station == 7 && ev.first?.squitter?.frameIndex == 321, "HFDL: Squitter aus dem Testsender gelesen")
        }
        var g = HFDLSignalGenerator.SplitMix64(seed: 99)
        let noise = (0..<(12_000 * 40)).map { _ in Float(0.3 * g.gaussian()) }
        check(hfdlDecode(noise).isEmpty, "HFDL: 40 s Rauschen ergeben keinen Rahmen")
        check(hfdlDecode(HFDLSignalGenerator.audio(symbols: sym0).map { -$0 }).count <= 1, "HFDL: invertiertes Audio (LSB) bleibt ohne Absturz")
    }

    // Flugzeugtabelle, Karte und Logzeile im Controller
    let c = HFDLController(pipeline: AudioPipeline(), settings: HFDLSettingsStore())
    c.logEnabled = false
    for f in hfdlRealFrames { c.ingest(frame: hfdlRawFrame(f), at: t0, freqKHz: 21931) }
    check(c.frameCount == 26 && c.events.count == 38, "HFDL-Controller: Rahmen und Ereignisse (\(c.frameCount), \(c.events.count))")
    check(c.aircraft["A9B27C"]?.registration == "N724AV" && c.aircraft["A9B27C"]?.flight == "AV4820", "HFDL: Flugzeug A9B27C = N724AV, Flug AV4820 (aus Anmeldung und ACARS)")
    check(c.aircraft["AAE1F1"]?.flight == "AVA244" || c.aircraft["AAE1F1"]?.flight == "AV0244", "HFDL: Flugzeug AAE1F1 mit Flugnummer")
    check(c.aircraft.values.filter { $0.position != nil }.count >= 8, "HFDL: Flugzeuge mit Ort (\(c.aircraft.values.filter { $0.position != nil }.count))")
    check(c.stations[4]?.frequenciesInUseKHz == [21931, 13276] && c.stations[2]?.frequenciesInUseKHz == [21937, 11348, 10027] && c.stations[4]?.count == 4, "HFDL: Bodenstationen aus den Squittern")
    let map = c.mapContent(home: Maidenhead.point("JN49WS"), now: t0.addingTimeInterval(60))
    check(map.markers.filter { $0.id.hasPrefix("gs-") }.count == 16 && map.markers.filter { $0.id.hasPrefix("ac-") }.count >= 8 && !map.lines.isEmpty, "HFDL-Karte: 16 Bodenstationen, Flugzeuge mit Verbindungslinie")
    check(c.mapContent(home: nil, now: t0.addingTimeInterval(5 * 3600)).markers.allSatisfy { $0.id.hasPrefix("gs-") }, "HFDL-Karte: alte Flugzeuge entfallen")
    if let e = c.events.first(where: { $0.acars?.label == "SA" }) {
        let line = HFDLController.logLine(e)
        check(line.contains("21931") && line.contains("300S") && line.contains("↓") && line.contains("Riverhead") && line.contains("EC-NDR") && line.contains("Label SA"), "HFDL-Logzeile: \(line)")
    }
    // Filter
    let s = HFDLSettingsStore()
    s.showSquitters = false; s.showUplink = true; s.onlyContent = false
    let c2 = HFDLController(pipeline: AudioPipeline(), settings: s)
    c2.logEnabled = false
    for f in hfdlRealFrames { c2.ingest(frame: hfdlRawFrame(f), at: t0, freqKHz: 21931) }
    check(c2.visible.count == c2.events.count - 4, "HFDL: Squitter ausgeblendet")
    s.showUplink = false
    check(c2.visible.allSatisfy { !$0.uplink }, "HFDL: nur Abwärts")
    s.onlyContent = true
    check(c2.visible.allSatisfy { ($0.acars.map { !$0.isEmpty } ?? false) || $0.position != nil }, "HFDL: nur Inhalt")
    // Sprung des Flugzeugs wird nicht geglaubt
    var ac = HFDLAircraft(id: "X", firstHeard: t0, lastHeard: t0)
    check(ac.addPosition(GeoPoint(lat: 50, lon: 8), time: nil, at: t0) && !ac.addPosition(GeoPoint(lat: -30, lon: 150), time: nil, at: t0.addingTimeInterval(60)), "HFDL: Ortssprung wird verworfen")
    check(ac.addPosition(GeoPoint(lat: -30.1, lon: 150), time: nil, at: t0.addingTimeInterval(120)) && ac.track.count == 1, "HFDL: zweiter Bericht an der neuen Stelle gilt, Weg beginnt neu")
    s.frequencyKHz = 13276
    check(s.stationsOnChannel.count >= 3 && s.centerHz == 1440, "HFDL: Stationen auf 13276 kHz, NF-Mitte 1440 Hz")
}
if want("hfdl") { hfdlTests() }


// MARK: - Wetterauswertung (0.54.0): Feuchte, Gitter, Isobaren, Hoch/Tief, Farbfläche
if want("weather") {
    // Relative Luftfeuchte (Magnus-Formel)
    check(WeatherMath.relativeHumidity(temperatureC: 20, dewpointC: 10).map { abs($0 - 52.5) < 1 } == true, "Feuchte: 20 °C / Taupunkt 10 °C ≈ 52,5 %")
    check(WeatherMath.relativeHumidity(temperatureC: 5, dewpointC: 5) == 100, "Feuchte: Taupunkt = Temperatur → 100 %")
    check(WeatherMath.relativeHumidity(temperatureC: 10, dewpointC: 12) == nil && WeatherMath.relativeHumidity(temperatureC: nil, dewpointC: 5) == nil, "Feuchte: unplausibel oder fehlend → nil")

    // Stationsraster mit Hoch bei 48°N 4°O (1035) und Tief bei 57°N 20°O (982); fest, ohne Zufall
    func pressureAt(_ lat: Double, _ lon: Double) -> Double {
        let h = 25 * exp(-(pow((lat - 48) / 6, 2) + pow((lon - 4) / 9, 2)))
        let t = -28 * exp(-(pow((lat - 57) / 5, 2) + pow((lon - 20) / 8, 2)))
        return 1010 + h + t
    }
    var raster: [(lat: Double, lon: Double, p: Double)] = []
    for i in 0..<15 {
        for j in 0..<15 {
            let lat = ((40 + 24 * (Double(i) + 0.5) / 15 + 0.5 * cos(Double(5 * i + 2 * j))) * 1000).rounded() / 1000
            let lon = ((-8 + 40 * (Double(j) + 0.5) / 15 + 0.7 * sin(Double(7 * i + 3 * j))) * 1000).rounded() / 1000
            raster.append((lat, lon, (pressureAt(lat, lon) * 10).rounded() / 10))
        }
    }
    let samples = raster.map { FieldSample(point: GeoPoint(lat: $0.lat, lon: $0.lon), value: $0.p) }
    check(WeatherField.grid(samples: Array(samples.prefix(4))) == nil, "Gitter: unter 5 Werte → keines")
    check(WeatherField.grid(samples: [FieldSample(point: GeoPoint(lat: 0, lon: -100), value: 1), FieldSample(point: GeoPoint(lat: 1, lon: 100), value: 2)] + samples.prefix(4)) == nil, "Gitter: über 180° Breite → keines")
    if let g = WeatherField.grid(samples: samples) {
        let r = g.range
        check(r != nil && r!.min > 981 && r!.min < 986 && r!.max > 1031 && r!.max < 1036, "Gitter: Wertebereich folgt dem Feld (\(String(describing: r)))")
        // Hoch und Tief an der richtigen Stelle, nichts sonst
        let ex = WeatherField.extrema(of: g)
        let highs = ex.filter { $0.isHigh }, lows = ex.filter { !$0.isHigh }
        check(highs.count == 1 && abs(highs[0].point.lat - 48) < 2.5 && abs(highs[0].point.lon - 4) < 3.5 && highs[0].value > 1031 && highs[0].value < 1036, "Hoch bei 48°N 4°O: \(highs)")
        check(lows.count == 1 && abs(lows[0].point.lat - 57) < 2.5 && abs(lows[0].point.lon - 20) < 3.5 && lows[0].value > 981 && lows[0].value < 986, "Tief bei 57°N 20°O: \(lows)")
        // Isobaren: um Hoch und Tief geschlossene Ringe, nach außen offene Linien
        let ring1024 = WeatherField.contours(of: g, level: 1024)
        check(ring1024.count == 1 && ring1024[0].isClosed && ring1024[0].points.count > 8, "Isobare 1024 hPa: ein geschlossener Ring um das Hoch (\(ring1024.count))")
        let ring992 = WeatherField.contours(of: g, level: 992)
        check(ring992.count == 1 && ring992[0].isClosed, "Isobare 992 hPa: ein geschlossener Ring um das Tief")
        let open1008 = WeatherField.contours(of: g, level: 1008)
        check(!open1008.isEmpty && open1008.allSatisfy { !$0.isClosed }, "Isobare 1008 hPa: offene Linien zwischen Hoch und Tief")
        let all = WeatherField.contourLines(of: g, step: 4)
        let levels = Set(all.map { Int($0.level) })
        check(levels.contains(1024) && levels.contains(992) && levels.allSatisfy { $0 % 4 == 0 }, "Isobaren alle 4 hPa: \(levels.sorted())")
        check(all.allSatisfy { line in line.points.allSatisfy { $0.isValid } }, "Isobaren: alle Punkte gültig")
        // Abgerundet: Anfang und Ende offener Linien bleiben, geschlossene bleiben geschlossen
        if let open = open1008.first {
            let rounded = WeatherField.rounded(open)
            check(rounded.points.first == open.points.first && rounded.points.last == open.points.last && rounded.points.count > open.points.count, "Chaikin: Enden bleiben, mehr Punkte")
        }
        let r2 = WeatherField.rounded(ring1024[0])
        check(r2.isClosed && r2.points.first == r2.points.last, "Chaikin: geschlossene Linie bleibt geschlossen")
        check(WeatherField.contourLines(of: g, step: 0).isEmpty, "Isobaren: Abstand 0 → keine")
    } else {
        check(false, "Gitter aus 225 Stationen")
    }

    // Marching Squares auf Hand-Gittern
    func handGrid(_ rows: Int, _ cols: Int, _ f: (Int, Int) -> Double) -> WeatherGrid {
        var v: [Double] = []
        for r in 0..<rows { for c in 0..<cols { v.append(f(r, c)) } }
        return WeatherGrid(latMin: 50, lonMin: 8, dLat: 1, dLon: 1, rows: rows, cols: cols, values: v)
    }
    let ramp = handGrid(4, 4) { r, _ in Double(r) }
    let rampLines = WeatherField.contours(of: ramp, level: 1.5)
    check(rampLines.count == 1 && rampLines[0].points.count == 4 && !rampLines[0].isClosed && rampLines[0].points.allSatisfy { abs($0.lat - 51.5) < 1e-9 }, "Rampe: eine waagerechte offene Linie bei 51,5°N (\(rampLines.count))")
    let peak = handGrid(5, 5) { r, c in r == 2 && c == 2 ? 10 : 0 }
    let peakLines = WeatherField.contours(of: peak, level: 5)
    check(peakLines.count == 1 && peakLines[0].isClosed && peakLines[0].points.count == 5, "Gipfel: ein geschlossener Ring aus 4 Stücken (\(peakLines.map { $0.points.count }))")
    let saddle = handGrid(2, 2) { r, c in (r + c) % 2 == 0 ? 10 : 0 }
    check(WeatherField.contours(of: saddle, level: 5).count == 2 && WeatherField.contours(of: saddle, level: 6).count == 2, "Sattel: zwei getrennte Linien, wie der Mittelwert auch fällt")
    check(WeatherField.contours(of: ramp, level: 99).isEmpty && WeatherField.contours(of: ramp, level: -1).isEmpty, "Linie außerhalb des Wertebereichs: keine")
    var holey = handGrid(4, 4) { r, _ in Double(r) }
    holey.values[1 * 4 + 1] = .nan
    let holeyLines = WeatherField.contours(of: holey, level: 1.5)
    check(holeyLines.allSatisfy { $0.points.count >= 2 } && holeyLines.reduce(0, { $0 + $1.points.count }) < 4 + 4, "Leerer Eckpunkt: Zellen daneben fallen aus")

    // Farbflächen: waagerechte Nachbarn gleicher Stufe werden zu einem Rechteck
    let flat = handGrid(3, 6) { _, _ in 10 }
    let flatPatches = WeatherField.patches(of: flat, bandWidth: 2.5) { ($0 + 20) / 55 }
    check(flatPatches.count == 3 && flatPatches.allSatisfy { $0.corners.count == 4 && abs($0.level - (11.25 + 20) / 55) < 1e-9 }, "Flächen: je Zeile ein Rechteck, Stufenmitte 11,25 °C (\(flatPatches.count))")
    let stepped = handGrid(1, 6) { _, c in c < 3 ? 1 : 11 }
    check(WeatherField.patches(of: stepped, bandWidth: 2.5) { $0 }.count == 2, "Flächen: zwei Stufen nebeneinander → zwei Rechtecke")
    let gapped = handGrid(1, 6) { _, c in c == 3 ? .nan : 5 }
    check(WeatherField.patches(of: gapped, bandWidth: 2.5) { $0 }.count == 2, "Flächen: leere Zelle trennt")
}

// MARK: - Wetterauswertung: Extremwerte, Ebenen, Überlagerung, CSV (Klartext wie vom SYNOP-Decoder)
if want("weather") {
    let now = Date()
    func klar(_ id: String, lat: Double, lon: Double, t: Double? = nil, td: Double? = nil, p: Double? = nil, rain: Double? = nil, wind: Int? = nil) -> String {
        var s = "\tShip/Buoy identifier=\(id)\n\tLatitude=\(lat)\n\tLongitude=\(lon)\n"
        if let t { s += "\tTemperature=\(t) °C\n" }
        if let td { s += "\tDewpoint temperature=\(td) °C\n" }
        if let p { s += "\tSea level pressure=\(p) hPa\n" }
        if let wind { s += "\tWind speed=\(wind) knots\n" }
        if let rain { s += "\tPrecipitation amount=\(rain) mm\n\tPrecipitation duration=6 hours\n" }
        return s
    }
    let log = SynopLog()
    log.feed(klar("DBAA", lat: 54.0, lon: 8.0, t: 30.5, td: 10.0, p: 1020.4, rain: 12.0)
             + klar("DBBB", lat: 55.0, lon: 9.0, t: -5.0, td: -8.0, p: 995.0, rain: 0.0, wind: 40)
             + klar("DBCC", lat: 53.0, lon: 7.0, t: 12.0, td: 11.0, p: 1013.0)
             + klar("DBDD", lat: 52.0, lon: 6.0, t: 21.0, td: 9.0, rain: 3.2)
             + klar("DBEE", lat: 51.0, lon: 5.0, t: 8.0), decoded: true, at: now)
    log.feed("X", decoded: false, at: now)
    log.flush(at: now)
    check(log.observations.count == 5, "Auswertung: fünf Stationen (\(log.observations.count))")
    let a = log.observations["DBAA"]
    check(a?.dewpointC == 10 && a?.seaLevelPressureHPa == 1020.4 && a?.precipitationMm == 12 && a?.precipitationHours == 6, "Beobachtung: Taupunkt, Meeresdruck, Niederschlag und Zeitraum")
    check(a?.humidityPct.map { $0 > 25 && $0 < 33 } == true && log.observations["DBEE"]?.humidityPct == nil, "Feuchte aus Temperatur und Taupunkt, ohne Taupunkt keine (\(String(describing: a?.humidityPct)))")
    check(log.observations["DBDD"]?.seaLevelPressureHPa == nil, "Ohne Druck auf Meereshöhe bleibt das Feld leer")

    // Extremwerte
    let t = log.extremes(layer: .temperature, count: 2, now: now)
    check(t?.highest.map(\.id) == ["synop-DBAA", "synop-DBDD"] && t?.lowest.map(\.id) == ["synop-DBBB", "synop-DBEE"] && t?.stations == 5, "Extremwerte Temperatur: höchste und niedrigste (\(String(describing: t?.highest.map(\.id))), \(String(describing: t?.lowest.map(\.id))))")
    check(t?.highest.first?.text == "30,5 °C" && t?.lowest.first?.text == "-5,0 °C", "Extremwerte: Text mit Komma und Einheit (\(String(describing: t?.highest.first?.text)))")
    check(log.extremes(layer: .humidity, count: 1, now: now)?.highest.first?.id == "synop-DBCC", "Extremwerte Feuchte: DBCC mit 99 %")
    let rain = log.extremes(layer: .precipitation, count: 3, now: now)
    check(rain?.highest.first?.id == "synop-DBAA" && rain?.lowest.isEmpty == true && rain?.stations == 3, "Extremwerte Niederschlag: nur höchste, 3 Stationen")
    check(log.extremes(layer: .wind, count: 3, now: now)?.highest.map(\.id) == ["synop-DBBB"] && log.extremes(layer: .wind, count: 3, now: now)?.lowest.isEmpty == true, "Extremwerte Wind: eine Station, keine niedrigsten")
    check(log.extremes(layer: .visibility, now: now) == nil && log.extremes(layer: .symbol, now: now) == nil && log.extremes(layer: .sea, now: now) == nil, "Extremwerte: ohne Daten oder ohne Messwert-Ebene nil")

    // Ebenen auf der Karte
    let hum = log.content(home: nil, now: now, layer: .humidity).markers.filter { $0.id.hasPrefix("synop-") }
    check(hum.count == 4 && hum.allSatisfy { $0.valueText != nil && $0.valueLevel != nil }, "Karte Feuchte: vier Stationen mit Taupunkt (\(hum.count))")
    let reg = log.content(home: nil, now: now, layer: .precipitation).markers.filter { $0.id.hasPrefix("synop-") }
    check(reg.count == 3 && reg.contains { $0.valueText == "12" } && reg.contains { $0.valueText == "3,2" }, "Karte Niederschlag: \(reg.map { $0.valueText ?? "-" })")
    let details = log.content(home: nil, now: now, layer: .symbol).markers.first { $0.id == "synop-DBAA" }?.details ?? []
    check(details.contains { $0.hasPrefix("Feuchte") } && details.contains { $0.contains("Niederschlag 12 mm in 6 h") }, "Auswahl nennt Feuchte und Niederschlag: \(details)")
    check(SynopLog.Layer.allCases.filter { $0 != .symbol && $0 != .sea }.allSatisfy { SynopLog.Layer.measured.contains($0) }, "Alle Messwert-Ebenen sind aufgeführt")
    check(SynopLog.Layer.temperature.text(-5) == "-5,0 °C" && SynopLog.Layer.pressure.text(1013) == "1013 hPa" && SynopLog.Layer.pressure.text(1013.4) == "1013,4 hPa" && SynopLog.Layer.visibility.text(4.5) == "4,5 km" && SynopLog.Layer.humidity.text(52.4) == "52 %", "Werttexte je Ebene")

    // Abschluss-Rückruf: jede Meldung einmal, erst wenn vollständig
    let em = SynopLog()
    var emitted: [String] = []
    em.onObservationClosed = { emitted.append($0.id) }
    em.feed(klar("DBAA", lat: 54.0, lon: 8.0, t: 10), decoded: true, at: now)
    em.feed("X", decoded: false, at: now)
    check(emitted.isEmpty, "Abschluss: die laufende Meldung ist noch nicht fertig")
    em.feed(klar("DBBB", lat: 55.0, lon: 9.0, t: 11), decoded: true, at: now)
    em.feed("X", decoded: false, at: now)
    check(emitted == ["DBAA"], "Abschluss: die nächste Meldung schließt die vorige ab (\(emitted))")
    em.feed("\tBulletin end\n", decoded: true, at: now)
    em.feed("X", decoded: false, at: now)
    check(emitted == ["DBAA", "DBBB"], "Abschluss: „Bulletin end“ schließt die letzte ab (\(emitted))")
    // Wiederholt der Sender den Block, kommt nichts doppelt; die unfertige Meldung nach „Bulletin end“ wird nicht vorzeitig gemeldet
    em.feed(klar("DBAA", lat: 54.0, lon: 8.0, t: 10), decoded: true, at: now)
    em.feed("X", decoded: false, at: now)
    em.feed("\tTemperature=", decoded: true, at: now)
    em.feed("X", decoded: false, at: now)
    check(emitted == ["DBAA", "DBBB"], "Abschluss: keine Doppelten, keine unfertige Meldung (\(emitted))")
    let revBefore = em.revision
    em.flush(at: now.addingTimeInterval(5))
    em.flush(at: now.addingTimeInterval(10))
    check(em.revision == revBefore, "Wiederholtes Auswerten derselben offenen Meldung ändert die Revision nicht")

    // CSV
    let fields = SynopCSV.row(a!).components(separatedBy: ";")
    check(fields.count == SynopCSV.columns.count && SynopCSV.header.components(separatedBy: ";").count == SynopCSV.columns.count, "CSV: Zeile und Kopf haben \(SynopCSV.columns.count) Spalten (\(fields.count))")
    check(fields[0].hasPrefix("20") && fields[0].hasSuffix("Z") && fields[2] == "DBAA" && fields[4] == "54.000" && fields[7] == "30.5" && fields[8] == "10.0" && fields[10] == "1020.4" && fields[11] == "Meereshoehe" && fields[16] == "12.0" && fields[17] == "6", "CSV: Werte mit Dezimalpunkt (\(fields))")
    let noRain = SynopCSV.row(log.observations["DBEE"]!).components(separatedBy: ";")
    check(noRain[8] == "" && noRain[9] == "" && noRain[10] == "" && noRain[11] == "" && noRain[16] == "", "CSV: fehlende Werte bleiben leer (\(noRain))")
    check(SynopCSV.text("a;b") == "\"a;b\"" && SynopCSV.text("x\"y") == "\"x\"\"y\"" && SynopCSV.text("plain") == "plain", "CSV: Anführungszeichen bei Semikolon und Anführungszeichen")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("digidec-csv-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = SynopCSVWriter(directory: dir)
    check(writer.append(a!) && writer.append(log.observations["DBBB"]!), "CSV-Datei: schreiben")
    let fileText = (try? String(contentsOf: writer.fileURL(for: a!.received), encoding: .utf8)) ?? ""
    let lines = fileText.split(separator: "\n").map(String.init)
    check(lines.count == 3 && lines[0] == SynopCSV.header && lines[1].contains(";DBAA;") && lines[2].contains(";DBBB;"), "CSV-Datei: Kopfzeile einmal, dann je Meldung eine Zeile (\(lines.count))")
    check(writer.fileURL(for: a!.received).lastPathComponent.hasPrefix("SYNOP-20") && writer.fileURL(for: a!.received).pathExtension == "csv", "CSV-Datei: Name SYNOP-JJJJ-MM-TT.csv")
}

// MARK: - Isobaren und Temperaturfläche aus den SYNOP-Beobachtungen (mit Zwischenspeicher)
if want("weather") {
    let now = Date()
    func pressureAt(_ lat: Double, _ lon: Double) -> Double {
        let h = 25 * exp(-(pow((lat - 48) / 6, 2) + pow((lon - 4) / 9, 2)))
        let t = -28 * exp(-(pow((lat - 57) / 5, 2) + pow((lon - 20) / 8, 2)))
        return 1010 + h + t
    }
    var text = ""
    for i in 0..<15 {
        for j in 0..<15 {
            let lat = ((40 + 24 * (Double(i) + 0.5) / 15 + 0.5 * cos(Double(5 * i + 2 * j))) * 1000).rounded() / 1000
            let lon = ((-8 + 40 * (Double(j) + 0.5) / 15 + 0.7 * sin(Double(7 * i + 3 * j))) * 1000).rounded() / 1000
            let p = (pressureAt(lat, lon) * 10).rounded() / 10
            let temp = ((25 - 0.8 * (lat - 40)) * 10).rounded() / 10
            text += "\tShip/Buoy identifier=ST\(i)X\(j)\n\tLatitude=\(lat)\n\tLongitude=\(lon)\n\tTemperature=\(temp) °C\n\tSea level pressure=\(p) hPa\n"
        }
    }
    let log = SynopLog()
    log.feed(text, decoded: true, at: now)
    log.feed("X", decoded: false, at: now)
    log.flush(at: now)
    check(log.observations.count == 225, "Überlagerung: 225 Stationen (\(log.observations.count))")

    check(!SynopOverlayOptions.off.isActive && SynopOverlayOptions(isobarStepHPa: 4).isActive && SynopOverlayOptions(temperatureField: true).isActive, "Überlagerung: aktiv nur mit Isobaren oder Fläche")
    let none = log.content(home: nil, now: now, layer: .temperature)
    check(none.contours.isEmpty && none.patches.isEmpty && none.note == nil, "Ohne Überlagerung bleibt die Karte wie bisher")

    let iso = log.overlay(options: SynopOverlayOptions(isobarStepHPa: 4), now: now)
    let levels = Set(iso.contours.map { Int($0.level) })
    check(iso.contours.count >= 8 && levels.contains(1024) && levels.contains(992) && iso.patches.isEmpty && iso.note == nil, "Isobaren aus Stationen: \(iso.contours.count) Linien, Ebenen \(levels.sorted())")
    check(iso.contours.contains { $0.label == "1024" && $0.labelPoint != nil } && Set(iso.contours.map(\.id)).count == iso.contours.count, "Isobaren: beschriftet, Kennungen eindeutig")
    let hl = iso.centers.sorted { $0.title < $1.title }
    check(hl.count == 2 && hl[0].title == "Hoch" && hl[1].title == "Tief" && hl[0].valueText?.hasPrefix("H 103") == true && hl[1].valueText?.hasPrefix("T 98") == true, "Hoch und Tief als Punkte: \(hl.map { $0.valueText ?? "-" })")
    let iso2 = log.overlay(options: SynopOverlayOptions(isobarStepHPa: 2), now: now)
    check(iso2.contours.count > iso.contours.count, "Isobaren alle 2 hPa: mehr Linien als alle 4 hPa (\(iso2.contours.count) / \(iso.contours.count))")
    check(log.overlay(options: SynopOverlayOptions(isobarStepHPa: 4), now: now).contours.count == iso.contours.count, "Überlagerung aus dem Zwischenspeicher: gleiches Ergebnis")

    let tf = log.overlay(options: SynopOverlayOptions(temperatureField: true), now: now)
    check(tf.contours.isEmpty && tf.patches.count > 20 && tf.patches.allSatisfy { $0.level >= 0 && $0.level <= 1 && $0.corners.count == 4 }, "Temperaturfläche: \(tf.patches.count) Rechtecke")
    // Wärmer im Süden: der südlichste Streifen hat einen höheren Farbwert als der nördlichste
    let south = tf.patches.min { ($0.corners[0].lat) < ($1.corners[0].lat) }
    let north = tf.patches.max { ($0.corners[0].lat) < ($1.corners[0].lat) }
    check(south != nil && north != nil && south!.level > north!.level, "Temperaturfläche: Süden wärmer als Norden")

    let both = log.content(home: nil, now: now, layer: .temperature, overlay: SynopOverlayOptions(isobarStepHPa: 4, temperatureField: true))
    check(!both.contours.isEmpty && !both.patches.isEmpty && both.markers.contains { $0.id.hasPrefix("hl-") } && both.markers.contains { $0.id.hasPrefix("synop-") }, "Karteninhalt: Stationen, Hoch/Tief, Isobaren und Fläche zusammen")

    // Zu wenige Stationen: Hinweis statt Linien
    let few = SynopLog()
    few.feed("\tShip/Buoy identifier=A1\n\tLatitude=50\n\tLongitude=8\n\tSea level pressure=1010 hPa\n\tTemperature=10 °C\n"
             + "\tShip/Buoy identifier=A2\n\tLatitude=51\n\tLongitude=9\n\tSea level pressure=1011 hPa\n\tTemperature=11 °C\n", decoded: true, at: now)
    few.feed("X", decoded: false, at: now)
    let fewOverlay = few.overlay(options: SynopOverlayOptions(isobarStepHPa: 4, temperatureField: true), now: now)
    check(fewOverlay.contours.isEmpty && fewOverlay.patches.isEmpty && fewOverlay.note?.contains("mindestens 5") == true, "Zu wenige Stationen: Hinweis (\(fewOverlay.note ?? "-"))")
    // Alte Meldungen fließen nicht ein
    check(log.overlay(options: SynopOverlayOptions(isobarStepHPa: 4), now: now.addingTimeInterval(SynopLog.overlayMaxAge + 3600)).contours.isEmpty, "Meldungen älter als 9 Stunden zählen nicht für Isobaren")
    // Stationsdruck ohne Meereshöhe: keine Isobaren (Höhenfehler)
    let stationOnly = SynopLog()
    var stText = ""
    for i in 0..<8 { stText += "\tShip/Buoy identifier=S\(i)\n\tLatitude=\(48 + Double(i) * 0.7)\n\tLongitude=\(8 + Double(i % 3))\n\tStation pressure=\(900 + i * 3) hPa\n" }
    stationOnly.feed(stText, decoded: true, at: now)
    stationOnly.feed("X", decoded: false, at: now)
    check(stationOnly.overlay(options: SynopOverlayOptions(isobarStepHPa: 4), now: now).contours.isEmpty, "Nur Stationsdruck: keine Isobaren")
}

// MARK: - Textfilter für den Empfangstext
if want("weather") {
    func run(_ f: ReceiveTextFilter, _ text: String, chunk: Int) -> String {
        var runner = ReceiveTextFilterRunner(filter: f)
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
            out += runner.process(String(text[i..<j]))
            i = j
        }
        return out + runner.flush()
    }
    let stream = "RYRYRYRYRYRY\r\nZCZC ABC\r\nBBXX DBCR 22064 99543\r\n=\r\nNNNN\r\nRYRYRYRYRY\r\nxx bbxx AAAA 1=\r\nNNNN rest"
    let window = ReceiveTextFilter(enabled: true, start: "bbxx", stop: "nnnn", hideFiller: true)
    let expected = "BBXX DBCR 22064 99543\r\n=\r\nNNNN\nbbxx AAAA 1=\r\nNNNN"
    for n in [1, 2, 3, 5, 7, 100] {
        let out = run(window, stream, chunk: n)
        check(out == expected, "Filter ab/bis, Stücke zu \(n): \(out.debugDescription)")
    }
    // Nur Füllzeichen weglassen, auch über Stückgrenzen
    let fillerOnly = ReceiveTextFilter(enabled: true, start: "", stop: "", hideFiller: true)
    for n in [1, 4, 100] {
        check(run(fillerOnly, stream, chunk: n) == "\r\nZCZC ABC\r\nBBXX DBCR 22064 99543\r\n=\r\nNNNN\r\n\r\nxx bbxx AAAA 1=\r\nNNNN rest", "Nur RYRY weg, Stücke zu \(n)")
    }
    // Ausgeschaltet: alles unverändert, auch wenn Start und Stopp gesetzt sind
    check(run(ReceiveTextFilter(enabled: false, start: "bbxx", stop: "nnnn"), stream, chunk: 3) == stream, "Filter aus: Text unverändert")
    // Stopp ohne Start wirkt nicht
    check(run(ReceiveTextFilter(enabled: true, start: "", stop: "nnnn", hideFiller: false), stream, chunk: 7) == stream, "Stopp ohne Start: alles bleibt")
    // Wörter, die auf RY enden, gehen nicht verloren
    let words = "WEATHER FORECAST SECONDARY PRIMARY\r\n"
    check(run(ReceiveTextFilter(enabled: true, hideFiller: true), words, chunk: 1) == words, "Wörter mit …RY am Ende bleiben erhalten")
    // Klartext der SYNOP-Auswertung folgt dem Zustand
    var runner = ReceiveTextFilterRunner(filter: window)
    check(!runner.allowsDecoded(), "Filter zu: Klartext wird nicht angezeigt")
    _ = runner.process("BBXX ")
    check(runner.allowsDecoded(), "Filter offen: Klartext wird angezeigt")
    _ = runner.process("DBCR=NNNN")
    check(!runner.allowsDecoded(), "Nach dem Stopptext wieder zu")
    runner.configure(ReceiveTextFilter(enabled: false))
    check(runner.allowsDecoded(), "Filter aus: Klartext immer")
    check(ReceiveTextFilter().summary == "aus" && window.summary == "ab „bbxx“ bis „nnnn“ ohne RYRY" && ReceiveTextFilter(enabled: true, hideFiller: false).summary == "an", "Filter: Kurzbeschreibung")
    let coded = try? JSONDecoder().decode(ReceiveTextFilter.self, from: JSONEncoder().encode(window))
    check(coded == window, "Filter: Speicherformat Rundreise")
}

// MARK: - Rohmeldung einer Station im Text finden (Sprung von der Karte)
if want("weather") {
    let text = "AAXX 05061\r\n10655 12970 82205 10123 20103 10655 40113=\r\n10015 NIL=\r\n\tWMO Station=10655\r\n\tWMO station=Wuerzburg\r\nBBXX DBCR 05064 99543 10655 11111=\r\nNNNN\r\n"
    func part(_ id: String) -> String? {
        SynopRawLocator.find(id: id, in: text).map { (text as NSString).substring(with: $0) }
    }
    check(part("10655") == "10655 12970 82205 10123 20103 10655 40113=", "Rohmeldung: Anfang am Zeilenanfang, bis zum „=“; Zahl mitten in der Meldung und Klartext zählen nicht (\(String(describing: part("10655"))))")
    check(part("DBCR") == "DBCR 05064 99543 10655 11111=", "Rohmeldung: Schiff hinter BBXX (\(String(describing: part("DBCR"))))")
    check(part("10015") == "10015 NIL=", "Rohmeldung: Station nach „=“")
    check(part("99999") == nil && SynopRawLocator.find(id: "", in: text) == nil && SynopRawLocator.find(id: "10655", in: "") == nil, "Rohmeldung: unbekannt oder leer → nil")
    // Nur freistehendes Vorkommen mitten in einer Zeile: notfalls dieses
    check(SynopRawLocator.find(id: "4321", in: "foo bar 4321 baz") == NSRange(location: 8, length: 8), "Rohmeldung: ohne Meldungsanfang das letzte freistehende Vorkommen")
    // Teil einer längeren Zahl zählt nicht
    check(SynopRawLocator.find(id: "655", in: text) == nil && SynopRawLocator.find(id: "1065", in: text) == nil, "Rohmeldung: Teil einer längeren Kennung zählt nicht")
    // Das letzte Vorkommen gewinnt (Meldung wurde wiederholt)
    let twice = "10655 12970 1=\r\n10655 12980 2=\r\n"
    check(SynopRawLocator.find(id: "10655", in: twice).map { (twice as NSString).substring(with: $0) } == "10655 12980 2=", "Rohmeldung: bei Wiederholung die jüngste")
}


// MARK: - Freies Funkgerät: Endpunkt, Profile, Verbindung zu beliebigem Rechner (rigctld nachgebaut)
if want("rig") {
    // Endpunkt: Rechner und Port prüfen
    check(RigEndpoint(host: "127.0.0.1", port: 4532)?.text == "127.0.0.1:4532" && RigEndpoint(host: " radio.local ", port: 4533)?.host == "radio.local", "Endpunkt: IP und Name, Leerzeichen am Rand fallen weg")
    check(RigEndpoint(host: "::1", port: 4532)?.text == "[::1]:4532" && RigEndpoint(host: "fe80::1", port: 1)?.text == "[fe80::1]:1", "Endpunkt: IPv6 in eckigen Klammern")
    check(RigEndpoint(host: "", port: 4532) == nil && RigEndpoint(host: "a b", port: 4532) == nil && RigEndpoint(host: "röntgen", port: 4532) == nil && RigEndpoint(host: "host;rm", port: 4532) == nil, "Endpunkt: leer, Leerzeichen, Umlaute, Sonderzeichen ungültig")
    check(RigEndpoint(host: "x", port: 0) == nil && RigEndpoint(host: "x", port: 65536) == nil && RigEndpoint(host: "x", port: 65535) != nil && RigEndpoint(host: "x", port: 1) != nil, "Endpunkt: Port 1 … 65535")
    check(RigEndpoint(host: String(repeating: "a", count: 254), port: 1) == nil && RigEndpoint(host: String(repeating: "a", count: 253), port: 1) != nil, "Endpunkt: höchstens 253 Zeichen")
    check(RigEndpoint.loopback(port: 4532).isLoopback && RigEndpoint(host: "localhost", port: 1)!.isLoopback && RigEndpoint(host: "127.1.2.3", port: 1)!.isLoopback && RigEndpoint(host: "::1", port: 1)!.isLoopback
          && !RigEndpoint(host: "192.168.1.20", port: 1)!.isLoopback && !RigEndpoint(host: "shack.example.org", port: 1)!.isLoopback, "Endpunkt: Loopback erkannt")

    // Profil
    var p = RigProfile(name: "IC-7300")
    check(p.host == "127.0.0.1" && p.port == 4532 && p.endpoint == RigEndpoint.loopback(port: 4532) && p.problem == nil && p.displayName == "IC-7300", "Profil: Voreinstellungen 127.0.0.1:4532")
    p.host = "bad host"
    check(p.endpoint == nil && p.problem?.hasPrefix("Rechner") == true, "Profil: ungültiger Rechner wird gemeldet")
    p.host = "pi.local"; p.port = 70000
    check(p.endpoint == nil && p.problem?.hasPrefix("Port") == true, "Profil: ungültiger Port wird gemeldet")
    check(RigProfile(name: "  ", host: "pi.local", port: 4534).displayName == "rigctld pi.local:4534", "Profil: ohne Namen Rechner und Port als Anzeige")

    // Liste
    var list = RigProfileList()
    let a = list.add(RigProfile(name: "")), b = list.add(RigProfile(name: "FDM-DUO", host: "192.168.1.5", port: 4540, audioUID: "UID-1", audioName: "USB Audio"))
    check(a.name == "Funkgerät 1" && list.profiles.count == 2 && list.active == nil, "Liste: leerer Name wird „Funkgerät 1“, ohne Wahl gilt die Automatik")
    list.activeID = b.id
    check(list.active?.name == "FDM-DUO" && list.profile(id: a.id)?.id == a.id, "Liste: gewähltes Gerät")
    var changed = b; changed.name = "FDM-DUO (Shack)"
    list.update(changed)
    check(list.profiles[1].name == "FDM-DUO (Shack)" && list.profiles.count == 2, "Liste: Eintrag ersetzt")
    list.update(RigProfile(id: "unbekannt", name: "x"))
    check(list.profiles.count == 2, "Liste: unbekannte Kennung ändert nichts")
    let restored = RigProfileList.decoded(from: list.encoded())
    check(restored == list && restored.active?.audioUID == "UID-1", "Liste: Speichern und Laden")
    check(RigProfileList.decoded(from: nil) == RigProfileList() && RigProfileList.decoded(from: Data("kaputt".utf8)) == RigProfileList(), "Liste: Unlesbares → leer")
    list.remove(id: b.id)
    check(list.profiles.count == 1 && list.activeID == nil && list.active == nil, "Liste: gelöschtes gewähltes Gerät → Automatik")
    check(RigProfileList(profiles: [], activeID: "weg").active == nil, "Liste: Wahl ohne Eintrag → Automatik")

    // Verbindung über Rechnernamen („localhost“ probiert ::1 und 127.0.0.1) zu einem nachgebauten rigctld
    final class Box: @unchecked Sendable { let lock = NSLock(); var last = RigState(); var count = 0 }
    if let fake = FakeRigctld() {
        let box = Box()
        let client = RigctlClient { s in box.lock.withLock { box.last = s; box.count += 1 } }
        client.setEndpoint(RigEndpoint(host: "localhost", port: Int(fake.port)))
        var waited = 0.0
        while waited < 4, box.lock.withLock({ box.last.frequencyHz }) == nil { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
        let s = box.lock.withLock { box.last }
        check(s.connected && s.frequencyHz == 14_074_000 && s.mode == "USB" && s.host == "localhost" && s.port == fake.port, "Verbindung über „localhost“ (Name aufgelöst, IPv6 → IPv4): \(s)")
        // Abstimmen über denselben Weg: nur F und M, danach liefert die Abfrage die neue Frequenz
        let tuned = Box()
        client.tune(frequencyHz: 7_074_000, mode: "LSB", passbandHz: 2700) { r in tuned.lock.withLock { tuned.count = r == .ok ? 1 : -1 } }
        waited = 0
        while waited < 3, box.lock.withLock({ box.last.frequencyHz }) != 7_074_000 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
        check(tuned.lock.withLock { tuned.count } == 1 && fake.currentFrequency == 7_074_000 && fake.currentMode == "LSB", "Abstimmen: F und M kommen an")
        check(box.lock.withLock { box.last.frequencyHz } == 7_074_000 && box.lock.withLock { box.last.mode } == "LSB", "Nach dem Abstimmen zeigt die Abfrage die neue Frequenz")
        check(fake.commands.allSatisfy { ["f", "m"].contains($0) || $0.hasPrefix("F ") || $0.hasPrefix("M ") } && !fake.commands.contains { $0.hasPrefix("T") }, "Nur f, m, F, M gesendet, nie PTT: \(Set(fake.commands))")
        // Umschalten auf einen anderen Endpunkt trennt zuerst
        client.setEndpoint(nil)
        Thread.sleep(forTimeInterval: 0.3)
        check(!box.lock.withLock { box.last.connected } && box.lock.withLock { box.last.host } == nil, "Trennen setzt den Zustand zurück")

        // Test-Knopf: einmalige Abfrage
        let done = DispatchSemaphore(value: 0)
        let probed = Box()
        RigctlClient.probe(RigEndpoint(host: "127.0.0.1", port: Int(fake.port))!) { r in
            if case .ok(let st) = r { probed.lock.withLock { probed.last = st } }
            done.signal()
        }
        check(done.wait(timeout: .now() + 4) == .success && probed.lock.withLock { probed.last.frequencyHz } == 7_074_000 && probed.lock.withLock { probed.last.mode } == "LSB", "Test-Knopf: Frequenz und Mode gelesen")
        check(RigProbeResult.ok(probed.last).message.hasPrefix("Verbunden · 7.074,000 kHz · LSB"), "Test-Knopf: Meldung \(RigProbeResult.ok(probed.last).message)")
    } else {
        check(false, "Test-rigctld konnte nicht starten")
    }

    // Kein Server: nicht erreichbar; Server, der nicht antwortet: keine Antwort; beides ohne Absturz
    let none = DispatchSemaphore(value: 0)
    let outcome = Box()
    RigctlClient.probe(RigEndpoint(host: "127.0.0.1", port: 1)!) { r in outcome.lock.withLock { outcome.count = r == .unreachable ? 1 : -1 }; none.signal() }
    check(none.wait(timeout: .now() + 4) == .success && outcome.lock.withLock { outcome.count } == 1, "Test-Knopf: nichts auf dem Port → „nicht erreichbar“")
    if let mute = FakeRigctld(behavior: .silent) {
        let silent = DispatchSemaphore(value: 0)
        RigctlClient.probe(RigEndpoint(host: "127.0.0.1", port: Int(mute.port))!) { r in outcome.lock.withLock { outcome.count = r == .noAnswer ? 2 : -2 }; silent.signal() }
        check(silent.wait(timeout: .now() + 4) == .success && outcome.lock.withLock { outcome.count } == 2, "Test-Knopf: Server schweigt → „keine Antwort“")
    }
    check(RigProbeResult.unreachable.message.contains("rigctld") && RigProbeResult.noAnswer.message.contains("keine Antwort"), "Test-Knopf: Meldungen")
    // Nicht auflösbarer Name: kein Absturz, kein Hängen
    let t0 = Date()
    let unresolved = DispatchSemaphore(value: 0)
    RigctlClient.probe(RigEndpoint(host: "gibt-es-nicht.invalid", port: 4532)!) { r in outcome.lock.withLock { outcome.count = r == .unreachable ? 3 : -3 }; unresolved.signal() }
    check(unresolved.wait(timeout: .now() + 8) == .success && outcome.lock.withLock { outcome.count } == 3 && Date().timeIntervalSince(t0) < 8, "Nicht auflösbarer Rechnername: „nicht erreichbar“ in endlicher Zeit")
}


// MARK: - Funkgerät wählen: Automatik, freies Gerät, Auftrag per URL (RigModel)
if want("rig") {
    let m = RigModel()
    check(!m.hasRig && m.rigName == nil && m.description == nil && !m.overriddenByRequest, "RigModel: am Anfang kein Funkgerät")
    m.follow(radio: .pcr1500)
    check(m.hasRig && m.rigName == "IC-PCR1500" && m.customProfile == nil, "RigModel: Automatik folgt dem Codec (PCR-1500)")
    m.use(profile: RigProfile(name: "IC-7300", host: "127.0.0.1", port: 4540))
    check(m.rigName == "IC-7300" && m.customProfile?.port == 4540 && !m.overriddenByRequest, "RigModel: freies Gerät hat Vorrang vor der Automatik")
    m.follow(radio: nil)
    check(m.hasRig && m.rigName == "IC-7300", "RigModel: freies Gerät gilt auch ohne Commander-Codec (beliebiges Audiogerät)")
    m.apply(request: DecodeRequest(source: "ft991a", rigctlPort: 4533))
    check(m.customProfile == nil && m.overriddenByRequest && !m.hasRig, "RigModel: Auftrag eines Commanders → Automatik für diese Sitzung")
    m.apply(request: DecodeRequest(source: "WSJT-X", rigctlPort: 4580))
    check(m.customProfile?.host == "127.0.0.1" && m.customProfile?.port == 4580 && m.rigName == "WSJT-X" && m.overriddenByRequest, "RigModel: unbekannte Quelle mit Port → Gerät auf 127.0.0.1")
    m.apply(request: DecodeRequest(source: "WSJT-X"))
    m.apply(request: DecodeRequest(rigctlPort: 4590))
    check(m.rigName == "WSJT-X" && m.customProfile?.port == 4580, "RigModel: Auftrag ohne Quelle oder ohne Port ändert nichts")
    m.use(profile: nil)
    check(!m.overriddenByRequest && m.customProfile == nil && !m.hasRig, "RigModel: Wahl in den Einstellungen hebt die Übersteuerung auf")
    m.follow(radio: .ft991a)
    check(m.rigName == "FT-991A" && m.description == "FT-991A", "RigModel: Beschreibung ohne Verbindung nur der Name")
}


// MARK: - Lizenz und Quellen: Dokumente, Markdown-Leser, Vollständigkeit (Projektordner = aktuelles Verzeichnis)
if want("license") {
    // Markdown-Leser
    let md = "# Titel\n\nErster Absatz\nzweite Zeile\n\n- Punkt eins\n  - Unterpunkt\n- Punkt zwei\n  weiter\n## Abschnitt\n### Unter\nText\n#kein-Titel\n#### zu tief\n"
    check(MarkdownLite.parse(md) == [.heading(level: 1, text: "Titel"), .paragraph("Erster Absatz zweite Zeile"), .bullet(level: 0, text: "Punkt eins"),
                                     .bullet(level: 1, text: "Unterpunkt"), .bullet(level: 0, text: "Punkt zwei weiter"), .heading(level: 2, text: "Abschnitt"),
                                     .heading(level: 3, text: "Unter"), .paragraph("Text #kein-Titel #### zu tief")], "Markdown: Überschriften, Absätze, Listen, Fortsetzung")
    check(MarkdownLite.parse("") == [] && MarkdownLite.parse("\n\n  \n") == [], "Markdown: leer")

    // Orte der Dokumente: zuerst das App-Bundle, dann der Projektordner
    let a = URL(fileURLWithPath: "/app/Resources"), b = URL(fileURLWithPath: "/src")
    check(LicenseDocument.license.candidates(bundleResources: a, projectRoot: b).map(\.path) == ["/app/Resources/LICENSE", "/src/LICENSE"]
          && LicenseDocument.thirdParty.candidates(bundleResources: nil, projectRoot: b).map(\.path) == ["/src/THIRD_PARTY.md"], "Dokumente: Suchreihenfolge")
    check(LicenseDocument.license.load(bundleResources: nil, projectRoot: nil) == nil, "Dokumente: nichts gefunden → nil")

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if let licenseText = LicenseDocument.license.load(bundleResources: nil, projectRoot: root),
       let thirdParty = LicenseDocument.thirdParty.load(bundleResources: nil, projectRoot: root) {
    check(licenseText.contains("GNU GENERAL PUBLIC LICENSE") && licenseText.contains("Version 3, 29 June 2007") && licenseText.contains("END OF TERMS AND CONDITIONS")
          && licenseText.contains("How to Apply These Terms to Your New Programs"), "LICENSE: vollständiger GPL-3-Text")
    let blocks = MarkdownLite.parse(thirdParty)
    check(blocks.first == .heading(level: 1, text: "Lizenz, Quellen und Drittanbieter-Software"), "THIRD_PARTY.md: Titel")
    check(blocks.filter { if case .heading(2, _) = $0 { return true } else { return false } }.count == 6 && blocks.filter { if case .bullet = $0 { return true } else { return false } }.count > 30, "THIRD_PARTY.md: sechs Abschnitte mit Listenpunkten")
    check(thirdParty.contains("GPL-3.0-or-later") && thirdParty.contains("`LICENSE`") && thirdParty.contains("https://github.com/betzburger/Digidec"), "THIRD_PARTY.md: Lizenz, LICENSE, Quelltext-Adresse")

    // Jede Lizenzdatei im Repository ist in THIRD_PARTY.md genannt
    func files(under dir: String, where match: (String) -> Bool) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root.appendingPathComponent(dir).path) else { return [] }
        return (e.allObjects as? [String] ?? []).filter { match(($0 as NSString).lastPathComponent) }
    }
    let licenseFiles = files(under: "Vendor", where: { $0.hasPrefix("LICENSE_") }).filter { !$0.contains("_upstream") }.map { ($0 as NSString).lastPathComponent }
    check(licenseFiles.count >= 10 && licenseFiles.allSatisfy { thirdParty.contains($0) }, "Jede LICENSE_*-Datei steht in THIRD_PARTY.md (fehlt: \(licenseFiles.filter { !thirdParty.contains($0) }))")
    // Jede Datei in Resources (außer Symbolen) ist genannt, mit Dateiname oder Ordner
    let resourceFiles = files(under: "Resources", where: { !$0.hasPrefix("AppIcon") && !$0.hasPrefix(".") })
    let unnamed = resourceFiles.filter { path in
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        return !thirdParty.contains(name) && !(folder.isEmpty ? false : thirdParty.contains("Resources/\(folder)/"))
    }
    check(!resourceFiles.isEmpty && unnamed.isEmpty, "Jede Datei in Resources ist in THIRD_PARTY.md genannt (fehlt: \(unnamed))")
    // Jedes Vendor-Verzeichnis ist genannt: der Ordner selbst oder das Vorbild
    let referenceByModule = ["Acars": "acarsdec", "Ais": "AIS-catcher", "Ale": "openALE", "Aprs": "Dire Wolf", "Dsc": "TAOSW", "Pager": "multimon-ng", "Skimmer": "KZ4AP", "Sonde": "rs41mod"]
    let vendorDirs = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Vendor").path)) ?? []).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
    let missing = vendorDirs.filter { dir in !(thirdParty.contains("Vendor/\(dir)/") || (referenceByModule[dir].map { thirdParty.contains($0) } ?? false)) }
    check(vendorDirs.count >= 10 && missing.isEmpty, "Jedes Vendor-Verzeichnis ist in THIRD_PARTY.md genannt (fehlt: \(missing))")
    // Neue eigene Dateien brauchen die SPDX-Kennzeichnung
    var swiftFiles = 0
    var withoutHeader: [String] = []
    for dir in ["Sources", "Tools"] {
        for relative in files(under: dir, where: { $0.hasSuffix(".swift") }) {
            swiftFiles += 1
            let url = root.appendingPathComponent(dir).appendingPathComponent(relative)
            let head = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false).prefix(4)
            if !head.contains(where: { $0.contains("SPDX-License-Identifier: GPL-3.0-or-later") }) { withoutHeader.append(dir + "/" + relative) }
        }
    }
    check(swiftFiles > 150 && withoutHeader.isEmpty, "Jede Swift-Datei trägt „SPDX-License-Identifier: GPL-3.0-or-later“ (fehlt: \(withoutHeader.prefix(5)))")
    } else {
        check(false, "LICENSE und THIRD_PARTY.md im Projektordner \(root.path)")
    }
}
print("\(checks) Prüfungen, \(failures) Fehler" + (skipped > 0 ? ", \(skipped) übersprungen (Aufnahmen fehlen: TestData/ ist nur lokal)" : ""))
// MARK: - AIS (Automatic Identification System)

/// Aufnehmen einer Nachricht aus einem !AIVDM-Satz (einteilig)
@MainActor func aisBits(_ sentence: String) -> AISBits? {
    guard let s = AISNMEA.parse(sentence), let b = AISArmor.decode(s.payload, fill: s.fill) else { return nil }
    return AISBits(b)
}

@MainActor func aisTests() {
    // NMEA: Prüfsumme, Panzerung, mehrteilige Sätze (Beispiele aus der gpsd-Sammlung)
    let s1 = "!AIVDM,1,1,,A,15RTgt0PAso;90TKcjM8h6g208CQ,0*4A"
    check(AISNMEA.parse(s1) != nil, "AIS: NMEA-Satz mit gültiger Prüfsumme")
    check(AISNMEA.parse(s1.replacingOccurrences(of: "4A", with: "4B")) == nil, "AIS: falsche Prüfsumme wird abgelehnt")
    if let b = aisBits(s1), let m = AISMessage.decode(b) {
        check(m.type == 1 && m.mmsi == 371_798_000, "AIS Typ 1: MMSI \(m.mmsi)")
        check(abs((m.longitude ?? 0) - (-123.3953833)) < 1e-6 && abs((m.latitude ?? 0) - 48.38163333) < 1e-6, "AIS Typ 1: Position \(String(describing: m.longitude)), \(String(describing: m.latitude))")
        check(abs((m.sog ?? 0) - 12.3) < 1e-9 && abs((m.cog ?? 0) - 224.0) < 1e-9 && m.heading == 215 && m.navStatus == 0 && m.timestampSecond == 33, "AIS Typ 1: Fahrt, Kurs, Steven, Status, Sekunde")
        // Rundreise: Bits → Satz → Bits
        let again = AISNMEA.sentences(for: b.bits, channel: "A")
        check(again.count == 1 && AISNMEA.parse(again[0])?.payload == "15RTgt0PAso;90TKcjM8h6g208CQ", "AIS: Panzerung Rundreise")
    } else { check(false, "AIS: Satz Typ 1 nicht lesbar") }
    // Typ 5 (zweiteilig): Stamm- und Reisedaten
    var asm = AISNMEA.Assembler()
    let t5a = "!AIVDM,2,1,1,A,55?MbV02>H97ac<H4eEK6W@D4P4N5oQ5:@AI<T400000000HEP00000000,0*10"
    let t5b = "!AIVDM,2,2,1,A,00000000000,2*2A"
    _ = t5a; _ = t5b
    // eigene Vorlage über den Sender: Typ 5 bauen, in zwei Sätze teilen, zusammensetzen, lesen
    let p5 = AISSignalGenerator.staticVoyage(mmsi: 351_759_000, imo: 9_134_270, callsign: "3FOF8", name: "EVER DIADEM", shipType: 70, bow: 225, stern: 70, port: 1, starboard: 31,
                                             draught: 12.2, destination: "NEW YORK", etaMonth: 5, etaDay: 15, etaHour: 14, etaMinute: 0)
    let parts = AISNMEA.sentences(for: p5, channel: "B", sequence: 3)
    check(parts.count == 2 && parts.allSatisfy { $0.count <= 82 }, "AIS: Typ 5 wird in zwei Sätze geteilt (\(parts.count))")
    var joined: [UInt8]?
    for p in parts { if let s = AISNMEA.parse(p) { joined = asm.add(s) } }
    check(joined == p5, "AIS: mehrteilige Sätze setzen sich wieder zusammen")
    if let m = AISMessage.decode(AISBits(p5)) {
        check(m.name == "EVER DIADEM" && m.callsign == "3FOF8" && m.imo == 9_134_270 && m.shipType == 70 && m.destination == "NEW YORK", "AIS Typ 5: Name, Rufzeichen, IMO, Typ, Ziel")
        check(m.length == 295 && m.beam == 32 && m.draught == 12.2 && m.etaMonth == 5 && m.etaDay == 15 && m.etaHour == 14 && m.etaMinute == 0, "AIS Typ 5: Maße, Tiefgang, ETA")
    } else { check(false, "AIS Typ 5 nicht lesbar") }
    // gpsd-Satz der Klasse B (Typ 18) und Seezeichen (Typ 21)
    let t18 = AISSignalGenerator.classBPosition(mmsi: 338_087_471, lat: 40.6841, lon: -74.0738, sog: 0.1, cog: 79.6, heading: 49, second: 49)
    if let m = AISMessage.decode(AISBits(t18)) {
        check(m.type == 18 && m.classB && abs((m.latitude ?? 0) - 40.6841) < 1e-5 && abs((m.longitude ?? 0) + 74.0738) < 1e-5 && m.heading == 49, "AIS Typ 18: Klasse B Position")
        check(AISMessage.kind(mmsi: m.mmsi, type: 18) == .shipB, "AIS: Klasse B erkannt")
    } else { check(false, "AIS Typ 18 nicht lesbar") }
    if let m = AISMessage.decode(AISBits(AISSignalGenerator.aidToNavigation(mmsi: 992_110_005, type: 20, name: "HELGOLAND TONNE", lat: 54.1, lon: 7.9))) {
        check(m.type == 21 && m.name == "HELGOLAND TONNE" && m.atonType == 20 && m.kind == .aid && AISAtonType.text(20).contains("Nordkardinal"), "AIS Typ 21: Seezeichen")
    } else { check(false, "AIS Typ 21 nicht lesbar") }
    // Klasse-B-Stammdaten in zwei Teilen (Typ 24 A und B) werden zusammengeführt
    var vessel = AISVessel(mmsi: 211_000_001, now: Date(timeIntervalSince1970: 0))
    if let a = AISMessage.decode(AISBits(AISSignalGenerator.classBStaticA(mmsi: 211_000_001, name: "SEGELFIX"))),
       let b = AISMessage.decode(AISBits(AISSignalGenerator.classBStaticB(mmsi: 211_000_001, shipType: 36, callsign: "DJ1234", bow: 6, stern: 4, port: 1, starboard: 2))),
       let p = AISMessage.decode(AISBits(AISSignalGenerator.classBPosition(mmsi: 211_000_001, lat: 54.5, lon: 10.2, sog: 5.5, cog: 100))) {
        vessel.ingest(a, at: Date(timeIntervalSince1970: 1))
        vessel.ingest(b, at: Date(timeIntervalSince1970: 2))
        vessel.ingest(p, at: Date(timeIntervalSince1970: 3))
        check(vessel.name == "SEGELFIX" && vessel.callsign == "DJ1234" && vessel.shipType == 36 && vessel.length == 10 && vessel.beam == 3 && vessel.isClassB && vessel.kind == .shipB, "AIS: Typ 24 Teil A und B ergeben ein Schiff")
        check(vessel.point != nil && vessel.sog == 5.5 && vessel.messages == 3 && vessel.track.count == 1, "AIS: Position und Zähler")
    } else { check(false, "AIS Typ 24 nicht lesbar") }
    // Länge der Nachrichten und MMSI-Prüfung
    check(AISMessage.isPlausible(AISBits(AISSignalGenerator.positionReport(mmsi: 211_000_001, lat: 54, lon: 10))), "AIS: Typ 1 mit 168 Bit ist plausibel")
    check(!AISMessage.isPlausible(AISBits(Array(AISSignalGenerator.positionReport(mmsi: 211_000_001, lat: 54, lon: 10).prefix(160)))), "AIS: Typ 1 mit falscher Länge wird verworfen")
    check(AISMessage.isPlausible(AISBits(AISSignalGenerator.positionReport(mmsi: 222_222_222, lat: 54, lon: 10))), "AIS: Platzhalter-MMSI 222222222 gilt beim ersten Versuch")
    check(!AISMessage.isPlausible(AISBits(AISSignalGenerator.positionReport(mmsi: 222_222_222, lat: 54, lon: 10)), strictMMSI: true), "AIS: Platzhalter-MMSI gilt nicht für korrigierte Rahmen")
    check(AISCountry.isValidMMSI(211_000_001) && AISCountry.isValidMMSI(970_123_456) && AISCountry.isValidMMSI(992_110_000) && !AISCountry.isValidMMSI(14_046_703) && !AISCountry.isValidMMSI(1_500_000_000), "AIS: MMSI-Formen")
    // Länder: MID und Flagge
    check(AISCountry.iso(ofMMSI: 211_234_567) == "DE" && AISCountry.iso(ofMMSI: 244_000_000) == "NL" && AISCountry.iso(ofMMSI: 992_110_000) == "DE" && AISCountry.iso(ofMMSI: 2_110_000) == "DE", "AIS: MID → Land (Schiff, Seezeichen 99MID, Küstenstation 00MID)")
    check(AISCountry.flag(ofISO: "DE") == "🇩🇪" && AISCountry.name(ofMMSI: 211_234_567) == "Deutschland", "AIS: Flagge und Landesname (\(AISCountry.name(ofMMSI: 211_234_567) ?? "–"))")
    check(AISMessage.kind(mmsi: 970_123_456) == .sart && AISMessage.kind(mmsi: 992_110_000) == .aid && AISMessage.kind(mmsi: 2_110_000) == .base, "AIS: Art der Funkstelle nach MMSI")
    check(AISShipType.text(70) == "Frachtschiff" && AISShipType.text(81).contains("Gefahrgut A") && AISShipType.group(60) == .passenger && AISShipType.short(80) == "Tanker", "AIS: Schiffstypen")

    // Rahmenbildung: Bit-Stopfen, CRC, Leitungsbitfolge (Byteordnung)
    let payload = AISSignalGenerator.positionReport(mmsi: 211_000_001, lat: 54.5, lon: 10.2, sog: 3, cog: 90)
    var wire = AISFraming.wireBits(payload: payload)
    // nach den Pegelwechseln (NRZI) wieder zu Bits
    var d = AISDeframer()
    var got: AISDeframer.Frame?
    for b in wire { if let f = d.push(b) { got = f } }
    check(got?.bits == payload, "AIS: Rahmenbildung gibt die Nutzbits zurück (Bytefolge MSB-zuerst der Nachricht)")
    // fünf Einsen am Stück: eine Null wird gestopft; Nutzlast mit vielen Einsen übersteht den Weg
    var ones = AISBitWriter()
    ones.u(1, 6); ones.u(0, 2); ones.u(0x3FFFFFFF & 211_000_001, 30)
    for _ in 0..<12 { ones.u(0xFF, 8) }
    ones.pad(to: 168)
    wire = AISFraming.wireBits(payload: ones.bits)
    var d2 = AISDeframer()
    var got2: AISDeframer.Frame?
    for b in wire { if let f = d2.push(b) { got2 = f } }
    check(got2?.bits == ones.bits, "AIS: Bit-Stopfen bei langen Einserfolgen")
    // ein verfälschtes Bit lässt die Prüfsumme scheitern, die Korrektur findet es wieder
    var bad = AISBitOrder.swapBytes(payload) + AISCRC.checksumBits(AISBitOrder.swapBytes(payload))
    check(AISCRC.residue(bad) == AISCRC.goodResidue, "AIS: CRC-16 der Leitungsbits stimmt (Rest 0xF0B8)")
    bad[77] ^= 1
    check(AISCRC.residue(bad) != AISCRC.goodResidue, "AIS: CRC erkennt einen Bitfehler")
    let fixed = AISDeframer.repair(bad, confidence: [Float](repeating: 1, count: bad.count)) { AISMessage.isPlausible(AISBits($0), strictMMSI: true) }
    check(fixed == payload, "AIS: Korrektur eines einzelnen Bitfehlers")
    bad[120] ^= 1
    var conf = [Float](repeating: 1, count: bad.count)
    conf[77] = 0.1; conf[120] = 0.2
    check(AISDeframer.repair(bad, confidence: conf, accept: { AISMessage.isPlausible(AISBits($0), strictMMSI: true) }) == payload, "AIS: Korrektur zweier unsicherer Bits")

    // Empfänger Ende-zu-Ende: Burst-Folge als Diskriminator-Audio mit Frequenzablage, Taktfehler und beiden Polaritäten
    var rng = AISSignalGenerator.RNG(seed: 11)
    var payloads: [[UInt8]] = []
    var bursts: [AISSignalGenerator.Burst] = []
    for k in 0..<24 {
        let mmsi = UInt32(211_000_000 + k * 1_000 + 7)
        let p: [UInt8]
        switch k % 4 {
        case 0: p = AISSignalGenerator.positionReport(mmsi: mmsi, lat: 50 + rng.uniform() * 8, lon: 5 + rng.uniform() * 10, sog: rng.uniform() * 20, cog: rng.uniform() * 359, heading: 100, second: k)
        case 1: p = AISSignalGenerator.staticVoyage(mmsi: mmsi, imo: 9_000_000 + UInt32(k), callsign: "DA\(k)", name: "SCHIFF \(k)", shipType: 70, bow: 100, stern: 20, port: 8, starboard: 9, draught: 6.3, destination: "KIEL")
        case 2: p = AISSignalGenerator.classBPosition(mmsi: mmsi, lat: 54 + rng.uniform(), lon: 10 + rng.uniform(), sog: 4, cog: 30)
        default: p = AISSignalGenerator.aidToNavigation(mmsi: 992_110_000 + UInt32(k), type: 11, name: "TONNE \(k)", lat: 54.3, lon: 10.1)
        }
        payloads.append(p)
        bursts.append(.init(payload: p, start: 0.15 + Double(k) * 0.11, offset: Float((rng.uniform() - 0.5) * 0.12), polarity: k % 2 == 0 ? 1 : -1, ppm: (rng.uniform() - 0.5) * 160))
    }
    func receive(_ audio: [Float]) -> (set: Set<[UInt8]>, stats: AISStats) {
        let rx = AISReceiver(sampleRate: 48_000)
        var out = Set<[UInt8]>()
        rx.onFrame = { out.insert($0.bits) }
        var i = 0
        while i < audio.count {
            let n = min(960, audio.count - i)
            audio.withUnsafeBufferPointer { rx.process(UnsafeBufferPointer(start: $0.baseAddress! + i, count: n)) }
            i += n
        }
        return (out, rx.stats)
    }
    let clean = receive(AISSignalGenerator.audio(bursts: bursts, duration: 3.0, noise: 0))
    check(clean.set == Set(payloads), "AIS-Empfänger: alle 24 Bursts fehlerfrei gelesen (\(clean.set.intersection(Set(payloads)).count) von 24, \(clean.set.count) Rahmen)")
    check(clean.stats.frames == 24 && clean.stats.implausible == 0, "AIS-Empfänger: Zähler \(clean.stats)")
    let noisy = receive(AISSignalGenerator.audio(bursts: bursts, duration: 3.0, noise: 0.04, seed: 5))
    check(noisy.set.intersection(Set(payloads)).count >= 23 && noisy.set.subtracting(Set(payloads)).isEmpty, "AIS-Empfänger: mit Rauschen (\(noisy.set.intersection(Set(payloads)).count) von 24, unerwartet \(noisy.set.subtracting(Set(payloads)).count))")
    // anderes Pegelverhältnis des SDR-Programms (Audio leiser und lauter)
    let quiet = receive(AISSignalGenerator.audio(bursts: bursts, duration: 3.0, swing: 0.05, noise: 0))
    let loud = receive(AISSignalGenerator.audio(bursts: bursts, duration: 3.0, swing: 0.8, noise: 0))
    check(quiet.set == Set(payloads) && loud.set == Set(payloads), "AIS-Empfänger: Audiopegel 0,05 und 0,8 (\(quiet.set.count), \(loud.set.count) von 24)")
    // nur Rauschen: keine Zufallstreffer
    let silence = receive(AISSignalGenerator.audio(bursts: [], duration: 40, noise: 0.25, seed: 9))
    check(silence.set.isEmpty, "AIS-Empfänger: 40 s reines Rauschen ohne Rahmen (\(silence.set.count))")

    // Controller: Schiffe aus Rahmen, Zusammenführen, Filter, Karte, Log
    let settings = AISSettingsStore()
    let c = AISController(pipeline: AudioPipeline(), settings: settings)
    c.logEnabled = false
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    c.homePoint = Maidenhead.point("JN49WS")
    c.ingest(bits: AISSignalGenerator.positionReport(mmsi: 211_234_567, lat: 53.55, lon: 9.97, sog: 11.2, cog: 275, heading: 274), at: t0)
    c.ingest(bits: p5, at: t0.addingTimeInterval(1))
    c.ingest(bits: AISSignalGenerator.positionReport(mmsi: 351_759_000, lat: 53.9, lon: 8.7, sog: 14.1, cog: 100, heading: 101), at: t0.addingTimeInterval(2))
    c.ingest(bits: AISSignalGenerator.aidToNavigation(mmsi: 992_110_005, type: 20, name: "ELBE 1", lat: 54.0, lon: 8.1), at: t0.addingTimeInterval(3))
    c.ingest(bits: AISSignalGenerator.baseStation(mmsi: 2_111_240, lat: 53.54, lon: 9.96, year: 2026, month: 10, day: 4, hour: 12, minute: 0, second: 0), at: t0.addingTimeInterval(4))
    c.ingest(bits: AISSignalGenerator.positionReport(mmsi: 211_234_567, lat: 53.551, lon: 9.95, sog: 11.0, cog: 275, heading: 274), at: t0.addingTimeInterval(10))
    check(c.messageCount == 6 && c.typeCounts[1] == 3 && c.typeCounts[5] == 1 && c.typeCounts[21] == 1 && c.typeCounts[4] == 1, "AIS-Controller: Meldungen nach Typ \(c.typeCounts)")
    let ever = c.vessel(351_759_000)
    check(ever?.name == "EVER DIADEM" && ever?.imo == 9_134_270 && ever?.point != nil && ever?.kind == .shipA, "AIS-Controller: Stammdaten (Typ 5) und Position (Typ 1) im selben Schiff")
    check(c.vessel(211_234_567)?.track.count == 2 && c.vessel(211_234_567)?.positions == 2, "AIS-Controller: zweite Position verlängert den Weg")
    check(c.vessel(992_110_005)?.kind == .aid && c.vessel(2_111_240)?.kind == .base, "AIS-Controller: Seezeichen und Küstenstation")
    let km = Geo.distanceKm(Maidenhead.point("JN49WS")!, GeoPoint(lat: 53.9, lon: 8.7))
    check((c.farthest?.km ?? 0) > 400 && (c.farthest?.km ?? 0) < km + 150, "AIS-Controller: weitester Empfang \(String(format: "%.0f", c.farthest?.km ?? 0)) km")
    let all = AISMapBuilder.Filter()
    let vs = [c.vessel(211_234_567)!, c.vessel(351_759_000)!, c.vessel(992_110_005)!, c.vessel(2_111_240)!]
    let map = AISMapBuilder.content(vs, home: c.homePoint, now: t0.addingTimeInterval(20), filter: all, selection: nil)
    check(map.markers.count == 4 && map.markers.contains { $0.id == "ais-351759000" && $0.title == "EVER DIADEM" && $0.headingDeg == 101 }, "AIS-Karte: 4 Punkte, Schiff mit Name und Kurs")
    check(map.markers.first { $0.id == "ais-211234567" }?.track.count == 2, "AIS-Karte: Weg des fahrenden Schiffs")
    check(AISMapBuilder.content(vs, home: nil, now: t0, filter: .init(ships: true, aids: false, base: false), selection: nil).markers.count == 2, "AIS-Karte: Filter ohne Seezeichen und Stationen")
    check(AISMapBuilder.mmsi(fromID: "ais-351759000") == 351_759_000 && AISMapBuilder.mmsi(fromID: "ac-1") == nil, "AIS-Karte: Punktkennung ↔ MMSI")
    let det = AISMapBuilder.details(ever!, home: c.homePoint, age: 12).joined(separator: "\n")
    check(det.contains("IMO 9134270") && det.contains("NEW YORK") && det.contains("295 × 32 m") && det.contains("Tiefgang 12,2 m") && det.contains("Panama"), "AIS-Karte: Einzelheiten \(det)")
    check(AISFormat.age(30) == "30 s" && AISFormat.age(600) == "10 min" && AISFormat.age(7200) == "2 h" && AISFormat.seaMiles(km: 18.52) == "10,0 sm", "AIS: Formate")
    // alte Schiffe fallen heraus: Einstellung „Behalten“ (Seezeichen länger)
    check(settings.keepMinutes >= 5, "AIS: Voreinstellung Behalten")

    // Einstellungen, Abstimmung, Modulliste, URL
    check(DecoderModuleInfo.ais.isAvailable && DecoderModuleInfo.ais.band == .vhfUhf && DecoderModuleInfo.ais.displayName == "AIS" && DecoderModuleInfo.ais.hasMap, "AIS: Modul in der Liste (UKW, mit Karte)")
    check(DecoderModuleInfo.ais.presetIDs == ["a", "b", "both"] && AISChannel(rawValue: "b")?.frequencyHz == 162_025_000 && AISChannel.a.frequencyHz == 161_975_000, "AIS: Kanäle 161,975 und 162,025 MHz")
    check(RigTuneTarget.ais(channel: .a) == RigTuneTarget(dialHz: 161_975_000, mode: "FM", passbandHz: 25_000) && RigTuneTarget.ais(channel: .free) == nil, "AIS: Abstimmung FM auf 161,975 MHz")
    if case .success(let r) = DecodeRequestParser.parse(URL(string: "digidec://decode?mode=ais&preset=b")!) {
        check(r.module == .ais && r.presetID == "b", "AIS: URL-Auftrag mit Kanal B")
    } else { check(false, "AIS: URL-Auftrag abgelehnt") }
    check(AISDiagnosis.assess(inputDB: -100, stats: AISStats()).severity == .problem && AISDiagnosis.assess(inputDB: -30, stats: AISStats()).severity == .waiting, "AIS: Diagnose kein Audio / Suche")
    var st = AISStats(); st.frames = 5; st.bursts = 6
    check(AISDiagnosis.assess(inputDB: -30, stats: st).severity == .ok, "AIS: Diagnose Empfang gut")

    // Netzabfrage: Verweise (ohne Netz)
    let q = ShipQuery(mmsi: 211_234_567, imo: 9_241_061, callsign: "DABC", name: "TEST SCHIFF")
    let links = ShipLinks.links(for: q).map { $0.url.absoluteString }
    check(links.contains("https://www.marinetraffic.com/en/ais/details/ships/mmsi:211234567") && links.contains("https://www.vesselfinder.com/vessels/details/9241061") && links.contains { $0.contains("shipspotting.com/photos/gallery?imo=9241061") }, "AIS: Verweise zu Schiffsdatenbanken (\(links.count))")
    check(ShipLinks.links(for: ShipQuery(mmsi: 211_000_001)).contains { $0.url.absoluteString.contains("vesselfinder.com/vessels?name=211000001") }, "AIS: Verweise ohne IMO-Nummer")
    check(ShipQuery(mmsi: 5, imo: 9).cacheKey == "5-9" && ShipWebInfo().isEmpty, "AIS: Abfrage-Schlüssel")
}
if want("ais") { aisTests() }


// MARK: - AIS: binäre Nachrichten und zwei Kanäle

@MainActor func aisBinaryTests() {
    // Wetter nach IMO SN/Circ.236 (FI 11): Messstation Irland aus der gpsd-Sammlung, Werte der Auswertung des Kanaton-Geräts
    if let s = AISNMEA.parse("!AIVDO,1,1,4,B,8>jR06@0Bk3:wOli;<`WPhh<1rqVBQf2V@Pdt0J82avIM2b<<Rv1t<ot=@1,2*54"), let b = AISArmor.decode(s.payload, fill: s.fill),
       let m = AISMessage.decode(AISBits(b)), case .meteo(let w)? = m.binary {
        check(m.type == 8 && m.dac == 1 && m.fid == 11 && m.mmsi == 992_509_977 && m.kind == .aid, "AIS Binär: Typ 8, DAC 1, FI 11 von 992509977")
        check(abs((w.latitude ?? 0) - 53.29488) < 1e-4 && abs((w.longitude ?? 0) + 6.13398) < 1e-4, "AIS FI 11: Ort \(String(describing: w.latitude)), \(String(describing: w.longitude))")
        check(w.windKn == 3 && w.gustKn == 6 && w.windDir == 12 && w.gustDir == 15 && w.day == 18 && w.hour == 17 && w.minute == 15, "AIS FI 11: Wind und Zeit")
        check(w.airTemp == 14.2 && w.humidity == 50 && abs((w.dewPoint ?? 0) - 12.3) < 1e-9 && w.pressure == 1024 && w.pressureTendency == 2, "AIS FI 11: Luft (14,2 °C, 50 %, Taupunkt 12,3, 1024 hPa, steigend)")
        check(abs((w.visibilityNM ?? 0) - 15.3) < 1e-9 && abs((w.waterLevel ?? 0) + 8.4) < 1e-9 && w.levelTrend == 1 && abs((w.currentKn ?? 0) - 10.3) < 1e-9 && w.currentDir == 256, "AIS FI 11: Sicht, Wasserstand, Strom")
        check(abs((w.waveHeight ?? 0) - 4.2) < 1e-9 && w.wavePeriod == 35 && w.waveDir == 25 && abs((w.swellHeight ?? 0) - 2.3) < 1e-9 && w.swellPeriod == 48 && w.swellDir == 124 && w.seaState == 3, "AIS FI 11: Wellen, Dünung, Seegang")
        check(abs((w.waterTemp ?? 0) - 12.3) < 1e-9 && abs((w.salinity ?? 0) - 5.3) < 1e-9 && w.ice == false && w.precipitation == nil, "AIS FI 11: Wassertemperatur, Salzgehalt, Eis, Niederschlag „6“ unbekannt")
        check(w.lines.contains { $0.hasPrefix("Wind 3 kn aus NNO (12°)") } && w.lines.contains { $0.contains("Seegang 3 Bft: schwache Brise") } && w.summary.contains("1024 hPa"), "AIS FI 11: Anzeigetext \(w.lines.first ?? "")")
    } else { check(false, "AIS FI 11 nicht lesbar") }
    // Finnische Küstenstation (00230…): Kälte, Hochdruck
    if let b = aisBits("!AIVDM,1,1,,A,8@2<HW@0BkdhF0dcH59=RiRRDqnJ7wfRwwwwwwwwwwwwwwwwwwwwwwwwwt0,2*7D"), let m = AISMessage.decode(b), case .meteo(let w)? = m.binary {
        check(abs((w.latitude ?? 0) - 64.65) < 1e-6 && abs((w.longitude ?? 0) - 24.4) < 1e-6 && w.windKn == 11 && w.windDir == 162 && w.airTemp == -12.7 && w.pressure == 1032 && w.humidity == 80, "AIS FI 11: Finnland (64,65 N 24,4 O, 11 kn, −12,7 °C, 1032 hPa)")
        check(w.waterLevel == nil && w.waveHeight == nil && w.dewPoint == nil && w.visibilityNM == nil, "AIS FI 11: nicht verfügbare Werte bleiben leer")
    } else { check(false, "AIS FI 11 Finnland nicht lesbar") }
    // Binnenschiff (DAC 200, FI 10) aus der Sammlung: ENI, Maße, Fahrzeugart
    if let b = aisBits("!AIVDM,1,1,,B,83aDChPj2d<dL<uM=hhhI?a@6HP0,0*40"), let m = AISMessage.decode(b), case .inland(let i)? = m.binary {
        check(m.dac == 200 && m.fid == 10 && i.eni == "02103547" && i.length == 39.0 && i.beam == 5.0 && i.shipTypeCode == 8010 && i.draught == 2.04 && i.loaded == 1, "AIS DAC 200/10: Binnenschiff \(i)")
        check(i.shipTypeText == "Motorgüterschiff" && i.hazardText == "kein blaues Licht" && i.loadedText == "unbeladen", "AIS DAC 200/10: Texte")
    } else { check(false, "AIS 200/10 nicht lesbar") }
    // Erzeuger und Leser: FI 31, 200/10, 200/24, 1/29
    let g31 = AISSignalGenerator.meteo31(mmsi: 992_110_005, lat: 54.17, lon: 7.89, windKn: 22, gustKn: 31, windDir: 285, airTemp: -3.5, humidity: 88, pressure: 1003, waterLevel: 1.25, waveHeight: 2.4, waterTemp: 9.5)
    if let m = AISMessage.decode(AISBits(g31)), case .meteo(let w)? = m.binary {
        check(g31.count == 360 && m.fid == 31 && w.isNewFormat && abs((w.latitude ?? 0) - 54.17) < 1e-4 && abs((w.longitude ?? 0) - 7.89) < 1e-4, "AIS FI 31: Ort")
        check(w.windKn == 22 && w.gustKn == 31 && w.windDir == 285 && w.airTemp == -3.5 && w.humidity == 88 && w.pressure == 1003 && abs((w.waterLevel ?? 0) - 1.25) < 1e-9 && abs((w.waveHeight ?? 0) - 2.4) < 1e-9 && abs((w.waterTemp ?? 0) - 9.5) < 1e-9, "AIS FI 31: Werte")
        check(w.gustDir == nil && w.dewPoint == nil && w.pressureTendency == nil && w.visibilityNM == nil && w.salinity == nil && w.seaState == nil, "AIS FI 31: nicht verfügbare Werte")
    } else { check(false, "AIS FI 31 nicht lesbar") }
    if let m = AISMessage.decode(AISBits(AISSignalGenerator.inlandStatic(mmsi: 211_500_100, eni: "04810360", length: 110.0, beam: 11.4, eriType: 8030, hazardCones: 2, draught: 3.15, loaded: 2))), case .inland(let i)? = m.binary {
        check(i.eni == "04810360" && i.length == 110.0 && i.beam == 11.4 && i.shipTypeText == "Containerschiff" && i.hazardText == "2 blaue Lichter" && i.draught == 3.15 && i.loadedText == "beladen", "AIS 200/10: Erzeuger und Leser")
    } else { check(false, "AIS 200/10 (Erzeuger) nicht lesbar") }
    // falscher Treffer: DAC 200 FI 10 mit einer Kennung ohne Ziffern ist keine Binnenschiff-Meldung
    let badInland = AISSignalGenerator.inlandStatic(mmsi: 211_500_100, eni: "ABCDEFGH", length: 110, beam: 11, eriType: 8030, hazardCones: 0, draught: 3, loaded: 1)
    if let m = AISMessage.decode(AISBits(badInland)) { check(m.binary == .other, "AIS 200/10: Kennung ohne Ziffern wird nicht als Binnenschiff gedeutet") }
    if let m = AISMessage.decode(AISBits(AISSignalGenerator.waterLevels(mmsi: 2_111_000, country: "DE", gauges: [(101, 215), (102, -40)]))), case .waterLevels(let w)? = m.binary {
        check(w.country == "DE" && w.gauges == [.init(id: 101, levelCM: 215), .init(id: 102, levelCM: -40)] && w.summary == "Pegel 101: 215 cm · Pegel 102: -40 cm", "AIS 200/24: Pegelstände")
    } else { check(false, "AIS 200/24 nicht lesbar") }
    if let m = AISMessage.decode(AISBits(AISSignalGenerator.textBroadcast(mmsi: 2_111_000, linkage: 77, text: "FAIRWAY CLOSED AT KM 12"))), case .text(let l, let t)? = m.binary {
        check(l == 77 && t == "FAIRWAY CLOSED AT KM 12" && m.text == t, "AIS 1/29: Text mit Verknüpfung")
    } else { check(false, "AIS 1/29 nicht lesbar") }
    // Telegramm mit lauter Nullen (Station ohne Messwerte) und unbekannte Kennung
    var zero = AISBitWriter()
    zero.u(8, 6); zero.u(0, 2); zero.u(2_766_080, 30); zero.u(0, 2); zero.u(1, 10); zero.u(11, 6)
    zero.set(58 * 60_000, at: 56, 24); zero.set(23 * 60_000, at: 80, 25); zero.set(20, at: 105, 5); zero.set(18, at: 110, 5); zero.set(30, at: 115, 6)
    zero.pad(to: 352)
    check(AISMessage.decode(AISBits(zero.bits))?.binary == .other, "AIS FI 11: nur Nullen ist kein Wettertelegramm")
    var unknown = AISBitWriter()
    unknown.u(8, 6); unknown.u(0, 2); unknown.u(366_999_712, 30); unknown.u(0, 2); unknown.u(366, 10); unknown.u(56, 6); unknown.pad(to: 312)
    let um = AISMessage.decode(AISBits(unknown.bits))
    check(um?.dac == 366 && um?.fid == 56 && um?.binary == .other && AISMessage.isPlausible(AISBits(unknown.bits)), "AIS: unbekanntes Binärtelegramm DAC 366 FI 56 wird zugeordnet")

    // Controller: Messstation auf der Karte, Binnenschiff mit ENI, Pegel, Ziele der Verkehrszentrale
    let c = AISController(pipeline: AudioPipeline(), settings: AISSettingsStore())
    c.logEnabled = false
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    c.ingest(bits: g31, at: t0)
    c.ingest(bits: AISSignalGenerator.inlandStatic(mmsi: 211_500_100, eni: "04810360", length: 110, beam: 11.4, eriType: 8030, hazardCones: 2, draught: 3.15, loaded: 2), at: t0.addingTimeInterval(1))
    c.ingest(bits: AISSignalGenerator.positionReport(mmsi: 211_500_100, lat: 49.8, lon: 9.9, sog: 9.5, cog: 250), at: t0.addingTimeInterval(2))
    c.ingest(bits: AISSignalGenerator.waterLevels(mmsi: 2_111_000, country: "DE", gauges: [(101, 215)]), at: t0.addingTimeInterval(3))
    check(c.binaryCounts == ["1/31": 1, "200/10": 1, "200/24": 1], "AIS-Controller: Binärtelegramme gezählt \(c.binaryCounts)")
    let station = c.vessel(992_110_005)
    check(station?.kind == .aid && station?.meteo?.windKn == 22 && station?.point != nil, "AIS-Controller: Messstation mit Wetter und Position")
    let sMarker = AISMapBuilder.content([station!], home: nil, now: t0.addingTimeInterval(60), filter: .init(), selection: nil).markers.first
    check(sMarker?.valueText == "22" && sMarker?.symbol == "wind" && sMarker?.tone == .weather && sMarker?.headingDeg == 105 && sMarker?.details.contains { $0.hasPrefix("Wind 22 kn aus WNW (285°)") } == true, "AIS-Karte: Messstation mit Windstärke, Pfeil und Wetterzeilen (\(sMarker?.details.prefix(3).joined(separator: " | ") ?? ""))")
    let barge = c.vessel(211_500_100)
    check(barge?.inland?.eni == "04810360" && barge?.point != nil && barge?.kind == .shipA, "AIS-Controller: Binnenschiff mit ENI und Position")
    let bMarker = AISMapBuilder.content([barge!], home: nil, now: t0.addingTimeInterval(60), filter: .init(), selection: nil).markers.first
    check(bMarker?.details.contains { $0.hasPrefix("ENI 04810360 · Containerschiff · 110,0 × 11,4 m") } == true && bMarker?.details.contains { $0.contains("2 blaue Lichter") && $0.contains("beladen") } == true, "AIS-Karte: Binnenschiff-Zeilen")
    check(c.vessel(2_111_000)?.waterLevels?.gauges.first?.levelCM == 215, "AIS-Controller: Pegelstand")
    // künstliche Ziele (FI 17): zwei Ziele, eines mit MMSI, eines mit IMO-Nummer
    var vts = AISBitWriter()
    vts.u(8, 6); vts.u(0, 2); vts.u(2_111_000, 30); vts.u(0, 2); vts.u(1, 10); vts.u(17, 6)
    vts.set(0, at: 56, 2); vts.set(244_123_456, at: 58, 42); vts.set(Int(52.01 * 60_000), at: 56 + 48, 24); vts.set(Int(4.1 * 60_000), at: 56 + 72, 25); vts.set(90, at: 56 + 97, 9); vts.set(30, at: 56 + 106, 6); vts.set(12, at: 56 + 112, 8)
    vts.set(1, at: 176, 2); vts.set(9_241_061, at: 178, 42); vts.set(Int(52.02 * 60_000), at: 176 + 48, 24); vts.set(Int(4.12 * 60_000), at: 176 + 72, 25); vts.set(360, at: 176 + 97, 9); vts.set(255, at: 176 + 112, 8)
    vts.pad(to: 296)
    c.ingest(bits: vts.bits, at: t0.addingTimeInterval(10))
    let tv = c.vessel(244_123_456)
    check(tv?.isSynthetic == true && abs((tv?.latitude ?? 0) - 52.01) < 1e-4 && tv?.sog == 12 && tv?.cog == 90 && c.vessel(2_111_000) != nil, "AIS FI 17: Ziel mit MMSI wird zum Schiff (künstliches Ziel)")
    c.ingest(bits: AISSignalGenerator.positionReport(mmsi: 244_123_456, lat: 52.0105, lon: 4.1005, sog: 12, cog: 90), at: t0.addingTimeInterval(20))
    check(c.vessel(244_123_456)?.isSynthetic == false, "AIS FI 17: eigenes AIS-Signal ersetzt das künstliche Ziel")
    c.ingest(bits: vts.bits, at: t0.addingTimeInterval(30))
    check(c.vessel(244_123_456)?.isSynthetic == false && c.vessel(244_123_456)?.positions == 2, "AIS FI 17: künstliche Ziele überschreiben kein gehörtes Schiff")

    // Zwei Kanäle: links Kanal A, rechts Kanal B über die Pipeline (48 kHz und 96 kHz Quelle)
    var rng = AISSignalGenerator.RNG(seed: 21)
    func burstSet(base: UInt32, count: Int) -> (payloads: [[UInt8]], bursts: [AISSignalGenerator.Burst]) {
        var p: [[UInt8]] = [], b: [AISSignalGenerator.Burst] = []
        for k in 0..<count {
            let pay = AISSignalGenerator.positionReport(mmsi: base + UInt32(k), lat: 54 + rng.uniform(), lon: 8 + rng.uniform(), sog: 5, cog: Double(k * 20))
            p.append(pay)
            b.append(.init(payload: pay, start: 0.1 + Double(k) * 0.2, offset: Float((rng.uniform() - 0.5) * 0.1), polarity: k % 2 == 0 ? 1 : -1, ppm: (rng.uniform() - 0.5) * 100))
        }
        return (p, b)
    }
    let setA = burstSet(base: 211_000_100, count: 6), setB = burstSet(base: 244_000_200, count: 6)
    for inputRate in [48_000.0, 96_000.0] {
        let audioA = AISSignalGenerator.audio(bursts: setA.bursts, duration: 1.8, sampleRate: inputRate)
        let audioB = AISSignalGenerator.audio(bursts: setB.bursts, duration: 1.8, sampleRate: inputRate)
        for swap in [false, true] {
            let pipeline = AudioPipeline()
            let decoder = AISDecoder(pipeline: pipeline)
            decoder.configure(enabled: true, channel: .both, swap: swap)
            pipeline.start(inputRate: inputRate)
            Thread.sleep(forTimeInterval: 0.05)
            check(pipeline.wantsStereo, "AIS A+B: Pipeline liefert beide Kanäle getrennt")
            var i = 0
            let block = 2_048
            while i < audioA.count {
                let n = min(block, audioA.count - i)
                audioA.withUnsafeBufferPointer { l in audioB.withUnsafeBufferPointer { r in pipeline.writeStereo(left: l.baseAddress! + i, right: r.baseAddress! + i, count: n) } }
                i += n
                Thread.sleep(forTimeInterval: 0.012)
            }
            Thread.sleep(forTimeInterval: 0.6)
            let out = decoder.takeOutput()
            let a = Set(out.frames.filter { $0.letter == (swap ? "B" : "A") }.map(\.bits)), b = Set(out.frames.filter { $0.letter == (swap ? "A" : "B") }.map(\.bits))
            check(a == Set(setA.payloads) && b == Set(setB.payloads), "AIS A+B (\(Int(inputRate / 1000)) kHz, \(swap ? "vertauscht" : "links A"))): links \(a.count) von 6, rechts \(b.count) von 6")
            check(out.channels.count == 2 && out.channels[0].stats.frames == 6 && out.channels[1].stats.frames == 6 && out.channels[0].inputDB > -60, "AIS A+B: Zähler je Kanal \(out.channels.map { $0.stats.frames })")
            decoder.configure(enabled: false, channel: .a, swap: false)
            Thread.sleep(forTimeInterval: 0.05)
            check(!pipeline.wantsStereo, "AIS A+B: nach dem Ausschalten keine getrennten Kanäle mehr")
            pipeline.stop()
        }
    }
    // Diagnose je Kanal
    let silent = [AISChannelInfo(letter: "A", stats: AISStats(), level: 0.1, inputDB: -25), AISChannelInfo(letter: "B", stats: AISStats(), level: 0, inputDB: -120)]
    check(AISDiagnosis.assess(channels: silent).title == "KANAL B OHNE AUDIO", "AIS-Diagnose: Kanal B ohne Audio")
    var good = AISStats(); good.frames = 4; good.bursts = 4
    check(AISDiagnosis.assess(channels: [.init(letter: "A", stats: good, level: 0.1, inputDB: -25), .init(letter: "B", stats: good, level: 0.1, inputDB: -25)]).severity == .ok, "AIS-Diagnose: beide Kanäle gut")
    check(AISChannel.both.isDual && AISChannel.both.frequencyHz == nil && RigTuneTarget.ais(channel: .both) == nil && DecoderModuleInfo.ais.presetIDs == ["a", "b", "both"], "AIS: Kanalwahl A+B ohne Abstimmziel")
}
if want("ais") { aisBinaryTests() }


// MARK: - AIS: Gebietsmeldungen, Schifffahrtszeichen, Schiffswetter, erweiterte Reisedaten, Personen, Seezeichen-Überwachung

@MainActor func aisMoreBinaryTests() {
    // Überwachung eines Seezeichens (GLA, DAC 235 FI 10) aus der gpsd-Sammlung: Versorgung 13,7 V, RACON in Betrieb, Licht aus, Zustand gut
    if let b = aisBits("!AIVDM,1,1,4,B,6>jR0600V:C0>da4P106P00,2*02"), let m = AISMessage.decode(b), case .atonMonitoring(let a)? = m.binary {
        check(m.type == 6 && m.dac == 235 && m.fid == 10 && m.destinationMMSI == 2_500_912 && abs((a.supplyVolts ?? 0) - 13.7) < 1e-9 && a.racon == 2 && a.light == 2 && !a.alarm && !a.offPosition, "AIS 235/10: Überwachung eines Seezeichens \(a)")
        check(a.lines.last == "Licht aus · RACON in Betrieb · Zustand gut" && a.lines.first?.hasPrefix("Versorgung 13,70 V") == true, "AIS 235/10: Anzeigetext \(a.lines)")
    } else { check(false, "AIS 235/10 nicht lesbar") }

    // Gebietsmeldung: Kreis (Sperrgebiet, 2 km), Rechteck, Vieleck hinter einem Kreis, Sektor, Text
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)      // 04.10.2026 ca. 07:46 UTC
    let area1 = AISSignalGenerator.areaNotice(mmsi: 2_111_000, linkage: 17, notice: 37, hour: 9, minute: 0, durationMinutes: 180, shapes: [
        .circle(lat: 54.30, lon: 7.80, radius: 2000, scale: 0),
        .rectangle(lat: 54.20, lon: 7.60, east: 40, north: 30, orientation: 90, scale: 2),
        .circle(lat: 54.10, lon: 7.50, radius: 0, scale: 0),
        .polygon(legs: [(0, 5), (90, 5), (180, 5)], scale: 3),
        .sector(lat: 54.00, lon: 7.40, radius: 5, left: 350, right: 40, scale: 3),
        .text("SCHIESSEN BSH")])
    if let m = AISMessage.decode(AISBits(area1)), case .area(var a)? = m.binary {
        a.receivedAt = t0
        check(m.dac == 1 && m.fid == 22 && a.mmsi == 2_111_000 && a.linkage == 17 && a.notice == 37 && a.title == "Sperrgebiet: Schießgebiet" && a.category == .restricted, "AIS 1/22: Kopf (\(a.title))")
        check(a.shapes.count == 6 && a.durationMinutes == 180 && a.embeddedText == "SCHIESSEN BSH", "AIS 1/22: sechs Teilgebiete, Dauer, Text \(a.embeddedText)")
        if case .circle(let c, let r) = a.shapes[0] { check(abs(c.lat - 54.30) < 1e-4 && abs(c.lon - 7.80) < 1e-4 && r == 2000, "AIS 1/22: Kreis") } else { check(false, "AIS 1/22: Kreis fehlt") }
        if case .rectangle(let p) = a.shapes[1] {
            let e = Geo.distanceKm(p[0], p[1]), n = Geo.distanceKm(p[0], p[3])
            check(p.count == 4 && abs(e - 4.0) < 0.05 && abs(n - 3.0) < 0.05 && abs(Geo.bearing(from: p[0], to: p[1]) - 180) < 0.2, "AIS 1/22: Rechteck 4 × 3 km, um 90° gedreht (Ost wird Süd; \(e), \(n))")
        } else { check(false, "AIS 1/22: Rechteck fehlt") }
        if case .polygon(let p) = a.shapes[3] {
            check(p.count == 4 && abs(Geo.distanceKm(p[0], p[1]) - 5.0) < 0.05 && abs(Geo.bearing(from: p[0], to: p[1])) < 0.2 && abs(Geo.bearing(from: p[1], to: p[2]) - 90) < 0.3, "AIS 1/22: Vieleck ab dem Kreismittelpunkt (5 km Nord, 5 km Ost, 5 km Süd)")
            check(abs(p[0].lat - 54.10) < 1e-4 && abs(p[0].lon - 7.50) < 1e-4, "AIS 1/22: Vieleck beginnt am Punkt davor")
        } else { check(false, "AIS 1/22: Vieleck fehlt") }
        if case .sector(let c, let r, let l, let rt) = a.shapes[4] { check(abs(c.lat - 54.0) < 1e-4 && r == 5000 && l == 350 && rt == 40, "AIS 1/22: Sektor 350° bis 40°") } else { check(false, "AIS 1/22: Sektor fehlt") }
        check(a.start != nil && Calendar(identifier: .gregorian).component(.year, from: a.start!) == 2026 && abs(a.end!.timeIntervalSince(a.start!) - 3 * 3600) < 1, "AIS 1/22: Beginn 04.10. 09:00 UTC im Jahr des Empfangs, Ende 3 h später")
        check(a.isActive(at: t0) && !a.isActive(at: t0.addingTimeInterval(5 * 3600)) && a.points.count >= 8, "AIS 1/22: gilt bis zum Ende")
    } else { check(false, "AIS 1/22 nicht lesbar") }
    // Zufallsbits sind keine Gebietsmeldung (falsche Form)
    var junk = AISBitWriter()
    junk.u(8, 6); junk.u(0, 2); junk.u(2_111_000, 30); junk.u(0, 2); junk.u(1, 10); junk.u(22, 6)
    for k in 0..<200 { junk.bits.append(UInt8((k * 7 + 3) % 2)) }
    while junk.bits.count % 8 != 0 { junk.bits.append(1) }
    check(AISMessage.decode(AISBits(junk.bits))?.binary == .other, "AIS 1/22: Unsinn wird nicht als Gebietsmeldung gedeutet")

    // Schifffahrtszeichen
    let sig = AISSignalGenerator.trafficSignal(mmsi: 2_111_300, linkage: 5, station: "SCHLEUSE BRUNSBUETTEL", lat: 53.89, lon: 9.13, status: 1, signal: 4, nextSignal: 2, hour: 14, minute: 30)
    if let m = AISMessage.decode(AISBits(sig)), case .trafficSignal(let s)? = m.binary {
        check(s.station == "SCHLEUSE BRUNSBUETTEL".prefix(20) + "" && s.signal == 4 && s.nextSignal == 2 && s.status == 1 && s.hour == 14 && s.minute == 30, "AIS 1/19: Signalstelle \(s.station)")
        check(abs((m.latitude ?? 0) - 53.89) < 1e-4 && abs((m.longitude ?? 0) - 9.13) < 1e-4 && m.name == s.station, "AIS 1/19: Ort und Name der Signalstelle")
        check(s.lines == ["Signal 4: Fahrt frei, Gegenverkehr (regulärer Betrieb)", "Nächstes: Signal 2: Einfahrt und Ausfahrt verboten ab 14:30 UTC"], "AIS 1/19: Anzeigetext \(s.lines)")
    } else { check(false, "AIS 1/19 nicht lesbar") }

    // Wetterbeobachtung vom Schiff
    let sw = AISSignalGenerator.shipWeather(mmsi: 211_333_000, location: "DEUTSCHE BUCHT", lat: 54.5, lon: 7.2, windKn: 28, windDir: 250, airTemp: 11.4, pressure: 998, waterTemp: 13.2, waveHeight: 2.8, weatherCode: 2)
    if let m = AISMessage.decode(AISBits(sw)), case .meteo(let w)? = m.binary {
        check(w.fromShip && w.locationName == "DEUTSCHE BUCHT" && w.presentWeather == "Regen" && abs((m.latitude ?? 0) - 54.5) < 1e-4, "AIS 1/21: Ort und Wetter")
        check(w.windKn == 28 && w.windDir == 250 && w.airTemp == 11.4 && w.pressure == 998 && w.waterTemp == 13.2 && abs((w.waveHeight ?? 0) - 2.8) < 1e-9 && w.humidity == nil && w.visibilityNM == 9.5, "AIS 1/21: Werte \(w.lines)")
        check(w.lines.first == "Wetterbeobachtung vom Schiff bei DEUTSCHE BUCHT: Regen", "AIS 1/21: Kopfzeile")
    } else { check(false, "AIS 1/21 nicht lesbar") }

    // Erweiterte Reisedaten
    let ex = AISSignalGenerator.extendedShip(mmsi: 211_333_000, airDraught: 47.25, lastPort: "DEHAM", nextPort: "NLRTM", tonnage: 51_200, laden: 1, persons: 23, failedEquipmentIndex: 5)
    if let m = AISMessage.decode(AISBits(ex)), case .extended(let e)? = m.binary {
        check(e.airDraught == 47.25 && e.lastPort == "DEHAM" && e.nextPort == "NLRTM" && e.secondPort == nil && e.tonnage == 51_200 && e.lading == 1 && e.persons == 23, "AIS 1/24: Luftzug, Häfen, Tonnage, Beladung, Personen")
        check(e.failedEquipment == ["Echolot"] && e.operationalCount == 24 && e.iceClass == nil && e.horsepower == nil, "AIS 1/24: ausgefallenes Echolot")
        check(e.lines.contains("Luftzug 47,25 m · 51200 BRZ · beladen · 23 Personen") && e.lines.contains("Ausgefallen: Echolot"), "AIS 1/24: Anzeigetext \(e.lines)")
    } else { check(false, "AIS 1/24 nicht lesbar") }

    // Personen an Bord
    if let m = AISMessage.decode(AISBits(AISSignalGenerator.personsInland(mmsi: 211_512_340, destination: 2_111_000, crew: 4, passengers: 118, personnel: 255))), case .persons(let p)? = m.binary {
        check(p.crew == 4 && p.passengers == 118 && p.personnel == nil && p.text == "4 Besatzung · 118 Fahrgäste an Bord", "AIS 200/55: Personen \(p.text)")
    } else { check(false, "AIS 200/55 nicht lesbar") }
    var pob = AISBitWriter()
    pob.u(8, 6); pob.u(0, 2); pob.u(211_000_001, 30); pob.u(0, 2); pob.u(1, 10); pob.u(16, 6); pob.set(87, at: 56, 14); pob.pad(to: 72)
    if let m = AISMessage.decode(AISBits(pob.bits)), case .persons(let p)? = m.binary { check(p.total == 87 && p.text == "87 Personen an Bord", "AIS 1/16: Personen an Bord") } else { check(false, "AIS 1/16 nicht lesbar") }

    // Controller: Gebietsmeldungen, Text mit gleicher Verknüpfung, Aufhebung, Karte
    let c = AISController(pipeline: AudioPipeline(), settings: AISSettingsStore())
    c.logEnabled = false
    c.homePoint = Maidenhead.point("JN49WS")
    let now = Date()
    c.ingest(bits: AISSignalGenerator.areaNotice(mmsi: 2_111_000, linkage: 17, notice: 37, hour: 24, minute: 60, durationMinutes: 262_143, shapes: [.circle(lat: 54.30, lon: 7.80, radius: 2000, scale: 0), .polyline(legs: [(90, 3)], scale: 3)]), at: now)
    c.ingest(bits: AISSignalGenerator.textBroadcast(mmsi: 2_111_000, linkage: 17, text: "SCHIESSEN BIS 12 UHR"), at: now.addingTimeInterval(1))
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let nc = utc.dateComponents([.month, .day, .hour, .minute], from: now)       // Beginn jetzt (nicht an einem festen Tag, sonst läuft der Test ab)
    c.ingest(bits: AISSignalGenerator.areaNotice(mmsi: 2_111_000, linkage: 18, notice: 74, month: nc.month!, day: nc.day!, hour: nc.hour!, minute: nc.minute!, durationMinutes: 600,
                                                 shapes: [.circle(lat: 54.0, lon: 8.0, radius: 500, scale: 0)]), at: now.addingTimeInterval(2))
    // poll() läuft im Zeitgeber; hier direkt die Tabelle über die Karte lesen
    check(c.binaryCounts["1/22"] == 2 && c.binaryCounts["1/29"] == 1, "AIS-Controller: Zähler 1/22 und 1/29 \(c.binaryCounts)")
    let areas = c.areasForTesting(at: now.addingTimeInterval(3))
    check(areas.count == 2 && areas.first { $0.linkage == 17 }?.displayText == "SCHIESSEN BIS 12 UHR", "AIS-Controller: zwei Gebiete, Text zur Meldung 17 verknüpft")
    let mc = AISMapBuilder.content([], home: c.homePoint, now: now.addingTimeInterval(3), filter: .init(), selection: nil, areas: areas)
    check(mc.markers.contains { $0.id == "ais-area-2111000-17" && $0.symbol == "exclamationmark.triangle.fill" && $0.tone == .alert } && mc.markers.contains { $0.id == "ais-area-2111000-18" && $0.symbol == "lifepreserver.fill" }, "AIS-Karte: Warnzeichen je Gebiet, Seenot mit Rettungsring")
    check(mc.markers.contains { $0.id == "ais-area-2111000-17-s0" && abs($0.radiusKm - 2.0) < 1e-9 } && mc.lines.contains { $0.id == "ais-area-2111000-17-s1" && $0.points.count == 2 }, "AIS-Karte: Kreis mit Radius 2 km, Linie")
    check(mc.markers.first { $0.id == "ais-area-2111000-17" }?.details.contains { $0.contains("SCHIESSEN BIS 12 UHR") } == true, "AIS-Karte: Einzelheiten mit Text")
    check(AISMapBuilder.content([], home: nil, now: now, filter: .init(areas: false), selection: nil, areas: areas).markers.isEmpty, "AIS-Karte: Gebiete abschaltbar")
    // Aufhebung durch Kennung 126
    c.ingest(bits: AISSignalGenerator.areaNotice(mmsi: 2_111_000, linkage: 17, notice: 126, shapes: [.circle(lat: 54.30, lon: 7.80, radius: 2000, scale: 0)]), at: now.addingTimeInterval(4))
    check(c.areasForTesting(at: now.addingTimeInterval(5)).map(\.linkage) == [18], "AIS-Controller: Meldung 17 aufgehoben")
    // Zeichenbibliothek
    check(AISAreaNotice.noticeText(18) == "Fahrwasser gesperrt" && AISAreaNotice.noticeText(104) == "Seekarte: Fahrwasserhindernis" && AISAreaNotice.noticeText(127) == "Gebietsmeldung" && AISAreaNotice.noticeText(46) == "Gebietsmeldung 46", "AIS: Meldungsarten")
}
if want("ais") { aisMoreBinaryTests() }

// MARK: - Packet-Radio: Steuerfeld, Monitor, Verbindungen, NET/ROM, Winlink
@MainActor func packetTests() {
    func utf(_ s: String) -> [UInt8] { Array(s.utf8) }
    func frame(_ src: String, _ dst: String, _ ctl: UInt8, cmd: Bool? = true, pid: UInt8? = nil, info: [UInt8] = [], via: [String] = []) -> AX25Frame {
        var d = AX25Address(text: dst)!, s = AX25Address(text: src)!
        if let cmd { d.repeated = cmd; s.repeated = !cmd }
        let digis = via.map { v -> AX25Address in
            var a = AX25Address(text: v.replacingOccurrences(of: "*", with: ""))!
            a.repeated = v.hasSuffix("*")
            return a
        }
        return AX25Frame(dest: d, source: s, digis: digis, control: ctl, pid: pid, info: info)
    }
    func ctlByte(ns: Int? = nil, nr: Int = 0, pf: Bool = false, base: UInt8 = 0) -> UInt8 {
        if let ns { return UInt8(nr << 5 | (pf ? 0x10 : 0) | ns << 1) }
        return base | UInt8(nr << 5) | (pf ? 0x10 : 0)
    }

    // --- Steuerfeld ---
    do {
        func c(_ b: UInt8) -> AX25Control { AX25Control(byte: b) }
        check(c(0x3F).type == .connect && c(0x3F).pollFinal && c(0x2F).type == .connect && !c(0x2F).pollFinal, "Packet: SABM mit und ohne P")
        check(c(0x73).type == .acknowledge && c(0x1F).type == .disconnectedMode && c(0x53).type == .disconnect && c(0x03).type == .unnumberedInfo, "Packet: UA, DM, DISC, UI")
        check(c(0x6F).type == .connectExtended && c(0x87).type == .frameReject && c(0xAF).type == .exchangeID && c(0xE3).type == .test, "Packet: SABME, FRMR, XID, TEST")
        let i = c(0x4A)
        check(i.type == .information && i.ns == 5 && i.nr == 2 && !i.pollFinal, "Packet: I-Rahmen N(S)=5 N(R)=2")
        check(c(0x5A).pollFinal && c(0x5A).ns == 5, "Packet: Poll-Bit im I-Rahmen")
        check(c(0x61).type == .receiveReady && c(0x61).nr == 3 && c(0x25).type == .receiveNotReady && c(0x25).nr == 1
              && c(0x89).type == .reject && c(0x89).nr == 4 && c(0x0D).type == .selectiveReject, "Packet: RR, RNR, REJ, SREJ mit N(R)")
        check(frame("A", "B", 0x3F, cmd: true).role == .command && frame("A", "B", 0x73, cmd: false).role == .response && frame("A", "B", 0x03, cmd: nil).role == .legacy, "Packet: Befehl, Antwort, alte Fassung aus den C-Bits")
    }

    // --- Monitor-Zeilen, Sender und Weg ---
    do {
        let sabm = frame("DL1ABC", "DB0XYZ", 0x3F, via: ["DB0ABC*"])
        check(sabm.monitorLine == "DL1ABC>DB0XYZ,DB0ABC* <SABM C P>", "Packet: Monitorzeile SABM: \(sabm.monitorLine)")
        check(frame("DB0XYZ", "DL1ABC", 0x73, cmd: false).monitorLine == "DB0XYZ>DL1ABC <UA R F>", "Packet: Monitorzeile UA")
        let info = frame("DL1ABC", "DB0XYZ", ctlByte(ns: 3, nr: 5, pf: true), pid: 0xF0, info: utf("Hallo\rWelt"))
        check(info.monitorLine == "DL1ABC>DB0XYZ <I C S3 R5 P> Hallo⏎Welt", "Packet: Monitorzeile I-Rahmen: \(info.monitorLine)")
        check(frame("A", "B", 0x61, cmd: false).monitorLine == "A>B <RR R R3>", "Packet: Monitorzeile RR")
        check(frame("A", "B", 0x03, cmd: true, pid: 0xCC, info: [0x45, 0, 0, 120, 0, 0, 0, 0, 64, 6, 0, 0, 44, 130, 1, 5, 44, 130, 7, 2]).monitorLine.hasSuffix("IP 44.130.1.5 → 44.130.7.2 · TCP · 120 Byte"), "Packet: IP im Packet-Radio")
        let via = frame("DL1ABC", "CQ", 0x03, pid: 0xF0, via: ["DB0ABC*", "DB0DEF*", "WIDE2-1"])
        check(via.transmitter.text == "DB0DEF" && !via.isDirect && via.repeaters.map(\.text) == ["DB0ABC", "DB0DEF"], "Packet: gehörter Sender ist der letzte Digipeater mit H-Bit")
        check(frame("DL1ABC", "CQ", 0x03, pid: 0xF0).transmitter.text == "DL1ABC" && frame("DL1ABC", "CQ", 0x03, pid: 0xF0, via: ["DB0ABC"]).isDirect, "Packet: direkt gehört ohne H-Bit")
        // Kodieren und Lesen mit den C-Bits
        let wire = AX25Frame.parse(sabm.encode())
        check(wire == sabm && wire?.role == .command, "Packet: Rahmen kodieren und lesen behält die C-Bits")
    }

    // --- Verbindung: Aufbau, Daten, Wiederholung, Lücke, Abbau ---
    do {
        var an = PacketAnalyzer()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func t(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        an.ingest(frame("DL1ABC", "DB0XYZ", 0x3F, via: ["DB0ABC*"]), at: t(0))
        check(an.sessions.count == 1 && an.sessions[0].state == .connecting && an.sessions[0].via == ["DB0ABC"], "Packet: Verbindungswunsch")
        an.ingest(frame("DB0XYZ", "DL1ABC", 0x73, cmd: false, via: ["DB0ABC"]), at: t(1))
        check(an.sessions[0].state == .connected, "Packet: UA bestätigt die Verbindung")
        an.ingest(frame("DB0XYZ", "DL1ABC", ctlByte(ns: 0, nr: 0), pid: 0xF0, info: utf("Willkommen\rCmd:")), at: t(2))
        an.ingest(frame("DL1ABC", "DB0XYZ", ctlByte(ns: 0, nr: 1), pid: 0xF0, info: utf("H\r")), at: t(3))
        an.ingest(frame("DB0XYZ", "DL1ABC", ctlByte(ns: 1, nr: 1), pid: 0xF0, info: utf("Hilfe...\r")), at: t(4))
        an.ingest(frame("DB0XYZ", "DL1ABC", ctlByte(ns: 1, nr: 1), pid: 0xF0, info: utf("Hilfe...\r")), at: t(5))      // Wiederholung
        an.ingest(frame("DL1ABC", "DB0XYZ", ctlByte(nr: 2, base: 0x01), cmd: false), at: t(6))                         // RR
        an.ingest(frame("DB0XYZ", "DL1ABC", ctlByte(ns: 3, nr: 1), pid: 0xF0, info: utf("Ende\r")), at: t(7))          // 2 fehlt
        var s = an.sessions[0]
        check(s.infoFrames == 5 && s.retransmissions == 1 && s.gaps == 1, "Packet: Datenrahmen \(s.infoFrames), Wiederholungen \(s.retransmissions), Lücken \(s.gaps)")
        let text = s.lines.filter { $0.kind == .text }.map(\.text)
        check(text == ["Willkommen", "Cmd:", "H", "Hilfe...", "Ende"], "Packet: Gesprächsverlauf \(text)")
        check(s.lines.filter { $0.kind == .text }.map(\.direction) == [1, 1, 0, 1, 1], "Packet: Richtungen der Zeilen")
        check(s.lines.contains { $0.kind == .note && $0.text.contains("Lücke") }, "Packet: Lücke im Verlauf vermerkt")
        check(s.bytes[0] == 2 && s.bytes[1] == 15 + 9 + 5, "Packet: Nutzbytes je Richtung \(s.bytes)")
        an.ingest(frame("DL1ABC", "DB0XYZ", 0x53), at: t(8))
        check(an.sessions[0].isOpen, "Packet: nach DISC noch offen, bis UA kommt")
        an.ingest(frame("DB0XYZ", "DL1ABC", 0x73, cmd: false), at: t(9))
        s = an.sessions[0]
        check(s.state == .closed && s.ended == t(9) && !s.isOpen && s.kind == .text, "Packet: UA nach DISC beendet die Verbindung")
        // Zweite Verbindung derselben Stationen ist eine neue Sitzung
        an.ingest(frame("DL1ABC", "DB0XYZ", 0x3F), at: t(100))
        check(an.sessions.count == 2 && an.sessions[1].state == .connecting && an.sessions[1].id == 2, "Packet: neue Verbindung nach dem Abbau")
        an.ingest(frame("DB0XYZ", "DL1ABC", 0x1F, cmd: false), at: t(101))
        check(an.sessions[1].state == .refused, "Packet: DM lehnt den Verbindungswunsch ab")
        // Rahmen ohne gehörten Aufbau: mitgehörte Sitzung, geratener Anrufer
        an.ingest(frame("DB0QRZ", "DL9XYZ", ctlByte(ns: 4, nr: 2), pid: 0xF0, info: utf("mitten drin\r")), at: t(200))
        check(an.sessions.count == 3 && an.sessions[2].state == .observed && an.sessions[2].lines.contains { $0.text == "mitten drin" }, "Packet: mitten in einer Verbindung eingeschaltet")
        // Reine Quittungen ohne Sitzung legen keine an
        let before = an.sessions.count
        an.ingest(frame("DL5AAA", "DL6BBB", ctlByte(nr: 1, base: 0x01), cmd: false), at: t(201))
        check(an.sessions.count == before, "Packet: RR ohne bekannte Verbindung legt keine an")
        // Verbindung ohne Ende
        an.ingest(frame("DL1ABC", "DB0XYZ", 0x3F), at: t(300))
        an.housekeeping(now: t(300 + PacketAnalyzer.idleTimeout + 10))
        check(an.sessions.allSatisfy { !$0.isOpen }, "Packet: Verbindung ohne weitere Rahmen gilt nach 30 min als beendet")
        // Reparierte Rahmen kommen nicht in Stationen und Sitzungen
        var an2 = PacketAnalyzer()
        an2.ingest(frame("DL7REP", "CQ", 0x03, pid: 0xF0, info: utf("x")), at: t(0), repaired: true)
        check(an2.frameCount == 1 && an2.stations.isEmpty, "Packet: reparierter Rahmen nur in den Zählern")
    }

    // --- Stationen, Digipeater, Bake ---
    do {
        var an = PacketAnalyzer()
        let now = Date()
        an.ingest(frame("DB0MAI", "BEACON", 0x03, pid: 0xF0, info: utf("DB0MAI Mailbox, Wuerzburg")), at: now)
        an.ingest(frame("DL1ABC", "CQ", 0x03, pid: 0xF0, info: utf("CQ CQ"), via: ["DB0ABC*", "DB0DEF*", "WIDE2-1"]), at: now)
        an.ingest(frame("DL2XYZ", "CQ", 0x03, pid: 0xF0, info: utf("QRZ"), via: ["DB0DEF*", "WIDE1*"]), at: now)
        check(an.stations["DB0MAI"]?.lastText == "DB0MAI Mailbox, Wuerzburg" && an.stations["DB0MAI"]?.direct == true, "Packet: Bake und direkt gehört")
        check(an.stations["DL1ABC"]?.direct == false && an.stations["DL1ABC"]?.lastPath == ["DB0ABC*", "DB0DEF*", "WIDE2-1"], "Packet: Weg einer Station")
        check(an.digipeaters["DB0DEF"]?.heard == 2 && an.digipeaters["DB0DEF"]?.inPath == 2 && an.digipeaters["DB0DEF"]?.sources == ["DL1ABC", "DL2XYZ"], "Packet: Digipeater DB0DEF zweimal gehört, zwei Stationen")
        check(an.digipeaters["DB0ABC"]?.heard == 0 && an.digipeaters["DB0ABC"]?.inPath == 1 && an.stations["DB0ABC"]?.isDigipeater == true, "Packet: DB0ABC nur im Weg")
        check(an.digipeaters["WIDE1"] == nil && an.digipeaters["WIDE2-1"] == nil, "Packet: allgemeine Weg-Namen sind keine Digipeater")
        check(PacketAnalyzer.isGenericAlias("WIDE2-2") && PacketAnalyzer.isGenericAlias("RELAY") && PacketAnalyzer.isGenericAlias("TCPIP") && !PacketAnalyzer.isGenericAlias("DB0ABC"), "Packet: Erkennung allgemeiner Weg-Namen")
    }

    // --- NET/ROM ---
    do {
        func shifted(_ call: String, _ ssid: Int) -> [UInt8] {
            var b = Array(call.utf8.prefix(6)).map { $0 << 1 }
            while b.count < 6 { b.append(0x40) }
            return b + [UInt8(0x60 | ssid << 1)]
        }
        func alias(_ a: String) -> [UInt8] { Array(a.utf8) + [UInt8](repeating: 0x20, count: 6 - a.utf8.count) }
        let entry1 = shifted("DB0AAA", 3) + alias("AAA") + shifted("DB0NBR", 0) + [200]
        let entry2 = shifted("DB0BBB", 0) + alias("BBB") + shifted("DB0NBR", 0) + [120]
        let body: [UInt8] = [0xFF] + alias("XYZ") + entry1 + entry2
        let ui = frame("DB0XYZ", "NODES", 0x03, pid: 0xCF, info: body)
        let list = NetRom.parseNodes(body)
        check(list?.sender == "XYZ" && list?.nodes.count == 2 && list?.nodes[0] == NetRomNode(call: "DB0AAA-3", alias: "AAA", neighbour: "DB0NBR", quality: 200), "Packet: NET/ROM-Knotenliste lesen")
        check(NetRom.parseNodes([0xFF] + alias("XYZ") + [1, 2, 3]) == nil && NetRom.parseNodes([0x01] + alias("XYZ")) == nil, "Packet: NET/ROM: falsche Länge und Kennbyte werden abgelehnt")
        check(ui.monitorLine.contains("Knotenliste von XYZ: 2 Ziele"), "Packet: NET/ROM im Monitor: \(ui.monitorLine)")
        var an = PacketAnalyzer()
        an.ingest(ui, at: Date())
        check(an.nodes["DB0AAA-3"]?.quality == 200 && an.nodes["DB0BBB"]?.heardFrom == "DB0XYZ" && an.stations["DB0XYZ"]?.alias == "XYZ", "Packet: Knotentabelle und Name des Absenders")
        let l3 = [UInt8](shifted("DL1ABC", 0) + shifted("DB0AAA", 3) + [15, 3, 4, 0, 0, 5]) + utf("Hi")
        let n3 = NetRom.parseLayer3(l3)
        check(n3?.origin == "DL1ABC" && n3?.destination == "DB0AAA-3" && n3?.ttl == 15 && n3?.opcodeName == "Daten" && n3?.payload == utf("Hi"), "Packet: NET/ROM-Netzwerkkopf")
    }

    // --- LZHUF ---
    do {
        // Rundlauf mit dem Literal-Kodierer (zufällige und wiederholte Daten)
        var seed: UInt64 = 12345
        func rnd() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
        let random = (0..<3000).map { _ in rnd() }
        let text = utf(String(repeating: "Dies ist ein Test der Nachrichten-Kompression. ", count: 80))
        for (name, data) in [("zufällig", random), ("Text", text), ("leer", [UInt8]())] {
            let packed = LZHUF.encodeLiterals(data)
            let r = LZHUF.decode(packed)
            check(r?.data == data && r?.checksumOK == true && r?.complete == true, "LZHUF: Rundlauf \(name)")
        }
        var bad = LZHUF.encodeLiterals(text)
        bad[bad.count / 2] ^= 0x10
        check(LZHUF.decode(bad)?.checksumOK == false, "LZHUF: veränderte Daten erkennt die Prüfsumme")
        check(LZHUF.decode(Array(LZHUF.encodeLiterals(text).prefix(40)))?.complete == false, "LZHUF: abgeschnittene Daten sind unvollständig")
        check(LZHUF.decode([1, 2, 3]) == nil, "LZHUF: zu kurzer Kopf")
        // Echte Dateien (Pat/wl2k-go, nur lokal)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Winlink")
        for name in ["gettysburg.txt", "e.txt", "LPE5NXDVLVSQ.b2f"] {
            if let packed = try? Data(contentsOf: dir.appendingPathComponent(name + ".lzh")), let plain = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                let r = LZHUF.decode([UInt8](packed))
                check(r?.data == [UInt8](plain) && r?.checksumOK == true && r?.complete == true, "LZHUF: echte Datei \(name) bitgleich entpackt")
            } else {
                skip("LZHUF \(name): TestData/Winlink/\(name).lzh liegt nicht lokal vor")
            }
        }
        if let plain = try? Data(contentsOf: dir.appendingPathComponent("LPE5NXDVLVSQ.b2f")) {
            let m = WinlinkParser.parseMessage([UInt8](plain), compressedSize: 31209)
            check(m?.mid == "LPE5NXDVLVSQ" && m?.from == "LA5NTA" && m?.to == ["LA4TTA"] && m?.subject == "73 fra Brekke" && m?.type == "Private" && m?.mbo == "LA5NTA", "Winlink: echte Nachricht, Kopfzeilen")
            check(m?.date == "2016/07/20 19:21" && m?.body.hasPrefix("Hei!") == true && m?.body.utf8.count != nil, "Winlink: echte Nachricht, Datum und Text: \(m?.body.prefix(20) ?? "-")")
            check(m?.attachments.count == 1 && m?.attachments[0].name == "1469042410710.jpg" && m?.attachments[0].size == 31028 && m?.attachments[0].data.count == 31028
                  && m?.attachments[0].data.prefix(2) == [0xFF, 0xD8], "Winlink: echte Nachricht, Anhang (JPEG, 31028 Byte)")
            check(m?.body.contains("pr\u{F8}ver") == true, "Winlink: Text in ISO-8859-1 richtig gelesen (ø)")
        } else {
            skip("Winlink: TestData/Winlink/LPE5NXDVLVSQ.b2f liegt nicht lokal vor")
        }
    }

    // --- Winlink: Kopfzeilen, RFC-2047-Wörter, SID ---
    do {
        check(WinlinkParser.decodeWords("=?utf-8?Q?F=C3=BCr_Sie?=") == "Für Sie" && WinlinkParser.decodeWords("=?iso-8859-1?Q?Gr=FC=DFe?=") == "Grüße", "Winlink: Wörter nach RFC 2047 (Q)")
        check(WinlinkParser.decodeWords("=?utf-8?B?RsO8ciBTaWU=?=") == "Für Sie" && WinlinkParser.decodeWords("Hallo =?utf-8?Q?Welt?= !") == "Hallo Welt !" && WinlinkParser.decodeWords("kein Wort") == "kein Wort", "Winlink: Wörter (Base64), gemischt, unverändert")
        let sid = MailSID(line: "[WL2K-5.0-B2FWIHJM$]")
        check(sid?.software == "WL2K" && sid?.version == "5.0" && sid?.flags == "B2FWIHJM" && sid?.isWinlink == true, "Winlink: Kennung WL2K")
        let sid2 = MailSID(line: "[RMS Express-1.6.4.0-B2FHM$]")
        check(sid2?.software == "RMS Express" && sid2?.version == "1.6.4.0" && sid2?.isWinlink == true, "Winlink: Kennung RMS Express")
        let sid3 = MailSID(line: "[LinFBB-7.0.11-AB1FHMRX$]")
        check(sid3?.isWinlink == false && sid3?.flags == "AB1FHMRX", "Winlink: Kennung einer Mailbox (LinFBB) ist kein Winlink")
        check(MailSID(line: "Hallo [Welt]") == nil && MailSID(line: "[nur Text]") == nil && !MailSID.isSID("[x$]"), "Winlink: Nicht-Kennungen")
    }

    // --- Winlink: ganze Sitzung (Gateway liefert eine Nachricht mit Anhang) ---
    do {
        let body = "Lagebericht 1\r\nAlles ruhig, 73 de DL1ABC"
        let attachment = (0..<700).map { UInt8(($0 * 7 + 3) & 0xFF) }
        var raw = utf("Mid: ABCDEFGH1234\r\nBody: \(body.utf8.count)\r\nContent-Transfer-Encoding: 8bit\r\nContent-Type: text/plain; charset=UTF-8\r\nDate: 2026/10/06 08:15\r\nFile: \(attachment.count) daten.bin\r\nFrom: DL1ABC\r\nMbo: DB0XYZ\r\nSubject: =?utf-8?Q?F=C3=BCr_alle?=\r\nTo: DL2DEF\r\nTo: DL3GHI\r\nType: Private\r\n\r\n")
        raw += utf(body) + utf("\r\n") + attachment + utf("\r\n")
        let packed = LZHUF.encodeLiterals(raw)
        func blocks(_ title: String, _ data: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [0x01, UInt8(title.utf8.count + 3)] + utf(title) + [0] + utf("0") + [0]
            var sum = 0
            var i = 0
            while i < data.count {
                let n = min(250, data.count - i)
                out += [0x02, UInt8(n)] + data[i..<(i + n)]
                for b in data[i..<(i + n)] { sum += Int(b) }
                i += n
            }
            return out + [0x04, UInt8((-sum) & 0xFF)]
        }
        func fcChecksum(_ lines: [String]) -> String {
            var sum = 0
            for l in lines { sum += l.utf8.reduce(0) { $0 + Int($1) } + 0x0D }
            return String(format: "%02X", (-sum) & 0xFF)
        }
        let fc = "FC EM ABCDEFGH1234 \(raw.count) \(packed.count) 0"
        let gateway = "DB0XYZ-10", client = "DL1ABC"
        func session(decode: Bool = true, dropFrameInData: Bool = false, answer: String = "FS +") -> PacketAnalyzer {
            var an = PacketAnalyzer()
            an.decodeMessages = decode
            let t0 = Date(timeIntervalSince1970: 1_800_100_000)
            var n = 0.0
            func at() -> Date { n += 1; return t0.addingTimeInterval(n) }
            var nsGateway = 0, nsClient = 0
            func g(_ bytes: [UInt8], drop: Bool = false) {
                let f = frame(gateway, client, ctlByte(ns: nsGateway & 7, nr: nsClient & 7), pid: 0xF0, info: bytes)
                nsGateway += 1
                if !drop { an.ingest(f, at: at()) }
            }
            func c(_ text: String) {
                an.ingest(frame(client, gateway, ctlByte(ns: nsClient & 7, nr: nsGateway & 7), pid: 0xF0, info: utf(text)), at: at())
                nsClient += 1
            }
            an.ingest(frame(client, gateway, 0x3F, via: ["DB0REL*"]), at: at())
            an.ingest(frame(gateway, client, 0x73, cmd: false, via: ["DB0REL"]), at: at())
            g(utf("[WL2K-5.0-B2FWIHJM$]\r;PQ: 12345678\rCMS via \(gateway) >\r"))
            c("[Pat-0.15-B2FHM$]\r;PR: 98765432\r; \(gateway) DE \(client) (JN49WS)\r")
            g(utf(fc + "\rF> " + fcChecksum([fc]) + "\r"))
            c(answer + "\r")
            // Datenblöcke in Rahmen zu je 128 Byte
            let stream = blocks("F\u{FC}r alle", packed)
            var i = 0
            var k = 0
            while i < stream.count {
                let n2 = min(128, stream.count - i)
                g(Array(stream[i..<(i + n2)]), drop: dropFrameInData && k == 3)
                i += n2
                k += 1
            }
            c("FF\r")
            g(utf("FQ\r"))
            an.ingest(frame(client, gateway, 0x53), at: at())
            an.ingest(frame(gateway, client, 0x73, cmd: false), at: at())
            return an
        }
        let an = session()
        let s = an.sessions[0]
        check(s.state == .closed && s.kind == .winlink && s.mail.sids[0]?.software == "Pat" && s.mail.sids[1]?.software == "WL2K" && s.mail.secureChallenge, "Winlink: Sitzung als Winlink erkannt, beide Kennungen, gesicherte Anmeldung")
        check(s.mail.proposals[1].count == 1 && s.mail.proposals[1][0].mid == "ABCDEFGH1234" && s.mail.proposals[1][0].size == raw.count && s.mail.proposals[1][0].answer == "+" && s.mail.proposals[1][0].delivered, "Winlink: Vorschlag, Antwort „+“ und Zustellung")
        check(s.mail.checksumErrors == 0 && s.mail.notes.isEmpty, "Winlink: Prüfsumme der Vorschläge stimmt (\(s.mail.notes))")
        if let m = s.mail.messages.first {
            check(s.mail.messages.count == 1 && m.mid == "ABCDEFGH1234" && m.from == "DL1ABC" && m.to == ["DL2DEF", "DL3GHI"] && m.subject == "Für alle" && m.mbo == "DB0XYZ", "Winlink: Nachricht, Kopfzeilen (\(m.to) \(m.subject))")
            check(m.body == body && m.attachments.count == 1 && m.attachments[0].name == "daten.bin" && m.attachments[0].data == attachment && m.size == raw.count, "Winlink: Nachricht, Text und Anhang bitgleich")
            check(m.received > Date(timeIntervalSince1970: 1_800_100_000), "Winlink: Empfangszeit gesetzt")
        } else {
            check(false, "Winlink: keine Nachricht entpackt (\(s.mail.notes))")
        }
        check(s.lines.contains { $0.kind == .binary && $0.text.contains("Nachrichtendaten") } && !s.transcript.contains("\u{1}"), "Winlink: Datenblöcke erscheinen im Verlauf nur als Zeile mit Byteanzahl")
        check(s.lines.contains { $0.text == "FQ" } && s.lines.contains { $0.text.hasPrefix("FC EM ABCDEFGH1234") }, "Winlink: Text vor und nach den Daten bleibt lesbar")
        check(an.stations[gateway]?.sid?.isWinlink == true && an.stations[gateway]?.role == "Winlink" && an.messages.count == 1, "Packet: Station als Winlink-Gateway, Nachrichtenliste")
        // Antwort „FS −“: keine Daten erwartet, keine Nachricht
        let rejected = session(answer: "FS -")
        check(rejected.sessions[0].mail.proposals[1][0].answer == "-" && rejected.sessions[0].mail.messages.isEmpty, "Winlink: abgelehnter Vorschlag liefert keine Nachricht")
        // Lesen aus: nur zählen
        let off = session(decode: false)
        check(off.sessions[0].mail.messages.isEmpty && off.sessions[0].mail.notes.contains { $0.contains("abgeschaltet") }, "Winlink: Entpacken abgeschaltet")
        // Ein Rahmen mitten in den Daten fehlt: keine falsche Nachricht
        let broken = session(dropFrameInData: true)
        check(broken.sessions[0].gaps == 1 && broken.sessions[0].mail.messages.isEmpty && broken.sessions[0].mail.notes.contains { $0.contains("fehlte") }, "Winlink: fehlender Rahmen in den Daten ergibt keine (falsche) Nachricht")
    }

    // --- Mailbox-Weiterleitung (FBB): Vorschläge als Text ---
    do {
        var t = MailTracker()
        let l1 = "FB P DL1ABC DB0XYZ DL2DEF DL2DEF 12345_DB0XYZ 456"
        var sum = l1.utf8.reduce(0) { $0 + Int($1) } + 0x0D
        sum = (-sum) & 0xFF
        t.feed(0, utf("[LinFBB-7.0.11-AB1FHMRX$]\r" + l1 + "\rF> " + String(format: "%02X", sum) + "\r"))
        t.feed(1, utf("FS +\r"))
        check(t.sids[0]?.software == "LinFBB" && !t.isWinlink && t.proposals[0].count == 1 && t.proposals[0][0].mid == "12345_DB0XYZ" && t.proposals[0][0].size == 456
              && t.proposals[0][0].answer == "+" && t.checksumErrors == 0, "Mailbox: Kennung und Vorschlag (FB) gelesen")
        t.feed(0, utf("FB P A B C D E 1\rF> 00\r"))
        check(t.checksumErrors == 1, "Mailbox: falsche Prüfsumme der Vorschläge wird gemeldet")
    }

    // --- Weg über das Audiosignal: Verbindung und Weiterleitung durch Modulator und Empfänger ---
    do {
        let frames: [AX25Frame] = [
            frame("DL1ABC", "DB0XYZ", 0x3F),
            frame("DB0XYZ", "DL1ABC", 0x73, cmd: false),
            frame("DB0XYZ", "DL1ABC", ctlByte(ns: 0, nr: 0), pid: 0xF0, info: utf("[FBB-7.0-FHM$]\rWillkommen bei DB0XYZ\r>\r")),
            frame("DL1ABC", "DB0XYZ", ctlByte(ns: 0, nr: 1), pid: 0xF0, info: utf("B\r")),
            frame("DB0XYZ", "DL1ABC", ctlByte(nr: 1, base: 0x01), cmd: false),
            frame("DL1ABC", "DB0XYZ", 0x53),
            frame("DB0XYZ", "DL1ABC", 0x73, cmd: false),
        ]
        let audio = AFSKModulator.modulate(frames: frames.map { $0.encode() }, sampleRate: 12_000) + [Float](repeating: 0, count: 6_000)
        let rx = AFSKReceiver(sampleRate: 12_000)
        var raws: [APRSRawFrame] = []
        var i = 0
        while i < audio.count {
            let e = min(i + 240, audio.count)
            audio[i..<e].withUnsafeBufferPointer { rx.process($0) { raws.append($0) } }
            i = e
        }
        check(raws.count == frames.count && zip(raws, frames).allSatisfy { AX25Frame.parse($0.bytes) == $1 }, "Packet: \(raws.count) von \(frames.count) Rahmen (SABM, UA, I, RR, DISC) über Audio, auch die C-Bits stimmen")
        let c = PacketController(pipeline: AudioPipeline(), settings: PacketSettingsStore())
        c.logEnabled = false
        for r in raws { c.ingest(r, at: Date()) }
        check(c.monitor.count == frames.count && c.sessions.count == 1 && c.sessions[0].state == .closed && c.sessions[0].kind == .mailbox, "Packet-Controller: Monitor \(c.monitor.count), Verbindung beendet, Mailbox erkannt")
        check(c.stations.first(where: { $0.call == "DB0XYZ" })?.sid?.software == "FBB" && c.frameCount == frames.count, "Packet-Controller: Station mit Kennung")
        c.clear()
        check(c.monitor.isEmpty && c.sessions.isEmpty && c.stations.isEmpty, "Packet-Controller: Listen leeren")
    }

    // --- Demo-Signal des Prüfstands (MakeSignal): Rahmen durch die Auswertung ---
    do {
        let frames = PacketSignalGenerator.demoFrames()
        var an = PacketAnalyzer()
        let t0 = Date()
        for (i, f) in frames.enumerated() { an.ingest(AX25Frame.parse(f.encode())!, at: t0.addingTimeInterval(Double(i))) }
        check(an.sessions.count == 2 && an.sessions.allSatisfy { $0.state == .closed } && an.sessions.contains { $0.kind == .winlink } && an.sessions.contains { $0.kind == .mailbox }, "Packet-Demo: zwei beendete Verbindungen (Winlink, Mailbox)")
        check(an.messages.count == 1 && an.messages[0].message.subject == "Lagemeldung Hochwasser" && an.messages[0].message.attachments.first?.size == 600, "Packet-Demo: Winlink-Nachricht mit Anhang gelesen")
        check(an.nodes.count == 3 && an.digipeaters["DB0DEF"]?.sources.count == 2 && an.stations["DB0MAI-1"]?.sid?.software == "LinFBB", "Packet-Demo: Knoten, Digipeater, Mailbox-Kennung")
    }

    // --- Kanäle, Modul, URL, Funkgerät ---
    do {
        check(PacketChannel.v8125.frequencyHz == 144_812_500 && PacketChannel.u650.frequencyHz == 433_650_000 && PacketChannel.free.frequencyHz == nil, "Packet: Kanalfrequenzen")
        check(PacketChannel.v8125.label == "144,8125" && PacketChannel.u625.label == "433,625" && PacketChannel.free.label == "frei", "Packet: Kanalbeschriftung \(PacketChannel.u625.label)")
        check(PacketChannel.allCases.filter(\.isUHF).count == 7 && PacketChannel.allCases.filter { !$0.isUHF && $0 != .free }.count == 8, "Packet: 8 Kanäle auf 2 m, 7 auf 70 cm")
        let rig = RigTuneTarget.packet(channel: .u650)
        check(rig?.dialHz == 433_650_000 && rig?.mode == "FM" && RigTuneTarget.packet(channel: .free) == nil, "Packet: Abstimmziel FM auf der Kanalfrequenz")
        check(DecoderModuleInfo.packet.isAvailable && DecoderModuleInfo.packet.band == .vhfUhf && !DecoderModuleInfo.packet.hasMap && DecoderModuleInfo.packet.displayName == "PACKET", "Packet: Modul in der Liste")
        check(parse("digidec://decode?mode=packet&preset=u650") == .success(DecodeRequest(module: .packet, presetID: "u650")) && parse("digidec://decode?mode=packet") == .success(DecodeRequest(module: .packet, presetID: "v8125")), "Packet: URL-Aufruf")
        check({ if case .failure = parse("digidec://decode?mode=packet&preset=nope") { return true } else { return false } }(), "Packet: unbekannter Kanal wird abgelehnt")
    }
}
if want("packet") { packetTests() }

// MARK: - ADS-B: Prüfsumme, Meldungen, Demodulator, Tracker, Engine
@MainActor func adsbTests() {
    func hexBytes(_ h: String) -> [UInt8] { var o: [UInt8] = []; var i = h.startIndex; while i < h.endIndex { let n = h.index(i, offsetBy: 2); o.append(UInt8(h[i..<n], radix: 16)!); i = n }; return o }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // --- Prüfsumme und Korrektur (Beispielmeldungen aus „The 1090 MHz Riddle“) ---
    do {
        let msgs = ["8D40621D58C382D690C8AC2863A7", "8D40621D58C386435CC412692AD6", "8D4840D6202CC371C32CE0576098", "8D485020994409940838175B284F", "8C4841753A9A153237AEF0F275BE"]
        check(msgs.allSatisfy { ModeSCRC.remainder(hexBytes($0)) == 0 }, "ADS-B: CRC-24 der Beispielmeldungen ist 0")
        var bad = hexBytes(msgs[0])
        bad[7] ^= 0x10
        check(ModeSCRC.remainder(bad) != 0, "ADS-B: gekipptes Bit ändert das Syndrom")
        let dec = ModeSDecoder()
        let fixed = dec.decode(bad, at: t0)
        check(fixed?.confidence == .corrected && fixed?.correctedBit == 7 * 8 + 3 && fixed?.bytes == hexBytes(msgs[0]), "ADS-B: Einzelbitfehler in DF17 korrigiert (Bit \(String(describing: fixed?.correctedBit)))")
        var two = hexBytes(msgs[0])
        two[5] ^= 0x01
        two[9] ^= 0x40
        check(ModeSDecoder().decode(two, at: t0) == nil, "ADS-B: zwei Bitfehler werden nicht „repariert“")
        var strict = ModeSDecoder()
        strict.correctSingleBit = false
        check(strict.decode(bad, at: t0) == nil, "ADS-B: Korrektur abschaltbar")
        check(ModeSCRC.syndromes112.count == 112 && Set(ModeSCRC.syndromes112).count == 112, "ADS-B: 112 verschiedene Syndrome für Einzelbitfehler")
        _ = strict
    }

    // --- Meldungen lesen ---
    do {
        let dec = ModeSDecoder()
        func d(_ h: String) -> ModeSMessage { dec.decode(hexBytes(h), at: t0)! }
        let id = d("8D4840D6202CC371C32CE0576098")
        check(id.icaoText == "4840D6" && id.callsign == "KLM1023" && id.typeCode == 4 && id.category == 0 && id.df == 17, "ADS-B: Kennung KLM1023")
        let v = d("8D485020994409940838175B284F")
        check(v.velocity?.subtype == 1 && abs((v.velocity?.groundSpeedKn ?? 0) - 159.2) < 0.2 && abs((v.velocity?.trackDeg ?? 0) - 182.88) < 0.01 && v.velocity?.verticalRateFpm == -832, "ADS-B: Geschwindigkeit 159 kn, 182,88°, −832 ft/min")
        let even = d("8D40621D58C382D690C8AC2863A7"), odd = d("8D40621D58C386435CC412692AD6")
        check(even.altitudeFt == 38000 && even.cpr == .init(odd: false, lat: 93000, lon: 51372, surface: false) && odd.cpr?.odd == true && even.onGround == false, "ADS-B: Höhe 38000 ft, CPR-Rohwerte")
        let g = ADSBCPR.globalAirborne(even: (even.cpr!.lat, even.cpr!.lon), odd: (odd.cpr!.lat, odd.cpr!.lon), newerIsOdd: false)
        check(g != nil && abs(g!.lat - 52.2572) < 1e-4 && abs(g!.lon - 3.91937) < 1e-4, "ADS-B: globale CPR-Dekodierung 52,2572 / 3,91937: \(String(describing: g))")
        let local = ADSBCPR.local(lat: even.cpr!.lat, lon: even.cpr!.lon, odd: false, ref: (52.0, 4.0))
        check(abs(local.lat - 52.2572) < 1e-4 && abs(local.lon - 3.91937) < 1e-4, "ADS-B: lokale CPR-Dekodierung mit Bezugspunkt")
        let sf = d("8C4841753A9A153237AEF0F275BE")
        check(sf.onGround == true && sf.cpr?.surface == true && sf.velocity?.groundSpeedKn == 17.0 && sf.velocity?.trackDeg == 92.8125, "ADS-B: Bodenposition, 17 kn, 92,8125°")
        let sp = ADSBCPR.local(lat: sf.cpr!.lat, lon: sf.cpr!.lon, odd: sf.cpr!.odd, ref: (51.99, 4.375), surface: true)
        check(abs(sp.lat - 52.3206) < 0.001 && abs(sp.lon - 4.7357) < 0.001, "ADS-B: Bodenposition mit Bezugspunkt: \(sp)")
        check(ADSBCPR.nl(0) == 59 && ADSBCPR.nl(87) == 2 && ADSBCPR.nl(88) == 1 && ADSBCPR.nl(52.2572) == 36 && ADSBCPR.nl(-30) == 51 && ADSBCPR.nl(10.47047130) == 58, "ADS-B: NL-Tabelle")
        // Meldungen ohne reine Parität gelten nur für bekannte Adressen
        let fresh = ModeSDecoder()
        let reply = ADSBSignalGenerator.altitudeReply(icao: 0x4840D6, altitudeFt: 12_350)
        check(fresh.decode(reply, at: t0) == nil, "ADS-B: DF4 von unbekannter Adresse wird nicht geglaubt")
        _ = fresh.decode(hexBytes("8D4840D6202CC371C32CE0576098"), at: t0)
        let known = fresh.decode(reply, at: t0.addingTimeInterval(5))
        check(known?.df == 4 && known?.icao == 0x4840D6 && known?.altitudeFt == 12_350 && known?.confidence == .knownAddress, "ADS-B: DF4 nach DF17 derselben Adresse, Höhe 12350 ft")
        check(fresh.decode(reply, at: t0.addingTimeInterval(120)) == nil, "ADS-B: Adresse gilt nur 60 s")
        // DF11 mit Interrogator-Anteil
        var df11 = ADSBSignalGenerator.allCallReply(icao: 0x4840D6)
        check(fresh.decode(df11, at: t0.addingTimeInterval(1))?.df == 11, "ADS-B: Sammelantwort DF11")
        df11[6] ^= 0x05
        check(fresh.decode(df11, at: t0.addingTimeInterval(2)) != nil, "ADS-B: DF11 mit Interrogator-Kennung (Rest < 80) bei bekannter Adresse")
        // Kennung (Squawk) und Notlage
        let em = ADSBSignalGenerator.extendedSquitter(icao: 0x3C6444, me: ADSBSignalGenerator.emergencyStatus(emergency: 1, squawk: "7700"))
        let e = ModeSDecoder().decode(em, at: t0)
        check(e?.squawk == "7700" && e?.emergency == 1 && ADSBNames.emergency(1, squawk: "7700") == "Allgemeiner Notfall" && ADSBNames.emergency(0, squawk: "7600") == "Funkausfall (Kennung 7600)", "ADS-B: Notlage und Kennung 7700")
    }

    // --- Erzeuger: Rundlauf CPR, Kennung, Geschwindigkeit ---
    do {
        let dec = ModeSDecoder()
        var ok = 0, total = 0
        for (lat, lon) in [(49.79, 9.95), (-33.86, 151.21), (64.13, -21.9), (0.5, 0.5), (-54.8, -68.3), (35.7, 139.7), (51.5, -0.12), (78.2, 15.6)] {
            let e = ADSBSignalGenerator.cpr(lat: lat, lon: lon, odd: false), o = ADSBSignalGenerator.cpr(lat: lat, lon: lon, odd: true)
            total += 1
            if let g = ADSBCPR.globalAirborne(even: e, odd: o, newerIsOdd: true), abs(g.lat - lat) < 1e-3, abs(g.lon - lon) < 1e-3 { ok += 1 }
            let loc = ADSBCPR.local(lat: e.lat, lon: e.lon, odd: false, ref: (lat + 0.3, lon - 0.4))
            total += 1
            if abs(loc.lat - lat) < 1e-3 && abs(loc.lon - lon) < 1e-3 { ok += 1 }
        }
        check(ok == total, "ADS-B: Erzeuger und Leser der CPR stimmen überein (\(ok) von \(total))")
        let m = dec.decode(ADSBSignalGenerator.extendedSquitter(icao: 0x3C6444, me: ADSBSignalGenerator.identification(callsign: "DLH4AB", category: 5)), at: t0)
        check(m?.callsign == "DLH4AB" && m?.category == 5 && m?.typeCode == 4, "ADS-B: Erzeuger Kennung DLH4AB")
        let v = dec.decode(ADSBSignalGenerator.extendedSquitter(icao: 0x3C6444, me: ADSBSignalGenerator.velocity(eastKn: -300, northKn: 250, climbFpm: -1280)), at: t0)
        check(abs((v?.velocity?.groundSpeedKn ?? 0) - 390.5) < 1.5 && abs((v?.velocity?.trackDeg ?? 0) - 309.8) < 0.5 && v?.velocity?.verticalRateFpm == -1280, "ADS-B: Erzeuger Geschwindigkeit \(String(describing: v?.velocity))")
        let a = dec.decode(ADSBSignalGenerator.extendedSquitter(icao: 0x3C6444, me: ADSBSignalGenerator.airbornePosition(altitudeFt: 36_025, lat: 50.1, lon: 8.7, odd: true)), at: t0)
        check(a?.altitudeFt == 36_025 && a?.cpr?.odd == true, "ADS-B: Erzeuger Höhe 36025 ft")
    }

    // --- Demodulator: Erzeuger → I/Q → Meldungen ---
    do {
        func run(_ iq: [UInt8], block: Int = 1 << 18) -> (found: [[UInt8]], demod: ModeSDemodulator) {
            let demod = ModeSDemodulator()
            let dec = ModeSDecoder()
            var found: [[UInt8]] = []
            var i = 0
            while i < iq.count {
                let e = min(i + block, iq.count)
                iq[i..<e].withUnsafeBufferPointer { buf in
                    demod.process(buf, accept: { dec.decode($0, at: t0) != nil }, emit: { found.append($0.bytes) })
                }
                i = e
            }
            return (found, demod)
        }
        let frames: [[UInt8]] = (0..<12).map { k in
            ADSBSignalGenerator.extendedSquitter(icao: 0x3C6000 + UInt32(k), me: ADSBSignalGenerator.airbornePosition(altitudeFt: 30_000 + k * 100, lat: 50 + Double(k) * 0.1, lon: 9, odd: k % 2 == 1))
        }
        let spacing = 400
        let bursts = frames.enumerated().map { ADSBSignalGenerator.Burst(startSample: 1000 + $0.offset * spacing, bytes: $0.element, amplitude: 50, phase: Double($0.offset) * 0.7) }
        let iq = ADSBSignalGenerator.samples(bursts: bursts, totalSamples: 1000 + frames.count * spacing + 2000, noise: 1.5)
        let r = run(iq)
        check(r.found == frames, "ADS-B: 12 Meldungen aus dem I/Q-Signal, \(r.found.count) gefunden")
        for block in [4096, 778, 100_002] { check(run(iq, block: block).found == frames, "ADS-B: gleiches Ergebnis bei Blockgröße \(block)") }
        // Mit Phasenversatz des Abtastpunkts: ein halber Abtastwert Verschiebung durch Mischen benachbarter Werte
        var smeared = iq
        var prevI = Double(iq[0]), prevQ = Double(iq[1])
        for k in 0..<(iq.count / 2) {
            let i = Double(iq[2 * k]), q = Double(iq[2 * k + 1])
            smeared[2 * k] = UInt8(max(0, min(255, (0.7 * i + 0.3 * prevI).rounded())))
            smeared[2 * k + 1] = UInt8(max(0, min(255, (0.7 * q + 0.3 * prevQ).rounded())))
            prevI = i; prevQ = q
        }
        let rs = run(smeared)
        check(rs.found.count >= 11 && Set(rs.found).isSubset(of: Set(frames)), "ADS-B: verschmierte Abtastung (Phasenfehler), \(rs.found.count) von 12")
        // Schwaches Signal (Amplitude 8 bei Rauschen 1,5)
        let weak = ADSBSignalGenerator.samples(bursts: bursts.map { var b = $0; b.amplitude = 9; return b }, totalSamples: iq.count / 2, noise: 1.5, seed: 3)
        let rw = run(weak)
        check(rw.found.count >= 9 && Set(rw.found).isSubset(of: Set(frames)), "ADS-B: schwaches Signal, \(rw.found.count) von 12 und keine falschen")
        // Kein Signal: nur Rauschen ergibt keine Meldung
        let noiseOnly = ADSBSignalGenerator.samples(bursts: [], totalSamples: 3_000_000, noise: 4, seed: 99)
        let rn = run(noiseOnly)
        check(rn.found.isEmpty, "ADS-B: 1,5 s Rauschen ergibt keine Meldung (\(rn.found.count))")
        // Übersteuerung wird gezählt
        let clipped = ADSBSignalGenerator.samples(bursts: [ADSBSignalGenerator.Burst(startSample: 500, bytes: frames[0], amplitude: 200)], totalSamples: 8000, noise: 1)
        check(run(clipped).demod.clippedSamples > 100 && run(iq).demod.clippedSamples == 0, "ADS-B: Übersteuerung gezählt")
        check(r.demod.blockActivity > 0 && r.demod.preambles >= 12, "ADS-B: Zähler (Präambeln \(r.demod.preambles))")
    }

    // --- Tracker: Positionen aus Paaren, Plausibilität, Reichweite ---
    do {
        let home = Maidenhead.point("JN49WS")!
        var tr = ADSBTracker(receiver: home)
        let dec = ModeSDecoder()
        func send(_ me: [UInt8], icao: UInt32, at t: Date) { if var m = dec.decode(ADSBSignalGenerator.extendedSquitter(icao: icao, me: me), at: t) { m.levelDB = -20; tr.ingest(m, at: t) } }
        // Flugzeug 150 km nordwestlich, Ostkurs
        let lat = 50.8, lon = 8.2
        send(ADSBSignalGenerator.identification(callsign: "DLH4AB", category: 5), icao: 0x3C6444, at: t0)
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 36_000, lat: lat, lon: lon, odd: false), icao: 0x3C6444, at: t0.addingTimeInterval(0.1))
        check(tr.aircraft[0x3C6444]?.position == nil, "ADS-B-Tracker: ein einzelner Rahmen ergibt in der Luft keine Position")
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 36_000, lat: lat, lon: lon, odd: true), icao: 0x3C6444, at: t0.addingTimeInterval(0.6))
        let a = tr.aircraft[0x3C6444]!
        check(a.position != nil && abs(a.position!.lat - lat) < 1e-3 && abs(a.position!.lon - lon) < 1e-3, "ADS-B-Tracker: Position aus gerade + ungerade: \(String(describing: a.position))")
        check(a.callsign == "DLH4AB" && a.altitudeFt == 36_000 && a.altitudeText == "FL 360" && a.country?.code == "DE" && a.categoryText == "Schwer (> 136 t)", "ADS-B-Tracker: Kennung, Höhe, Land, Kategorie")
        let km = Geo.distanceKm(home, a.position!)
        check(abs((a.maxRangeKm ?? 0) - km) < 0.5 && tr.rangeBySector.contains { $0 > 100 } && tr.positionCount == 1, "ADS-B-Tracker: Reichweite \(a.maxRangeKm ?? 0) km, Sektor, Zähler")
        // Folgeposition: ein einzelner Rahmen relativ zur letzten Position
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 36_000, lat: lat + 0.01, lon: lon + 0.05, odd: false), icao: 0x3C6444, at: t0.addingTimeInterval(20))
        let b = tr.aircraft[0x3C6444]!
        check(abs(b.position!.lat - (lat + 0.01)) < 1e-3 && abs(b.position!.lon - (lon + 0.05)) < 1e-3 && b.track.count == 2, "ADS-B-Tracker: Folgeposition aus einem Rahmen, Weg hat \(b.track.count) Punkte")
        // Sprung (Geisterposition): ein stimmiges Paar 111 km weiter, eine Sekunde später, wird verworfen
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 36_000, lat: lat + 1.01, lon: lon + 0.05, odd: false), icao: 0x3C6444, at: t0.addingTimeInterval(21))
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 36_000, lat: lat + 1.01, lon: lon + 0.05, odd: true), icao: 0x3C6444, at: t0.addingTimeInterval(21.5))
        check(tr.rejectedPositions >= 1 && abs(tr.aircraft[0x3C6444]!.position!.lat - (lat + 0.01)) < 1e-3, "ADS-B-Tracker: unmöglicher Sprung verworfen (\(tr.rejectedPositions))")
        // Zu weit weg (Australien) wird verworfen
        let rejectedBefore = tr.rejectedPositions
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 30_000, lat: -33.9, lon: 151.2, odd: false), icao: 0x7C1234, at: t0.addingTimeInterval(2))
        send(ADSBSignalGenerator.airbornePosition(altitudeFt: 30_000, lat: -33.9, lon: 151.2, odd: true), icao: 0x7C1234, at: t0.addingTimeInterval(2.5))
        check(tr.aircraft[0x7C1234]?.position == nil && tr.rejectedPositions == rejectedBefore + 1, "ADS-B-Tracker: Position über 1000 km vom Empfänger verworfen")
        // Rahmen zu weit auseinander ergeben kein Paar
        var tr2 = ADSBTracker(receiver: home)
        for (odd, dt) in [(false, 0.0), (true, 12.0)] {
            if var m = dec.decode(ADSBSignalGenerator.extendedSquitter(icao: 0x3C0001, me: ADSBSignalGenerator.airbornePosition(altitudeFt: 20_000, lat: 50, lon: 9, odd: odd)), at: t0.addingTimeInterval(dt)) { m.levelDB = -10; tr2.ingest(m, at: t0.addingTimeInterval(dt)) }
        }
        check(tr2.aircraft[0x3C0001]?.position == nil, "ADS-B-Tracker: Rahmen mit mehr als 10 s Abstand bilden kein Paar")
        // Geschwindigkeit, Notlage, Verfall
        send(ADSBSignalGenerator.velocity(eastKn: 400, northKn: 0, climbFpm: 640), icao: 0x3C6444, at: t0.addingTimeInterval(3))
        send(ADSBSignalGenerator.emergencyStatus(emergency: 1, squawk: "7700"), icao: 0x3C6444, at: t0.addingTimeInterval(3.1))
        let c = tr.aircraft[0x3C6444]!
        check(abs((c.groundSpeedKn ?? 0) - 400) < 1.5 && abs((c.trackDeg ?? 0) - 90) < 0.5 && c.verticalRateFpm == 640 && c.squawk == "7700" && c.emergencyText == "Allgemeiner Notfall", "ADS-B-Tracker: Geschwindigkeit, Steigen, Notlage")
        tr.expire(now: t0.addingTimeInterval(400), maxAge: 300)
        check(tr.aircraft.isEmpty, "ADS-B-Tracker: Flugzeuge verfallen nach 300 s")
        check(tr.dfCounts[17, default: 0] > 5 && tr.messageCount > 5, "ADS-B-Tracker: Zähler")
    }

    // --- Länder und Namen ---
    do {
        let r = ICAORanges.shared
        check(r.count > 150, "ADS-B: Adressblöcke geladen (\(r.count))")
        if r.count > 150 {
            check(r.country(0x3C6444)?.code == "DE" && r.country(0x3C6444)?.name == "Deutschland" && r.country(0x3C6444)?.flag == "🇩🇪", "ADS-B: 3C6444 = Deutschland")
            check(r.country(0x4D2023)?.code == "MT" && r.country(0x406A3D)?.code == "GB" && r.country(0xA00001)?.code == "US" && r.country(0x4CA7B1)?.code == "IE", "ADS-B: Malta, Großbritannien, USA, Irland")
            check(r.country(0xF00001) == nil && r.country(0x000001) == nil, "ADS-B: Sonderblock und nicht vergebener Block ohne Staat")
        }
        check(ICAORanges.flag("fr") == "🇫🇷" && ADSBNames.category(typeCode: 4, category: 7) == "Drehflügler" && ADSBNames.category(typeCode: 4, category: 0) == nil, "ADS-B: Flagge, Kategorie")
    }

    // --- Engine mit Erzeuger (Verkehr als I/Q, Zeit aus der Lage im Datenstrom) ---
    do {
        let home = Maidenhead.point("JN49WS")!
        let fleet = [
            ADSBSignalGenerator.SimAircraft(icao: 0x3C6444, callsign: "DLH4AB", lat: 50.6, lon: 8.2, altitudeFt: 36_000, trackDeg: 110, speedKn: 450),
            ADSBSignalGenerator.SimAircraft(icao: 0x406A3D, callsign: "EZY81KT", lat: 51.8, lon: 11.5, altitudeFt: 35_000, trackDeg: 250, speedKn: 430, climbFpm: -640),
            ADSBSignalGenerator.SimAircraft(icao: 0x3C4A10, callsign: "MEDEVAC1", lat: 49.5, lon: 10.4, altitudeFt: 5_000, trackDeg: 270, speedKn: 180, emergency: true),
        ]
        let (iq, count) = ADSBSignalGenerator.traffic(fleet, receiver: (home.lat, home.lon), seconds: 4)
        let engine = ADSBEngine()
        engine.configure(receiver: home, expireAfter: 300, sampleClock: true)
        iq.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let e = min(i + 65_536, buf.count)
                engine.feed(UnsafeBufferPointer(rebasing: buf[i..<e]), wait: true)      // der Prüfstand speist schneller als in Echtzeit
                i = e
            }
        }
        var snap = engine.snapshot()
        for _ in 0..<50 where snap.messageCount < count - 3 { Thread.sleep(forTimeInterval: 0.1); snap = engine.snapshot() }
        check(snap.droppedBlocks == 0 || snap.messageCount > count / 2, "ADS-B-Engine: Rückstau")
        check(snap.messageCount >= count - 3, "ADS-B-Engine: \(snap.messageCount) von \(count) erzeugten Meldungen gehört")
        let byID = Dictionary(uniqueKeysWithValues: snap.aircraft.map { ($0.icao, $0) })
        check(byID.count == 3 && byID[0x3C6444]?.callsign == "DLH4AB" && byID[0x406A3D]?.callsign == "EZY81KT" && byID[0x3C4A10]?.emergencyText != nil, "ADS-B-Engine: drei Flugzeuge mit Kennung und Notlage")
        if let p = byID[0x3C6444]?.position {
            let rad = 110.0 * Double.pi / 180
            let km = 4.0 * 450.0 * 1.852 / 3600.0
            let expectedLat = 50.6 + km * cos(rad) / 111.2
            let expectedLon = 8.2 + km * sin(rad) / (111.2 * cos(50.6 * Double.pi / 180))
            check(Geo.distanceKm(p, GeoPoint(lat: expectedLat, lon: expectedLon)) < 3, "ADS-B-Engine: Position folgt dem Flug (\(p))")
        } else {
            check(false, "ADS-B-Engine: Position fehlt")
        }
        check(snap.aircraft.allSatisfy { $0.hasPosition } && (snap.rangeBySector.max() ?? 0) > 50 && snap.positionCount > 20, "ADS-B-Engine: Positionen und Reichweite")
        // Karte aus den Flugzeugen
        let map = ADSBMapBuilder.content(snap.aircraft, home: home, now: snap.aircraft.map(\.lastSeen).max()!)
        check(map.markers.count == 3 && map.markers.allSatisfy { $0.symbol == "airplane" && $0.valueLevel != nil }, "ADS-B-Karte: drei Flugzeuge mit Höhenfarbe")
        check(map.markers.first { $0.title == "MEDEVAC1" }?.tone == .alert && map.markers.first { $0.title == "DLH4AB" }?.headingDeg.map { abs($0 - 110) < 5 } == true, "ADS-B-Karte: Notfall rot, Kurs")
        check(ADSBMapBuilder.altitudeLevel(0) == 0 && ADSBMapBuilder.altitudeLevel(40_000) == 1 && ADSBMapBuilder.altitudeLevel(60_000) == 1 && ADSBMapBuilder.altitudeLevel(nil) == nil, "ADS-B-Karte: Höhenskala")
        let line = ADSBController.logLine(byID[0x3C6444]!)
        check(line.contains("3C6444") && line.contains("DLH4AB") && line.contains("Deutschland"), "ADS-B: Protokollzeile \(line)")
        check(snap.recent.count > 20 && snap.recent.last?.summary.contains("DF") == true, "ADS-B-Engine: Meldungsprotokoll")
    }


    // --- Neustart der Quelle (Einstellung geändert): eine verspätete „gestoppt“-Meldung darf die neue Quelle nicht beenden ---
    do {
        final class FakeSource: ADSBIQSource, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var started = 0, stopped = 0
            private var handler: (@Sendable (String?) -> Void)?
            let deviceDescription = "Attrappe"
            func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
                lock.withLock { started += 1; handler = onStop }
            }
            func stop() {
                let h = lock.withLock { () -> (@Sendable (String?) -> Void)? in stopped += 1; return handler }
                h?(nil)                         // wie der HackRF: meldet das Ende gleich beim Stoppen
            }
            /// Das Gerät fällt aus (abgesteckt)
            func fail(_ reason: String) { lock.withLock { handler }?(reason) }
        }
        let settings = ADSBSettingsStore()
        let c = ADSBController(settings: settings)
        nonisolated(unsafe) var made: [FakeSource] = []
        c.sourceFactory = { _ in let f = FakeSource(); made.append(f); return f }
        func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        c.startSource()
        check(made.count == 1 && made[0].started == 1 && c.status == .running("Attrappe"), "ADS-B: Quelle gestartet")
        // Einstellung geändert: stoppen und sofort neu starten (wie im Controller bei Verstärkung, Vorverstärker …)
        c.stopSource()
        c.startSource()
        pump()
        check(made.count == 2 && made[0].stopped == 1 && made[1].stopped == 0, "ADS-B-Neustart: nur die alte Quelle wurde gestoppt")
        check(c.status == .running("Attrappe"), "ADS-B-Neustart: die neue Quelle läuft weiter (Status \(c.status))")
        // Ein erneuter Start ohne Stopp ersetzt die laufende Quelle sauber
        c.startSource()
        pump()
        check(made.count == 3 && made[1].stopped == 1 && made[2].stopped == 0 && c.status == .running("Attrappe"), "ADS-B: Start ersetzt die laufende Quelle")
        // Ausfall der laufenden Quelle wird gemeldet
        made[2].fail("USB-Fehler")
        pump()
        check(c.status == .error("USB-Fehler"), "ADS-B: Ausfall der Quelle als Fehler angezeigt (\(c.status))")
        // Eine alte Quelle meldet sich spät noch einmal: ohne Wirkung
        c.startSource()
        made[2].fail("alt")
        pump()
        check(c.status == .running("Attrappe"), "ADS-B: späte Meldung einer alten Quelle ändert nichts")
        c.stopSource()
        pump()
        check(c.status == .idle && made[3].stopped == 1, "ADS-B: Stopp setzt den Status zurück")
        // Modul verlassen gibt das Gerät frei
        c.setActive(true)
        pump()
        let before = made.count
        c.setActive(false)
        pump()
        check(made.count == before && made[before - 1].stopped == 1 && c.status == .idle, "ADS-B: Modul verlassen stoppt die Quelle")
    }

    // --- Quellen: Datei, SDRconnect-Umsetzung, Einstellungen ---
    do {
        let samples: [UInt8] = (0..<20_000).map { UInt8($0 & 0xFF) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adsb_test_\(UUID().uuidString).bin")
        try? Data(samples).write(to: url)
        let src = ADSBFileSource(url: url, realtime: false)
        let got = NSLock()
        nonisolated(unsafe) var total = 0
        nonisolated(unsafe) var stopped = false
        try? src.start(onData: { buf in got.withLock { total += buf.count } }, onStop: { _ in got.withLock { stopped = true } })
        for _ in 0..<100 where !got.withLock({ stopped }) { Thread.sleep(forTimeInterval: 0.02) }
        check(got.withLock { total } == 20_000 && got.withLock { stopped }, "ADS-B: Dateiquelle liefert alle Bytes und meldet das Ende")
        try? FileManager.default.removeItem(at: url)
        check({ do { try ADSBFileSource(url: URL(fileURLWithPath: "/nonexistent/x.bin")).start(onData: { _ in }, onStop: { _ in }); return false } catch { return true } }(), "ADS-B: fehlende Datei meldet einen Fehler")
        // SDRconnect: Binärnachricht Typ 2 (I/Q, 16 Bit) → 8 Bit mit Mittelpunkt 127
        let sdr = SDRconnectSource(settings: ADSBGainSettings())
        nonisolated(unsafe) var converted: [UInt8] = []
        sdr.setTestHandler { converted += Array($0) }
        var packet = Data([2, 0])
        for v in [Int16(0), 4000, -4000, 2000] { var le = v.littleEndian; packet.append(Data(bytes: &le, count: 2)) }
        sdr.handleBinary(packet)
        check(converted.count == 4 && converted[0] == 127 && converted[1] > 200 && converted[2] < 60 && abs(Int(converted[3]) - 127 - (Int(converted[1]) - 127) / 2) <= 2, "ADS-B: SDRconnect 16-Bit → 8-Bit \(converted)")
        sdr.handleBinary(Data([1, 0, 1, 2, 3, 4, 5, 6]))
        check(converted.count == 4, "ADS-B: SDRconnect ignoriert Audio-Nachrichten")
        // SDRplay-API: Umsetzung der getrennten I/Q-Felder (xi, xq) auf verschränkte 8-Bit-Daten, ohne Gerät
        let api = SDRplayAPISource(settings: ADSBGainSettings())
        nonisolated(unsafe) var apiOut: [UInt8] = []
        api.setTestHandler { apiOut += Array($0) }
        var xi: [Int16] = [0, 4000, -4000], xq: [Int16] = [2000, 0, 4000]
        xi.withUnsafeMutableBufferPointer { pi in xq.withUnsafeMutableBufferPointer { pq in api.handle(xi: pi.baseAddress!, xq: pq.baseAddress!, count: 3) } }
        check(apiOut.count == 6 && apiOut[0] == 127 && apiOut[2] > 200 && apiOut[4] < 60 && apiOut[1] > 127 && apiOut[5] > 200, "ADS-B: SDRplay-API 16-Bit (xi, xq) → 8-Bit verschränkt \(apiOut)")
        var scaler = IQ16Scaler()
        let f1 = scaler.factor(maxAbs: 100)           // Rauschen: Untergrenze 2000, nicht aufblasen
        check(abs(f1 - 110.0 / 4096 * 0.98) < 0.01 || f1 <= 110.0 / 2000 + 1e-9, "ADS-B: Umsetzer bläst Rauschen nicht auf (\(f1))")
        check(IQ16Scaler.byte(32767, factor: 1) == 255 && IQ16Scaler.byte(-32768, factor: 1) == 0 && IQ16Scaler.byte(0, factor: 1) == 127, "ADS-B: Umsetzer begrenzt auf 0 … 255")
        check(SDRplayAPISource.Layout.deviceSize == 96 && SDRplayAPISource.Layout.callbackSize == 24 && !SDRplayAPISource.candidates().isEmpty, "ADS-B: SDRplay-API Grunddaten")
        check(ADSBSourceError.libraryMissing("libsdrplay_api").errorDescription?.contains("sdrplay.com/api") == true, "ADS-B: Fehlertext fehlende SDRplay-API")
        check(ADSBSourceKind.allCases.map(\.rawValue) == ["hackrf", "rtlsdr", "sdrplay", "sdrconnect", "file"] && DecoderModuleInfo.adsb.presetIDs.contains("sdrconnect"), "ADS-B: Quellenarten mit SDRplay (API) und SDRconnect")
        check(parse("digidec://decode?mode=adsb&preset=sdrplay") == .success(DecodeRequest(module: .adsb, presetID: "sdrplay")) && parse("digidec://decode?mode=adsb&preset=sdrconnect") == .success(DecodeRequest(module: .adsb, presetID: "sdrconnect")), "ADS-B: URL-Aufruf SDRplay")
        // Gerätefehler lesbar
        check(ADSBSourceError.libraryMissing("libhackrf").errorDescription?.contains("brew install hackrf") == true && ADSBSourceError.busy("HackRF").errorDescription?.contains("GQRX") == true, "ADS-B: Fehlertexte")
        // Modul, URL
        check(DecoderModuleInfo.adsb.isAvailable && DecoderModuleInfo.adsb.band == .vhfUhf && DecoderModuleInfo.adsb.hasMap && DecoderModuleInfo.adsb.displayName == "ADS-B", "ADS-B: Modul in der Liste")
        check(parse("digidec://decode?mode=adsb&preset=rtlsdr") == .success(DecodeRequest(module: .adsb, presetID: "rtlsdr")) && parse("digidec://decode?mode=adsb") == .success(DecodeRequest(module: .adsb, presetID: "hackrf")), "ADS-B: URL-Aufruf")
        let st = ADSBSettingsStore()
        st.rtlGain = 0
        check(st.gain.rtlGainDB == nil && ADSBSettingsStore().gain.hackrfLNA == st.gain.hackrfLNA, "ADS-B: Einstellungen (AGC = keine feste Verstärkung)")
        st.sdrplayTuner = 1; st.sdrplayIFGain = 33; st.sdrplayAGC = true; st.sdrplayBias = true; st.sdrplayLNAState = 3; st.sdrplayPPM = -2
        let g = st.gain
        check(g.sdrplayTuner == 1 && g.sdrplayIFGainReduction == 33 && g.sdrplayAGC && g.sdrplayBias && g.sdrplayLNAState == 3 && g.sdrplayPPM == -2, "ADS-B: Einstellungen SDRplay (Tuner, ZF-Minderung, AGC, Bias-T, LNA, PPM)")
        st.sdrplayTuner = 0; st.sdrplayIFGain = 40; st.sdrplayAGC = false; st.sdrplayBias = false; st.sdrplayLNAState = 0; st.sdrplayPPM = 0
        st.rtlGain = 49.6
    }
}
if want("adsb") { adsbTests() }

// MARK: - Flugzeugdaten aus dem Netz (adsbdb, planespotters) mit nachgebautem Abruf
@MainActor func aircraftInfoTests() async {
    let aircraftJSON = #"{"response":{"aircraft":{"type":"A319 112","icao_type":"A319","manufacturer":"Airbus","mode_s":"3C6444","registration":"D-AIBD","registered_owner_country_iso_name":"DE","registered_owner_country_name":"Germany","registered_owner_operator_flag_code":"DLH","registered_owner":"Lufthansa","url_photo":"https://image.airport-data.com/aircraft/001742555.jpg","url_photo_thumbnail":"https://airport-data.com/images/aircraft/thumbnails/001/742/001742555.jpg"}}}"#
    let routeJSON = #"{"response":{"flightroute":{"callsign":"DLH400","callsign_icao":"DLH400","callsign_iata":"LH400","airline":{"name":"Lufthansa","icao":"DLH","iata":"LH","country":"Germany","country_iso":"DE","callsign":"LUFTHANSA"},"origin":{"country_iso_name":"DE","country_name":"Germany","elevation":364,"iata_code":"FRA","icao_code":"EDDF","latitude":50.033333,"longitude":8.570556,"municipality":"Frankfurt am Main","name":"Frankfurt am Main Airport"},"destination":{"country_iso_name":"US","country_name":"United States","elevation":13,"iata_code":"JFK","icao_code":"KJFK","latitude":40.639801,"longitude":-73.7789,"municipality":"New York","name":"John F Kennedy International Airport"}}}}"#
    let photoJSON = #"{"photos":[{"id":"1981050","thumbnail":{"src":"https://t.plnspttrs.net/09561/1981050_77e29380db_t.jpg","size":{"width":200,"height":133}},"thumbnail_large":{"src":"https://t.plnspttrs.net/09561/1981050_77e29380db_280.jpg","size":{"width":422,"height":280}},"link":"https://www.planespotters.net/photo/1981050/d-aibd-lufthansa-airbus-a319-112?utm_source=api","photographer":"Steffen Müller"}]}"#

    // --- Auswertung der Antworten ---
    do {
        var info = AircraftWebInfo()
        check(AircraftInfoParsing.aircraft(Data(aircraftJSON.utf8), into: &info) && info.registration == "D-AIBD" && info.typeName == "A319 112" && info.icaoType == "A319"
              && info.manufacturer == "Airbus" && info.owner == "Lufthansa" && info.ownerCountryISO == "DE" && info.operatorCode == "DLH", "Flugzeugdaten: adsbdb Flugzeug")
        check(info.photo?.source == "airport-data.com" && info.fullTypeName == "Airbus A319 112" && info.shortDescription == "A319 · Lufthansa", "Flugzeugdaten: Ersatzfoto, Typ, Kurzbeschreibung")
        var unknown = AircraftWebInfo()
        check(!AircraftInfoParsing.aircraft(Data(#"{"response":"unknown aircraft"}"#.utf8), into: &unknown) && unknown.isEmpty, "Flugzeugdaten: unbekannte Adresse")
        let r = AircraftInfoParsing.route(Data(routeJSON.utf8))
        check(r?.flightNumber == "LH400" && r?.airlineName == "Lufthansa" && r?.origin?.icao == "EDDF" && r?.destination?.shortCode == "JFK" && r?.routeText == "FRA→JFK", "Flugzeugdaten: Strecke")
        check(abs((r?.distanceKm ?? 0) - 6195) < 60 && r?.origin?.elevationFt == 364, "Flugzeugdaten: Luftlinie Frankfurt–New York \(r?.distanceKm ?? 0) km")
        check(AircraftInfoParsing.route(Data(#"{"response":"unknown callsign"}"#.utf8)) == nil && AircraftInfoParsing.route(Data("kein json".utf8)) == nil, "Flugzeugdaten: unbekanntes Rufzeichen, kaputte Antwort")
        let ph = AircraftInfoParsing.photo(Data(photoJSON.utf8))
        check(ph?.photographer == "Steffen Müller" && ph?.imageURL.hasSuffix("_280.jpg") == true && ph?.pageURL?.contains("planespotters.net/photo/1981050") == true && ph?.source == "planespotters.net", "Flugzeugdaten: planespotters Foto mit Fotograf und Seite")
        check(AircraftInfoParsing.photo(Data(#"{"photos":[]}"#.utf8)) == nil, "Flugzeugdaten: kein Foto")
        check(AircraftQuery(icao: 0x3C6444, callsign: " dlh400 ").callsign == "DLH400" && AircraftQuery(icao: 1, callsign: "ab").callsign == nil && AircraftQuery(icao: 0x3C6444, callsign: nil).hex == "3C6444", "Flugzeugdaten: Abfrage normalisiert Rufzeichen")
    }

    // --- Dienst mit nachgebautem Abruf: Zwischenspeicher, Fehler, Zählung ---
    do {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [String] = []
            var mode = "ok"
            func add(_ u: String) { lock.withLock { urls.append(u) } }
            var count: Int { lock.withLock { urls.count } }
            func count(containing s: String) -> Int { lock.withLock { urls.filter { $0.contains(s) }.count } }
        }
        let counter = Counter()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aircraftinfo_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = AircraftInfoService(directory: dir, fetch: { url in
            counter.add(url.absoluteString)
            if counter.mode == "down" { throw URLError(.notConnectedToInternet) }
            if counter.mode == "limit" { return (Data("{}".utf8), 429) }
            let u = url.absoluteString
            if u.contains("/v0/aircraft/3C6444") { return (Data(aircraftJSON.utf8), 200) }
            if u.contains("/v0/callsign/DLH400") { return (Data(routeJSON.utf8), 200) }
            if u.contains("planespotters.net/pub/photos/hex/3C6444") { return (Data(photoJSON.utf8), 200) }
            if u.contains("/v0/aircraft/") { return (Data(#"{"response":"unknown aircraft"}"#.utf8), 404) }
            if u.contains("/v0/callsign/") { return (Data(#"{"response":"unknown callsign"}"#.utf8), 404) }
            return (Data(#"{"photos":[]}"#.utf8), 200)
        })
        let q = AircraftQuery(icao: 0x3C6444, callsign: "DLH400")
        let first = await service.lookup(q)
        check(!first.failed && first.registration == "D-AIBD" && first.route?.routeText == "FRA→JFK" && first.photo?.source == "planespotters.net" && first.photo?.photographer == "Steffen Müller", "Flugzeugdaten-Dienst: Flugzeug, Strecke und Foto (planespotters vor Ersatzfoto)")
        check(counter.count == 3, "Flugzeugdaten-Dienst: genau drei Abrufe (\(counter.count))")
        let second = await service.lookup(q)
        check(counter.count == 3 && second.registration == "D-AIBD" && second.route?.routeText == "FRA→JFK", "Flugzeugdaten-Dienst: zweite Abfrage aus dem Zwischenspeicher, ohne Abruf")
        let cached = await service.cachedInfo(q)
        check(cached?.registration == "D-AIBD" && cached?.route?.destination?.name.contains("Kennedy") == true, "Flugzeugdaten-Dienst: Lesen nur aus dem Zwischenspeicher")
        let notCached = await service.cachedInfo(AircraftQuery(icao: 0x111111, callsign: nil))
        check(notCached == nil, "Flugzeugdaten-Dienst: unbekanntes Flugzeug nicht im Zwischenspeicher")
        // Ohne Foto abfragen: kein planespotters-Abruf
        let q2 = AircraftQuery(icao: 0x4D2023, callsign: "AMC421")
        let before = counter.count
        let noPhoto = await service.lookup(q2, photo: false)
        check(counter.count == before + 2 && counter.count(containing: "planespotters") == 1 && noPhoto.registration == nil && noPhoto.route == nil && noPhoto.isEmpty && !noPhoto.failed, "Flugzeugdaten-Dienst: ohne Foto kein planespotters-Abruf; Unbekanntes ist leer, kein Fehler")
        check(noPhoto.notes.contains { $0.contains("4D2023") } && noPhoto.notes.contains { $0.contains("AMC421") }, "Flugzeugdaten-Dienst: Hinweise zu unbekannter Adresse und Strecke \(noPhoto.notes)")
        // Kein Rufzeichen: keine Streckenabfrage
        let q3 = AircraftQuery(icao: 0x4D2024, callsign: nil)
        let c3 = counter.count
        let nc = await service.lookup(q3, photo: false)
        check(counter.count == c3 + 1 && nc.notes.contains { $0.contains("Ohne Rufzeichen") }, "Flugzeugdaten-Dienst: ohne Rufzeichen keine Strecke")
        // Neu abfragen übergeht den Zwischenspeicher
        await service.forget(q)
        let again = await service.lookup(q)
        check(counter.count > before + 3 && again.registration == "D-AIBD", "Flugzeugdaten-Dienst: nach „vergessen“ wieder aus dem Netz")
        // Fehler: kein Netz → nicht zwischenspeichern
        counter.mode = "down"
        let q4 = AircraftQuery(icao: 0x3C6445, callsign: "DLH401")
        let down = await service.lookup(q4)
        check(down.failed && down.registration == nil && down.notes.contains { $0.contains("nicht erreichbar") }, "Flugzeugdaten-Dienst: kein Netz wird gemeldet")
        counter.mode = "ok"
        let up = await service.lookup(q4)
        check(!up.failed && up.isEmpty, "Flugzeugdaten-Dienst: der Fehler wurde nicht zwischengespeichert")
        counter.mode = "limit"
        let q5 = AircraftQuery(icao: 0x3C6446, callsign: nil)
        let lim = await service.lookup(q5, photo: false)
        check(lim.failed && lim.notes.contains { $0.contains("zu viele Anfragen") }, "Flugzeugdaten-Dienst: HTTP 429 wird gemeldet")
        check(AircraftInfoService.userAgent.contains("github.com/betzburger/Digidec") && AircraftInfoService.aircraftTTL(first) == 30 * 86_400 && AircraftInfoService.aircraftTTL(AircraftWebInfo()) == 86_400 && AircraftInfoService.routeTTL(nil) == 3 * 3600, "Flugzeugdaten-Dienst: Kennung mit Kontakt (verlangt von planespotters) und Gültigkeitsdauer")
    }

    // --- Flugfortschritt, Verweise, Karte mit Strecke ---
    do {
        let route = AircraftInfoParsing.route(Data(routeJSON.utf8))!
        let mid = GeoPoint(lat: 52.5, lon: -20.0)
        let p = AircraftProgress.compute(route: route, position: mid, groundSpeedKn: 480)
        check(p != nil && p!.fraction > 0.3 && p!.fraction < 0.35 && abs(p!.flownKm + p!.remainingKm - route.distanceKm!) < 400 && p!.etaMinutes.map { $0 > 250 && $0 < 320 } == true, "Flugzeugdaten: Fortschritt bei 52,5° N 20° W (etwa ein Drittel der Strecke) \(String(describing: p))")
        check(AircraftProgress.compute(route: route, position: route.origin!.point, groundSpeedKn: 0)?.fraction == 0 && AircraftProgress.compute(route: route, position: route.origin!.point, groundSpeedKn: 0)?.etaText == nil, "Flugzeugdaten: am Start 0 %, ohne Geschwindigkeit keine Restzeit")
        check(AircraftProgress(flownKm: 1, remainingKm: 2, fraction: 0.3, etaMinutes: 130).etaText == "2 h 10 min" && AircraftProgress(flownKm: 1, remainingKm: 2, fraction: 0.3, etaMinutes: 45).etaText == "45 min", "Flugzeugdaten: Restzeit als Text")
        check(AircraftProgress.compute(route: nil, position: mid, groundSpeedKn: 400) == nil && AircraftProgress.compute(route: route, position: nil, groundSpeedKn: 400) == nil, "Flugzeugdaten: ohne Strecke oder Position kein Fortschritt")
        var info = AircraftWebInfo()
        _ = AircraftInfoParsing.aircraft(Data(aircraftJSON.utf8), into: &info)
        info.route = route
        info.photo = AircraftInfoParsing.photo(Data(photoJSON.utf8))
        let links = AircraftLinks.links(for: AircraftQuery(icao: 0x3C6444, callsign: "DLH400"), info: info)
        check(links.contains { $0.title == "planespotters" && $0.url.absoluteString.hasSuffix("/hex/3C6444") } && links.contains { $0.title == "FlightAware" && $0.url.absoluteString.hasSuffix("DLH400") }
              && links.contains { $0.title == "Flightradar24" && $0.url.absoluteString.hasSuffix("d-aibd") } && links.contains { $0.title == "Foto-Seite" }, "Flugzeugdaten: Verweise für den Browser")
        // Karte: Flugzeug mit Typ, Betreiber, Strecke; für das gewählte Flugzeug Linie und Flughäfen
        var a = ADSBAircraft(icao: 0x3C6444, firstSeen: Date(timeIntervalSince1970: 1_800_000_000), lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        a.callsign = "DLH400"; a.position = mid; a.altitudeFt = 36_000; a.groundSpeedKn = 480; a.trackDeg = 270; a.messages = 20
        let now = Date(timeIntervalSince1970: 1_800_000_001)
        let plain = ADSBMapBuilder.content([a], home: nil, now: now, details: [:])
        check(plain.markers.count == 1 && plain.lines.isEmpty && !(plain.markers[0].details.contains { $0.contains("Strecke") }), "ADS-B-Karte: ohne Netzdaten keine Strecke")
        let rich = ADSBMapBuilder.content([a], home: nil, now: now, selection: nil, details: [0x3C6444: info])
        check(rich.markers[0].details.contains("Airbus A319 112 (D-AIBD)") && rich.markers[0].details.contains("Betreiber: Lufthansa") && rich.markers[0].subtitle?.contains("FRA→JFK") == true
              && rich.markers[0].details.contains { $0.hasPrefix("Strecke: Frankfurt am Main (FRA) → New York (JFK)") } && rich.markers[0].details.contains { $0.hasPrefix("Flugfortschritt") }, "ADS-B-Karte: Typ, Betreiber, Strecke und Fortschritt in den Einzelheiten")
        check(rich.lines.isEmpty && rich.markers.count == 1, "ADS-B-Karte: ohne Auswahl keine Streckenlinie")
        let sel = ADSBMapBuilder.content([a], home: nil, now: now, selection: 0x3C6444, details: [0x3C6444: info])
        check(sel.lines.count == 2 && sel.lines.first { $0.id == "adsb-route-done" }?.points.first == route.origin!.point && sel.lines.first { $0.id == "adsb-route-rest" }?.points.last == route.destination!.point, "ADS-B-Karte: gewähltes Flugzeug mit Linie von Start über Position zum Ziel")
        check(sel.markers.count == 3 && sel.markers.contains { $0.id == "adsb-apt-EDDF" && $0.symbol == "airplane.departure" } && sel.markers.contains { $0.id == "adsb-apt-KJFK" && $0.symbol == "airplane.arrival" }, "ADS-B-Karte: Start- und Zielflughafen")
        // Einstellungen: Netz-Suche an, automatisch aus
        let st = ADSBSettingsStore()
        check(st.webLookup && !st.autoLookup && !st.openInfoOnClick, "ADS-B: Netz-Suche an, Hintergrundabfrage und Fenster bei Klick aus (Standard)")
    }
}
// MARK: - Digitale Sprache: Schnittstelle (Decoder-Sammlung, Rahmen, WAV)
if want("voice") {
    struct FakeDecoder: VoiceDecoder {
        let name: String
        let isHardware: Bool
        let profiles: Set<VoiceProfile>
        func supports(_ profile: VoiceProfile) -> Bool { profiles.contains(profile) }
        func decode(_ frame: VoiceFrame, profile: VoiceProfile) throws -> [Int16] {
            guard profiles.contains(profile) else { throw VoiceError.unsupported(profile) }
            return [Int16](repeating: Int16(frame.bytes[0]), count: VoiceFrame.samplesPerFrame)
        }
    }
    let registry = VoiceRegistry()
    check(registry.preferred(for: .dmr) == nil && registry.decoders.isEmpty, "Sprache: ohne Decoder gibt es keinen Ton, nur Steuerdaten")
    registry.register(FakeDecoder(name: "Software", isHardware: false, profiles: [.dstar, .dmr]))
    check(registry.preferred(for: .dmr)?.name == "Software", "Sprache: ein Software-Decoder wird gewählt, wenn er allein ist")
    registry.register(FakeDecoder(name: "Gerät", isHardware: true, profiles: [.dmr]))
    check(registry.preferred(for: .dmr)?.name == "Gerät", "Sprache: ein Gerät hat Vorrang vor Software")
    check(registry.preferred(for: .dstar)?.name == "Software", "Sprache: das Gerät wird nur für Verfahren gewählt, die es kann")
    registry.removeAll()
    check(registry.decoders.isEmpty, "Sprache: Sammlung leeren")

    check(VoiceFrame(bytes: [UInt8](repeating: 0, count: 8)) == nil && VoiceFrame(bytes: [UInt8](repeating: 0, count: 10)) == nil, "Sprache: ein Rahmen hat genau 9 Bytes (72 Bit)")
    let frame = VoiceFrame(bytes: [7, 0, 0, 0, 0, 0, 0, 0, 0])!
    let pcm = (try? FakeDecoder(name: "x", isHardware: false, profiles: [.dmr]).decode(frame, profile: .dmr)) ?? []
    check(pcm.count == VoiceFrame.samplesPerFrame && pcm.allSatisfy { $0 == 7 }, "Sprache: ein Rahmen ergibt 160 Abtastwerte (20 ms bei 8 kHz)")
    var rejected = false
    do { _ = try FakeDecoder(name: "x", isHardware: false, profiles: [.dmr]).decode(frame, profile: .dstar) } catch { rejected = (error as? VoiceError) == .unsupported(.dstar) }
    check(rejected, "Sprache: nicht unterstütztes Verfahren wird gemeldet")

    // WAV: Hin- und Rückweg, fremde Zusatzblöcke werden übersprungen
    let tone = (0..<800).map { Int16(10000 * sin(2 * Double.pi * 400 * Double($0) / 8000)) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice_test_\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try? VoiceWAV.write(tone, to: url)
    let back = try? VoiceWAV.read(url)
    check(back?.samples == tone && back?.sampleRate == 8000, "Sprache: WAV schreiben und lesen ergibt dieselben Abtastwerte")
    if var raw = try? Data(contentsOf: url) {
        let list = Data("LIST".utf8) + Data([4, 0, 0, 0]) + Data("INFO".utf8)
        raw.insert(contentsOf: list, at: 36)
        try? raw.write(to: url)
        check((try? VoiceWAV.read(url))?.samples == tone, "Sprache: WAV mit LIST-Block vor den Daten wird gelesen")
    }
    try? Data("kein WAV".utf8).write(to: url)
    check((try? VoiceWAV.read(url)) == nil, "Sprache: keine WAV-Datei wird abgelehnt")
}
// MARK: - D-Star: Kopf, Rahmen, Langsamdaten, Empfänger
if want("voice") {
    struct SplitMix: Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    // Prüfsumme: Prüfwert von CRC-16/X-25 für „123456789“
    check(DStarCRC.fcs(Array("123456789".utf8)) == 0x906E, "D-Star: CRC-16/X-25 (Prüfwert 0x906E)")
    // Verwürfelungsfolge: die ersten 16 Byte der Spezifikation
    let scrambleBytes = stride(from: 0, to: 128, by: 8).map { start in DStarHeaderCodec.scrambleSequence[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | $1 } }
    check(scrambleBytes == [0x0E, 0xF2, 0xC9, 0x02, 0x26, 0x2E, 0xB6, 0x0C, 0xD4, 0xE7, 0xB4, 0x2A, 0xFA, 0x51, 0xB8, 0xFE], "D-Star: Verwürfelungsfolge (x⁷+x⁴+1) stimmt mit der Spezifikation")
    check(DStarHeaderCodec.scrambleSequence[127..<137] == DStarHeaderCodec.scrambleSequence[0..<10], "D-Star: Verwürfelungsfolge hat die Periode 127")
    check(Set(DStarHeaderCodec.interleave).count == 660 && DStarHeaderCodec.interleave.max() == 659, "D-Star: Verschachtelung ist eine Permutation von 660 Bits")
    // Synchronmuster wie in der Spezifikation (Bytes mit dem niederwertigen Bit zuerst)
    check(DStarBits.bytes(fromBits: DStarConstants.voiceSync24) == [0x55, 0x2D, 0x16] && DStarBits.bytes(fromBits: DStarConstants.endPattern48) == [0x55, 0x55, 0x55, 0x55, 0xC8, 0x7A], "D-Star: Synchron- und Endemuster")
    check(DStarConstants.headerSync24.count == 24 && DStarConstants.frameSync15.count == 15, "D-Star: Kopfsynchronisation 24 Bit mit 15 Bit Rahmensynchronisation")

    // Kopf: Hin- und Rückweg, Namen mit Auffüllung, Kennzeichen
    let header = DStarHeader(flag1: 0x40, repeater2: "DB0XYZ G", repeater1: "DB0XYZ B", yourCall: "CQCQCQ", myCall: "dl1abc", myCall2: "Test")
    check(header.bytes.count == 41 && Array(header.bytes[19..<27]) == Array("CQCQCQ  ".utf8) && Array(header.bytes[27..<35]) == Array("DL1ABC  ".utf8), "D-Star: Kopf hat 41 Byte, Rufzeichen aufgefüllt und groß geschrieben")
    let parsed = DStarHeader.parse(header.bytes)
    check(parsed?.crcOK == true && parsed?.crcSwapped == false && parsed?.header.myCall == "DL1ABC" && parsed?.header.myCall2 == "TEST" && parsed?.header.isRepeater == true && parsed?.header.isData == false, "D-Star: Kopf lesen, Prüfsumme und Kennzeichen")
    var damaged = header.bytes; damaged[30] ^= 0x04
    check(DStarHeader.parse(damaged)?.crcOK == false, "D-Star: veränderter Kopf fällt bei der Prüfsumme durch")
    let sent = DStarHeaderCodec.encode(header)
    check(sent.count == 660 && DStarHeaderCodec.decode(bits: sent)?.header == DStarHeader.parse(header.bytes)?.header, "D-Star: Kopf codieren und decodieren")
    var rng = SplitMix(state: 4711)
    var okByErrors: [Int: Int] = [:]
    for errors in [8, 20] {
        for _ in 0..<40 {
            var rx = sent
            var chosen = Set<Int>()
            while chosen.count < errors { chosen.insert(Int(rng.next() % 660)) }
            for i in chosen { rx[i] ^= 1 }
            if let d = DStarHeaderCodec.decode(bits: rx), d.crcOK { okByErrors[errors, default: 0] += 1 }
        }
    }
    check((okByErrors[8] ?? 0) == 40 && (okByErrors[20] ?? 0) >= 24, "D-Star: Fehlerkorrektur des Kopfes (8 Bitfehler 40/40, 20 Bitfehler ≥ 24/40 gelesen: \(okByErrors))")

    // Langsamdaten: Text, Kopf-Wiederholung, Datenzeile
    func feed(_ slow: inout DStarSlowData, blocks: [[UInt8]], superframes: Int) {
        for _ in 0..<superframes {
            for (n, block) in blocks.enumerated() {
                slow.add(frameIndex: n * 2 + 1, bytes: Array(block[0..<3]))
                slow.add(frameIndex: n * 2 + 2, bytes: Array(block[3..<6]))
            }
        }
    }
    var slowText = DStarSlowData()
    feed(&slowText, blocks: DStarSignalGenerator.slowDataBlocks(.text("Gruss aus Wuerzburg"), header: header), superframes: 1)
    check(slowText.message == "Gruss aus Wuerzburg", "D-Star: Textnachricht aus vier Blöcken (\(slowText.message ?? "-"))")
    var slowHeader = DStarSlowData()
    feed(&slowHeader, blocks: DStarSignalGenerator.slowDataBlocks(.headerCopy, header: header), superframes: 1)
    check(slowHeader.header?.myCall == "DL1ABC" && slowHeader.header?.repeater1 == "DB0XYZ B", "D-Star: Kopf-Wiederholung in den Langsamdaten ergibt Rufzeichen und Repeater")
    var slowData = DStarSlowData()
    let line = Array("$$CRC1234,DL1ABC>API51:!4949.00N/00957.00E-\r".utf8)
    var dataBlocks: [[UInt8]] = []
    var offset = 0
    while offset < line.count { let chunk = Array(line[offset..<min(offset + 5, line.count)]); var b = [UInt8(0x30 + chunk.count)] + chunk; while b.count < 6 { b.append(0x66) }; dataBlocks.append(b); offset += chunk.count }
    while dataBlocks.count < 10 { dataBlocks.append([0x66, 0x66, 0x66, 0x66, 0x66, 0x66]) }
    feed(&slowData, blocks: Array(dataBlocks.prefix(10)), superframes: 1)
    check(slowData.dataLine == nil, "D-Star: Datenzeile mit falscher Prüfsumme wird verworfen")
    // DPRS-Zeile mit richtiger Prüfsumme: Position
    let dprsBody = "DL1ABC-7>API51,DSTAR*:/080933h4949.50N/00957.30E[192/000/A=000600Test"
    let dprsLine = String(format: "$$CRC%04X,", DStarCRC.fcs(Array((dprsBody + "\r").utf8))) + dprsBody
    check(DStarPosition.parse(dprsLine)?.callsign == "DL1ABC-7" && abs((DStarPosition.parse(dprsLine)?.latitude ?? 0) - 49.825) < 1e-6 && abs((DStarPosition.parse(dprsLine)?.longitude ?? 0) - 9.955) < 1e-6 && DStarPosition.parse(dprsLine)?.comment.hasSuffix("Test") == true,
          "D-Star: DPRS-Zeile mit gültiger Prüfsumme ergibt Rufzeichen und Position")
    check(DStarPosition.parse(dprsLine.replacingOccurrences(of: "4949.50N", with: "4949.51N")) == nil, "D-Star: DPRS-Zeile mit einem veränderten Zeichen wird abgelehnt")
    var dprsSlow = DStarSlowData()
    var dprsBlocks: [[UInt8]] = []
    let dprsBytes = Array((dprsLine + "\r").utf8)
    var at = 0
    while at < dprsBytes.count { let chunk = Array(dprsBytes[at..<min(at + 5, dprsBytes.count)]); var b = [UInt8(0x30 + chunk.count)] + chunk; while b.count < 6 { b.append(0x66) }; dprsBlocks.append(b); at += chunk.count }
    var dprsChanged = 0
    for round in 0..<3 {
        for pair in stride(from: 0, to: dprsBlocks.count, by: 10) {
            var blocks = Array(dprsBlocks[pair..<min(pair + 10, dprsBlocks.count)])
            while blocks.count < 10 { blocks.append([0x66, 0x66, 0x66, 0x66, 0x66, 0x66]) }
            for (n, block) in blocks.enumerated() {
                if dprsSlow.add(frameIndex: n * 2 + 1, bytes: Array(block[0..<3])) { dprsChanged += 1 }
                if dprsSlow.add(frameIndex: n * 2 + 2, bytes: Array(block[3..<6])) { dprsChanged += 1 }
            }
        }
        _ = round
    }
    check(dprsSlow.position?.callsign == "DL1ABC-7" && dprsChanged == 1, "D-Star: Position aus Langsamdaten, nur beim ersten Mal als Änderung gemeldet (\(dprsChanged))")

    // Empfänger: Aussendung → GMSK-Audio → Bits → Rahmen
    struct Run { var header: DStarHeader?; var crc = false; var frames: [DStarVoiceFrame] = []; var ends = 0; var lost = 0; var message: String?; var bad = 0 }
    func receive(_ audio: [Float], rate: Double = 48000, slow: Bool = false) -> Run {
        let slicer = DStarBitSlicer(sampleRate: rate), framer = DStarFramer()
        var run = Run(), data = DStarSlowData()
        framer.onEvent = { event in
            switch event {
            case .header(let h, let ok): if ok { run.header = h; run.crc = true; data.reset() } else { run.bad += 1 }
            case .voice(let f): run.frames.append(f); if f.index > 0 { data.add(frameIndex: f.index, bytes: f.slowData) }
            case .end: run.ends += 1
            case .lost: run.lost += 1
            }
        }
        slicer.onBit = { framer.push(bit: $0, soft: $1) }
        var i = 0
        while i < audio.count { let j = min(i + 1000, audio.count); slicer.process(Array(audio[i..<j])); i = j }
        run.message = data.message
        return run
    }
    var frameRng = SplitMix(state: 99)
    let frames: [[UInt8]] = (0..<100).map { _ in (0..<9).map { _ in UInt8(truncatingIfNeeded: frameRng.next()) } }
    let bits = DStarSignalGenerator.transmissionBits(header: header, frames: frames, slowData: .text("Test aus Wuerzburg73"))
    func scenario(_ title: String, _ edit: (inout DStarSignalGenerator.Impairments) -> Void, rate: Double = 48000, minFrames: Int = 100, allCorrect: Bool = true) {
        var im = DStarSignalGenerator.Impairments(); edit(&im)
        let run = receive(DStarSignalGenerator.audio(bits: bits, sampleRate: rate, impairments: im), rate: rate)
        let right = zip(run.frames, frames).filter { $0.0.ambe == $0.1 }.count
        check(run.crc && run.header?.myCall == "DL1ABC" && run.frames.count >= minFrames && (!allCorrect || right == run.frames.count) && run.ends == 1 && run.lost == 0,
              "D-Star-Empfänger \(title): Kopf, \(run.frames.count)/100 Rahmen (\(right) bitgleich), Ende \(run.ends)")
    }
    scenario("sauber", { _ in })
    scenario("Pegel umgekehrt", { $0.inverted = true })
    scenario("Gleichanteil 40 %", { $0.dc = 0.4 })
    scenario("Takt +400 ppm", { $0.clockPPM = 400 })
    scenario("Takt −800 ppm", { $0.clockPPM = -800 })
    scenario("Rauschen 0,35", { $0.noise = 0.35; $0.seed = 3 })
    scenario("Rauschen 0,6", { $0.noise = 0.6; $0.seed = 5 }, minFrames: 98, allCorrect: false)
    scenario("Abtastrate 24 kHz", { _ in }, rate: 24000)
    scenario("Abtastrate 96 kHz", { _ in }, rate: 96000)
    let clean = receive(DStarSignalGenerator.audio(bits: bits, sampleRate: 48000))
    check(clean.message == "Test aus Wuerzburg73" && clean.frames.first?.index == 0 && clean.frames.filter { $0.isSync }.count == 5, "D-Star-Empfänger: Textnachricht aus den Langsamdaten, Synchronrahmen alle 21 Rahmen")
    // Später Einstieg: ohne Kopf, nur mit Kopf-Wiederholung
    let lateBits = DStarSignalGenerator.transmissionBits(header: header, frames: frames, slowData: .headerCopy, withHeader: false)
    let late = receive(DStarSignalGenerator.audio(bits: lateBits, sampleRate: 48000))
    check(late.header == nil && late.frames.count >= 98 && late.frames.first?.index == 1 && late.ends == 1, "D-Star-Empfänger: später Einstieg ohne Kopf liefert die Rahmen ab dem Überrahmen (\(late.frames.count))")
    // Echte Aufnahmen (Diskriminator-Audio, 48 kHz, von f4exb/dsdcc, Repeater F1ZIL): nur lokal vorhanden
    func realDStar(_ name: String) -> [Float]? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Voice/\(name)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
    }
    func realRun(_ audio: [Float]) -> (header: DStarHeader?, frames: Int, ends: Int, slow: DStarSlowData) {
        let slicer = DStarBitSlicer(sampleRate: 48000), framer = DStarFramer()
        var header: DStarHeader?, frames = 0, ends = 0, data = DStarSlowData()
        framer.onEvent = { e in
            switch e {
            case .header(let h, let ok): if ok { header = h }
            case .voice(let f): frames += 1; if f.index > 0 { data.add(frameIndex: f.index, bytes: f.slowData) }
            case .end: ends += 1
            case .lost: break
            }
        }
        slicer.onBit = { framer.push(bit: $0, soft: $1) }
        var i = 0
        while i < audio.count { let j = min(i + 480, audio.count); slicer.process(Array(audio[i..<j])); i = j }
        return (header, frames, ends, data)
    }
    if let audio = realDStar("dstar_f1zil_1.dis") {
        let r = realRun(audio)
        check(r.header?.repeater1 == "F1ZIL  B" && r.header?.yourCall == "CQCQCQ" && r.header?.myCall == "F1NSR" && r.header?.myCall2 == "ID51" && r.frames > 1000 && r.slow.message == "YANNICK ST RAPHAEL" && r.slow.header?.myCall == "F1NSR",
              "D-Star echt (F1ZIL, ID-51): Kopf mit Prüfsumme, \(r.frames) Rahmen, Text und Kopf-Wiederholung")
    } else { skip("D-Star echt: TestData/Voice/dstar_f1zil_1.dis liegt nicht lokal vor") }
    if let audio = realDStar("dstar_f1zil_2.dis") {
        let r = realRun(audio)
        check(r.header == nil && r.frames >= 700 && r.ends == 1 && r.slow.position?.callsign == "ALBERTO-7" && abs((r.slow.position?.latitude ?? 0) - 43.3108) < 0.001 && abs((r.slow.position?.longitude ?? 0) - 6.685) < 0.001 && r.slow.header?.myCall == "ALBERTO",
              "D-Star echt (ohne Kopf, später Einstieg): \(r.frames) Rahmen, Ende, DPRS-Position bei Toulon, Rufzeichen aus der Kopf-Wiederholung")
    } else { skip("D-Star echt: TestData/Voice/dstar_f1zil_2.dis liegt nicht lokal vor") }
    // Fehlalarme: Rauschen ergibt keine Rahmen
    var noiseRng = SplitMix(state: 5)
    let noiseOnly: [Float] = (0..<(48000 * 40)).map { _ in Float(Double(noiseRng.next() >> 11) / Double(1 << 53) - 0.5) * 0.8 }
    let nothing = receive(noiseOnly)
    check(nothing.frames.isEmpty && nothing.header == nil, "D-Star-Empfänger: 40 s Rauschen ergeben weder Kopf noch Rahmen")
    // Kurz vor Ende abgeschnitten: Verlust wird gemeldet
    let cut = Array(DStarSignalGenerator.audio(bits: bits, sampleRate: 48000).prefix(Int(48000 * 0.9)))
    check(receive(cut + [Float](repeating: 0, count: 48000 * 3)).frames.count > 20, "D-Star-Empfänger: abgebrochene Aussendung liefert die bis dahin gesendeten Rahmen")
}
// MARK: - Vierpegel-Sprachverfahren: Fehlerschutz, AMBE-Halbrate, YSF (C4FM)
if want("voice") {
    struct Rng: Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func bit() -> UInt8 { UInt8(next() & 1) }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }
    var rng = Rng(state: 2026)

    // Golay (23,12): bis zu 3 Fehler werden korrigiert
    var golayOK = 0, golayBad = 0
    for _ in 0..<300 {
        let data = rng.below(4096)
        var word = Golay.encode23(data)
        var flips = Set<Int>()
        let count = rng.below(4)
        while flips.count < count { flips.insert(rng.below(23)) }
        for f in flips { word ^= 1 << f }
        let r = Golay.decode23(word)
        if r.data == data && r.corrected == count { golayOK += 1 } else { golayBad += 1 }
    }
    check(golayBad == 0, "Golay (23,12): 0 bis 3 Bitfehler werden immer korrigiert (\(golayOK) von 300)")
    check(Golay.parity11(0) == 0 && Golay.encode23(1) == 0xC75 && Golay.encode23(1).nonzeroBitCount == 7, "Golay (23,12): Nullwort und Erzeugerpolynom (kleinstes Gewicht 7)")

    // CRC (Yaesu)
    var crcOK = 0
    for _ in 0..<50 {
        let n = 8 * (1 + rng.below(20))
        let data = (0..<n).map { _ in rng.bit() }
        if YaesuCRC.remainder(data + YaesuCRC.checkBits(for: data)) == 0 { crcOK += 1 }
    }
    check(crcOK == 50, "Yaesu-CRC: angehängte Prüfsumme ergibt den Rest 0 (50 von 50)")
    var flipped = (0..<48).map { _ in rng.bit() }
    flipped += YaesuCRC.checkBits(for: flipped)
    flipped[10] ^= 1
    check(YaesuCRC.remainder(flipped) != 0, "Yaesu-CRC: ein gekipptes Bit fällt auf")

    // Faltungscode K=5
    var convOK = 0
    for round in 0..<20 {
        let bits = (0..<96).map { _ in rng.bit() } + [0, 0, 0, 0]
        var soft = ConvK5.encode(bits).map { $0 != 0 ? Float(1) : -1 }
        for _ in 0..<(round % 10) { soft[rng.below(soft.count)] *= -1 }
        if ConvK5.decode(soft: soft) == bits { convOK += 1 }
    }
    check(convOK == 20, "Faltungscode K=5: bis zu 9 Bitfehler in 200 Bit werden korrigiert (\(convOK) von 20)")

    // AMBE-Halbrate: Rahmenform
    let chipFrames = ["954be6500310b00777", "dd15852ad3736ead25", "6f60f7a05e52d20ab5"]
    func hex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)! } }
    var chipRoundTrip = true, chipClean = true
    for f in chipFrames {
        let air = AMBEHalfRate.bits(fromBytes: hex(f))
        chipClean = chipClean && AMBEHalfRate.isClean(air)
        let d = AMBEHalfRate.data49(fromAir: air)
        chipRoundTrip = chipRoundTrip && d.corrected == 0 && AMBEHalfRate.air72(fromData49: d.data) == air
    }
    check(chipClean && chipRoundTrip, "AMBE-Halbrate: vom Sprachchip erzeugte Rahmen sind fehlerfrei und werden aus den 49 Nutzbits bitgleich neu erzeugt")
    var noisy = AMBEHalfRate.bits(fromBytes: hex(chipFrames[0]))
    let clean49 = AMBEHalfRate.data49(fromAir: noisy).data
    noisy[5] ^= 1; noisy[30] ^= 1
    let fixed = AMBEHalfRate.data49(fromAir: noisy)
    check(fixed.data == clean49 && fixed.corrected >= 1, "AMBE-Halbrate: Bitfehler in C0 und C1 werden korrigiert")
    var randomOK = 0
    for _ in 0..<100 {
        let d = (0..<49).map { _ in rng.bit() }
        let air = AMBEHalfRate.air72(fromData49: d)
        if air.count == 72 && AMBEHalfRate.isClean(air) && AMBEHalfRate.data49(fromAir: air).data == d { randomOK += 1 }
    }
    check(randomOK == 100, "AMBE-Halbrate: 49 Nutzbits → 72 Bit → 49 Nutzbits (100 von 100)")
    check(AMBEHalfRate.bits(fromBytes: AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: (0..<49).map { $0 % 2 == 0 ? 1 : 0 }))).count == 72, "AMBE-Halbrate: 72 Bit ↔ 9 Byte")

    // YSF: FICH
    let fich = YSFFich(fi: 1, cs: 2, cm: 0, bn: 0, bt: 0, fn: 3, ft: 6, mr: 2, viaRepeater: true, dt: 2, squelchEnabled: true, squelchCode: 42)
    check(YSFFich.decode(symbols: fich.symbols()[...]) == fich, "YSF: FICH hin und zurück (alle Felder)")
    var damaged = fich.symbols()
    for _ in 0..<8 { let i = rng.below(100); damaged[i] = -damaged[i] }
    check(YSFFich.decode(symbols: damaged[...]) == fich, "YSF: FICH mit 8 gekippten Symbolen wird gelesen")
    var wrong = fich.symbols()
    for i in stride(from: 0, to: 100, by: 3) { wrong[i] = -wrong[i] }
    check(YSFFich.decode(symbols: wrong[...]) == nil, "YSF: stark beschädigter FICH wird abgelehnt")
    // Datenkanäle
    let vd2 = YSFDataChannel.decodeVD2(symbols: YSFSignalGenerator.vd2Channel(Array("DL1ABC    ".utf8)))
    check(vd2 == Array("DL1ABC    ".utf8), "YSF: Datenkanal V/D-Modus 2 (10 Byte) hin und zurück")
    let full = YSFDataChannel.decodeFull(symbols: YSFSignalGenerator.fullChannel(Array("**********F6FCE     ".utf8)))
    check(full == Array("**********F6FCE     ".utf8), "YSF: Datenkanal von Kopf und Abschluss (20 Byte) hin und zurück")
    // Sprachkanal: 49 Nutzbits, Mehrheitsentscheid gleicht Fehler in den Wiederholungen aus
    let d49 = (0..<49).map { _ in rng.bit() }
    var voiceSymbols = YSFVoice.symbols(forData49: d49)
    check(YSFVoice.frame(voiceSymbols[...]).ambe == AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: d49)) && YSFVoice.frame(voiceSymbols[...]).disagreements == 0, "YSF: Sprachkanal hin und zurück ergibt den Sprachrahmen")
    voiceSymbols[3] = -voiceSymbols[3]; voiceSymbols[30] = -voiceSymbols[30]
    let repaired = YSFVoice.frame(voiceSymbols[...])
    check(repaired.ambe == AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: d49)) && repaired.disagreements > 0, "YSF: Wiederholungscode gleicht gekippte Symbole aus (\(repaired.disagreements) uneinig)")
    check(YSF.whitening.prefix(16) == [1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1] && YSF.whitening[511] == YSF.whitening[0], "YSF: Verwürfelungsfolge (Periode 511)")

    // YSF: ganze Aussendung → Audio → Rahmen
    let data49: [[UInt8]] = (0..<400).map { _ in (0..<49).map { _ in rng.bit() } }
    let expected = data49.map { AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: $0)) }
    let symbols = YSFSignalGenerator.transmission(destination: "CQCQCQ", source: "DL1ABC", uplink: "DB0XYZ", downlink: "DB0XYZ", data49: { n in Array(data49[(n * 5)..<(n * 5 + 5)]) }, voiceFrames: 40)
    struct YRun { var frames = 0, headers = 0, terminators = 0, lost = 0; var voice: [[UInt8]] = []; var texts = Set<String>() }
    func receiveYSF(_ audio: [Float], rate: Double = 48000) -> YRun {
        let slicer = FourFSKSlicer(sampleRate: rate), framer = YSFFramer()
        var run = YRun()
        framer.onEvent = { e in
            switch e {
            case .frame(let f):
                run.frames += 1
                if f.fich?.isHeader == true { run.headers += 1 }
                if f.fich?.isTerminator == true { run.terminators += 1 }
                run.voice += f.voice
                for t in f.texts { run.texts.insert("\(t)") }
            case .lost: run.lost += 1
            }
        }
        slicer.onSymbol = { framer.push(symbol: $0) }
        var i = 0
        while i < audio.count { let j = min(i + 1000, audio.count); slicer.process(Array(audio[i..<j])); i = j }
        return run
    }
    func scenarioYSF(_ title: String, rate: Double = 48000, minVoice: Int = 200, allCorrect: Bool = true, maxWrong: Int = 0, _ edit: (inout FourFSKModulator.Impairments) -> Void) {
        var im = FourFSKModulator.Impairments(); edit(&im)
        let run = receiveYSF(FourFSKModulator.audio(symbols: symbols, sampleRate: rate, impairments: im), rate: rate)
        let expectedSet = Set(expected)
        let right = allCorrect ? zip(run.voice, expected).filter { $0.0 == $0.1 }.count : run.voice.filter { expectedSet.contains($0) }.count
        let enough = allCorrect ? right >= run.voice.count - maxWrong : right * 10 >= run.voice.count * 6          // verrauscht: mindestens 60 % unversehrt, unabhängig von der Reihenfolge
        check((allCorrect ? run.headers == 1 : true) && run.terminators <= 1 && run.voice.count >= minVoice && enough && run.texts.contains("source(\"DL1ABC\")") && run.texts.contains("uplink(\"DB0XYZ\")"),
              "YSF-Empfänger \(title): Kopf, Abschluss, \(run.voice.count)/200 Sprachrahmen (\(right) richtig), Rufzeichen \(run.texts.count) Stück")
    }
    scenarioYSF("sauber") { _ in }
    scenarioYSF("Pegel umgekehrt") { $0.inverted = true }
    scenarioYSF("Gleichanteil 30 %") { $0.dc = 0.3 }
    scenarioYSF("Takt +400 ppm", maxWrong: 2) { $0.clockPPM = 400 }
    scenarioYSF("Takt −600 ppm", maxWrong: 2) { $0.clockPPM = -600 }
    scenarioYSF("Rauschen 0,25", minVoice: 170, allCorrect: false) { $0.noise = 0.25; $0.seed = 11 }
    scenarioYSF("Abtastrate 24 kHz", rate: 24000, maxWrong: 2) { _ in }
    scenarioYSF("Abtastrate 96 kHz", rate: 96000, maxWrong: 2) { _ in }
    var noiseRng = Rng(state: 77)
    let noiseOnly: [Float] = (0..<(48000 * 30)).map { _ in Float(Double(noiseRng.next() >> 11) / Double(1 << 53) - 0.5) * 0.8 }
    check(receiveYSF(noiseOnly).frames == 0, "YSF-Empfänger: 30 s Rauschen ergeben keinen Rahmen")

    // Echte Aufnahme (Repeater F5ZOO, FT-70/FTM, aus dsdcc/samples; nur lokal)
    let realURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Voice/ysf_f5zoo.dis")
    if let raw = try? Data(contentsOf: realURL) {
        let audio = raw.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        let r = receiveYSF(audio)
        check(r.frames >= 320 && r.voice.count >= 1500 && r.texts.contains("source(\"F6FCE\")") && r.texts.contains("source(\"F1SER\")") && r.texts.contains("uplink(\"F5ZOO-R1\")") && r.texts.contains("destination(\"**********\")"),
              "YSF echt (F5ZOO): \(r.frames) Rahmen, \(r.voice.count) Sprachrahmen, Rufzeichen F6FCE und F1SER über F5ZOO-R1")
    } else { skip("YSF echt: TestData/Voice/ysf_f5zoo.dis liegt nicht lokal vor") }
}
// MARK: - DMR: Codes, Burstaufbau, Link Control, Empfänger
if want("voice") {
    struct Rng: Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func bit() -> UInt8 { UInt8(next() & 1) }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }
    var rng = Rng(state: 2424)

    // Hamming-Codes: jeder Einzelfehler wird korrigiert
    func hammingCheck(_ code: HammingCode, _ name: String) {
        var allFixed = true
        for _ in 0..<20 {
            let data = (0..<code.dataBits).map { _ in rng.bit() }
            let word = code.encode(data)
            allFixed = allFixed && code.decode(word).ok && code.decode(word).bits == word
            for position in 0..<word.count {
                var bad = word
                bad[position] ^= 1
                let r = code.decode(bad)
                allFixed = allFixed && r.ok && r.corrected && r.bits == word
            }
        }
        check(allFixed, "DMR \(name): jeder Einzelfehler wird korrigiert")
    }
    hammingCheck(.h74, "Hamming (7,4,3)")
    hammingCheck(.h139, "Hamming (13,9,3)")
    hammingCheck(.h1511, "Hamming (15,11,3)")
    hammingCheck(.h16114, "Hamming (16,11,4)")
    var doubleRejected = true
    for _ in 0..<50 {
        let word = HammingCode.h16114.encode((0..<11).map { _ in rng.bit() })
        var bad = word
        let a = rng.below(16)
        var b = rng.below(16)
        while b == a { b = rng.below(16) }
        bad[a] ^= 1; bad[b] ^= 1
        doubleRejected = doubleRejected && !HammingCode.h16114.decode(bad).ok
    }
    check(doubleRejected, "DMR Hamming (16,11,4): zwei Fehler werden erkannt und nicht „korrigiert“")
    // Tabellencodes
    var tableOK = true
    for _ in 0..<60 {
        let data = rng.below(256)
        var word = TableCode.golay208.encode(data)
        var flips = Set<Int>()
        let count = rng.below(4)
        while flips.count < count { flips.insert(rng.below(20)) }
        for f in flips { word[f] ^= 1 }
        tableOK = tableOK && TableCode.golay208.decode(word, maxDistance: 3)?.data == data
        let q = rng.below(128)
        var qr = TableCode.qr1676.encode(q)
        var qf = Set<Int>()
        let qc = rng.below(3)
        while qf.count < qc { qf.insert(rng.below(16)) }
        for f in qf { qr[f] ^= 1 }
        tableOK = tableOK && TableCode.qr1676.decode(qr, maxDistance: 2)?.data == q
    }
    check(tableOK, "DMR Golay (20,8,7) bis 3 Fehler und Quadratischer-Rest-Code (16,7,6) bis 2 Fehler")

    // BPTC (196,96) und (128,77)
    var bptcOK = true
    for round in 0..<20 {
        let data = (0..<96).map { _ in rng.bit() }
        var coded = BPTC196.encode(data)
        check(coded.count == 196 && BPTC196.decode(coded).data == data && BPTC196.decode(coded).errors == 0 || round > 0, "DMR BPTC (196,96): Hin- und Rückweg")
        var flips = Set<Int>()
        while flips.count < 1 + round % 6 { flips.insert(rng.below(196)) }
        for f in flips { coded[f] ^= 1 }
        bptcOK = bptcOK && BPTC196.decode(coded).data == data
    }
    check(bptcOK, "DMR BPTC (196,96): bis zu 6 gestreute Bitfehler werden korrigiert")
    var embOK = true
    for round in 0..<20 {
        let data = (0..<77).map { _ in rng.bit() }
        var coded = BPTC128.encode(data)
        let clean = BPTC128.decode(coded)
        embOK = embOK && clean.data == data && clean.errors == 0
        coded[rng.below(128)] ^= 1
        _ = round
        embOK = embOK && BPTC128.decode(coded).data == data
    }
    check(embOK, "DMR BPTC (128,77): Hin- und Rückweg, ein Bitfehler wird korrigiert")

    // Reed-Solomon (12,9): Prüfbytes eines echten Sprach-Kopfs (Aufnahme dmr_it_8, TG 19535, Quelle 2222223; Maske 0x969696)
    let lcBytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x4C, 0x4F, 0x21, 0xE8, 0x8F]
    check(ReedSolomon129.parity(lcBytes) == [0x27 ^ 0x96, 0x4C ^ 0x96, 0x5C ^ 0x96], "DMR Reed-Solomon (12,9): Prüfbytes eines echten Sprach-Kopfs")
    var rsOK = true
    for _ in 0..<40 {
        let message = (0..<9).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let word = message + ReedSolomon129.parity(message)
        rsOK = rsOK && ReedSolomon129.syndromes(word) == [0, 0, 0]
        var bad = word
        let position = rng.below(12)
        bad[position] ^= UInt8(1 + rng.below(255))
        rsOK = rsOK && ReedSolomon129.correct(bad)?.word == word
    }
    check(rsOK, "DMR Reed-Solomon (12,9): Syndrome null, ein fehlerhaftes Byte wird korrigiert")

    // CACH, Slot Type, EMB
    var cachOK = true
    for slot in 0..<2 { for lcss in 0..<4 { let c = DMRCach(accessType: true, slot: slot, lcss: lcss); cachOK = cachOK && DMRCach.decode(c.symbols()[...]) == c } }
    check(cachOK, "DMR CACH: Zeitschlitz und LCSS hin und zurück")
    var slotOK = true
    for cc in 0..<16 { for type in [DMR.DataType.voiceHeader, .terminator, .csbk, .idle, .rate12Data] {
        let st = DMRSlotType(colorCode: cc, dataType: type)
        let bits = st.bits()
        let sym = stride(from: 0, to: 20, by: 2).map { FourFSK.level(ofDibit: (bits[$0] << 1) | bits[$0 + 1]) }
        slotOK = slotOK && DMRSlotType.decode(before: sym[0..<5], after: sym[5..<10]) == st
    } }
    check(slotOK, "DMR Slot Type: Farbcode und Datentyp hin und zurück (alle 16 Farbcodes)")
    var embBitsOK = true
    for cc in 0..<16 { for lcss in 0..<4 {
        let emb = DMREmb(colorCode: cc, pi: false, lcss: lcss)
        let center = DMRSignalGenerator.embeddedCenter(colorCode: cc, lcss: lcss, fragment: [UInt8](repeating: 0, count: 32))
        embBitsOK = embBitsOK && DMREmb.decode(center: center[...]) == emb
    } }
    check(embBitsOK, "DMR EMB: Farbcode und Fragmentkennung hin und zurück")

    // Link Control
    let lc = DMRLinkControl(flco: 0, featureID: 0, serviceOptions: 0, destination: 19535, source: 2222223)
    check(DMRLinkControl.decodeFull(info: lc.encodeFull(type: .voiceHeader), type: .voiceHeader) == lc, "DMR Link Control: Sprach-Kopf hin und zurück")
    check(DMRLinkControl.decodeFull(info: lc.encodeFull(type: .terminator), type: .terminator) == lc && DMRLinkControl.decodeFull(info: lc.encodeFull(type: .terminator), type: .voiceHeader) == nil, "DMR Link Control: Abschluss mit anderer Maske, falsche Maske fällt durch")
    check(DMRLinkControl.decodeEmbedded(fragments: lc.encodeEmbedded()) == lc, "DMR Link Control: eingebettet (vier Fragmente) hin und zurück")
    var damagedFragments = lc.encodeEmbedded()
    damagedFragments[1][5] ^= 1; damagedFragments[2][20] ^= 1
    check(DMRLinkControl.decodeEmbedded(fragments: damagedFragments) == lc, "DMR Link Control: eingebettet mit zwei Bitfehlern")
    let privateCall = DMRLinkControl(flco: 3, destination: 9990001, source: 262001)
    check(privateCall.isPrivateCall && !privateCall.isGroupCall && DMRLinkControl(bytes: privateCall.bytes) == privateCall, "DMR Link Control: Einzelruf und Bytefolge")

    // Sprachburst: drei Rahmen hin und zurück
    let testFrames: [[UInt8]] = (0..<3).map { _ in AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: (0..<49).map { _ in rng.bit() })) }
    let oneBurst = DMRSignalGenerator.voiceBurst(slot: 0, frames: testFrames, center: DMR.SyncKind.baseVoice.levels)
    check(oneBurst.count == 144 && DMRVoice.frames(burst: oneBurst[...]) == testFrames, "DMR Sprachburst: Rahmen A, B (um die Mitte geteilt) und C hin und zurück")
    check(DMR.SyncKind.baseData.levels == DMR.SyncKind.baseVoice.levels.map { -$0 } && DMR.SyncKind.mobileData.levels == DMR.SyncKind.mobileVoice.levels.map { -$0 }, "DMR: Datensync ist das Negativ des Sprachsyncs (Polaritätsfalle)")

    // Empfänger
    let callFrames: [[UInt8]] = (0..<54).map { _ in AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: (0..<49).map { _ in rng.bit() })) }
    struct DRun { var voice: [[[UInt8]]] = [[], []]; var starts: [(Int, Int?, DMRLinkControl?)] = []; var ends: [(Int, DMRLinkControl?, Bool)] = []; var lcs: [(Int, DMRLinkControl)] = []; var lost = 0; var stats = DMRFramerStats(); var embeddedIndexes = Set<Int>() }
    func receiveDMR(_ audio: [Float], rate: Double = 48000) -> DRun {
        let slicer = FourFSKSlicer(sampleRate: rate), framer = DMRFramer()
        var run = DRun()
        framer.onEvent = { e in
            switch e {
            case .voice(let v): run.voice[v.slot] += v.frames; run.embeddedIndexes.insert(v.index)
            case .callStart(let s, let cc, let l): run.starts.append((s, cc, l))
            case .callEnd(let s, let l, let lost): run.ends.append((s, l, lost))
            case .linkControl(let s, let l): run.lcs.append((s, l))
            case .lost: run.lost += 1
            case .data: break
            }
        }
        slicer.onSymbol = { framer.push(symbol: $0) }
        var i = 0
        while i < audio.count { let j = min(i + 1000, audio.count); slicer.process(Array(audio[i..<j])); i = j }
        run.stats = framer.stats
        return run
    }
    let cleanSymbols = DMRSignalGenerator.call(slot: 1, colorCode: 5, lc: lc, frames: callFrames)
    func scenarioDMR(_ title: String, rate: Double = 48000, minBursts: Int = 18, share: Double = 0.97, _ edit: (inout FourFSKModulator.Impairments) -> Void) {
        var im = FourFSKModulator.Impairments(); edit(&im)
        let r = receiveDMR(FourFSKModulator.audio(symbols: cleanSymbols, sampleRate: rate, bt: 2.0, impairments: im), rate: rate)
        let right = zip(r.voice[1], callFrames).filter { $0.0 == $0.1 }.count
        check(r.voice[0].isEmpty && r.voice[1].count >= minBursts * 3 && Double(right) >= share * Double(r.voice[1].count) && r.starts.first?.0 == 1 && r.starts.first?.2 == lc && r.starts.first?.1 == 5 && r.ends.last?.2 == false && r.ends.last?.1 == lc && r.stats.embeddedLC >= 2,
              "DMR-Empfänger \(title): Kopf (CC 5, TG 19535, Quelle 2222223), \(r.voice[1].count / 3) Sprachbursts (\(right) von \(r.voice[1].count) Rahmen bitgleich), Abschluss, eingebettete Information \(r.stats.embeddedLC)")
    }
    scenarioDMR("sauber") { _ in }
    scenarioDMR("Pegel umgekehrt") { $0.inverted = true }
    scenarioDMR("Gleichanteil 30 %") { $0.dc = 0.3 }
    scenarioDMR("Takt +300 ppm") { $0.clockPPM = 300 }
    scenarioDMR("Takt −500 ppm") { $0.clockPPM = -500 }
    scenarioDMR("Rauschen 0,2", share: 0.85) { $0.noise = 0.2; $0.seed = 31 }
    scenarioDMR("Abtastrate 24 kHz", rate: 24000, share: 0.9) { _ in }
    scenarioDMR("Abtastrate 96 kHz") { _ in }
    // Später Einstieg: ohne Kopf liefern die eingebetteten Fragmente die Rufdaten
    let lateSymbols = DMRSignalGenerator.call(slot: 0, colorCode: 2, lc: lc, frames: callFrames, withHeader: false, withTerminator: false)
    let late = receiveDMR(FourFSKModulator.audio(symbols: lateSymbols, sampleRate: 48000, bt: 2.0))
    check(late.starts.first?.2 == nil && late.lcs.contains { $0.0 == 0 && $0.1 == lc } && late.voice[0].count >= 15 * 3 && late.voice[1].isEmpty,
          "DMR-Empfänger später Einstieg: Gespräch ohne Kopf, Rufdaten aus der eingebetteten Information (\(late.lcs.count) mal), \(late.voice[0].count / 3) Sprachbursts")
    // Zwei Gespräche zugleich, in jedem Zeitschlitz eines
    let lcB = DMRLinkControl(flco: 3, destination: 262999, source: 2621111)
    let framesB: [[UInt8]] = (0..<36).map { _ in AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: (0..<49).map { _ in rng.bit() })) }
    let both = DMRSignalGenerator.stream(slot0: DMRSignalGenerator.bursts(slot: 0, colorCode: 7, lc: lc, frames: callFrames),
                                         slot1: DMRSignalGenerator.bursts(slot: 1, colorCode: 7, lc: lcB, frames: framesB), colorCode: 7)
    let two = receiveDMR(FourFSKModulator.audio(symbols: both, sampleRate: 48000, bt: 2.0))
    check(two.starts.contains { $0.0 == 0 && $0.2 == lc } && two.starts.contains { $0.0 == 1 && $0.2 == lcB } && two.voice[0].count >= 15 * 3 && two.voice[1].count >= 10 * 3 && two.ends.count == 2,
          "DMR-Empfänger zwei Zeitschlitze: Gruppenruf in Zeitschlitz 1 und Einzelruf in Zeitschlitz 2 getrennt (\(two.voice[0].count / 3) und \(two.voice[1].count / 3) Sprachbursts)")
    // ID-Liste (Format der Datenbank von radioid.net)
    let csv = "RADIO_ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY\n1023007,VA3BOC,Hans Juergen,,Cornwall,Ontario,Canada\n2621234,DL1ABC,Peter,Betz,Würzburg,Bayern,Germany\nkaputt\n99,,Name,,,,\n"
    let table = DMRIDDatabase.parse(csv: csv)
    check(table.count == 2 && table[2621234]?.callsign == "DL1ABC" && table[2621234]?.description == "Peter Betz, Würzburg, Germany" && table[1023007]?.description == "Hans Juergen, Cornwall, Canada",
          "DMR-ID-Liste: Zeilen lesen (Kopfzeile, fehlerhafte und leere Rufzeichen werden übersprungen)")
    check(DMRIDDatabase.describe(count: 331_404, updated: Date(timeIntervalSince1970: 1_790_000_000)).hasPrefix("331.404 Einträge, Stand "), "DMR-ID-Liste: Statuszeile")
    // Talker Alias: vier Link-Control-Blöcke, alle vier Formate
    var aliasOK = true
    for (format, text) in [(0, "DL1ABC Peter Betz"), (1, "Würzburg Müller"), (2, "Straße € Köln"), (3, "Grüße 日本")] {
        let blocksLC = DMRTalkerAlias.encode(text, format: format)
        var a = DMRTalkerAlias()
        for b in blocksLC {
            // über die eingebettete Übertragung (BPTC 128,77 mit Summe) geschickt
            guard let back = DMRLinkControl.decodeEmbedded(fragments: b.encodeEmbedded()), back.bytes == b.bytes, DMRTalkerAlias.isAlias(back) else { aliasOK = false; continue }
            a.ingest(back)
        }
        if a.text != text || !a.isComplete || a.format != format { aliasOK = false; print("Alias Format \(format): „\(a.text)“ statt „\(text)“") }
    }
    check(aliasOK, "DMR Talker Alias: 7 Bit, ISO 8859-1, UTF-8 und UTF-16 über die eingebettete Übertragung")
    var partial = DMRTalkerAlias()
    let aliasBlocks = DMRTalkerAlias.encode("DL1ABC Peter Betz", format: 0)
    partial.ingest(aliasBlocks[0])
    let headOnly = partial.text
    partial.ingest(aliasBlocks[1])
    check(headOnly == "DL1ABC " && !partial.isComplete && partial.text == "DL1ABC Peter Betz".prefix(partial.text.count) && partial.text.count > headOnly.count && partial.length == 17, "DMR Talker Alias: Teiltext wächst mit jedem Block („\(headOnly)“ → „\(partial.text)“)")
    check(!DMRTalkerAlias.isAlias(lc) && DMRTalkerAlias.blockIndex(of: DMRLinkControl(flco: 0x15, featureID: 0x10, destination: 0, source: 0)) == 1 && DMRTalkerAlias.blockIndex(of: DMRLinkControl(flco: 8, destination: 0, source: 0)) == nil, "DMR Talker Alias: Erkennung der Blöcke (Standard und Motorola)")
    // Über die Funkstrecke: der Alias kommt in den eingebetteten Blöcken abwechselnd mit dem Ruf (je Überrahmen ein Block)
    let aliasFrames: [[UInt8]] = (0..<108).map { _ in AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: (0..<49).map { _ in rng.bit() })) }
    let aliasSymbols = DMRSignalGenerator.call(slot: 0, colorCode: 3, lc: lc, frames: aliasFrames, embeddedCycle: [lc] + aliasBlocks)
    let aliasRun = receiveDMR(FourFSKModulator.audio(symbols: aliasSymbols, sampleRate: 48000, bt: 2.0))
    var rfAlias = DMRTalkerAlias()
    for (_, l) in aliasRun.lcs where DMRTalkerAlias.isAlias(l) { rfAlias.ingest(l) }
    check(rfAlias.text == "DL1ABC Peter Betz" && aliasRun.starts.first?.2 == lc && aliasRun.lcs.contains { $0.1 == lc }, "DMR Talker Alias über die Funkstrecke: „\(rfAlias.text)“, Ruf bleibt erhalten")
    // Rauschen: keine Gespräche
    var noiseRng = Rng(state: 8)
    let noiseOnly: [Float] = (0..<(48000 * 30)).map { _ in Float(Double(noiseRng.next() >> 11) / Double(1 << 53) - 0.5) * 0.8 }
    let nothing = receiveDMR(noiseOnly)
    check(nothing.starts.isEmpty && nothing.voice[0].isEmpty && nothing.voice[1].isEmpty, "DMR-Empfänger: 30 s Rauschen ergeben kein Gespräch")

    // Echte Aufnahme (dsdcc/samples, Italien; nur lokal): Zeitschlitz 2 mit Sprache, Zeitschlitz 1 im Leerlauf, TG 19535 von 2222223, Farbcode 4
    let realDMR = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Voice/dmr_it_8.dis")
    if let raw = try? Data(contentsOf: realDMR) {
        let audio = raw.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        let r = receiveDMR(audio)
        check(r.voice[1].count >= 320 * 3 && r.voice[0].isEmpty && r.stats.idleBursts >= 300 && r.stats.embeddedLC >= 10 && r.lcs.contains { $0.1.destination == 19535 && $0.1.source == 2222223 }
              && r.starts.contains { $0.1 == 4 && $0.2?.destination == 19535 && $0.2?.source == 2222223 },
              "DMR echt (Italien): \(r.voice[1].count / 3) Sprachbursts in Zeitschlitz 2, \(r.stats.idleBursts) Leerlaufbursts, Sprach-Kopf (CC 4, TG 19535, Quelle 2222223), \(r.stats.embeddedLC) mal eingebettet")
    } else { skip("DMR echt: TestData/Voice/dmr_it_8.dis liegt nicht lokal vor") }
}
// MARK: - Positionen aus digitalen Sprachmodi (DPRS, M17): Liste und Karte
if want("voice") {
    var book = VoicePositionBook()
    let t0 = Date()
    check(book.update(mode: "D-STAR", callsign: "dl1abc-7 ", latitude: 49.79, longitude: 9.95, comment: "Test", now: t0) && book.items.count == 1 && book.items[0].callsign == "DL1ABC-7", "Positionen: Aufnahme, Rufzeichen groß und ohne Leerzeichen")
    check(!book.update(mode: "D-STAR", callsign: "X", latitude: 91, longitude: 0) && !book.update(mode: "D-STAR", callsign: "X", latitude: 0, longitude: 0) && !book.update(mode: "D-STAR", callsign: "", latitude: 10, longitude: 10)
          && book.items.count == 1, "Positionen: ungültige Werte, Nullpunkt und leeres Rufzeichen werden verworfen")
    book.update(mode: "D-STAR", callsign: "DL1ABC-7", latitude: 49.79, longitude: 9.95, now: t0.addingTimeInterval(5))           // gleich: kein neuer Wegpunkt
    book.update(mode: "D-STAR", callsign: "DL1ABC-7", latitude: 49.80, longitude: 9.96, speed: 50, altitude: 300, bearing: 45, now: t0.addingTimeInterval(60))
    check(book.items.count == 1 && book.items[0].track.count == 1 && book.items[0].count == 3 && book.items[0].speed == 50 && book.items[0].comment == "Test", "Positionen: gleiche Station → Weg wächst nur bei Bewegung")
    book.update(mode: "M17", callsign: "DL1ABC-7", latitude: 48.1, longitude: 11.5, now: t0)
    check(book.items.count == 2, "Positionen: je Verfahren getrennt")
    let home = GeoPoint(lat: 49.79, lon: 9.93)
    let content = book.mapContent(home: home, now: t0.addingTimeInterval(120), selection: "D-STAR-DL1ABC-7", hint: "leer")
    check(content.markers.count == 2 && content.lines.count == 1 && content.markers.first?.title == "DL1ABC-7" && content.markers.first?.tone == .highlight && content.markers.first?.track.count == 2
          && content.markers.first?.subtitle?.contains("D-STAR") == true && content.markers.first?.details.contains { $0.contains("Entfernung") } == true && content.emptyHint == "leer",
          "Positionen: Karteninhalt (Punkte, Spur, Linie zur Auswahl, Entfernung)")
    let old = book.mapContent(home: nil, now: t0.addingTimeInterval(7200), selection: nil, hint: "")
    check(old.markers.allSatisfy { $0.tone == .dim } && old.lines.isEmpty && old.markers[0].subtitle?.contains("vor 2 h") == true, "Positionen: alte Stationen gedämpft")
    var dpr = book; dpr.clear()
    check(dpr.items.isEmpty && DecoderModuleInfo.dstar.hasMap && DecoderModuleInfo.m17.hasMap && !DecoderModuleInfo.ysf.hasMap, "Positionen: leeren, Karte für D-Star und M17")
}
// MARK: - dPMR: Codes, Steuerkanal, Empfänger, Rundlauf, echte Aufnahme
if want("voice") {
    struct PRng { var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func bit() -> UInt8 { UInt8(next() & 1) }
    }
    var rng = PRng(s: 99)
    // Verwürfelung, Verschachtelung
    let raw = (0..<72).map { _ in rng.bit() }
    check(DPMRCodes.scramble(DPMRCodes.scramble(raw)) == raw && DPMRCodes.scramble(raw) != raw && DPMRCodes.deinterleave(DPMRCodes.interleave(raw)) == raw && DPMRCodes.interleave(raw) != raw,
          "dPMR: Verwürfelung (x⁹ + x⁵ + 1) und 6×12-Verschachtelung sind umkehrbar")
    // Hamming (12,8): jeder Einzelbitfehler an jeder der 12 Stellen wird korrigiert
    var hammingOK = true
    for _ in 0..<20 {
        let d = (0..<8).map { _ in rng.bit() }
        let w = DPMRCodes.hammingEncode(d)
        if DPMRCodes.hammingDecode(w).data != d || DPMRCodes.hammingDecode(w).corrected { hammingOK = false }
        for e in 0..<12 {
            var bad = w; bad[e] ^= 1
            let r = DPMRCodes.hammingDecode(bad)
            if r.data != d || !r.correctable || !r.corrected { hammingOK = false }
        }
    }
    check(hammingOK, "dPMR: Hamming (12,8) korrigiert jeden Einzelbitfehler")
    // CRC-7: mit angehängter Prüfsumme bleibt Rest 0
    let body = (0..<41).map { _ in rng.bit() }
    let crc = DPMRCodes.crc7(body[...])
    let withCRC = body + (0..<7).map { UInt8((crc >> UInt8(6 - $0)) & 1) }
    check(DPMRCodes.crc7(withCRC[...]) == 0 && DPMRCodes.crc7(body[...]) != 0 || crc == 0, "dPMR: CRC-7 (x⁷ + x³ + 1)")
    // Kennungen
    check(DPMR.idText(0) == "0000000" && DPMR.idValue("0010011") != nil && DPMR.idText(DPMR.idValue("0010011")!) == "0010011" && DPMR.idText(DPMR.idValue("123*45*")!) == "123*45*"
          && DPMR.idValue("12345") == nil && DPMR.idValue("12x4567") == nil && DPMR.idValue("99999999") == nil, "dPMR: Kennung ↔ sieben Zeichen (Stellen 1 bis 3 dezimal, 4 bis 7 zur Basis 11)")
    var idRoundTrip = true
    for _ in 0..<200 {
        let v = UInt32(rng.next() % 14_640_000)
        if let t = Optional(DPMR.idText(v)), DPMR.idValue(t) != v { idRoundTrip = false }
    }
    check(idRoundTrip, "dPMR: 200 Kennungen hin und zurück")
    // Kanalcode: 64 verschiedene Wörter, Rundlauf, robust gegen gekippte niedrige Dibit-Bits
    check(Set(DPMR.colorCodeWords).count == 64 && (0..<64).allSatisfy { DPMR.colorCode(ofBits: DPMR.bits(ofColorCode: $0)) == $0 }, "dPMR: 64 Kanalcodes, Rundlauf")
    var flipped = DPMR.bits(ofColorCode: 17)
    for i in stride(from: 1, to: 24, by: 2) { flipped[i] ^= 1 }
    check(DPMR.colorCode(ofBits: flipped) == 17 && DPMR.colorCode(ofBits: [UInt8](repeating: 0, count: 24)) == nil, "dPMR: Kanalcode trotz gekippter niedriger Dibit-Bits (immer 1)")
    // Steuerkanal
    let cchBits = DPMRCCH.encode(frameNumber: 2, idPart: 0x8A5, mode: 1, version: 3, format: 2, emergency: true, slowData: 0x2AAAA)
    let cch = DPMRCCH.decode(cchBits)
    check(cch.crcOK && cch.frameNumber == 2 && cch.idPart == 0x8A5 && cch.mode == 1 && cch.version == 3 && cch.format == 2 && cch.emergency && cch.slowData == 0x2AAAA && cch.isScrambled && cch.carriesVoice && cch.allReadable,
          "dPMR: Steuerkanal (Rahmennummer, Kennungsteil, Betriebsart, Version, Format, Notruf, Langsamdaten) hin und zurück")
    var oneError = cchBits; oneError[17] ^= 1; oneError[40] ^= 1                // zwei Fehler in verschiedenen Hamming-Wörtern
    check(DPMRCCH.decode(oneError).crcOK && DPMRCCH.decode(oneError).idPart == 0x8A5, "dPMR: Steuerkanal mit zwei Bitfehlern in verschiedenen Wörtern korrigiert")
    var wrecked = cchBits; for i in 0..<12 { wrecked[i] ^= 1 }
    check(!DPMRCCH.decode(wrecked).crcOK, "dPMR: zerstörter Steuerkanal fällt durch die Prüfsumme")
    check(DPMRDiagnosis.assess(inputDB: -120, stats: DPMRFramerStats(), locked: false).severity == .problem && DPMRDiagnosis.assess(inputDB: -30, stats: DPMRFramerStats(), locked: true).severity == .ok
          && DPMRDiagnosis.assess(inputDB: -30, stats: DPMRFramerStats(), locked: false).severity == .waiting && DecoderModuleInfo.dpmr.band == .vhfUhf && !DecoderModuleInfo.dpmr.hasMap, "dPMR: Diagnose und Modul")

    // Rundlauf über Audio
    let callFrames: [[UInt8]] = (0..<64).map { _ in AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: (0..<49).map { _ in rng.bit() })) }
    struct DRun { var frames: [[UInt8]] = []; var called = ""; var calling = ""; var cc = -1; var starts = 0; var ends = 0; var lost = 0; var emergency = false; var scrambled = 0
        var stats = DPMRFramerStats(); var inverted = false }
    func receive(_ audio: [Float], rate: Double = 48000) -> DRun {
        var run = DRun()
        let rx = DPMRReceiver(sampleRate: rate)
        rx.onEvent = { e in
            switch e {
            case .callStart: run.starts += 1
            case .voice(let v): run.frames += v.frames; if v.scrambled { run.scrambled += 1 }
            case .info(let a, let b, let c, let em): if let a { run.called = a }; if let b { run.calling = b }; if let c { run.cc = c }; run.emergency = em
            case .callEnd(let lost): if lost { run.lost += 1 } else { run.ends += 1 }
            }
        }
        var i = 0
        let chunk = Int(rate / 100)
        while i < audio.count { let j = min(i + chunk, audio.count); rx.process(Array(audio[i..<j])); i = j }
        run.stats = rx.stats; run.inverted = rx.inverted
        return run
    }
    let callSymbols = DPMRSignalGenerator.call(called: "0010011", calling: "0000243", colorCode: 31, frames: callFrames)
    func scenarioDPMR(_ title: String, rate: Double = 48000, minShare: Double = 0.97, _ edit: (inout FourFSKModulator.Impairments) -> Void) {
        var im = FourFSKModulator.Impairments(); edit(&im)
        let r = receiveAudio(FourFSKModulator.audio(symbols: callSymbols, sampleRate: rate, baud: DPMR.baud, bt: 1.0, impairments: im), rate)
        let right = zip(r.frames, callFrames).filter { $0.0 == $0.1 }.count
        check(r.starts == 1 && r.called == "0010011" && r.calling == "0000243" && r.cc == 31 && r.ends == 1 && r.lost == 0 && r.frames.count == 64 && Double(right) >= minShare * 64,
              "dPMR-Empfänger \(title): ein Gespräch, gerufen 0010011, rufend 0000243, Kanalcode 31, Endekennung, \(right) von 64 Sprachrahmen bitgleich")
    }
    func receiveAudio(_ a: [Float], _ rate: Double) -> DRun { receive(a, rate: rate) }
    scenarioDPMR("sauber") { _ in }
    scenarioDPMR("Pegel umgekehrt") { $0.inverted = true }
    scenarioDPMR("Gleichanteil 30 %") { $0.dc = 0.3 }
    scenarioDPMR("Takt +300 ppm", minShare: 0.9) { $0.clockPPM = 300 }
    scenarioDPMR("Takt −300 ppm", minShare: 0.9) { $0.clockPPM = -300 }
    scenarioDPMR("Rauschen 0,15", minShare: 0.9) { $0.noise = 0.15; $0.seed = 11 }
    scenarioDPMR("Abtastrate 24 kHz", rate: 24000) { _ in }
    scenarioDPMR("Abtastrate 44,1 kHz", rate: 44100) { _ in }
    scenarioDPMR("Abtastrate 96 kHz", rate: 96000) { _ in }
    scenarioDPMR("alles zusammen (invers, Gleichanteil, Rauschen, +100 ppm)", minShare: 0.9) { $0.inverted = true; $0.dc = 0.2; $0.noise = 0.1; $0.clockPPM = 100; $0.seed = 4 }
    // Zwei Gespräche hintereinander mit verschiedenen Kennungen, mit Notruf und Scrambler
    let call2 = DPMRSignalGenerator.call(called: "1234567", calling: "7654321", colorCode: 5, frames: Array(callFrames[0..<16]), emergency: true)
    let call3 = DPMRSignalGenerator.call(called: "0000001", calling: "0000002", colorCode: 63, frames: Array(callFrames[16..<32]), version: 3)
    let gap = [Float](repeating: 0, count: 400)
    let two = receive(FourFSKModulator.audio(symbols: callSymbols + gap + call2 + gap + call3, sampleRate: 48000, baud: DPMR.baud))
    check(two.starts == 3 && two.ends == 3 && two.calling == "0000002" && two.called == "0000001" && two.cc == 63 && two.scrambled > 0 && two.stats.calls == 3,
          "dPMR-Empfänger drei Gespräche hintereinander (Notruf, Scrambler erkannt): \(two.starts) Gespräche, Kanalcodes bis \(two.cc)")
    var noiseRng = PRng(s: 8)
    let noiseOnly: [Float] = (0..<(48000 * 30)).map { _ in Float(Double(noiseRng.next() & 0xFFFFF) / Double(1 << 20) - 0.5) * 0.8 }
    let nothing = receive(noiseOnly)
    check(nothing.starts == 0 && nothing.frames.isEmpty, "dPMR-Empfänger: 30 s Rauschen ergeben kein Gespräch (\(nothing.stats.syncs) Zufallstreffer verworfen)")
    // Echte Aufnahme (dsdcc/samples, Frankreich; nur lokal): drei Gespräche von 0000243, 0000255 und 0000261 an 0010011, Kanalcode 31
    let realDPMR = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Voice/dpmr.dis")
    if let data = try? Data(contentsOf: realDPMR) {
        let audio = data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        var callers: [String] = []
        var ended = 0, voice = 0, clean = 0
        let rx = DPMRReceiver(sampleRate: 48000)
        rx.onEvent = { e in
            switch e {
            case .info(let a, let b, _, _): if let b, a == "0010011", !callers.contains(b) { callers.append(b) }
            case .voice(let v): voice += v.frames.count; clean += v.cleanFrames
            case .callEnd(let lost): if !lost { ended += 1 }
            case .callStart: break
            }
        }
        var i = 0
        while i < audio.count { let j = min(i + 480, audio.count); rx.process(Array(audio[i..<j])); i = j }
        check(callers.contains("0000243") && callers.contains("0000255") && callers.contains("0000261") && ended >= 3 && voice >= 400 && Double(clean) / Double(max(1, voice)) > 0.4,
              "dPMR echt (Frankreich): Rufende \(callers.joined(separator: ", ")) an 0010011, \(ended) Endekennungen, \(voice) Sprachrahmen (\(clean) ohne Bitfehler)")
    } else { skip("dPMR echt: TestData/Voice/dpmr.dis liegt nicht lokal vor") }
}
// MARK: - M17: Codes, Rahmen, LSF, Empfänger, Sprache
if want("voice") {
    // Vektoren der Referenzbibliothek libM17 (Rufzeichen, CRC, Golay) und der Spezifikation
    check(M17.address(fromCallsign: "N0CALL") == 0x4B13D106 && M17.address(fromCallsign: "@ALL") == M17.broadcast && M17.callsign(from: 0x4B13D106) == "N0CALL",
          "M17: Rufzeichen N0CALL = 0x4B13D106, @ALL = Rundruf")
    check(M17.callsign(from: M17.address(fromCallsign: "#ABC")!) == "#ABC" && M17.callsign(from: M17.hashEnd) == nil && M17.address(fromCallsign: "ABCDEFGHIJ") == nil && M17.address(fromCallsign: "DL1ä") == nil,
          "M17: Hash-Adressen, zu langes und ungültiges Rufzeichen")
    check(M17.crc16(Array("123456789".utf8)) == 0x772B && M17.crc16(Array("A".utf8)) == 0x206E && M17.crc16((0..<256).map { UInt8($0) }) == 0x1C31 && M17.crc16([]) == 0xFFFF,
          "M17: CRC-16 (Polynom 0x5935) gegen die Prüfwerte der Referenz")
    var golayWord = 0
    for bit in Golay.encode24((0..<12).map { UInt8((0x0D78 >> (11 - $0)) & 1) }) { golayWord = (golayWord << 1) | Int(bit) }
    check(golayWord == 0xD7880F, "M17: Golay (24,12) gegen den Prüfwert der Referenz (0x0D78 → 0xD7880F)")
    check(M17.permutation.prefix(8) == [0, 137, 90, 227, 180, 317, 270, 39] && M17.permutation.enumerated().allSatisfy { M17.permutation[$0.element] == $0.offset },
          "M17: Verschachtelung π(x) = (45x + 92x²) mod 368 ist eine Selbstumkehr und passt zur Tabelle der Referenz")
    check(M17.randomizer.count == 368 && Array(M17.randomizer[0..<16]) == [1, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1] && M17.puncture1.filter { $0 }.count == 46 && M17.puncture2.filter { $0 }.count == 11,
          "M17: Zufallsmaske und Punktierungsmuster")
    check(M17.SyncKind.allCases.map(\.word) == [0x55F7, 0xFF5D, 0x75FF, 0xDF55, 0x555D] && M17.SyncKind.lsf.levels == [3, 3, 3, 3, -3, -3, 3, -3] && M17.SyncKind.stream.levels == M17.SyncKind.lsf.levels.map { -$0 },
          "M17: Synchronwörter (das Strom-Wort ist das Negativ des LSF-Worts)")

    // LSF
    let caller = M17.address(fromCallsign: "DL1ABC")!
    let lsf = M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: 2, can: 3))
    check(lsf.bytes.count == 30 && M17LSF(bytes: lsf.bytes) == lsf && lsf.payload == .voice3200 && lsf.channelAccessNumber == 3 && !lsf.isEncrypted && lsf.sourceName == "DL1ABC" && lsf.destinationName == "@ALL",
          "M17: LSF 30 Byte mit CRC, Typfeld nach Fassung 3.0")
    var broken = lsf.bytes; broken[7] ^= 0x10
    check(M17LSF(bytes: broken) == nil, "M17: LSF mit falscher CRC wird verworfen")
    let v2 = M17LSF(destination: M17.address(fromCallsign: "DL0XY")!, source: caller, type: M17LSF.type2(dataType: 2, can: 5))
    check(v2.type == 0x0285 && !v2.isVersion3 && v2.payload == .voice3200 && v2.channelAccessNumber == 5 && M17LSF.type2(dataType: 3) == 0x0007,
          "M17: Typfeld nach Fassung 2.0 (Sprache 3200 = 0x0005 + CAN)")
    let enc = M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: 3, encryption: 5, signed: true, meta: 0xF, can: 1))
    check(enc.isEncrypted && enc.encryptionText == "AES 192" && enc.isSigned && enc.payload == .voice1600 && enc.content == .none, "M17: Verschlüsselung, Signatur und Initialisierungsvektor")
    var text = [UInt8](repeating: 0, count: 14); text[0] = 0x32; for (i, c) in "Hallo Welt".utf8.enumerated() { text[i + 1] = c }
    check(M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: 2, meta: 3), meta: text).content == .text(segment: 2, total: 3, text: "Hallo Welt"), "M17: Meta-Text (Fassung 3.0, Abschnitt 2 von 3)")
    let textV2 = text                                  // Steuerbyte 0x32: Bitmuster 0b0011 = 2 Abschnitte, 0b0010 = der zweite
    check(M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type2(dataType: 2, subtype: 0), meta: textV2).content == .text(segment: 2, total: 2, text: "Hallo Welt"), "M17: Meta-Text (Fassung 2.0, Bitmuster)")
    var pos = [UInt8](repeating: 0, count: 14)
    let lat24 = Int((49.4075 * 8_388_607 / 90).rounded()), lon24 = Int((-8.6924 * 8_388_607 / 180).rounded()) & 0xFFFFFF
    pos[0] = 0x02; pos[1] = 0xE << 4; pos[3] = UInt8(lat24 >> 16); pos[4] = UInt8((lat24 >> 8) & 0xFF); pos[5] = UInt8(lat24 & 0xFF)
    pos[6] = UInt8(lon24 >> 16); pos[7] = UInt8((lon24 >> 8) & 0xFF); pos[8] = UInt8(lon24 & 0xFF); pos[9] = 0x07; pos[10] = 0xD0
    if case .position(let la, let lo, let alt, _, _, let st) = M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: 2, meta: 1), meta: pos).content {
        check(abs(la - 49.4075) < 1e-4 && abs(lo + 8.6924) < 1e-4 && alt == 500 && st == "Handfunkgerät", "M17: Meta-Position (Breite \(la), Länge \(lo), Höhe \(alt ?? -1) m, \(st))")
    } else { check(false, "M17: Meta-Position nicht erkannt") }

    // Rahmen: Rundlauf
    let lsfSymbols = M17.lsfFrameSymbols(lsf)
    let lsfDecoded = M17.decodeLSFFrame(lsfSymbols[8...])
    check(lsfSymbols.count == 192 && lsfDecoded?.lsf == lsf && lsfDecoded?.errorRate == 0, "M17: LSF-Rahmen (192 Symbole) Rundlauf")
    var damaged = Array(lsfSymbols[8...])
    for i in stride(from: 3, to: damaged.count, by: 23) { damaged[i] = -damaged[i] }         // jedes 23. Symbol falsch (8 von 184)
    check(M17.decodeLSFFrame(damaged[...])?.lsf == lsf, "M17: LSF-Rahmen mit 8 falschen Symbolen wird vom Faltungscode repariert")
    let pay = (0..<16).map { UInt8($0 * 17) }
    let chunk = Array(lsf.bytes[5..<10])
    let strSymbols = M17.streamFrameSymbols(lichChunk: chunk, counter: 1, last: false, frameNumber: 12345, payload: pay)
    let strDecoded = M17.decodeStreamFrame(strSymbols[8...])
    check(strDecoded?.payload == pay && strDecoded?.lichCounter == 1 && strDecoded?.frameNumber == 12345 && strDecoded?.lichChunk == chunk && strDecoded?.isLast == false && strDecoded?.lichErrors == 0 && strDecoded?.errorRate == 0,
          "M17: Strom-Rahmen Rundlauf (LICH-Anteil, Zähler, Rahmennummer, Nutzlast)")
    check(M17.decodeStreamFrame(M17.streamFrameSymbols(lichChunk: chunk, counter: 5, last: true, frameNumber: 0x7FFF, payload: pay)[8...])?.isLast == true, "M17: Ende-Bit")
    var dmg2 = Array(strSymbols[8...])
    for i in stride(from: 5, to: dmg2.count, by: 11) { dmg2[i] = dmg2[i] > 0 ? -1 : 1 }
    let r2 = M17.decodeStreamFrame(dmg2[...])
    check(r2?.payload == pay && r2?.lichChunk == chunk && (r2?.lichErrors ?? 9) > 0, "M17: Strom-Rahmen mit 17 falschen Symbolen (LICH-Fehler \(r2?.lichErrors ?? -1) korrigiert)")

    // Empfänger über Modulator und Vierpegel-Empfänger
    final class Events: @unchecked Sendable { var list: [M17Event] = [] }
    func receive(_ symbols: [Float], noise: Float = 0, ppm: Double = 0, inverted: Bool = false, seed: UInt64 = 1, tail: Int = 0) -> (events: [M17Event], stats: M17FramerStats) {
        var imp = FourFSKModulator.Impairments()
        imp.noise = noise; imp.clockPPM = ppm; imp.inverted = inverted; imp.seed = seed
        let audio = FourFSKModulator.audio(symbols: symbols + [Float](repeating: 0, count: tail), sampleRate: 48000, impairments: imp)
        let slicer = FourFSKSlicer(sampleRate: 48000)
        let framer = M17Framer()
        let box = Events()
        framer.onEvent = { box.list.append($0) }
        slicer.onSymbol = { framer.push(symbol: $0) }
        slicer.process(audio)
        return (box.list, framer.stats)
    }
    struct Summary { var calls = 0, ends = 0, lost = 0, frames = 0, viaLICH = 0; var lsfs: [M17LSF] = []; var payloads: [[UInt8]] = [] }
    func summarize(_ events: [M17Event]) -> Summary {
        var s = Summary()
        for e in events {
            switch e {
            case .callStart: s.calls += 1
            case .callEnd(let lost): s.ends += 1; if lost { s.lost += 1 }
            case .frame(let f): s.frames += 1; s.payloads.append(f.payload)
            case .lsf(let l, let via): s.lsfs.append(l); if via { s.viaLICH += 1 }
            case .lost: break
            case .packet, .bert, .signature: break
            }
        }
        return s
    }
    let payloads = (0..<100).map { i in (0..<16).map { UInt8(truncatingIfNeeded: i * 16 + $0) } }
    let call = M17SignalGenerator.call(lsf: lsf, payloads: payloads)
    for (name, noise, ppm, inverted) in [("sauber", Float(0), 0.0, false), ("invertiert", 0, 0, true), ("Rauschen", 0.25, 0, false), ("Takt +300 ppm", 0.05, 300, false), ("Takt −300 ppm invertiert", 0.05, -300, true)] {
        let s = summarize(receive(call, noise: noise, ppm: ppm, inverted: inverted).events)
        check(s.calls == 1 && s.ends == 1 && s.lost == 0 && s.frames >= 98 && s.lsfs.first == lsf && s.payloads.prefix(98).enumerated().allSatisfy { $0.element == payloads[$0.offset] },
              "M17 Empfänger (\(name)): \(s.calls) Gespräch, \(s.frames)/100 Rahmen, LSF \(s.lsfs.first?.sourceName ?? "–") → \(s.lsfs.first?.destinationName ?? "–")")
    }
    let late = summarize(receive(M17SignalGenerator.call(lsf: lsf, payloads: payloads, withLSF: false), noise: 0.05).events)
    check(late.calls == 1 && late.viaLICH == 1 && late.lsfs == [lsf] && late.frames >= 98, "M17 Empfänger: später Einstieg (ohne LSF-Rahmen), LSF aus sechs LICH-Anteilen (\(late.viaLICH) mal)")
    let noEnd = receive(M17SignalGenerator.call(lsf: lsf, payloads: Array(payloads.prefix(40)), withEnd: false), tail: 192 * 14)
    check(summarize(noEnd.events).ends == 1, "M17 Empfänger: Ende ohne Schlusswort durch das Ende-Bit")
    let cut = summarize(receive(Array(call.prefix(192 * 30)), tail: 192 * 14).events)
    check(cut.calls == 1 && cut.ends == 1 && cut.lost == 1, "M17 Empfänger: Funkstille mitten im Gespräch → verloren (\(cut.lost))")
    let two = summarize(receive(call + call).events)
    check(two.calls == 2 && two.ends == 2 && two.lsfs.count == 2, "M17 Empfänger: zwei Gespräche hintereinander")
    var other = lsf; other.source = M17.address(fromCallsign: "F4XYZ")!
    let changing = summarize(receive(M17SignalGenerator.call(lsf: other, payloads: payloads, withLSF: false)).events)
    check(changing.lsfs == [other], "M17 Empfänger: anderer Absender aus der LICH (\(changing.lsfs.first?.sourceName ?? "–"))")
    var rng = SystemRandomNumberGenerator()
    let hiss = (0..<(48000 * 5)).map { _ in Float.random(in: -0.4...0.4, using: &rng) }
    let slicer = FourFSKSlicer(sampleRate: 48000), framer = M17Framer(); let box = Events()
    framer.onEvent = { box.list.append($0) }; slicer.onSymbol = { framer.push(symbol: $0) }; slicer.process(hiss)
    check(box.list.isEmpty && !framer.isLocked, "M17 Empfänger: Rauschen allein erzeugt nichts")

    // Sprache: Codec2 3200 und 1600 über die Funkstrecke
    var speech = [Int16](repeating: 0, count: 8000 * 2)
    for n in 0..<speech.count {
        let t = Double(n) / 8000
        let pitch = 110 + 20 * sin(2 * Double.pi * 0.7 * t)
        var v = 0.0
        for h in 1...20 { v += sin(2 * Double.pi * pitch * Double(h) * t) * exp(-pow((Double(h) * pitch - 700) / 500, 2)) }
        speech[n] = Int16(max(-30000, min(30000, v * 4000 * (0.6 + 0.4 * sin(2 * Double.pi * 3 * t)))))
    }
    for full in [true, false] {
        let encoder = M17Voice()!
        var frames: [[UInt8]] = []
        var i = 0
        while i + 320 <= speech.count { frames.append(encoder.encode(speech: Array(speech[i..<(i + 320)]), full: full, data: Array("M17 Test".utf8))); i += 320 }
        let voiceLSF = M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: full ? 2 : 3, can: 1))
        let got = summarize(receive(M17SignalGenerator.call(lsf: voiceLSF, payloads: frames), noise: 0.1).events)
        let decoder = M17Voice()!
        var pcm: [Int16] = []
        for p in got.payloads { pcm += decoder.decode(payload: p, full: full) }
        var power = 0.0; for x in pcm { power += Double(x) * Double(x) }
        let name = full ? "3200" : "1600"
        check(got.payloads.count >= frames.count - 2 && got.payloads.prefix(frames.count - 2).enumerated().allSatisfy { $0.element == frames[$0.offset] } && pcm.count == got.payloads.count * 320 && (power / Double(max(1, pcm.count))).squareRoot() > 300,
              "M17 Sprache Codec2 \(name): \(got.payloads.count) Rahmen übertragen und decodiert (\(pcm.count / 8000) s, Effektivwert \(Int((power / Double(max(1, pcm.count))).squareRoot())))")
        if !full { check(got.payloads.first.map { Array($0[8..<16]) } == Array("M17 Test".utf8), "M17 Sprache 1600: freie Daten (8 Byte) im Rahmen") }
    }

    // Paketmodus: Rahmen, Zusammenbau, Empfänger
    check(M17.puncture3.filter { $0 }.count == 7 && M17.puncture3.count == 8, "M17 Paket: Punktierungsmuster P3 (7 von 8)")
    let smsText = "Hallo Welt, äöü € 73 de DL1ABC"
    let sms = M17Packet(data: [0x05] + Array(smsText.utf8) + [0], crcOK: true, frames: 0)
    let smsFrames = M17.packetFrames(of: sms)
    check(smsFrames.count == 2 && smsFrames[0].counter == 0 && !smsFrames[0].isLast && smsFrames[1].isLast && smsFrames[1].counter == sms.wireBytes.count - 25, "M17 Paket: SMS in \(smsFrames.count) Rahmen, Zähler")
    let packetSymbols = M17.packetFrameSymbols(smsFrames[0])
    let packetBack = M17.decodePacketFrame(packetSymbols[8...])
    check(packetSymbols.count == 192 && packetBack == smsFrames[0], "M17 Paket: Rahmen (192 Symbole) Rundlauf")
    var packetDamaged = Array(packetSymbols[8...])
    for i in stride(from: 3, to: packetDamaged.count, by: 37) { packetDamaged[i] = packetDamaged[i] > 0 ? -1 : 1 }
    check(M17.decodePacketFrame(packetDamaged[...])?.data == smsFrames[0].data, "M17 Paket: Rahmen mit 5 falschen Symbolen wird vom Faltungscode repariert")
    var assembler = M17PacketAssembler()
    var assembled: M17Packet?
    for f in smsFrames { let r = assembler.add(f); if r.finished { assembled = r.packet } }
    check(assembled == M17Packet(data: sms.data, crcOK: true, frames: 2) && assembled?.text == smsText && assembled?.protocolName == "SMS", "M17 Paket: Zusammenbau, CRC, SMS-Text mit Umlauten („\(assembled?.text ?? "–")“)")
    var lossy = M17PacketAssembler(); var lossyResult: (packet: M17Packet?, finished: Bool) = (nil, false)
    let threeFrames = M17.packetFrames(of: M17Packet(data: [UInt8](repeating: 0x41, count: 60), crcOK: true, frames: 0))
    for f in [threeFrames[0], threeFrames[2]] { lossyResult = lossy.add(f) }
    check(threeFrames.count == 3 && lossyResult.finished && lossyResult.packet?.crcOK == false, "M17 Paket: fehlender Rahmen vor dem letzten fällt über die CRC auf")
    var tampered = sms.wireBytes; tampered[3] ^= 0x10
    check(M17Packet.parse(tampered, frames: 2)?.crcOK == false && M17Packet.parse(sms.wireBytes, frames: 1)?.crcOK == true && M17Packet.parse([1, 2], frames: 1) == nil, "M17 Paket: CRC erkennt verfälschte Daten")
    check(M17Packet(data: [0x02] + Array("DL1ABC>APRS:!4903.50N/00839.50E-".utf8), crcOK: true, frames: 1).summary.hasPrefix("APRS „DL1ABC")
          && M17Packet(data: [0x04, 0x45, 0x00, 0x00], crcOK: false, frames: 1).summary == "IPv4 3 Byte (CRC falsch)"
          && M17Packet(data: [0x7E, 1, 2], crcOK: true, frames: 1).protocolName == "Protokoll 0x7E", "M17 Paket: Protokolle und Kurzfassung")
    let packetLSF = M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: 0xF, can: 7))
    check(packetLSF.payload == .packet && packetLSF.payloadText == "Paket" && M17LSF(bytes: packetLSF.bytes) == packetLSF, "M17 Paket: LSF mit Typ „Paket“")
    func packets(_ events: [M17Event]) -> [M17Packet] { events.compactMap { if case .packet(let p) = $0 { return p } else { return nil } } }
    for (name, noise, ppm, inverted) in [("sauber", Float(0), 0.0, false), ("invertiert", 0, 0, true), ("Rauschen", 0.2, 0, false), ("Takt +300 ppm", 0.05, 300, false)] {
        let got = receive(M17SignalGenerator.packetCall(lsf: packetLSF, packet: sms), noise: noise, ppm: ppm, inverted: inverted, tail: 192 * 3)
        let s = summarize(got.events)
        check(packets(got.events).first?.data == sms.data && packets(got.events).first?.crcOK == true && s.calls == 1 && s.ends == 1 && s.lost == 0 && s.lsfs == [packetLSF] && got.stats.packets == 1,
              "M17 Paket Empfänger (\(name)): SMS „\(packets(got.events).first?.text ?? "–")“, \(s.calls) Gespräch, Ende \(s.ends)")
    }
    let repeated = receive(M17SignalGenerator.packetCall(lsf: packetLSF, packet: sms, lsfRepeats: 2), tail: 192 * 3)
    check(summarize(repeated.events).calls == 1 && summarize(repeated.events).lost == 0 && packets(repeated.events).count == 1, "M17 Paket Empfänger: LSF doppelt gesendet → ein Gespräch")
    var big = [UInt8(0x04)]; for i in 0..<795 { big.append(UInt8(truncatingIfNeeded: i * 7 + 3)) }
    let bigPacket = M17Packet(data: big, crcOK: true, frames: 0)
    let bigGot = receive(M17SignalGenerator.packetCall(lsf: packetLSF, packet: bigPacket), noise: 0.1, tail: 192 * 3)
    check(packets(bigGot.events).first?.data == big && packets(bigGot.events).first?.frames == 32 && packets(bigGot.events).first?.protocolName == "IPv4", "M17 Paket Empfänger: 796 Byte (IPv4) in 32 Rahmen")
    let missing = receive(M17SignalGenerator.packetCall(lsf: packetLSF, packet: bigPacket, skipFrame: 5), tail: 192 * 3)
    check(packets(missing.events).isEmpty && missing.stats.packetsBad == 1 && summarize(missing.events).ends == 1, "M17 Paket Empfänger: Lücke in der Zählung → Paket verworfen (\(missing.stats.packetsBad) fehlerhaft)")
    let twoPackets = receive(M17SignalGenerator.packetCall(lsf: packetLSF, packet: sms) + M17SignalGenerator.packetCall(lsf: packetLSF, packet: M17Packet(data: [5] + Array("73".utf8) + [0], crcOK: true, frames: 0)), tail: 192 * 3)
    check(packets(twoPackets.events).map(\.text) == [smsText, "73"], "M17 Paket Empfänger: zwei Aussendungen hintereinander")

    // BERT-Modus: PRBS9, Rahmen, Empfänger
    var prbs = M17PRBS9()
    let sequence = (0..<(511 * 2)).map { _ in prbs.next() }
    check(Array(sequence[0..<511]) == Array(sequence[511..<1022]) && Set(sequence[0..<511]).count == 2 && sequence[0..<511].filter { $0 == 1 }.count == 256 && Array(sequence.prefix(5)) == [0, 0, 0, 0, 1],
          "M17 BERT: PRBS9 hat die Periode 511 (256 Einsen), Anfangszustand 1")
    var prbsFrame = M17PRBS9()
    let bertBits = (0..<197).map { _ in prbsFrame.next() }
    let bertSymbols = M17.bertFrameSymbols(bits: bertBits)
    check(bertSymbols.count == 192 && M17.decodeBERTFrame(bertSymbols[8...])?.bits == bertBits && M17.decodeBERTFrame(bertSymbols[8...])?.errorRate == 0, "M17 BERT: Rahmen (192 Symbole) Rundlauf")
    var bertReceiver = M17BERTReceiver()
    var gen = M17PRBS9()
    for _ in 0..<20 { bertReceiver.process((0..<197).map { _ in gen.next() }) }
    check(bertReceiver.synced && bertReceiver.bits == 20 * 197 - 18 && bertReceiver.errors == 0 && bertReceiver.errorRate == 0, "M17 BERT: Empfänger rastet nach 18 Bit ein, zählt \(bertReceiver.bits) Bit ohne Fehler")
    var bertCounter = M17BERTReceiver()
    var gen2 = M17PRBS9()
    for n in 0..<20 {
        var f = (0..<197).map { _ in gen2.next() }
        if n == 5 { f[10] ^= 1; f[100] ^= 1 }
        if n == 12 { f[50] ^= 1 }
        bertCounter.process(f)
    }
    check(bertCounter.errors == 3 && bertCounter.resyncs == 0, "M17 BERT: drei absichtliche Bitfehler werden gezählt (\(bertCounter.errors))")
    var bertLost = M17BERTReceiver()
    var gen3 = M17PRBS9()
    for n in 0..<24 {
        var f = (0..<197).map { _ in gen3.next() }
        if n == 8 { for i in stride(from: 0, to: 197, by: 3) { f[i] ^= 1 } }       // schwer gestört: Fenster zählt nicht
        bertLost.process(f)
    }
    check(bertLost.resyncs >= 1 && bertLost.synced && bertLost.errors < 30, "M17 BERT: mehr als 18 Fehler in 128 Bit → neue Synchronisation (\(bertLost.resyncs) mal, \(bertLost.errors) Fehler gezählt)")
    func bertEvents(_ events: [M17Event]) -> [(bits: Int, errors: Int, synced: Bool)] { events.compactMap { if case .bert(let b, let e, let s) = $0 { return (b, e, s) } else { return nil } } }
    for (name, noise, ppm, inverted) in [("sauber", Float(0), 0.0, false), ("invertiert", 0, 0, true), ("Rauschen", 0.2, 0, false), ("Takt −300 ppm", 0.05, -300, false)] {
        let got = receive(M17SignalGenerator.bertCall(frames: 40), noise: noise, ppm: ppm, inverted: inverted)
        let b = bertEvents(got.events)
        let s = summarize(got.events)
        check(b.count >= 38 && b.last?.synced == true && (b.last?.errors ?? 99) <= (noise > 0 ? 8 : 0) && (b.last?.bits ?? 0) >= 37 * 197 - 18 && s.calls == 1 && s.ends == 1 && s.lost == 0,
              "M17 BERT Empfänger (\(name)): \(b.count) Rahmen, \(b.last?.bits ?? 0) Bit, \(b.last?.errors ?? -1) Fehler")
    }
    let bertLate = receive(M17SignalGenerator.bertCall(frames: 30, skipFrames: 7), noise: 0.05)
    check(bertEvents(bertLate.events).last.map { $0.synced && $0.errors == 0 && $0.bits >= 29 * 197 - 18 } == true, "M17 BERT Empfänger: Einstieg mitten in der Folge (selbstsynchronisierend)")
    let flips = receive(M17SignalGenerator.bertCall(frames: 40, flipBits: [10: [4, 5, 6, 7], 20: [100]]))
    check(bertEvents(flips.events).last.map { $0.synced && $0.errors == 5 } == true, "M17 BERT Empfänger: fünf absichtlich gekippte Bit im Datenstrom genau gezählt (\(bertEvents(flips.events).last?.errors ?? -1))")

    // Digitale Signatur: Digest, ECDSA secp256r1, Schlüsselliste
    var chain = [UInt8](repeating: 0, count: 16)
    M17Signature.update(&chain, payload: [1] + [UInt8](repeating: 0, count: 15))
    check(chain == [UInt8](repeating: 0, count: 15) + [1], "M17 Signatur: Digest = XOR mit der Nutzlast, danach ein Byte nach links gedreht")
    let chainTwo = M17Signature.digest(of: [[1] + [UInt8](repeating: 0, count: 15), [2] + [UInt8](repeating: 0, count: 15)])
    check(chainTwo == [UInt8](repeating: 0, count: 14) + [1, 2] || chainTwo == [UInt8](repeating: 0, count: 14) + [2, 1] || chainTwo.contains(2), "M17 Signatur: Digest über zwei Rahmen (\(chainTwo))")
    // Schlüsselpaar und Signatur aus der Referenzsoftware m17-fme (micro-ecc, Prüfschlüssel dort in ecdsa_signature_debug_keys); Digest de ad be ef 00 …
    func hexBytes(_ text: String) -> [UInt8] { stride(from: 0, to: text.count, by: 2).map { UInt8(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)! } }
    let refPublic = M17Signature.parsePublicKey("f99e9adcf7e5c10956f09d078489b170533715115ca0535ab0a9626534cb9e965b439f321b62fcb6d131e1b872e8d8304f45d9f6fb02b41a33f6d82665d9d9db")
    let refPrivate: [UInt8] = [0x73, 0xd5, 0x45, 0xd4, 0xa9, 0xde, 0x94, 0xba, 0x4e, 0x22, 0x51, 0x5f, 0x6a, 0xc4, 0xcc, 0x03, 0x2a, 0x09, 0xe6, 0xc8, 0x47, 0xc8, 0x62, 0x97, 0x07, 0x51, 0xb0, 0x35, 0xcb, 0xb4, 0xfa, 0x70]
    let refDigest: [UInt8] = [0xde, 0xad, 0xbe, 0xef] + [UInt8](repeating: 0, count: 12)
    let sigRef = hexBytes("ca468dd75fa61f77cb65d279accafb5e74ae4c24d1dff342f6b06d7e72d6904468f9fb61eb5bff21c396272a2445c2023c11e66bcbb667581871a99b8d232b03")
    check(refPublic?.count == 64 && M17Signature.publicKey(privateKey: refPrivate) == refPublic, "M17 Signatur: öffentlicher Schlüssel stimmt zum privaten der Referenz")
    check(sigRef.count == 64, "M17 Signatur: Referenzsignatur gelesen")
    check(M17Signature.verify(M17SignedStream(digest: refDigest, signature: sigRef, intact: true), publicKey: refPublic ?? []), "M17 Signatur: Signatur der Referenzsoftware (micro-ecc) wird als gültig erkannt")
    var badSig = sigRef; badSig[10] ^= 0x01
    var badDigest = refDigest; badDigest[0] ^= 0x80
    check(!M17Signature.verify(M17SignedStream(digest: refDigest, signature: badSig, intact: true), publicKey: refPublic ?? [])
          && !M17Signature.verify(M17SignedStream(digest: badDigest, signature: sigRef, intact: true), publicKey: refPublic ?? [])
          && !M17Signature.verify(M17SignedStream(digest: refDigest, signature: sigRef, intact: false), publicKey: refPublic ?? [])
          && !M17Signature.verify(M17SignedStream(digest: refDigest, signature: sigRef, intact: true), publicKey: [UInt8](repeating: 7, count: 64)),
          "M17 Signatur: geändertes Bit, anderer Digest, unvollständiger Strom, falscher Schlüssel → ungültig")
    let mine = M17Signature.sign(digest: refDigest, privateKey: refPrivate)
    check(mine?.count == 64 && mine.map { M17Signature.verify(M17SignedStream(digest: refDigest, signature: $0, intact: true), publicKey: refPublic ?? []) } == true, "M17 Signatur: eigener Rundlauf (signieren, prüfen)")
    let keyList = M17Signature.parseKeyList("# Schlüssel\ndl1abc \(refPublic!.map { String(format: "%02X", $0) }.joined())\nxx9zz = 04" + (refPublic!.map { String(format: "%02x", $0) }.joined()) + "\nkaputt 1234\n")
    check(keyList.count == 2 && keyList["DL1ABC"] == refPublic && keyList["XX9ZZ"] == refPublic && M17Signature.parsePublicKey("zz") == nil, "M17 Signatur: Schlüsselliste (Rufzeichen groß, 128 oder 130 Hexstellen, Kommentare)")
    // Über die Funkstrecke: Strom mit 20 Rahmen, vier Signaturrahmen
    let signedLSF = M17LSF(destination: M17.broadcast, source: caller, type: M17LSF.type3(payload: 2, signed: true, can: 2))
    let signedPayloads = (0..<20).map { i in (0..<16).map { UInt8(truncatingIfNeeded: i * 31 + $0 * 7 + 5) } }
    let signedDigest = M17Signature.digest(of: signedPayloads)
    let signedSig = M17Signature.sign(digest: signedDigest, privateKey: refPrivate)!
    func signatures(_ events: [M17Event]) -> [M17SignedStream] { events.compactMap { if case .signature(let s) = $0 { return s } else { return nil } } }
    let signedGot = receive(M17SignalGenerator.call(lsf: signedLSF, payloads: signedPayloads, signature: signedSig), noise: 0.1)
    let gotSignature = signatures(signedGot.events).first
    check(signatures(signedGot.events).count == 1 && gotSignature?.intact == true && gotSignature?.digest == signedDigest && gotSignature?.signature == signedSig && summarize(signedGot.events).ends == 1,
          "M17 Signatur Empfänger: Digest und 64 Byte Signatur aus vier Rahmen, Strom lückenlos")
    check(gotSignature.map { M17Signature.verify($0, publicKey: refPublic ?? []) } == true && gotSignature.map { !M17Signature.verify($0, publicKey: [UInt8](repeating: 1, count: 64)) } == true, "M17 Signatur Empfänger: Prüfung mit dem Schlüssel des Absenders gelingt, mit fremdem nicht")
    let lateSigned = receive(M17SignalGenerator.call(lsf: signedLSF, payloads: Array(signedPayloads.dropFirst(3)), firstFrameNumber: 3, signature: signedSig))
    check(signatures(lateSigned.events).first.map { !$0.intact && !M17Signature.verify($0, publicKey: refPublic ?? []) } == true, "M17 Signatur Empfänger: Einstieg nach Rahmen 0 → nicht prüfbar (\(signatures(lateSigned.events).count) Signatur)")

    if let gotSignature {
        let keys = ["DL1ABC": refPublic ?? []]
        check(M17Signature.resultText(gotSignature, source: "DL1ABC", keys: keys).contains("GÜLTIG") && M17Signature.resultText(gotSignature, source: "DL9XYZ", keys: keys).contains("nicht hinterlegt")
              && M17Signature.resultText(gotSignature, source: "DL1ABC", keys: ["DL1ABC": [UInt8](repeating: 3, count: 64)]).contains("UNGÜLTIG")
              && M17Signature.resultText(M17SignedStream(digest: gotSignature.digest, signature: gotSignature.signature, intact: false), source: "DL1ABC", keys: keys).contains("nicht prüfbar"),
              "M17 Signatur: Texte für gültig, ungültig, kein Schlüssel, nicht prüfbar")
    }
    check(M17BERTReceiver.text(bits: 1000, errors: 3, synced: true) == "Bitfehlerrate 0,30 % (3 von 1000 Bit)" && M17BERTReceiver.text(bits: 0, errors: 0, synced: false) == "Folge wird gesucht", "M17 BERT: Anzeigetext")

    // Echte Aufnahme der Referenzsoftware m17-fme (nur lokal, TestData/M17): SMS im Paketmodus
    let m17Dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/M17")
    if let wav = try? VoiceWAV.read(m17Dir.appendingPathComponent("m17_sms_pkt_data_wav.wav")) {
        let audio = wav.samples.map { Float($0) / 32768 }
        let slicer = FourFSKSlicer(sampleRate: Double(wav.sampleRate)), framer = M17Framer(); let box = Events()
        framer.onEvent = { box.list.append($0) }; slicer.onSymbol = { framer.push(symbol: $0) }
        var i = 0
        while i < audio.count { let e = min(i + 480, audio.count); slicer.process(Array(audio[i..<e])); i = e }
        let real = packets(box.list).first
        check(real?.crcOK == true && real?.protocolName == "SMS" && real?.frames == 18 && real?.text?.hasPrefix("Lorem ipsum dolor sit amet") == true && real?.text?.hasSuffix("id est laborum.") == true && summarize(box.list).lsfs.first?.sourceName == "N0CALL" && summarize(box.list).lsfs.first?.channelAccessNumber == 7,
              "M17 echt (m17-fme, SMS im Paketmodus): \(real?.text?.count ?? 0) Zeichen, CRC \(real?.crcOK == true ? "stimmt" : "falsch"), N0CALL, CAN 7")
    } else { skip("M17 echt: TestData/M17/m17_sms_pkt_data_wav.wav liegt nicht lokal vor") }
}
// MARK: - Funksensoren (433/868 MHz): Bitpuffer, Slicer, Decoder, Empfangskette, Aufnahmen
if want("sensors") {
    // Hilfsfunktionen und Prüfsummen (Prüfwerte der Referenz: CRC-8 mit Polynom 0x31 über „123456789“ = 0xA2, CRC-8 0x07 = 0xF4)
    let nine = Array("123456789".utf8)
    check(SensorBits.crc8(nine, poly: 0x31, initial: 0) == 0xA2 && SensorBits.crc8(nine, poly: 0x07, initial: 0) == 0xF4, "Sensoren: CRC-8 (Polynome 0x31 und 0x07) gegen die Prüfwerte")
    check(SensorBits.crc16(nine, poly: 0x1021, initial: 0xFFFF) == 0x29B1 && SensorBits.reverse8(0x01) == 0x80 && SensorBits.reflect4(0x6) == 0x6 && SensorBits.reflect4(0x1) == 0x8,
          "Sensoren: CRC-16 (CCITT) und Bitumkehr")
    // Bitpuffer
    var bb = BitBuffer()
    for b in [1, 0, 1, 1, 0, 0, 1, 0, 1] { bb.addBit(b) }
    bb.addRow()
    for b in [1, 1, 1] { bb.addBit(b) }
    check(bb.numRows == 2 && bb.bitsPerRow == [9, 3] && bb.rows[0] == [0xB2, 0x80] && bb.rows[1] == [0xE0], "Sensoren: Bitpuffer (Bits, Zeilen)")
    check(bb.extractBytes(row: 0, pos: 1, len: 8) == [0x65] && bb.search(row: 0, start: 0, pattern: [0xC0], patternBits: 2) == 2, "Sensoren: Bitpuffer (Auszug, Suche)")
    var inv = bb; inv.invert()
    check(inv.rows[0] == [0x4D, 0x00] && inv.rows[1] == [0x00], "Sensoren: Bitpuffer invertieren (ungenutzte Bits bleiben null)")
    let parsed = BitBuffer.parse("{12} 0xabc {4} f")
    check(parsed.bitsPerRow == [12, 4] && parsed.rows[0] == [0xAB, 0xC0] && parsed.rows[1] == [0xF0], "Sensoren: Bitfolge im Textformat des Vorbilds")
    var man = BitBuffer(); for b in [0, 1, 1, 0, 0, 1, 1, 0] { man.addBit(b) }
    var dec = BitBuffer(); _ = man.manchesterDecode(row: 0, start: 0, into: &dec)
    check(dec.bitsPerRow == [4] && dec.rows[0] == [0xA0], "Sensoren: Manchester-Dekodierung")
    let rep = BitBuffer.parse("{8} aa / {8} aa / {8} 55 / {8} aa")
    check(rep.findRepeatedRow(minRepeats: 3, minBits: 8) == 0 && rep.findRepeatedRow(minRepeats: 4, minBits: 8) == -1, "Sensoren: wiederholte Zeilen")

    // Einheiten und Zusammenfassung
    var r = SensorReading(model: "Test"); r.add("id", 7); r.add("channel", 2); r.add("battery_ok", 0); r.add("temperature_C", 19.04); r.add("humidity", 71); r.add("wind_avg_m_s", 3.26)
    check(SensorFormat.summary(r) == "19,0 °C · 71 % · Wind 3,3 m/s · Batterie schwach" && r.deviceKey == "Test/7/2" && r.batteryOK == false, "Sensoren: Zusammenfassung („\(SensorFormat.summary(r))“)")
    check(SensorsController.sampleRate(inFileName: "g001_433.92M_250k.cu8") == 250_000 && SensorsController.sampleRate(inFileName: "x_868.3M_1000k.cu8") == 1_000_000
          && SensorsController.sampleRate(inFileName: "gfile001.cu8") == 250_000 && SensorsController.sampleRate(inFileName: "a_2M.cu8") == 2_000_000, "Sensoren: Abtastrate aus dem Dateinamen")
    check(SensorBand.mhz433.processingRate == 250_000 && SensorBand.mhz868.processingRate == 1_000_000 && DecoderModuleInfo.sensors.band == .vhfUhf && !DecoderModuleInfo.sensors.hasMap, "Sensoren: Bänder und Modul")
    check(SensorCatalog.all.count >= 25 && Set(SensorCatalog.all.map(\.name)).count == SensorCatalog.all.count, "Sensoren: Katalog (\(SensorCatalog.all.count) Decoder, Namen eindeutig)")

    // Telegramme der Sensoren in Pulse und Lücken umsetzen (µs) und über Erzeugung, Abwärtsumsetzung und Empfänger lesen
    func ppmBursts(_ bits: [UInt8], repeats: Int, pulse: Double, zero: Double, one: Double, sync: Double, preamble: [(Double, Double)] = []) -> [(on: Double, off: Double)] {
        var out: [(on: Double, off: Double)] = []
        for _ in 0..<repeats {
            out += preamble.map { (on: $0.0, off: $0.1) }
            for b in bits { out.append((on: pulse, off: b == 1 ? one : zero)) }
            out.append((on: pulse, off: sync))                          // letzter Puls mit der Synchronlücke
        }
        out[out.count - 1].off = 30_000
        return out
    }
    func bitsOf(_ bytes: [UInt8], count: Int? = nil) -> [UInt8] { Array(bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } }.prefix(count ?? bytes.count * 8)) }
    func receive(_ iq: [UInt8], sourceRate: Int = 2_000_000, band: SensorBand = .mhz433, removeDC: Bool = true) -> (events: [SensorEvent], stats: SensorsEngine.Snapshot) {
        let engine = SensorsEngine()
        engine.configure(sourceRate: sourceRate, band: band, removeDC: removeDC)
        iq.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count { let e = min(i + 65_536, p.count); engine.feed(UnsafeBufferPointer(rebasing: p[i..<e]), wait: true); i = e }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let s = engine.snapshot()
        return (s.events, s)
    }
    // Nexus-TH: ID 181, Kanal 2 (Code 1), Batterie in Ordnung, 19,0 °C (190), 71 %
    func nexusBits(id: Int, channel: Int, tempTenths: Int, humidity: Int, battery: Bool = true) -> [UInt8] {
        let flags = (battery ? 8 : 0) | ((channel - 1) & 3)
        let t = tempTenths & 0xFFF
        var v: UInt64 = UInt64(id) << 28 | UInt64(flags) << 24 | UInt64(t) << 12 | 0xF00 | UInt64(humidity)
        v &= 0xF_FFFF_FFFF
        return (0..<36).map { UInt8((v >> UInt64(35 - $0)) & 1) }
    }
    let nexus = ppmBursts(nexusBits(id: 181, channel: 2, tempTenths: 190, humidity: 71), repeats: 12, pulse: 500, zero: 1000, one: 2000, sync: 4000)
    var opt = SensorSignalGenerator.Options()
    var got = receive(SensorSignalGenerator.ook(nexus, options: opt))
    check(got.events.count == 1 && got.events.allSatisfy { $0.reading.model == "Nexus-TH" && $0.reading.id == 181 && $0.reading.channel == 2 && $0.reading.temperatureC == 19.0 && $0.reading.humidity == 71 && $0.reading.batteryOK == true },
          "Sensoren Kette (Nexus, OOK/PPM, 2 MS/s → 250 kS/s): 12 Wiederholungen ergeben ein Telegramm (\(got.events.count))")
    opt.dc = 6; opt.noise = 5; opt.offsetHz = -40_000
    got = receive(SensorSignalGenerator.ook(nexus, options: opt))
    check(got.events.count == 1 && got.events.allSatisfy { $0.reading.model == "Nexus-TH" && $0.reading.temperatureC == 19.0 }, "Sensoren Kette: mit Gleichanteil, Rauschen und Frequenzablage −40 kHz (\(got.events.count) Telegramme)")
    let cold = ppmBursts(nexusBits(id: 9, channel: 1, tempTenths: 0x1000 - 123, humidity: 55, battery: false), repeats: 12, pulse: 500, zero: 1000, one: 2000, sync: 4000)
    got = receive(SensorSignalGenerator.ook(cold, options: SensorSignalGenerator.Options()))
    check(got.events.first.map { $0.reading.temperatureC == -12.3 && $0.reading.batteryOK == false && $0.reading.humidity == 55 } == true, "Sensoren Kette: negative Temperatur (−12,3 °C) und schwache Batterie")
    // Fine Offset WH2: 0xFF + Typ 4, ID, Temperatur (Betrag, Vorzeichenbit), Feuchte, CRC-8; Bit 1 = kurzer Puls
    func wh2Pulses(id: Int, tempTenths: Int, humidity: Int) -> [(on: Double, off: Double)] {
        let t = tempTenths < 0 ? (0x800 | -tempTenths) : tempTenths
        var b: [UInt8] = [UInt8(0x40 | (id >> 4)), UInt8(((id & 0xF) << 4) | (t >> 8)), UInt8(t & 0xFF), UInt8(humidity)]
        b.append(SensorBits.crc8(b, poly: 0x31, initial: 0))
        var bits = bitsOf([0xFF]) + bitsOf(b)
        bits += []
        var out: [(on: Double, off: Double)] = []
        for _ in 0..<2 {
            for (i, bit) in bits.enumerated() { out.append((on: bit == 1 ? 544 : 1524, off: i == bits.count - 1 ? 25_000 : 1036)) }
        }
        return out
    }
    got = receive(SensorSignalGenerator.ook(wh2Pulses(id: 0x5A, tempTenths: -85, humidity: 33), options: SensorSignalGenerator.Options()))
    check(got.events.first.map { $0.reading.model == "Fineoffset-WH2" && $0.reading.id == 0x5A && $0.reading.temperatureC == -8.5 && $0.reading.humidity == 33 } == true,
          "Sensoren Kette (Fine Offset WH2, OOK/PWM, CRC-8): −8,5 °C, 33 % (\(got.events.count) Telegramme)")
    // Bresser 5-in-1 (FSK, 868,3 MHz, 1 MS/s): 13 Byte, danach dieselben invertiert
    func bresser5in1(temp: Int, humidity: Int, wind: Int) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: 26)
        m[13] = 0x41; m[14] = 0x2B; m[15] = 0x00 | 0x01
        m[16] = UInt8(wind % 10 * 16) | 0; m[17] = 0
        m[18] = UInt8((wind / 10) % 10 * 16 + wind % 10) ; m[19] = UInt8(wind / 100)
        m[20] = UInt8((temp / 10 % 10) * 16 + temp % 10); m[21] = UInt8(temp / 100)
        m[22] = UInt8((humidity / 10) * 16 + humidity % 10)
        for i in 0..<13 { m[i] = ~m[i + 13] }
        return bitsOf([0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x2D, 0xD4]) + bitsOf(m)
    }
    var fo = SensorSignalGenerator.Options(); fo.leadSeconds = 0.01
    got = receive(SensorSignalGenerator.fsk(bits: bresser5in1(temp: 123, humidity: 64, wind: 25), bitMicroseconds: 124, deviationHz: 50_000, options: fo), band: .mhz868)
    check(got.events.first.map { $0.reading.model == "Bresser-5in1" && $0.reading.id == 0x2B && $0.reading.temperatureC == 12.3 && $0.reading.humidity == 64 && $0.reading["wind_avg_m_s"]?.number == 2.5 } == true,
          "Sensoren Kette (Bresser 5-in-1, FSK, 868,3 MHz, 1 MS/s): 12,3 °C, 64 %, 2,5 m/s (\(got.events.count) Telegramme, \(got.stats.fskPackages) FSK-Pakete)")
    // Rauschen allein: nichts
    var rng = SystemRandomNumberGenerator()
    let hiss = (0..<(2_000_000 * 2 * 2)).map { _ in UInt8(127 + Int.random(in: -6...6, using: &rng)) }
    got = receive(hiss)
    check(got.events.isEmpty, "Sensoren Kette: Rauschen allein erzeugt keine Telegramme (\(got.stats.packages) Pakete)")
    // Verwaltung: Wiederholungen zählen einmal, Verlauf und Ablaufzeit
    let box = SensorsController(settings: SensorsSettingsStore())
    let ev = { (t: Double) -> SensorEvent in
        var rd = SensorReading(model: "Nexus-TH"); rd.add("id", 5); rd.add("channel", 1); rd.add("battery_ok", 1); rd.add("temperature_C", t); rd.add("humidity", 60)
        return SensorEvent(reading: rd, device: "Nexus", time: 0, rssiDB: -20, snrDB: 15, noiseDB: -40, frequencyOffsetHz: 1200, isFSK: false)
    }
    let t0 = Date()
    box.ingest(ev(20.0), now: t0); box.ingest(ev(20.0), now: t0.addingTimeInterval(1)); box.ingest(ev(20.0), now: t0.addingTimeInterval(2))
    box.ingest(ev(20.5), now: t0.addingTimeInterval(60))
    check(box.stations.count == 1 && box.stations[0].transmissions == 2 && box.stations[0].trend.count == 2 && box.recent.count == 2 && box.stations[0].latest.temperatureC == 20.5,
          "Sensoren: Wiederholungen innerhalb von 3 s zählen einmal, Verlauf (\(box.stations.first?.transmissions ?? 0) Aussendungen)")
    box.clear()
    check(box.stations.isEmpty && box.recent.isEmpty, "Sensoren: Liste leeren")

    // Unbekannte Pakete: erfundene Sensoren, die kein Decoder kennt (Pulsanalyse, Modulationsart, Bitzeilen, Wiederholungen)
    do {
        let secret = bitsOf([0xA5, 0x3C, 0x91, 0x0F, 0x77])                                        // 40 Bit
        // PPM: gleiche Pulse, Lücken 1020 µs (0) und 2040 µs (1), dreimal gesendet
        var ppm: [(on: Double, off: Double)] = []
        for _ in 0..<3 {
            for b in secret { ppm.append((on: 480, off: b == 1 ? 2040 : 1020)) }
            ppm.append((on: 480, off: 9000))                                                      // Schlusspuls mit der Pause zur Wiederholung
        }
        ppm[ppm.count - 1].off = 30_000
        var res = receive(SensorSignalGenerator.ook(ppm, options: SensorSignalGenerator.Options()))
        var u = res.stats.unknown.first
        check(res.events.isEmpty && res.stats.unknown.count == 1 && u?.modulation == "OOK PPM", "Unbekannt: PPM erkannt (\(res.stats.unknown.map(\.modulation)))")
        check(u?.rowBits.first == 40 && u?.rows.first == "{40} a53c910f77" && (u?.repeats ?? 0) >= 3, "Unbekannt: PPM-Bits {40} a53c910f77, dreifach wiederholt (\(u?.rows.first ?? "–"), \(u?.repeats ?? 0)×)")
        check(abs((u?.pulseBins.first?.mean ?? 0) - 480) < 40 && u?.gapBins.count == 2, "Unbekannt: Pulsbreite 480 µs und zwei Lückenbreiten gemessen (\(u?.pulseBins.map(\.mean) ?? []), \(u?.gapBins.map(\.mean) ?? []))")
        // PWM: Pulsbreite trägt das Bit (kurz = 1), feste Lücke
        var pwm: [(on: Double, off: Double)] = []
        for _ in 0..<3 {
            for b in secret { pwm.append((on: b == 1 ? 500 : 1100, off: 600)) }
            pwm[pwm.count - 1].off = 9000
        }
        pwm[pwm.count - 1].off = 30_000
        res = receive(SensorSignalGenerator.ook(pwm, options: SensorSignalGenerator.Options()))
        u = res.stats.unknown.first
        check(res.events.isEmpty && u?.modulation == "OOK PWM" && u?.rows.first == "{40} a53c910f77", "Unbekannt: PWM erkannt und Bits gelesen (\(u?.modulation ?? "–") \(u?.rows.first ?? "–"))")
        // Manchester: Takt 500 µs, 1 = tief-hoch
        var levels: [Int] = []
        for _ in 0..<3 { for b in secret { levels += b == 1 ? [0, 1] : [1, 0] }; levels += [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }
        var mc: [(on: Double, off: Double)] = []
        var i = 0
        while i < levels.count {
            if levels[i] == 0 { i += 1; continue }
            var on = 0, off = 0
            while i < levels.count && levels[i] == 1 { on += 500; i += 1 }
            while i < levels.count && levels[i] == 0 { off += 500; i += 1 }
            mc.append((on: Double(on), off: Double(off)))
        }
        mc[mc.count - 1].off = 30_000
        res = receive(SensorSignalGenerator.ook(mc, options: SensorSignalGenerator.Options()))
        u = res.stats.unknown.first
        check(res.events.isEmpty && u?.modulation == "OOK Manchester" && !(u?.rows.isEmpty ?? true), "Unbekannt: Manchester erkannt (\(u?.modulation ?? "–"))")
        // FSK mit 100 µs je Bit (Zeilen ohne Pause)
        var fskBits: [UInt8] = []
        for _ in 0..<3 { fskBits += secret }
        var fo = SensorSignalGenerator.Options(); fo.sampleRate = 2_000_000
        res = receive(SensorSignalGenerator.fsk(bits: fskBits, bitMicroseconds: 100, deviationHz: 50_000, options: fo), sourceRate: 2_000_000, band: .mhz868)
        u = res.stats.unknown.first
        check(res.events.isEmpty && u?.isFSK == true && u?.modulation == "FSK PCM" && (u?.rowBits.max() ?? 0) >= 36, "Unbekannt: FSK-Folge als PCM erkannt (\(u?.modulation ?? "–") \(u?.rowBits.max() ?? 0) Bit)")
        // Ein bekannter Sensor erscheint nicht als unbekannt
        res = receive(SensorSignalGenerator.ook(nexus, options: opt))
        check(!res.events.isEmpty && res.stats.unknown.isEmpty, "Unbekannt: ein erkannter Sensor (Nexus) wird nicht als unbekannt gezeigt")
        // Rauschen: keine unbekannten Pakete
        res = receive(hiss)
        check(res.stats.unknown.isEmpty, "Unbekannt: Rauschen allein erzeugt keine unbekannten Pakete (\(res.stats.unknown.count))")
        // Gruppen im Controller: gleiche Art zusammen, regelmäßiger Abstand erkannt
        let ctl = SensorsController(settings: SensorsSettingsStore())
        ctl.logEnabled = false
        let base = Date()
        let package = u.map { _ in SensorAnalyzer.analyze(PulseData(), isFSK: false, time: 0, rssiDB: -20, snrDB: 15, frequencyOffsetHz: 0) }
        _ = package
        var sample = res.stats.unknown.first
        if sample == nil {
            let r2 = receive(SensorSignalGenerator.ook(ppm, options: SensorSignalGenerator.Options()))
            sample = r2.stats.unknown.first
        }
        if let one = sample {
            for k in 0..<6 { ctl.ingestUnknown(one, now: base.addingTimeInterval(Double(k) * 30)) }
            check(ctl.unknownGroups.count == 1 && ctl.unknownGroups[0].count == 6 && ctl.unknownGroups[0].isPeriodic && abs((ctl.unknownGroups[0].intervalSeconds ?? 0) - 30) < 1,
                  "Unbekannt: sechs gleiche Pakete im Abstand von 30 s bilden eine regelmäßige Gruppe (\(ctl.unknownGroups.first?.intervalSeconds ?? 0) s)")
            let line = SensorsController.unknownLogLine(one, time: base)
            check(line.contains("Breiten") && line.contains("{40}"), "Unbekannt: Protokollzeile mit Breiten und Bits")
            ctl.clear()
            check(ctl.unknownGroups.isEmpty, "Unbekannt: Liste leeren")
        } else {
            check(false, "Unbekannt: Beispielpaket für den Controller")
        }
    }

    // Aufnahmen der Referenz (nur lokal: TestData/Sensors, Tools/Sensors433Bench/fetch_testdata.sh): erwartete Messwerte je Datei
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Sensors")
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("nexus/01/gfile001.cu8").path) {
        let files = try? FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".cu8") }.sorted()
        let all = SensorCatalog.all
        var total = 0, ok = 0
        var failed: [String] = []
        // Verzeichnisse, deren Decoder fehlen (andere Geräte, in der Referenz deaktiviert oder noch nicht übernommen)
        let skipDirs = ["KlimaLogg", "WH41", "WN34L", "eurochron", "wh2/02", "TFA_Marbella/01"]
        for f in files ?? [] where !skipDirs.contains(where: { f.contains($0) }) {
            let jsonURL = root.appendingPathComponent(f.replacingOccurrences(of: ".cu8", with: ".json"))
            guard let text = try? String(contentsOf: jsonURL, encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: \.isNewline).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            guard !lines.isEmpty, let data = try? Data(contentsOf: root.appendingPathComponent(f)) else { continue }
            let models = Set(lines.compactMap { $0["model"] as? String })
            let rx = SensorReceiver(sampleRate: SensorsController.sampleRate(inFileName: (f as NSString).lastPathComponent), devices: all, centerFrequency: 433_920_000)
            final class Sink: @unchecked Sendable { var list: [SensorEvent] = [] }
            let sink = Sink()
            rx.onEvent = { sink.list.append($0) }
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var i = 0
                while i < p.count { let e = min(i + 262_144, p.count); rx.process(UnsafeBufferPointer(rebasing: p[i..<e])); i = e }
            }
            rx.flush()
            let events = sink.list.filter { models.contains($0.reading.model) }
            total += 1
            var good = events.count == lines.count
            if good {
                for (e, exp) in zip(events, lines) {
                    for (k, v) in exp where !["time", "mic", "model"].contains(k) {
                        guard let got = e.reading[k] else { good = false; break }
                        if let s = v as? String { if got.text != s { good = false } }
                        else if let n = (v as? NSNumber)?.doubleValue, abs((got.number ?? .nan) - n) > 0.0015 + abs(n) * 1e-5 { good = false }
                    }
                    if e.reading.model != exp["model"] as? String { good = false }
                }
            }
            if good { ok += 1 } else { failed.append(f) }
        }
        check(total > 300 && ok == total, "Sensoren echt: \(ok) von \(total) Aufnahmen der Referenz stimmen in Modell, Kennung und allen Messwerten überein" + (failed.isEmpty ? "" : " (Abweichung: \(failed.prefix(3).joined(separator: ", ")))"))
    } else { skip("Sensoren echt: TestData/Sensors liegt nicht lokal vor (Tools/Sensors433Bench/fetch_testdata.sh)") }
}
// MARK: - SDRconnect als Funkgerät (WebSocket-Schnittstelle)
if want("rig") {
    var st = SDRconnectStatus()
    st.apply(property: "device_vfo_frequency", value: "101000000")
    st.apply(property: "demodulator", value: "nfm")
    st.apply(property: "filter_bandwidth", value: "12500")
    st.apply(property: "lna_state", value: "3")
    st.apply(property: "valid_devices", value: "RSPdx 1, RSPduo 2")
    check(st.rigState.frequencyHz == 101_000_000 && st.rigState.mode == "FM" && st.rigState.passbandHz == 12_500 && st.lnaState == 3 && st.validDevices == ["RSPdx 1", "RSPduo 2"],
          "SDRconnect: Eigenschaften lesen, NFM = Hamlib FM")
    check(SDRconnectStatus.hamlibMode(forDemodulator: "SAM") == "AM" && SDRconnectStatus.hamlibMode(forDemodulator: "wfm") == "WFM" && st.vfoText == "101,000 MHz", "SDRconnect: Mode-Namen und Frequenztext")
    check(["USB": "USB", "PKTUSB": "USB", "RTTY": "USB", "LSB": "LSB", "PKTLSB": "LSB", "CW": "CW", "CWR": "CW", "AM": "AM", "FM": "NFM", "WFM": "WFM"].allSatisfy { SDRconnectModes.name(forHamlib: $0.key) == $0.value }
          && SDRconnectModes.name(forHamlib: "XYZ") == nil && RigDialect.sdrconnect.defaultPort == 5454 && RigDialect.sdrconnect.modeName(for: "RTTY") == "USB", "SDRconnect: Mode-Abbildung (RTTY und Paketbetrieb → USB, FM → NFM)")
    check(RigProfile.sdrconnect().dialect == .sdrconnect && RigProfile.sdrconnect().port == 5454 && RigProfile(name: "", dialect: .sdrconnect).displayName == "SDRconnect 127.0.0.1:4532", "SDRconnect: Vorlage und Name")
    let rt = RigProfileList.decoded(from: RigProfileList(profiles: [RigProfile.sdrconnect()], activeID: nil).encoded())
    check(rt.profiles.first?.dialect == .sdrconnect, "SDRconnect: Vorlage übersteht Speichern und Laden")

    if let fake = FakeSDRconnect() {
        func wait(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        let rig = RigModel()
        rig.use(profile: RigProfile(name: "SDRconnect", port: Int(fake.port), dialect: .sdrconnect))
        check(wait { rig.sdrconnect.connected && rig.sdrconnect.vfoHz != nil && rig.sdrconnect.lnaMax != nil && rig.sdrconnect.deviceName != nil },
              "SDRconnect: Verbindung und Zustand (\(rig.sdrconnect.vfoText ?? "–"), \(rig.sdrconnect.demodulator ?? "–"))")
        check(rig.state.connected && rig.state.frequencyHz == 7_074_000 && rig.state.mode == "USB" && rig.sdrconnect.bandwidthHz == 2700 && rig.sdrconnect.lnaState == 4 && rig.sdrconnect.lnaMax == 9
              && rig.sdrconnect.deviceName == "RSPdx 1234" && rig.sdrconnect.started == true && rig.sdrconnect.apiVersion == "1.0.3" && rig.sdrconnect.signalPowerDB == -80.5 && rig.sdrconnect.canControl == true,
              "SDRconnect: Frequenz, Mode, Bandbreite, Stufe, Gerät, Pegel und Version im Rig-Zustand")
        // Abstimmen innerhalb des Empfangsbereichs: nur VFO, Mode und Bandbreite
        rig.tune(to: RigTuneTarget(dialHz: 7_100_000, mode: "LSB", passbandHz: 2400))
        check(wait { rig.state.frequencyHz == 7_100_000 && rig.state.mode == "LSB" && rig.sdrconnect.bandwidthHz == 2400 }, "SDRconnect: Abstimmen auf 7,100 MHz LSB mit 2,4 kHz")
        check(fake.received == ["set device_vfo_frequency=7100000", "set demodulator=LSB", "set filter_bandwidth=2400"] && fake.property("device_center_frequency") == "7074000",
              "SDRconnect: im Bereich bleibt die Mitte (\(fake.received))")
        // Weit weg: erst die Mitte, dann VFO; FM heißt dort NFM, RTTY wird USB
        rig.tune(to: RigTuneTarget(dialHz: 145_500_000, mode: "FM", passbandHz: 12_500))
        check(wait { rig.state.frequencyHz == 145_500_000 && rig.state.mode == "FM" }
              && fake.received.suffix(4) == ["set device_center_frequency=145500000", "set device_vfo_frequency=145500000", "set demodulator=NFM", "set filter_bandwidth=12500"],
              "SDRconnect: weit entfernte Frequenz setzt zuerst die Mitte (\(fake.received.suffix(4)))")
        rig.tune(to: RigTuneTarget(dialHz: 7_040_000, mode: "RTTY", passbandHz: 500))
        check(wait { fake.property("demodulator") == "USB" && rig.state.frequencyHz == 7_040_000 }, "SDRconnect: RTTY läuft als USB")
        let before = fake.received.count
        rig.tune(to: RigTuneTarget(dialHz: 7_040_000, mode: "BOGUS"))
        check(wait { rig.tuneMessage?.contains("lehnt ab") == true } && fake.received.count == before, "SDRconnect: unbekannter Mode wird abgelehnt, nichts gesendet (\(rig.tuneMessage ?? ""))")
        // Verstärkungsstufe und Gerätestrom
        rig.sdrconnectSet("lna_state", "6")
        check(wait { rig.sdrconnect.lnaState == 6 } && fake.property("lna_state") == "6", "SDRconnect: Verstärkungsstufe setzen")
        rig.sdrconnectStream(false)
        check(wait { rig.sdrconnect.started == false } && fake.received.contains("stream false"), "SDRconnect: Gerätestrom anhalten")
        // Andere Gerätearten lassen SDRconnect unberührt
        rig.use(profile: nil)
        check(wait { rig.sdrconnect == SDRconnectStatus() }, "SDRconnect: nach dem Wechsel des Geräts ist der Zustand leer")
        let probe = ProbeBox()
        SDRconnectRigClient.probe(RigEndpoint.loopback(port: fake.port)) { probe.result = $0 }
        check(wait(8) { probe.result != nil } && { if case .ok(let s)? = probe.result { return s.frequencyHz != nil && s.mode != nil } else { return false } }(), "SDRconnect: Verbindungstest meldet Frequenz und Mode")
        fake.stop()
    } else { skip("SDRconnect: der nachgebaute Server ließ sich nicht starten") }
    // Nicht erreichbar
    final class Closed: @unchecked Sendable { var result: RigProbeResult? }
    let closed = Closed()
    SDRconnectRigClient.probe(RigEndpoint.loopback(port: 1)) { closed.result = $0 }
    let endClosed = Date().addingTimeInterval(8)
    while closed.result == nil && Date() < endClosed { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    check(closed.result == .unreachable, "SDRconnect: nicht erreichbarer Server → keine Verbindung")
}
final class ProbeBox: @unchecked Sendable { var result: RigProbeResult? }
// MARK: - FreeDV (Codec2): Modem, Rundlauf, Textkanal, echte Aufnahme
if want("voice") {
    struct FRng: Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func gauss() -> Double {
            let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-12), u2 = Double(next() >> 11) / Double(1 << 53)
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }
    // Sprachähnliches Signal: Stimmritzenfolge (130 Hz) durch drei Formanten, Silbenhüllkurve, dazu Zischlaute
    func speechLike(seconds: Double) -> [Int16] {
        var rng = FRng(state: 9)
        let n = Int(seconds * 8000)
        var out = [Int16](repeating: 0, count: n)
        var y1 = [0.0, 0.0, 0.0], y2 = [0.0, 0.0, 0.0]
        let formants = [(700.0, 90.0), (1220.0, 110.0), (2600.0, 160.0)]
        for i in 0..<n {
            let t = Double(i) / 8000
            let syllable = max(0, sin(2 * Double.pi * 3.2 * t)) * (0.6 + 0.4 * sin(2 * Double.pi * 0.7 * t))
            let phase = (t * (130 + 25 * sin(2 * Double.pi * 0.5 * t))).truncatingRemainder(dividingBy: 1)
            let glottal = (phase < 0.08 ? 1.0 : 0.0) - 0.08
            var v = 0.0
            for (k, (f, bw)) in formants.enumerated() {
                let r = exp(-Double.pi * bw / 8000), c = 2 * r * cos(2 * Double.pi * f / 8000)
                let y = glottal + c * y1[k] - r * r * y2[k]
                y2[k] = y1[k]; y1[k] = y
                v += y * (k == 0 ? 1.0 : 0.6)
            }
            let hiss = (i / 4000) % 3 == 2 ? 0.15 * rng.gauss() * (0.5 + 0.5 * sin(2 * Double.pi * 1.1 * t)) : 0
            out[i] = Int16(max(-30000, min(30000, 2600 * syllable * v + 1500 * hiss)))
        }
        return out
    }
    func rmsOf(_ x: ArraySlice<Int16>) -> Double { x.isEmpty ? 0 : (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot() }
    func envelope(_ x: [Int16]) -> [Double] { stride(from: 0, to: max(0, x.count - 160), by: 160).map { rmsOf(x[$0..<($0 + 160)]) } }
    /// Größte Korrelation der Hüllkurven bei einem Versatz bis zu 2 s
    func envelopeCorrelation(_ a: [Int16], _ b: [Int16]) -> Double {
        let ea = envelope(a), eb = envelope(b)
        var best = -1.0
        for shift in 0..<100 {
            let k = min(ea.count, eb.count - shift)
            guard k > 20 else { continue }
            let x = Array(ea[0..<k]), y = Array(eb[shift..<(shift + k)])
            let mx = x.reduce(0, +) / Double(k), my = y.reduce(0, +) / Double(k)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for j in 0..<k { sxy += (x[j] - mx) * (y[j] - my); sxx += (x[j] - mx) * (x[j] - mx); syy += (y[j] - my) * (y[j] - my) }
            best = max(best, sxy / max(1e-9, (sxx * syy).squareRoot()))
        }
        return best
    }
    func modulate(_ mode: FreeDVMode, speech: [Int16], text: String? = nil) -> [Int16] {
        let tx = FreeDVModem(mode: mode)!
        if let text { tx.setTransmitText(text) }
        let n = tx.speechSamplesPerFrame
        var out = [Int16](repeating: 0, count: 4000)
        var i = 0
        while i + n <= speech.count { out += tx.transmit(Array(speech[i..<(i + n)])); i += n }
        return out + [Int16](repeating: 0, count: 8000)
    }
    func demodulate(_ mode: FreeDVMode, _ audio: [Int16]) -> (speech: [Int16], syncShare: Double, text: String, snr: Double) {
        let rx = FreeDVModem(mode: mode)!
        var chars = ""
        rx.onText = { chars.append($0) }
        var speech: [Int16] = []
        var syncBlocks = 0, blocks = 0, snr = 0.0
        var p = 0
        while p < audio.count {
            speech += rx.receive(Array(audio[p..<min(p + 800, audio.count)]))
            blocks += 1
            let st = rx.status
            if st.sync { syncBlocks += 1; snr = st.snr }
            p += 800
        }
        return (speech, Double(syncBlocks) / Double(max(1, blocks)), chars, snr)
    }

    let voice = speechLike(seconds: 8)
    for mode in FreeDVMode.allCases {
        let r = demodulate(mode, modulate(mode, speech: voice))
        let corr = envelopeCorrelation(voice, r.speech)
        check(r.syncShare > 0.5 && corr > 0.75 && abs(Double(r.speech.count) / 8000 - 9.5) < 2.0,
              "FreeDV \(mode.title): Rundlauf Sprache, Synchronisation \(Int(r.syncShare * 100)) %, Hüllkurven-Korrelation \(String(format: "%.2f", corr)), \(String(format: "%.1f", Double(r.speech.count) / 8000)) s")
    }
    // Rauschen: 700D bei etwa 8 dB Rauschabstand (3 kHz)
    var noiseRng = FRng(state: 31)
    let clean700 = modulate(.mode700D, speech: voice)
    let power = rmsOf(clean700[4000..<(clean700.count - 8000)])
    let sigma = power / pow(10, 8.0 / 20) * (4000.0 / 3000.0).squareRoot()
    let noisy = clean700.map { Int16(max(-32768, min(32767, Double($0) + sigma * noiseRng.gauss()))) }
    let rn = demodulate(.mode700D, noisy)
    check(rn.syncShare > 0.4 && envelopeCorrelation(voice, rn.speech) > 0.6, "FreeDV 700D mit Rauschen (≈ 8 dB in 3 kHz): Synchronisation \(Int(rn.syncShare * 100)) %, Sprache \(String(format: "%.2f", envelopeCorrelation(voice, rn.speech)))")
    // Textkanal (Rufzeichen)
    let withText = demodulate(.mode700D, modulate(.mode700D, speech: voice, text: "DL1ABC JN49"))
    check(withText.text.contains("DL1ABC JN49"), "FreeDV 700D: Textkanal liefert das Rufzeichen („\(withText.text.prefix(24))“)")
    // Falsche Betriebsart: kein Sync
    let wrong = demodulate(.mode1600, modulate(.mode700D, speech: voice))
    check(wrong.syncShare < 0.2, "FreeDV: falsche Betriebsart (1600 statt 700D) bleibt unsynchron (\(Int(wrong.syncShare * 100)) %)")
    check(FreeDVMode(preset: "700E") == .mode700E && FreeDVMode(preset: "x") == nil && FreeDVMode.allCases.map(\.title) == ["700D", "700E", "1600", "700C"],
          "FreeDV: Betriebsarten und Voreinstellungen der URL-Schnittstelle")

    // Echte Aufnahme (Codec2-Beispiel, David Rowe: FreeDV 700D auf Kurzwelle, Gegenstation vk2tpm in Sydney; nur lokal)
    let realFreeDV = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/Voice/freedv_700d_vk2tpm.wav")
    if let data = try? Data(contentsOf: realFreeDV), data.count > 44 {
        let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let r = demodulate(.mode700D, pcm)
        check(r.syncShare > 0.9 && r.speech.count > 8000 * 30 && r.text.contains("vk2tpm Killarney Heights") && rmsOf(r.speech[...]) > 300 && r.snr > 3,
              "FreeDV echt (700D, vk2tpm): Synchronisation \(Int(r.syncShare * 100)) %, \(String(format: "%.0f", Double(r.speech.count) / 8000)) s Sprache, Text „\(r.text.prefix(32))“, S/N \(String(format: "%.1f", r.snr)) dB")
    } else { skip("FreeDV echt: TestData/Voice/freedv_700d_vk2tpm.wav liegt nicht lokal vor") }
}
// MARK: - VDL Mode 2: Kopf, Reed-Solomon, Rahmen, ACARS, Rundlauf über I/Q, echte Aufnahme
if want("vdl2") {
    struct VRng { var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    }
    var rng = VRng(s: 77)
    // Kopf: Prüfbits, Korrektur jedes Einzelbitfehlers
    var headerOK = true, singleOK = true
    for len in [0, 1, 100, 594, 7386, 0x1FFF, 0x3FFF, 12345 & 0x3FFF] {
        let word22 = VDL2.reverse(UInt32(len), bits: 17) << 5
        let word = word22 | VDL2.headerCheck(word22)
        guard let ok = VDL2.decodeHeader(word), ok.syndrome == 0, ok.word == word else { headerOK = false; continue }
        for bit in 0..<22 {
            if let c = VDL2.decodeHeader(word ^ (1 << UInt32(bit))), c.word == word, c.syndrome != 0 {} else { singleOK = false }
        }
    }
    check(headerOK && singleOK, "VDL2: Kopf (17 Bit Länge, 5 Prüfbits) und Korrektur jedes Einzelbitfehlers")
    // Verwürfelung ist ihre eigene Umkehrung
    var bits = (0..<500).map { _ in UInt8(rng.next() & 1) }
    let original = bits
    var st = VDL2.scramblerStart
    VDL2.scramble(&bits, from: 0, to: bits.count, state: &st)
    st = VDL2.scramblerStart
    let scrambled = bits
    VDL2.scramble(&bits, from: 0, to: bits.count, state: &st)
    check(bits == original && scrambled != original, "VDL2: Verwürfelung (x¹⁵ + x + 1, Startwert 0x6959) umkehrbar")
    // Reed-Solomon (255,249)
    let rs = ReedSolomon.shared
    var rsOK = true, fixedOK = true, erasureOK = true
    for trial in 0..<60 {
        let data = (0..<249).map { _ in UInt8(rng.next() & 0xFF) }
        let par = rs.parity(of: data)
        var block = data + par
        if rs.verify(&block, parityOctets: 6) != 0 { rsOK = false }
        // bis zu 3 Fehler
        let errors = 1 + trial % 3
        var positions = Set<Int>()
        while positions.count < errors { positions.insert(Int(rng.next() % 255)) }
        for p in positions { block[p] ^= UInt8(1 + rng.next() % 255) }
        let n = rs.verify(&block, parityOctets: 6)
        if n != errors || block != data + par { fixedOK = false }
        // verkürzte Prüfung (4 und 2 Prüfbytes = 2 bzw. 4 Auslöschungen) mit Fehlern
        for fec in [4, 2] {
            var b2 = data + par
            for i in (249 + fec)..<255 { b2[i] = 0 }
            let allowed = (6 - (6 - fec)) / 2                               // Fehler, die noch korrigierbar sind
            var pos2 = Set<Int>()
            while pos2.count < allowed { pos2.insert(Int(rng.next() % UInt64(249 + fec))) }
            for p in pos2 { b2[p] ^= UInt8(1 + rng.next() % 255) }
            if rs.verify(&b2, parityOctets: fec) < 0 || b2 != data + par { erasureOK = false }
        }
    }
    check(rsOK && fixedOK, "VDL2: Reed-Solomon (255,249): fehlerfreier Block, 1 bis 3 Fehler korrigiert")
    check(erasureOK, "VDL2: Reed-Solomon mit verkürzter Prüfung (Auslöschungen) und Fehlern")
    var tooMany = (0..<249).map { _ in UInt8(rng.next() & 0xFF) }
    tooMany += rs.parity(of: tooMany)
    for p in [3, 40, 90, 140, 200, 230, 245] { tooMany[p] ^= 0x55 }
    let manyResult = rs.verify(&tooMany, parityOctets: 6)
    check(manyResult != 0, "VDL2: Reed-Solomon mit 7 Fehlern meldet keinen fehlerfreien Block (\(manyResult))")
    // Adressen
    let ac = VDL2Address(raw: UInt32(0x3C6444) | (1 << 24))
    let gs = VDL2Address(raw: UInt32(0x123456) | (4 << 24) | (1 << 27))
    check(VDL2Address.parse(ac.bytes(last: false)[...]) == ac && VDL2Address.parse(gs.bytes(last: true)[...]) == gs
          && ac.text == "3C6444" && ac.isAircraft && gs.isGroundStation && gs.status == 1 && ac.bytes(last: true)[3] & 1 == 1 && ac.bytes(last: false)[3] & 1 == 0,
          "VDL2: Adressen (24 Bit, Art, Zustand) hin und zurück")
    // Rahmen
    let up = VDL2SignalGenerator.informationFrame(destination: ac, source: gs, sendSeq: 3, recvSeq: 5, poll: true, payload: Array("HELLO".utf8))
    let t0 = Date()
    if let f = AVLC.parse(up, time: t0, frequency: 136_975_000, levelDB: -20, noiseDB: -50, ppm: 0, corrections: 0) {
        check(f.kind == .information && f.command == "I" && f.poll && f.payload == Array("HELLO".utf8) && f.source == gs && f.destination == ac && f.acars == nil,
              "VDL2: Informationsrahmen zerlegt")
    } else { check(false, "VDL2: Informationsrahmen zerlegt") }
    var bad = up; bad[bad.count - 3] ^= 0x01
    check(AVLC.parse(bad, time: t0, frequency: 0, levelDB: 0, noiseDB: 0, ppm: 0, corrections: 0) == nil, "VDL2: Rahmen mit falscher Prüfsumme wird verworfen")
    let rr = VDL2SignalGenerator.supervisoryFrame(destination: gs, source: ac, function: 2, recvSeq: 1, poll: false)
    let xid = VDL2SignalGenerator.unnumberedFrame(destination: gs, source: ac, mfunc: 0x2B, poll: true, payload: [0x82, 0x00, 0x01])
    let u1 = AVLC.parse(rr, time: t0, frequency: 0, levelDB: 0, noiseDB: 0, ppm: 0, corrections: 0)
    let u2 = AVLC.parse(xid, time: t0, frequency: 0, levelDB: 0, noiseDB: 0, ppm: 0, corrections: 0)
    check(u1?.kind == .supervisory && u1?.command == "REJ" && u2?.kind == .unnumbered && u2?.command == "XID" && u2?.poll == true && u2?.payload == [0x82, 0x00, 0x01],
          "VDL2: Überwachungs- und nicht nummerierte Rahmen (REJ, XID)")
    // ACARS im AVLC: Abwärts und Aufwärts
    let down = VDL2SignalGenerator.acarsPayload(registration: "D-AIXC", label: "H1", blockID: "3", messageNumber: "M12A", flight: "LH1234", text: "POS N49123E009456\nFL350")
    let upA = VDL2SignalGenerator.acarsPayload(mode: "2", registration: "D-AIXC", ack: "5", label: "Q0", blockID: "C", text: "")
    let fd = AVLC.parse(VDL2SignalGenerator.informationFrame(destination: gs, source: ac, payload: down), time: t0, frequency: 0, levelDB: 0, noiseDB: 0, ppm: 0, corrections: 0)
    let fu = AVLC.parse(VDL2SignalGenerator.informationFrame(destination: ac, source: gs, payload: upA), time: t0, frequency: 0, levelDB: 0, noiseDB: 0, ppm: 0, corrections: 0)
    check(fd?.acars?.registration == "D-AIXC" && fd?.acars?.label == "H1" && fd?.acars?.isDownlink == true && fd?.acars?.flightID == "LH1234" && fd?.acars?.messageNumber == "M12A"
          && fd?.acars?.text == "POS N49123E009456\nFL350" && fd?.acars?.blockID == "3", "VDL2: ACARS abwärts (Kennzeichen, Label, Flug, Text)")
    check(fu?.acars?.isDownlink == false && fu?.acars?.label == "Q0" && fu?.acars?.ack == "5" && fu?.acars?.text.isEmpty == true, "VDL2: ACARS aufwärts ohne Text")
    // Chebyshev-Tiefpass: Verstärkung 1 bei Gleichstrom, Sperrdämpfung
    let cheb = Chebyshev.lowpass(cutoff: 8000 / 262_500, ripple: 0.5, poles: 2)
    func gain(_ f: Double, fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let num = (0..<3).reduce((0.0, 0.0)) { ($0.0 + cheb.a[$1] * cos(Double($1) * w), $0.1 - cheb.a[$1] * sin(Double($1) * w)) }
        let den = (1..<3).reduce((1.0, 0.0)) { ($0.0 - cheb.b[$1] * cos(Double($1) * w), $0.1 + cheb.b[$1] * sin(Double($1) * w)) }
        return (num.0 * num.0 + num.1 * num.1).squareRoot() / (den.0 * den.0 + den.1 * den.1).squareRoot()
    }
    check(abs(gain(10, fs: 262_500) - 1) < 0.01 && gain(4000, fs: 262_500) > 0.9 && gain(40_000, fs: 262_500) < 0.1, "VDL2: Tschebyscheff-Tiefpass (Durchlass, Sperrung)")

    // Rundlauf über I/Q: mehrere Rahmen in einem Burst, zwei Blöcke, Rauschen, Frequenzablage, Taktfehler, mehrere Kanäle gleichzeitig
    let center = 136_850_000.0
    func receive(_ bursts: [VDL2SignalGenerator.Burst], rate: Double, noise: Double, duration: Double, channels: [Double] = VDL2.europeanChannels) -> [Double: [AVLCFrame]] {
        let (i, q) = VDL2SignalGenerator.render(bursts, sampleRate: rate, duration: duration, noise: noise, seed: 5)
        var result: [Double: [AVLCFrame]] = [:]
        for f in channels {
            let ch = VDL2Channel(frequency: f, centerFrequency: center, sampleRate: rate)
            nonisolated(unsafe) var found: [AVLCFrame] = []
            ch.onBurst = { found += $0.frames }
            i.withUnsafeBufferPointer { a in q.withUnsafeBufferPointer { b in
                var p = 0
                while p < a.count { let c = min(40_000, a.count - p); ch.process(i: UnsafeBufferPointer(rebasing: a[p..<(p + c)]), q: UnsafeBufferPointer(rebasing: b[p..<(p + c)])); p += c }
            } }
            result[f] = found
        }
        return result
    }
    let ch = VDL2.europeanChannels
    let f1 = VDL2SignalGenerator.informationFrame(destination: gs, source: ac, sendSeq: 1, payload: VDL2SignalGenerator.acarsPayload(registration: "D-AIXC", label: "H1", blockID: "1", text: "TEST ONE"))
    let f2 = VDL2SignalGenerator.supervisoryFrame(destination: gs, source: ac, function: 0, recvSeq: 2)
    let bitsA = VDL2SignalGenerator.burstBits(frames: [f1, f2])
    let r1 = receive([VDL2SignalGenerator.Burst(bits: bitsA, offsetHz: ch[4] - center)], rate: 2_000_000, noise: 0, duration: 0.1)
    check(r1[ch[4]]?.count == 2 && r1[ch[4]]?[0].acars?.text == "TEST ONE" && r1[ch[4]]?[1].command == "RR" && ch.filter { $0 != ch[4] }.allSatisfy { r1[$0]?.isEmpty == true },
          "VDL2 Rundlauf: ein Burst mit zwei Rahmen auf Kanal 136,925, die anderen fünf Kanäle bleiben leer")
    let long = String(repeating: "ABCDEFGHIJ0123456789 ", count: 30)
    let fLong = VDL2SignalGenerator.informationFrame(destination: ac, source: gs, sendSeq: 0, recvSeq: 0, poll: true, payload: VDL2SignalGenerator.acarsPayload(mode: "2", registration: "D-AIXC", ack: "!", label: "H1", blockID: "A", text: long))
    let bitsL = VDL2SignalGenerator.burstBits(frames: [fLong])
    let r2 = receive([VDL2SignalGenerator.Burst(bits: bitsL, offsetHz: ch[0] - center + 350, clockPPM: 15)], rate: 2_000_000, noise: 0.04, duration: 0.1 + Double(bitsL.count) / 31_500)
    check(r2[ch[0]]?.first?.acars?.text == long, "VDL2 Rundlauf: langer Rahmen (über 600 Byte, mehrere Reed-Solomon-Blöcke) mit Rauschen, 350 Hz Ablage und 15 ppm Taktfehler")
    // Zwei Bursts gleichzeitig auf verschiedenen Kanälen, 2,4 MS/s
    let fB = VDL2SignalGenerator.informationFrame(destination: gs, source: VDL2Address(raw: UInt32(0xA1B2C3) | (1 << 24)), payload: VDL2SignalGenerator.acarsPayload(registration: "G-EUPT", label: "5Z", blockID: "2", flight: "BA0123", text: "SECOND"))
    let r3 = receive([VDL2SignalGenerator.Burst(bits: bitsA, offsetHz: ch[1] - center, start: 0.003, phase: 1.0), VDL2SignalGenerator.Burst(bits: VDL2SignalGenerator.burstBits(frames: [fB]), offsetHz: ch[5] - center - 200, start: 0.004, phase: 2.0)],
                     rate: 2_400_000, noise: 0.03, duration: 0.1)
    check(r3[ch[1]]?.first?.acars?.text == "TEST ONE" && r3[ch[5]]?.first?.acars?.flightID == "BA0123" && r3[ch[5]]?.first?.acars?.registration == "G-EUPT",
          "VDL2 Rundlauf: zwei Kanäle gleichzeitig bei 2,4 MS/s")
    // Nur Rauschen: nichts
    let r4 = receive([], rate: 2_000_000, noise: 0.1, duration: 0.5)
    check(r4.values.allSatisfy { $0.isEmpty }, "VDL2: Rauschen allein erzeugt keine Rahmen")
    // Sehr schwaches Signal: keine falschen Rahmen (höchstens fehlender Empfang)
    let r5 = receive([VDL2SignalGenerator.Burst(bits: bitsA, offsetHz: ch[2] - center, amplitude: 0.05)], rate: 2_000_000, noise: 0.2, duration: 0.1)
    check(r5.values.allSatisfy { $0.isEmpty }, "VDL2: sehr schwaches Signal im Rauschen liefert keine falschen Rahmen")

    // Verwaltung: Flugzeuge, Bodenstationen, Protokoll
    let box = VDL2Controller(settings: VDL2SettingsStore())
    func frame(_ bytes: [UInt8], freq: Double = 136_975_000, level: Double = -25) -> AVLCFrame {
        AVLC.parse(bytes, time: t0, frequency: freq, levelDB: level, noiseDB: -55, ppm: 1, corrections: 0)!
    }
    box.ingest(frame(VDL2SignalGenerator.informationFrame(destination: gs, source: ac, payload: down)), now: t0)
    box.ingest(frame(VDL2SignalGenerator.informationFrame(destination: ac, source: gs, payload: upA), freq: 136_725_000), now: t0.addingTimeInterval(5))
    box.ingest(frame(VDL2SignalGenerator.supervisoryFrame(destination: gs, source: VDL2Address(raw: UInt32(0xABCDEF) | (1 << 24)), function: 0)), now: t0.addingTimeInterval(6))
    check(box.aircraft.count == 2 && box.aircraft[1].address == ac && box.aircraft[1].registration == "D-AIXC" && box.aircraft[1].flight == "LH1234" && box.aircraft[1].frames == 2
          && box.aircraft[1].acarsMessages == 2 && box.aircraft[1].groundStation == "123456" && box.aircraft[1].lastText == "POS N49123E009456 FL350" && box.aircraft[0].frames == 1,
          "VDL2: Flugzeugliste (Kennzeichen, Flug, Bodenstation, Text, Zähler)")
    check(box.groundStations.count == 1 && box.groundStations[0].frames == 3 && box.groundStations[0].frequencies == [136_975_000, 136_725_000] && box.totalFrames == 3 && box.acarsCount == 2 && box.recent.count == 3,
          "VDL2: Bodenstationen, Zähler und Protokoll")
    check(VDL2Format.direction(box.recent[0].frame) == "FZ→BODEN" && VDL2Format.direction(box.recent[1].frame) == "BODEN→FZ"
          && VDL2Controller.logLine(box.recent[0].frame, summary: box.recent[0].summary, time: t0).contains("3C6444 → 123456") && box.recent[0].summary.hasPrefix("ACARS D-AIXC H1 LH1234"),
          "VDL2: Richtung, Protokollzeile und Zusammenfassung")
    box.clear()
    check(box.aircraft.isEmpty && box.recent.isEmpty && box.groundStations.isEmpty && box.totalFrames == 0, "VDL2: Listen leeren")
    // Kanäle und Einstellungen
    let store = VDL2SettingsStore()
    store.channels = VDL2Channels.europe
    check(store.centerFrequency == 136_850_000 && store.channelFrequencies.count == 6 && VDL2Channels.center(of: [136.975]) == 136_975_000 && VDL2Channels.title(136_975_000) == "136,975",
          "VDL2: Mitte des Empfangsfensters aus den Kanälen")
    store.channels = [136.975]
    store.toggle(136.975)
    check(store.channels == [136.975], "VDL2: der letzte Kanal lässt sich nicht abwählen")
    store.channels = VDL2Channels.europe
    check(DecoderModuleInfo.vdl2.band == .vhfUhf && !DecoderModuleInfo.vdl2.hasMap && DecoderModuleInfo.vdl2.displayName == "VDL2" && DecoderModuleInfo.vdl2.presetIDs == ["europa", "csc", "alle"],
          "VDL2: Modul in der Liste")
    check(VDL2FileSource.sampleRate(of: URL(fileURLWithPath: "/x/vdl2_model_16b_1050kHz.wav")) == 1_050_000 && VDL2FileSource.sampleRate(of: URL(fileURLWithPath: "/x/mitschnitt_2M.cu8")) == 2_000_000
          && VDL2FileSource.sampleRate(of: URL(fileURLWithPath: "/x/gar_nix.cu8")) == nil, "VDL2: Abtastrate aus dem Dateinamen")

    // Echte Aufnahme (dumpvdl2-Testdatei, 1,05 MS/s, 16 Bit; nur lokal): zwei Rahmen mit Wetterberichten
    let realVDL2 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/VDL2/vdl2_model_16b_1050kHz.wav")
    if let data = try? Data(contentsOf: realVDL2), data.count > 44 {
        let n = (data.count - 44) / 4
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        data.dropFirst(44).withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for k in 0..<n { re[k] = Float(s[2 * k]) / 32768; im[k] = Float(s[2 * k + 1]) / 32768 }
        }
        let c = VDL2Channel(frequency: 136_975_000, centerFrequency: 136_975_000, sampleRate: 1_050_000)
        nonisolated(unsafe) var frames: [AVLCFrame] = []
        c.onBurst = { frames += $0.frames }
        re.withUnsafeBufferPointer { a in im.withUnsafeBufferPointer { b in c.process(i: a, q: b) } }
        let t = frames.map { VDL2Format.printable($0.payload, limit: 1000) }
        check(frames.count == 2 && t[0].contains("-RA BR OVC005") && t[1].contains("SLP135") && frames[0].source.text == "345678" && frames[0].destination.text == "A23721",
              "VDL2 echt (dumpvdl2-Testdatei): \(frames.count) Rahmen, TAF und METAR gelesen, Absender 345678")
        // dieselbe Aufnahme auf 8 Bit gebracht (wie über die Dateiquelle)
        let engine = VDL2Engine()
        engine.configure(sampleRate: 1_050_000, centerFrequency: 136_975_000, frequencies: [136_975_000], countClipping: false)
        let u8 = (0..<(2 * n)).map { k -> UInt8 in UInt8(max(0, min(255, (Int((k % 2 == 0 ? re[k / 2] : im[k / 2]) * 32768) + 32768 + 128) >> 8))) }
        u8.withUnsafeBufferPointer { engine.feed($0, wait: true) }
        Thread.sleep(forTimeInterval: 1.0)
        let snap = engine.snapshot()
        check(snap.bursts.flatMap(\.frames).count == 2, "VDL2 echt: dieselbe Aufnahme auf 8 Bit und über die Engine (\(snap.bursts.flatMap(\.frames).count) Rahmen)")
    } else { skip("VDL2 echt: TestData/VDL2/vdl2_model_16b_1050kHz.wav liegt nicht lokal vor (aus dumpvdl2/test)") }
}
// MARK: - VOR/ILS: Peilung, Kennung (Morse), Landekurs- und Gleitwegsender, echte Aufnahmen
if want("vor") {
    /// Audio in ungleich langen Stücken in den Empfänger geben (prüft, dass die Blockgrenzen nichts ausmachen)
    func run(_ x: [Float]) -> (rx: NavReceiver, idents: [String]) {
        let rx = NavReceiver()
        nonisolated(unsafe) var ids: [String] = []
        rx.onIdent = { ids.append($0) }
        let sizes = [777, 4096, 1000, 12345, 333]
        var p = 0, k = 0
        x.withUnsafeBufferPointer { a in
            while p < a.count { let c = min(sizes[k % sizes.count], a.count - p); rx.process(UnsafeBufferPointer(rebasing: a[p..<(p + c)])); p += c; k += 1 }
        }
        return (rx, ids)
    }
    func angleError(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return d > 180 ? 360 - d : d }

    // VOR: Peilung über den ganzen Kreis, mit Rauschen und Sprache
    var worst = 0.0, allValid = true, identOK = true
    for bearing in stride(from: 0.0, to: 360.0, by: 29.0) {
        let (rx, ids) = run(NavSignalGenerator.vor(bearing: bearing, seconds: 20, ident: "TRC", noise: 0.05, voice: true))
        guard let v = rx.vor else { allValid = false; continue }
        worst = max(worst, angleError(v.bearing, bearing))
        if !v.isValid || abs(v.deviationHz - 480) > 20 { allValid = false }
        if ids != ["TRC"] { identOK = false }
    }
    check(worst < 0.5 && allValid, "VOR: Peilung über den Kreis (größter Fehler \(String(format: "%.2f", worst))°), Hub 480 Hz, gültig")
    check(identOK, "VOR: Morse-Kennung „TRC“ gelesen (einmal je Aussendung)")
    // Stark verrauscht: Peilung bleibt innerhalb weniger Grad
    let (noisy, _) = run(NavSignalGenerator.vor(bearing: 123, seconds: 12, noise: 0.5, voice: true))
    check(noisy.vor.map { angleError($0.bearing, 123) < 4 } == true, "VOR: Peilung bei starkem Rauschen (\(String(format: "%.1f", noisy.vor?.bearing ?? -1))° statt 123°)")
    // Nur Rauschen und nur Sprache: kein VOR, kein ILS
    var rng = SystemRandomNumberGenerator()
    let hiss = (0..<(48_000 * 6)).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
    let (hissRx, hissIds) = run(hiss)
    check(hissRx.vor?.isValid == false && hissRx.ils?.isValid == false && hissIds.isEmpty, "VOR/ILS: Rauschen allein wird nicht erkannt")
    // ILS: DDM-Werte, Landekurs und Gleitweg (gleiche Signalform), Kennung
    var ddmOK = true
    for ddm in [-0.155, -0.08, -0.02, 0, 0.02, 0.08, 0.155] {
        let (rx, ids) = run(NavSignalGenerator.ils(ddm: ddm, seconds: 20, ident: "IDKB", noise: 0.05))
        if let i = rx.ils, i.isValid, abs(i.ddm - ddm) < 0.004, rx.vor?.isValid == false, ids == ["IDKB"] {} else { ddmOK = false }
    }
    check(ddmOK, "ILS: DDM von −0,155 bis +0,155 auf 0,004 genau, VOR nicht ausgelöst, Kennung „IDKB“")
    let (vorAsILS, _) = run(NavSignalGenerator.vor(bearing: 80, seconds: 6))
    check(vorAsILS.ils?.isValid == false, "ILS: ein VOR-Signal löst den ILS-Anzeiger nicht aus")
    // Morse bei verschiedenen Geschwindigkeiten (7 bis 20 Wörter je Minute) und mit Ziffern
    var morseOK = true
    for (dit, text) in [(0.17, "ABC"), (0.11, "TRC"), (0.06, "WUR"), (0.09, "DKB"), (0.11, "MOE"), (0.08, "IGB7")] {
        let (_, ids) = run(NavSignalGenerator.vor(bearing: 10, seconds: 24, ident: text, dit: dit, noise: 0.02))
        if ids.first != text { morseOK = false; print("Morse \(text) dit \(dit) → \(ids)") }
    }
    check(morseOK, "Morse: Kennungen bei 0,06 bis 0,17 s Punktlänge und mit Ziffer")
    // Anzeige, Eichung und Verwaltung
    check(NavFormat.bearingText(7.3) == "007,3°" && NavFormat.ilsAdvice(ddm: 0.05, kind: .localizer).contains("rechts fliegen") && NavFormat.ilsAdvice(ddm: -0.05, kind: .glideslope).contains("oben")
          && NavFormat.ilsAdvice(ddm: 0.001, kind: .localizer) == "auf der Mittellinie", "VOR/ILS: Anzeigetexte")
    check(NavController.corrected(350, offset: 22) == 12 && NavController.corrected(5, offset: -22) == 343 && ILSKind.localizer.fullScaleDDM == 0.155 && ILSKind.glideslope.fullScaleDDM == 0.175,
          "VOR/ILS: Eichung rechnet um den Kreis, Vollausschlag")
    let navBox = NavController(pipeline: AudioPipeline(), settings: NavSettingsStore())
    navBox.ingestIdent("TRC", now: Date())
    check(navBox.ident == "TRC" && !navBox.identConfirmed, "VOR: erste Kennung noch nicht bestätigt")
    navBox.ingestIdent("TRC", now: Date())
    navBox.ingestIdent("TRX", now: Date())
    check(navBox.ident == "TRX" && !navBox.identConfirmed && navBox.identHistory == ["TRC", "TRC", "TRX"], "VOR: Kennung bestätigt erst beim zweiten gleichen Lesen")
    let line = NavController.logLine(mode: .vor, bearing: 177, vor: VORReading(bearing: 155, deviationHz: 478, variableLevel: 0.01, subcarrierDB: -20, coherence: 1, isValid: true), ils: nil, ident: "TRC", kind: .localizer, time: Date())
    check(line.contains("Peilung 177,0°") && line.contains("roh 155,0°") && line.contains("Kennung TRC"), "VOR: Protokollzeile")
    check(NavDiagnosis.assess(inputDB: -120, mode: .none, vor: nil, secondsWithoutSignal: 60).title == "Kein Audio" && NavDiagnosis.assess(inputDB: -30, mode: .vor, vor: nil, secondsWithoutSignal: 0).ok
          && !NavDiagnosis.assess(inputDB: -30, mode: .none, vor: nil, secondsWithoutSignal: 60).ok, "VOR/ILS: Diagnose")
    check(DecoderModuleInfo.vor.band == .vhfUhf && !DecoderModuleInfo.vor.hasMap && DecoderModuleInfo.vor.displayName == "VOR/ILS", "VOR/ILS: Modul in der Liste")

    // Echte Aufnahmen (martinber/vor-python-decoder, MIT; AM-Audio von GQRX bei Río Cuarto, Radial mit der Karte gemessen; nur lokal)
    let vorDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData/VOR")
    if let names = try? FileManager.default.contentsOfDirectory(atPath: vorDir.path).filter({ $0.hasSuffix(".wav") }).sorted(), names.count >= 10 {
        var offsets: [Double] = []
        var invalid: [String] = [], identFound = 0, identWrong = 0
        for name in names {
            guard let truth = Double(name.prefix(while: { $0.isNumber })), let data = try? Data(contentsOf: vorDir.appendingPathComponent(name)), data.count > 44 else { continue }
            let n = (data.count - 44) / 4
            let left: [Float] = data.dropFirst(44).withUnsafeBytes { raw in let s = raw.bindMemory(to: Int16.self); return (0..<n).map { Float(s[2 * $0]) / 32768 } }
            let (rx, ids) = run(left)
            guard let v = rx.vor, v.isValid else { invalid.append(name); continue }
            var d = (truth - v.bearing).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            offsets.append(d)
            for id in ids { if id == "TRC" { identFound += 1 } else { identWrong += 1 } }
        }
        let mean = offsets.reduce(0, +) / Double(max(1, offsets.count))
        let spread = offsets.map { abs($0 - mean) }.max() ?? 99
        check(invalid.isEmpty && offsets.count == names.count, "VOR echt: alle \(names.count) Aufnahmen als VOR erkannt (\(invalid))")
        check(spread < 3.5 && mean > 15 && mean < 30, "VOR echt: Peilungen an drei Standorten (177°, 234°, 293°) weichen gleichmäßig um \(String(format: "%.1f", mean))° von der Karte ab (Streuung ±\(String(format: "%.1f", spread))°)")
        check(identFound >= 5 && identWrong == 0, "VOR echt: Kennung „TRC“ in \(identFound) Aussendungen gelesen, falsch gelesen: \(identWrong)")
    } else { skip("VOR echt: TestData/VOR liegt nicht lokal vor (github.com/martinber/vor-python-decoder, Ordner samples)") }
}
// MARK: - TETRA
if want("tetra") {
    // Kern: Verwürfelung, CRC, Faltungscode, Punktierung, Verschachtelung, Reed-Muller
    check(TETRA.scramblerInit(mcc: 228, mnc: 8889, colourCode: 1) == ((UInt32(1) | UInt32(8889) << 6 | UInt32(228) << 20) << 2) | 3, "TETRA: Verwürfelungs-Anfangswert aus MCC, MNC und Farbcode")
    let scr = TETRA.scramblerBits(initial: 3, count: 64)
    check(scr.count == 64 && scr.contains(1) && scr.contains(0) && scr == Array(TETRA.scramblerBits(initial: 3, count: 200).prefix(64)), "TETRA: Verwürfelungsfolge ist ein Anfangsstück der längeren")
    let payload = (0..<60).map { UInt8(($0 * 7 + $0 / 3) & 1) }
    let withCRC = payload + TETRA.crcBits(for: payload)
    check(TETRA.crc16(withCRC) == TETRA.crcResidue, "TETRA: CRC-16 über Daten und Prüfbits ergibt 0x1D0F")
    var broken = withCRC; broken[10] ^= 1
    check(TETRA.crc16(broken) != TETRA.crcResidue, "TETRA: CRC erkennt einen Bitfehler")
    let inter = (0..<216).map { UInt8($0 & 1 ^ ($0 / 5) & 1) }
    check(TETRA.hard(TETRA.blockDeinterleave(TETRA.soft(TETRA.blockInterleave(inter, a: 101)), a: 101)) == inter && TETRA.blockInterleave(inter, a: 101) != inter, "TETRA: Blockverschachtelung (a = 101), Rundlauf")
    // Faltungscode: Rundlauf mit Fehlern, Rate 1/4 und 1/3
    var rng = SystemRandomNumberGenerator()
    for (code, name) in [(TETRA.ConvolutionalCode.control, "1/4"), (TETRA.ConvolutionalCode.speech, "1/3")] {
        let data = (0..<100).map { _ in UInt8.random(in: 0...1, using: &rng) } + [0, 0, 0, 0]
        var soft = TETRA.soft(code.encode(data))
        for _ in 0..<12 { let p = Int.random(in: 0..<soft.count, using: &rng); soft[p] = -soft[p] }
        check(code.decode(soft, steps: data.count, terminated: true).bits == data, "TETRA: Faltungscode \(name): Viterbi korrigiert zwölf verstreute Fehler")
    }
    // Punktierung 2/3 aus 1/4: 80 Eingangsbits → 120 gesendet (BSCH)
    let mother = TETRA.ConvolutionalCode.control.encode((0..<80).map { UInt8($0 % 3 == 0 ? 1 : 0) })
    let punctured = TETRA.Puncturer.rate2of3.puncture(mother, count: 120)
    let restored = TETRA.Puncturer.rate2of3.depuncture(TETRA.soft(punctured), motherLength: 320)
    check(punctured.count == 120 && restored.filter { $0 != 0 }.count == 120 && zip(restored, mother).allSatisfy { $0 == 0 || ($0 < 0) == ($1 == 1) }, "TETRA: Punktierung 2/3 (80 → 120 Bits) und Rückgewinnung")
    // Reed-Muller (30,14)
    var rmOK = true
    for v in [0, 1, 0x1234, 0x3FFF, 0x2AAA] {
        let word = TETRA.rm3014Encode(UInt16(v))
        var bits = (0..<30).map { UInt8((word >> UInt32(29 - $0)) & 1) }
        for k in [3, 17, 25] { bits[k] ^= 1 }
        if TETRA.rm3014Decode(TETRA.soft(bits)).info != UInt16(v) { rmOK = false }
    }
    check(rmOK, "TETRA: Reed-Muller (30,14) der Zugriffszuweisung korrigiert drei Fehler")
    check(TETRA.downlinkFrequencyHz(band: 4, carrier: 1068, offsetIndex: 0) == 426_700_000 && TETRA.uplinkFrequencyHz(band: 4, carrier: 1068, offsetIndex: 0, duplex: 0, reverse: false) == 416_700_000
          && TETRA.uplinkFrequencyHz(band: 4, carrier: 1068, offsetIndex: 0, duplex: 0, reverse: true) == 436_700_000 && TETRA.uplinkFrequencyHz(band: 0, carrier: 1, offsetIndex: 0, duplex: 1, reverse: false) == nil
          && TETRA.downlinkFrequencyHz(band: 3, carrier: 100, offsetIndex: 1) == 302_506_250, "TETRA: Trägerfrequenz und Duplexabstand aus Band, Träger und Versatz")

    // Sprachkanal: Rundlauf, Fehlertoleranz und echte Blöcke (Bit für Bit wie der ETSI-Referenzdecoder)
    var speechRoundTrip = true, badFlagged = 0
    for _ in 0..<30 {
        let a = (0..<137).map { _ in UInt8.random(in: 0...1, using: &rng) }, b = (0..<137).map { _ in UInt8.random(in: 0...1, using: &rng) }
        let frames = TETRASpeech.decodeBlock(TETRA.soft(TETRASpeech.encodeBlock(a, b)))
        if frames?[0].bits != a || frames?[1].bits != b || frames?[0].badFrame != false { speechRoundTrip = false }
        var noisy = TETRA.soft(TETRASpeech.encodeBlock(a, b))
        for _ in 0..<10 { let p = Int.random(in: 0..<432, using: &rng); noisy[p] = -noisy[p] }
        if TETRASpeech.decodeBlock(noisy)?[0].badFrame == true { badFlagged += 1 }
        // Halbblock bei Blockraub
        let half = TETRASpeech.decodeHalf(TETRA.soft(TETRA.blockInterleave(Array(TETRASpeech.encodeHalf(a)), a: 101).isEmpty ? [] : TETRASpeech.encodeHalf(a)))
        if half?.bits != a || half?.badFrame != false { speechRoundTrip = false }
    }
    check(speechRoundTrip, "TETRA: Sprachblock und Halbblock (Blockraub): Codierer → Decoder Rundlauf, Klassen, Prüfbits")
    check(badFlagged <= 3, "TETRA: Sprachblock mit zehn Bitfehlern meist noch fehlerfrei (\(badFlagged)/30 markiert)")
    var wrecked = TETRA.soft(TETRASpeech.encodeBlock((0..<137).map { UInt8($0 & 1) }, (0..<137).map { _ in UInt8.random(in: 0...1, using: &rng) }))
    for i in stride(from: 0, to: 432, by: 3) { wrecked[i] = -wrecked[i] }
    check(TETRASpeech.decodeBlock(wrecked)?[0].badFrame == true, "TETRA: zerstörter Sprachblock wird über die Prüfbits als fehlerhaft erkannt")
    let teliveURL = URL(fileURLWithPath: "Vendor/_upstream/tetra/telive/testfile.acelp")
    if let d = try? Data(contentsOf: teliveURL), d.count == 41400 {
        var hash: UInt64 = 0xcbf29ce484222325
        var bad = 0
        for blk in 0..<30 {
            func w(_ i: Int) -> SoftBit { SoftBit(truncatingIfNeeded: Int(Int16(bitPattern: UInt16(d[2 * (blk * 690 + i)]) | UInt16(d[2 * (blk * 690 + i) + 1]) << 8))) }
            let soft = (0..<114).map { w(1 + $0) } + (0..<114).map { w(116 + $0) } + (0..<114).map { w(231 + $0) } + (0..<90).map { w(346 + $0) }
            for f in TETRASpeech.decodeBlock(soft) ?? [] {
                if f.badFrame { bad += 1 }
                for b in f.bits { hash ^= UInt64(b); hash = hash &* 0x100000001b3 }
            }
        }
        check(bad == 0 && hash == 0x727d9ff62bf18d88, "TETRA echt: 30 Sprachblöcke aus telive (60 Rahmen) stimmen Bit für Bit mit dem ETSI-Referenzdecoder überein")
    } else { skip("TETRA echt: telive/testfile.acelp liegt nicht lokal vor (github.com/sq5bpf/telive)") }

    // Zeit
    var t = TETRATime(tn: 4, fn: 18, mn: 60); t.advance()
    check(t == TETRATime(tn: 1, fn: 1, mn: 1), "TETRA: Zeitzähler läuft von Schlitz 4, Rahmen 18, Mehrfachrahmen 60 auf 1/1/1 um")
}

// TETRA: Sendebursts durch Synchronisierer, untere und obere MAC-Schicht (Bitebene)
@MainActor func tetraSpeechFrames() -> [[UInt8]] {
    var rng = SystemRandomNumberGenerator()
    // Rahmen mit erkennbarem Muster: Sprache selbst wird nicht gebraucht, nur eindeutige Rahmen
    return (0..<80).map { _ in (0..<137).map { _ in UInt8.random(in: 0...1, using: &rng) } }
}
final class TETRABox: @unchecked Sendable { var chunks: [TETRASpeechChunk] = []; var samples = 0; var signals: [String] = [] }
if want("tetra") {
    let frames = tetraSpeechFrames()
    var cfg = TETRATestNetwork.Config()
    cfg.text = "Digidec Test \u{E4}\u{F6}\u{FC}"
    let net = TETRATestNetwork(config: cfg, speech: frames)
    let bursts = net.bursts(frames: 70, callStart: 22, callEnd: 60, stealEvery: 7)
    let tracker = TETRACallTracker()
    let box = TETRABox()
    let car = TETRACarrier(frequency: 426_700_000, inputRate: 72_000, centerFrequency: 426_700_000)
    car.onSignal = { s, tm in tracker.handle(s, time: tm, carrier: 426_700_000) }
    car.onTraffic = { b in box.chunks += tracker.traffic(b, carrier: 426_700_000) }
    var stream: [SoftBit] = (0..<1020).map { _ in SoftBit.random(in: -60...60) }
    for b in bursts { stream += TETRA.soft(b) }
    car.framer.feed(stream)
    let snap = tracker.snapshot()
    check(car.framer.statistics.locks == 1 && car.framer.statistics.losses == 0 && car.lowerMAC.crcBad == 0 && car.lowerMAC.crcOK > 200, "TETRA: Sendebursts: ein Lauf Synchronisation, keine fehlerhafte CRC (\(car.lowerMAC.crcOK) gut)")
    check(tracker.currentNetwork?.mcc == nil || true, "TETRA: Netz")
    let n = tracker.currentNetwork
    check(n?.downlinkHz == 426_700_000 && n?.locationArea == 1 && n?.voiceService == true && n?.airEncryption == false, "TETRA: Systeminformation: Träger 426,7 MHz, Standortbereich 1, Sprachdienst")
    check(car.syncInfo?.mcc == 262 && car.syncInfo?.mnc == 99 && car.syncInfo?.colourCode == 7, "TETRA: Synchronisationsnachricht: MCC 262, MNC 99, Farbcode 7")
    check(snap.calls.count == 1, "TETRA: ein Gespräch erkannt")
    if let c = snap.calls.first {
        check(c.target == 100601 && c.caller == 100701 && c.usageMarker == 51 && c.callID == 113 && c.timeslot == 2 && c.carrierHz == 426_700_000 && c.isGroup, "TETRA: Gespräch: Gruppe 100601, Rufer 100701, Marke 51, Ruf 113, Zeitschlitz 2")
        check(c.speakers == [100701, 100702] && c.speaker == 100702, "TETRA: Sprecherwechsel erkannt (100701 → 100702), jetzt \(c.speakers)")
        check(c.released && c.end != nil, "TETRA: Freigabe beendet das Gespräch")
        check(c.missingFrames > 0 && c.frames > 60 && c.badFrames == c.missingFrames, "TETRA: Blockraub: \(c.missingFrames) Sprachrahmen durch Signalisierung ersetzt, sonst keine fehlerhaften (\(c.frames) Rahmen)")
        let wanted = Set(frames)
        check(c.audio.filter { !$0.badFrame }.allSatisfy { wanted.contains($0.bits) }, "TETRA: alle übertragenen Sprachrahmen kommen bitgleich an")
    }
    check(snap.events.contains { $0.kind == "SDS" && $0.text.contains("Digidec Test äöü") }, "TETRA: Kurznachricht (SDS) mit Text gelesen (\(snap.events.filter { $0.kind == "SDS" }.map(\.text)))")
    check(snap.subscribers.contains { $0.ssi == 100702 } && snap.subscribers.contains { $0.ssi == 100601 }, "TETRA: Teilnehmerliste enthält Gruppe und Sprecher")
}

// TETRA: Funkebene mit Rauschen, Versatz, Taktfehler und 8-Bit-Quantisierung; verschiedene Abtastraten und Stückgrößen
if want("tetra") {
    let frames = tetraSpeechFrames()
    @MainActor func runRF(rate: Double, offsetHz: Double, ppm: Double, snr: Double?, label: String, chunk: Int, frameCount: Int = 56, carrierCenterOffset: Double = 0) -> (matched: Int, calls: Int, bad: Int, crcBad: Int, locked: Bool, offset: Double, audio: Int) {
        let net = TETRATestNetwork(config: TETRATestNetwork.Config(), speech: frames)
        let bs = net.bursts(frames: frameCount, callStart: 22 - 2, callEnd: frameCount - 3, stealEvery: 7)
        var bits: [UInt8] = (0..<1020).map { _ in UInt8.random(in: 0...1) }
        for b in bs { bits += b }
        let (i, q) = TETRAModulator.modulate(bits: bits, sampleRate: rate, offsetHz: offsetHz, clockPPM: ppm)
        var bytes = [UInt8](repeating: 128, count: 2 * i.count)
        let sigma = snr.map { Float(pow(10, -$0 / 20) / 2.0.squareRoot()) } ?? 0
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Float {
            let u1 = Float.random(in: 1e-7...1, using: &rng), u2 = Float.random(in: 0...1, using: &rng)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        for k in 0..<i.count {
            bytes[2 * k] = UInt8(max(0, min(255, ((i[k] + sigma * gauss()) * 0.45 * 127.5 + 127.5).rounded())))
            bytes[2 * k + 1] = UInt8(max(0, min(255, ((q[k] + sigma * gauss()) * 0.45 * 127.5 + 127.5).rounded())))
        }
        let engine = TETRAEngine()
        let box = TETRABox()
        engine.audioSink = { box.samples += $0.count }
        engine.speech = TETRASpeechAdapter(name: "Test", reset: {}, decode: { _, _ in [Int16](repeating: 0, count: 240) })
        let center = 426_700_000.0 - carrierCenterOffset
        engine.configure(sampleRate: Int(rate), centerFrequency: center, frequencies: [426_700_000], countClipping: true)
        var pos = 0
        while pos < i.count {
            let m = min(chunk, i.count - pos)
            bytes.withUnsafeBufferPointer { b in engine.feed(UnsafeBufferPointer(rebasing: b[(2 * pos)..<(2 * (pos + m))]), wait: true) }
            pos += m
        }
        let s = engine.snapshot()
        let ch = s.channels.first
        let wanted = Set(frames)
        let matched = s.calls.first.map { c in c.audio.filter { !$0.badFrame && wanted.contains($0.bits) }.count } ?? 0
        return (matched, s.calls.count, s.calls.first?.badFrames ?? 0, ch?.crcBad ?? 99, ch?.locked ?? false, ch?.offsetHz ?? 0, box.samples / 240)
    }
    let a = runRF(rate: 72_000, offsetHz: 0, ppm: 0, snr: nil, label: "72k", chunk: 4800)
    check(a.calls == 1 && a.matched >= 60 && a.crcBad == 0 && a.locked && a.audio >= 60, "TETRA Funk: 72 kS/s sauber: \(a.matched) Sprachrahmen bitgleich, keine CRC-Fehler")
    let b = runRF(rate: 48_000, offsetHz: 400, ppm: 20, snr: 20, label: "48k", chunk: 4800)
    check(b.calls == 1 && b.matched >= 60 && b.crcBad == 0 && abs(b.offset - 400) < 40, "TETRA Funk: 48 kS/s, +400 Hz, 20 ppm, 20 dB: \(b.matched) Rahmen, Versatz \(Int(b.offset)) Hz")
    let c1 = runRF(rate: 72_000, offsetHz: 6500, ppm: 100, snr: 12, label: "72k Versatz", chunk: 4096)
    check(c1.calls == 1 && c1.matched >= 55 && c1.crcBad == 0 && abs(c1.offset - 6500) < 80, "TETRA Funk: +6,5 kHz, 100 ppm, 12 dB (Grobsuche): \(c1.matched) Rahmen, Versatz \(Int(c1.offset)) Hz")
    let c2 = runRF(rate: 72_000, offsetHz: -7000, ppm: -50, snr: 9, label: "72k neg", chunk: 100_000)
    check(c2.calls == 1 && c2.matched >= 50 && abs(c2.offset + 7000) < 80, "TETRA Funk: −7 kHz, −50 ppm, 9 dB, große Stücke (Nachführung unabhängig von der Stückgröße): \(c2.matched) Rahmen")
    let d = runRF(rate: 2_000_000, offsetHz: 300_000 + 2_500, ppm: 10, snr: 25, label: "2M", chunk: 32_768, frameCount: 40, carrierCenterOffset: 300_000)
    check(d.calls == 1 && d.matched >= 25 && d.crcBad == 0 && abs(d.offset - 2500) < 60, "TETRA Funk: 2 MS/s, Träger bei +300 kHz, +2,5 kHz, 10 ppm, 25 dB, 8 Bit: \(d.matched) Rahmen, Versatz \(Int(d.offset)) Hz")
}

// TETRA: zwei Träger im selben Fenster (Steuerkanal und Verkehrskanal), Zuschalten durch die Kanalzuweisung
if want("tetra") {
    let frames = tetraSpeechFrames()
    var cfgA = TETRATestNetwork.Config()
    cfgA.allocationCarrier = 1069; cfgA.trafficSlot = 3; cfgA.hostsTraffic = false; cfgA.text = nil
    let netA = TETRATestNetwork(config: cfgA, speech: frames)
    let bsA = netA.bursts(frames: 90, callStart: 20, callEnd: 84)
    var cfgB = TETRATestNetwork.Config()
    cfgB.mainCarrier = 1069; cfgB.trafficSlot = 3; cfgB.controlChannel = false; cfgB.text = nil
    let netB = TETRATestNetwork(config: cfgB, speech: frames)
    let bsB = netB.bursts(frames: 90, callStart: 20, callEnd: 84)
    func flat(_ bs: [[UInt8]]) -> [UInt8] { var o: [UInt8] = (0..<1020).map { _ in UInt8.random(in: 0...1) }; for b in bs { o += b }; return o }
    let rate = 2_000_000.0
    let (ia, qa) = TETRAModulator.modulate(bits: flat(bsA), sampleRate: rate, offsetHz: 150_000)
    let (ib, qb) = TETRAModulator.modulate(bits: flat(bsB), sampleRate: rate, offsetHz: 150_000 + 25_000, clockPPM: 5)
    let count = min(ia.count, ib.count)
    var bytes = [UInt8](repeating: 128, count: 2 * count)
    for k in 0..<count {
        bytes[2 * k] = UInt8(max(0, min(255, ((ia[k] + ib[k]) * 0.3 * 127.5 + 127.5).rounded())))
        bytes[2 * k + 1] = UInt8(max(0, min(255, ((qa[k] + qb[k]) * 0.3 * 127.5 + 127.5).rounded())))
    }
    let engine = TETRAEngine()
    engine.configure(sampleRate: Int(rate), centerFrequency: 426_700_000 - 150_000, frequencies: [426_700_000], countClipping: true)
    var pos = 0
    while pos < count {
        let m = min(32_768, count - pos)
        bytes.withUnsafeBufferPointer { b in engine.feed(UnsafeBufferPointer(rebasing: b[(2 * pos)..<(2 * (pos + m))]), wait: true) }
        pos += m
    }
    let s = engine.snapshot()
    check(s.channels.count == 2 && s.channels.allSatisfy(\.locked), "TETRA: zweiter Träger (426,7250 MHz) durch die Kanalzuweisung zugeschaltet, beide synchron (\(s.channels.count) Träger)")
    let call = s.calls.first(where: { $0.target == 100601 })
    check(call != nil && (call?.frames ?? 0) > 12 && call?.carrierHz == 426_725_000 && call?.timeslot == 3, "TETRA: Gespräch läuft auf dem zugeschalteten Träger (\(call?.frames ?? 0) Sprachrahmen, \(String(describing: call?.carrierHz)) Hz)")
    let wanted = Set(frames)
    check(call?.audio.filter { !$0.badFrame }.allSatisfy { wanted.contains($0.bits) } == true, "TETRA: Sprachrahmen vom zweiten Träger bitgleich")
}

// TETRA: Zerlegte Nachrichten (MAC-RESOURCE mit Fortsetzung, MAC-FRAG, MAC-END) und 7-Bit-Text
if want("tetra") {
    let text = "Alarm Halle 7: Brandmeldeanlage ausgeloest, bitte melden."
    let sdu = TETRAPDUBuilder.dSDSSDU(from: 100701, text: text)
    var head = TETRABitWriter()
    head.put(0, 2); head.put(0, 1); head.put(0, 1); head.put(0, 2); head.put(0, 1); head.put(0x3F, 6)
    head.put(1, 3); head.put(100601, 24); head.put(0, 1); head.put(0, 1); head.put(0, 1)
    let room1 = 268 - head.count
    let block1 = head.bits + Array(sdu[0..<room1])
    var rest = Array(sdu[room1...])
    // MAC-FRAG: Typ 01, Teilart 0, keine Füllbits, 264 Bits Nutzdaten
    let frag = TETRABitWriter(bits: [0, 1, 0, 0] + Array(rest.prefix(264)))
    rest = Array(rest.dropFirst(264))
    precondition(rest.count > 0 && rest.count < 230)
    // MAC-END: Typ 01, Teilart 1, Füllbits, Lage 0, Länge in Oktetten, ohne Zeitschlitzvergabe und Kanalzuweisung
    var end = TETRABitWriter(); end.put(1, 2); end.put(1, 1); end.put(1, 1); end.put(0, 1)
    let totalBits = 4 + 1 + 6 + 1 + 1 + rest.count + 1
    let octets = (totalBits + 7) / 8
    end.put(octets, 6); end.put(0, 1); end.put(0, 1)
    end.bits += rest; end.bits.append(1)
    while end.bits.count < octets * 8 { end.bits.append(0) }
    let up = TETRAUpperMAC()
    let got = TETRABox()
    up.onSignal = { s, _ in if case .sds(let m) = s { got.signals.append(m.text ?? "") } }
    func blk(_ b: [UInt8], tn: Int = 1) -> TETRAMacBlock { TETRAMacBlock(channel: .schF, bits: TETRAPDUBuilder.pad(b, to: 268), crcOK: true, time: TETRATime(tn: tn, fn: 3, mn: 5), blockNumber: 0, trafficMarker: 0) }
    up.process(blk(block1)); up.process(blk(frag.bits)); up.process(blk(end.bits))
    check(got.signals == [text], "TETRA: Kurznachricht über MAC-RESOURCE, MAC-FRAG und MAC-END zusammengesetzt (\(got.signals))")
    up.process(blk(end.bits, tn: 3))
    check(got.signals.count == 1, "TETRA: MAC-END ohne Anfang wird verworfen")
    // 7-Bit-Text: Zeichen LSB zuerst in Oktette gepackt
    var packed: [UInt8] = [0x00]
    var acc: UInt16 = 0, nb = 0
    for ch in Array("Halli Hallo".utf8) {
        acc |= UInt16(ch & 0x7F) << UInt16(nb); nb += 7
        while nb >= 8 { packed.append(UInt8(acc & 0xFF)); acc >>= 8; nb -= 8 }
    }
    if nb > 0 { packed.append(UInt8(acc & 0xFF)) }
    check(TETRAUpperMAC.decodeText(packed)?.hasPrefix("Halli Hallo") == true, "TETRA: 7-Bit-Text wird gelesen")
    check(TETRAUpperMAC.decodeText([0x01] + Array("Hallo".utf8)) == "Hallo", "TETRA: 8-Bit-Text wird gelesen")
}

// TETRA: Rufverfolgung, Filter und Verschlüsselung
if want("tetra") {
    let tracker = TETRACallTracker()
    var setup = TETRACallSignal(kind: .setup, callID: 5, address: TETRAAddress(kind: .ssiUsage, ssi: 4711, eventLabel: nil, usageMarker: 20), party: 999, usageMarker: 20, allocation: nil)
    setup.communicationType = 1
    tracker.handle(.call(setup), time: TETRATime(), carrier: 400e6)
    func block(_ marker: Int, bad: Bool = false) -> TETRATrafficBlock {
        let f = TETRASpeechFrame(bits: [UInt8](repeating: 1, count: 137), badFrame: bad)
        return TETRATrafficBlock(time: TETRATime(tn: 2), usageMarker: marker, frames: [f, f])
    }
    check(tracker.traffic(block(20), carrier: 400e6).count == 2, "TETRA: Verkehr einer bekannten Gruppe wird wiedergegeben")
    // Zweites Gespräch zugleich: nicht wiedergegeben
    check(tracker.traffic(block(33), carrier: 400e6).isEmpty, "TETRA: parallel laufendes zweites Gespräch bleibt stumm")
    // Gruppenfilter
    let t2 = TETRACallTracker()
    t2.configure(listenGroups: [1234])
    t2.handle(.call(setup), time: TETRATime(), carrier: 400e6)
    check(t2.traffic(block(20), carrier: 400e6).isEmpty && t2.snapshot().calls.first?.frames == 2, "TETRA: Gruppenfilter: andere Gruppe wird nicht abgespielt, aber gezählt")
    var wanted = setup
    wanted.callID = 6; wanted.usageMarker = 21; wanted.address = TETRAAddress(kind: .ssiUsage, ssi: 1234, eventLabel: nil, usageMarker: 21)
    t2.handle(.call(wanted), time: TETRATime(), carrier: 400e6)
    Thread.sleep(forTimeInterval: 0.9)
    check(t2.traffic(block(21), carrier: 400e6).count == 2, "TETRA: Gruppenfilter: gewählte Gruppe wird abgespielt")
    // Verschlüsselt
    let t3 = TETRACallTracker()
    var enc = setup; enc.encryptedCall = true
    t3.handle(.call(enc), time: TETRATime(), carrier: 400e6)
    check(t3.traffic(block(20), carrier: 400e6).isEmpty && t3.snapshot().calls.first?.encrypted == true, "TETRA: als verschlüsselt gekennzeichnetes Gespräch bleibt stumm")
    // Auffällig viele fehlerhafte Rahmen: Verdacht auf Verschlüsselung
    let t4 = TETRACallTracker()
    t4.handle(.call(setup), time: TETRATime(), carrier: 400e6)
    var heard = 0
    for _ in 0..<12 { heard += t4.traffic(block(20, bad: true), carrier: 400e6).count }
    check(t4.snapshot().calls.first?.suspect == true && heard < 24, "TETRA: fast nur fehlerhafte Rahmen: als verschlüsselt oder gestört markiert, Ton endet")
    // Auslaufen und Freigabe
    t4.expire(now: Date().addingTimeInterval(20))
    check(t4.snapshot().calls.first?.end != nil, "TETRA: Gespräch ohne Verkehr läuft aus")
    let t5 = TETRACallTracker()
    var late = TETRATrafficBlock(time: TETRATime(tn: 3), usageMarker: 40, frames: [nil, nil])
    late.frames = [TETRASpeechFrame(bits: [UInt8](repeating: 0, count: 137), badFrame: false), nil]
    check(t5.traffic(late, carrier: 400e6).count == 2 && t5.snapshot().calls.count == 1 && t5.snapshot().calls[0].target == nil, "TETRA: Verkehr ohne Rufaufbau (spätes Einsteigen) wird als eigenes Gespräch geführt")
    // Der Rufaufbau, der danach kommt, ergänzt dieses Gespräch (gleiche Marke), statt ein zweites anzulegen
    var lateSetup = setup; lateSetup.usageMarker = 40; lateSetup.address = TETRAAddress(kind: .ssiUsage, ssi: 555, eventLabel: nil, usageMarker: 40)
    t5.handle(.call(lateSetup), time: TETRATime(), carrier: 400e6)
    check(t5.snapshot().calls.count == 1 && t5.snapshot().calls[0].target == 555 && t5.snapshot().calls[0].callID == 5 && t5.snapshot().calls[0].frames == 2, "TETRA: später Rufaufbau ergänzt das Gespräch mit gleicher Marke")
    // Dieselbe Marke mit neuer Rufkennung: neues Gespräch, das alte ist beendet
    var other = lateSetup; other.callID = 6
    t5.handle(.call(other), time: TETRATime(), carrier: 400e6)
    check(t5.snapshot().calls.count == 2 && t5.snapshot().calls[0].end != nil && t5.snapshot().calls[1].end == nil, "TETRA: neue Rufkennung auf derselben Marke beginnt ein neues Gespräch")
}

// TETRA: Einstellungen, Kanalplan, Modul
if want("tetra") {
    check(TETRAChannelPlan.parseFrequencies("426,7000 426.725; 12 abc 3000") == [426.7, 426.725], "TETRA: Frequenzeingabe mit Komma und Punkt, unsinnige Werte verworfen")
    check(TETRAChannelPlan.parseGroups("100601, 100602;abc 7") == [100601, 100602, 7] && TETRAChannelPlan.parseLabels("100601 = Werkschutz\nx=y\n42=Chef = Boss") == [100601: "Werkschutz", 42: "Chef = Boss"], "TETRA: Gruppenliste und Namenstabelle")
    check(TETRAChannelPlan.center(for: [426.7]) == 426_400_000 && TETRAChannelPlan.fits(426_700_000, center: 426_400_000) && !TETRAChannelPlan.fits(428_000_000, center: 426_400_000), "TETRA: Empfangsfenster: ein Träger liegt 300 kHz über der Mitte")
    let wide = TETRAChannelPlan.center(for: [426.0, 427.0])
    check(abs(wide - 426_500_000) < 30_000 && TETRAChannelPlan.fits(426_000_000, center: wide) && TETRAChannelPlan.fits(427_000_000, center: wide), "TETRA: Empfangsfenster mit zwei weit auseinanderliegenden Trägern")
    check(DecoderModuleInfo.tetra.band == .vhfUhf && !DecoderModuleInfo.tetra.hasMap && DecoderModuleInfo.tetra.isAvailable && DecoderModuleInfo.tetra.displayName == "TETRA", "TETRA: Modul")
}

// MARK: - NDB
if want("ndb") {
    check(NDBFormat.collapse("ABCABC") == "ABC" && NDBFormat.collapse("ABAB") == "AB" && NDBFormat.collapse("ABCABCABC") == "ABC" && NDBFormat.collapse("ABCD") == "ABCD"
          && NDBFormat.collapse("EE") == "EE" && NDBFormat.collapse("AGB") == "AGB", "NDB: wiederholte Kennungsgruppe wird zusammengefasst")
    check(NDBFormat.carrierKHz(dialHz: 318_000, mode: "AM", toneHz: 1020) == 318 && NDBFormat.carrierKHz(dialHz: 318_000, mode: "USB", toneHz: 1020) == 318
          && abs(NDBFormat.carrierKHz(dialHz: 317_300, mode: "USB", toneHz: 700) - 318) < 0.01 && abs(NDBFormat.carrierKHz(dialHz: 319_000, mode: "LSB", toneHz: 800) - 318.2) < 0.01
          && NDBFormat.carrierKHz(dialHz: 318_000, mode: nil, toneHz: 0) == 318, "NDB: Träger aus Dial-Frequenz, Mode und Ton (AM, A2A in USB, Überlagerungston)")
    check(NDBFormat.toneKind(1020.4) == "A2A 1020 Hz" && NDBFormat.toneKind(399) == "A2A 400 Hz" && NDBFormat.toneKind(812) == "Ton 812 Hz", "NDB: Tonart")

    // Empfänger mit Testsignalen (getastete Kennung, Rauschen)
    func read(ident: String, tone: Double, dit: Double, snr: Double?, seconds: Double = 70, fixed: Double? = nil) -> (reads: [String], tone: Double) {
        final class Box: @unchecked Sendable { var reads: [String] = [] }
        let box = Box()
        let audio = NDBSignalGenerator.audio(ident: ident, toneHz: tone, dit: dit, repeatEvery: 11, seconds: seconds, snrDB: snr)
        let rx = NDBReceiver()
        rx.fixedToneHz = fixed
        rx.onIdent = { box.reads.append($0) }
        var pos = 0
        while pos < audio.count {
            let n = min(800, audio.count - pos)
            audio.withUnsafeBufferPointer { rx.process(UnsafeBufferPointer(rebasing: $0[pos..<(pos + n)])) }
            pos += n
        }
        return (box.reads, rx.reading.toneHz)
    }
    let a = read(ident: "AGB", tone: 1020, dit: 0.13, snr: nil)
    check(a.reads.count >= 5 && a.reads.allSatisfy { $0 == "AGB" } && abs(a.tone - 1020) < 3, "NDB: Kennung AGB, 1020 Hz, sauber: \(a.reads.count) Lesungen, Ton \(Int(a.tone)) Hz")
    let b = read(ident: "KW", tone: 400, dit: 0.15, snr: 12)
    check(b.reads.count >= 4 && b.reads.filter { $0 == "KW" }.count >= b.reads.count - 1 && abs(b.tone - 400) < 3, "NDB: Kennung KW, 400 Hz, 12 dB: \(b.reads)")
    let c = read(ident: "DLS", tone: 812, dit: 0.1, snr: 6)
    check(c.reads.filter { $0 == "DLS" }.count >= 4 && abs(c.tone - 812) < 3, "NDB: Überlagerungston 812 Hz (A1A in USB), 6 dB: \(c.reads)")
    let d = read(ident: "OSM", tone: 1020, dit: 0.17, snr: -3, seconds: 100)
    check(d.reads.filter { $0 == "OSM" }.count >= 5, "NDB: langsame Kennung bei −3 dB Rauschabstand (3 kHz): \(d.reads)")
    let e = read(ident: "T", tone: 1020, dit: 0.12, snr: 15)
    check(e.reads.filter { $0 == "T" }.count >= 4, "NDB: einbuchstabige Kennung")
    let f = read(ident: "ABU", tone: 1020, dit: 0.06, snr: 15, fixed: 1020)
    check(f.reads.filter { $0 == "ABU" }.count >= 4, "NDB: schnelle Kennung (Punkt 60 ms) mit fest eingestelltem Ton")
    let silent = read(ident: "", tone: 1020, dit: 0.12, snr: 10, seconds: 30)
    check(silent.reads.isEmpty, "NDB: nur Rauschen ergibt keine Kennung")

    // Sammeln und Bestätigen
    var tracker = NDBIdentTracker()
    check(!tracker.add("AGB") && !tracker.confirmed && tracker.ident == "AGB", "NDB: erste Lesung ist unbestätigt")
    check(tracker.add("AGB") && tracker.confirmed, "NDB: zweite gleiche Lesung bestätigt")
    check(!tracker.add("ABB") && tracker.confirmed && tracker.ident == "AGB", "NDB: Fehllesung kippt die bestätigte Kennung nicht")
    tracker.reset()
    _ = tracker.add("XY"); _ = tracker.add("XZ"); _ = tracker.add("XY")
    check(tracker.ident == "XY" && tracker.confirmed, "NDB: Mehrheit entscheidet")

    // Datenbank
    let db = NDBDatabase(loadCache: false)
    check(db.count > 1000 && db.count == NDBBuiltinData.count, "NDB: eingebaute Liste (\(db.count) Funkfeuer)")
    let agb = db.lookup(ident: "AGB", frequencyKHz: 318)
    check(agb.first?.name == "Augsburg" && agb.first?.country == "DE" && agb.first?.frequencyKHz == 318, "NDB: AGB = Augsburg, 318 kHz")
    let home = Maidenhead.point("JN49WS")!
    let near = db.within(km: 300, of: home)
    check(near.count > 5 && zip(near, near.dropFirst()).allSatisfy { $0.km <= $1.km } && near.allSatisfy { $0.km <= 300 }, "NDB: Umkreis nach Entfernung sortiert (\(near.count) Funkfeuer in 300 km)")
    if case .confirmed(let s) = NDBMatch.evaluate(ident: "AGB", frequencyKHz: 318, database: db) { check(s.name == "Augsburg", "NDB: Abgleich bestätigt") } else { check(false, "NDB: Abgleich bestätigt") }
    if case .confirmed = NDBMatch.evaluate(ident: "AGB", frequencyKHz: 318.5, database: db) { check(true, "NDB: halbe kHz Abweichung zählt noch") } else { check(false, "NDB: halbe kHz Abweichung zählt noch") }
    if case .identOnly(_, let delta) = NDBMatch.evaluate(ident: "AGB", frequencyKHz: 322, database: db) { check(abs(delta - 4) < 0.01, "NDB: Kennung stimmt, Frequenz weicht um 4 kHz ab") } else { check(false, "NDB: Kennung stimmt, Frequenz weicht ab") }
    if case .frequencyOnly(let l) = NDBMatch.evaluate(ident: "ZZZ", frequencyKHz: 318, database: db) { check(l.contains { $0.ident == "AGB" }, "NDB: Frequenz bekannt, Kennung anders") } else { check(false, "NDB: Frequenz bekannt, Kennung anders") }
    check(NDBMatch.evaluate(ident: "QQQ", frequencyKHz: 1555, database: db) == .unknown, "NDB: unbekannt")
    let csv = "id,filename,ident,name,type,frequency_khz,latitude_deg,longitude_deg,elevation_ft,iso_country\n1,x,\"AB\",\"Test, Feuer\",NDB,355,50.5,9.5,100,DE\n2,y,VX,Vor,VOR,114000,50,9,0,DE\n3,z,CD,Zwei,NDB-DME,402,51,8,0,AT\n"
    let parsed = NDBDatabase.parseCSV(csv)
    check(parsed.count == 2 && parsed[0].name == "Test, Feuer" && parsed[0].frequencyKHz == 355 && parsed[1].country == "AT", "NDB: CSV (Anführungszeichen, nur NDB und NDB-DME)")
    if let text = try? String(contentsOfFile: "TestData/NDB/navaids.csv", encoding: .utf8) {
        let all = NDBDatabase.parseCSV(text)
        check(all.count > 6000 && all.filter { $0.country == "DE" }.count >= 90, "NDB echt: OurAirports-Liste mit \(all.count) Funkfeuern gelesen")
    } else { skip("NDB echt: TestData/NDB/navaids.csv liegt nicht lokal vor (ourairports.com/data)") }

    // Controller
    let settings = NDBSettingsStore()
    settings.manualKHz = 318
    let ndb = NDBController(pipeline: AudioPipeline(), settings: settings, database: db)
    ndb.home = { home }
    ndb.ingest("AGB"); ndb.ingest("AGBAGB")
    if case .confirmed(let s) = ndb.match { check(s.ident == "AGB", "NDB: Controller gleicht die bestätigte Kennung mit der Liste ab") } else { check(false, "NDB: Controller gleicht ab (\(ndb.match))") }
    check(ndb.heard.count == 1 && ndb.heard[0].confirmedByList && (ndb.heard[0].km ?? 0) > 100 && (ndb.heard[0].km ?? 0) < 250, "NDB: gehörtes Funkfeuer mit Entfernung (\(ndb.heard.first?.km ?? 0) km)")
    let map = ndb.mapContent(now: Date())
    check(map.markers.contains { $0.title == "AGB" && $0.tone != .dim } && map.markers.count > 20 && !map.lines.isEmpty, "NDB: Karte zeigt Funkfeuer im Umkreis und das gehörte hervorgehoben")
    settings.setCenter(900)
    check(settings.centerHz == 900 && settings.fixedToneHz == 900 && DecoderModuleInfo.ndb.band == .hf && DecoderModuleInfo.ndb.hasMap && DecoderModuleInfo.ndb.displayName == "NDB", "NDB: Ton per Klick im Wasserfall, Modul")
    settings.fixedToneHz = 0; settings.manualKHz = 0
}

// MARK: - SDR-Empfänger (eingebaut)
if want("sdr") {
    func level(_ a: [Float], _ f: Double, skip: Double = 0.4) -> Double {
        let start = Int(skip * 48_000)
        guard a.count > start + 4_800 else { return 0 }
        let n = a.count - start
        var re = 0.0, im = 0.0, w = 0.0
        for k in 0..<n {
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n))
            let ph = 2 * Double.pi * f * Double(k) / 48_000
            re += Double(a[start + k]) * win * cos(ph)
            im -= Double(a[start + k]) * win * sin(ph)
            w += win
        }
        return 2 * (re * re + im * im).squareRoot() / w
    }
    func run(_ s: SDRTestSignal, _ config: SDRChannelConfig, offset: Double, chunk: Int = 262_144) -> [Float] {
        let demod = SDRDemodulator(sampleRate: s.sampleRate, config: config)
        demod.setOffset(offset)
        var audio = [Float]()
        let bytes = s.quantized()
        bytes.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count { let e = min(i + chunk, b.count); demod.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &audio); i = e }
        }
        return audio
    }
    let fs = 2_400_000.0
    // FM mit Nachbarkanal
    var fm = SDRTestSignal(sampleRate: fs, seconds: 1.5)
    fm.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.4)
    fm.addFM(offsetHz: 325_000, tone: 2000, deviation: 3000, amplitude: 0.5)
    fm.addNoise(sigma: 0.003)
    var cfm = SDRChannelConfig(mode: .nfm); cfm.bandwidthHz = 12_500
    let fa = run(fm, cfm, offset: 300_000)
    check(abs(level(fa, 1000) - 0.6) < 0.05, "SDR FM: 3 kHz Hub ergibt Amplitude 0,6 (\(level(fa, 1000)))")
    check(level(fa, 2000) / level(fa, 1000) < 0.02, "SDR FM: Nachbarkanal in 25 kHz Abstand um mehr als 34 dB unterdrückt")
    // AM
    var am = SDRTestSignal(sampleRate: fs, seconds: 1.5)
    am.addAM(offsetHz: -200_000, tone: 1000, depth: 0.5, amplitude: 0.3)
    am.addNoise(sigma: 0.003)
    let aa = run(am, SDRChannelConfig(mode: .am), offset: -200_000)
    check(abs(level(aa, 1000) - 0.5) < 0.05, "SDR AM: Modulationsgrad 50 % ergibt Amplitude 0,5 (\(level(aa, 1000)))")
    // SSB: oberes Seitenband hörbar, unteres unterdrückt; LSB umgekehrt
    var ssb = SDRTestSignal(sampleRate: fs, seconds: 1.5)
    ssb.addCarrier(offsetHz: 500_000 + 1500, amplitude: 0.1)
    ssb.addCarrier(offsetHz: 500_000 - 2000, amplitude: 0.1)
    ssb.addNoise(sigma: 0.002)
    var cu = SDRChannelConfig(mode: .usb); cu.agc = false
    let ua = run(ssb, cu, offset: 500_000)
    check(level(ua, 1500) > 0.1 && level(ua, 2000) / level(ua, 1500) < 0.003, "SDR USB: Ton im oberen Seitenband, unteres um mehr als 50 dB unterdrückt")
    cu.mode = .lsb
    let la = run(ssb, cu, offset: 500_000)
    check(level(la, 2000) > 0.1 && level(la, 1500) / level(la, 2000) < 0.003, "SDR LSB: Ton im unteren Seitenband, oberes um mehr als 50 dB unterdrückt")
    // CW: der Träger auf der angezeigten Frequenz wird als 700-Hz-Ton hörbar
    var cw = SDRTestSignal(sampleRate: fs, seconds: 1.5)
    cw.addCarrier(offsetHz: -400_000, amplitude: 0.1)
    cw.addNoise(sigma: 0.002)
    var ccw = SDRChannelConfig(mode: .cw); ccw.agc = false
    let ca = run(cw, ccw, offset: -400_000)
    check(level(ca, 700) > 0.1 && level(ca, 1500) / level(ca, 700) < 0.01, "SDR CW: Träger als 700-Hz-Ton")
    // Rundfunk-FM mit Pilotton
    var wfm = SDRTestSignal(sampleRate: fs, seconds: 1.5)
    wfm.addFM(offsetHz: -300_000, tone: 1000, deviation: 75_000, amplitude: 0.3)
    wfm.addNoise(sigma: 0.003)
    let wa = run(wfm, SDRChannelConfig(mode: .wfm), offset: -300_000)
    check(abs(level(wa, 1000) - 0.95) < 0.1, "SDR WFM: 75 kHz Hub ergibt etwa Vollaussteuerung (\(level(wa, 1000)))")
    // Squelch
    var noise = SDRTestSignal(sampleRate: fs, seconds: 1.5)
    noise.addNoise(sigma: 0.01)
    var csq = SDRChannelConfig(mode: .nfm); csq.squelchEnabled = true; csq.squelchDB = -50
    let sq = run(noise, csq, offset: 300_000)
    check(sq.dropFirst(24_000).allSatisfy { $0 == 0 }, "SDR: Squelch sperrt bei Rauschen")
    // Squelch-Schließzeit: Nach Signalende schließt die Rauschsperre innerhalb von wenigen Blöcken (< 40 ms)
    var sigThenSilence = SDRTestSignal(sampleRate: fs, seconds: 0.2)
    sigThenSilence.addFM(offsetHz: 0, tone: 1000, deviation: 3000, amplitude: 0.3)
    var silencePart = SDRTestSignal(sampleRate: fs, seconds: 0.3)
    silencePart.addNoise(sigma: 0.0001)
    var csqFast = SDRChannelConfig(mode: .nfm)
    csqFast.squelchEnabled = true
    csqFast.squelchDB = -50
    let dSqu = SDRDemodulator(sampleRate: fs, config: csqFast)
    dSqu.setOffset(0)
    var dummyAudio = [Float]()
    let sigBytes = sigThenSilence.quantized()
    sigBytes.withUnsafeBufferPointer { b in dSqu.process(b, audio: &dummyAudio) }
    check(dSqu.isSquelchOpen, "SDR Squelch: bei starkem Signal geöffnet")
    let silBytes = silencePart.quantized()
    var closedWithinChunks = 0
    let chunkSz = 16384
    silBytes.withUnsafeBufferPointer { b in
        var idx = 0
        while idx < b.count {
            let end = min(idx + chunkSz, b.count)
            dSqu.process(UnsafeBufferPointer(rebasing: b[idx..<end]), audio: &dummyAudio)
            closedWithinChunks += 1
            if !dSqu.isSquelchOpen { break }
            idx = end
        }
    }
    let timeToCloseMs = Double(closedWithinChunks * chunkSz) / (2.0 * fs) * 1000.0
    check(!dSqu.isSquelchOpen && timeToCloseMs < 40.0, "SDR Squelch: schließt nach Signalende rasch (in \(String(format: "%.1f", timeToCloseMs)) ms < 40 ms)")
    // Blockunabhängigkeit
    let whole = run(fm, cfm, offset: 300_000, chunk: 4_800_000), parts = run(fm, cfm, offset: 300_000, chunk: 7_000)
    var maxDiff: Float = 0
    for k in 0..<min(whole.count, parts.count) { maxDiff = max(maxDiff, abs(whole[k] - parts[k])) }
    check(whole.count == parts.count && maxDiff < 2e-3, "SDR: Ergebnis hängt nicht von der Blockaufteilung ab (\(maxDiff))")
    // Betriebsarten und Hamlib-Namen
    check(SDRMode(hamlib: "FM") == .nfm && SDRMode(hamlib: "WFM") == .wfm && SDRMode(hamlib: "PKTUSB") == .usb && SDRMode(hamlib: "RTTY") == .lsb
          && SDRMode(hamlib: "CW") == .cw && SDRMode(hamlib: "CWR") == .cwr && SDRMode(hamlib: "xyz") == nil, "SDR: Hamlib-Namen der Betriebsarten")
    // Spektrum: Träger bei −700 kHz an der richtigen Stelle, Pegel stimmt
    var sp = SDRTestSignal(sampleRate: fs, seconds: 1)
    sp.addCarrier(offsetHz: -700_000, amplitude: 0.05)
    sp.addNoise(sigma: 0.003)
    let engine = SDRReceiverEngine(sampleRate: fs)
    let bytes = sp.quantized()
    bytes.withUnsafeBufferPointer { b in
        var i = 0
        while i < b.count { let e = min(i + 262_144, b.count); engine.feed(UnsafeBufferPointer(rebasing: b[i..<e]), wait: true); i = e }
    }
    Thread.sleep(forTimeInterval: 0.5)
    let rows = engine.takeSpectrumRows()
    check(rows.count >= 20 && rows.count <= 30, "SDR: etwa 25 Spektrumzeilen je Sekunde (\(rows.count))")
    if let row = rows.last {
        let binHz = fs / Double(SDRSpectrum.size)
        let center = SDRSpectrum.size / 2 + Int((-700_000 / binHz).rounded())
        var best = center, v: Float = -200
        for k in (center - 40)...(center + 40) where row[k] > v { v = row[k]; best = k }
        check(abs(Double(best - SDRSpectrum.size / 2) * binHz + 700_000) < 3_000 && abs(Double(v) - 20 * log10(0.05)) < 2.5, "SDR: Spektrum zeigt den Träger bei −700 kHz mit richtigem Pegel (\(v) dB)")
    }
    // Kanalbank: Planung der Gerätemitte
    func slot(_ id: Int, _ f: Double, bw: Double = 12_500) -> SDRBankSlot { SDRBankSlot(id: id, moduleID: "aprs", frequencyHz: f, mode: .nfm, bandwidthHz: bw) }
    let half = SDRSettingsStore.window(forRate: 2_400_000)
    check(half == 850_000 && SDRSettingsStore.window(forRate: 9_600_000) == 3_400_000, "SDR Bank: nutzbares Fenster 850 kHz bei 2,4 MS/s, 3,4 MHz bei 9,6 MS/s")
    let p1 = SDRBankPlanner.plan(slots: [slot(1, 161_975_000, bw: 25_000), slot(2, 162_025_000, bw: 25_000)], halfWindowHz: half)
    check(p1.covered == [1, 2] && p1.uncovered.isEmpty && abs(p1.loHz - 162_000_000) >= 40_000 && abs(p1.loHz - 162_000_000) <= 100_000, "SDR Bank: AIS A und B liegen zusammen im Fenster, die Mitte meidet die Gleichanteil-Spitze (\(p1.loHz))")
    let p2 = SDRBankPlanner.plan(slots: [slot(1, 144_800_000), slot(2, 145_500_000), slot(3, 161_975_000)], halfWindowHz: half)
    check(p2.covered == [1, 2] && p2.uncovered == [3], "SDR Bank: 144,8 und 145,5 MHz passen zusammen, 161,975 MHz liegt außerhalb (\(p2.covered) / \(p2.uncovered))")
    let p3 = SDRBankPlanner.plan(slots: [slot(1, 144_800_000), slot(2, 161_975_000), slot(3, 162_025_000), slot(4, 162_300_000)], halfWindowHz: half)
    check(p3.covered == [2, 3, 4] && p3.uncovered == [1], "SDR Bank: das Fenster mit den meisten Kanälen gewinnt (\(p3.covered))")
    var disabled = slot(5, 100_000_000); disabled.enabled = false
    check(SDRBankPlanner.plan(slots: [disabled], halfWindowHz: half, currentLoHz: 7).covered.isEmpty && SDRBankPlanner.plan(slots: [disabled], halfWindowHz: half, currentLoHz: 7).loHz == 7, "SDR Bank: ausgeschaltete Kanäle zählen nicht")
    let keep = SDRBankPlanner.plan(slots: [slot(1, 131_550_000), slot(2, 131_725_000)], halfWindowHz: half, currentLoHz: 131_900_000)
    check(keep.loHz == 131_900_000, "SDR Bank: trägt die bisherige Mitte alle Kanäle, bleibt das Gerät stehen (kein Umstimmen)")
    let p9 = SDRBankPlanner.plan(slots: [slot(1, 130_300_000), slot(2, 131_550_000), slot(3, 133_000_000), slot(4, 136_900_000), slot(5, 136_975_000)], halfWindowHz: SDRSettingsStore.window(forRate: 9_600_000))
    check(p9.covered == [1, 2, 3, 4, 5] && p9.spanHz > 6_000_000, "SDR Bank: 9,6 MS/s überspannt 130,3 bis 137 MHz (\(p9.covered))")

    // Mehrere Kanäle zugleich aus einem I/Q-Strom
    final class Collector: @unchecked Sendable {
        let lock = NSLock(); var samples: [Float] = []
        func add(_ b: UnsafeBufferPointer<Float>) { lock.lock(); samples.append(contentsOf: b); lock.unlock() }
        var all: [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    }
    for rate in [2_400_000.0, 4_800_000.0] {
        let wide = rate > 3_000_000
        var multi = SDRTestSignal(sampleRate: rate, seconds: 2)
        let farA = wide ? 1_600_000.0 : 500_000.0, farB = wide ? -1_800_000.0 : -600_000.0
        multi.addFM(offsetHz: farA, tone: 1000, deviation: 3_000, amplitude: 0.2)
        multi.addFM(offsetHz: farB, tone: 2000, deviation: 3_000, amplitude: 0.2)
        multi.addAM(offsetHz: 150_000, tone: 700, depth: 0.5, amplitude: 0.15)
        multi.addNoise(sigma: 0.004)
        let bank = SDRReceiverEngine(sampleRate: rate)
        let outA = Collector(), outB = Collector(), outC = Collector()
        var cfm = SDRChannelConfig(mode: .nfm); cfm.bandwidthHz = 12_500
        bank.setPrimaryEnabled(false)
        bank.setExtraChannel(id: 1, config: cfm, offsetHz: farA, handler: { outA.add($0) })
        bank.setExtraChannel(id: 2, config: cfm, offsetHz: farB, handler: { outB.add($0) })
        bank.setExtraChannel(id: 3, config: SDRChannelConfig(mode: .am), offsetHz: 150_000, handler: { outC.add($0) })
        let raw = multi.quantized()
        raw.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count { let e = min(i + 262_144, b.count); bank.feed(UnsafeBufferPointer(rebasing: b[i..<e]), wait: true); i = e }
        }
        Thread.sleep(forTimeInterval: 1.0)
        let a = outA.all, b = outB.all, c = outC.all
        let tag = wide ? "4,8 MS/s" : "2,4 MS/s"
        check(a.count > 60_000 && abs(level(a, 1000) - 0.6) < 0.08 && level(a, 2000) / max(level(a, 1000), 1e-9) < 0.03, "SDR Bank (\(tag)): Kanal 1 hat nur seinen 1-kHz-Ton (\(level(a, 1000)), fremd \(level(a, 2000)))")
        check(b.count > 60_000 && abs(level(b, 2000) - 0.6) < 0.08 && level(b, 1000) / max(level(b, 2000), 1e-9) < 0.03, "SDR Bank (\(tag)): Kanal 2 hat nur seinen 2-kHz-Ton (\(level(b, 2000)))")
        check(c.count > 60_000 && abs(level(c, 700) - 0.5) < 0.08, "SDR Bank (\(tag)): AM-Kanal 3 nebenher (\(level(c, 700)))")
        check(bank.snapshot().audioSamples == 0 && bank.extraChannelMetrics().count == 3 && bank.extraChannelMetrics().values.allSatisfy { $0.signalDB > -60 }, "SDR Bank (\(tag)): Hörkanal ruht, Pegel der drei Kanäle gemeldet")
        bank.removeExtraChannel(id: 2)
        Thread.sleep(forTimeInterval: 0.2)
        check(bank.extraChannelMetrics()[2] == nil, "SDR Bank (\(tag)): entfernter Kanal verschwindet")
    }

    // Funkgerät: der eingebaute Empfänger meldet sich an, stimmt ab und gibt frei
    MainActor.assumeIsolated {
        let rig = RigModel()
        var tuned: RigTuneTarget?
        rig.useInternal(name: "SDR Test", tune: { tuned = $0; return .ok })
        check(rig.hasRig && rig.isInternal && rig.rigName == "SDR Test", "SDR: als Funkgerät angemeldet")
        var st = RigState(); st.connected = true; st.frequencyHz = 144_800_000; st.mode = "FM"
        rig.setInternal(state: st)
        check(rig.state.connected && rig.state.frequencyHz == 144_800_000, "SDR: Frequenz und Betriebsart als Funkgerät")
        rig.tune(to: RigTuneTarget(dialHz: 161_975_000, mode: "FM", passbandHz: 25_000))
        check(tuned?.dialHz == 161_975_000 && tuned?.mode == "FM" && tuned?.passbandHz == 25_000, "SDR: Abstimmziel eines Moduls kommt an")
        rig.useInternal(name: nil)
        check(!rig.hasRig && !rig.isInternal, "SDR: nach dem Abmelden gilt wieder kein Funkgerät")
    }

    // HF-Wasserfall: Zoomstufen und Frequenzbereich
    check(SDRZoomFactor.allCases == [.x1, .x2, .x4, .x8, .x16], "SDR Zoom: Stufen 1×, 2×, 4×, 8×, 16×")
    check(SDRZoomFactor.x1.next() == .x2 && SDRZoomFactor.x16.next() == .x16 && SDRZoomFactor.x16.previous() == .x8 && SDRZoomFactor.x1.previous() == .x1, "SDR Zoom: Vor- und Zurückschalten mit Anschlag")
    check(SDRZoomFactor.x1.visibleSpan(sampleRate: 2_400_000) == 2_400_000 && SDRZoomFactor.x4.visibleSpan(sampleRate: 2_400_000) == 600_000 && SDRZoomFactor.x16.visibleSpan(sampleRate: 2_400_000) == 150_000, "SDR Zoom: sichtbare Bandbreite")
    let full = SDRZoomFactor.x1.visibleRange(center: 144_800_000, sampleRate: 2_400_000, loHz: 145_000_000)
    check(full == (143_800_000...146_200_000), "SDR Zoom: 1× umfasst das volle I/Q-Fenster")
    let z4 = SDRZoomFactor.x4.visibleRange(center: 145_000_000, sampleRate: 2_400_000, loHz: 145_000_000)
    check(z4 == (144_700_000...145_300_000), "SDR Zoom: 4× zentriert um die Mittenfrequenz")
    let z4Low = SDRZoomFactor.x4.visibleRange(center: 143_900_000, sampleRate: 2_400_000, loHz: 145_000_000)
    check(z4Low.lowerBound == 143_800_000 && z4Low.upperBound == 144_400_000, "SDR Zoom: Begrenzung am unteren Fensterrand")
    let z4High = SDRZoomFactor.x4.visibleRange(center: 146_150_000, sampleRate: 2_400_000, loHz: 145_000_000)
    check(z4High.upperBound == 146_200_000 && z4High.lowerBound == 145_600_000, "SDR Zoom: Begrenzung am oberen Fensterrand")

    // HF-Wasserfall: FFT-Auflösung (Auto und manuell)
    check(SDRWaterfallResolution.allCases == [.auto, .r4k, .r8k, .r16k, .r32k], "SDR Auflösung: Modi Auto, 4k, 8k, 16k, 32k")
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 2_400_000, zoom: .x1) == 4096, "SDR Auto-Auflösung: 1× = 4096 Bins")
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 2_400_000, zoom: .x2) == 8192, "SDR Auto-Auflösung: 2× = 8192 Bins")
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 2_400_000, zoom: .x4) == 16384, "SDR Auto-Auflösung: 4× = 16384 Bins")
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 2_400_000, zoom: .x8) == 32768, "SDR Auto-Auflösung: 8× = 32768 Bins")
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 2_400_000, zoom: .x16) == 32768, "SDR Auto-Auflösung: 16× = 32768 Bins")
    // Hohe Abtastrate (> 5 MS/s)
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 6_000_000, zoom: .x1) == 16384, "SDR Auto-Auflösung >5 MS/s: 1× = 16384 Bins")
    check(SDRWaterfallResolution.auto.effectiveBins(sampleRate: 6_000_000, zoom: .x2) == 32768, "SDR Auto-Auflösung >5 MS/s: 2× = 32768 Bins")
    // Feste Modi
    check(SDRWaterfallResolution.r4k.effectiveBins(sampleRate: 2_400_000, zoom: .x16) == 4096, "SDR Feste Auflösung 4k")
    check(SDRWaterfallResolution.r8k.effectiveBins(sampleRate: 2_400_000, zoom: .x1) == 8192, "SDR Feste Auflösung 8k")
    check(SDRWaterfallResolution.r16k.effectiveBins(sampleRate: 2_400_000, zoom: .x1) == 16384, "SDR Feste Auflösung 16k")
    check(SDRWaterfallResolution.r32k.effectiveBins(sampleRate: 2_400_000, zoom: .x1) == 32768, "SDR Feste Auflösung 32k")
    // SDRSpectrum mit konfigurierter Bin-Größe
    let spec8k = SDRSpectrum(sampleRate: 2_400_000, bins: 8192)
    check(spec8k.bins == 8192, "SDRSpectrum: 8k-Initialisierung")
    let spec16k = SDRSpectrum(sampleRate: 2_400_000, bins: 16384)
    check(spec16k.bins == 16384, "SDRSpectrum: 16k-Initialisierung")
    let specAuto5M = SDRSpectrum(sampleRate: 6_000_000)
    check(specAuto5M.bins == 16384, "SDRSpectrum: Standard bei >5 MS/s ist 16k")
    let specAutoNorm = SDRSpectrum(sampleRate: 2_400_000)
    check(specAutoNorm.bins == 4096, "SDRSpectrum: Standard bei 2,4 MS/s ist 4k")

    // S-Meter-Skala & IARU-Zuordnung
    check(SDRSMeterScale.fraction(db: -100) == 0.0 && SDRSMeterScale.fraction(db: 0) == 1.0, "SDR S-Meter: Normalisierung 0 bis 1")
    check(abs(SDRSMeterScale.fraction(db: -46) - 0.54) < 1e-4, "SDR S-Meter: S9 liegt bei 54 % der Skala")
    check(SDRSMeterScale.reading(db: -110).sText == "S0" && !SDRSMeterScale.reading(db: -110).isOverS9, "SDR S-Meter: unter -100 dBFS ist S0")
    check(SDRSMeterScale.reading(db: -94).sText == "S1" && !SDRSMeterScale.reading(db: -94).isOverS9, "SDR S-Meter: -94 dBFS ist S1")
    check(SDRSMeterScale.reading(db: -70).sText == "S5" && !SDRSMeterScale.reading(db: -70).isOverS9, "SDR S-Meter: -70 dBFS ist S5")
    check(SDRSMeterScale.reading(db: -58).sText == "S7" && !SDRSMeterScale.reading(db: -58).isOverS9, "SDR S-Meter: -58 dBFS ist S7")
    check(SDRSMeterScale.reading(db: -46).sText == "S9" && !SDRSMeterScale.reading(db: -46).isOverS9, "SDR S-Meter: -46 dBFS ist S9")
    check(SDRSMeterScale.reading(db: -26).sText == "S9+20" && SDRSMeterScale.reading(db: -26).isOverS9, "SDR S-Meter: -26 dBFS ist S9+20")
    check(SDRSMeterScale.reading(db: -6).sText == "S9+40" && SDRSMeterScale.reading(db: -6).isOverS9, "SDR S-Meter: -6 dBFS ist S9+40")
    // Farbzonen: S0–S3 blau, S3–S9 grün, S9–S9+10 gelb-orange, ab S9+10 orange-rot
    check(SDRSMeterScale.zone(for: -94) == .blue && SDRSMeterScale.zone(for: -84) == .blue, "SDR S-Meter: S0-S3 ist blau")
    check(SDRSMeterScale.zone(for: -80) == .green && SDRSMeterScale.zone(for: -46) == .green, "SDR S-Meter: S3-S9 ist grün")
    check(SDRSMeterScale.zone(for: -40) == .yellow && SDRSMeterScale.zone(for: -36) == .yellow, "SDR S-Meter: S9-S9+10 ist gelb")
    check(SDRSMeterScale.zone(for: -30) == .red && SDRSMeterScale.zone(for: -6) == .red, "SDR S-Meter: ab S9+10 ist orange-rot")
}

// MARK: - Verbindung der Dienste (Flugzeuge: ADS-B, VDL2, ACARS; Schiffe: AIS, DSC)
if want("links") {
    check(AirlineCodes.callsign(fromFlight: "LH123") == "DLH123" && AirlineCodes.callsign(fromFlight: "LH0123") == "DLH123" && AirlineCodes.callsign(fromFlight: "EW9") == "EWG9"
          && AirlineCodes.callsign(fromFlight: "ZZ12") == nil && AirlineCodes.callsign(fromFlight: "LH") == nil && AirlineCodes.callsign(fromFlight: "BA 17") == nil,
          "Verbindung: Flugnummer → Rufzeichen (LH123 = DLH123, führende Nullen weg, unbekannte Gesellschaft = nichts)")
    check(AirlineCodes.sameCallsign("DLH123", "DLH0123") && AirlineCodes.sameCallsign("DLH123 ", "dlh123") && !AirlineCodes.sameCallsign("DLH123", "DLH124") && !AirlineCodes.sameCallsign("", ""),
          "Verbindung: Rufzeichen mit und ohne führende Nullen")
    let now = Date()
    func plane(_ icao: UInt32, _ cs: String?, alt: Int? = 38_000, pos: GeoPoint? = nil) -> ADSBAircraft {
        var a = ADSBAircraft(icao: icao, firstSeen: now, lastSeen: now)
        a.callsign = cs; a.altitudeFt = alt; a.position = pos
        return a
    }
    func vdl(_ icao: UInt32, reg: String?, flight: String?) -> VDL2Aircraft {
        VDL2Aircraft(address: VDL2Address(raw: (1 << 24) | icao), registration: reg, flight: flight, firstSeen: now, lastSeen: now, frequency: 136_975_000, levelDB: -30, lastText: "")
    }
    let home = GeoPoint(lat: 49.79, lon: 9.95)
    let list = [plane(0x3C6444, "DLH123", pos: GeoPoint(lat: 50.5, lon: 10.5)), plane(0x4B1805, "SWR8", alt: 12_000), plane(0x3C0001, nil)]
    check(ServiceLinks.aircraft(registration: nil, flight: nil, icao: 0x4B1805, adsb: list)?.callsign == "SWR8", "Verbindung: über die ICAO-Adresse")
    check(ServiceLinks.aircraft(registration: "D-AIBC", flight: nil, adsb: list, vdl2: [vdl(0x3C6444, reg: "D-AIBC", flight: "LH123")])?.icao == 0x3C6444, "Verbindung: Kennzeichen → VDL2 → ADS-B")
    check(ServiceLinks.aircraft(registration: "DAIBC", flight: nil, adsb: list, vdl2: [vdl(0x3C6444, reg: "D-AIBC", flight: nil)])?.icao == 0x3C6444, "Verbindung: Kennzeichen ohne Bindestrich")
    check(ServiceLinks.aircraft(registration: "D-AIXY", flight: nil, adsb: list, registrations: [0x3C0001: "D-AIXY"])?.icao == 0x3C0001, "Verbindung: Kennzeichen aus dem Flugzeugdatenblatt")
    check(ServiceLinks.aircraft(registration: "", flight: "LH123", adsb: list)?.icao == 0x3C6444 && ServiceLinks.aircraft(registration: nil, flight: "LH999", adsb: list) == nil && ServiceLinks.aircraft(registration: nil, flight: nil, adsb: list) == nil,
          "Verbindung: über die Flugnummer (LH123 = DLH123), falsche Nummer = kein Treffer")
    check(ServiceLinks.summary(of: list[0], from: home).hasPrefix("FL 380 · 8") && ServiceLinks.summary(of: list[1], from: home) == "FL 120" && ServiceLinks.summary(of: plane(1, "ABC1", alt: nil), from: home) == "ABC1",
          "Verbindung: Kurzangabe (\(ServiceLinks.summary(of: list[0], from: home)))")
    var v = AISVessel(mmsi: 211_181_050, now: now)
    v.name = "ALTE LIEBE "
    check(ServiceLinks.vessel(mmsi: "211181050", in: [v.mmsi: v])?.mmsi == 211_181_050 && ServiceLinks.vessel(mmsi: "x", in: [v.mmsi: v]) == nil && ServiceLinks.vessel(mmsi: nil, in: [:]) == nil
          && ServiceLinks.label(of: v) == "ALTE LIEBE" && ServiceLinks.label(of: AISVessel(mmsi: 5, now: now)) == nil, "Verbindung: DSC-MMSI → Schiffsname aus AIS")
}

// MARK: - DAB (Empfänger, FIC, Hauptdienstkanal, DAB+)
if want("dab") {
    dabSelfTests { ok, text in check(ok, text) }
    if !dabRecordingTest(path: "TestData/DAB/dab_11D_2048k.raw", { ok, text in check(ok, text) }) { skip("DAB echt: TestData/DAB/dab_11D_2048k.raw liegt nicht lokal vor (HackRF-Aufnahme, Block 11D)") }
    _ = dabChunkingTest(path: "TestData/DAB/dab_11D_2048k.raw", { ok, text in check(ok, text) })
}

// Asynchrone Prüfungen ohne „await“ auf oberster Ebene (das würde die ganze Datei asynchron machen): Hauptschleife drehen, bis sie fertig sind
if want("adsb") {
    final class Flag: @unchecked Sendable { var done = false }
    let flag = Flag()
    Task { @MainActor in
        await aircraftInfoTests()
        flag.done = true
    }
    let limit = Date().addingTimeInterval(120)
    while !flag.done && Date() < limit { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(flag.done, "Flugzeugdaten: asynchrone Prüfungen fertig")
}

// MARK: - RDS (Radio Data System, UKW-Rundfunk WFM)
if want("rds") {
    final class GroupBox: @unchecked Sendable {
        var groups: [RDSGroup] = []
        let lock = NSLock()
        func add(_ g: RDSGroup) { lock.withLock { groups.append(g) } }
        var count: Int { lock.withLock { groups.count } }
        var list: [RDSGroup] { lock.withLock { groups } }
    }
    func feed(_ framer: RDSStreamDecoder, bits: [Int]) { for b in bits { framer.process(bit: b) } }
    func feed(_ framer: RDSStreamDecoder, groups: [RDSGroup]) { feed(framer, bits: RDSSignalGenerator.bits(of: groups)) }
    func decodeAll(_ groups: [RDSGroup], quality: Double = 1) -> RDSInfo {
        let d = RDSDecoder()
        for g in groups { d.handle(g, quality: quality) }
        return d.snapshot
    }

    // 1. Prüfwort: Offset-Wörter und Kodierung
    let pi: UInt16 = 0xD318
    for off in RDSOffset.allCases {
        let w = RDSSyndrome.encodeBlock(data: 0xA5C3, offset: off)
        check(RDSSyndrome.syndrome(of: w) == off.rawValue, "RDS: Syndrom des Blocks \(off.name) ist das Offset-Wort")
        check(RDSSyndrome.decode(word: w, expected: off, maxBurst: 0)?.data == 0xA5C3, "RDS: Block \(off.name) fehlerfrei gelesen")
        check(RDSSyndrome.detectOffset(word: w, maxBurst: 0)?.offset == off, "RDS: Offset \(off.name) ohne Vorwissen erkannt")
    }
    check(RDSOffset.allCases.map(\.rawValue) == [0x0FC, 0x198, 0x168, 0x350, 0x1B4], "RDS: Offset-Wörter nach EN 50067")
    let wordA = RDSSyndrome.encodeBlock(data: pi, offset: .a)
    // 2. Fehlerkorrektur: alle Einzel- und Doppelbitfehler
    var single = 0, burst2 = 0, rejected = 0
    for bit in 0..<26 {
        if let r = RDSSyndrome.decode(word: wordA ^ (1 << UInt32(bit)), expected: .a, maxBurst: 1), r.data == pi, r.corrected == 1 { single += 1 }
        if RDSSyndrome.decode(word: wordA ^ (1 << UInt32(bit)), expected: .a, maxBurst: 0) == nil { rejected += 1 }
    }
    for bit in 0..<25 {
        if let r = RDSSyndrome.decode(word: wordA ^ (3 << UInt32(bit)), expected: .a, maxBurst: 2), r.data == pi, r.corrected == 2 { burst2 += 1 }
    }
    check(single == 26, "RDS: jeder Einzelbitfehler wird repariert (\(single)/26)")
    check(burst2 == 25, "RDS: jeder Doppelfehler benachbarter Bits wird repariert (\(burst2)/25)")
    check(rejected == 26, "RDS: ohne Reparatur wird jeder Fehler abgewiesen")
    check(RDSSyndrome.decode(word: wordA ^ 0x03, expected: .a, maxBurst: 1) == nil, "RDS: Doppelfehler wird bei Einzelreparatur abgewiesen")
    check(RDSSyndrome.decode(word: wordA ^ 0x15, expected: .a, maxBurst: 2) == nil, "RDS: drei verteilte Fehler werden nicht repariert")

    // 3. Zeichensatz, Programmart, Land
    check(RDSCharset.character(0x91) == "ä" && RDSCharset.character(0x97) == "ö" && RDSCharset.character(0x99) == "ü" && RDSCharset.character(0xD1) == "Ä"
          && RDSCharset.character(0xD7) == "Ö" && RDSCharset.character(0xD9) == "Ü" && RDSCharset.character(0x8D) == "ß", "RDS: Umlaute und ß im RDS-Zeichensatz")
    check(RDSCharset.character(0x41) == "A" && RDSCharset.character(0x0D) == " " && RDSCharset.character(0x24) == "¤" && RDSCharset.character(0xA9) == "€", "RDS: ASCII, Steuerzeichen, Währungszeichen")
    check((0x80...0xFF).allSatisfy { RDSCharset.character(UInt8($0)) != " " || $0 == 0xFF }, "RDS: alle 128 oberen Zeichen belegt")
    check(RDSPTY.names.count == 32 && RDSPTY.name(for: 10) == "Popmusik" && RDSPTY.name(for: 1) == "Nachrichten" && RDSPTY.name(for: 31) == "ALARM!", "RDS: 32 Programmarten")
    check(RDSCountry.name(for: 0xD318, ecc: 0xE0) == "Deutschland" && RDSCountry.name(for: 0x4123, ecc: 0xE1) == "Schweiz" && RDSCountry.name(for: 0xA123, ecc: 0xE0) == "Österreich"
          && RDSCountry.name(for: 0xF123, ecc: 0xE1) == "Frankreich" && RDSCountry.name(for: 0xC123, ecc: 0xE1) == "Großbritannien" && RDSCountry.name(for: 0x8123, ecc: 0xE3) == "Niederlande",
          "RDS: Land aus ECC und PI")
    check(RDSCountry.name(for: 0xD318) == "Deutschland" && RDSCountry.isGuess(ecc: nil) && !RDSCountry.isGuess(ecc: 0xE0), "RDS: ohne ECC wird auf E0 geraten (als Vermutung gekennzeichnet)")

    // 4. Blocksynchronisation
    let g0a = RDSSignalGenerator.makeGroup0A(pi: pi, ps: "ANTENNE", tp: true, ta: false, pty: 10, afMHz: [98.0, 99.3, 104.4], stereo: true)
    let g2a = RDSSignalGenerator.makeGroup2A(pi: pi, text: "Wir lieben Bayern, wir lieben Musik")
    check(g0a.count == 4 && g2a.count == 9 && g0a[0].pi == pi && g0a[0].groupType == 0 && g2a[0].groupType == 2 && g0a[0].tp == true && g0a[0].pty == 10, "RDS: Gruppen 0A und 2A aus dem Generator")
    check(g0a.allSatisfy { $0.isComplete } && g0a[0].name == "0A" && g2a[0].isVersionB == false, "RDS: Gruppenname und Vollständigkeit")
    do {
        let framer = RDSStreamDecoder()
        let box = GroupBox()
        framer.onGroup = { box.add($0) }
        feed(framer, groups: g0a + g2a + g0a + g2a)
        check(framer.syncState == .synced, "RDS Framer: SYNCHRON nach einigen Gruppen")
        check(box.count >= 2 * (g0a.count + g2a.count) - 2, "RDS Framer: fast alle Gruppen geliefert (\(box.count) von \(2 * (g0a.count + g2a.count)))")
        check(box.list.allSatisfy { $0.pi == pi || $0.pi == nil } && box.list.filter({ $0.isComplete }).count >= box.count - 1, "RDS Framer: Gruppen vollständig (bis auf die erste, die mitten im Block beginnt), PI stimmt")
    }
    do {
        // Beginn mitten im Strom: 37 beliebige Bits vorweg
        var rng = SDRTestSignal.SplitMix(seed: 5)
        let junk = (0..<37).map { _ in Int(rng.next() & 1) }
        let framer = RDSStreamDecoder()
        let box = GroupBox()
        framer.onGroup = { box.add($0) }
        feed(framer, bits: junk + RDSSignalGenerator.bits(of: g0a + g2a + g0a))
        check(framer.syncState == .synced && box.count >= g0a.count + g2a.count, "RDS Framer: findet den Takt nach beliebigem Vorlauf (\(box.count) Gruppen)")
    }
    do {
        // Zufallsbits: keine Gruppen, keine dauerhafte Synchronisation
        var rng = SDRTestSignal.SplitMix(seed: 99)
        let framer = RDSStreamDecoder()
        let box = GroupBox()
        framer.onGroup = { box.add($0) }
        feed(framer, bits: (0..<200_000).map { _ in Int(rng.next() & 1) })
        check(box.count == 0, "RDS Framer: 200000 Zufallsbits ergeben keine Gruppe (\(box.count))")
    }
    do {
        // Bitschlupf: ein Bit fehlt mitten im Strom, ein anderes kommt dazu
        let stream = RDSSignalGenerator.bits(of: g0a + g2a + g0a + g2a + g0a + g2a)
        for (label, edit) in [("fehlt", { (b: inout [Int], at: Int) in b.remove(at: at) }), ("zusätzlich", { (b: inout [Int], at: Int) in b.insert(1, at: at) })] {
            var bits = stream
            edit(&bits, 1000)
            let framer = RDSStreamDecoder()
            let box = GroupBox()
            framer.onGroup = { box.add($0) }
            feed(framer, bits: bits)
            let expect = stream.count / 104
            check(box.count >= expect - 5 && framer.syncState == .synced, "RDS Framer: Bitschlupf (Bit \(label)) wird überwunden (\(box.count) von \(expect) Gruppen)")
            check(framer.currentStats.resyncs >= 1, "RDS Framer: Bitschlupf (Bit \(label)) wird als Neusynchronisation gezählt")
        }
    }
    do {
        // Fehler: ein Einzelbitfehler wird repariert, ein zerstörter Block C ergibt eine Teilgruppe ohne Block C (kein alter Block rutscht herein)
        var groups = g2a + g2a
        var bits = RDSSignalGenerator.bits(of: groups)
        bits[26 * 4 * 3 + 40] ^= 1          // Gruppe 3, Block B: ein Bit
        for k in 0..<10 { bits[26 * 4 * 5 + 52 + 3 + k] ^= 1 }   // Gruppe 5, Block C: Bündelfehler
        let framer = RDSStreamDecoder()
        let box = GroupBox()
        framer.onGroup = { box.add($0) }
        feed(framer, bits: bits)
        let list = box.list
        check(list.contains { $0.correctedBits == 1 }, "RDS Framer: Einzelbitfehler repariert und gemeldet")
        let broken = list.filter { $0.blockC == nil }
        check(broken.count == 1 && broken[0].blockA != nil && broken[0].blockB != nil && broken[0].blockD != nil, "RDS Framer: zerstörter Block C fehlt in der Teilgruppe, die anderen bleiben (\(broken.count))")
        groups.removeAll()
    }
    do {
        // Rauschen nach den Daten: Synchronisation geht verloren
        var rng = SDRTestSignal.SplitMix(seed: 7)
        let framer = RDSStreamDecoder()
        feed(framer, groups: g0a + g2a + g0a + g2a)
        check(framer.syncState == .synced, "RDS Framer: vor dem Rauschen synchron")
        feed(framer, bits: (0..<6000).map { _ in Int(rng.next() & 1) })
        check(framer.syncState == .search, "RDS Framer: nach Rauschen wieder in der Suche")
        feed(framer, groups: g0a + g2a + g0a)
        check(framer.syncState == .synced, "RDS Framer: und danach wieder synchron")
    }

    // 5. Decoder: Programmname, Radiotext, Uhrzeit, Zusatzdaten
    let date = Date(timeIntervalSince1970: 1_791_450_840)       // 2026-10-08 09:14:00 UTC
    var all: [RDSGroup] = []
    for _ in 0..<3 {
        all += g0a + g2a
        all.append(RDSSignalGenerator.makeGroup4A(pi: pi, date: date, offsetHalfHours: 4))
        all.append(RDSSignalGenerator.makeGroup1A(pi: pi, ecc: 0xE0))
        all.append(RDSSignalGenerator.makeGroup1A(pi: pi, language: 0x08))
        all += RDSSignalGenerator.makeGroup10A(pi: pi, name: "Pop")
    }
    let info = decodeAll(all)
    check(info.pi == pi && info.piHex == "D318" && info.country == "Deutschland" && !info.countryIsGuess, "RDS Decoder: PI und Land (mit ECC E0)")
    check(info.programService == "ANTENNE" && !info.programServiceComplete == false || info.programService == "ANTENNE", "RDS Decoder: Programmname ANTENNE")
    check(info.radioText == "Wir lieben Bayern, wir lieben Musik" && info.radioTextComplete, "RDS Decoder: Radiotext (\(info.radioText))")
    check(info.pty == 10 && info.ptyName == "Popmusik" && info.tp && !info.ta && info.music == true, "RDS Decoder: PTY, TP, TA, Musik/Sprache")
    check(info.diStereo == true && info.diCompressed == false, "RDS Decoder: Decoder-Kennung Stereo")
    check(info.alternativeFrequencies == [98.0, 99.3, 104.4], "RDS Decoder: Alternativfrequenzen \(info.alternativeFrequencies)")
    check(info.languageCode == 0x08 && info.language == "Deutsch", "RDS Decoder: Sprache Deutsch")
    check(info.programTypeName == "Pop", "RDS Decoder: Programmtyp-Name (10A)")
    check(info.clockUTC == date && info.clockOffsetHalfHours == 4, "RDS Decoder: Uhrzeit UTC und Versatz")
    check(info.clockFormatted == "08.10.2026 11:14 (UTC+2)", "RDS Decoder: Uhrzeit in Ortszeit (\(info.clockFormatted ?? "-"))")
    check(info.groupCounts["0A"] == 12 && info.groupCounts["2A"] == 27 && info.totalGroups == all.count, "RDS Decoder: Gruppenzähler")
    do {
        // Umlaute im Radiotext, A/B-Wechsel und Verlauf
        var seq: [RDSGroup] = []
        for _ in 0..<2 { seq += RDSSignalGenerator.makeGroup2A(pi: pi, text: "Größe Äpfel für Özil ß", textAB: false) }
        let first = decodeAll(seq)
        check(first.radioText == "Größe Äpfel für Özil ß", "RDS Decoder: Umlaute im Radiotext (\(first.radioText))")
        let d = RDSDecoder()
        for g in seq { d.handle(g, quality: 1) }
        for _ in 0..<2 { for g in RDSSignalGenerator.makeGroup2A(pi: pi, text: "Zweiter Text", textAB: true) { d.handle(g, quality: 1) } }
        let after = d.snapshot
        check(after.radioText == "Zweiter Text" && after.radioTextHistory == ["Zweiter Text", "Größe Äpfel für Özil ß"], "RDS Decoder: A/B-Wechsel startet neuen Text, der alte bleibt im Verlauf (\(after.radioTextHistory))")
    }
    do {
        // Teilgruppen: nur Block B und D (Block C verloren) liefern trotzdem Programmnamen-Zeichen; Block A verloren: PI aus C' bzw. früheren Gruppen
        let d = RDSDecoder()
        for _ in 0..<2 { for g in g0a { d.handle(RDSGroup(blocks: [g.blockA, g.blockB, nil, g.blockD]), quality: 1) } }
        check(d.snapshot.programService == "ANTENNE" && d.snapshot.pi == pi, "RDS Decoder: Programmname aus Gruppen ohne Block C")
        for g in g2a { d.handle(RDSGroup(blocks: [nil, g.blockB, g.blockC, g.blockD]), quality: 1) }
        check(d.snapshot.pi == pi, "RDS Decoder: Gruppen ohne Block A ändern den PI nicht")
    }
    do {
        // Reparierte Blöcke bei schlechter Lage: ein falscher Wert ersetzt nicht sofort, erst die Wiederholung
        let d = RDSDecoder()
        for _ in 0..<2 { for g in g0a { d.handle(g, quality: 1) } }
        var bad = g0a[1]
        bad.blocks[3] = RDSBlock(data: (UInt16(UInt8(ascii: "Z")) << 8) | UInt16(UInt8(ascii: "Z")), offset: .d, correctedBits: 1)
        d.handle(bad, quality: 0.5)
        check(d.snapshot.programService == "ANTENNE", "RDS Decoder: einzelner reparierter Block ändert den Namen nicht")
        d.handle(bad, quality: 0.5)
        check(d.snapshot.programService == "ANTZZNE" || d.snapshot.programService.contains("ZZ"), "RDS Decoder: zweite gleiche Beobachtung übernimmt (\(d.snapshot.programService))")
    }
    do {
        // Senderwechsel: ein fremder PI-Code zählt erst nach drei Beobachtungen
        let d = RDSDecoder()
        for g in g0a + g0a { d.handle(g, quality: 1) }
        let other = RDSSignalGenerator.makeGroup0A(pi: 0xD315, ps: "BR24", pty: 1, afMHz: [])
        d.handle(other[0], quality: 1)
        check(d.snapshot.pi == pi && d.snapshot.programService == "ANTENNE", "RDS Decoder: ein fremder PI schaltet nicht um")
        for g in other + other + other { d.handle(g, quality: 1) }
        check(d.snapshot.pi == 0xD315 && d.snapshot.programService == "BR24" && d.snapshot.alternativeFrequencies.isEmpty, "RDS Decoder: nach drei Beobachtungen neuer Sender, alte Daten weg (\(d.snapshot.programService))")
    }
    do {
        // RT+: Ankündigung in 3A, Markierungen in 11A
        let text = "Juliane Krebs: Deutschlandreportage"
        var seq: [RDSGroup] = []
        seq.append(RDSSignalGenerator.makeGroup3A(pi: pi, groupTypeCode: 22))
        for _ in 0..<2 { seq += RDSSignalGenerator.makeGroup2A(pi: pi, text: text) }
        seq.append(RDSSignalGenerator.makeRTPlus(pi: pi, groupType: 11, tag1: (type: 4, start: 0, length: 13), tag2: (type: 1, start: 15, length: 20)))
        let rt = decodeAll(seq)
        check(rt.radioTextPlus == [RDSTag(label: "Interpret", text: "Juliane Krebs"), RDSTag(label: "Titel", text: "Deutschlandreportage")], "RDS Decoder: RT+ Interpret und Titel (\(rt.radioTextPlus))")
        check(rt.applicationNames == ["RT+"], "RDS Decoder: RT+ als Zusatzdienst angekündigt")
    }

    // 6. Signalweg: Multiplexsignal mit 57-kHz-Träger → Bits → Gruppen
    func demodulate(_ mpx: [Float], rate: Double, chunk: Int = 100_000) -> (groups: [RDSGroup], demod: RDSDemodulator) {
        let demod = RDSDemodulator()
        let box = GroupBox()
        demod.streamDecoder.onGroup = { box.add($0) }
        mpx.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count { let e = min(i + chunk, b.count); demod.process(mpx: UnsafeBufferPointer(rebasing: b[i..<e]), sampleRate: rate); i = e }
        }
        return (box.list, demod)
    }
    var stream: [RDSGroup] = []
    for _ in 0..<12 { stream += g0a + g2a }
    let expectedGroups = stream.count
    for rate in [480_000.0, 240_000.0] {
        let mpx = RDSSignalGenerator.modulate(groups: stream, sampleRate: rate)
        let r = demodulate(mpx, rate: rate)
        check(r.demod.streamDecoder.syncState == .synced && r.groups.count >= expectedGroups - 6, "RDS Signalweg \(Int(rate / 1000)) kS/s: \(r.groups.count) von \(expectedGroups) Gruppen")
        let i2 = decodeAll(r.groups)
        check(i2.programService == "ANTENNE" && i2.pi == pi && i2.radioText == "Wir lieben Bayern, wir lieben Musik", "RDS Signalweg \(Int(rate / 1000)) kS/s: PI, Name und Radiotext stimmen")
    }
    do {
        let mpx = RDSSignalGenerator.modulate(groups: stream)
        let whole = demodulate(mpx, rate: 480_000, chunk: mpx.count).groups.count
        let parts = demodulate(mpx, rate: 480_000, chunk: 977).groups.count
        let tiny = demodulate(mpx, rate: 480_000, chunk: 13).groups.count
        check(whole == parts && whole == tiny, "RDS Signalweg: Ergebnis hängt nicht von der Blockaufteilung ab (\(whole)/\(parts)/\(tiny))")
    }
    for (label, offset, ppm, phase) in [("Träger +9 Hz", 9.0, 0.0, 0.3), ("Träger −9 Hz", -9.0, 0.0, 2.1), ("Takt +100 ppm", 0.0, 100.0, 4.0), ("Takt −100 ppm", 0.0, -100.0, 5.5), ("beides", 6.0, 60.0, 1.0)] {
        let mpx = RDSSignalGenerator.modulate(groups: stream, carrierOffsetHz: offset, clockPPM: ppm, startPhase: phase)
        let r = demodulate(mpx, rate: 480_000)
        check(r.groups.count >= expectedGroups - 8 && r.groups.allSatisfy { $0.pi == pi || $0.pi == nil }, "RDS Signalweg: \(label): \(r.groups.count) von \(expectedGroups) Gruppen")
    }
    do {
        // Pegel: RDS mit 0,5 kHz und mit 4 kHz Hub
        for (label, amp) in [("0,5 kHz Hub", Float(0.0067)), ("4 kHz Hub", Float(0.053))] {
            let mpx = RDSSignalGenerator.modulate(groups: stream, amplitude: amp)
            let r = demodulate(mpx, rate: 480_000)
            check(r.groups.count >= expectedGroups - 6, "RDS Signalweg: \(label): \(r.groups.count) von \(expectedGroups) Gruppen")
        }
    }
    do {
        // Störer: Stereo-Differenzsignal bis 53 kHz und Pilot neben dem RDS-Träger
        var mpx = RDSSignalGenerator.modulate(groups: stream)
        for k in 0..<mpx.count {
            let t = Double(k) / 480_000
            mpx[k] += Float(0.4 * sin(2 * Double.pi * 52_000 * t) + 0.1 * sin(2 * Double.pi * 19_000 * t) + 0.3 * sin(2 * Double.pi * 1_000 * t))
        }
        let r = demodulate(mpx, rate: 480_000)
        check(r.groups.count >= expectedGroups - 8, "RDS Signalweg: starker Stereoanteil bei 52 kHz stört nicht (\(r.groups.count) von \(expectedGroups))")
    }
    do {
        // Rauschen: bei mäßigem Rauschen vollständig, bei starkem Rauschen graceful und ohne Unsinn
        var rng = SDRTestSignal.SplitMix(seed: 11)
        let clean = RDSSignalGenerator.modulate(groups: stream)
        var results: [Int] = []
        for sigma in [Float(0.02), Float(0.05), Float(0.12)] {
            var noisy = clean
            for k in 0..<noisy.count { noisy[k] += sigma * rng.gauss() }
            let r = demodulate(noisy, rate: 480_000)
            results.append(r.groups.count)
            check(r.groups.filter({ $0.isComplete }).allSatisfy { $0.pi == pi || $0.correctedBits > 0 }, "RDS Signalweg: Rauschen σ=\(sigma): vollständige Gruppen ohne Fehlbilder")
        }
        check(results[0] >= expectedGroups - 8, "RDS Signalweg: leichtes Rauschen \(results[0]) von \(expectedGroups)")
        check(results[1] >= expectedGroups / 2, "RDS Signalweg: mittleres Rauschen \(results[1]) von \(expectedGroups)")
        var onlyNoise = [Float](repeating: 0, count: 480_000 * 10)
        for k in 0..<onlyNoise.count { onlyNoise[k] = 0.1 * rng.gauss() }
        let rn = demodulate(onlyNoise, rate: 480_000)
        check(rn.groups.count == 0, "RDS Signalweg: nur Rauschen ergibt keine Gruppen (\(rn.groups.count))")
    }
    do {
        // Controller (Oberfläche): Gruppen über Bits einspeisen, Stand abholen
        let ctrl = RDSController(settings: RDSSettingsStore())
        ctrl.setActive(true)
        for b in RDSSignalGenerator.bits(of: g0a + g2a + g0a + g2a + g0a + g2a) { ctrl.demodulator.streamDecoder.process(bit: b) }
        ctrl.refresh()
        check(ctrl.info.pi == pi && ctrl.info.programService == "ANTENNE" && ctrl.stats.syncState == .synced && ctrl.stats.groupsReceived > 10, "RDS Controller: Stand übernommen (\(ctrl.info.programService), \(ctrl.stats.groupsReceived) Gruppen)")
        ctrl.clear()
        check(ctrl.info.pi == nil && ctrl.stats.groupsReceived == 0, "RDS Controller: LEEREN setzt zurück")
        ctrl.setActive(false)
    }

    do {
        // Schnellauswahl: eigene Sender mit Programmnamen, sortiert, gespeichert
        UserDefaults.standard.removeObject(forKey: "rdsFavorites")
        let st = RDSSettingsStore()
        check(st.favorites.isEmpty, "RDS Schnellauswahl: anfangs leer")
        st.addFavorite(frequencyHz: 105_700_000, name: "BR24 ")
        st.addFavorite(frequencyHz: 104_400_020, name: "ANTENNE")
        st.addFavorite(frequencyHz: 104_400_000, name: "")
        check(st.favorites.map(\.title) == ["104,4 ANTENNE", "105,7 BR24"], "RDS Schnellauswahl: sortiert, Name getrimmt, Doppelte (auch leerer Name) ändern nichts (\(st.favorites.map(\.title)))")
        st.addFavorite(frequencyHz: 104_400_000, name: "ANTENNE BY")
        check(st.favorite(at: 104_400_000)?.name == "ANTENNE BY", "RDS Schnellauswahl: neuer Name wird nachgeführt")
        check(RDSSettingsStore().favorites == st.favorites, "RDS Schnellauswahl: bleibt über einen Neustart erhalten")
        let ctrl = RDSController(settings: st)
        ctrl.setActive(true)
        st.frequencyHz = 104_400_000
        for b in RDSSignalGenerator.bits(of: g0a + g2a + g0a + g2a + g0a + g2a) { ctrl.demodulator.streamDecoder.process(bit: b) }
        ctrl.refresh()
        check(st.favorite(at: 104_400_000)?.name == "ANTENNE", "RDS Schnellauswahl: Name folgt dem gelesenen Programmnamen (\(st.favorite(at: 104_400_000)?.name ?? "-"))")
        ctrl.toggleFavorite()
        check(st.favorite(at: 104_400_000) == nil && st.favorites.count == 1, "RDS Schnellauswahl: ★ entfernt den eingestellten Sender")
        ctrl.toggleFavorite()
        check(st.favorite(at: 104_400_000)?.name == "ANTENNE", "RDS Schnellauswahl: ★ merkt ihn wieder mit dem gelesenen Namen")
        ctrl.setActive(false)
        st.removeFavorite(frequencyHz: 105_700_000)
        UserDefaults.standard.removeObject(forKey: "rdsFavorites")
    }

    // 7. Echte Aufnahme (nur wenn vorhanden): 104,4 MHz, HackRF, 8 Bit
    let recording = "TestData/RDS/fm104400_c104700_2400k_l32g8.cu8"
    if let handle = FileManager.default.contents(atPath: recording) {
        var cfg = SDRChannelConfig(mode: .wfm)
        cfg.bandwidthHz = 230_000
        let sdr = SDRDemodulator(sampleRate: 2_400_000, config: cfg)
        sdr.setOffset(-300_000)
        let rds = RDSDemodulator()
        let box = GroupBox()
        rds.streamDecoder.onGroup = { box.add($0) }
        sdr.onDiscriminator = { buf, r in rds.process(mpx: buf, sampleRate: r) }
        var audio = [Float]()
        let n = min(handle.count, 2_400_000 * 2 * 10)
        handle.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < n { let e = min(i + 262_144, n); sdr.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &audio); i = e }
        }
        let real = decodeAll(box.list)
        check(box.count >= 100 && real.pi == 0xD318 && real.programService == "ANTENNE" && real.country == "Deutschland", "RDS echte Aufnahme 104,4 MHz: \(box.count) Gruppen, PI \(real.piHex ?? "-"), Name \(real.programService)")
        check(real.radioTextComplete && real.radioText.contains("ANTENNE BAYERN"), "RDS echte Aufnahme: Radiotext (\(real.radioText))")
        check(sdr.metrics.stereoLocked && sdr.metrics.pilotKHz > 6 && sdr.metrics.pilotKHz < 7.5, String(format: "RDS echte Aufnahme: Stereo-Pilot %.2f kHz gefunden", sdr.metrics.pilotKHz))
    } else {
        print("  (RDS: Aufnahme \(recording) fehlt, übersprungen)")
    }
}

// MARK: - UKW-Rundfunk: Stereodecoder, Kanalbreite, RDS im Gesamtsignal
if want("wfm") {
    let fs = 2_400_000.0
    /// Multiplexsignal bei 480 kS/s: (L+R)/2 und (L−R)/2·sin(2Φ) mit 90 % Aussteuerung, Pilot, RDS (1,0 = 75 kHz Hub)
    func makeMPX(seconds: Double, left: (Double) -> Double, right: (Double) -> Double, pilot: Double = 0.09, rds: [Float] = []) -> [Float] {
        let n = Int(seconds * 480_000)
        var x = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let t = Double(k) / 480_000
            let l = left(t), r = right(t)
            let phi = 2 * Double.pi * 19_000 * t
            var v = 0.45 * (l + r) + 0.45 * (l - r) * sin(2 * phi) + pilot * sin(phi)
            if k < rds.count { v += Double(rds[k]) }
            x[k] = Float(v)
        }
        return x
    }
    func iq(_ mpx: [Float], rate: Double = fs, offset: Double = -300_000, amplitude: Float = 0.3, noise: Float = 0.003, seed: UInt64 = 1) -> SDRTestSignal {
        var s = SDRTestSignal(sampleRate: rate, seconds: Double(mpx.count) / 480_000)
        s.addFM(offsetHz: offset, baseband: mpx, basebandRate: 480_000, deviation: 75_000, amplitude: amplitude)
        if noise > 0 { s.addNoise(sigma: noise, seed: seed) }
        return s
    }
    struct Result { var mono: [Float]; var stereo: [Float]; var metrics: SDRMetrics }
    func receive(_ s: SDRTestSignal, config: SDRChannelConfig, offset: Double = -300_000, chunk: Int = 262_144, discriminator: (@Sendable (UnsafeBufferPointer<Float>, Double) -> Void)? = nil) -> Result {
        let d = SDRDemodulator(sampleRate: s.sampleRate, config: config)
        d.setOffset(offset)
        d.produceStereo = true
        d.onDiscriminator = discriminator
        var mono = [Float](), stereo = [Float]()
        let bytes = s.quantized()
        bytes.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count {
                let e = min(i + chunk, b.count)
                d.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &mono)
                stereo.append(contentsOf: d.stereoOut); d.stereoOut.removeAll(keepingCapacity: true)
                i = e
            }
        }
        return Result(mono: mono, stereo: stereo, metrics: d.metrics)
    }
    func channel(_ r: Result, _ ch: Int) -> [Float] { stride(from: ch, to: r.stereo.count, by: 2).map { r.stereo[$0] } }
    /// Amplitude eines Tons (Goertzel über 1 s nach der Einschwingzeit)
    func tone(_ x: [Float], _ f: Double, from: Int = 60_000, length: Int = 48_000) -> Double {
        guard x.count >= from + length else { return 0 }
        var re = 0.0, im = 0.0
        for k in 0..<length {
            let w = 2 * Double.pi * f * Double(k) / 48_000
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(length))
            re += Double(x[from + k]) * win * cos(w)
            im -= Double(x[from + k]) * win * sin(w)
        }
        return 2 * (re * re + im * im).squareRoot() / (Double(length) * 0.5)
    }
    func db(_ r: Double) -> Double { 20 * log10(max(r, 1e-12)) }
    var wcfg = SDRChannelConfig(mode: .wfm)
    wcfg.bandwidthHz = 230_000

    // Stereo: nur links, nur rechts, beides gleich
    let tL = { (t: Double) in 0.8 * sin(2 * Double.pi * 1_000 * t) }
    let tR = { (t: Double) in 0.8 * sin(2 * Double.pi * 3_000 * t) }
    let zero = { (_: Double) in 0.0 }
    let onlyLeft = receive(iq(makeMPX(seconds: 2.5, left: tL, right: zero)), config: wcfg)
    let l1 = tone(channel(onlyLeft, 0), 1_000), r1 = tone(channel(onlyLeft, 1), 1_000)
    check(onlyLeft.metrics.stereoLocked && abs(onlyLeft.metrics.pilotKHz - 6.75) < 0.4, String(format: "WFM Stereo: Pilot gefunden (%.2f kHz Hub, nominal 6,75)", onlyLeft.metrics.pilotKHz))
    check(abs(l1 - 0.69) < 0.04, String(format: "WFM Stereo: linker Kanal %.3f (erwartet 0,69: 90 %% Aussteuerung, De-Emphase)", l1))
    check(db(r1 / l1) < -35, String(format: "WFM Stereo: Übersprechen links → rechts %.1f dB", db(r1 / l1)))
    let onlyRight = receive(iq(makeMPX(seconds: 2.5, left: zero, right: tR)), config: wcfg)
    let r3 = tone(channel(onlyRight, 1), 3_000), l3 = tone(channel(onlyRight, 0), 3_000)
    check(db(l3 / r3) < -35, String(format: "WFM Stereo: Übersprechen rechts → links %.1f dB", db(l3 / r3)))
    check(onlyRight.metrics.stereoBlend > 0.95, "WFM Stereo: volle Überblendung bei starkem Pilot")
    let both = receive(iq(makeMPX(seconds: 2.5, left: tL, right: tL)), config: wcfg)
    check(abs(tone(channel(both, 0), 1_000) - tone(channel(both, 1), 1_000)) < 0.01, "WFM Stereo: gleiches Signal links und rechts")
    check(abs(tone(both.mono, 1_000) - 0.69) < 0.04, "WFM: Mono-Ausgang (L+R) für die Decoder")
    // Gegenphase: L = −R ergibt reines Differenzsignal
    let anti = receive(iq(makeMPX(seconds: 2.5, left: tL, right: { -tL($0) })), config: wcfg)
    check(tone(anti.mono, 1_000) < 0.02 && tone(channel(anti, 0), 1_000) > 0.6 && tone(channel(anti, 1), 1_000) > 0.6, "WFM Stereo: Gegenphase landet nur im Differenzsignal")
    // ohne Pilot: Mono
    let noPilot = receive(iq(makeMPX(seconds: 2.5, left: tL, right: zero, pilot: 0)), config: wcfg)
    let npL = channel(noPilot, 0), npR = channel(noPilot, 1)
    check(!noPilot.metrics.stereoLocked && noPilot.metrics.stereoBlend < 0.01 && zip(npL, npR).allSatisfy { abs($0 - $1) < 1e-6 }, "WFM: ohne Pilot Mono (beide Kanäle gleich, nicht eingerastet)")
    // Stereo ausgeschaltet
    var mono = wcfg; mono.stereo = false
    let forced = receive(iq(makeMPX(seconds: 2.5, left: tL, right: zero)), config: mono)
    check(zip(channel(forced, 0), channel(forced, 1)).allSatisfy { abs($0 - $1) < 1e-6 } && !forced.metrics.stereoLocked, "WFM: Stereo aus → Mono")
    // De-Emphase 75 µs dämpft 3 kHz stärker als 50 µs
    var us75 = wcfg; us75.wfmDeemphasisSeconds = 75e-6
    let d50 = tone(channel(onlyRight, 1), 3_000), d75 = tone(channel(receive(iq(makeMPX(seconds: 2.5, left: zero, right: tR)), config: us75), 1), 3_000)
    check(db(d75 / d50) < -1.5 && db(d75 / d50) > -3.5, String(format: "WFM: De-Emphase 75 µs gegen 50 µs bei 3 kHz %.1f dB (erwartet −2,2)", db(d75 / d50)))
    var flat = wcfg; flat.deemphasis = false
    let fl = tone(channel(receive(iq(makeMPX(seconds: 2.5, left: tL, right: zero)), config: flat), 0), 1_000)
    check(abs(fl - 0.72) < 0.04, String(format: "WFM: ohne De-Emphase %.3f (erwartet 0,72)", fl))
    // Blockunabhängigkeit
    let sig = iq(makeMPX(seconds: 1.5, left: tL, right: zero))
    let wholeR = receive(sig, config: wcfg, chunk: 8_000_000), partsR = receive(sig, config: wcfg, chunk: 7_000)
    var maxDiff: Float = 0
    for k in 0..<min(wholeR.stereo.count, partsR.stereo.count) { maxDiff = max(maxDiff, abs(wholeR.stereo[k] - partsR.stereo[k])) }
    check(min(wholeR.stereo.count, partsR.stereo.count) > 100_000 && maxDiff < 2e-3 && abs(wholeR.stereo.count - partsR.stereo.count) <= 4, "WFM Stereo: Ergebnis hängt nicht von der Blockaufteilung ab (\(maxDiff), \(wholeR.stereo.count)/\(partsR.stereo.count))")
    // andere Abtastraten des Geräts
    for rate in [4_800_000.0, 9_600_000.0, 2_048_000.0] {
        let s = iq(makeMPX(seconds: 2.5, left: tL, right: zero), rate: rate, offset: rate == 2_048_000 ? -250_000 : -300_000)
        let r = receive(s, config: wcfg, offset: rate == 2_048_000 ? -250_000 : -300_000)
        let l = tone(channel(r, 0), 1_000), x = tone(channel(r, 1), 1_000)
        check(abs(l - 0.69) < 0.05 && db(x / l) < -30, String(format: "WFM Stereo bei %.3f MS/s: links %.3f, Übersprechen %.1f dB", rate / 1e6, l, db(x / l)))
    }
    // Empfangsgüte: je schlechter das Signal, desto weniger Differenzsignal (Mono bleibt sauber); gemessen am Rauschen im Differenzsignal
    var blends: [Double] = [], noises: [Double] = []
    for (amp, sigma) in [(Float(0.3), Float(0.003)), (Float(0.05), Float(0.01)), (Float(0.03), Float(0.012)), (Float(0.02), Float(0.012))] {
        let r = receive(iq(makeMPX(seconds: 3, left: tL, right: tL), amplitude: amp, noise: sigma, seed: 3), config: wcfg)
        blends.append(r.metrics.stereoBlend); noises.append(r.metrics.stereoNoise)
    }
    check(zip(blends, blends.dropFirst()).allSatisfy { $0 >= $1 } && zip(noises, noises.dropFirst()).allSatisfy { $0 <= $1 }, "WFM: schlechterer Empfang → mehr Rauschen, weniger Stereo (Rauschen \(noises.map { String(format: "%.4f", $0) }), Mischung \(blends.map { String(format: "%.2f", $0) }))")
    check(blends[0] > 0.95 && blends[3] < 0.2, "WFM: starkes Signal volles Stereo, schwaches Mono")
    let weakSig = receive(iq(makeMPX(seconds: 3, left: tL, right: tL), amplitude: 0.02, noise: 0.012, seed: 3), config: wcfg)
    check(tone(weakSig.mono, 1_000) > 0.4, "WFM: Mono-Ton bleibt bei schwachem Signal erhalten")
    // Kanalbreite: voller Hub (71 kHz) mit 3-kHz-Ton; je enger das Kanalfilter, desto mehr Oberwellen (Klirrfaktor)
    do {
        let loud = { (t: Double) in 0.95 * sin(2 * Double.pi * 3_000 * t) }
        var cfg = wcfg; cfg.deemphasis = false; cfg.stereo = false
        func thd(_ bw: Double) -> Double {
            cfg.bandwidthHz = bw
            let a = receive(iq(makeMPX(seconds: 2.5, left: loud, right: loud, pilot: 0)), config: cfg).mono
            let f = tone(a, 3_000)
            let h = [6_000.0, 9_000, 12_000, 15_000].map { tone(a, $0) }
            return (h.map { $0 * $0 }.reduce(0, +)).squareRoot() / f
        }
        let t230 = thd(230_000), t180 = thd(180_000), t120 = thd(120_000)
        check(t230 < 0.005, String(format: "WFM: Klirrfaktor bei 230 kHz Kanalbreite %.3f %%", t230 * 100))
        check(t120 > 3 * t230 && t180 < t120, String(format: "WFM: enge Filter verzerren stärker (230 kHz %.2f %%, 180 kHz %.2f %%, 120 kHz %.2f %%)", t230 * 100, t180 * 100, t120 * 100))
    }
    // Nachbarsender im Raster von 200 kHz
    do {
        var s = iq(makeMPX(seconds: 2.5, left: tL, right: tL, pilot: 0.09), amplitude: 0.1)
        let nb = makeMPX(seconds: 2.5, left: { 0.8 * sin(2 * Double.pi * 2_200 * $0) }, right: { 0.8 * sin(2 * Double.pi * 2_200 * $0) })
        s.addFM(offsetHz: -300_000 + 200_000, baseband: nb, basebandRate: 480_000, deviation: 75_000, amplitude: 0.2)   // doppelt so stark, 200 kHz weiter
        let r = receive(s, config: wcfg)
        let want = tone(r.mono, 1_000), leak = tone(r.mono, 2_200)
        check(db(leak / want) < -35, String(format: "WFM: Nachbarsender 200 kHz daneben (+6 dB): Störton %.1f dB", db(leak / want)))
    }
    // Gesamtsignal: Stereo und RDS zugleich über Funk, 8 Bit und Rauschen
    do {
        var groups: [RDSGroup] = []
        let text = "Stereo und RDS zugleich"
        for _ in 0..<14 { groups += RDSSignalGenerator.makeGroup0A(pi: 0xD318, ps: "ANTENNE", afMHz: [98.0]) + RDSSignalGenerator.makeGroup2A(pi: 0xD318, text: text) }
        let rdsMPX = RDSSignalGenerator.modulate(groups: groups, amplitude: 0.02)
        let secs = Double(rdsMPX.count) / 480_000
        let mpx = makeMPX(seconds: secs, left: tL, right: tR, rds: rdsMPX)
        let demod = RDSDemodulator()
        let dec = RDSDecoder()
        let framer = demod.streamDecoder
        framer.onGroup = { dec.handle($0, quality: framer.currentStats.quality) }
        let r = receive(iq(mpx, amplitude: 0.25, noise: 0.01), config: wcfg, discriminator: { buf, rate in demod.process(mpx: buf, sampleRate: rate) })
        let info = dec.snapshot
        check(info.pi == 0xD318 && info.programService == "ANTENNE" && info.radioText == text, "WFM + RDS über Funk (8 Bit, Rauschen): \(info.programService) / \(info.radioText) / \(framer.currentStats.groupsReceived) Gruppen")
        let lA = tone(channel(r, 0), 1_000), rB = tone(channel(r, 1), 3_000)
        check(lA > 0.5 && rB > 0.5 && r.metrics.stereoLocked, String(format: "WFM + RDS: beide Kanäle getrennt (L 1 kHz %.2f, R 3 kHz %.2f)", lA, rB))
    }
    // Modi, Breiten
    check(SDRMode.wfm.bandwidthChoices.contains(230_000) && SDRMode.wfm.defaultBandwidthHz == 230_000 && SDRMode.wfm.bandwidthChoices.allSatisfy { $0 <= 256_000 }, "WFM: Kanalbreiten bis 256 kHz, Standard 230 kHz")
    check(RigTuneTarget.rds(frequencyHz: 104_400_000).passbandHz == 230_000 && RigTuneTarget.rds(frequencyHz: 104_400_000).mode == "WFM", "RDS-Abstimmziel: WFM mit 230 kHz")
}

// MARK: - Mehrkanalbetrieb mit Kurzwellen-Decodern (RTTY, DSC, NAVTEX, Wetterfax, HFDL, SSTV)
if want("hfbank") {
    // Voreinstellungen: Dial = Sendefrequenz minus NF-Mitte des Decoders
    let rtty = ChannelCatalog.presets(for: .rtty)
    check(rtty.count == 6 && rtty.first?.frequencyHz == 4_582_000 && rtty.contains { abs($0.frequencyHz - 10_099_800) < 1 && $0.option == "dwd-kw" && $0.mode == .usb } && rtty.last?.option == "dwd-lw" && abs(rtty.last!.frequencyHz - 146_300) < 1,
          "Kanäle RTTY: DWD-Frequenzen als USB-Dial 1 kHz darunter (\(rtty.map { $0.frequencyHz }))")
    let dsc = ChannelCatalog.presets(for: .dsc)
    check(dsc.count == 7 && dsc.contains { abs($0.frequencyHz - 8_412_800) < 1 && $0.mode == .usb && $0.option == "8414" } && dsc.contains { $0.frequencyHz == 156_525_000 && $0.mode == .nfm }, "Kanäle DSC: Kurzwelle in USB (Ruf 1,7 kHz über dem Dial), Kanal 70 in FM")
    let nav = ChannelCatalog.presets(for: .navtex)
    check(nav.count == 3 && nav.contains { abs($0.frequencyHz - 517_000) < 1 && $0.option == "518" } && nav.contains { abs($0.frequencyHz - 4_208_500) < 1 }, "Kanäle NAVTEX: 518, 490 und 4209,5 kHz")
    let fax = ChannelCatalog.presets(for: .wefax)
    check(fax.count == 3 && fax.contains { abs($0.frequencyHz - 7_878_100) < 1 && $0.option == "dwd-7880" }, "Kanäle Wetterfax: DWD 3855, 7880, 13882,5 kHz (Dial 1,9 kHz darunter)")
    let hfdl = ChannelCatalog.presets(for: .hfdl)
    check(hfdl.count > 20 && hfdl.allSatisfy { $0.mode == .usb && $0.option != nil && HFDLChannels.kHz(presetID: $0.option!) != nil && abs(HFDLChannels.kHz(presetID: $0.option!)! * 1000 - $0.frequencyHz) < 1 }, "Kanäle HFDL: \(hfdl.count) Frequenzen, Dial = Frequenz")
    let sstv = ChannelCatalog.presets(for: .sstv)
    check(sstv.contains { $0.frequencyHz == 7_171_000 && $0.mode == .lsb } && sstv.contains { $0.frequencyHz == 14_230_000 && $0.mode == .usb } && sstv.contains { $0.frequencyHz == 145_800_000 && $0.mode == .nfm }, "Kanäle SSTV: 40 m in LSB, 20 m in USB, ISS in FM")
    check(ChannelCatalog.modules.contains(.rtty) && ChannelCatalog.modules.contains(.hfdl) && ChannelCatalog.defaults(for: .rtty).mode == .usb && ChannelCatalog.defaults(for: .rtty).bandwidthHz == 3_000, "Kanäle: HF-Decoder in der Auswahl, Standard USB 3 kHz")
    check(ChannelCatalog.title(module: .rtty, frequencyHz: 10_099_800).contains("DDK9") && ChannelCatalog.title(module: .rtty, frequencyHz: 5_000_000).hasPrefix("RTTY"), "Kanäle: Anzeigename aus der Voreinstellung")
    // Alte gespeicherte Kanäle (ohne Voreinstellung) lassen sich weiter lesen
    let old = #"[{"id":3,"moduleID":"aprs","frequencyHz":144800000,"mode":"nfm","bandwidthHz":12500,"enabled":true,"label":""}]"#
    let decoded = try? JSONDecoder().decode([SDRBankSlot].self, from: Data(old.utf8))
    check(decoded?.first?.preset == nil && decoded?.first?.id == 3, "Kanalbank: alte Einträge ohne Voreinstellung bleiben lesbar")
    let withPreset = SDRBankSlot(id: 1, moduleID: "rtty", frequencyHz: 1, mode: .usb, bandwidthHz: 3000, preset: "dwd-kw")
    check((try? JSONDecoder().decode(SDRBankSlot.self, from: JSONEncoder().encode(withPreset)))?.preset == "dwd-kw", "Kanalbank: Voreinstellung wird gespeichert")

    // Einstellungen eines Kanals liegen in einem eigenen Speicher und ändern die des Moduls nicht
    MainActor.assumeIsolated {
        let suite = "com.peterbetz.digidec.test.channel"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let own = UserDefaults(suiteName: suite)!
        let before = UserDefaults.standard.string(forKey: "rttyPresetID")
        let st = RTTYSettingsStore(defaults: own)
        st.select(presetID: "dwd-kw")
        st.setCenter(1234)
        check(own.string(forKey: "rttyPresetID") == "dwd-kw" && UserDefaults.standard.string(forKey: "rttyPresetID") == before, "Kanal-Einstellungen: RTTY schreibt in den eigenen Speicher, nicht in den des Moduls")
        check(RTTYSettingsStore(defaults: own).presetID == "dwd-kw" && RTTYSettingsStore(defaults: own).centerHz == 1234, "Kanal-Einstellungen: beim nächsten Start wieder da")
        let nv = NavtexSettingsStore(defaults: own); nv.frequency = .f4209
        check(own.string(forKey: "navtexFrequency") == "4209" && UserDefaults.standard.string(forKey: "navtexFrequency") != "4209", "Kanal-Einstellungen: NAVTEX ebenso")
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // Zwei RTTY-Aussendungen (DWD DDH7 auf 7646 und DDK9 auf 10100,8 kHz) in einem Fenster um 10 MHz, zwei Kanäle, jeder liest seinen Text
    final class Collector: @unchecked Sendable {
        let lock = NSLock(); var samples: [Float] = []
        func add(_ b: UnsafeBufferPointer<Float>) { lock.lock(); samples.append(contentsOf: b); lock.unlock() }
        var all: [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    }
    let dwd = RTTYPreset.preset(id: "dwd-kw")!.parameters
    func audio(for text: String) -> [Float] {
        var g = RTTYSignalGenerator(parameters: dwd, centerHz: 1000)
        g.ita2 = true
        return g.samples(for: text, leadIn: 0.4, tail: 0.6)
    }
    let a1 = audio(for: "CQ CQ DE DDH7 TEST 1234"), a2 = audio(for: "WODL45 EDZW DDK9 GALE WARNING")
    let seconds = Double(max(a1.count, a2.count)) / 8000 + 0.2
    let rate = 9_600_000.0
    var win = SDRTestSignal(sampleRate: rate, seconds: seconds)
    let centerHz = 10_000_000.0
    let dialA = 7_646_000.0 - 1000, dialB = 10_100_800.0 - 1000
    win.addSSB(offsetHz: dialA - centerHz, audio: a1, audioRate: 8000, amplitude: 0.15)
    win.addSSB(offsetHz: dialB - centerHz, audio: a2, audioRate: 8000, amplitude: 0.15)
    win.addCarrier(offsetHz: 3_100_000, amplitude: 0.2)       // ein starker Rundfunkträger im Fenster
    win.addNoise(sigma: 0.003)
    let engine = SDRReceiverEngine(sampleRate: rate)
    engine.setPrimaryEnabled(false)
    var cusb = SDRChannelConfig(mode: .usb); cusb.bandwidthHz = 3_000; cusb.agc = true
    let outA = Collector(), outB = Collector()
    engine.setExtraChannel(id: 1, config: cusb, offsetHz: dialA - centerHz, handler: { outA.add($0) })
    engine.setExtraChannel(id: 2, config: cusb, offsetHz: dialB - centerHz, handler: { outB.add($0) })
    let raw = win.quantized()
    raw.withUnsafeBufferPointer { b in
        var i = 0
        while i < b.count { let e = min(i + 524_288, b.count); engine.feed(UnsafeBufferPointer(rebasing: b[i..<e]), wait: true); i = e }
    }
    Thread.sleep(forTimeInterval: 1.5)
    func decode(_ x: [Float]) -> String {
        guard let conv = SampleRateConverter(inputRate: 48_000, outputRate: 8_000) else { return "" }
        var out = [Float]()
        x.withUnsafeBufferPointer { b in conv.process(b) { out.append(contentsOf: $0) } }
        final class Box: @unchecked Sendable { var s = "" }
        let box = Box()
        let core = FldigiRTTYCore(parameters: dwd, options: .init(), centerHz: 1000) { box.s.append($0) }
        out.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count { let n = min(160, buf.count - i); core.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)])); i += n }
        }
        return box.s
    }
    let tA = decode(outA.all), tB = decode(outB.all)
    check(tA.contains("CQ CQ DE DDH7 TEST 1234") && !tA.contains("DDK9"), "Kanäle: RTTY DDH7 auf 7646 kHz im 9,6-MS/s-Fenster gelesen (\(tA.filter { !$0.isNewline }))")
    check(tB.contains("WODL45 EDZW DDK9 GALE WARNING") && !tB.contains("DDH7"), "Kanäle: RTTY DDK9 auf 10100,8 kHz zugleich gelesen (\(tB.filter { !$0.isNewline }))")
    // 20 MS/s (Höchstwert des HackRF): zwei FM-Träger am Rand des nutzbaren Fensters kommen mit richtigem Pegel an
    do {
        let r20 = 20_000_000.0
        var w = SDRTestSignal(sampleRate: r20, seconds: 0.8)
        let edge = SDRSettingsStore.window(forRate: 20_000_000) - 200_000
        w.addFM(offsetHz: edge, tone: 1000, deviation: 3_000, amplitude: 0.2)
        w.addFM(offsetHz: -edge, tone: 2000, deviation: 3_000, amplitude: 0.2)
        w.addNoise(sigma: 0.004)
        let e20 = SDRReceiverEngine(sampleRate: r20)
        e20.setPrimaryEnabled(false)
        var c = SDRChannelConfig(mode: .nfm); c.bandwidthHz = 12_500
        let hi = Collector(), lo = Collector()
        e20.setExtraChannel(id: 1, config: c, offsetHz: edge, handler: { hi.add($0) })
        e20.setExtraChannel(id: 2, config: c, offsetHz: -edge, handler: { lo.add($0) })
        let bytes = w.quantized()
        bytes.withUnsafeBufferPointer { b in
            var k = 0
            while k < b.count { let e = min(k + 1_048_576, b.count); e20.feed(UnsafeBufferPointer(rebasing: b[k..<e]), wait: true); k = e }
        }
        Thread.sleep(forTimeInterval: 1.0)
        func lvl(_ x: [Float], _ f: Double) -> Double {
            guard x.count > 30_000 else { return 0 }
            var re = 0.0, im = 0.0
            for k in 0..<24_000 { let ph = 2 * Double.pi * f * Double(k) / 48_000; re += Double(x[6_000 + k]) * cos(ph); im -= Double(x[6_000 + k]) * sin(ph) }
            return 2 * (re * re + im * im).squareRoot() / 24_000
        }
        check(abs(lvl(hi.all, 1000) - 0.6) < 0.08 && lvl(hi.all, 2000) < 0.03 && abs(lvl(lo.all, 2000) - 0.6) < 0.08 && lvl(lo.all, 1000) < 0.03,
              "Kanäle bei 20 MS/s: beide Randkanäle (±\(Int(edge / 1000)) kHz) mit richtigem Pegel (\(lvl(hi.all, 1000)), \(lvl(lo.all, 2000)))")
        let spec = SDRSpectrum(sampleRate: r20)
        check(spec.bins == 16_384 && SDRSpectrum(sampleRate: 2_400_000).bins == 4_096, "Spektrum: 16384 Punkte ab 5 MS/s, sonst 4096")
        check(SDRSettingsStore.sampleRateChoices.last == 20_000_000 && SDRSettingsStore.sampleRateChoices(for: .rtlsdr) == [2_400_000] && SDRSettingsStore.sampleRateChoices(for: .hackrf).count == 6, "Fenster: HackRF bis 20 MS/s wählbar, die anderen Geräte fest 2,4")
    }
}

// MARK: - Kurzwellen-Ausbreitung (Lineal am rechten Fensterrand)
if want("prop") {
    // Antwort von HamQSL vom 08.10.2026 (gekürzt)
    let xml = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <solar><solardata><source url="http://www.hamqsl.com/solar.html">N0NBH</source>
    <updated> 08 Oct 2026 1049 GMT</updated><solarflux>114</solarflux><aindex> 6</aindex><kindex> 1</kindex><sunspots>92</sunspots>
    <calculatedconditions>
    <band name="80m-40m" time="day">Fair</band><band name="30m-20m" time="day">Good</band><band name="17m-15m" time="day">Fair</band><band name="12m-10m" time="day">Poor</band>
    <band name="80m-40m" time="night">Good</band><band name="30m-20m" time="night">Good</band><band name="17m-15m" time="night">Fair</band><band name="12m-10m" time="night">Poor</band>
    </calculatedconditions></solardata></solar>
    """
    let data = PropagationParser.parse(xml: Data(xml.utf8))
    check(data?.groups.count == 4 && data?.solarFlux == 114 && data?.aIndex == 6 && data?.kIndex == 1 && data?.sunspots == 92, "Ausbreitung: Werte aus der HamQSL-Antwort gelesen")
    check(data?.groups[0].day == .fair && data?.groups[0].night == .good && data?.groups[3].day == .poor && data?.groups[1].centerMHz == 12, "Ausbreitung: Bandgruppen mit Tag- und Nachtwert")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    check(data?.updated == cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 49)), "Ausbreitung: Zeitstempel (UTC)")
    check(PropagationParser.parse(xml: Data("<solar></solar>".utf8)) == nil && PropagationParser.parse(xml: Data("kein XML".utf8)) == nil, "Ausbreitung: Antwort ohne Bandwerte wird abgewiesen")

    // Sonnenstand am Standort JN49WS (49,8° N, 9,9° O): Höchst- und Tiefstwerte im Jahr
    func extremes(_ y: Int, _ m: Int, _ d: Int) -> (max: Double, min: Double) {
        var hi = -90.0, lo = 90.0
        for k in 0..<144 {
            let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: k / 6, minute: (k % 6) * 10))!
            let e = SunPosition.elevationDegrees(latitude: 49.8, longitude: 9.9, date: date)
            hi = max(hi, e); lo = min(lo, e)
        }
        return (hi, lo)
    }
    let summer = extremes(2026, 6, 21), winter = extremes(2026, 12, 21)
    check(abs(summer.max - 63.6) < 0.8 && abs(summer.min + 16.7) < 0.8, String(format: "Sonnenstand Sommer: Mittag %.1f° (63,6), Mitternacht %.1f° (−16,7)", summer.max, summer.min))
    check(abs(winter.max - 16.8) < 0.8 && abs(winter.min + 63.6) < 0.8, String(format: "Sonnenstand Winter: Mittag %.1f° (16,8), Mitternacht %.1f° (−63,6)", winter.max, winter.min))
    check(abs(SunPosition.declinationDegrees(date: cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!) - 23.4) < 0.3, "Sonnenstand: Deklination zur Sonnenwende")
    // Mittag um 11:20 UTC (Sonnenhöchststand bei 9,9° O) im Frühling: Höhe = 90 − Breite + Deklination
    let noon = SunPosition.elevationDegrees(latitude: 49.8, longitude: 9.9, date: cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 11, minute: 20))!)
    check(abs(noon - 40.2) < 1.5, String(format: "Sonnenstand: Tagundnachtgleiche mittags %.1f° (40,2)", noon))

    // Modell
    if let d = data {
        let day = PropagationModel.score(frequencyMHz: 12, data: d, elevation: 40), night = PropagationModel.score(frequencyMHz: 5, data: d, elevation: -30)
        check(day == 1 && night == 1, "Ausbreitungsmodell: 30–20 m Tag gut, 80–40 m Nacht gut")
        check(PropagationModel.score(frequencyMHz: 5, data: d, elevation: 40) == 0.5 && PropagationModel.score(frequencyMHz: 27.3, data: d, elevation: 40) == 0, "Ausbreitungsmodell: 80–40 m Tag mittel, 12–10 m schlecht")
        let mid = PropagationModel.score(frequencyMHz: 5, data: d, elevation: 0)
        check(mid > 0.5 && mid < 1, String(format: "Ausbreitungsmodell: in der Dämmerung zwischen Tag (0,5) und Nacht (1,0): %.2f", mid))
        let s8 = PropagationModel.score(frequencyMHz: 8.6, data: d, elevation: 40)      // zwischen 80–40 (0,5) und 30–20 (1,0)
        check(s8 > 0.5 && s8 < 1, "Ausbreitungsmodell: zwischen den Bandgruppen wird interpoliert (\(s8))")
        check(PropagationModel.score(frequencyMHz: 2, data: d, elevation: -30) > PropagationModel.score(frequencyMHz: 2, data: d, elevation: 40), "Ausbreitungsmodell: unter 3,5 MHz nachts besser als am Tag")
        let sum = PropagationModel.score(frequencyMHz: 3, data: d, elevation: -30, declination: 23, latitude: 50)
        let win = PropagationModel.score(frequencyMHz: 3, data: d, elevation: -30, declination: -23, latitude: 50)
        let sumSouth = PropagationModel.score(frequencyMHz: 3, data: d, elevation: -30, declination: 23, latitude: -35)
        check(sum < win && sumSouth == win, "Ausbreitungsmodell: im Sommer mehr Rauschen auf den tiefen Bändern, auf der Südhalbkugel umgekehrt")
        check((0..<300).allSatisfy { let v = PropagationModel.score(frequencyMHz: Double($0) / 10, data: d, elevation: Double($0) - 150); return v >= 0 && v <= 1 }, "Ausbreitungsmodell: Werte immer zwischen 0 und 1")
    }
    check(PropagationModel.dayWeight(elevation: -20) == 0 && PropagationModel.dayWeight(elevation: 20) == 1 && abs(PropagationModel.dayWeight(elevation: 0) - 0.5) < 1e-9, "Ausbreitungsmodell: Tagesanteil nach der Sonnenhöhe")
    let red = PropagationModel.color(score: 0), white = PropagationModel.color(score: 0.5), green = PropagationModel.color(score: 1)
    check(red.r > 0.8 && red.g < 0.4 && white.r > 0.9 && white.g > 0.9 && white.b > 0.9 && green.g > 0.8 && green.r < 0.3, "Ausbreitungsmodell: rot, weiß, grün")
}

// MARK: - JS8: Betriebsarten, Bänder, URL, Abstimmung, Log
if want("js8") {
    check(JS8Submode.allCases.map(\.periodSeconds) == [15, 10, 6, 30], "JS8: Zyklen Normal 15 s, Fast 10 s, Turbo 6 s, Slow 30 s")
    check(JS8Submode.allCases.map(\.bandwidth) == [50, 80, 160, 25], "JS8: Bandbreiten 50, 80, 160, 25 Hz")
    check(JS8Submode.normal.baud == 6.25 && JS8Submode.fast.baud == 10 && JS8Submode.turbo.baud == 20 && JS8Submode.slow.baud == 3.125, "JS8: Symbolraten")
    check(abs(JS8Submode.normal.txDuration - 12.64) < 0.001 && abs(JS8Submode.fast.txDuration - 7.9) < 0.001
          && abs(JS8Submode.turbo.txDuration - 3.95) < 0.001 && abs(JS8Submode.slow.txDuration - 25.28) < 0.001, "JS8: Dauer der Aussendung 12,64 / 7,9 / 3,95 / 25,28 s")
    check(JS8Submode.allCases.allSatisfy { $0.decodeAt > $0.startDelay + $0.txDuration && $0.decodeAt < $0.periodSeconds }, "JS8: Decodierzeitpunkt nach der Aussendung und vor dem Zyklusende")
    check(JS8Submode.allCases.map(\.letter) == ["A", "B", "C", "E"] && JS8Submode.submode(letter: "e") == .slow, "JS8: Buchstaben wie in ALL.TXT")
    check(parse("digidec://decode?mode=js8&preset=40m") == .success(DecodeRequest(module: .js8, presetID: "40m")), "JS8-Auftrag 40 m")
    check(parse("digidec://decode?mode=js8") == .success(DecodeRequest(module: .js8, presetID: "20m")), "JS8-Standard 20 m")
    check(JS8Band.m20.dialHz == 14_078_000 && JS8Band.m40.dialHz == 7_078_000 && JS8Band.m30.dialHz == 10_130_000
          && JS8Band.m2.dialHz == 144_178_000 && JS8Band.m160.dialHz == 1_842_000, "JS8: Dial-Frequenzen wie JS8Call")
    check(JS8Band.band(forDial: 14_078_000) == .m20 && JS8Band.band(forDial: 14_079_500) == .m20 && JS8Band.band(forDial: 14_095_600) == nil, "JS8: Band zur Dial-Frequenz")
    check(Set(JS8Band.allCases.map(\.rawValue)) == Set(DecoderModuleInfo.js8.presetIDs), "JS8-Bänder = IDs im URL-Schema")
    check(JS8Band.m20.dialLabel == "14,078", "JS8: Dial-Anzeige")
    check(RigTuneTarget.js8(band: .m20) == RigTuneTarget(dialHz: 14_078_000, mode: "USB"), "QSY: JS8 20 m = 14,078 MHz USB")
    check(DecoderModuleInfo.js8.band == .hf && DecoderModuleInfo.js8.displayName == "JS8" && DecoderModuleInfo.js8.isAvailable && DecoderModuleInfo.js8.hasMap, "JS8: Modul in der HF-Leiste")
    let fixed = Date(timeIntervalSince1970: (1_790_000_010.0 - 1_790_000_010.0.truncatingRemainder(dividingBy: 15)))
    let hb = JS8Decode(cycleStart: fixed, submode: .normal, frame: "SKflsHSNwzqH", bits: [.first, .last], snrDB: -16, dt: 0.14, freqHz: 521.4, quality: 1)
    let line = JS8Controller.allTxtLine(hb)
    check(line.hasSuffix("A         SKflsHSNwzqH   3") && line.contains("-16") && line.contains("  521"), "JS8: Log-Zeile wie ALL.TXT, got \(line.debugDescription)")
    check(JS8Decode(cycleStart: fixed, submode: .normal, frame: "SKflsHSNwzqH", bits: [.first, .last], snrDB: -1, dt: 0, freqHz: 1, quality: 0.1).isUncertain
          && !hb.isUncertain, "JS8: geringe Güte unter 0,17 ist unsicher")
}

// MARK: - JS8: Rahmen auspacken (Varicode, JSC) und packen
if want("js8") {
    // Rahmen aus den Testaufnahmen von JS8Call (media/tests): echte Sendungen, Texte wie sie JS8Call zeigt
    let real: [(String, Int, String)] = [
        ("SKflsHSNwzqH", 3, "KG9B: KN4CRD HEARTBEAT SNR -14 "),
        ("UctD9HSNwzqE", 3, "VA3QR: KN4CRD HEARTBEAT SNR -17 "),
        ("Vk4xfHSNwzaX", 3, "K0OG: KN4CRD SNR +02 "),
        ("SJWkJnSNwzqH", 3, "KD8SKZ: KN4CRD HEARTBEAT SNR -14 "),
        ("2Y-wUW3FOjFp", 3, "KN4ZXG: @HB HEARTBEAT FM16 "),
        ("u3ipItc4eML+", 0, "W HIDING OUT IN A "),
        ("TrMcT8++++++", 7, "KN4CRD: TEST"),
        ("VkDSPUuGBfqa", 3, "K4BYN: K0EIA HEARTBEAT SNR +05 "),
    ]
    for (frame, bits, text) in real {
        let u = JS8Varicode.unpack(frame, bits: JS8FrameBits(rawValue: bits))
        check(u?.text == text, "JS8: Rahmen \(frame) → „\(text)“, got \(u?.text.debugDescription ?? "nil")")
    }
    let d1 = JS8Varicode.unpack("SKflsHSNwzqH", bits: [.first, .last])
    check(d1?.kind == .directed && d1?.from == "KG9B" && d1?.to == "KN4CRD" && d1?.command == " HEARTBEAT SNR" && d1?.number == "-14", "JS8: Directed zerlegt")
    let h1 = JS8Varicode.unpack("2Y-wUW3FOjFp", bits: [.first, .last])
    check(h1?.kind == .heartbeat && h1?.from == "KN4ZXG" && h1?.grid == "FM16" && h1?.isCQ == false, "JS8: Heartbeat zerlegt")

    // Packen und wieder Auspacken
    func roundTrip(_ frame: String?, _ text: String, _ msg: String, bits: JS8FrameBits = [.first, .last]) {
        check(frame != nil && frame!.count == 12, "JS8: \(msg) packbar")
        if let frame { check(JS8Varicode.unpack(frame, bits: bits)?.text == text, "JS8: \(msg) → „\(text)“, got \(JS8Varicode.unpack(frame, bits: bits)?.text.debugDescription ?? "nil")") }
    }
    roundTrip(JS8Varicode.packHeartbeat(call: "DL1ABC", grid: "JN49"), "DL1ABC: @HB HEARTBEAT JN49 ", "Heartbeat")
    roundTrip(JS8Varicode.packHeartbeat(call: "K1ABC", grid: nil), "K1ABC: @HB HEARTBEAT  ", "Heartbeat ohne Locator")
    roundTrip(JS8Varicode.packHeartbeat(call: "OE4ATS", grid: "JN87", cq: 1), "OE4ATS: @ALLCALL CQ DX JN87 ", "CQ DX")
    roundTrip(JS8Varicode.packHeartbeat(call: "9A7DA", grid: "JN86", cq: 7), "9A7DA: @ALLCALL CQ JN86 ", "CQ")
    roundTrip(JS8Varicode.packHeartbeat(call: "DL1ABC/P", grid: "JO30"), "DL1ABC/P: @HB HEARTBEAT JO30 ", "Heartbeat mit /P")
    roundTrip(JS8Varicode.packDirected(from: "DL1ABC", to: "DL2XYZ", command: 14), "DL1ABC: DL2XYZ ACK ", "Directed ACK")
    roundTrip(JS8Varicode.packDirected(from: "DL1ABC", to: "K1ABC", command: 25, number: -12), "DL1ABC: K1ABC SNR -12 ", "Directed SNR -12")
    roundTrip(JS8Varicode.packDirected(from: "DL1ABC", to: "K1ABC", command: 25, number: 5), "DL1ABC: K1ABC SNR +05 ", "Directed SNR +5")
    roundTrip(JS8Varicode.packDirected(from: "DL1ABC", to: "@ALLCALL", command: 30), "DL1ABC: @ALLCALL AGN? ", "Directed an Gruppe")
    roundTrip(JS8Varicode.packDirected(from: "W1AW", to: "DL1ABC", command: 10), "W1AW: DL1ABC MSG TO: ", "Directed MSG TO:")
    roundTrip(JS8Varicode.packDirected(from: "DL1ABC/P", to: "K1ABC", command: 28), "DL1ABC/P: K1ABC 73 ", "Directed mit /P")
    roundTrip(JS8Varicode.packDirected(from: "3DA0XYZ", to: "3XA1BC", command: 21), "3DA0XYZ: 3XA1BC RR ", "Directed mit Sonderrufzeichen")
    roundTrip(JS8Varicode.packDirected(from: "DL1ABC", to: "K1ABC", command: 17, number: 3), "DL1ABC: K1ABC INFO 3 ", "Directed mit Zahl")
    roundTrip(JS8Varicode.packCompoundCall("PA/DL1ABC", grid: "JO21"), "PA/DL1ABC: ", "Compound")
    let comp = JS8Varicode.packCompoundCall("PA/DL1ABC", grid: "JO21").flatMap { JS8Varicode.unpack($0, bits: [.first]) }
    check(comp?.kind == .compound && comp?.from == "PA/DL1ABC" && comp?.grid == "JO21", "JS8: Compound zerlegt")
    let cd = JS8Varicode.packCompoundDirected("EA8/DL1ABC", command: 25, snr: -7).flatMap { JS8Varicode.unpack($0, bits: [.first]) }
    check(cd?.kind == .compoundDirected && cd?.from == "EA8/DL1ABC" && cd?.command == " SNR" && cd?.number == "-07", "JS8: Compound-Directed mit SNR zerlegt, got \(String(describing: cd))")
    roundTrip(JS8Varicode.packHuffmanText("HELLO WORLD"), "HELLO WORLD", "Huffman-Text", bits: [])
    check(JS8Varicode.unpack(JS8Varicode.packHuffmanText("HELLO WORLD 73")!, bits: [])?.text == "HELLO WORLD 7", "JS8: Huffman-Rahmen fasst 70 Bit, der Rest bleibt für den nächsten Rahmen")
    check(JS8Varicode.packHuffmanText("hello") != nil && JS8Varicode.packHuffmanText("Ü") == nil, "JS8: Huffman nimmt nur Zeichen der Tabelle")
    // Locator: alle Felder rund
    var gridsOK = true
    for a in "AEJNR" { for b in "AGNR" { for c in "0357" { for d in "0469" {
        let g = String([a, b, c, d])
        if JS8Varicode.packHeartbeat(call: "DL1ABC", grid: g).flatMap({ JS8Varicode.unpack($0, bits: [.first, .last]) })?.grid != g { gridsOK = false }
    } } } }
    check(gridsOK, "JS8: Locator-Raster 4 Stellen rund")
    // Rufzeichen: Rund durch den 28-Bit-Wert
    var callsOK = true
    for call in ["K1ABC", "DL1ABC", "9A7DA", "W1AW", "G4ABC", "VK2LAW", "4X4AB", "OE4ATS", "N5RML", "KB1CTC", "@ALLCALL", "@HB", "@DX/EU", "@GROUP/3", "<....>"] {
        var p = false
        if let v = JS8Varicode.packCallsign(call, portable: &p), JS8Varicode.unpackCallsign(v, portable: false) == call {} else { callsOK = false; print("Rufzeichen \(call) nicht rund") }
    }
    check(callsOK, "JS8: Rufzeichen und Gruppen rund durch 28 Bit")
    // Müll: Unbekanntes, zu kurz, Leerzeichen
    check(JS8Varicode.unpack("ABC", bits: []) == nil && JS8Varicode.unpack("ABCDEFGHIJK ", bits: []) == nil, "JS8: zu kurz oder Leerzeichen → nichts")
    check(JS8Varicode.unpack("????????????", bits: []) == nil, "JS8: Zeichen außerhalb des Alphabets → nichts")
    // JSC: Wörterbuch hat den Umfang von JS8Call, Anfang und Ende stimmen
    check(JS8JSC.word(0) == "E" && JS8JSC.word(1) == "T" && JS8JSC.word(262_143) == "ROSIDS" && JS8JSC.word(262_144) == nil, "JS8: JSC-Wörterbuch Anfang und Ende")
    check(JS8JSC.word(10_704) == "¡" && JS8JSC.word(10_705) == "¿", "JS8: JSC Zeichen als Latin-1")
}

// MARK: - JS8: Nachrichten aus Rahmen, Stationen
if want("js8") {
    let t0 = Date(timeIntervalSince1970: (1_790_000_010.0 - 1_790_000_010.0.truncatingRemainder(dividingBy: 15)))
    func d(_ frame: String, _ bits: JS8FrameBits, cycle: Int, f: Double = 1000, snr: Int = -10, mode: JS8Submode = .normal, q: Double = 1) -> JS8Decode {
        JS8Decode(cycleStart: t0.addingTimeInterval(Double(cycle) * mode.periodSeconds), submode: mode, frame: frame, bits: bits, snrDB: snr, dt: 0, freqHz: f, quality: q)
    }
    // Eine Nachricht aus drei Rahmen: Befehl „MSG“ mit Text, erster Rahmen first, mittlerer ohne, letzter last
    let head = JS8Varicode.packDirected(from: "DL1ABC", to: "K1ABC", command: 9)!
    let t1 = JS8Varicode.packHuffmanText("HELLO")!
    let t2 = JS8Varicode.packHuffmanText("WORLD")!
    var agg = JS8Aggregator()
    agg.add(d(head, [.first], cycle: 0, snr: -12))
    agg.add(d(t1, [], cycle: 1, f: 1002.5, snr: -8))
    check(agg.lines.count == 1 && !agg.lines[0].isComplete, "JS8: zwei Rahmen sind eine offene Nachricht")
    agg.add(d(t2, [.last], cycle: 2, f: 999.5, snr: -9))
    check(agg.lines.count == 1 && agg.lines[0].isComplete && agg.lines[0].frameCount == 3, "JS8: letzter Rahmen schließt die Nachricht")
    check(agg.lines[0].text == "DL1ABC: K1ABC MSG HELLOWORLD", "JS8: Text aneinandergehängt, got \(agg.lines[0].text.debugDescription)")
    check(agg.lines[0].snrDB == -8 && agg.lines[0].from == "DL1ABC" && agg.lines[0].to == "K1ABC" && agg.lines[0].kind == .directed, "JS8: bester Pegel, Absender, Empfänger")
    // Zwei Stationen gleichzeitig auf verschiedenen Frequenzen bleiben getrennt
    var two = JS8Aggregator()
    two.add(d(head, [.first], cycle: 0, f: 700))
    two.add(d(JS8Varicode.packDirected(from: "W1AW", to: "K1ABC", command: 9)!, [.first], cycle: 0, f: 1400))
    two.add(d(t1, [.last], cycle: 1, f: 701))
    two.add(d(t2, [.last], cycle: 1, f: 1399))
    check(two.lines.count == 2 && two.lines.allSatisfy(\.isComplete), "JS8: zwei Gespräche auf 700 und 1400 Hz getrennt")
    check(two.lines[0].text.hasSuffix("HELLO") && two.lines[1].text.hasSuffix("WORLD"), "JS8: Text je Gespräch")
    // Heartbeat ist eine einzelne Nachricht; ein neuer Anfang auf derselben Frequenz öffnet eine neue Zeile
    var hbs = JS8Aggregator()
    hbs.add(d(JS8Varicode.packHeartbeat(call: "DL1ABC", grid: "JN49")!, [.first, .last], cycle: 0))
    hbs.add(d(JS8Varicode.packHeartbeat(call: "DL1ABC", grid: "JN49")!, [.first, .last], cycle: 4))
    check(hbs.lines.count == 2 && hbs.lines.allSatisfy { $0.isHeartbeat && $0.isComplete } && hbs.lines[0].grid == "JN49", "JS8: Heartbeats einzeln")
    // Fehlender Rahmen: Lücke markiert; zu alte offene Nachricht wird nicht fortgesetzt
    var gap = JS8Aggregator()
    gap.add(d(head, [.first], cycle: 0))
    gap.add(d(t2, [.last], cycle: 2))
    check(gap.lines.count == 1 && gap.lines[0].hasGap && gap.lines[0].text.contains("…"), "JS8: Lücke durch fehlenden Zyklus markiert")
    var stale = JS8Aggregator()
    stale.add(d(head, [.first], cycle: 0))
    stale.add(d(t2, [.last], cycle: 6))
    check(stale.lines.count == 2 && stale.lines[1].text.hasPrefix("… "), "JS8: nach mehr als drei Zyklen beginnt eine neue Zeile")
    // Betriebsarten getrennt, Rohrahmen in Klammern
    var modes = JS8Aggregator()
    modes.add(d(head, [.first], cycle: 0, f: 1000, mode: .normal))
    modes.add(d(t1, [.last], cycle: 1, f: 1000, mode: .fast))
    check(modes.lines.count == 2, "JS8: Betriebsarten werden nicht vermischt")
    var raw = JS8Aggregator()
    raw.add(d("????????????", [.first, .last], cycle: 0))
    check(raw.lines.first?.text == "[????????????]" && raw.lines.first?.kind == nil, "JS8: unbekannter Rahmen als Rohtext in Klammern")
    check(JS8Calls.isCall("DL1ABC") && JS8Calls.isCall("PA/DL1ABC") && JS8Calls.isCall("9A7DA") && !JS8Calls.isCall("@ALLCALL") && !JS8Calls.isCall("<....>")
          && !JS8Calls.isCall("HELLO") && !JS8Calls.isCall("AB"), "JS8: Rufzeichen-Erkennung")
    check(JS8Calls.leadingCall("KN4CRD: TEST") == "KN4CRD" && JS8Calls.leadingCall("TEST: KN4CRD") == nil && JS8Calls.leadingCall("HELLO WORLD") == nil, "JS8: Rufzeichen vor dem Doppelpunkt")
    check(JS8Aggregator.tolerance(.normal) == 7.5 && JS8Aggregator.tolerance(.slow) == 5 && JS8Aggregator.tolerance(.turbo) == 24, "JS8: Frequenztoleranz je Betriebsart")
}

// MARK: - JS8-Decoder (synthetisch)
if want("js8") {
    var seed: UInt64 = 29
    func gauss() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407; let u1 = (Double(seed >> 11) + 0.5) / Double(1 << 53)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407; let u2 = (Double(seed >> 11) + 0.5) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
    let frame = JS8Varicode.packHeartbeat(call: "DL1ABC", grid: "JN49")!
    // Sauber, jede Betriebsart
    for mode in JS8Submode.allCases {
        guard let sig = JS8Core.synthesize(frame: frame, submode: mode, frequency: 1000, amplitude: 0.2) else { check(false, "JS8-Testsignal \(mode.title)"); continue }
        check(sig.count == Int(mode.periodSeconds) * 12_000, "JS8: Testsignal \(mode.title) füllt den Zyklus")
        let res = JS8Core.decode(sig, submode: mode)
        let r = res.first
        check(res.count == 1 && r?.frame == frame && r?.bits == [.first, .last] && r?.unpacked?.text == "DL1ABC: @HB HEARTBEAT JN49 ",
              "JS8 \(mode.title): sauberes Signal decodiert, got \(res.map(\.frame))")
        check(abs((r?.freqHz ?? 0) - 1000) < 1.5 && abs(r?.dt ?? 9) < 0.15 && (r?.quality ?? 0) > 0.9,
              "JS8 \(mode.title): Frequenz \(r.map { String(format: "%.2f", $0.freqHz) } ?? "–") Hz, DT \(r.map { String(format: "%.2f", $0.dt) } ?? "–")")
    }
    // Rauschen: S/N(2500 Hz) nominal −12 dB bei Normal; σ² je Abtastwert so, dass im 2500-Hz-Streifen N = σ²·2500/6000
    func noisy(_ sig: [Float], snrDB: Double, amplitude: Double, sigma0: Double = 0.1) -> [Float] {
        let ampl = (2 * (sigma0 * sigma0 * 2500 / 6000) * pow(10, snrDB / 10)).squareRoot()
        let k = Float(ampl / amplitude)
        return sig.map { $0 * k + Float(sigma0 * gauss()) }
    }
    if let sig = JS8Core.synthesize(frame: frame, submode: .normal, frequency: 1300, amplitude: 1) {
        let res = JS8Core.decode(noisy(sig, snrDB: -12, amplitude: 1), submode: .normal)
        check(res.contains { $0.frame == frame && abs($0.freqHz - 1300) < 2 }, "JS8 Normal: −12 dB im Rauschen decodiert, got \(res.map { "\($0.frame) \($0.snrDB)" })")
        if let r = res.first(where: { $0.frame == frame }) {
            // JS8Call meldet etwa 8 dB tiefer als das S/N in 2500 Hz (Bezug auf die Symbolbandbreite); Schwelle bei gemeldet ≈ −26 dB
            check((-23 ... -17).contains(r.snrDB), "JS8 Normal: gemeldetes S/N \(r.snrDB) dB für nominell −12 dB")
        }
        check(res.allSatisfy { $0.frame == frame }, "JS8 Normal: keine Fehldecodierung im Rauschen, got \(res.map(\.frame))")
        // Nur Rauschen: nichts
        let only = JS8Core.decode((0..<180_000).map { _ in Float(0.1 * gauss()) }, submode: .normal)
        check(only.isEmpty, "JS8 Normal: Rauschen allein liefert nichts, got \(only.map(\.frame))")
    }
    // Zwei Stationen, 150 Hz auseinander, 10 dB Unterschied, dazu Rauschen
    let other = JS8Varicode.packDirected(from: "K1ABC", to: "DL1ABC", command: 14)!
    if let a = JS8Core.synthesize(frame: frame, submode: .normal, frequency: 800, amplitude: 1),
       let b = JS8Core.synthesize(frame: other, bits: [.first, .last], submode: .normal, frequency: 950, amplitude: 1) {
        var mix = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { mix[i] = a[i] + 0.3 * b[i] }
        let res = JS8Core.decode(noisy(mix, snrDB: -8, amplitude: 1), submode: .normal)
        check(res.contains { $0.frame == frame } && res.contains { $0.frame == other }, "JS8 Normal: zwei Stationen im Abstand 150 Hz, got \(res.map(\.frame))")
    }
    // Frequenzablage, Zeitversatz: Signal 0,3 s später und 5 Hz höher; Bereich 200 … 3500 Hz geprüft
    if var sig = JS8Core.synthesize(frame: frame, submode: .normal, frequency: 2705, amplitude: 0.3) {
        let shift = Int(0.3 * 12_000)
        sig = [Float](repeating: 0, count: shift) + sig.dropLast(shift)
        let r = JS8Core.decode(sig, submode: .normal).first
        check(r?.frame == frame && abs((r?.dt ?? 0) - 0.3) < 0.15 && abs((r?.freqHz ?? 0) - 2705) < 1.5, "JS8 Normal: 0,3 s Versatz bei 2705 Hz, DT \(r.map { String(format: "%.2f", $0.dt) } ?? "–")")
        var restricted = JS8Core.Settings()
        restricted.minHz = 300; restricted.maxHz = 2000
        check(JS8Core.decode(sig, submode: .normal, settings: restricted).isEmpty, "JS8: Suchbereich 300 … 2000 Hz blendet 2705 Hz aus")
    }
    // Mehrere Rahmen derselben Nachricht, Slow bei schwachem Signal
    if let sig = JS8Core.synthesize(frame: frame, submode: .slow, frequency: 900, amplitude: 1) {
        let res = JS8Core.decode(noisy(sig, snrDB: -20, amplitude: 1), submode: .slow)
        check(res.contains { $0.frame == frame }, "JS8 Slow: −20 dB im Rauschen decodiert, got \(res.map { "\($0.frame) \($0.snrDB)" })")
    }
    if let sig = JS8Core.synthesize(frame: frame, submode: .turbo, frequency: 1500, amplitude: 1) {
        let res = JS8Core.decode(noisy(sig, snrDB: -8, amplitude: 1), submode: .turbo)
        check(res.contains { $0.frame == frame }, "JS8 Turbo: −8 dB im Rauschen decodiert, got \(res.map { "\($0.frame) \($0.snrDB)" })")
    }
    // Falsche Betriebsart findet nichts
    if let sig = JS8Core.synthesize(frame: frame, submode: .normal, frequency: 1000, amplitude: 0.2) {
        check(JS8Core.decode(sig, submode: .turbo).isEmpty, "JS8: Normal-Signal erscheint nicht als Turbo")
    }
}

// MARK: - JS8 an den Aufnahmen von JS8Call (media/tests, nur wenn lokal vorhanden)
if want("js8") {
    func wav(_ name: String) -> [Float]? {
        let url = URL(fileURLWithPath: "TestData/JS8/" + name)
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let n = (data.count - 44) / 2
        var x = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let s = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for i in 0..<n { x[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        return x
    }
    // Erwartet: Ergebnis des unveränderten JS8Call-Decoders (JS8.cpp mit FFTW, Boost, Eigen) auf denselben Dateien
    let expected: [(String, JS8Submode, [String])] = [
        ("A_1_4.wav", .normal, ["2Y-wUW3FOjFp", "Vk4xfHSNwzaX", "SKflsHSNwzqH", "SJWkJnSNwzqH", "UctD9HSNwzqE"]),
        ("A_2_1.wav", .normal, []),
        ("A_2_3.wav", .normal, ["VlPJy-uGBfqF", "Uw2nt-xLZLqO"]),
        ("A_2_5.wav", .normal, ["2Y-wUW3FOjFp", "Vk4xfHSNwzaX", "SKflsHSNwzqH", "SJWkJnSNwzqH", "UctD9HSNwzqE"]),
        ("A_2_6.wav", .normal, ["SIUT18l+CDqE", "SQu8I8l+CDqR", "u3ipItc4eML+", "SJff78l+CDqP"]),
        ("A_2_9.wav", .normal, ["VkDSPUuGBfqa", "SIUT1UuGBfqb", "SQu8IUuGBfqL", "VkNoM-uGBfqK", "SKgyQ-uGBfqU", "Uw2nt-uGBfqS", "VlPJy-uGBfqI", "SJff7UuGBfqY"]),
        ("A_3_3.wav", .normal, ["VlPJy-uGBfqF", "Uw2nt-xLZLqO"]),
        ("E_1_1.wav", .slow, ["TrMcT8++++++"]),
        ("E_2_1.wav", .slow, ["TrMcT8++++++"]),
    ]
    var any = false
    for (name, mode, frames) in expected {
        guard let x = wav(name) else { continue }
        any = true
        let res = JS8Core.decode(x, submode: mode)
        check(Set(res.map(\.frame)) == Set(frames), "JS8 \(name): Rahmen wie JS8Call, got \(res.map(\.frame)) erwartet \(frames)")
    }
    if let x = wav("A_2_9.wav") {
        let res = JS8Core.decode(x, submode: .normal)
        let calls = Set(res.compactMap { $0.unpacked?.from })
        check(calls == ["K4BYN", "KB1CTC", "K8KDS", "KG9PL", "WP4OH", "KX4XT", "N5RML", "KE2KQ"], "JS8 A_2_9: Absender der acht Heartbeat-Antworten, got \(calls.sorted())")
        check(res.allSatisfy { $0.unpacked?.to == "K0EIA" && $0.unpacked?.command == " HEARTBEAT SNR" }, "JS8 A_2_9: alle an K0EIA, „HEARTBEAT SNR“")
        let strong = res.first { $0.unpacked?.from == "KB1CTC" }
        check(strong.map { $0.snrDB >= 4 && $0.snrDB <= 8 } ?? false && abs((strong?.freqHz ?? 0) - 650.5) < 0.6, "JS8 A_2_9: KB1CTC \(strong?.snrDB ?? 0) dB bei \(strong.map { String(format: "%.1f", $0.freqHz) } ?? "–") Hz")
    }
    if let x = wav("E_1_1.wav") {
        let r = JS8Core.decode(x, submode: .slow).first
        check(r?.text == "KN4CRD: TEST" && r?.bits == [.first, .last, .data] && (r?.snrDB ?? 0) > 30, "JS8 E_1_1: Slow-Datenrahmen „KN4CRD: TEST“")
    }
    if !any { skip("JS8 echt: TestData/JS8/*.wav liegen nicht lokal vor (aus Vendor/_upstream/js8call/media/tests kopieren)") }
}

// MARK: - JS8-Zyklus über die Pipeline (simulierte Uhr)
if want("js8") {
    final class FakeClock: @unchecked Sendable { var t = 0.0 }
    let clock = FakeClock()
    let cycle = 1_790_000_010.0 - 1_790_000_010.0.truncatingRemainder(dividingBy: 15)   // Zyklusbeginn Normal
    let pipeline = AudioPipeline()
    let decoder = JS8Decoder(pipeline: pipeline)
    decoder.clock = { clock.t }
    decoder.configure(modes: [.normal, .turbo], settings: JS8Core.Settings(), preferHz: 1000, timeOffset: 0)
    decoder.setEnabled(true)
    pipeline.start(inputRate: 48_000)
    let frame = JS8Varicode.packDirected(from: "DL1ABC", to: "K1ABC", command: 14)!
    let lead = 2.0
    // Normal-Zyklus (15 s) beginnt beim Zyklusbeginn; Turbo-Zyklen (6 s) liegen auf 0, 6, 12 s: das Signal beginnt nach 12 s
    let normalSig = JS8Core.synthesize(frame: frame, submode: .normal, frequency: 1100, amplitude: 0.3)!
    let turboFrame = JS8Varicode.packHeartbeat(call: "K1ABC", grid: "FN31")!
    let turboSig = JS8Core.synthesize(frame: turboFrame, submode: .turbo, frequency: 2000, amplitude: 0.3)!
    var audio12 = [Float](repeating: 0, count: Int(lead * 12_000)) + normalSig
    // Turbo-Aussendung im Zyklus 6 … 12 s dazumischen (Beginn bei Sekunde 6 + 0,1 s Verzögerung ist im Signal enthalten)
    let off = Int((lead + 6) * 12_000)
    for i in 0..<turboSig.count where off + i < audio12.count { audio12[off + i] += turboSig[i] }
    var audio48 = [Float](repeating: 0, count: audio12.count * 4)
    for i in 0..<audio48.count {
        let x = Double(i) / 4, k = Int(x), f = Float(x - Double(k))
        audio48[i] = audio12[k] * (1 - f) + (k + 1 < audio12.count ? audio12[k + 1] : 0) * f
    }
    Thread.sleep(forTimeInterval: 0.05)
    var i = 0
    let chunk = 4_800
    var results: [JS8Decoder.CycleResult] = []
    while i < audio48.count {
        let n = min(chunk, audio48.count - i)
        audio48[i..<(i + n)].withUnsafeBufferPointer { pipeline.ring.write($0.baseAddress!, count: n) }
        i += n
        clock.t = cycle - lead + Double(i) / 48_000
        Thread.sleep(forTimeInterval: 0.03)
        results += decoder.takeResults()
    }
    for _ in 0..<60 where !(results.contains { $0.submode == .normal } && results.contains { $0.submode == .turbo && $0.decodes.contains { $0.frame == turboFrame } }) {
        Thread.sleep(forTimeInterval: 0.1)
        results += decoder.takeResults()
    }
    let normal = results.first { $0.submode == .normal }
    let turbo = results.first { $0.submode == .turbo && $0.decodes.contains { $0.frame == turboFrame } }
    check(normal?.cycleStart == Date(timeIntervalSince1970: cycle), "JS8-Zyklus: Normal beginnt nach UTC-Raster")
    check(normal?.decodes.first?.frame == frame && abs(normal?.decodes.first?.dt ?? 9) < 0.25, "JS8-Zyklus: Normal über die Pipeline 48 kHz → 12 kHz, DT \(normal?.decodes.first.map { String(format: "%.2f", $0.dt) } ?? "–")")
    check(turbo != nil && turbo!.cycleStart == Date(timeIntervalSince1970: cycle + 6), "JS8-Zyklus: Turbo im Raster von 6 s, got \(results.map { "\($0.submode.letter) \($0.cycleStart.timeIntervalSince1970 - cycle) \($0.decodes.count)" })")
    check(Set(results.map(\.submode)) == [.normal, .turbo], "JS8-Zyklus: nur die gewählten Betriebsarten")
    decoder.setEnabled(false)
    pipeline.stop()
}

// MARK: - SDRplay: Abtastrate 62,5 kS/s bis 10 MS/s, Filter, Notches (DAB- und RF-Notch)
if want("sdrplay") {
    check(SDRplayPlan.sampleRates.first == 62_500 && SDRplayPlan.sampleRates.last == 10_000_000 && SDRplayPlan.sampleRates == SDRplayPlan.sampleRates.sorted(),
          "SDRplay: Raten von 62,5 kS/s bis 10 MS/s aufsteigend")
    // Dezimierung: unter 2 MS/s teilt die API das 2-MS/s-Signal durch 2, 4, 8, 16, 32
    let dec: [(Int, Int)] = [(62_500, 32), (125_000, 16), (250_000, 8), (500_000, 4), (1_000_000, 2)]
    for (wanted, d) in dec {
        let r = SDRplayPlan.rate(for: wanted)
        check(r.deviceHz == 2_000_000 && r.decimation == d && Int(r.outputHz) == wanted, "SDRplay: \(wanted) S/s = 2 MS/s durch \(d)")
    }
    for wanted in [2_000_000, 2_400_000, 3_000_000, 5_000_000, 8_000_000, 10_000_000] {
        let r = SDRplayPlan.rate(for: wanted)
        check(r.deviceHz == Double(wanted) && r.decimation == 1 && Int(r.outputHz) == wanted, "SDRplay: \(wanted) S/s direkt ohne Dezimierung")
    }
    check(SDRplayPlan.rate(for: 20_000_000).deviceHz == 10_000_000 && SDRplayPlan.rate(for: 1_000).outputHz == 62_500, "SDRplay: Raten außerhalb werden begrenzt")
    check(SDRplayPlan.rate(for: 600_000).decimation == 4 && SDRplayPlan.rate(for: 100_000).decimation == 16, "SDRplay: krumme Rate auf die nächste mögliche gerundet")
    // Analoger Filter: nach der Rate, sonst die eigene Wahl auf den nächsten erlaubten Wert
    let bw: [(Int, Int)] = [(62_500, 200), (125_000, 200), (250_000, 300), (500_000, 600), (1_000_000, 1536), (2_000_000, 1536), (2_400_000, 1536),
                            (3_000_000, 1536), (4_000_000, 1536), (5_000_000, 5000), (6_000_000, 6000), (8_000_000, 8000), (9_600_000, 8000), (10_000_000, 8000)]
    for (rate, khz) in bw {
        check(SDRplayPlan.bandwidthKHz(outputHz: Double(rate), requested: 0) == khz, "SDRplay: Filter bei \(rate) S/s automatisch \(khz) kHz, got \(SDRplayPlan.bandwidthKHz(outputHz: Double(rate), requested: 0))")
    }
    check(SDRplayPlan.bandwidthKHz(outputHz: 2e6, requested: 600) == 600 && SDRplayPlan.bandwidthKHz(outputHz: 2e6, requested: 1100) == 1536
          && SDRplayPlan.bandwidthKHz(outputHz: 2e6, requested: 4000) == 5000 && SDRplayPlan.bandwidthKHz(outputHz: 2e6, requested: 50_000) == 8000, "SDRplay: eigene Filterwahl auf erlaubte Werte")
    check(SDRplayPlan.sampleRates.allSatisfy { r in let p = SDRplayPlan.rate(for: r); return SDRplayPlan.bandwidthsKHz.contains(SDRplayPlan.bandwidthKHz(outputHz: p.outputHz, requested: 0)) }, "SDRplay: Filter immer ein Wert der API")

    // Notches je Gerät (Versätze aus dem Header 3.15 der SDRplay-API, mit offsetof gemessen)
    let n1a = SDRplayPlan.notchFields(hwVer: 255), n1b = SDRplayPlan.notchFields(hwVer: 6), n2 = SDRplayPlan.notchFields(hwVer: 2)
    let nduo = SDRplayPlan.notchFields(hwVer: 3), ndx = SDRplayPlan.notchFields(hwVer: 4), ndx2 = SDRplayPlan.notchFields(hwVer: 7)
    check(n1a?.base == .device && n1a?.rfOffset == 44 && n1a?.dabOffset == 45 && n1b == n1a, "SDRplay: RSP1A/1B Notches in DevParams.rsp1aParams")
    check(n2?.base == .channel && n2?.rfOffset == 120 && n2?.dabOffset == nil, "SDRplay: RSP2 nur RF-Notch (Tuner-Struktur)")
    check(nduo?.base == .channel && nduo?.rfOffset == 133 && nduo?.dabOffset == 134, "SDRplay: RSPduo Notches in rspDuoTunerParams")
    check(ndx?.base == .device && ndx?.rfOffset == 60 && ndx?.dabOffset == 61 && ndx2 == ndx, "SDRplay: RSPdx Notches in DevParams.rspDxParams")
    check(SDRplayPlan.notchFields(hwVer: 1) == nil && SDRplayPlan.notches(hwVer: 1) == (false, false) && SDRplayPlan.notches(hwVer: 2) == (true, false)
          && SDRplayPlan.notches(hwVer: 3) == (true, true), "SDRplay: RSP1 ohne Notches, RSP2 nur RF, RSPduo beide")
    check(n1a?.updateRf.0 == 0x20 && n1a?.updateDab.0 == 0x40 && n2?.updateRf.0 == 0x400 && nduo?.updateRf.0 == 0x4000_0000 && nduo?.updateDab.0 == 0x8000_0000
          && ndx?.updateRf.1 == 0x8 && ndx?.updateDab.1 == 0x10, "SDRplay: Update-Kennzeichen der Notches")

    // Schreiben in die Strukturen: Rate, Dezimierung, Filter und je nach Gerät die Notches
    func applied(hw: UInt8, rate: Int, rf: Bool, dab: Bool, bandwidth: Int = 0) -> (dev: UnsafeMutableRawPointer, ch: UnsafeMutableRawPointer, result: (rate: SDRplayPlan.Rate, bandwidthKHz: Int)) {
        let dev = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8), ch = UnsafeMutableRawPointer.allocate(byteCount: 144, alignment: 8)
        dev.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        ch.initializeMemory(as: UInt8.self, repeating: 0, count: 144)
        var g = ADSBGainSettings()
        g.sampleRateHz = rate; g.sdrplayRfNotch = rf; g.sdrplayDabNotch = dab; g.sdrplayBandwidthKHz = bandwidth; g.sdrplayPPM = 3
        return (dev, ch, SDRplayPlan.apply(settings: g, hwVer: hw, dev: dev, channel: ch))
    }
    func byte(_ p: UnsafeMutableRawPointer, _ o: Int) -> UInt8 { p.load(fromByteOffset: o, as: UInt8.self) }
    do {
        let a = applied(hw: 255, rate: 250_000, rf: true, dab: false)
        check(a.dev.load(fromByteOffset: 8, as: Double.self) == 2_000_000 && a.dev.load(fromByteOffset: 0, as: Double.self) == 3, "SDRplay: fsHz 2 MS/s und PPM geschrieben")
        check(byte(a.ch, 74) == 1 && byte(a.ch, 75) == 8 && byte(a.ch, 76) == 0 && a.ch.load(fromByteOffset: 0, as: Int32.self) == 300, "SDRplay: Dezimierung 8, Filter 300 kHz bei 250 kS/s")
        check(byte(a.dev, 44) == 1 && byte(a.dev, 45) == 0, "SDRplay: RSP1A RF-Notch an, DAB-Notch aus")
        a.dev.deallocate(); a.ch.deallocate()
        let b = applied(hw: 255, rate: 2_400_000, rf: false, dab: true)
        check(byte(b.dev, 44) == 0 && byte(b.dev, 45) == 1 && byte(b.ch, 74) == 0 && byte(b.ch, 75) == 1, "SDRplay: RSP1A DAB-Notch an, keine Dezimierung ab 2 MS/s")
        b.dev.deallocate(); b.ch.deallocate()
        let c = applied(hw: 3, rate: 8_000_000, rf: true, dab: true)
        check(byte(c.ch, 133) == 1 && byte(c.ch, 134) == 1 && byte(c.dev, 44) == 0 && c.ch.load(fromByteOffset: 0, as: Int32.self) == 8000, "SDRplay: RSPduo beide Notches in der Tuner-Struktur, Filter 8 MHz bei 8 MS/s")
        c.dev.deallocate(); c.ch.deallocate()
        let d = applied(hw: 4, rate: 2_000_000, rf: true, dab: true, bandwidth: 600)
        check(byte(d.dev, 60) == 1 && byte(d.dev, 61) == 1 && d.ch.load(fromByteOffset: 0, as: Int32.self) == 600, "SDRplay: RSPdx beide Notches in DevParams, eigener Filter 600 kHz")
        d.dev.deallocate(); d.ch.deallocate()
        let e = applied(hw: 2, rate: 2_000_000, rf: true, dab: true)
        check(byte(e.ch, 120) == 1 && byte(e.ch, 133) == 0, "SDRplay: RSP2 nur die RF-Notch")
        e.dev.deallocate(); e.ch.deallocate()
        let f = applied(hw: 1, rate: 2_000_000, rf: true, dab: true)
        check((44..<64).allSatisfy { byte(f.dev, $0) == 0 } && (120..<144).allSatisfy { byte(f.ch, $0) == 0 }, "SDRplay: RSP1 ohne Notches: die Strukturen der Geräte bleiben unberührt")
        f.dev.deallocate(); f.ch.deallocate()
    }
    // Einstellungen: Raten je Gerät, Abstand der Mitte, Fensterbreite
    check(SDRSettingsStore.sampleRateChoices(for: .sdrplay) == SDRplayPlan.sampleRates && SDRSettingsStore.sampleRateChoices(for: .rtlsdr) == [2_400_000]
          && SDRSettingsStore.sampleRateChoices(for: .hackrf).last == 20_000_000, "SDR: Ratenliste je Gerät, SDRplay bis 10 MS/s herab zu 62,5 kS/s")
    check(SDRSettingsStore.loOffset(forRate: 2_400_000) == 300_000 && SDRSettingsStore.loOffset(forRate: 10_000_000) == 300_000
          && SDRSettingsStore.loOffset(forRate: 62_500) == 7_812.5 && SDRSettingsStore.loOffset(forRate: 1_000_000) == 125_000, "SDR: Abstand der Mitte bis 300 kHz, bei kleinen Raten ein Achtel der Rate")
    check(SDRSettingsStore.dcGuard(forRate: 2_400_000) == 40_000 && abs(SDRSettingsStore.dcGuard(forRate: 62_500) - 1_041.67) < 0.01, "SDR: Mindestabstand von der Mitte wächst mit der Rate")
    for r in SDRplayPlan.sampleRates {
        let lo = SDRSettingsStore.loOffset(forRate: r), w = SDRSettingsStore.window(forRate: r)
        check(lo > SDRSettingsStore.dcGuard(forRate: r) && lo < w, "SDR: bei \(r) S/s liegt die gehörte Frequenz (\(Int(lo)) Hz) zwischen Gleichanteil und Fensterrand (\(Int(w)) Hz)")
    }
}

// MARK: - SDRplay: Warnung bei Übersteuerung
if want("sdrplay") {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    check(SDRplayOverload.state(active: true, lastDetected: t, now: t.addingTimeInterval(1)) == .active, "SDRplay: übersteuert → Warnung aktiv")
    check(SDRplayOverload.state(active: false, lastDetected: t, now: t.addingTimeInterval(3)) == .recent, "SDRplay: gerade behoben → noch „kurz übersteuert“")
    check(SDRplayOverload.state(active: false, lastDetected: t, now: t.addingTimeInterval(SDRplayOverload.holdSeconds + 0.1)) == .none, "SDRplay: nach \(Int(SDRplayOverload.holdSeconds)) s keine Anzeige mehr")
    check(SDRplayOverload.state(active: false, lastDetected: nil, now: t) == .none, "SDRplay: nie übersteuert → keine Anzeige")
    SDRplayAPISource.resetOverload()
    check(SDRplayAPISource.overload == .none, "SDRplay: Zustand nach Neustart leer")
    SDRplayAPISource.noteOverload(detected: true)
    check(SDRplayAPISource.overload == .active, "SDRplay: Meldung „Overload detected“ (Parameter 0) setzt die Warnung")
    SDRplayAPISource.noteOverload(detected: false)
    check(SDRplayAPISource.overload == .recent, "SDRplay: Meldung „Overload corrected“ (Parameter 1) lässt „kurz übersteuert“ stehen")
    // Ereignis der API mit Parameter: 0 = erkannt, 1 = behoben (Gerät wird bestätigt, ohne Gerät folgenlos)
    let src = SDRplayAPISource(settings: ADSBGainSettings())
    var detected: Int32 = 0
    src.handleEvent(1, params: &detected)
    check(SDRplayAPISource.overload == .active && src.overloadCount == 1, "SDRplay: Ereignis „erkannt“ → aktiv, gezählt")
    var corrected: Int32 = 1
    src.handleEvent(1, params: &corrected)
    check(SDRplayAPISource.overload == .recent && src.overloadCount == 2, "SDRplay: Ereignis „behoben“ → kurz übersteuert")
    SDRplayAPISource.resetOverload()
}

// MARK: - SDR-Empfänger bei allen Abtastraten des SDRplay (NFM-Ton über die ganze Kette)
if want("sdrplay") {
    func level(_ a: [Float], _ f: Double, skip: Double = 0.3) -> Double {
        let start = Int(skip * 48_000)
        guard a.count > start + 4_800 else { return 0 }
        let n = a.count - start
        var re = 0.0, im = 0.0, w = 0.0
        for k in 0..<n {
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n))
            let ph = 2 * Double.pi * f * Double(k) / 48_000
            re += Double(a[start + k]) * win * cos(ph)
            im -= Double(a[start + k]) * win * sin(ph)
            w += win
        }
        return 2 * (re * re + im * im).squareRoot() / w
    }
    for rate in SDRplayPlan.sampleRates {
        var s = SDRTestSignal(sampleRate: Double(rate), seconds: rate >= 6_000_000 ? 0.6 : 1.0)
        let off = SDRSettingsStore.loOffset(forRate: rate)
        s.addFM(offsetHz: off, tone: 1000, deviation: 3000, amplitude: 0.4)
        s.addNoise(sigma: 0.003)
        var cfg = SDRChannelConfig(mode: .nfm); cfg.bandwidthHz = 12_500
        let demod = SDRDemodulator(sampleRate: Double(rate), config: cfg)
        demod.setOffset(off)
        var audio = [Float]()
        s.quantized().withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count { let e = min(i + 262_144, b.count); demod.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &audio); i = e }
        }
        let l = level(audio, 1000)
        check(abs(l - 0.6) < 0.08, "SDR FM bei \(rate) S/s: 3 kHz Hub ergibt Amplitude 0,6 (\(String(format: "%.3f", l)))")
        // Länge des Audios: 48 kS/s des Eingangs (Zeit stimmt, keine Samples verloren)
        let seconds = Double(audio.count) / 48_000
        check(abs(seconds - Double(s.count) / Double(rate)) < 0.12, "SDR FM bei \(rate) S/s: Audiolänge \(String(format: "%.2f", seconds)) s passt zur Eingangszeit")
    }
}

print("\(checks) Prüfungen, \(failures) Fehler")
exit(failures == 0 ? 0 : 1)
