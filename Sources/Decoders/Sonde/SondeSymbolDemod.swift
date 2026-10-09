// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Symbolempfänger für Radiosonden mit Manchester-codierter FSK (Graw DFM, Meteomodem M10, Meteosis M20) aus FM-Diskriminator-Audio.
///
/// Ein Rahmen beginnt mit einem festen Kopf aus Rohsymbolen. Der Empfänger sucht ihn mit einer Korrelation (beide Polaritäten),
/// liest danach eine feste Zahl Symbole und führt den Takt dabei nach (Gardner-Fehlerdetektor, Schleife zweiter Ordnung).
/// Der Aufbau ist unabhängig von der Abtastrate; bei nur 5 Abtastwerten je Symbol (M10/M20 mit 48 kHz) interpoliert er zwischen den Abtastwerten.
final class SymbolBurstDemodulator {
    /// Ein gelesener Rahmenabschnitt hinter dem Kopf
    struct Burst {
        /// Weiche Symbolwerte (Polarität korrigiert: positiv entspricht dem Kopfmuster), auf mittleren Betrag 1 normiert
        var symbols: [Float]
        /// Güte der Kopfkorrelation (0 … 1)
        var score: Float
        /// Das Signal lag mit umgekehrter Polarität an
        var inverted: Bool
        /// Audiozeit des Kopfendes in Sekunden
        var time: Double
        /// Nachgeführte Symbolrate in Bd
        var symbolRate: Double
    }

    let sampleRate: Double
    let symbolRate: Double
    private let header: [Float]
    private let bodySymbols: Int
    private let threshold: Float
    private let tolerance: Double
    private let earlyCount: Int
    /// Prüfung der ersten Symbole nach dem Kopf; fällt sie durch, wird der Treffer verworfen (Schutz vor Zufallstreffern)
    var earlyCheck: (([Float]) -> Bool)?
    var onBurst: ((Burst) -> Void)?

    private static let capacity = 1 << 18
    private static let mask = capacity - 1
    private var cum = [Double](repeating: 0, count: SymbolBurstDemodulator.capacity)
    /// Zahl der bisher verarbeiteten Abtastwerte; `cum[n & mask]` ist die Summe aller Werte davor
    private var n = 0
    private var dc: Float = 0
    private let dcAlpha: Float
    private var levelAvg: Float = 0
    /// Eingangspegel (Mittelwert des Betrags nach Abzug des Gleichanteils)
    var level: Float { levelAvg }
    /// Zahl der Köpfe, die die Prüfung bestanden haben
    private(set) var headers = 0

    private var searchFrom = 0
    private let nominalSPS: Double

    private var collecting = false
    private var pos = 0.0
    private var sps = 0.0
    private var polarity: Float = 1
    private var amplitude: Float = 1
    private var previous: Float = 0
    private var soft: [Float] = []
    private var burstScore: Float = 0
    private var burstTime = 0.0

    /// Schleifenverstärkungen (Phase und Takt) der Taktnachführung
    private let kp = 0.4
    private let ki = 0.04

    /// - Parameters:
    ///   - header: Kopfmuster als Rohsymbole (+1 / −1), ein Wert je Symbol
    ///   - bodySymbols: Zahl der Symbole, die hinter dem Kopf gelesen werden
    ///   - tolerance: größte Abweichung der Symbolrate vom Nennwert (Anteil, z. B. 0,01)
    init(sampleRate: Double, symbolRate: Double, header: [Float], bodySymbols: Int, threshold: Float, tolerance: Double = 0.01, earlyCount: Int = 0) {
        self.sampleRate = sampleRate
        self.symbolRate = symbolRate
        self.header = header
        self.bodySymbols = bodySymbols
        self.threshold = threshold
        self.tolerance = tolerance
        self.earlyCount = earlyCount
        nominalSPS = sampleRate / symbolRate
        sps = nominalSPS
        dcAlpha = Float(1 - exp(-1 / (0.03 * sampleRate)))
        precondition(nominalSPS >= 2.5, "Abtastrate zu niedrig für diese Symbolrate")
    }

    func reset() {
        for i in 0..<cum.count { cum[i] = 0 }
        n = 0
        dc = 0
        levelAvg = 0
        history.removeAll()
        pending = nil
        searchFrom = 0
        collecting = false
        soft.removeAll(keepingCapacity: true)
        sps = nominalSPS
    }

    // MARK: Summen

    /// Summe aller Abtastwerte bis zur (gebrochenen) Stelle x, linear zwischen den Abtastwerten
    @inline(__always)
    private func sum(_ x: Double) -> Double {
        let i = Int(x.rounded(.down))
        let f = x - Double(i)
        let a = cum[i & Self.mask]
        let b = cum[(i + 1) & Self.mask]
        return a + f * (b - a)
    }

    // MARK: Eingang

    func process(_ samples: UnsafeBufferPointer<Float>) {
        for x in samples {
            dc += dcAlpha * (x - dc)
            let y = x - dc
            levelAvg += 0.0005 * (abs(y) - levelAvg)
            cum[(n + 1) & Self.mask] = cum[n & Self.mask] + Double(y)
            n += 1
            if collecting { collectStep() } else { searchStep() }
        }
    }

    // MARK: Kopfsuche

