// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// YSF-Rahmenautomat über dem 4-Pegel-Empfänger (`FourFSKSlicer`): Synchronmuster in beiden Polaritäten suchen, dann Rahmen
// alle 480 Symbole lesen. Fehlt ein Synchronmuster, läuft der Takt weiter (bis zu 4 Rahmen), danach gilt das Signal als verloren.

public struct YSFFrame: Sendable {
    /// `nil`, wenn der FICH nicht lesbar war und auch kein vorheriger Rahmen zum Ableiten da war
    public var fich: YSFFich?
    /// FICH war nicht lesbar: Angaben vom vorherigen Rahmen übernommen (Rahmennummer weitergezählt)
    public var inferred = false
    public var texts: [YSFText] = []
    /// Sprachrahmen im Format des Sprachsticks (V/D-Modus 2: bis zu 5 mal 9 Byte)
    public var voice: [[UInt8]] = []
    /// Uneinige Wiederholungen je Sprachrahmen (0 … 27): Maß für die Fehler im Sprachkanal
    public var voiceDisagreements: [Int] = []
    /// Der Sprachanteil ist nicht entschlüsselbar (V/D-Modus 1, Vollrate-Sprache)
    public var voiceUnsupported = false
}

public enum YSFEvent: Sendable {
    case frame(YSFFrame)
    case lost
}

public struct YSFFramerStats: Equatable, Sendable {
    public var syncs = 0
    public var frames = 0
    public var fichBad = 0
    public var inferred = 0
    public var syncsMissed = 0
    public var lost = 0
}

public final class YSFFramer {
    public var onEvent: ((YSFEvent) -> Void)?
    public private(set) var stats = YSFFramerStats()
    public private(set) var inverted = false
    public var isLocked: Bool { locked }
    /// Schwelle der Korrelation für die erste Synchronisation
    public var acquireThreshold: Float = 0.7

    private var locked = false
    private var recent = [Float](repeating: 0, count: YSF.syncSymbols)
    private var frameSymbols: [Float] = []
    private var syncSymbols: [Float] = []
    private var phaseSync = true            // gerade die 20 Synchronsymbole sammeln (im gesperrten Zustand)
    private var missed = 0
    private var last: YSFFich?
    /// Einrasten: nach dem Überschreiten der Schwelle noch einige Symbole abwarten und den besten Treffer nehmen
    private var acquireCountdown = 0
    private var acquireBest: Float = 0
    private var acquireTail: [Float] = []
    private var firstFrameFailures = 0
    private static let patternEnergy = YSF.syncLevels.reduce(0) { $0 + $1 * $1 }

    public init() {}

    public func reset() {
        locked = false
        recent = [Float](repeating: 0, count: YSF.syncSymbols)
        frameSymbols.removeAll(keepingCapacity: true)
        syncSymbols.removeAll(keepingCapacity: true)
        inverted = false
        last = nil
        missed = 0
        acquireCountdown = 0
        acquireTail.removeAll()
        firstFrameFailures = 0
    }

    private static func correlation(_ window: [Float]) -> Float {
        var dot: Float = 0, energy: Float = 0
        for i in 0..<YSF.syncSymbols { dot += window[i] * YSF.syncLevels[i]; energy += window[i] * window[i] }
        return dot / max(1e-6, (energy * patternEnergy).squareRoot())
    }

    /// Ein Symbol (−3 … +3)
    public func push(symbol raw: Float) {
        recent.removeFirst()
        recent.append(raw)
        // Gesperrt und bestätigt (ein Rahmen mit lesbarem FICH ist durch): der Takt läuft über die Rahmen weiter
        if locked && last != nil {
            lockedStep(inverted ? -raw : raw)
            return
        }
        // Suche (und unbestätigte Sperre: ein besseres Synchronmuster hat Vorrang vor einem Zufallstreffer im Rauschen)
        let c = Self.correlation(recent)
        if acquireCountdown > 0 {
            if abs(c) > abs(acquireBest) { acquireBest = c; acquireTail.removeAll(keepingCapacity: true) } else { acquireTail.append(raw) }
            acquireCountdown -= 1
            if acquireCountdown == 0 {
                inverted = acquireBest < 0
                locked = true
                stats.syncs += 1
                frameSymbols = inverted ? acquireTail.map { -$0 } : acquireTail
                acquireTail.removeAll(keepingCapacity: true)
                phaseSync = false
                missed = 0
                firstFrameFailures = 0
            }
            return
        }
        // Bei unbestätigter Sperre nur ein klarer Treffer (sonst wirft ein Zufallstreffer in den Nutzdaten den ersten Rahmen aus dem Takt)
        if abs(c) >= (locked ? max(acquireThreshold, 0.9) : acquireThreshold) {
            acquireBest = c
            acquireTail.removeAll(keepingCapacity: true)
            acquireCountdown = 3
            locked = false
            frameSymbols.removeAll(keepingCapacity: true)
            return
        }
        if locked { lockedStep(inverted ? -raw : raw) }
    }

