// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// D-Star-Empfänger für FM-Diskriminator-Audio (GMSK, 4800 Bd, BT 0,5, Hub ±1,2 kHz).
//
// Teil 1 (`DStarBitSlicer`): Tiefpass → Schwelle aus Spitzenwerten (schnell genug für die kurze Bitsynchronisation) →
// Bittakt aus den Nulldurchgängen nachführen → ein weicher Wert je Bit.
// Teil 2 (`DStarFramer`): Synchronmuster suchen (beide Polaritäten), Kopf lesen, Sprachrahmen schneiden, Ende erkennen.

// MARK: - Bits aus dem Audio

public final class DStarBitSlicer {
    public let sampleRate: Double
    public let sps: Double
    /// Pro Bit: Entscheidung (1 bei positivem Pegel) und weicher Wert (−1…+1)
    public var onBit: ((UInt8, Float) -> Void)?
    /// Kopplung des Taktregelkreises (Anteil des Phasenfehlers je Nulldurchgang)
    public var loopGain = 0.12

    // Tiefpass
    private let taps: [Float]
    private var ring: [Float]
    private var ringPos = 0

    // Schwelle aus Spitzenwerten
    private var peakHigh: Float = 0
    private var peakLow: Float = 0
    private let peakDecay: Float

    // Takt
    private var phase = 0.0
    private var emitted = false
    private var previous: Float = 0
    private var previousSign = false
    private var started = false

    public private(set) var level: Float = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        sps = sampleRate / DStarConstants.baud
        // Fenster-Sinc, Grenzfrequenz 3,3 kHz (Blackman)
        let count = max(11, Int(sps * 3.2) | 1)
        let fc = min(0.45, 3300.0 / sampleRate)
        var h = [Float](repeating: 0, count: count)
        let mid = Double(count - 1) / 2
        var sum = 0.0
        for n in 0..<count {
            let x = Double(n) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let window = 0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1)) + 0.08 * cos(4 * Double.pi * Double(n) / Double(count - 1))
            h[n] = Float(sinc * window)
            sum += sinc * window
        }
        taps = h.map { $0 / Float(sum) }
        ring = [Float](repeating: 0, count: count)
        peakDecay = Float(1.0 / (sampleRate * 0.012))
    }

    public func reset() {
        ring = [Float](repeating: 0, count: ring.count)
        peakHigh = 0; peakLow = 0
        phase = 0; emitted = false; started = false
    }

    public func process(_ samples: [Float]) {
        let count = taps.count
        for sample in samples {
            ring[ringPos] = sample
            ringPos += 1
            if ringPos == count { ringPos = 0 }
            var acc: Float = 0
            var index = ringPos
            for tap in taps {                     // ältester Wert zuerst (Tabelle ist symmetrisch)
                acc += tap * ring[index]
                index += 1
                if index == count { index = 0 }
            }
            step(acc)
        }
    }

    private func step(_ x: Float) {
        // Spitzenwerte nachführen: sofort an, langsam zur Mitte zurück
        if !started { peakHigh = x; peakLow = x; previous = x; started = true }
        if x > peakHigh { peakHigh = x } else { peakHigh += (x - peakHigh) * peakDecay }
        if x < peakLow { peakLow = x } else { peakLow += (x - peakLow) * peakDecay }
        let threshold = (peakHigh + peakLow) / 2
        let half = max((peakHigh - peakLow) / 2, 1e-6)
        level = half
        let s = x - threshold
        let sign = s > 0

        // Nulldurchgang: Phasenfehler gegen die Bitgrenze (Phase 0)
        let ds = phaseStep
        var next = phase + ds
        if sign != previousSign {
            let prevS = previous - threshold
            let frac = Double(abs(prevS) / max(abs(prevS) + abs(s), 1e-9))          // Lage des Durchgangs zwischen den Abtastwerten
            var e = next - (1 - frac) * ds
            e -= e.rounded()
            next -= loopGain * e
        }
        previousSign = sign

        // Abtastzeitpunkt: Mitte des Bits (Phase 0,5)
        if next < 0 { next += 1; emitted = true }
        if next >= 1 { next -= 1; emitted = false }
        if !emitted && next >= 0.5 {
            emitted = true
            let value = max(-1, min(1, s / half))
            onBit?(value > 0 ? 1 : 0, value)
        }
        phase = next
        previous = x
    }

    private var phaseStep: Double { 1 / sps }
}

