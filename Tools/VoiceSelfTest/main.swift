// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import VoiceCore

// Prüfstand für den Sprachstick: Sprache (WAV, 8 kHz, 16 Bit, mono) codieren, vom Chip zurückwandeln lassen, als WAV ausgeben.
// Aufruf: voice-selftest <ein.wav> <aus.wav> [--profile dstar|dmr|p25] [--port /dev/cu.…] [--play]
nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
let profile = VoiceProfile(rawValue: option("--profile") ?? "dmr") ?? .dmr
let explicitPort = option("--port")
let play = arguments.firstIndex(of: "--play").map { arguments.remove(at: $0) } != nil
guard arguments.count == 2 else {
    print("Aufruf: voice-selftest <ein.wav> <aus.wav> [--profile dstar|dmr|p25] [--port <Pfad>] [--play]")
    exit(2)
}

func fail(_ text: String) -> Never { print("FEHLER: \(text)"); exit(1) }

let input: (samples: [Int16], sampleRate: Int)
do { input = try VoiceWAV.read(URL(fileURLWithPath: arguments[0])) } catch { fail("\(arguments[0]): \(error)") }
guard input.sampleRate == VoiceFrame.sampleRate else { fail("Eingabe muss 8000 Hz haben (hat \(input.sampleRate))") }

var stick: AMBE3000Stick?
for path in explicitPort.map({ [$0] }) ?? AMBE3000Stick.candidatePaths() {
    do { stick = try AMBE3000Stick(path: path); break } catch { print("kein AMBE-3000 an \(path): \(error)") }
}
guard let stick else { fail("kein Stick gefunden (Anschluss mit --port angeben)") }
print("Stick: \(stick.name), Firmware \(stick.firmware), Verfahren \(profile.rawValue)")

let frameSize = VoiceFrame.samplesPerFrame
let frameCount = input.samples.count / frameSize
var output: [Int16] = []
var frames: [VoiceFrame] = []
var encodeTimes: [Double] = [], decodeTimes: [Double] = []
do {
    for index in 0..<frameCount {
        let chunk = Array(input.samples[index * frameSize..<(index + 1) * frameSize])
        let t0 = Date()
        let frame = try stick.encode(chunk, profile: profile)
        let t1 = Date()
        let pcm = try stick.decode(frame, profile: profile)
        let t2 = Date()
        encodeTimes.append(t1.timeIntervalSince(t0) * 1000)
        decodeTimes.append(t2.timeIntervalSince(t1) * 1000)
        frames.append(frame)
        output += pcm
    }
} catch { fail("nach \(frames.count) Rahmen: \(error)") }

func rms(_ samples: ArraySlice<Int16>) -> Double {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
}
// Hüllkurve je Rahmen, Korrelation zwischen Ein- und Ausgabe (Verzögerung bis 3 Rahmen berücksichtigt)
let envelopeIn = (0..<frameCount).map { rms(input.samples[$0 * frameSize..<($0 + 1) * frameSize]) }
let envelopeOut = (0..<min(frameCount, output.count / frameSize)).map { rms(output[$0 * frameSize..<($0 + 1) * frameSize]) }
func correlation(_ a: [Double], _ b: [Double], shift: Int) -> Double {
    var pairs: [(Double, Double)] = []
    for index in 0..<a.count where index + shift >= 0 && index + shift < b.count { pairs.append((a[index], b[index + shift])) }
    guard pairs.count > 2 else { return 0 }
    let meanA = pairs.map(\.0).reduce(0, +) / Double(pairs.count), meanB = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
    let cross = pairs.reduce(0.0) { $0 + ($1.0 - meanA) * ($1.1 - meanB) }
    let varA = pairs.reduce(0.0) { $0 + ($1.0 - meanA) * ($1.0 - meanA) }, varB = pairs.reduce(0.0) { $0 + ($1.1 - meanB) * ($1.1 - meanB) }
    return cross / max(1e-9, (varA * varB).squareRoot())
}
let best = (-3...3).map { ($0, correlation(envelopeIn, envelopeOut, shift: $0)) }.max { $0.1 < $1.1 }!
func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
let distinct = Set(frames.map(\.bytes)).count

print(String(format: "Rahmen: %d (%.1f s), verschiedene Kanalrahmen: %d", frameCount, Double(frameCount) * 0.02, distinct))
print(String(format: "Pegel Ein/Aus (RMS): %.0f / %.0f", rms(input.samples[...]), rms(output[...])))
print(String(format: "Hüllkurven-Korrelation: %.3f bei Versatz %d Rahmen", best.1, best.0))
print(String(format: "Laufzeit je Rahmen: codieren %.1f ms, decodieren %.1f ms (Rahmen = 20 ms)", average(encodeTimes), average(decodeTimes)))

do { try VoiceWAV.write(output, to: URL(fileURLWithPath: arguments[1])) } catch { fail("\(arguments[1]): \(error)") }
print("geschrieben: \(arguments[1])")

if play {
    let player = VoicePlayer()
    do { try player.start() } catch { fail("Wiedergabe: \(error)") }
    player.enqueue(output)
    Thread.sleep(forTimeInterval: Double(output.count) / Double(VoiceFrame.sampleRate) + 0.5)
    player.stop()
}
