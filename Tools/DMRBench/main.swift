// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den DMR-Empfänger: Aufnahme (Diskriminator-Audio) → Gespräche je Zeitschlitz, IDs, Zähler → (mit Stick) Ton.

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
let audioSlot = (Int(option("--slot") ?? "2") ?? 2) - 1
guard let path = arguments.first, (0...1).contains(audioSlot) else {
    print("Aufruf: dmr_bench.sh <aufnahme.dis|wav> [--slot 1|2] [--port <Anschluss>] [--out ton.wav] [--play]")
    exit(2)
}

nonisolated(unsafe) var stick: AMBE3000Stick?
if let port {
    do { stick = try AMBE3000Stick(path: port); print("Stick: \(stick!.name), Ton aus Zeitschlitz \(audioSlot + 1)") } catch { fail("Stick \(port): \(error)") }
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

let slicer = FourFSKSlicer(sampleRate: rate), framer = DMRFramer()
var pcm: [Int16] = []
var time = 0.0
var voice = [0, 0]
var seen = Set<String>()
var stickErrors = 0
func describe(_ lc: DMRLinkControl) -> String {
    "\(lc.isPrivateCall ? "Einzelruf" : lc.isGroupCall ? "Gruppenruf" : "FLCO \(lc.flco)") Ziel \(lc.destination) Quelle \(lc.source)"
}
framer.onEvent = { event in
    switch event {
    case .callStart(let slot, let cc, let lc):
        print(String(format: "%7.2f s  ZS %d  Gespräch beginnt, Farbcode %@, %@", time, slot + 1, cc.map(String.init) ?? "?", lc.map(describe) ?? "ohne Kopf (später Einstieg)"))
    case .linkControl(let slot, let lc):
        let key = "\(slot)/\(lc.flco)/\(lc.destination)/\(lc.source)"
        if seen.insert(key).inserted { print(String(format: "%7.2f s  ZS %d  Link Control: %@", time, slot + 1, describe(lc))) }
    case .callEnd(let slot, let lc, let lost):
        print(String(format: "%7.2f s  ZS %d  Gespräch endet (%@)%@", time, slot + 1, lost ? "ohne Abschluss" : "Abschluss", lc.map { " " + describe($0) } ?? ""))
    case .voice(let burst):
        voice[burst.slot] += 1
        if burst.slot == audioSlot, let stick {
            for bytes in burst.frames {
                guard let frame = VoiceFrame(bytes: bytes) else { continue }
                do { pcm += try stick.decode(frame, profile: .dmr) } catch { stickErrors += 1; pcm += [Int16](repeating: 0, count: VoiceFrame.samplesPerFrame) }
            }
        }
    case .data(let slot, let type, let cc):
        let key = "Daten \(slot)/\(type.title)/\(cc)"
        if seen.insert(key).inserted { print(String(format: "%7.2f s  ZS %d  Datenburst %@ (Farbcode %d)", time, slot + 1, type.title, cc)) }
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
print("Sprachbursts je Zeitschlitz: \(voice[0]) / \(voice[1]), Sprachrahmen ohne Bitfehler \(s.cleanFrames) von \(s.frames), eingebettete Information \(s.embeddedLC), Leerlauf \(s.idleBursts)\(stickErrors > 0 ? ", Stickfehler \(stickErrors)" : "")")
print("Zähler: \(s)")
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
