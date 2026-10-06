// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Eine aus dem Betragssignal gewonnene Mode-S-Meldung (7 oder 14 Byte), noch ohne Prüfung der Prüfsumme
public struct ModeSRawFrame: Sendable, Equatable {
    public var bytes: [UInt8]
    /// Pegel der vier Präambelimpulse (Mittel) in dB unter Vollaussteuerung (≤ 0)
    public var levelDB: Double
    /// Erst nach der Phasenkorrektur lesbar (Abtastpunkt lag neben dem Bit)
    public var phaseCorrected: Bool
    /// Lage im Datenstrom (Abtastwerte seit Beginn)
    public var sampleIndex: Int
}

/// Demodulator für Mode S auf 1090 MHz bei 2 Megaabtastungen je Sekunde (8-Bit-I/Q, vorzeichenlos mit Mittelpunkt 127).
/// Ein Bit dauert 1 µs = zwei Abtastwerte; Impulslage-Modulation: Bit 1 = erste Hälfte stärker, Bit 0 = zweite Hälfte stärker.
/// Die Präambel besteht aus Impulsen bei 0, 1, 3,5 und 4,5 µs. Der Ablauf (Präambelprüfung, Pegelprüfung der Lücken,
/// Wiederholung mit Phasenkorrektur) entspricht dem, was dump1090 (Salvatore Sanfilippo, BSD) und seine Weiterentwicklungen beschreiben.
public final class ModeSDemodulator {
    public static let sampleRate = 2_000_000.0
    static let preambleSamples = 16
    static let longBits = 112
    static let shortBits = 56
    /// Vorschau, die ein Fenster braucht: Präambel (8 µs) und lange Meldung (112 µs), zwei Abtastwerte je µs
    static let fullSamples = (8 + 112) * 2

