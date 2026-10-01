import Foundation
import os

/// Laufzeitteil des NAVTEX-Moduls: der fldigi-Kern als 11 025-Hz-Senke an der Pipeline.
/// Alle Kern-Aufrufe auf der Verarbeitungs-Queue; die Anzeige holt Text, Nachrichten und Status mit `takeOutput()`.
public final class NavtexDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var text: String
        public var messages: [NavtexMessage]
        public var status: FldigiNavtexCore.Status?
    }

    private let pipeline: AudioPipeline
    // Nur auf der Verarbeitungs-Queue
    private var core: FldigiNavtexCore?
    private var enabled = false

    private let lock = OSAllocatedUnfairLock()
    private var pendingText = ""
    private var pendingMessages: [NavtexMessage] = []
    private var lastStatus: FldigiNavtexCore.Status?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: FldigiNavtexCore.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(options: FldigiNavtexCore.Options, centerHz: Double) {
        pipeline.perform { [self] in
            if let core {
                if core.options != options { core.configure(options) }
                core.setCenter(centerHz)
            } else {
                core = FldigiNavtexCore(options: options, centerHz: centerHz, onChar: { [weak self] ch in
                    self?.lock.withLockUnchecked { self?.pendingText.append(ch) }
                }, onMessage: { [weak self] msg in
                    self?.lock.withLockUnchecked { self?.pendingMessages.append(msg) }
                })
            }
        }
    }

    public func setCenter(_ hz: Double) {
        pipeline.perform { [self] in core?.setCenter(hz) }
    }

    /// Nur das aktive Modul decodiert (spart Rechenzeit, kein Text im Hintergrund)
    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in enabled = on }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer {
                pendingText = ""
                pendingMessages.removeAll()
            }
            return Output(text: pendingText, messages: pendingMessages, status: lastStatus)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let core else { return }
        core.process(samples)
        let status = core.status
        lock.withLockUnchecked { lastStatus = status }
    }
}
