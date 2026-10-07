// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Schneller Informationskanal (FIC): drei OFDM-Symbole je Rahmen tragen vier Codewörter zu je 2304 Bits, aus jedem entstehen drei Informationsblöcke (FIB) zu 32 Byte mit CRC.
public final class DABFICDecoder {
    /// Ein FIB mit gültiger CRC (30 Nutzbytes) und die Nummer der Gruppe im Rahmen (0 … 11)
    public var onFIB: (([UInt8], Int) -> Void)?
    public private(set) var fibsGood = 0
    public private(set) var fibsBad = 0

    private let viterbi: DABViterbi
    private var collected = [Int8](repeating: 0, count: 3 * DABMode1.bitsPerSymbol)
    private let prbs = DABTables.energyDispersal(count: 768)
    private var input = [Int8](repeating: 0, count: (768 + 6) * 4)

    public init(positiveIsOne: Bool = true) {
        viterbi = DABViterbi()
        viterbi.positiveIsOne = positiveIsOne
    }

    public var positiveIsOne: Bool {
        get { viterbi.positiveIsOne }
        set { viterbi.positiveIsOne = newValue }
    }

    /// Anteil gültiger FIB der letzten Zeit (0 … 1)
    public private(set) var recentRatio = 0.0

    /// Symbole 1 bis 3 eines Rahmens
    public func process(symbol: Int, bits: UnsafeBufferPointer<Int8>) {
        guard (1...3).contains(symbol) else { return }
        let offset = (symbol - 1) * DABMode1.bitsPerSymbol
        for i in 0..<DABMode1.bitsPerSymbol { collected[offset + i] = bits[i] }
        guard symbol == 3 else { return }
        for group in 0..<4 {
            let block = Array(collected[(group * 2304)..<((group + 1) * 2304)])
            decodeBlock(block, group: group)
        }
    }

    private func decodeBlock(_ block: [Int8], group: Int) {
        // Entpunktieren: 21 Blöcke zu 128 mit PI_16, drei mit PI_15, am Ende 24 Bits mit PI_X
        for i in 0..<input.count { input[i] = 0 }
        var take = 0, put = 0
        let pi16 = DABTables.puncture[15], pi15 = DABTables.puncture[14]
        for _ in 0..<21 {
            for k in 0..<128 {
                if pi16[k % 32] != 0 { input[put] = block[take]; take += 1 }
                put += 1
            }
        }
        for _ in 0..<3 {
            for k in 0..<128 {
                if pi15[k % 32] != 0 { input[put] = block[take]; take += 1 }
                put += 1
            }
        }
        for k in 0..<24 {
            if DABTables.punctureTail[k] != 0 { input[put] = block[take]; take += 1 }
            put += 1
        }
        let decoded = input.withUnsafeBufferPointer { viterbi.decode(soft: $0, bitCount: 768) }
        for i in 0..<768 { _ = decoded[i] }
        var bytes = [UInt8](repeating: 0, count: 96)
        for i in 0..<768 {
            let b = decoded[i] ^ prbs[i]
            bytes[i / 8] |= b << UInt8(7 - (i % 8))
        }
        for f in 0..<3 {
            let fib = Array(bytes[(f * 32)..<(f * 32 + 32)])
            let crc = DABCRC.crc16(Array(fib[0..<30]))
            let stored = UInt16(fib[30]) << 8 | UInt16(fib[31])
            if crc == stored {
                fibsGood += 1
                recentRatio = recentRatio * 0.98 + 0.02
                onFIB?(Array(fib[0..<30]), group * 3 + f)
            } else {
                fibsBad += 1
                recentRatio *= 0.98
            }
        }
    }
}