    /// Ein Symbol im gesperrten Zustand (`s` schon in Normalpolarität)
    private func lockedStep(_ s: Float) {
        if phaseSync {
            syncSymbols.append(s)
            if syncSymbols.count == YSF.syncSymbols {
                let c = Self.correlation(syncSymbols)
                syncSymbols.removeAll(keepingCapacity: true)
                if c >= 0.5 { missed = 0; stats.syncs += 1 } else {
                    missed += 1
                    stats.syncsMissed += 1
                    if missed > 4 { loseLock(); return }
                }
                phaseSync = false
            }
            return
        }
        frameSymbols.append(s)
        if frameSymbols.count == YSF.fichSymbols + YSF.payloadSymbols {
            process(frameSymbols)
            frameSymbols.removeAll(keepingCapacity: true)
            phaseSync = true
        }
    }

    private func loseLockQuietly() {
        locked = false
        acquireCountdown = 0
        firstFrameFailures = 0
        recent = [Float](repeating: 0, count: YSF.syncSymbols)
        frameSymbols.removeAll(keepingCapacity: true)
        syncSymbols.removeAll(keepingCapacity: true)
        inverted = false
    }

    private func loseLock() {
        stats.lost += 1
        locked = false
        recent = [Float](repeating: 0, count: YSF.syncSymbols)
        frameSymbols.removeAll(keepingCapacity: true)
        syncSymbols.removeAll(keepingCapacity: true)
        last = nil
        inverted = false
        acquireCountdown = 0
        firstFrameFailures = 0
        onEvent?(.lost)
    }

    // MARK: Rahmen

    private func process(_ symbols: [Float]) {
        var frame = YSFFrame()
        var fich = YSFFich.decode(symbols: symbols[0..<YSF.fichSymbols])
        if fich == nil {
            stats.fichBad += 1
            if let previous = last {
                var guess = previous
                guess.fn = previous.fn >= previous.ft ? 0 : previous.fn + 1
                fich = guess
                frame.inferred = true
                stats.inferred += 1
            }
        }
        // Die erste Synchronisation gilt erst, wenn der FICH lesbar ist (sonst war es ein Zufallstreffer im Rauschen)
        if fich == nil {
            firstFrameFailures += 1
            if firstFrameFailures >= 2 { loseLockQuietly() }
            return
        }
        firstFrameFailures = 0
        frame.fich = fich
        stats.frames += 1
        guard let f = fich else { return }
        if !frame.inferred { last = f }
        let payload = Array(symbols[YSF.fichSymbols...])

        if f.isHeader || f.isTerminator {
            // zwei Kanäle zu je 180 Symbolen, die Stücke zu 36 Symbolen wechseln sich ab
            var first: [Float] = [], second: [Float] = []
            for chunk in 0..<10 {
                let part = payload[(chunk * 36)..<(chunk * 36 + 36)]
                if chunk % 2 == 0 { first += part } else { second += part }
            }
            if let a = YSFDataChannel.decodeFull(symbols: first) {
                if f.cm == 1 { frame.texts.append(.radioIDs(destination: YSFDataChannel.text(a[0..<5]), source: YSFDataChannel.text(a[5..<10]))) }
                else { frame.texts.append(.destination(YSFDataChannel.text(a[0..<10]))) }
                frame.texts.append(.source(YSFDataChannel.text(a[10..<20])))
            }
            if let b = YSFDataChannel.decodeFull(symbols: second) {
                frame.texts.append(.uplink(YSFDataChannel.text(b[0..<10])))
                frame.texts.append(.downlink(YSFDataChannel.text(b[10..<20])))
            }
        } else if f.dt == 2 {
            var dch: [Float] = []
            for i in 0..<5 {
                let base = i * 72
                dch += payload[base..<(base + 20)]
                let v = YSFVoice.frame(payload[(base + 20)..<(base + 72)])
                frame.voice.append(v.ambe)
                frame.voiceDisagreements.append(v.disagreements)
            }
            if let bytes = YSFDataChannel.decodeVD2(symbols: dch), let t = YSFDataChannel.textVD2(fn: f.fn, cm: f.cm, bytes: bytes) { frame.texts.append(t) }
        } else {
            frame.voiceUnsupported = (f.dt == 0 || f.dt == 3)
        }
        onEvent?(.frame(frame))
    }
}
