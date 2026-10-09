// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den dPMR-Empfänger: Aufnahme (Diskriminator-Audio) → Gespräche, Kennungen, Sprachrahmen → (mit Stick) Ton.

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func flag(_ name: String) -> Bool { arguments.firstIndex(of: name).map { arguments.remove(at: $0) } != nil }
func fail(_ text: String) -> Never { print("FEHLER: \(text)"); exit(1) }

let port = option("--port")
let outPath = option("--out")
let play = flag("--play")
guard let path = arguments.first else {
    print("Aufruf: dpmr_bench.sh <aufnahme.dis|wav> [--port <Anschluss>] [--out ton.wav] [--play]")
    exit(2)
}

nonisolated(unsafe) var stick: AMBE3000Stick?
if let port {
    do { stick = try AMBE3000Stick(path: port); print("Stick: \(stick!.name)") } catch { fail("Stick \(port): \(error)") }
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

let framer = DPMRReceiver(sampleRate: rate)
var pcm: [Int16] = []
var time = 0.0
var voiceFrames = 0, stickErrors = 0
var lastInfo = ""
framer.onEvent = { event in
    switch event {
    case .callStart: print(String(format: "%7.2f s  Gespräch beginnt%@", time, framer.inverted ? " (Pegel umgekehrt)" : ""))
    case .info(let called, let calling, let cc, let emergency):
        let text = "gerufen \(called ?? "?")  rufend \(calling ?? "?")  Kanalcode \(cc.map(String.init) ?? "?")\(emergency ? "  NOTRUF" : "")"
        if text != lastInfo { print(String(format: "%7.2f s  %@", time, text)); lastInfo = text }
    case .voice(let v):
        voiceFrames += v.frames.count
        if v.scrambled { break }
        if let stick {
            for bytes in v.frames {
                guard let frame = VoiceFrame(bytes: bytes) else { continue }
                do { pcm += try stick.decode(frame, profile: .dmr) } catch { stickErrors += 1; pcm += [Int16](repeating: 0, count: VoiceFrame.samplesPerFrame) }
            }
        }
    case .callEnd(let lost): print(String(format: "%7.2f s  Gespräch endet (%@)", time, lost ? "ohne Endekennung" : "Endekennung"))
    }
}
var index = 0
let chunk = Int(rate / 100)
while index < audio.count {
    let end = min(index + chunk, audio.count)
    framer.process(Array(audio[index..<end]))
    index = end
    time = Double(index) / rate
}
let s = framer.stats
print("Zähler: \(s), Sprachrahmen \(voiceFrames)\(stickErrors > 0 ? ", Stickfehler \(stickErrors)" : "")")
if !pcm.isEmpty {
    print(String(format: "Ton: %.1f s", Double(pcm.count) / 8000))
    if let outPath { do { try VoiceWAV.write(pcm, to: URL(fileURLWithPath: outPath)); print("geschrieben: \(outPath)") } catch { fail("\(outPath): \(error)") } }
    if play {
        let player = VoicePlayer()
        do { try player.start() } catch { fail("Wiedergabe: \(error)") }
        player.enqueue(pcm)
        Thread.sleep(forTimeInterval: Double(pcm.count) / 8000 + 0.5)
        player.stop()
    }
}
