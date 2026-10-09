// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den YSF-Empfänger: Aufnahme (Diskriminator-Audio) → Rufzeichen, Rahmen → (mit Stick) Ton.

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
    print("Aufruf: ysf_bench.sh <aufnahme.dis|wav> [--port <Anschluss>] [--out ton.wav] [--play]")
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

let slicer = FourFSKSlicer(sampleRate: rate), framer = YSFFramer()
var pcm: [Int16] = []
var seen = Set<String>()
var time = 0.0
var voiceFrames = 0, stickErrors = 0
framer.onEvent = { event in
    switch event {
    case .lost: print(String(format: "%7.2f s  Signal verloren", time))
    case .frame(let f):
        guard let fich = f.fich else { return }
        for t in f.texts {
            let key = "\(fich.fi)/\(t)"
            if seen.insert(key).inserted { print(String(format: "%7.2f s  %@ FN %d: %@", time, ["Kopf", "Kommunikation", "Abschluss", "Test"][fich.fi], fich.fn, "\(t)")) }
        }
        if f.voiceUnsupported { print(String(format: "%7.2f s  Datentyp %d: Sprache nicht unterstützt", time, fich.dt)) }
        for v in f.voice {
            voiceFrames += 1
            if let stick, let frame = VoiceFrame(bytes: v) {
                do { pcm += try stick.decode(frame, profile: .dmr) } catch { stickErrors += 1; pcm += [Int16](repeating: 0, count: VoiceFrame.samplesPerFrame) }
            }
        }
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
print("Zähler: \(framer.stats), Sprachrahmen \(voiceFrames)\(stickErrors > 0 ? ", Stickfehler \(stickErrors)" : "")")
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
