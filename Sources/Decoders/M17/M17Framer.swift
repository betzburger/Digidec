// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// M17-Rahmenautomat über dem 4-Pegel-Empfänger: Synchronwort suchen (LSF- und Strom-Wort sind zueinander negiert, also zugleich
// die Frage nach der Polarität), den ersten Rahmen auf Gültigkeit prüfen (CRC des LSF, Golay und Faltungscode des Stroms), dann
// im Takt von 192 Symbolen weiterlesen. Aus den LICH-Anteilen der Strom-Rahmen setzt sich der LSF nach sechs Rahmen zusammen
// (später Einstieg); das Ende zeigt das Ende-Bit, das Synchronwort 0x555D oder Funkstille an.

public enum M17Event: Sendable {
    /// Ein Gespräch beginnt (der LSF folgt, sobald bekannt)
    case callStart
    /// Der LSF ist bekannt (aus dem LSF-Rahmen oder aus sechs LICH-Anteilen)
    case lsf(M17LSF, viaLICH: Bool)
    case frame(M17StreamFrame)
    /// Ein Paket (Paketmodus) ist vollständig empfangen
    case packet(M17Packet)
    /// BERT-Rahmen: bisher gezählte Bit und Fehler, `synced` = Folge eingerastet
    case bert(bits: Int, errors: Int, synced: Bool)
    /// Die Signatur eines Stroms (Rahmen 0x7FFC … 0x7FFF) ist angekommen; geprüft wird später mit dem Schlüssel des Absenders
    case signature(M17SignedStream)
    case callEnd(lost: Bool)
    case lost
}

public struct M17FramerStats: Equatable, Sendable {
    public var syncs = 0
    public var lsfFrames = 0
    public var streamFrames = 0
    public var badFrames = 0
    public var lsfFromLICH = 0
    public var lsfBad = 0
    public var calls = 0
    public var packetFrames = 0
    public var packets = 0
    /// Pakete mit falscher CRC oder fehlenden Rahmen
    public var packetsBad = 0
    public var bertFrames = 0
    public var bertBits = 0
    public var bertErrors = 0
    public var bertSynced = false
    public var lost = 0
    public var endMarkers = 0
    /// Mittlerer Anteil gestörter Bits der gültigen Strom-Rahmen (gleitend)
    public var errorRate: Float = 0
}

public final class M17Framer {
    public var onEvent: ((M17Event) -> Void)?
    public private(set) var stats = M17FramerStats()
    public private(set) var inverted = false
    public var isLocked: Bool { locked }
    public var acquireThreshold: Float = 0.85

    private var buffer: [Float] = []
    private var base = 0
    private var count = 0
    private var locked = false
    private var nextSync = 0
    private var misses = 0
    private var callActive = false
    private var chunks = [[UInt8]?](repeating: nil, count: 6)
    private var lsfKnown = false
    private var lastLSF: M17LSF?
    /// Seit dem letzten LSF-Rahmen kam ein Strom- oder Paket-Rahmen (sonst ist ein gleicher LSF nur eine Wiederholung)
    private var framesSinceLSF = false
    // Einrasten am besten Treffer
    private var acquireCountdown = 0
    private var acquireBestIndex = 0
    private var acquireBestValue: Float = 0
    private var pending: [Int] = []
    private var assembler = M17PacketAssembler()
    private var bertReceiver = M17BERTReceiver()
    // Digest über die Strom-Nutzlasten und gesammelte Signaturteile
    private var digest = [UInt8](repeating: 0, count: 16)
    private var digestIntact = true
    private var nextFrameNumber = 0
    private var signatureParts = [[UInt8]?](repeating: nil, count: 4)

