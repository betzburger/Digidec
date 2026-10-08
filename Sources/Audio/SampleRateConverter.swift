// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

/// Streaming-Abtastratenwandler Mono-Float (z. B. 48 kHz → 8 kHz für den RTTY-Kern von fldigi).
///
/// Bandbegrenzte Interpolation: Sinc-Tiefpass mit Kaiser-Fenster als Polyphasen-Tabelle,
/// linear zwischen benachbarten Phasen interpoliert. Eigene Umsetzung statt AVAudioConverter, weil dieser
/// im Streaming-Betrieb (`.noDataNow`) je nach Blockgröße Samples verlor (≈ 54 pro Sekunde bei 4800er-Blöcken),
/// was den Bit-Takt des Decoders verfälscht hätte. Ergebnis hier: unabhängig von der Blockaufteilung
/// bitgleich, feste Latenz von `halfTaps` Eingangssamples.
public final class SampleRateConverter {
    public let inputRate: Double
    public let outputRate: Double

    /// Grenzfrequenz relativ zur halben Zielrate (Rest ist Übergangsbereich des Filters)
    private static let passbandFraction = 0.92
    /// Nulldurchgänge des Sinc je Seite
    private static let zeroCrossings = 24
    private static let phases = 128
    private static let kaiserBeta = 9.0

    private let step: Double
    private let halfTaps: Int
    private let tapCount: Int
    /// (phases + 1) Zeilen × tapCount, Zeile p gehört zur Nachkommastelle p / phases
    private let table: [Float]

    // Streaming-Zustand
    private var history: [Float]
    /// Position des nächsten Ausgabesamples in `history` (in Eingangssamples)
    private var position: Double

    public init?(inputRate: Double, outputRate: Double) {
        guard inputRate > 0, outputRate > 0 else { return nil }
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate

        // Grenzfrequenz normiert auf die Eingangsrate
        let fc = 0.5 * min(1.0, outputRate / inputRate) * Self.passbandFraction
        halfTaps = Int((Double(Self.zeroCrossings) / (2 * fc)).rounded(.up))
        tapCount = 2 * halfTaps

        // h(t) = 2fc·sinc(2fc·t)·kaiser(t), t in Eingangssamples; Tabelle[p][j] = h(p/P − (j − halfTaps + 1))
        var table = [Float](repeating: 0, count: (Self.phases + 1) * tapCount)
        let i0Beta = Self.besselI0(Self.kaiserBeta)
        let width = Double(halfTaps)
        for p in 0...Self.phases {
            let frac = Double(p) / Double(Self.phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: tapCount)
            for j in 0..<tapCount {
                let t = frac - Double(j - halfTaps + 1)
                let x = 2 * fc * t
                let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let r = t / width
                let window = abs(r) >= 1 ? 0 : Self.besselI0(Self.kaiserBeta * (1 - r * r).squareRoot()) / i0Beta
                row[j] = 2 * fc * sinc * window
                sum += row[j]
            }
            // Jede Phase auf Verstärkung 1 normieren (exakter Gleichanteil)
            for j in 0..<tapCount {
                table[p * tapCount + j] = Float(row[j] / sum)
            }
        }
        self.table = table

        // Vorlauf aus Nullen, damit das erste Ausgabesample volle Filterlänge hat
        history = [Float](repeating: 0, count: halfTaps - 1)
        position = Double(halfTaps - 1)
    }

    /// Feste Verzögerung in Ausgabesamples
    public var latencyOutputSamples: Double { Double(halfTaps) / step }

    public func reset() {
        history = [Float](repeating: 0, count: halfTaps - 1)
        position = Double(halfTaps - 1)
    }

    /// Wandelt einen Block; `output` wird mit dem Ergebnis aufgerufen (entfällt, wenn noch kein Sample fällig ist).
    public func process(_ input: UnsafeBufferPointer<Float>, output: (UnsafeBufferPointer<Float>) -> Void) {
        guard !input.isEmpty else { return }
        if inputRate == outputRate {
            output(input)
            return
        }
        history.append(contentsOf: input)

        var out = [Float]()
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        table.withUnsafeBufferPointer { tab in
            history.withUnsafeBufferPointer { hist in
                let tabBase = tab.baseAddress!
                let histBase = hist.baseAddress!
                while true {
                    let i = Int(position)                        // floor, position ≥ 0
                    guard i + halfTaps < hist.count else { break }
                    let frac = position - Double(i)
                    let pf = frac * Double(Self.phases)
                    let p = min(Int(pf), Self.phases - 1)
                    let w = Float(pf - Double(p))
                    let src = histBase + (i - halfTaps + 1)
                    var a: Float = 0
                    var b: Float = 0
                    vDSP_dotpr(src, 1, tabBase + p * tapCount, 1, &a, vDSP_Length(tapCount))
                    vDSP_dotpr(src, 1, tabBase + (p + 1) * tapCount, 1, &b, vDSP_Length(tapCount))
                    out.append(a + (b - a) * w)
                    position += step
                }
            }
        }

        // Verbrauchte Samples verwerfen, nur die für das nächste Ausgabesample nötige Vorgeschichte behalten
        let keepFrom = max(0, Int(position) - halfTaps + 1)
        if keepFrom > 0 {
            history.removeFirst(keepFrom)
            position -= Double(keepFrom)
        }

        if !out.isEmpty {
            out.withUnsafeBufferPointer { output($0) }
        }
    }

    /// Modifizierte Besselfunktion 0. Ordnung (Reihenentwicklung) für das Kaiser-Fenster
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let q = x * x / 4
        for k in 1..<50 {
            term *= q / Double(k * k)
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }
}
