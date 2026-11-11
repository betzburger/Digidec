// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Taktpuffer des HF-Wasserfalls: Zeilen kommen in Schüben an (Blöcke des Empfängers, Zeitgeber der Oberfläche; gemessen
/// unter Linux: ein Drittel der Abrufe mit zwei Zeilen, Abstände 30–100 ms statt 40) und werden hier einzeln im Zeilentakt
/// freigegeben. Zu jeder freigegebenen Zeile gehört ein Rollzeitraum `scrollStart…scrollEnd`, in dem die Ansicht sie
/// weich ins Bild schiebt; so bewegt sich der Wasserfall bei jeder Bildwiederholrate gleichmäßig.
///
/// Regeln: Nach einer Lücke (Start, Pause, Umschalten) wartet die erste Zeile einen Takt, damit ein Polster von etwa einer
/// Zeile entsteht, das die Schübe auffängt. Wächst der Rückstand (Uhr des Empfängers etwas schneller), wird der Takt
/// verkürzt; läuft der Puffer leer, wird er verlängert. Ein großer Stau wird sofort bis auf zwei Zeilen abgebaut.
public struct SDRRowPacer {
    public let interval: TimeInterval
    public private(set) var queue: [[Float]] = []
    /// Fälligkeit der nächsten Zeile (Sekunden, gleiche Zeitbasis wie `now`)
    public private(set) var next: TimeInterval = -.infinity
    public private(set) var scrollStart: TimeInterval = 0
    public private(set) var scrollEnd: TimeInterval = 0

    /// Ab diesem Rückstand wird der Stau auf einmal abgebaut
    static let maxBacklog = 6

    public init(interval: TimeInterval = 1 / SDRSpectrum.rowsPerSecond) {
        self.interval = interval
    }

    public mutating func push(_ rows: [[Float]], now: TimeInterval) {
        guard !rows.isEmpty else { return }
        // Lücke: Takt neu beginnen, erste Zeile nach einem Takt (Polster)
        if queue.isEmpty, now - next > interval * 3 { next = now + interval }
        queue += rows
    }

    /// Gibt die fälligen Zeilen frei (meist keine oder eine)
    public mutating func release(now: TimeInterval) -> [[Float]] {
        guard !queue.isEmpty else { return [] }
        if queue.count > Self.maxBacklog {
            let overflow = queue.count - 2
            let out = Array(queue.prefix(overflow))
            queue.removeFirst(overflow)
            scrollStart = now
            next = now + interval
            scrollEnd = next
            return out
        }
        var out: [[Float]] = []
        while !queue.isEmpty, now >= next {
            out.append(queue.removeFirst())
            scrollStart = next
            next += interval * (queue.count > 2 ? 0.85 : (queue.isEmpty ? 1.1 : 1))
            scrollEnd = next
        }
        return out
    }

    /// Wie weit die zuletzt freigegebene Zeile ins Bild gerollt ist (0 = gerade freigegeben, 1 = ganz sichtbar)
    public func progress(at now: TimeInterval) -> Double {
        guard scrollEnd > scrollStart else { return 1 }
        return min(1, max(0, (now - scrollStart) / (scrollEnd - scrollStart)))
    }

    public mutating func reset() {
        queue.removeAll()
        next = -.infinity
        scrollStart = 0
        scrollEnd = 0
    }
}
