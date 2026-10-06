// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den M17-Empfänger: Aufnahme (Diskriminator-Audio) → Gespräche, LSF, Zähler → (mit --out) Sprache als WAV.

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func fail(_ text: String) -> Never { print("FEHLER: \(text)"); exit(1) }

let outPath = option("--out")
guard let path = arguments.first else {
    print("Aufruf: m17_bench.sh <aufnahme.dis|wav> [--out sprache.wav]")
    exit(2)
}

let url = URL(fileURLWithPath: path)
var audio: [Float]
var rate = 48000.0
if path.hasSuffix(".wav"), let wav = try? VoiceWAV.read(url) {
    audio = wav.samples.map { Float($0) / 32768 }
    rate = Double(wav.sampleRate)
} else {
    guard let data = try? Data(contentsOf: url) else { fail("\(path) nicht lesbar") }
    audio = data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
}
print(String(format: "%@: %.1f s, %.0f Hz", url.lastPathComponent, Double(audio.count) / rate, rate))

let slicer = FourFSKSlicer(sampleRate: rate), framer = M17Framer()
var time = 0.0
var pcm: [Int16] = []
var lsf: M17LSF?
var voice = M17Voice()!
var frames = 0
var errorSum: Float = 0
func describe(_ l: M17LSF) -> String {
    var s = "\(l.sourceName) → \(l.destinationName), CAN \(l.channelAccessNumber), \(l.payloadText)"
    if l.isEncrypted { s += ", \(l.encryptionText)" }
    switch l.content {
    case .text(let n, let total, let text): s += ", Text \(n)/\(total) „\(text)“"
    case .position(let la, let lo, _, _, _, let st): s += String(format: ", Position %.4f %.4f (%@)", la, lo, st)
    case .extendedCallsign(let a, let b): s += ", CF1 \(a)" + (b.map { " CF2 \($0)" } ?? "")
    default: break
    }
    return s
}
framer.onEvent = { event in
    switch event {
    case .callStart:
        print(String(format: "%7.2f s  Gespräch beginnt", time))
        voice = M17Voice()!
        lsf = nil
    case .lsf(let l, let viaLICH):
        lsf = l
        print(String(format: "%7.2f s  LSF%@: %@", time, viaLICH ? " (aus LICH)" : "", describe(l)))
    case .frame(let f):
        frames += 1
        errorSum += f.errorRate
        if let l = lsf, l.isVoice, !l.isEncrypted, f.frameNumber < 0x7FFC, f.errorRate <= 0.2 { pcm += voice.decode(payload: f.payload, full: l.payload == .voice3200) }
        else if outPath != nil { pcm += [Int16](repeating: 0, count: 320) }
    case .callEnd(let lost):
        print(String(format: "%7.2f s  Gespräch endet (%@)", time, lost ? "ohne Ende-Kennung" : "Ende-Kennung"))
    case .lost:
        print(String(format: "%7.2f s  Signal verloren", time))
    }
}
slicer.onSymbol = { framer.push(symbol: $0) }
var index = 0
let chunk = Int(rate / 100)
while index < audio.count {
    let end = min(index + chunk, audio.count)
    slicer.process(Array(audio[index..<end]))
    index = end
    time = Double(index) / rate
}
let s = framer.stats
print("Synchronisationen \(s.syncs), Strom-Rahmen \(s.streamFrames), LSF-Rahmen \(s.lsfFrames), LSF aus LICH \(s.lsfFromLICH), nicht lesbar \(s.badFrames), LSF-Prüfsumme \(s.lsfBad), Ende-Kennungen \(s.endMarkers), Verluste \(s.lost), Gespräche \(s.calls)")
if frames > 0 { print(String(format: "mittlere Bitfehlerrate %.1f %%", Double(errorSum) / Double(frames) * 100)) }
if let outPath {
    do { try VoiceWAV.write(pcm, sampleRate: 8000, to: URL(fileURLWithPath: outPath)); print("Sprache: \(outPath) (\(pcm.count / 8000) s)") } catch { fail("\(outPath): \(error)") }
}
