// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den TETRA-Empfänger: I/Q-Aufnahme → Zelle, Gespräche, Meldungen, Sprachrahmen; oder Testsender als I/Q-WAV.

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func flag(_ name: String) -> Bool { arguments.firstIndex(of: name).map { arguments.remove(at: $0) } != nil }
func fail(_ text: String) -> Never { print("FEHLER: \(text)"); exit(1) }

func writeWAV(i: [Float], q: [Float], rate: Int, to url: URL) throws {
    var data = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let payload = UInt32(i.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); put32(36 + payload); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(2); put32(UInt32(rate)); put32(UInt32(rate * 4)); put16(4); put16(16)
    data.append(contentsOf: Array("data".utf8)); put32(payload)
    for k in 0..<i.count {
        put16(UInt16(bitPattern: Int16(max(-32767, min(32767, i[k] * 12000)))))
        put16(UInt16(bitPattern: Int16(max(-32767, min(32767, q[k] * 12000)))))
    }
    try data.write(to: url)
}

func readSpeech(_ path: String) -> [[UInt8]] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("\(path) nicht lesbar") }
    var out: [[UInt8]] = []
    d.withUnsafeBytes { raw in
        let w = raw.bindMemory(to: Int16.self)
        for f in 0..<(w.count / 138) { out.append((0..<137).map { UInt8(w[f * 138 + 1 + $0] & 1) }) }
    }
    return out
}

if arguments.first == "synth" {
    arguments.removeFirst()
    guard let outPath = arguments.first else { fail("Ausgabedatei fehlt") }
    let rate = Double(option("--rate") ?? "48000") ?? 48000
    let snr = option("--snr").flatMap(Double.init)
    let offset = Double(option("--offset") ?? "0") ?? 0
    let ppm = Double(option("--ppm") ?? "0") ?? 0
    let frames = Int(option("--frames") ?? "70") ?? 70
    let speech = option("--speech").map(readSpeech) ?? []
    let net = TETRATestNetwork(config: TETRATestNetwork.Config(), speech: speech)
    var bits: [UInt8] = (0..<1020).map { _ in UInt8.random(in: 0...1) }
    for b in net.bursts(frames: frames, callStart: 22, callEnd: frames - 6, stealEvery: 7) { bits += b }
    var (i, q) = TETRAModulator.modulate(bits: bits, sampleRate: rate, offsetHz: offset, clockPPM: ppm)
    if let snr {
        let sigma = Float(pow(10, -snr / 20) / 2.0.squareRoot())
        func gauss() -> Float { (-2 * log(Float.random(in: 1e-7...1))).squareRoot() * cos(2 * .pi * Float.random(in: 0...1)) }
        for k in 0..<i.count { i[k] += sigma * gauss(); q[k] += sigma * gauss() }
    }
    do { try writeWAV(i: i, q: q, rate: Int(rate), to: URL(fileURLWithPath: outPath)) } catch { fail("\(error)") }
    print(String(format: "%@: %.1f s, %.0f Hz, %d TDMA-Rahmen", outPath, Double(i.count) / rate, rate, frames))
    exit(0)
}

