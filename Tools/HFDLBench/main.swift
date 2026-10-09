// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// HFDL-Prüfstand: liest eine WAV-Aufnahme (16 Bit, mono, 12 kHz, USB-Audio) und gibt die decodierten Rahmen aus.
import Foundation

func readWAV(_ path: String) -> [Float] {
    guard let d = FileManager.default.contents(atPath: path) else { print("Datei fehlt"); exit(1) }
    let b = [UInt8](d)
    var i = 12
    while i + 8 <= b.count {
        let id = String(decoding: b[i..<(i + 4)], as: UTF8.self)
        let n = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
        if id == "data" {
            let cnt = min(n, b.count - i - 8) / 2
            return (0..<cnt).map { Float(Int16(bitPattern: UInt16(b[i + 8 + 2 * $0]) | UInt16(b[i + 9 + 2 * $0]) << 8)) / 32768 }
        }
        i += 8 + n + (n & 1)
    }
    return []
}

let args = Array(CommandLine.arguments.dropFirst())

func writeWAV(_ path: String, _ samples: [Float]) {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(Data("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(12000); u32(24000); u16(2); u16(16)
    d.append(Data("data".utf8)); u32(UInt32(samples.count * 2))
    for s in samples { u16(UInt16(bitPattern: Int16(max(-32767, min(32767, s * 32767))))) }
    FileManager.default.createFile(atPath: path, contents: d)
}

func testPayload() -> [UInt8] {
    HFDLSignalGenerator.downlinkMPDU(station: 4, aircraft: 77, lpdus: [
        HFDLSignalGenerator.frequencyDataLPDU(flight: "DLH400", lat: 50.03, lon: 8.57, seconds: 45296),
        HFDLSignalGenerator.frequencyDataLPDU(flight: "BAW117", lat: -33.9, lon: 151.2, seconds: 3600)
    ])
}

func option(_ name: String, _ def: Double) -> Double {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return def
}

if args.first == "synth" {
    // synth <Betriebsart 0-7> <Ausgabe ohne Endung> [--noise s] [--freqerr hz]
    let mode = Int(args[1]) ?? 0
    let prefix = args[2]
    let payload = testPayload()
    let sym = HFDLSignalGenerator.frameSymbols(payload: payload, mode: mode)
    let seed = UInt64(option("--seed", 1))
    let audio = HFDLSignalGenerator.audio(symbols: sym, freqError: option("--freqerr", 0), noise: option("--noise", 0) / 2.0.squareRoot(), seed: seed)
    writeWAV(prefix + ".wav", audio)
    let bb = HFDLSignalGenerator.baseband(symbols: sym, freqError: option("--freqerr", 0))
    var raw = [Float](); raw.reserveCapacity(bb.count * 2)
    var rng = HFDLSignalGenerator.SplitMix64(seed: seed &+ 100)
    let nz = option("--noise", 0)
    for v in bb { raw.append(Float(v.re + nz * rng.gaussian())); raw.append(Float(v.im + nz * rng.gaussian())) }
    FileManager.default.createFile(atPath: prefix + ".cf32", contents: raw.withUnsafeBufferPointer { Data(buffer: $0) })
    print("Betriebsart \(mode): \(payload.count) Byte Nutzlast, \(audio.count) Abtastwerte -> \(prefix).wav / .cf32 (12 kHz)")
    exit(0)
}

if args.first == "selftest" {
    // Alle 8 Betriebsarten: Rahmen senden, empfangen, Bytes vergleichen; optional mit Rauschen
    let noise = option("--noise", 0), freqErr = option("--freqerr", 0)
    let payload = testPayload()
    var failed = 0
    for mode in 0..<8 {
        let sym = HFDLSignalGenerator.frameSymbols(payload: payload, mode: mode)
        let audio = HFDLSignalGenerator.audio(symbols: sym, freqError: freqErr, noise: noise, seed: UInt64(mode + 1))
        let rx = HFDLReceiver()
        var got: HFDLRawFrame?
        audio.withUnsafeBufferPointer { rx.process($0) { got = $0 } }
        let ok = got.map { Array($0.bytes.prefix(payload.count)) == payload } ?? false
        if !ok { failed += 1 }
        print("Betriebsart \(mode) (\(HFDLPHY.modes[mode].bitRate) bit/s \(HFDLPHY.modes[mode].double ? "doppelt" : "einfach")): " + (ok ? "ok" : "FEHLER") + (got.map { String(format: ", SNR %.1f dB, %+.1f Hz, Versuch %d", $0.snrDB, $0.freqErrorHz, $0.attempt) } ?? ", kein Rahmen") + " [\(rx.stats)]")
    }
    exit(failed == 0 ? 0 : 1)
}

guard let path = args.first else { print("Aufruf: hfdl_bench.sh <wav> [--trace] | synth <modus> <präfix> | selftest"); exit(2) }
let rx = HFDLReceiver()
if args.contains("--trace") { rx.trace = { print("  · " + $0) } }
if let i = args.firstIndex(of: "--noeq") { _ = i; rx.tuning.equalizer = false }
var dumpFrom = 0.0, dumpTo = 0.0
var dumpFile: FileHandle?
if let i = args.firstIndex(of: "--dump"), i + 3 < args.count {
    dumpFrom = Double(args[i + 1]) ?? 0; dumpTo = Double(args[i + 2]) ?? 0
    FileManager.default.createFile(atPath: args[i + 3], contents: nil)
    dumpFile = FileHandle(forWritingAtPath: args[i + 3])
    rx.sampleTap = { n, re, im in
        let t = Double(n) / 5400
        if t >= dumpFrom && t <= dumpTo { dumpFile?.write(Data("\(n) \(re) \(im)\n".utf8)) }
    }
}
let audio = readWAV(path)
print("\(audio.count) Abtastwerte, \(Double(audio.count) / 12000) s")
var frames = 0
var cache = HFDLAircraftCache()
var pstats = HFDLParseStats()
let showEvents = args.contains("--events")
let freqKHz = Double(args.first(where: { $0.hasPrefix("--freq=") })?.dropFirst(7) ?? "21931") ?? 21931
let chunk = 1200
var pos = 0
let t0 = Date()
while pos < audio.count {
    let end = min(audio.count, pos + chunk)
    audio[pos..<end].withUnsafeBufferPointer { buf in
        rx.process(buf) { f in
            frames += 1
            let t = Double(f.startSample) / 12000
            print(String(format: "%7.2f s  %4d bit/s %@  %+6.1f Hz  SNR %5.1f dB  Versuch %d  %d Byte  ", t, f.bitRate, f.doubleSlot ? "D" : "S", f.freqErrorHz, f.snrDB, f.attempt, f.bytes.count)
                  + f.bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))
            if args.contains("--hex") { print("HEX|\(String(format: "%.2f", t))|" + f.bytes.map { String(format: "%02X", $0) }.joined()) }
            if showEvents {
                print("FRAME|\(String(format: "%.2f", t))|\(f.bitRate)")
                for e in HFDLProtocol.parse(f, freqKHz: freqKHz, time: Date(timeIntervalSince1970: 0), cache: &cache, stats: &pstats) {
                    let pos = e.position.map { String(format: "%.3f,%.3f", $0.lat, $0.lon) } ?? "-"
                    let a = e.acars
                    print("EVENT|\(e.uplink ? "UP" : "DOWN")|\(e.title)|\(e.icaoHex ?? "-")|\(e.flightID ?? "-")|\(pos)|\(a?.label ?? "-")|\(a?.registration ?? "-")|\((a?.text ?? "").replacingOccurrences(of: "\n", with: "\\n"))|gs=\(e.station ?? -1)|ac=\(e.aircraftID ?? -1)")
                    for l in e.lines { print("    " + l) }
                }
            }
        }
    }
    pos = end
}
let s = rx.stats
if showEvents { print("Protokoll: \(pstats)") }
print("Rahmen \(frames); Kandidaten \(s.candidates), A2 bestätigt \(s.confirmedA2), M1 erkannt \(s.matchedM1), Bursts \(s.bursts), gut \(s.goodFrames); \(String(format: "%.1f", Date().timeIntervalSince(t0))) s Rechenzeit")
