// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den D-Star-Empfänger: Aufnahme (Diskriminator-Audio) → Kopf, Langsamdaten, Sprachrahmen → (mit Stick) Ton.

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
/// Gegenprobe: Bits jedes AMBE-Bytes umdrehen (falsche Bitreihenfolge muss Rauschen ergeben)
let reverseBits = flag("--bitrev")
let noise = Float(option("--noise") ?? "0") ?? 0
let text = option("--text") ?? "Hallo aus Wuerzburg"
let profile = VoiceProfile(rawValue: option("--profile") ?? "dstar") ?? .dstar
guard !arguments.isEmpty else {
    print("Aufruf: dstar_bench.sh <aufnahme.dis|wav> [--port <Anschluss>] [--out ton.wav] [--play]\n        dstar_bench.sh synth <aus.wav> [--noise s] [--text …] [--port <Anschluss>]")
    exit(2)
}

nonisolated(unsafe) var stick: AMBE3000Stick?
if let port {
    do { stick = try AMBE3000Stick(path: port); print("Stick: \(stick!.name)") } catch { fail("Stick \(port): \(error)") }
}

func readAudio(_ path: String) -> (samples: [Float], rate: Double) {
    let url = URL(fileURLWithPath: path)
    if path.hasSuffix(".wav"), let wav = try? VoiceWAV.read(url) { return (wav.samples.map { Float($0) / 32768 }, Double(wav.sampleRate)) }
    guard let data = try? Data(contentsOf: url) else { fail("\(path) nicht lesbar") }
    let samples = data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
    return (samples, 48000)
}

func decode(_ audio: [Float], rate: Double) {
    let slicer = DStarBitSlicer(sampleRate: rate), framer = DStarFramer()
    var slow = DStarSlowData()
    var pcm: [Int16] = []
    var frames = 0
    var time = 0.0
    var failures = 0
    framer.onEvent = { event in
        switch event {
        case .header(let h, let ok):
            print(String(format: "%7.2f s  KOPF %@  RPT2 %@  RPT1 %@  UR %@  MY %@ %@  Kennzeichen %02X%02X%02X%@", time, ok ? "ok    " : "FEHLER", h.repeater2, h.repeater1, h.yourCall, h.myCall, h.myCall2, h.flag1, h.flag2, h.flag3, framer.inverted ? "  (Pegel umgekehrt)" : ""))
            if ok { slow.reset() }
        case .voice(let frame):
            frames += 1
            if frame.index > 0, slow.add(frameIndex: frame.index, bytes: frame.slowData) {
                var parts: [String] = []
                if let m = slow.message { parts.append("Text „\(m)“") }
                if let h = slow.header { parts.append("Kopf-Wiederholung \(h.myCall) \(h.myCall2) über \(h.repeater1)") }
                if let p = slow.position { parts.append(String(format: "Position %@ %.4f %.4f %@", p.callsign, p.latitude, p.longitude, p.comment)) }
                print(String(format: "%7.2f s  Langsamdaten: %@", time, parts.joined(separator: "; ")))
            }
            let ambe = reverseBits ? frame.ambe.map { b in (0..<8).reduce(UInt8(0)) { $0 | (((b >> UInt8($1)) & 1) << UInt8(7 - $1)) } } : frame.ambe
            if let stick, let vf = VoiceFrame(bytes: ambe) {
                do { pcm += try stick.decode(vf, profile: profile) } catch { failures += 1; pcm += [Int16](repeating: 0, count: VoiceFrame.samplesPerFrame) }
            }
        case .end: print(String(format: "%7.2f s  ENDE nach %d Rahmen (%.1f s Sprache)", time, frames, Double(frames) * 0.02)); frames = 0
        case .lost: print(String(format: "%7.2f s  SIGNAL VERLOREN nach %d Rahmen", time, frames)); frames = 0
        }
    }
    slicer.onBit = { framer.push(bit: $0, soft: $1) }
    var index = 0
    let chunk = Int(rate / 100)
    while index < audio.count {
        let end = min(index + chunk, audio.count)
        slicer.process(Array(audio[index..<end]))
        index = end
        time = Double(index) / rate
    }
    print("Zähler: \(framer.stats)\(failures > 0 ? ", Stickfehler \(failures)" : "")")
    guard !pcm.isEmpty else { return }
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

if arguments[0] == "synth" {
    guard arguments.count >= 2 else { fail("synth braucht eine Ausgabedatei") }
    // Sprache: Text → (macOS `say` ist hier nicht verfügbar) einfache Folge aus der Eingabedatei oder Stille
    var frames: [[UInt8]] = []
    if let stick, let speech = option("--speech"), let wav = try? VoiceWAV.read(URL(fileURLWithPath: speech)), wav.sampleRate == 8000 {
        for n in 0..<(wav.samples.count / VoiceFrame.samplesPerFrame) {
            let chunk = Array(wav.samples[n * VoiceFrame.samplesPerFrame..<(n + 1) * VoiceFrame.samplesPerFrame])
            do { frames.append(try stick.encode(chunk, profile: profile).bytes) } catch { fail("Codieren: \(error)") }
        }
    } else {
        frames = [[UInt8]](repeating: DStarConstants.nullAmbe, count: 150)
    }
    let header = DStarHeader(repeater2: "DB0XYZ G", repeater1: "DB0XYZ B", yourCall: "CQCQCQ", myCall: "DL1ABC", myCall2: "TEST")
    let bits = DStarSignalGenerator.transmissionBits(header: header, frames: frames, slowData: .text(text))
    var impairments = DStarSignalGenerator.Impairments(); impairments.noise = noise
    let audio = DStarSignalGenerator.audio(bits: bits, sampleRate: 48000, impairments: impairments)
    let pcm = audio.map { Int16(max(-1, min(1, $0)) * 32767) }
    do { try VoiceWAV.write(pcm, sampleRate: 48000, to: URL(fileURLWithPath: arguments[1])) } catch { fail("\(arguments[1]): \(error)") }
    print("Aussendung: \(frames.count) Rahmen, \(String(format: "%.1f", Double(audio.count) / 48000)) s, geschrieben: \(arguments[1])")
    decode(audio, rate: 48000)
} else {
    let (audio, rate) = readAudio(arguments[0])
    print(String(format: "%@: %.1f s, %.0f Hz", (arguments[0] as NSString).lastPathComponent, Double(audio.count) / rate, rate))
    decode(audio, rate: rate)
}
