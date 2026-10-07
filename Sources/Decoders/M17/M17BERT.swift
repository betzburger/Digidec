// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// M17 BERT-Modus (Bitfehlertest): Vorspann B (−3, +3), dann ununterbrochen BERT-Rahmen (Synchronwort 0xDF55) ohne LSF. Jeder Rahmen trägt
// 197 Bit einer PRBS9-Folge (x⁹ + x⁵ + 1, Anfangszustand 1, über die Rahmen hinweg ohne Rücksetzen). Faltungscode K=5 über 201 Bit, Punktierung P2
// (402 → 368 Bit). Der Empfänger rastet selbstsynchronisierend ein (18 richtige Bit in Folge) und zählt danach die Abweichungen von der
// freilaufenden Folge; mehr als 18 Fehler in 128 Bit lösen eine neue Synchronisation aus. Nach M17-Spezifikation Abschnitt „BERT Mode“.

/// Die M17-PRBS9: das erzeugte Bit ist zugleich das Ausgangsbit
public struct M17PRBS9: Sendable {
    public var state: UInt16 = 1

    public init() {}

    public mutating func next() -> UInt8 {
        let bit = UInt8(((state >> 8) ^ (state >> 4)) & 1)
        state = ((state << 1) | UInt16(bit)) & 0x1FF
        return bit
    }
}

/// Zählt die Bitfehler einer BERT-Aussendung
public struct M17BERTReceiver: Sendable {
    public static let lockCount = 18
    public static let windowBits = 128
    public static let windowLimit = 18

    private var state: UInt16 = 1
    private var syncCount = 0
    private var windowFill = 0
    private var windowErrors = 0
    public private(set) var synced = false
    /// Gezählte Bit und Fehler (ohne die Zeit der Synchronisation)
    public private(set) var bits = 0
    public private(set) var errors = 0
    /// Wie oft neu synchronisiert werden musste (nach dem ersten Einrasten)
    public private(set) var resyncs = 0

    public init() {}

    public var errorRate: Double { bits > 0 ? Double(errors) / Double(bits) : 0 }

    public mutating func reset() { self = M17BERTReceiver() }

    /// „Bitfehlerrate 0,31 % (3 von 960 Bit)“ oder „synchronisiert …“
    public static func text(bits: Int, errors: Int, synced: Bool) -> String {
        guard synced || bits > 0 else { return "Folge wird gesucht" }
        let rate = bits > 0 ? Double(errors) / Double(bits) * 100 : 0
        return String(format: "Bitfehlerrate %.2f %% (%d von %d Bit)", rate, errors, bits).replacingOccurrences(of: ".", with: ",") + (synced ? "" : " · Gleichlauf verloren")
    }

    public mutating func process(_ frame: [UInt8]) {
        for bit in frame {
            let b = bit & 1
            let expected = UInt8(((state >> 8) ^ (state >> 4)) & 1)
            if !synced {
                // Selbstsynchronisation: das empfangene Bit wird in das Register geschoben
                state = ((state << 1) | UInt16(b)) & 0x1FF
                if b != expected { syncCount = 0 } else {
                    syncCount += 1
                    if syncCount >= Self.lockCount { synced = true; windowFill = 0; windowErrors = 0 }
                }
                continue
            }
            state = ((state << 1) | UInt16(expected)) & 0x1FF
            let wrong = b != expected
            bits += 1
            if wrong { errors += 1; windowErrors += 1 }
            windowFill += 1
            if windowFill == Self.windowBits {
                if windowErrors > Self.windowLimit {
                    // Gleichlauf verloren: das Fenster zählt nicht, neu einrasten
                    bits -= Self.windowBits
                    errors -= windowErrors
                    synced = false
                    syncCount = 0
                    resyncs += 1
                }
                windowFill = 0; windowErrors = 0
            }
        }
    }
}

extension M17 {
    /// BERT-Rahmen aus den 184 Symbolen hinter dem Synchronwort: 197 Bit und der Anteil gestörter Bits des Faltungscodes
    public static func decodeBERTFrame(_ symbols: ArraySlice<Float>) -> (bits: [UInt8], errorRate: Float)? {
        let soft = deliver(symbols)
        guard soft.count == payloadBits else { return nil }
        // Punktierung P2 über 402 Bit ergibt 369; das letzte fehlt (bleibt „unbekannt“)
        let decoded = viterbi(soft[0..<368], pattern: puncture2, coded: 402)
        guard decoded.bits.count == 197 else { return nil }
        return (decoded.bits, decoded.errorRate)
    }

    /// Symbole eines BERT-Rahmens mit Synchronwort (Prüfstände)
    public static func bertFrameSymbols(bits: [UInt8]) -> [Float] {
        precondition(bits.count == 197)
        let coded = ConvK5.encode(bits + [0, 0, 0, 0])
        return SyncKind.bert.levels + symbols(ofPayloadBits: Array(puncture(coded, pattern: puncture2).prefix(payloadBits)))
    }

    /// Vorspann B (BERT): 40 ms abwechselnd −3 und +3
    public static func bertPreambleSymbols() -> [Float] { (0..<frameSymbols).map { $0 % 2 == 0 ? -3 : 3 } }
}
