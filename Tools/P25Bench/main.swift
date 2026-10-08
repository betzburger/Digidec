// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den P25-Empfänger: Aufnahme (Diskriminator-Audio) → Gespräche, Kennungen, Sprachrahmen → (mit Stick) Ton.

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func flag(_ name: String) -> Bool { arguments.firstIndex(of: name).map { arguments.remove(at: $0) } != nil }
func fail(_ text: String) -> Never { print("FEHLER: \(text)"); exit(1) }

let dumpPath = option("--dump")
guard let path = arguments.first else {
    print("Aufruf: p25_bench.sh <aufnahme.dis|wav> [--dump sprachrahmen.bin]")
    exit(2)
}
nonisolated(unsafe) var dumped: [UInt8] = []

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

let receivers = [P25Receiver(sampleRate: rate)]
nonisolated(unsafe) var time = 0.0
nonisolated(unsafe) var voiceFrames = 0
nonisolated(unsafe) var cleanFrames = 0
nonisolated(unsafe) var lastInfo = ""
func handle(_ event: P25Event, _ r: P25Receiver) {
    switch event {
    case .callStart(let nac): print(String(format: "%7.2f s  Aussendung beginnt, NAC 0x%03X%@", time, nac, r.inverted ? " (Pegel umgekehrt)" : ""))
    case .info(let i):
        let text = "NAC \(i.nac.map { String(format: "0x%03X", $0) } ?? "?")  Gruppe \(i.group.map(String.init) ?? "-")  Ziel \(i.target.map(String.init) ?? "-")  Quelle \(i.source.map(String.init) ?? "-")  MFID \(i.manufacturer.map { String(format: "0x%02X", $0) } ?? "-")  Alg \(i.algorithm.map { P25.algorithmName($0) } ?? "-")  Schlüssel \(i.keyID.map { String($0) } ?? "-")  MI \(i.mi ?? "-")\(i.emergency ? "  NOTRUF" : "")"
        if text != lastInfo { print(String(format: "%7.2f s  %@", time, text)); lastInfo = text }
    case .voice(let v):
        voiceFrames += v.frames.count
        cleanFrames += v.cleanFrames
        if v.encrypted { break }
        for f in v.frames { dumped += f }
    case .callEnd(let lost): print(String(format: "%7.2f s  Aussendung endet (%@)", time, lost ? "ohne Endekennung" : "Endekennung"))
    }
}
for r in receivers { r.onEvent = { [unowned r] e in handle(e, r) } }
var index = 0
let chunk = Int(rate / 100)
while index < audio.count {
    let end = min(index + chunk, audio.count)
    let block = Array(audio[index..<end])
    for r in receivers { r.process(block) }
    index = end
    time = Double(index) / rate
}
for r in receivers { print("Zähler: \(r.stats)") }
if let dumpPath { try? Data(dumped).write(to: URL(fileURLWithPath: dumpPath)) }
print("Sprachrahmen \(voiceFrames), ohne Bitfehler \(cleanFrames)")
