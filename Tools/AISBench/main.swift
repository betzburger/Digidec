// AIS-Prüfstand: decodiert FM-Diskriminator-Audio (WAV) mit dem Empfänger der App, erzeugt Testsignale und rechnet I/Q in Diskriminator-Audio um.
//   ais_bench.sh <aufnahme.wav> [--nmea] [--channel 0|1]          decodieren (jede Abtastrate, wird auf 48 kHz gewandelt)
//   ais_bench.sh fm <iq.wav> <audio.wav> [--shift hz] [--gain g]  I/Q-WAV (stereo) → Diskriminator-Audio 48 kHz (±2,4 kHz Hub = ±0,3)
//   ais_bench.sh synth <prefix> [--noise s] [--seed n] [--count n]  Testsignal (.wav) und erwartete Sätze (.nmea)
//   ais_bench.sh selftest [--noise s]                              Senden und Empfangen in einem Zug
//   ais_bench.sh info <mmsi> [imo] [rufzeichen] [name]             Schiffsdaten aus dem Netz (Wikidata, Wikimedia Commons)
import Foundation

struct WAV { var rate: Double; var channels: Int; var data: [Float] }

func readWAV(_ path: String) -> WAV {
    guard let d = FileManager.default.contents(atPath: path) else { print("Datei fehlt: \(path)"); exit(1) }
    let b = [UInt8](d)
    var i = 12
    var rate = 48_000.0, ch = 1, bits = 16, fmt = 1
    while i + 8 <= b.count {
        let id = String(decoding: b[i..<(i + 4)], as: UTF8.self)
        let n = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
        if id == "fmt " {
            fmt = Int(b[i + 8]) | Int(b[i + 9]) << 8
            ch = Int(b[i + 10]) | Int(b[i + 11]) << 8
            rate = Double(Int(b[i + 12]) | Int(b[i + 13]) << 8 | Int(b[i + 14]) << 16 | Int(b[i + 15]) << 24)
            bits = Int(b[i + 22]) | Int(b[i + 23]) << 8
        } else if id == "data" {
            let avail = min(n, b.count - i - 8)
            var out: [Float] = []
            if fmt == 3 && bits == 32 {
                out = (0..<(avail / 4)).map { k in
                    let u = UInt32(b[i + 8 + 4 * k]) | UInt32(b[i + 9 + 4 * k]) << 8 | UInt32(b[i + 10 + 4 * k]) << 16 | UInt32(b[i + 11 + 4 * k]) << 24
                    return Float(bitPattern: u)
                }
            } else {
                out = (0..<(avail / 2)).map { Float(Int16(bitPattern: UInt16(b[i + 8 + 2 * $0]) | UInt16(b[i + 9 + 2 * $0]) << 8)) / 32768 }
            }
            return WAV(rate: rate, channels: ch, data: out)
        }
        i += 8 + n + (n & 1)
    }
    print("keine Daten"); exit(1)
}

