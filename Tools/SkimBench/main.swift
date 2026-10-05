// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// SkimBench: Skimmer (CW, BPSK31/63) an synthetischen Mischungen und an Aufnahmen messen.
//
//   skim_bench.sh synth <cw|psk31|psk63> [--seconds n] [--snr dB] [--thr dB] [--seed n] [--verbose]
//   skim_bench.sh file <aufnahme.wav> <cw|psk31|psk63> [--thr dB] [--from s] [--to s]
import Foundation
import AVFoundation

func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}

/// Kleinster Bearbeitungsabstand des Sendetexts zu irgendeinem Stück des Empfangstexts (Sellers: freier Anfang und freies Ende im Empfang)
func bestMatch(truth: String, decoded: String) -> (cer: Double, found: Bool) {
    let t = Array(truth.uppercased().filter { !$0.isWhitespace })
    let d = Array(decoded.uppercased().filter { !$0.isWhitespace })
    guard !t.isEmpty else { return (1, false) }
    if d.isEmpty { return (1, false) }
    var prev = [Int](repeating: 0, count: d.count + 1)       // Zeile 0: freier Anfang
    var cur = prev
    for i in 1...t.count {
        cur[0] = i
        for j in 1...d.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (t[i - 1] == d[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    let best = prev.min() ?? t.count
    return (Double(best) / Double(t.count), true)
}

func run(engine: SkimmerEngine, audio: [Float], verbose: Bool) -> (channels: [SkimChannelInfo], text: [Int: String]) {
    var texts: [Int: String] = [:]
    engine.onText = { id, s, _ in texts[id, default: ""] += s }
    var i = 0
    audio.withUnsafeBufferPointer { buf in
        while i < buf.count {
            let n = min(400, buf.count - i)
            engine.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    return (engine.channels(), texts)
}

func readWAV(_ path: String) -> [Float]? {
    guard let f = try? AVAudioFile(forReading: path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + path),
                                   commonFormat: .pcmFormatFloat32, interleaved: false),
          let conv = SampleRateConverter(inputRate: f.processingFormat.sampleRate, outputRate: 8000) else { return nil }
    var out: [Float] = []
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 48_000)!
    while true {
        buf.frameLength = 0
        try? f.read(into: buf, frameCount: 48_000)
        guard buf.frameLength > 0 else { break }
        conv.process(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))) { out += Array($0) }
    }
    return out
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("Aufruf: skim_bench.sh synth <cw|psk31|psk63> | file <wav> <modus>")
    exit(2)
}
args.removeFirst()
var thr = 8.0, seconds = 60.0, snrOffset = 0.0, seed: UInt64 = 7, verbose = false, from = 0.0, to = Double.infinity
@MainActor func option(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v }
    return nil
}
if let v = option("--thr") { thr = Double(v) ?? thr }
if let v = option("--seconds") { seconds = Double(v) ?? seconds }
if let v = option("--snr") { snrOffset = Double(v) ?? 0 }
if let v = option("--seed") { seed = UInt64(v) ?? 7 }
if let v = option("--from") { from = Double(v) ?? 0 }
if let v = option("--to") { to = Double(v) ?? .infinity }
if let i = args.firstIndex(of: "--verbose") { verbose = true; args.remove(at: i) }
let dumpPath = option("--dump")
var customSignals: [(Double, Double, Double)] = []        // Hz : WpM : dB
while let v = option("--sig") {
    let p = v.split(separator: ":").compactMap { Double($0) }
    if p.count == 3 { customSignals.append((p[0], p[1], p[2])) }
}

