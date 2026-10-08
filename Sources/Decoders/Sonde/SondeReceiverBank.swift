// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Alle Sondenarten zugleich: RS41, DFM, M10 und M20 laufen parallel auf demselben Audio; wessen Kopf passt, liefert die Rahmen.
public final class SondeReceiverBank {
    public var onTelemetry: ((SondeTelemetry) -> Void)?
    private let receivers: [any SondeReceiving]
    public let sampleRate: Double

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        receivers = [RS41Receiver(sampleRate: sampleRate), DFMReceiver(sampleRate: sampleRate), M10Receiver(sampleRate: sampleRate)]
        for r in receivers { r.onTelemetry = { [weak self] t in self?.onTelemetry?(t) } }
    }

    /// Zähler der Empfänger, die Rahmen lesen; liest keiner etwas, die Summe aller (damit die Diagnose „Signal, aber nichts lesbar“ zeigen kann).
    /// Fremde Empfänger sprechen auf Signale anderer Sondenarten gelegentlich an; deren Fehlversuche sollen nicht zählen.
    public var stats: SondeStats {
        let all = receivers.map(\.stats)
        let active = all.filter { $0.frames + $0.partial > 0 }
        let used = active.isEmpty ? all : active
        return used.dropFirst().reduce(used[0]) { $0 + $1 }
    }
    public var level: Double { receivers.map(\.level).max() ?? 0 }
    public func process(_ samples: UnsafeBufferPointer<Float>) { for r in receivers { r.process(samples) } }
    public func reset() { for r in receivers { r.reset() } }
    public func resetStats() { for r in receivers { r.resetStats() } }
}