// MARK: - Rahmen

public enum DStarEvent: Sendable {
    /// Kopf gelesen (`crcOK`: Prüfsumme stimmt)
    case header(DStarHeader, crcOK: Bool)
    /// Sprachrahmen (mit Nummer im Überrahmen)
    case voice(DStarVoiceFrame)
    /// Ende der Aussendung (Ende-Muster gesehen)
    case end
    /// Synchronisation verloren (Signal weg, ohne Ende-Muster)
    case lost
}

public struct DStarFramerStats: Equatable, Sendable {
    public var headersOK = 0
    public var headersBad = 0
    public var frames = 0
    public var syncsMissed = 0
    public var lateEntries = 0
    public var ends = 0
    public var lost = 0
}

public final class DStarFramer {
    private enum State { case search, header, voice }

    public var onEvent: ((DStarEvent) -> Void)?
    public private(set) var stats = DStarFramerStats()
    /// Seit der letzten Synchronisation war der Pegel umgekehrt (Diskriminator mit anderer Polarität)
    public private(set) var inverted = false
    public var isLocked: Bool { state == .voice }

    private var state = State.search
    private var register: UInt64 = 0
    private var buffer: [UInt8] = []
    private var soft: [Float] = []
    private var frameIndex = 0
    private var missedSyncs = 0
    private var bitsSinceSync = 0
    private var armedForLateEntry = true
    /// Später Einstieg: Rahmen werden erst freigegeben, wenn das nächste Synchronmuster 21 Rahmen später stimmt
    private var confirmed = true
    private var pendingFrames: [DStarVoiceFrame] = []

    private static let headerSync32 = pattern([0, 1, 0, 1, 0, 1, 0, 1] + DStarConstants.headerSync24)
    private static let voiceSync = pattern(DStarConstants.voiceSync24)
    private static let end48 = pattern(DStarConstants.endPattern48)

    /// Muster als Zahl: das erste Bit liegt ganz oben (ältestes im Schieberegister)
    private static func pattern(_ bits: [UInt8]) -> (value: UInt64, mask: UInt64, count: Int) {
        var value: UInt64 = 0
        for bit in bits { value = (value << 1) | UInt64(bit) }
        let mask: UInt64 = bits.count >= 64 ? ~0 : (UInt64(1) << UInt64(bits.count)) - 1
        return (value, mask, bits.count)
    }

    private static func mismatches(_ register: UInt64, _ p: (value: UInt64, mask: UInt64, count: Int)) -> Int {
        ((register ^ p.value) & p.mask).nonzeroBitCount
    }

    public init() {}

    public func reset() {
        state = .search
        register = 0
        buffer.removeAll(keepingCapacity: true)
        soft.removeAll(keepingCapacity: true)
        inverted = false
    }

    /// Ein Bit (1 = positiver Pegel) mit weichem Wert (−1…+1)
    public func push(bit rawBit: UInt8, soft rawSoft: Float) {
        let flip = inverted && state != .search
        let bit = flip ? rawBit ^ 1 : rawBit
        let value = flip ? -rawSoft : rawSoft
        register = (register << 1) | UInt64(bit)

        switch state {
        case .search:
            searchStep(rawBit: rawBit, rawSoft: rawSoft)
        case .header:
            buffer.append(bit)
            soft.append(value)
            if buffer.count == DStarConstants.headerBits { finishHeader() }
        case .voice:
            voiceStep(bit: bit)
        }
    }

    // MARK: Suche

    private func searchStep(rawBit: UInt8, rawSoft: Float) {
        // Kopfsynchronisation, in beiden Polaritäten (3 Fehler von 32 Bit erlaubt)
        let reg = register
        if Self.mismatches(reg, Self.headerSync32) <= 3 {
            beginHeader(inverted: false); return
        }
        if Self.mismatches(~reg, Self.headerSync32) <= 3 {
            beginHeader(inverted: true); return
        }
        // Später Einstieg über den Synchronrahmen (nur sehr genau, 1 Fehler von 24 Bit)
        if armedForLateEntry {
            if Self.mismatches(reg, Self.voiceSync) <= 1 { beginVoice(inverted: false, late: true); return }
            if Self.mismatches(~reg, Self.voiceSync) <= 1 { beginVoice(inverted: true, late: true); return }
        }
    }

    private func beginHeader(inverted: Bool) {
        self.inverted = inverted
        state = .header
        buffer.removeAll(keepingCapacity: true)
        soft.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(DStarConstants.headerBits)
        soft.reserveCapacity(DStarConstants.headerBits)
    }

