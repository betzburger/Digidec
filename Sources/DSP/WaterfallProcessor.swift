import Foundation
import os

/// Berechnet aus dem 8-kHz-Strom der Pipeline Spektrumzeilen für Wasserfall und Spektrumanzeige.
/// Läuft als Senke auf der Verarbeitungs-Queue; die Anzeige holt die fertigen Zeilen mit `takeRows()`.
public final class WaterfallProcessor: @unchecked Sendable {
    public static let fftSize = 2048          // 3,9 Hz je Bin bei 8 kHz – reicht für 85 Hz Shift (DDH47)
    public static let hop = 256               // 32 ms → 31,25 Zeilen/s
    public static let maxQueuedRows = 64

    public let sampleRate: Double
    public var binCount: Int { Self.fftSize / 2 }
    public var binWidth: Double { sampleRate / Double(Self.fftSize) }
    public var rowsPerSecond: Double { sampleRate / Double(Self.hop) }

    private let analyzer: SpectrumAnalyzer
    // Nur auf der Verarbeitungs-Queue
    private var history: [Float]
    private var pending = 0
    private var rowBuffer: [Float]
    private var sortBuffer: [Float]

    // Geteilt mit der Anzeige
    private let lock = OSAllocatedUnfairLock()
    private var rows: [[Float]] = []
    private var averaged: [Float]
    private var noiseFloor: Float = -100
    private var hasFloor = false

    public init(sampleRate: Double = AudioPipeline.decoderSampleRate) {
        self.sampleRate = sampleRate
        analyzer = SpectrumAnalyzer(size: Self.fftSize, sampleRate: sampleRate)!
        history = [Float](repeating: 0, count: Self.fftSize)
        rowBuffer = [Float](repeating: -140, count: Self.fftSize / 2)
        sortBuffer = rowBuffer
        averaged = rowBuffer
    }

    /// Senke für `AudioPipeline.addSink`
    public func consume(_ samples: UnsafeBufferPointer<Float>) {
        var index = 0
        while index < samples.count {
            let take = min(Self.hop - pending, samples.count - index)
            // Verlauf um `take` nach links schieben und neue Samples hinten anfügen
            history.withUnsafeMutableBufferPointer { h in
                let base = h.baseAddress!
                base.update(from: base + take, count: Self.fftSize - take)
                (base + Self.fftSize - take).update(from: samples.baseAddress! + index, count: take)
            }
            pending += take
            index += take
            if pending == Self.hop {
                pending = 0
                produceRow()
            }
        }
    }

    private func produceRow() {
        history.withUnsafeBufferPointer { h in
            rowBuffer.withUnsafeMutableBufferPointer { r in
                analyzer.process(h.baseAddress!, into: r.baseAddress!)
            }
        }
        // Rauschboden: Median des Spektrums, langsam geglättet (Signale verschieben den Median kaum)
        sortBuffer = rowBuffer
        sortBuffer.sort()
        let median = sortBuffer[sortBuffer.count / 2]
        let row = rowBuffer

        lock.withLockUnchecked {
            if hasFloor {
                noiseFloor += (median - noiseFloor) / 20
            } else {
                noiseFloor = median
                hasFloor = true
            }
            for i in 0..<averaged.count {
                averaged[i] += (row[i] - averaged[i]) * 0.3
            }
            rows.append(row)
            if rows.count > Self.maxQueuedRows {
                rows.removeFirst(rows.count - Self.maxQueuedRows)
            }
        }
    }

    /// Neue Zeilen seit dem letzten Aufruf (älteste zuerst)
    public func takeRows() -> [[Float]] {
        lock.withLockUnchecked {
            defer { rows.removeAll(keepingCapacity: true) }
            return rows
        }
    }

    /// Geglättetes aktuelles Spektrum und geschätzter Rauschboden (dBFS je Bin)
    public func snapshot() -> (spectrum: [Float], noiseFloor: Float) {
        lock.withLockUnchecked { (averaged, noiseFloor) }
    }

    public func reset() {
        lock.withLockUnchecked {
            rows.removeAll()
            hasFloor = false
            for i in 0..<averaged.count { averaged[i] = -140 }
        }
    }
}