    /// Verlauf der letzten Korrelationswerte: normiert (für die Schwelle) und unnormiert (für die Lage der Spitze)
    private var history: [(score: Float, num: Float, mean: Float)] = []
    private lazy var historyHalf = max(2, Int((nominalSPS / 2).rounded(.up)))

    private func searchStep() {
        let len = header.count
        guard n >= searchFrom, Double(n) > Double(len + 2) * sps else {
            if !history.isEmpty { history.removeAll(keepingCapacity: true) }
            pending = nil
            return
        }
        let te = Double(n)
        var num: Float = 0, den: Float = 0
        var previousSum = sum(te - Double(len) * sps)
        for k in 0..<len {
            let next = sum(te - Double(len - 1 - k) * sps)
            let v = Float(next - previousSum)
            num += header[k] * v
            den += abs(v)
            previousSum = next
        }
        let score: Float = den > 0 ? num / den : 0
        history.append((score, abs(num), den / Float(len)))
        let window = 2 * historyHalf + 1
        if history.count > window { history.removeFirst(history.count - window) }
        guard history.count == window else { commitPending(); return }
        defer { commitPending() }

        // Die normierte Korrelation ist bei sauberem Signal auf einem breiten Plateau genau 1: die Lage bestimmt die unnormierte Korrelation,
        // sie ist am größten, wenn die Integrationsfenster mittig auf den Symbolen liegen. Geprüft wird die Mitte des Fensters.
        let center = history[historyHalf]
        guard center.score.magnitude >= threshold else { return }
        for (i, h) in history.enumerated() where i != historyHalf {
            if i < historyHalf ? h.num > center.num : h.num >= center.num { return }
        }
        // Das Signal muss so stark sein wie der Eingangspegel; Rauschen hat im Symbolmittel einen viel kleineren Betrag
        guard center.mean >= 0.5 * levelAvg * Float(sps) else { return }
        let a = history[historyHalf - 1].num, b = center.num, c = history[historyHalf + 1].num
        let denom = a - 2 * b + c
        let delta = denom < -1e-9 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / denom))) : 0
        let end = Double(n - historyHalf) + delta
        // Vor dem Kopf läuft oft ein langer, periodischer Vorlauf, der dem Kopf in vielen Lagen ähnelt (Korrelation um 0,75).
        // Deshalb zählt erst der beste Treffer, nach dem 24 Symbole lang kein besserer mehr folgt.
        lastHit = n
        if pending == nil || center.score.magnitude > pending!.score.magnitude + 0.02 {
            pending = (end, center.score, center.mean)
        }
    }

    /// Bester Treffer, der noch auf einen besseren wartet: Ende des Kopfes, Güte (mit Vorzeichen), mittlerer Symbolbetrag
    private var pending: (end: Double, score: Float, mean: Float)?
    private var lastHit = 0

    private func commitPending() {
        guard let p = pending, Double(n - lastHit) > 24 * sps else { return }
        pending = nil
        history.removeAll(keepingCapacity: true)
        beginBurst(headerEnd: p.end, score: p.score, meanAbs: p.mean)
    }

    private func beginBurst(headerEnd: Double, score: Float, meanAbs: Float) {
        collecting = true
        pos = headerEnd
        sps = nominalSPS
        polarity = score < 0 ? -1 : 1
        amplitude = max(meanAbs, 1e-9)
        previous = polarity * Float(sum(pos) - sum(pos - sps))
        soft.removeAll(keepingCapacity: true)
        burstScore = abs(score)
        burstTime = headerEnd / sampleRate
    }

    // MARK: Symbole lesen

    private func collectStep() {
        while collecting, Double(n) >= pos + sps {
            let i = polarity * Float(sum(pos + sps) - sum(pos))
            // Gardner: Wert in der Mitte zwischen den Symbolen mal Änderung der Symbolwerte
            let boundary = polarity * Float(sum(pos + sps / 2) - sum(pos - sps / 2))
            var e = boundary * (i - previous) / (amplitude * amplitude)
            e = max(-2, min(2, e))
            // e ≈ 4·d/sps bei Übergängen (d: Lage hinter der wahren Grenze in Abtastwerten)
            let d = Double(e) * sps / 4
            amplitude += 0.02 * (abs(i) - amplitude)
            if amplitude < 1e-9 { amplitude = 1e-9 }
            previous = i
            soft.append(i)
            pos += sps - kp * d
            sps = max(nominalSPS * (1 - tolerance), min(nominalSPS * (1 + tolerance), sps - ki * d))

            if soft.count == earlyCount, let check = earlyCheck {
                let norm = meanAbs(soft)
                if !check(soft.map { $0 / norm }) {
                    finish(emit: false)
                    return
                }
            }
            if soft.count >= bodySymbols {
                finish(emit: true)
            }
        }
    }

    private func meanAbs(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += abs(x) }
        return max(s / Float(max(v.count, 1)), 1e-9)
    }

    private func finish(emit: Bool) {
        collecting = false
        searchFrom = max(n, Int(pos + Double(header.count) * sps * 0.95))
        history.removeAll(keepingCapacity: true)
        pending = nil
        guard emit else { soft.removeAll(keepingCapacity: true); return }
        headers += 1
        let norm = meanAbs(soft)
        let burst = Burst(symbols: soft.map { $0 / norm }, score: burstScore, inverted: polarity < 0, time: burstTime, symbolRate: sampleRate / sps)
        soft.removeAll(keepingCapacity: true)
        onBurst?(burst)
    }
}