func writeWAV(_ path: String, _ samples: [Float], rate: Int = 48_000) {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(Data("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(Data("data".utf8)); u32(UInt32(samples.count * 2))
    for s in samples { u16(UInt16(bitPattern: Int16(max(-32767, min(32767, s * 32767))))) }
    FileManager.default.createFile(atPath: path, contents: d)
}

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ def: Double) -> Double {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return def
}

/// Abwechslungsreiche Testnachrichten
func testPayloads(_ count: Int, seed: UInt64) -> [[UInt8]] {
    var rng = AISSignalGenerator.RNG(seed: seed)
    var out: [[UInt8]] = []
    for k in 0..<count {
        let mmsi = UInt32(200_000_000 + Int(rng.uniform() * 570_000_000))
        let lat = 40 + rng.uniform() * 20, lon = -5 + rng.uniform() * 30
        switch k % 6 {
        case 0, 1, 2: out.append(AISSignalGenerator.positionReport(mmsi: mmsi, lat: lat, lon: lon, sog: rng.uniform() * 20, cog: rng.uniform() * 359, heading: Int(rng.uniform() * 359), navStatus: Int(rng.uniform() * 8), second: Int(rng.uniform() * 59)))
        case 3: out.append(AISSignalGenerator.staticVoyage(mmsi: mmsi, imo: UInt32(9_000_000 + Int(rng.uniform() * 999_999)), callsign: "DABC\(k % 10)", name: "TESTSCHIFF \(k)", shipType: 70, bow: 120, stern: 40, port: 10, starboard: 12, draught: 8.5, destination: "HAMBURG", etaMonth: 10, etaDay: 12, etaHour: 14, etaMinute: 30))
        case 4: out.append(AISSignalGenerator.classBPosition(mmsi: mmsi, lat: lat, lon: lon, sog: rng.uniform() * 8, cog: rng.uniform() * 359))
        default: out.append(AISSignalGenerator.aidToNavigation(mmsi: 992_110_000 + UInt32(k), type: 20, name: "TONNE \(k)", lat: lat, lon: lon))
        }
    }
    return out
}

func decode(_ audio: [Float], rate: Double = 48_000) -> (frames: [AISReceiver.Decoded], stats: AISStats, seconds: Double) {
    let rx = AISReceiver(sampleRate: rate)
    var frames: [AISReceiver.Decoded] = []
    rx.onFrame = { frames.append($0) }
    let t0 = Date()
    var i = 0
    while i < audio.count {
        let n = min(960, audio.count - i)
        audio.withUnsafeBufferPointer { rx.process(UnsafeBufferPointer(start: $0.baseAddress! + i, count: n)) }
        i += n
    }
    return (frames, rx.stats, Date().timeIntervalSince(t0))
}

if args.first == "fm" {
    // fm <iq.wav> <audio.wav>
    let w = readWAV(args[1])
    guard w.channels == 2 else { print("I/Q-WAV muss stereo sein"); exit(1) }
    let shift = option("--shift", 0), gain = option("--gain", 1)
    let n = w.data.count / 2
    var prev = (re: 1.0, im: 0.0)
    var out = [Float](repeating: 0, count: n)
    var ph = 0.0
    for k in 0..<n {
        var re = Double(w.data[2 * k]), im = Double(w.data[2 * k + 1])
        if shift != 0 {
            let c = cos(ph), s = sin(ph)
            (re, im) = (re * c - im * s, re * s + im * c)
            ph += 2 * Double.pi * shift / w.rate
        }
        // Phasendifferenz = Momentanfrequenz
        let dre = re * prev.re + im * prev.im, dim = im * prev.re - re * prev.im
        let f = atan2(dim, dre) / (2 * Double.pi) * w.rate        // Hz
        out[k] = Float(f / 2400 * 0.3 * gain)
        prev = (re, im)
    }
    // auf 48 kHz bringen
    var res = out
    if abs(w.rate - 48_000) > 1, let conv = SampleRateConverter(inputRate: w.rate, outputRate: 48_000) {
        res = []
        out.withUnsafeBufferPointer { conv.process($0) { res += Array($0) } }
    }
    writeWAV(args[2], res)
    print("\(res.count) Abtastwerte -> \(args[2])")
    exit(0)
}

if args.first == "synth" {
    let count = Int(option("--count", 20)), seed = UInt64(option("--seed", 1))
    let payloads = testPayloads(count, seed: seed)
    var rng = AISSignalGenerator.RNG(seed: seed &+ 7)
    var bursts: [AISSignalGenerator.Burst] = []
    var nmea: [String] = []
    for (k, p) in payloads.enumerated() {
        // Abstand: ganze Zeitschlitze (26,67 ms), zufällig 3 bis 12 Schlitze
        let start = 0.2 + Double(k) * 0.22 + rng.uniform() * 0.1
        bursts.append(.init(payload: p, start: start, offset: Float((rng.uniform() - 0.5) * 0.12), polarity: rng.uniform() < 0.5 ? 1 : -1,
                            ppm: (rng.uniform() - 0.5) * 200))
        nmea += AISNMEA.sentences(for: p, channel: "A")
    }
    let audio = AISSignalGenerator.audio(bursts: bursts, duration: 0.5 + Double(count) * 0.24, noise: Float(option("--noise", 0)), seed: seed)
    writeWAV(args[1] + ".wav", audio)
    try? nmea.joined(separator: "\n").appending("\n").write(toFile: args[1] + ".nmea", atomically: true, encoding: .utf8)
    print("\(count) Bursts -> \(args[1]).wav / .nmea")
    exit(0)
}

if args.first == "demo" {
    // demo <ausgabe.nmea>: ein paar bekannte Schiffe in der Deutschen Bucht (für Schnappschüsse der App, DIGIDEC_AIS_NMEA)
    let ships: [(UInt32, UInt32, String, String, Int, Int, Int, Int, Int, Double, String, Double, Double, Double, Double)] = [
        (310627000, 9241061, "ZCEF6", "QUEEN MARY 2", 60, 345, 0, 20, 21, 10.3, "HAMBURG", 53.97, 8.55, 8.3, 101),
        (255806000, 9703291, "3FBT7", "MSC OSCAR", 71, 380, 15, 30, 29, 16.0, "ROTTERDAM", 54.15, 7.4, 17.5, 268),
        (211000001, 0, "DABC", "TESTBOOT", 36, 8, 2, 2, 1, 1.2, "HELGOLAND", 54.10, 8.0, 5.2, 295)]
    var lines: [String] = []
    for s in ships {
        lines += AISNMEA.sentences(for: AISSignalGenerator.positionReport(mmsi: s.0, lat: s.11, lon: s.12, sog: s.13, cog: s.14, heading: Int(s.14)), channel: "A")
        lines += AISNMEA.sentences(for: AISSignalGenerator.staticVoyage(mmsi: s.0, imo: s.1, callsign: s.2, name: s.3, shipType: s.4, bow: s.5 - s.6, stern: s.6, port: s.7, starboard: s.8, draught: s.9, destination: s.10, etaMonth: 10, etaDay: 5, etaHour: 14, etaMinute: 0), channel: "A", sequence: 1)
    }
    lines += AISNMEA.sentences(for: AISSignalGenerator.aidToNavigation(mmsi: 992_110_005, type: 20, name: "ELBE 1", lat: 54.0, lon: 8.1))
    try? lines.joined(separator: "\n").appending("\n").write(toFile: args[1], atomically: true, encoding: .utf8)
    print("\(lines.count) Sätze -> \(args[1])")
    exit(0)
}

if args.first == "info" {
    let q = ShipQuery(mmsi: UInt32(args[1]) ?? 0, imo: args.count > 2 ? UInt32(args[2]).flatMap { $0 > 0 ? $0 : nil } : nil,
                      callsign: args.count > 3 && args[3] != "-" ? args[3] : nil, name: args.count > 4 ? args[4] : nil)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        await ShipInfoService.shared.forget(q)
        let info = await ShipInfoService.shared.lookup(q, useCache: false)
        print("Treffer: \(info.matchedBy ?? "–") \(info.entityID ?? "") \(info.title ?? "") – \(info.summary ?? "")")
        for f in info.facts { print("  \(f.label): \(f.value)") }
        print("Bild: \(info.imageURL ?? "–")  (\(info.imageSource ?? "")) \(info.imageCredit ?? "")")
        print("Wikipedia: \(info.wikipediaURL ?? "–")\n  \(info.extract?.prefix(200) ?? "")")
        for n in info.notes { print("Hinweis: \(n)") }
        for l in ShipLinks.links(for: q) { print("Link: \(l.title) \(l.url)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if args.first == "selftest" {
    let noise = Float(option("--noise", 0))
    var total = 0, got = 0, extra = 0
    for seed in 1...Int(option("--runs", 5)) {
        let payloads = testPayloads(40, seed: UInt64(seed))
        var rng = AISSignalGenerator.RNG(seed: UInt64(seed) &+ 99)
        var bursts: [AISSignalGenerator.Burst] = []
        for (k, p) in payloads.enumerated() {
            bursts.append(.init(payload: p, start: 0.2 + Double(k) * 0.12 + rng.uniform() * 0.05, offset: Float((rng.uniform() - 0.5) * 0.12),
                                polarity: rng.uniform() < 0.5 ? 1 : -1, ppm: (rng.uniform() - 0.5) * 200))
        }
        let audio = AISSignalGenerator.audio(bursts: bursts, duration: 0.5 + 40 * 0.13, noise: noise, seed: UInt64(seed))
        let r = decode(audio)
        let want = Set(payloads.map { $0 })
        let have = Set(r.frames.map(\.bits))
        total += payloads.count
        got += want.intersection(have).count
        extra += have.subtracting(want).count
        for f in r.frames where !want.contains(f.bits) {
            let m = AISMessage.decode(AISBits(f.bits))
            print("  unerwartet (Lauf \(seed)): t=\(String(format: "%.3f", f.time)) Typ \(AISBits(f.bits).u(0, 6)) MMSI \(m?.mmsi ?? 0) Länge \(f.bits.count) gerettet=\(f.rescued)")
        }
    }
    print(String(format: "Rauschen %.3f: %d von %d Rahmen gelesen (%.1f %%), %d unerwartete", noise, got, total, 100 * Double(got) / Double(total), extra))
    exit(got == total && extra == 0 ? 0 : 1)
}

// Standard: Datei decodieren
guard let path = args.first(where: { !$0.hasPrefix("--") && FileManager.default.fileExists(atPath: $0) }) else { print("Aufruf: ais_bench.sh <aufnahme.wav> | fm | synth | selftest"); exit(1) }
let w = readWAV(path)
let ch = Int(option("--channel", 0))
var mono = w.channels == 1 ? w.data : stride(from: ch, to: w.data.count, by: w.channels).map { w.data[$0] }
if abs(w.rate - 48_000) > 1, let conv = SampleRateConverter(inputRate: w.rate, outputRate: 48_000) {
    var res: [Float] = []
    mono.withUnsafeBufferPointer { conv.process($0) { res += Array($0) } }
    mono = res
}
let r = decode(mono)
let sec = Double(mono.count) / 48_000
for f in r.frames {
    let s = AISNMEA.sentences(for: f.bits, channel: "A").joined(separator: "\n")
    if args.contains("--nmea") { print(s) }
    else if let m = AISMessage.decode(AISBits(f.bits)) {
        print(String(format: "%7.2f s  Typ %2d  MMSI %09d  %@%@  %@", f.time, m.type, m.mmsi,
                     m.latitude.map { String(format: "%.4f,%.4f ", $0, m.longitude ?? 0) } ?? "", m.sog.map { String(format: "%.1f kn ", $0) } ?? "", m.name ?? m.destination ?? ""))
    } else {
        print(String(format: "%7.2f s  Typ %2d (nicht ausgewertet)", f.time, Int(AISBits(f.bits).u(0, 6))))
    }
}
print(String(format: "%d Rahmen in %.1f s Audio (%d Burst-Treffer, %d ohne Rahmen, %d gerettet), Rechenzeit %.2f s (%.0f× Echtzeit)",
             r.stats.frames, sec, r.stats.bursts, r.stats.failed, r.stats.rescued, r.seconds, sec / max(r.seconds, 1e-6)))