    private func finishHeader() {
        let decoded = DStarHeaderCodec.decode(soft: soft)
        if let decoded, decoded.crcOK {
            stats.headersOK += 1
            onEvent?(.header(decoded.header, crcOK: true))
            startVoiceAfterHeader()
        } else {
            stats.headersBad += 1
            if let decoded { onEvent?(.header(decoded.header, crcOK: false)) }
            // Kopf nicht lesbar: trotzdem die Sprache dahinter suchen (später Einstieg über den Synchronrahmen)
            state = .search
            inverted = false
            buffer.removeAll(keepingCapacity: true)
            soft.removeAll(keepingCapacity: true)
        }
    }

    // MARK: Sprache

    private func startVoiceAfterHeader() {
        state = .voice
        buffer.removeAll(keepingCapacity: true)
        frameIndex = 0
        missedSyncs = 0
        bitsSinceSync = 0
        confirmed = true
        pendingFrames.removeAll()
    }

    private func beginVoice(inverted: Bool, late: Bool) {
        self.inverted = inverted
        state = .voice
        buffer.removeAll(keepingCapacity: true)
        // Das Muster lag im letzten Rahmen: der nächste Rahmen hat die Nummer 1
        frameIndex = 1
        missedSyncs = 0
        bitsSinceSync = 0
        confirmed = !late
        pendingFrames.removeAll()
        // Der Synchronrahmen selbst ist vorbei; danach geht es mit Rahmen 1 weiter. Die Rufzeichen kommen
        // dann aus den Langsamdaten (Kopf-Wiederholung), sobald sie vollständig sind.
    }

    private func voiceStep(bit: UInt8) {
        buffer.append(bit)
        bitsSinceSync += 1

        // Ende-Muster (48 Bit, 4 Fehler erlaubt)
        if confirmed, Self.mismatches(register, Self.end48) <= 4 {
            stats.ends += 1
            finishTransmission(event: .end)
            return
        }

        guard buffer.count == DStarConstants.voiceFrameBits else { return }
        let ambe = DStarBits.bytes(fromBits: buffer[0..<DStarConstants.ambeBits])
        let sdBits = Array(buffer[DStarConstants.ambeBits..<DStarConstants.voiceFrameBits])
        buffer.removeAll(keepingCapacity: true)

        var syncMatches = false
        let sdValue = sdBits.reduce(UInt64(0)) { ($0 << 1) | UInt64($1) }
        if (sdValue ^ Self.voiceSync.value).nonzeroBitCount <= 3 { syncMatches = true }

        var index = frameIndex
        if syncMatches {
            if !confirmed {
                // Das zweite Muster im Abstand eines Überrahmens bestätigt den späten Einstieg
                if index == 0 { confirmed = true; stats.lateEntries += 1 }
            }
            index = 0
            missedSyncs = 0
        } else if index == 0 {
            // An dieser Stelle gehörte ein Synchronrahmen hin
            if !confirmed { drop(); return }
            missedSyncs += 1
            stats.syncsMissed += 1
            if missedSyncs >= 4 { finishTransmission(event: .lost); return }
        }
        let slow = syncMatches ? [] : DStarBits.bytes(fromBits: sdBits).enumerated().map { $0.element ^ DStarConstants.slowDataScramble[$0.offset] }
        let frame = DStarVoiceFrame(index: index, ambe: ambe, slowData: slow)
        frameIndex = (index + 1) % DStarConstants.framesPerSuperframe
        if confirmed {
            for held in pendingFrames { stats.frames += 1; onEvent?(.voice(held)) }
            pendingFrames.removeAll()
            stats.frames += 1
            onEvent?(.voice(frame))
        } else {
            pendingFrames.append(frame)
        }
    }

    /// Späten Einstieg verwerfen (kein Synchronmuster zur erwarteten Zeit): zurück zur Suche
    private func drop() {
        pendingFrames.removeAll()
        state = .search
        inverted = false
        buffer.removeAll(keepingCapacity: true)
        register = 0
    }

    private func finishTransmission(event: DStarEvent) {
        if case .lost = event { stats.lost += 1 }
        onEvent?(event)
        state = .search
        inverted = false
        buffer.removeAll(keepingCapacity: true)
        soft.removeAll(keepingCapacity: true)
        register = 0
    }
}
