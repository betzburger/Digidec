// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import AVFoundation

/// Spielt dekodierte Sprache (8 kHz, 16 Bit, mono) über den Standard-Ausgang.
public final class VoicePlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat

    public init() {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceFrame.sampleRate), channels: 1, interleaved: false)!
        engine.attach(node)
    }

    public func start() throws {
        // Die macOS-27-Fassungen mit Fehlermeldung sind hier nicht erreichbar; die alten Aufrufe laufen ab macOS 14 (nur Hinweise des Compilers)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
    }

    public func stop() {
        node.stop()
        engine.stop()
    }

    /// Hängt Abtastwerte an die Wiedergabe an.
    public func enqueue(_ samples: [Int16]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        node.scheduleBuffer(buffer, completionHandler: nil)
    }
}

/// Einfaches WAV (16 Bit, mono) für Prüfstände und Aufnahmen.
public enum VoiceWAV {
    public static func write(_ samples: [Int16], sampleRate: Int = VoiceFrame.sampleRate, to url: URL) throws {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(payload)
        for sample in samples { put16(UInt16(bitPattern: sample)) }
        try data.write(to: url)
    }

    /// Liest 16-Bit-PCM mono; andere Formate werden abgelehnt.
    public static func read(_ url: URL) throws -> (samples: [Int16], sampleRate: Int) {
        let data = try Data(contentsOf: url)
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard data.count > 44, String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { throw VoiceError.protocolError("keine WAV-Datei") }
        var position = 12
        var rate = 0
        while position + 8 <= data.count {
            let id = String(decoding: data[position..<position + 4], as: UTF8.self)
            let size = u32(position + 4)
            let body = position + 8
            if id == "fmt " {
                guard u16(body) == 1, u16(body + 2) == 1, u16(body + 14) == 16 else {
                    throw VoiceError.protocolError("nur 16-Bit-PCM mono")
                }
                rate = u32(body + 4)
            } else if id == "data" {
                guard rate > 0 else { throw VoiceError.protocolError("Format fehlt") }
                let count = min(size, data.count - body) / 2
                let samples = (0..<count).map { Int16(bitPattern: UInt16(u16(body + $0 * 2))) }
                return (samples, rate)
            }
            position = body + size + (size & 1)
        }
        throw VoiceError.protocolError("keine Tondaten")
    }
}