switch cmd {
case "file":
    guard args.count >= 2, var audio = readWAV(args[0]), let mode = SkimMode(rawValue: args[1]) else { print("Datei oder Modus nicht lesbar"); exit(2) }
    let a = Int(from * 8000), b = min(audio.count, to.isFinite ? Int(to * 8000) : audio.count)
    audio = Array(audio[a..<b])
    let e = SkimmerEngine(mode: mode)
    e.config.thresholdDB = thr
    let began = Date()
    let r = run(engine: e, audio: audio, verbose: verbose)
    print(String(format: "%.1f s Audio in %.2f s · %d Kanäle (Spuren %d)", Double(audio.count) / 8000, Date().timeIntervalSince(began), r.channels.count, e.trackCount))
    for c in r.channels {
        let txt = (r.text[c.id] ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        print(String(format: "%7.1f Hz  %5.1f dB  %5.1f %@  %@  q%.2f  %d Z  ", c.frequencyHz, c.snrDB, c.speed, mode == .cw ? "WpM" : "Bd", c.state.rawValue, c.quality, c.characters) + String(txt.suffix(110)))
    }
case "synth":
    guard let mode = args.first.flatMap(SkimMode.init(rawValue:)) else { print("Modus cw|psk31|psk63"); exit(2) }
    struct Sig { var hz: Double; var wpm: Double; var snr: Double; var text: String; var start: Double }
    var sigs: [Sig] = []
    let calls = ["DL1ABC", "OK2XYZ", "F5NZB", "SP9KJ", "HB9TST", "G4WXY", "I2LMN", "OE6ABC", "PA3GOT", "ON4ZZ"]
    if mode == .cw {
        let spec: [(Double, Double, Double)] = !customSignals.isEmpty ? customSignals : [(520, 18, 28), (700, 24, 20), (905, 14, 12), (1130, 30, 25), (1380, 20, 8), (1625, 16, 22), (1890, 26, 15), (2210, 22, 10), (2470, 12, 30)]
        for (i, s) in spec.enumerated() {
            let c = calls[i % calls.count]
            sigs.append(Sig(hz: s.0, wpm: s.1, snr: s.2 + snrOffset, text: "CQ CQ CQ DE \(c) \(c) K CQ DE \(c) PSE K", start: Double(i) * 1.7))
        }
    } else {
        let spec: [(Double, Double)] = !customSignals.isEmpty ? customSignals.map { ($0.0, $0.2) } : [(500, 25), (680, 18), (900, 12), (1150, 22), (1500, 15), (1880, 20)]
        for (i, s) in spec.enumerated() {
            let c = calls[i % calls.count]
            sigs.append(Sig(hz: s.0, wpm: 0, snr: s.1 + snrOffset, text: "CQ CQ CQ DE \(c) \(c) PSE K", start: Double(i) * 1.3))
        }
    }
    let amplitude: Float = 0.08
    let sigma = SkimTestSignal.noiseSigma(snr500: 0, amplitude: amplitude)      // Rauschen für 0 dB; die Amplituden der Signale ergeben dann die SNR
    var parts: [[Float]] = []
    for s in sigs {
        let amp = amplitude * Float(pow(10, s.snr / 20))
        var x = mode == .cw
            ? SkimTestSignal.cw(text: s.text, wpm: s.wpm, toneHz: s.hz, amplitude: amp, leadSeconds: 0, tailSeconds: 0.2)
            : SkimTestSignal.bpsk(text: s.text, mode: mode, carrierHz: s.hz, amplitude: amp)
        // wiederholen, bis die Zeit gefüllt ist
        let single = x
        var reps = 1
        while Double(x.count) < (seconds - s.start) * 8000 { x += [Float](repeating: 0, count: Int(1.5 * 8000)) + single; reps += 1 }
        if verbose { print("Wiederholungen: \(reps) (je \(String(format: "%.1f", Double(single.count) / 8000)) s)") }
        parts.append(SkimTestSignal.delayed(x, seconds: s.start))
    }
    let audio = SkimTestSignal.mix(parts, noise: sigma, seconds: seconds, seed: seed)
    if let d = dumpPath {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + audio.count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16); data.append(contentsOf: Array("data".utf8)); u32(UInt32(audio.count * 2))
        // auf Spitze 0,9 skalieren (starke Signale würden sonst abgeschnitten); der Rauschabstand bleibt gleich
        let peak = max(audio.map { abs($0) }.max() ?? 1, 1e-6)
        var pcm = audio.map { Int16(max(-1, min(1, $0 * 0.9 / peak)) * 32_000) }
        pcm.withUnsafeMutableBytes { data.append(contentsOf: $0) }
        try? data.write(to: URL(fileURLWithPath: d))
    }
    let e = SkimmerEngine(mode: mode)
    e.config.thresholdDB = thr
    let began = Date()
    let r = run(engine: e, audio: audio, verbose: verbose)
    print(String(format: "%.0f s Audio in %.2f s · %d Kanäle, Spuren %d", seconds, Date().timeIntervalSince(began), r.channels.count, e.trackCount))
    var found = 0
    for s in sigs {
        let ch = r.channels.filter { abs($0.frequencyHz - s.hz) < 20 }.min { abs($0.frequencyHz - s.hz) < abs($1.frequencyHz - s.hz) }
        if let c = ch {
            let decoded = r.text[c.id] ?? ""
            let m = bestMatch(truth: s.text, decoded: decoded)
            if c.state == .active { found += 1 }
            if verbose { print("   TEXT: " + decoded.replacingOccurrences(of: "\n", with: " ⏎ ")) }
            print(String(format: "%7.1f Hz %@ %4.0f dB: Kanal %@ %.1f Hz %.1f dB %.1f %@ → CER %.0f %%  ", s.hz, mode == .cw ? String(format: "%2.0f WpM", s.wpm) : "BPSK ", s.snr, c.state.rawValue, c.frequencyHz, c.snrDB, c.speed, mode == .cw ? "WpM" : "Bd", m.cer * 100) + String(decoded.suffix(60)).replacingOccurrences(of: "\n", with: " ⏎ "))
        } else {
            print(String(format: "%7.1f Hz %@ %4.0f dB: kein Kanal", s.hz, mode == .cw ? String(format: "%2.0f WpM", s.wpm) : "BPSK ", s.snr))
        }
    }
    let extra = r.channels.filter { c in !sigs.contains { abs($0.hz - c.frequencyHz) < 20 } }
    print("aktiv gefunden: \(found) von \(sigs.count); zusätzliche Kanäle: \(extra.count)" + (extra.isEmpty ? "" : " " + extra.map { String(format: "%.0f Hz(%@)", $0.frequencyHz, $0.state.rawValue) }.joined(separator: ", ")))
default:
    print("Unbekannt: \(cmd)")
    exit(2)
}
