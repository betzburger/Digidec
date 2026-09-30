import Foundation
import os

/// Laufzeitteil des RTTY-Moduls: der fldigi-Kern als Senke an der Pipeline.
/// Alle Kern-Aufrufe laufen auf der Verarbeitungs-Queue der Pipeline; die Anzeige holt die Ergebnisse
/// mit `takeOutput()` ab (Text seit dem letzten Abruf, letzter Status, XY-Punkte).
public final class RTTYDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var text: String
        public var status: FldigiRTTYCore.Status?
        public var scope: [CGPoint]
    }

    private let pipeline: AudioPipeline
    // Nur auf der Verarbeitungs-Queue
    private var core: FldigiRTTYCore?
    private var enabled = true
    private var samplesSinceScope = 0

    // Geteilt mit der Anzeige
    private let lock = OSAllocatedUnfairLock()
    private var pendingText = ""
    private var lastStatus: FldigiRTTYCore.Status?
    private var lastScope: [CGPoint] = []

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    /// Kern anlegen oder umstellen (wie fldigi `restart()` bei geänderten Einstellungen).
    public func configure(parameters: RTTYParameters, options: RTTYDecodeOptions, centerHz: Double) {
        let coreOptions = Self.coreOptions(parameters, options)
        pipeline.perform { [self] in
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
            defer { pendingText = "" }
            return Output(text: pendingText, status: lastStatus, scope: lastScope)
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

    private func append(_ ch: Character) {
        lock.withLockUnchecked {
            pendingText.append(ch)
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
