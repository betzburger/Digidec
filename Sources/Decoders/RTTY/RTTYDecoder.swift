// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import os

/// Laufzeitteil des RTTY-Moduls: der fldigi-Kern als Senke an der Pipeline.
/// Alle Kern-Aufrufe laufen auf der Verarbeitungs-Queue der Pipeline; die Anzeige holt die Ergebnisse
/// mit `takeOutput()` ab (Text seit dem letzten Abruf, letzter Status, XY-Punkte).
public final class RTTYDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        /// Empfangstext in Abschnitten: Rohtext und (bei SYNOP) Klartextblöcke
        public var segments: [TextSegment]
        public var status: FldigiRTTYCore.Status?
        public var scope: [CGPoint]

        /// Nur der Rohtext (ohne Klartextblöcke)
        public var text: String { segments.filter { !$0.decoded }.map(\.text).joined() }
    }

    private let pipeline: AudioPipeline
    // Nur auf der Verarbeitungs-Queue
    private var core: FldigiRTTYCore?
    private var enabled = true
    private var samplesSinceScope = 0
    private var synop: SynopDecoder?
    private var synopOn = false

    // Geteilt mit der Anzeige
    private let lock = OSAllocatedUnfairLock()
    private var pending: [TextSegment] = []
    private var lastStatus: FldigiRTTYCore.Status?
    private var lastScope: [CGPoint] = []

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
        // Stationslisten und SYNOP-Decoder auf der Verarbeitungs-Queue anlegen (dort laufen alle Aufrufe)
        pipeline.perform { [weak self] in
            SynopDecoder.loadStations()
            self?.synop = SynopDecoder { [weak self] seg in self?.appendSegment(seg) }
        }
    }

    /// Kern anlegen oder umstellen (wie fldigi `restart()` bei geänderten Einstellungen).
    public func configure(parameters: RTTYParameters, options: RTTYDecodeOptions, centerHz: Double) {
        let coreOptions = Self.coreOptions(parameters, options)
        let synopWanted = options.synopDecoding
        pipeline.perform { [self] in
            if synopOn && !synopWanted { synop?.flush() }
            synopOn = synopWanted
            if let core {
                if core.parameters != parameters || core.options != coreOptions {
                    core.configure(parameters: parameters, options: coreOptions)
                }
                core.setCenter(centerHz)
            } else {
                core = FldigiRTTYCore(parameters: parameters, options: coreOptions, centerHz: centerHz) { [weak self] ch in
                    self?.append(ch)
                }
            }
        }
    }

    /// Mitte von Hand gesetzt (Klick im Wasserfall, Auftrag)
    public func setCenter(_ hz: Double) {
        pipeline.perform { [self] in core?.setCenter(hz) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in enabled = on }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll(keepingCapacity: true) }
            return Output(segments: pending, status: lastStatus, scope: lastScope)
        }
    }

    // MARK: - Verarbeitungs-Queue

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let core else { return }
        core.process(samples)
        let status = core.status
        samplesSinceScope += samples.count
        var scope: [CGPoint]?
        if samplesSinceScope >= 400 {               // ≈ 20 Hz
            samplesSinceScope = 0
            scope = core.scopePoints(max: 256)
        }
        lock.withLockUnchecked {
            lastStatus = status
            if let scope { lastScope = scope }
        }
    }

    /// Zeichen aus dem RTTY-Kern: bei aktiver SYNOP-Decodierung durch den SYNOP-Decoder (wie fldigi rtty::rx())
    private func append(_ ch: Character) {
        if synopOn, let synop {
            synop.feed(ch)
        } else {
            appendSegment(TextSegment(String(ch)))
        }
    }

    private func appendSegment(_ seg: TextSegment) {
        lock.withLockUnchecked {
            if let last = pending.last, last.decoded == seg.decoded {
                pending[pending.count - 1].text += seg.text
            } else {
                pending.append(seg)
            }
        }
    }

    static func coreOptions(_ p: RTTYParameters, _ o: RTTYDecodeOptions) -> FldigiRTTYCore.Options {
        var c = FldigiRTTYCore.Options()
        c.afcOn = o.afc != .off
        c.afcSpeed = max(0, o.afc.rawValue)
        c.squelchOn = o.squelchOn
        c.squelch = o.squelch
        c.cwi = o.tones.rawValue
        c.unshiftOnSpace = p.unshiftOnSpace
        c.ita2 = p.ita2
        c.trueScope = o.trueScope
        c.filterK = o.filterK
        c.lowCutoff = 0
        c.highCutoff = AudioPipeline.decoderSampleRate / 2
        return c
    }
}
