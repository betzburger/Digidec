// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den DRM-Empfänger: WAV (48 kHz; zwei Kanäle = I/Q, ein Kanal = reelles Audio, 16 oder 24 Bit) → Status und Audiorahmen.

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
let dumpPath = option("--dump")
guard let path = arguments.first else {
    print("Aufruf: drm_bench.sh <aufnahme.wav> [--dump aac.bin]")
    exit(2)
}
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
var pos = 12
nonisolated(unsafe) var channels = 1, bits = 16, rate = 48000
nonisolated(unsafe) var dataStart = 0
nonisolated(unsafe) var dataSize = 0
while pos + 8 <= data.count {
    let id = String(decoding: data[pos..<pos + 4], as: UTF8.self)
    let size = u32(pos + 4)
    if id == "fmt " { channels = u16(pos + 10); rate = u32(pos + 12); bits = u16(pos + 22) }
    if id == "data" { dataStart = pos + 8; dataSize = min(size, data.count - pos - 8); break }
    pos += 8 + size + (size & 1)
}
let bytes = bits / 8
let frames = dataSize / (bytes * channels)
func sampleAt(_ index: Int) -> Float {
    let o = dataStart + index * bytes
    switch bytes {
    case 2: return Float(Int16(bitPattern: UInt16(u16(o)))) / 32768
    case 3:
        var v = Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16
        if v >= 1 << 23 { v -= 1 << 24 }
        return Float(v) / 8_388_608
    default: return 0
    }
}
print(String(format: "%@: %.1f s, %d Hz, %d Kanal/Kanäle, %d Bit", (path as NSString).lastPathComponent, Double(frames) / Double(rate), rate, channels, bits))
let rx = DRMReceiver()
nonisolated(unsafe) var lastText = ""
nonisolated(unsafe) var audioUnits = 0
nonisolated(unsafe) var dump: [UInt8] = []
nonisolated(unsafe) var time = 0.0
rx.onEvent = { e in
    switch e {
    case .status(let s):
        var t = "gesperrt \(s.locked) Modus \(s.mode.map { $0.letter } ?? "-") Belegung \(s.occupancy?.title ?? "-") MSC \(s.mscMode) SDC \(s.sdcMode) SNR \(String(format: "%.1f", s.snr)) dB  FAC \(s.facGood)/\(s.facBad) SDC \(s.sdcGood)/\(s.sdcBad) MSC \(s.mscFrames)"
        for sv in s.services { t += "  [\(sv.shortID): \(sv.label) \(sv.audio.map { "\($0.coding.title) \($0.modeTitle) \($0.outputRate) Hz" } ?? "")]" }
        if t != lastText { print(String(format: "%7.2f s  ", time) + t); lastText = t }
    case .text(let t): print(String(format: "%7.2f s  Text: %@", time, t))
    case .audio(let u):
        audioUnits += 1
        for f in u.frames { dump += [UInt8(f.count)] + f }
    }
}
let chunk = 4800
var index = 0
while index < frames {
    let end = min(index + chunk, frames)
    if channels >= 2 {
        let re = (index..<end).map { sampleAt($0 * channels) }, im = (index..<end).map { sampleAt($0 * channels + 1) }
        rx.processComplex(re: re, im: im)
    } else {
        rx.process((index..<end).map { sampleAt($0) })
    }
    index = end
    time = Double(index) / Double(rate)
}
print("Audio-Überrahmen: \(audioUnits)")
if let dumpPath { try? Data(dump).write(to: URL(fileURLWithPath: dumpPath)) }