let rateOption = option("--rate").flatMap(Double.init)
let center = option("--center").flatMap(Double.init)
let carrier = option("--carrier").flatMap(Double.init) ?? center
let framesPath = option("--frames")
let showEvents = flag("--events")
guard let path = arguments.first else {
    print("Aufruf: tetra_bench.sh <aufnahme> [--rate Hz] [--center MHz] [--carrier MHz] [--frames ausgabe.ser] [--events]  |  synth <aus.wav> …")
    exit(2)
}
let url = URL(fileURLWithPath: path)
guard let file = try? Data(contentsOf: url), file.count > 44 else { fail("\(path) nicht lesbar") }
var rate = rateOption ?? 48000
var offset = 0
var bytesPerSample = 1
if url.pathExtension.lowercased() == "wav" {
    rate = rateOption ?? Double(Int(file[24]) | Int(file[25]) << 8 | Int(file[26]) << 16 | Int(file[27]) << 24)
    var pos = 12
    while pos + 8 <= file.count {
        let id = String(decoding: file[pos..<(pos + 4)], as: UTF8.self)
        let size = Int(file[pos + 4]) | Int(file[pos + 5]) << 8 | Int(file[pos + 6]) << 16 | Int(file[pos + 7]) << 24
        if id == "fmt " { bytesPerSample = Int(file[pos + 22]) / 8 }
        if id == "data" { offset = pos + 8; break }
        pos += 8 + size + (size & 1)
    }
} else if url.pathExtension.lowercased() == "cs16" { bytesPerSample = 2 }
let count = (file.count - offset) / (2 * bytesPerSample)
var peak = 1
if bytesPerSample == 2 {
    file.withUnsafeBytes { raw in
        for k in 0..<min(2 * count, 400_000) { peak = max(peak, abs(Int(raw.loadUnaligned(fromByteOffset: offset + 2 * k, as: Int16.self)))) }
    }
}
var bytes = [UInt8](repeating: 128, count: 2 * count)
file.withUnsafeBytes { raw in
    for k in 0..<(2 * count) {
        if bytesPerSample == 2 { bytes[k] = UInt8(max(0, min(255, (Double(raw.loadUnaligned(fromByteOffset: offset + 2 * k, as: Int16.self)) * 100.0 / Double(peak) + 128).rounded()))) }
        else { bytes[k] = raw[offset + k] }
    }
}
let f = (carrier ?? 400) * 1e6
let engine = TETRAEngine()
engine.configure(sampleRate: Int(rate), centerFrequency: (center ?? carrier ?? 400) * 1e6, frequencies: [f], countClipping: false)
var pos = 0
while pos < count {
    let m = min(32768, count - pos)
    bytes.withUnsafeBufferPointer { b in engine.feed(UnsafeBufferPointer(rebasing: b[(2 * pos)..<(2 * (pos + m))]), wait: true) }
    pos += m
}
Thread.sleep(forTimeInterval: 0.3)
let s = engine.snapshot()
print(String(format: "%@: %.1f s, %.0f Hz", url.lastPathComponent, Double(count) / rate, rate))
for c in s.channels {
    print(String(format: "Träger %.4f MHz: synchron %@%@, Versatz %+.0f Hz, Sync-Bursts %d, normale Bursts %d, CRC gut/schlecht %d/%d, Verkehrsblöcke %d, Zeit %@",
                 c.frequency / 1e6, c.locked ? "ja" : "nein", c.inverted ? " (I/Q vertauscht)" : "", c.offsetHz, c.syncBursts, c.normalBursts, c.crcOK, c.crcBad, c.trafficBlocks, c.tetraTime))
    if let sy = c.sync { print("  Zelle: MCC \(sy.mcc) MNC \(sy.mnc) Farbcode \(sy.colourCode)") }
}
if let n = s.network {
    print(String(format: "Netz: Träger %.4f MHz, Standortbereich %d, Dienste 0x%03X%@", n.downlinkHz / 1e6, n.locationArea, n.serviceDetails, n.airEncryption ? ", Luftverschlüsselung" : ""))
}
for c in s.calls {
    print("Gespräch: an \(c.target.map(String.init) ?? "?") von \(c.caller.map(String.init) ?? "?") Sprecher \(c.speakers.map(String.init).joined(separator: ",")) Marke \(c.usageMarker) TS \(c.timeslot ?? 0) Rahmen \(c.frames) fehlerhaft \(c.badFrames) ersetzt \(c.missingFrames)\(c.encrypted ? " VERSCHLÜSSELT" : "")\(c.suspect ? " (gestört?)" : "")")
}
print("Teilnehmer: " + s.subscribers.sorted { $0.ssi < $1.ssi }.map { "\($0.ssi)" }.joined(separator: " "))
if showEvents { for e in s.events { print("\(e.tetraTime) \(e.kind) \(e.text)") } }
if let framesPath {
    var out = Data()
    for c in s.calls {
        for chunk in c.audio {
            var words = [Int16](repeating: 0, count: 138)
            words[0] = chunk.badFrame ? 1 : 0
            for k in 0..<137 { words[1 + k] = Int16(chunk.bits[k]) }
            words.withUnsafeBytes { out.append(contentsOf: $0) }
        }
    }
    try? out.write(to: URL(fileURLWithPath: framesPath))
    print("Sprachrahmen: \(out.count / 276) → \(framesPath)")
}