    public init() {}

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        base = 0; count = 0
        locked = false
        inverted = false
        misses = 0
        callActive = false
        chunks = [[UInt8]?](repeating: nil, count: 6)
        lsfKnown = false
        lastLSF = nil
        acquireCountdown = 0
        pending.removeAll()
        assembler.reset()
        bertReceiver.reset()
    }

    // MARK: Eingang

    public func push(symbol: Float) {
        buffer.append(symbol)
        count += 1
        if locked {
            while locked && count >= nextSync + M17.frameSymbols + 1 { processFrame() }
        } else {
            search()
            while !locked, let first = pending.first, count >= first + M17.frameSymbols {
                pending.removeFirst()
                tryAcquire(at: first)
            }
        }
        let keepFrom = locked ? nextSync - 4 : (pending.first ?? count - 400) - 4
        if keepFrom - base > 3000 {
            let drop = keepFrom - base - 1500
            buffer.removeFirst(drop)
            base += drop
        }
    }

    private func slice(_ from: Int, _ to: Int) -> ArraySlice<Float> {
        let a = from - base, b = to - base
        guard a >= 0, b <= buffer.count else { return [Float](repeating: 0, count: max(0, to - from))[...] }
        let s = buffer[a..<b]
        return inverted ? ArraySlice(s.map { -$0 }) : s
    }

    // MARK: Suche

    private func search() {
        guard count - base >= M17.syncSymbols else { return }
        let window = buffer[(buffer.count - M17.syncSymbols)...]
        // LSF- und Strom-Wort sind zueinander negiert: eine Korrelation genügt, ihr Vorzeichen sagt, welches von beiden (und in welcher Polarität)
        let cLSF = M17.correlation(window, M17.patterns[M17.SyncKind.lsf.rawValue])
        let cPacket = M17.correlation(window, M17.patterns[M17.SyncKind.packet.rawValue])
        let c = abs(cLSF) >= abs(cPacket) ? cLSF : cPacket
        if acquireCountdown > 0 {
            if abs(c) > abs(acquireBestValue) { acquireBestValue = c; acquireBestIndex = count - M17.syncSymbols }
            acquireCountdown -= 1
            if acquireCountdown == 0 { pending.append(acquireBestIndex) }
        } else if abs(c) >= acquireThreshold {
            acquireBestValue = c
            acquireBestIndex = count - M17.syncSymbols
            acquireCountdown = 3
        }
    }

    /// Prüft die Auslegungen eines Synchronworts (LSF/normal oder Strom/invertiert, bzw. umgekehrt; Paket und BERT ebenso): gültig ist die, bei der der Rahmen etwas ergibt
    private func tryAcquire(at start: Int) {
        guard start - base >= 0 else { return }
        let raw = Array(buffer[(start - base)..<(start - base + M17.frameSymbols)])
        let cLSF = M17.correlation(raw[0..<M17.syncSymbols], M17.patterns[M17.SyncKind.lsf.rawValue])
        let cPacket = M17.correlation(raw[0..<M17.syncSymbols], M17.patterns[M17.SyncKind.packet.rawValue])
        // Beide Wortpaare prüfen, das besser passende zuerst: LSF und Strom sind zueinander negiert, ebenso Paket und BERT
        let lsfOptions: [(kind: M17.SyncKind, flip: Bool)] = cLSF > 0 ? [(.lsf, false), (.stream, true)] : [(.stream, false), (.lsf, true)]
        let packetOptions: [(kind: M17.SyncKind, flip: Bool)] = cPacket > 0 ? [(.packet, false), (.bert, true)] : [(.bert, false), (.packet, true)]
        let options = abs(cLSF) >= abs(cPacket) ? lsfOptions + packetOptions : packetOptions + lsfOptions
        for option in options {
            let symbols = option.flip ? raw.map { -$0 } : raw
            let body = symbols[M17.syncSymbols..<M17.frameSymbols]
            switch option.kind {
            case .lsf:
                if let r = M17.decodeLSFFrame(body) {
                    lock(at: start, inverted: option.flip)
                    lsfFrame(r.lsf)
                    return
                }
            case .stream:
                if let f = M17.decodeStreamFrame(body), f.lichErrors <= 2, f.errorRate < 0.12 {
                    lock(at: start, inverted: option.flip)
                    streamFrame(f)
                    return
                }
            case .packet:
                if let f = M17.decodePacketFrame(body), f.errorRate < 0.05 {
                    lock(at: start, inverted: option.flip)
                    packetFrame(f)
                    return
                }
            case .bert:
                if let f = M17.decodeBERTFrame(body), f.errorRate < 0.05 {
                    lock(at: start, inverted: option.flip)
                    bertFrame(f.bits)
                    return
                }
            case .eot:
                break
            }
        }
    }

    private func lock(at start: Int, inverted flip: Bool) {
        stats.syncs += 1
        locked = true
        inverted = flip
        nextSync = start + M17.frameSymbols
        misses = 0
        pending.removeAll()
        acquireCountdown = 0
    }

    // MARK: Rahmen

    private func processFrame() {
        // Takt nachführen: Synchronwort im Fenster ±1 Symbol
        var best: Float = 0
        var bestKind: M17.SyncKind?
        var bestOffset = 0
        for offset in -1...1 {
            let w = slice(nextSync + offset, nextSync + offset + M17.syncSymbols)
            // Ein Fenster ohne Signal (Funkstille) darf nicht als Synchronwort durchgehen: Mindestenergie, und für das Schlusswort
            // (sechs gleiche Symbole hintereinander) eine hohe Korrelation, weil jede Gleichspannung schon 0,75 ergibt
            guard w.reduce(0, { $0 + $1 * $1 }) / Float(M17.syncSymbols) >= 1.5 else { continue }
            for kind in [M17.SyncKind.stream, .lsf, .packet, .bert, .eot] {
                let c = M17.correlation(w, M17.patterns[kind.rawValue])
                if kind == .eot && c < 0.9 { continue }
                if c > best { best = c; bestKind = kind; bestOffset = offset }
            }
        }
        var kind: M17.SyncKind?
        if best >= 0.7, let bestKind { kind = bestKind; nextSync += bestOffset }
        let start = nextSync
        nextSync += M17.frameSymbols

        if kind == .eot {
            if callActive { stats.endMarkers += 1 }          // nach einem Ende-Bit ist das Gespräch schon beendet und gezählt
            finishCall(lost: false)
            unlock()
            return
        }
        let body = slice(start + M17.syncSymbols, start + M17.frameSymbols)
        if kind == .bert {
            if let f = M17.decodeBERTFrame(body), f.errorRate <= 0.25 {
                misses = 0
                bertFrame(f.bits)
            } else {
                stats.badFrames += 1
                miss()
            }
            return
        }
        if kind == .packet {
            if let f = M17.decodePacketFrame(body), f.errorRate <= 0.25 {
                misses = 0
                packetFrame(f)
            } else {
                stats.badFrames += 1
                miss()
            }
            return
        }
        if kind == .lsf {
            if let r = M17.decodeLSFFrame(body) {
                misses = 0
                lsfFrame(r.lsf)
                return
            }
            stats.badFrames += 1
            miss()
            return
        }
        if let f = M17.decodeStreamFrame(body), f.lichErrors <= 4, f.errorRate <= 0.25 {
            misses = 0
            streamFrame(f)
        } else {
            stats.badFrames += 1
            miss()
        }
    }

    private func miss() {
        misses += 1
        if misses >= 8 { lose() }
    }

    private func unlock() {
        assembler.reset()
        locked = false
        inverted = false
        pending.removeAll()
        acquireCountdown = 0
        // Die Suche beginnt hinter dem Ende wieder bei Null
        buffer.removeAll(keepingCapacity: true)
        base = count
    }

    private func lose() {
        stats.lost += 1
        if callActive { finishCall(lost: true) }
        unlock()
        onEvent?(.lost)
    }

    // MARK: Gespräch

    private func beginCall() {
        guard !callActive else { return }
        callActive = true
        bertReceiver.reset()
        resetSignature()
        lsfKnown = false
        lastLSF = nil
        chunks = [[UInt8]?](repeating: nil, count: 6)
        stats.calls += 1
        onEvent?(.callStart)
    }

    private func finishCall(lost: Bool) {
        guard callActive else { return }
        callActive = false
        lsfKnown = false
        lastLSF = nil
        chunks = [[UInt8]?](repeating: nil, count: 6)
        onEvent?(.callEnd(lost: lost))
    }

    private func lsfFrame(_ lsf: M17LSF) {
        stats.lsfFrames += 1
        // Sendet ein Gerät den LSF mehrfach hintereinander, ist das dasselbe Gespräch
        if callActive && lsfKnown && !framesSinceLSF && lsf == lastLSF { return }
        framesSinceLSF = false
        // Ein neuer LSF mitten im Gespräch ist ein neues Gespräch (der Abschluss ging verloren)
        if callActive && lsfKnown { finishCall(lost: true) }
        beginCall()
        lsfKnown = true
        lastLSF = lsf
        onEvent?(.lsf(lsf, viaLICH: false))
    }

    private func streamFrame(_ f: M17StreamFrame) {
        stats.streamFrames += 1
        framesSinceLSF = true
        stats.errorRate += (f.errorRate - stats.errorRate) * 0.1
        beginCall()
        if f.lichErrors <= 2 { collect(f) }
        track(f)
        onEvent?(.frame(f))
        if f.isLast {
            stats.endMarkers += 1
            finishCall(lost: false)
            // Das Synchronwort 0x555D folgt noch; es beendet den Zustand „gesperrt“
        }
    }

    private func resetSignature() {
        digest = [UInt8](repeating: 0, count: 16)
        digestIntact = true
        nextFrameNumber = 0
        signatureParts = [[UInt8]?](repeating: nil, count: 4)
    }

    /// Digest weiterführen oder Signaturteil sammeln
    private func track(_ f: M17StreamFrame) {
        if f.frameNumber >= M17Signature.firstSignatureFrame {
            let part = f.frameNumber - M17Signature.firstSignatureFrame
            guard part < 4 else { return }
            signatureParts[part] = f.payload
            if f.errorRate > 0.15 { digestIntact = false }
            if part == 3 {
                let intact = digestIntact && signatureParts.allSatisfy { $0 != nil }
                let signature = signatureParts.flatMap { $0 ?? [UInt8](repeating: 0, count: 16) }
                let result = M17SignedStream(digest: digest, signature: signature, intact: intact)
                resetSignature()
                onEvent?(.signature(result))
            }
            return
        }
        // Ein Rahmen, der nicht der nächste ist (später Einstieg, Lücke) oder stark gestört war, macht den Digest unbrauchbar
        if digestIntact && f.frameNumber == nextFrameNumber && f.errorRate <= 0.15 {
            M17Signature.update(&digest, payload: f.payload)
            nextFrameNumber += 1
        } else {
            digestIntact = false
        }
    }

    private func bertFrame(_ bits: [UInt8]) {
        stats.bertFrames += 1
        beginCall()
        bertReceiver.process(bits)
        stats.bertBits = bertReceiver.bits
        stats.bertErrors = bertReceiver.errors
        stats.bertSynced = bertReceiver.synced
        onEvent?(.bert(bits: bertReceiver.bits, errors: bertReceiver.errors, synced: bertReceiver.synced))
    }

    private func packetFrame(_ f: M17PacketFrame) {
        stats.packetFrames += 1
        framesSinceLSF = true
        stats.errorRate += (f.errorRate - stats.errorRate) * 0.1
        beginCall()
        let result = assembler.add(f)
        guard result.finished else { return }
        if let packet = result.packet {
            stats.packets += 1
            if !packet.crcOK { stats.packetsBad += 1 }
            onEvent?(.packet(packet))
        } else {
            stats.packetsBad += 1
        }
        // Mit dem letzten Rahmen ist die Aussendung zu Ende (es folgt kein Schlusswort)
        finishCall(lost: false)
        unlock()
    }

    private func collect(_ f: M17StreamFrame) {
        chunks[f.lichCounter] = f.lichChunk
        guard chunks.allSatisfy({ $0 != nil }) else { return }
        let bytes = chunks.flatMap { $0! }
        chunks = [[UInt8]?](repeating: nil, count: 6)
        if let lsf = M17LSF(bytes: bytes) {
            // Bekannter LSF: nur melden, wenn sich etwas geändert hat (Textabschnitte wechseln von Überrahmen zu Überrahmen)
            guard lsf != lastLSF else { return }
            lsfKnown = true
            lastLSF = lsf
            stats.lsfFromLICH += 1
            onEvent?(.lsf(lsf, viaLICH: true))
        } else if !lsfKnown {
            stats.lsfBad += 1
        }
    }
}