    /// Betragstabelle: round(sqrt(i² + q²) · 360) für i, q = 0 … 128
    private static let magnitudeTable: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 129 * 129)
        for i in 0...128 {
            for q in 0...128 { t[i * 129 + q] = UInt16((Double(i * i + q * q)).squareRoot() * 360 + 0.5) }
        }
        return t
    }()
    /// Vollaussteuerung der Tabelle (128 · 360), Bezug für den Pegel in dB
    static let fullScale = 128.0 * 360.0

    /// Betragswerte; vorn der Rest des letzten Blocks. Index 0 ist nur der Vorgänger des ersten Fensters (Phasenkorrektur).
    private var mag: [UInt16] = [0]
    /// Erstes noch nicht geprüftes Fenster (Index in `mag`)
    private var resume = 1
    /// Wie viele Abtastwerte schon verworfen wurden (für `sampleIndex`)
    private var base = 0
    /// Anzahl ausgewerteter Präambeln, Phasenkorrekturen: für Anzeige und Prüfungen
    public private(set) var preambles = 0
    public private(set) var phaseRetries = 0
    /// Abtastwerte mit Vollaussteuerung (Betrag eines Teils nahe am Anschlag) im letzten Block, ein Maß für Übersteuerung
    public private(set) var clippedSamples = 0
    public private(set) var totalSamples = 0
    private var window = [UInt16](repeating: 0, count: 256)
    /// Mittlere Auslenkung der letzten Daten von der Mitte (0 … 127): ein Maß für Rauschen und Signalstärke
    public private(set) var blockActivity = 0.0

    public init() {}

    public func reset() {
        mag = [0]
        resume = 1
        base = 0
        clippedSamples = 0
        totalSamples = 0
    }

    /// Einen Block I/Q-Daten (abwechselnd I, Q, vorzeichenlos; gerade Länge, die Geräte liefern nur ganze Paare) verarbeiten. `accept` prüft eine Kandidatenmeldung (Prüfsumme, Adresse);
    /// nur bei `true` wird sie gemeldet und übersprungen, sonst folgt ein Versuch mit Phasenkorrektur.
    public func process(_ iq: UnsafeBufferPointer<UInt8>, accept: ([UInt8]) -> Bool, emit: (ModeSRawFrame) -> Void) {
        let pairs = iq.count / 2
        guard pairs > 0 else { return }
        mag.reserveCapacity(mag.count + pairs)
        let table = Self.magnitudeTable
        var clipped = 0
        var sum: UInt64 = 0
        table.withUnsafeBufferPointer { t in
            for k in 0..<pairs {
                let ri = iq[2 * k], rq = iq[2 * k + 1]
                if ri == 0 || ri == 255 || rq == 0 || rq == 255 { clipped += 1 }
                sum += UInt64(abs(Int(ri) - 127) + abs(Int(rq) - 127))
                var i = Int(ri) - 127
                var q = Int(rq) - 127
                if i < 0 { i = -i }
                if q < 0 { q = -q }
                mag.append(t[min(i, 128) * 129 + min(q, 128)])
            }
        }
        clippedSamples += clipped
        totalSamples += pairs
        blockActivity = Double(sum) / Double(pairs) / 2
        detect(accept: accept, emit: emit)
        // Den unverarbeiteten Rest und einen Vorgänger behalten
        let keepFrom = max(0, mag.count - Self.fullSamples - 1)
        if keepFrom > 0 {
            mag.removeFirst(keepFrom)
            base += keepFrom
            resume = max(1, resume - keepFrom)
        }
    }

    private func detect(accept: ([UInt8]) -> Bool, emit: (ModeSRawFrame) -> Void) {
        let n = mag.count
        guard n > Self.fullSamples + 2 else { return }
        mag.withUnsafeBufferPointer { m in
            var j = resume
            var correcting = false
            let limit = n - Self.fullSamples
            var win = window
            while j < limit {
                if !correcting {
                    // Verhältnisse der ersten zehn Abtastwerte einer gültigen Präambel
                    guard m[j] > m[j + 1], m[j + 1] < m[j + 2], m[j + 2] > m[j + 3], m[j + 3] < m[j], m[j + 4] < m[j], m[j + 5] < m[j],
                          m[j + 6] < m[j], m[j + 7] > m[j + 8], m[j + 8] < m[j + 9], m[j + 9] > m[j + 6] else { j += 1; continue }
                    // Zwischen den Impulsen darf es nicht über zwei Drittel des Mittels der hohen Impulse liegen
                    let high = (Int(m[j]) + Int(m[j + 2]) + Int(m[j + 7]) + Int(m[j + 9])) / 6
                    guard Int(m[j + 4]) < high, Int(m[j + 5]) < high else { j += 1; continue }
                    guard Int(m[j + 11]) < high, Int(m[j + 12]) < high, Int(m[j + 13]) < high, Int(m[j + 14]) < high else { j += 1; continue }
                    preambles += 1
                }
                // Arbeitskopie des Fensters (mit Vorgänger an Stelle 0)
                for k in 0...Self.fullSamples { win[k] = m[j - 1 + k] }
                if correcting {
                    phaseRetries += 1
                    Self.applyPhaseCorrection(&win)
                }
                // Bits lesen: Vergleich beider Hälften, bei kaum Unterschied das vorige Bit wiederholen
                var bits = [UInt8](repeating: 0, count: Self.longBits)
                var errors = 0
                for i in stride(from: 0, to: Self.longBits * 2, by: 2) {
                    let low = Int(win[1 + Self.preambleSamples + i]), high = Int(win[1 + Self.preambleSamples + i + 1])
                    let delta = abs(low - high)
                    if i > 0 && delta < 256 {
                        bits[i / 2] = bits[i / 2 - 1]
                    } else if low == high {
                        bits[i / 2] = 0
                        if i < Self.shortBits * 2 { errors += 1 }
                    } else {
                        bits[i / 2] = low > high ? 1 : 0
                    }
                }
                var msg = [UInt8](repeating: 0, count: Self.longBits / 8)
                for i in 0..<msg.count {
                    var b: UInt8 = 0
                    for k in 0..<8 { b = b << 1 | bits[i * 8 + k] }
                    msg[i] = b
                }
                let df = Int(msg[0] >> 3)
                let longMessage = df >= 16
                let length = longMessage ? 14 : 7
                // Zu geringer Unterschied zwischen den Hälften: Rauschen, kein Signal
                var delta = 0
                for i in stride(from: 0, to: length * 8 * 2, by: 2) {
                    delta += abs(Int(win[1 + Self.preambleSamples + i]) - Int(win[1 + Self.preambleSamples + i + 1]))
                }
                delta /= length * 4
                if delta < 10 * 255 {
                    correcting = false
                    j += 1
                    continue
                }
                var good = false
                if errors == 0 {
                    let frame = Array(msg.prefix(length))
                    if accept(frame) {
                        let level = (Double(m[j]) + Double(m[j + 2]) + Double(m[j + 7]) + Double(m[j + 9])) / 4
                        emit(ModeSRawFrame(bytes: frame, levelDB: 20 * log10(max(level, 1) / Self.fullScale), phaseCorrected: correcting,
                                           sampleIndex: base + j))
                        good = true
                        j += (8 + length * 8) * 2
                    }
                }
                if !good && !correcting {
                    correcting = true       // dieselbe Stelle noch einmal, mit Phasenkorrektur
                } else {
                    correcting = false
                    j += 1
                }
            }
            // Fortsetzung im nächsten Block ab dem ersten nicht geprüften Fenster
            resume = j
        }
    }

    /// Phasenkorrektur nach dem Verfahren von Oliver Jowett: Liegt der Abtastpunkt etwas neben dem Bit, enthält jeder Wert Energie des
    /// Nachbarbits. Anhand der Präambel wird geschätzt, in welche Richtung, und die Werte werden gegenläufig neu gewichtet.
    /// `w[0]` ist der Wert vor der Präambel, `w[1 + k]` der k-te Wert der Meldung.
    static func applyPhaseCorrection(_ w: inout [UInt16]) {
        func scale(_ v: UInt16, _ s: Int) -> UInt16 { UInt16(min(65535, Int(v) * s / 16384)) }
        let on = Int(w[1]) + Int(w[3]) + Int(w[8]) + Int(w[10])
        let early = (Int(w[0]) + Int(w[7])) * 2
        let late = (Int(w[4]) + Int(w[11])) * 2
        let first = 1 + preambleSamples
        if early > late {
            let up = 16384 + 16384 * early / (early + on)
            let down = 16384 - 16384 * early / (early + on)
            w[first + longBits * 2 - 1] = scale(w[first + longBits * 2 - 1], up)
            var j = first + longBits * 2 - 2
            while j > first {
                w[j - 1] = scale(w[j - 1], w[j] > w[j + 1] ? down : up)
                j -= 2
            }
        } else {
            let up = 16384 + 16384 * late / (late + on)
            let down = 16384 - 16384 * late / (late + on)
            w[first] = scale(w[first], up)
            var j = first
            while j < first + longBits * 2 - 2 {
                w[j + 2] = scale(w[j + 2], w[j] > w[j + 1] ? up : down)
                j += 2
            }
        }
    }
}
