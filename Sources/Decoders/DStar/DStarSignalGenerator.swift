// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Erzeugt D-Star-Aussendungen (Betriebsart DV) als Bitfolge und als FM-Diskriminator-Audio: für Prüfstände und Demos.
// Die Sprachrahmen (je 9 Byte) liefert der Aufrufer, zum Beispiel aus dem Sprachstick; ohne eigene Rahmen sendet er Stille.

public enum DStarSignalGenerator {
    /// Inhalt der Langsamdaten
    public enum SlowDataMode: Sendable {
        case none
        /// Textnachricht (bis 20 Zeichen), Teile 0…3 im Wechsel mit Leerblöcken
        case text(String)
        /// Kopf-Wiederholung für späten Einstieg (9 Blöcke je Überrahmen, dazu ein Leerblock)
        case headerCopy
    }

    /// Bitsynchronisation (64 Bit, alternierend, endet mit 0) und die 15 Bit der Rahmensynchronisation
    public static var preamble: [UInt8] {
        (0..<32).flatMap { _ in [UInt8(1), UInt8(0)] } + DStarConstants.frameSync15
    }

    /// 6-Byte-Blöcke der Langsamdaten, die ein Überrahmen (10 Blöcke) in der Reihenfolge trägt
    public static func slowDataBlocks(_ mode: SlowDataMode, header: DStarHeader) -> [[UInt8]] {
        let fill: [UInt8] = [0x66, 0x66, 0x66, 0x66, 0x66, 0x66]
        switch mode {
        case .none:
            return [[UInt8]](repeating: fill, count: 10)
        case .text(let text):
            var chars = Array(text.utf8.prefix(20))
            while chars.count < 20 { chars.append(0x20) }
            let parts = (0..<4).map { [UInt8(0x40 + $0)] + chars[($0 * 5)..<($0 * 5 + 5)] }
            return parts + [[UInt8]](repeating: fill, count: 6)
        case .headerCopy:
            let bytes = header.bytes
            var blocks: [[UInt8]] = []
            var offset = 0
            while offset < bytes.count {
                let chunk = Array(bytes[offset..<min(offset + 5, bytes.count)])
                var block: [UInt8] = [0x50 + UInt8(chunk.count)] + chunk
                while block.count < 6 { block.append(0x66) }
                blocks.append(block)
                offset += chunk.count
            }
            while blocks.count < 10 { blocks.append(fill) }
            return Array(blocks.prefix(10))
        }
    }

    /// Eine ganze Aussendung als Bitfolge in der Reihenfolge der Leitung.
    /// - Parameters:
    ///   - frames: AMBE-Rahmen zu 9 Byte, einer je 20 ms
    ///   - withHeader: ohne Kopf (nur für Prüfungen des späten Einstiegs)
    public static func transmissionBits(header: DStarHeader, frames: [[UInt8]], slowData: SlowDataMode = .none, withHeader: Bool = true, withEnd: Bool = true) -> [UInt8] {
        var bits: [UInt8] = []
        if withHeader {
            bits += preamble
            bits += DStarHeaderCodec.encode(header)
        }
        let blocks = slowDataBlocks(slowData, header: header)
        for (n, ambe) in frames.enumerated() {
            let index = n % DStarConstants.framesPerSuperframe
            precondition(ambe.count == 9)
            bits += DStarBits.bits(fromBytes: ambe)
            if index == 0 {
                bits += DStarConstants.voiceSync24
            } else {
                let block = blocks[(index - 1) / 2]
                let half = (index - 1) % 2
                let raw = Array(block[(half * 3)..<(half * 3 + 3)])
                let scrambled = zip(raw, DStarConstants.slowDataScramble).map { $0 ^ $1 }
                bits += DStarBits.bits(fromBytes: scrambled)
            }
        }
        if withEnd { bits += DStarConstants.endPattern48 }
        return bits
    }

    /// Frequenzverlauf einer Pegelfolge (±1), Gauß-Filter mit BT = `DStarConstants.bt`; Bit k belegt [k, k+1) Bitdauern.
    static func gaussianPulses(levels: [Float], samplesPerBit sps: Double, count: Int) -> [Float] {
        guard !levels.isEmpty else { return [Float](repeating: 0, count: count) }
        let sigma = log(2.0).squareRoot() / (2 * Double.pi * DStarConstants.bt)      // in Bitdauern
        let s2 = sigma * 2.0.squareRoot()
        let span = 3
        let pad = span + 2
        let ext = [Float](repeating: levels[0], count: pad) + levels + [Float](repeating: levels[levels.count - 1], count: pad)
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let x = Double(n) / sps + Double(pad)
            let k0 = Int(x.rounded(.down))
            var v = 0.0
            for k in max(0, k0 - span)...min(ext.count - 1, k0 + span) {
                let u = x - Double(k) - 0.5
                v += Double(ext[k]) * 0.5 * (erf((u + 0.5) / s2) - erf((u - 0.5) / s2))
            }
            out[n] = Float(v)
        }
        return out
    }

    public struct Impairments: Sendable {
        /// Rauschen (Standardabweichung) bezogen auf den Spitzenpegel 1
        public var noise: Float = 0
        /// Gleichanteil (z. B. Frequenzablage), bezogen auf den Spitzenpegel 1
        public var dc: Float = 0
        /// Abweichung des Bittakts in ppm
        public var clockPPM: Double = 0
        /// Pegel umkehren (Diskriminator mit anderer Polarität)
        public var inverted = false
        public var seed: UInt64 = 1
        public init() {}
    }

    /// Moduliert Bits als Diskriminator-Audio (Gauß-geformte Pegelfolge, ±amplitude), `leadSilence` Sekunden Stille davor und danach.
    public static func audio(bits: [UInt8], sampleRate: Double, amplitude: Float = 0.5, leadSilence: Double = 0.1, impairments: Impairments = Impairments()) -> [Float] {
        let sps = sampleRate / DStarConstants.baud * (1 + impairments.clockPPM * 1e-6)
        let levels: [Float] = bits.map { $0 != 0 ? 1 : -1 }
        let count = Int(Double(bits.count) * sps)
        var shaped = gaussianPulses(levels: levels, samplesPerBit: sps, count: count)
        if impairments.inverted { for i in 0..<shaped.count { shaped[i] = -shaped[i] } }
        var state = impairments.seed &* 6364136223846793005 &+ 1442695040888963407
        func gaussian() -> Float {
            func uniform() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
        }
        let lead = Int(leadSilence * sampleRate)
        var out = [Float](repeating: 0, count: lead + shaped.count + lead)
        for i in 0..<out.count {
            let signal: Float = (i >= lead && i < lead + shaped.count) ? shaped[i - lead] * amplitude : 0
            out[i] = signal + impairments.dc * amplitude + impairments.noise * amplitude * gaussian()
        }
        return out
    }
}
