import Foundation
import CoreGraphics

// MARK: - FM Demodulator (12 kHz Quadrature Discriminator)

/// Quadratur-FM-Diskriminator für SSTV-Audiosignale.
/// Abtastrate: 12.000 Hz, Trägermitte: 1.750 Hz (Mitte zwischen 1.200 Hz Sync und 2.300 Hz Weiß).
/// Alle Filterzustände bleiben über Blockgrenzen hinweg erhalten (kein Artefakt im Takt der Audiopuffer).
public final class SSTVFMDemodulator: @unchecked Sendable {
    public static let sampleRate: Double = 12000.0
    public static let centerFreq: Double = 1750.0
    private static let smoothing = 7   // Gleitmittel gegen die 2×-Träger-Restwelligkeit (Nullstelle bei 12000/7 ≈ 1714 Hz)

    /// Biquad-Sektion (Direktform I)
    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(cutoffHz: Double, q: Double) {
            let w0 = 2.0 * Double.pi * cutoffHz / SSTVFMDemodulator.sampleRate
            let alpha = sin(w0) / (2.0 * q)
            let c = cos(w0)
            let a0 = 1.0 + alpha
            b0 = ((1.0 - c) / 2.0) / a0
            b1 = (1.0 - c) / a0
            b2 = b0
            a1 = (-2.0 * c) / a0
            a2 = (1.0 - alpha) / a0
        }

        @inline(__always)
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }

        mutating func clear() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
    }

    private var phase: Double = 0.0
    private let phaseInc: Double

    // Tiefpass 4. Ordnung (Butterworth, 1 kHz) je für I und Q: unterdrückt das Summenprodukt bei ≈ 3,5 kHz um > 35 dB
    private var iFilter = [Biquad(cutoffHz: 1000, q: 0.5412), Biquad(cutoffHz: 1000, q: 1.3066)]
    private var qFilter = [Biquad(cutoffHz: 1000, q: 0.5412), Biquad(cutoffHz: 1000, q: 1.3066)]

    // Vorherige komplexe I/Q-Werte für die Phasen-Differenzierung
    private var prevI = 1.0
    private var prevQ = 0.0

    // Ringpuffer für das Gleitmittel
    private var ring = [Double](repeating: SSTVFMDemodulator.centerFreq, count: SSTVFMDemodulator.smoothing)
    private var ringIndex = 0
    private var ringSum = Double(SSTVFMDemodulator.smoothing) * SSTVFMDemodulator.centerFreq

    public init() {
        phaseInc = 2.0 * Double.pi * Self.centerFreq / Self.sampleRate
    }

    public func reset() {
        phase = 0.0
        for k in 0..<2 { iFilter[k].clear(); qFilter[k].clear() }
        prevI = 1.0; prevQ = 0.0
        for k in 0..<ring.count { ring[k] = Self.centerFreq }
        ringIndex = 0
        ringSum = Double(ring.count) * Self.centerFreq
    }

    /// Demoduliert einen Block von Audiosamples und liefert die Momentanfrequenzen in Hz (1 Wert je Sample).
    public func process(samples: [Float]) -> [Double] {
        var out = [Double](repeating: 0.0, count: samples.count)
        let twoPi = 2.0 * Double.pi
        let hzPerRad = Self.sampleRate / twoPi
        let n = Double(ring.count)

        for i in 0..<samples.count {
            let x = Double(samples[i])

            // 1. Mischung ins Basisband (1750 Hz Träger abziehen)
            let rawI = x * cos(phase)
            let rawQ = -x * sin(phase)
            phase += phaseInc
            if phase >= twoPi { phase -= twoPi }

            // 2. Tiefpass auf I und Q
            let fI = iFilter[1].process(iFilter[0].process(rawI))
            let fQ = qFilter[1].process(qFilter[0].process(rawQ))

            // 3. Phasendifferenz = Momentanfrequenz relativ zur Trägermitte
            let cross = fQ * prevI - fI * prevQ
            let dot = fI * prevI + fQ * prevQ
            prevI = fI; prevQ = fQ
            let inst = Self.centerFreq + atan2(cross, dot) * hzPerRad

            // 4. Gleitmittel über die letzten 7 Werte
            ringSum += inst - ring[ringIndex]
            ring[ringIndex] = inst
            ringIndex = (ringIndex + 1) % ring.count
            out[i] = ringSum / n
        }
        return out
    }

    /// Mappt eine SSTV-Frequenz (1500 Hz = Schwarz, 2300 Hz = Weiß) auf 0...255.
    @inline(__always)
    public static func frequencyToPixelByte(_ freq: Double) -> UInt8 {
        if freq <= 1500.0 { return 0 }
        if freq >= 2300.0 { return 255 }
        return UInt8(((freq - 1500.0) / 800.0 * 255.0).rounded())
    }
}

// MARK: - VIS Header Detector

/// Erkennt den SSTV-Kalibrierungs-Header und VIS-Code (Vertical Interval Signaling).
/// 1. 1900 Hz Leader (300 ms) · 2. 1200 Hz Break (10 ms) · 3. 1900 Hz Leader (300 ms) · 4. 1200 Hz Start-Bit (30 ms)
/// 5. 7 VIS-Datenbits (30 ms je Bit, LSB zuerst; 1100 Hz = 1, 1300 Hz = 0)
/// 6. Paritätsbit (gerade Parität über alle 8 Bits) · 7. 1200 Hz Stopp-Bit (30 ms)
/// Header mit falscher Parität oder ohne Stopp-Bit werden verworfen.
public final class SSTVVISDetector: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case searchingLeader1(count: Int, slew: Int)
        case searchingBreak(count: Int, slew: Int)
        case searchingLeader2(count: Int, slew: Int)
        case searchingStartBit(count: Int)
        case readingBits(bitIndex: Int, samplesInBit: Int, accumulator: Double, bits: [UInt8])
        case readingStopBit(count: Int, good: Int, bits: [UInt8])
    }

    public private(set) var state: State = .searchingLeader1(count: 0, slew: 0)
    /// Index (im zuletzt übergebenen Block) des Samples, bei dem der Header als gültig erkannt wurde.
    public private(set) var lastDetectionIndex: Int = 0

    private let sampleRate: Double = 12000.0
    private let leaderFreqRange: ClosedRange<Double> = 1750.0...2050.0 // 1900 Hz
    private let breakFreqRange: ClosedRange<Double> = 1050.0...1350.0  // 1200 Hz
    private let maxSlewSamples = 60 // bis zu 5 ms Übergangszeit zwischen Tönen

    // Gleitmittel über 2 ms: Rauschen im Diskriminatorausgang darf einen Leader nicht unterbrechen
    private static let prefilter = 24
    private var ring = [Double](repeating: SSTVFMDemodulator.centerFreq, count: SSTVVISDetector.prefilter)
    private var ringIndex = 0
    private var ringSum = Double(SSTVVISDetector.prefilter) * SSTVFMDemodulator.centerFreq

    public init() {}

    public func reset() {
        state = .searchingLeader1(count: 0, slew: 0)
    }

    /// Verarbeitet Momentanfrequenzen und gibt den erkannten Modus zurück, sobald ein gültiger VIS-Code empfangen wurde.
    public func process(frequencies: [Double]) -> (mode: SSTVMode, visCode: UInt8)? {
        let bitSamples = Int((0.030 * sampleRate).rounded())       // 360
        let minLeaderSamples = Int((0.150 * sampleRate).rounded()) // 1800
        let minBreakSamples = Int((0.005 * sampleRate).rounded())  // 60
        let maxBreakSamples = Int((0.030 * sampleRate).rounded())  // 360
        let stopCheckSamples = bitSamples / 3                      // 10 ms des Stopp-Bits genügen

        for (index, rawFreq) in frequencies.enumerated() {
            ringSum += rawFreq - ring[ringIndex]
            ring[ringIndex] = rawFreq
            ringIndex = (ringIndex + 1) % ring.count
            let freq = ringSum / Double(ring.count)

            switch state {
            case .searchingLeader1(let count, let slew):
                if leaderFreqRange.contains(freq) {
                    state = .searchingLeader1(count: count + 1, slew: 0)
                } else if count >= minLeaderSamples {
                    if breakFreqRange.contains(freq) {
                        state = .searchingBreak(count: 1, slew: 0)
                    } else if slew < maxSlewSamples {
                        state = .searchingLeader1(count: count, slew: slew + 1)
                    } else {
                        reset()
                    }
                } else {
                    reset()
                }

            case .searchingBreak(let count, let slew):
                if breakFreqRange.contains(freq) {
                    if count + 1 > maxBreakSamples { reset() } else { state = .searchingBreak(count: count + 1, slew: 0) }
                } else if count >= minBreakSamples {
                    if leaderFreqRange.contains(freq) {
                        state = .searchingLeader2(count: 1, slew: 0)
                    } else if slew < maxSlewSamples {
                        state = .searchingBreak(count: count, slew: slew + 1)
                    } else {
                        reset()
                    }
                } else {
                    reset()
                }

            case .searchingLeader2(let count, let slew):
                if leaderFreqRange.contains(freq) {
                    state = .searchingLeader2(count: count + 1, slew: 0)
                } else if count >= minLeaderSamples {
                    if breakFreqRange.contains(freq) {
                        state = .searchingStartBit(count: 1)
                    } else if slew < maxSlewSamples {
                        state = .searchingLeader2(count: count, slew: slew + 1)
                    } else {
                        reset()
                    }
                } else {
                    reset()
                }

            case .searchingStartBit(let count):
                // Die Datenbits (1100/1300 Hz) liegen im selben Toleranzfenster wie das Start-Bit;
                // das Bitraster ergibt sich daher aus der Zeit seit Beginn des Start-Bits.
                if breakFreqRange.contains(freq) {
                    if count + 1 >= bitSamples {
                        state = .readingBits(bitIndex: 0, samplesInBit: 0, accumulator: 0.0, bits: [])
                    } else {
                        state = .searchingStartBit(count: count + 1)
                    }
                } else if count >= bitSamples * 2 / 3 {
                    state = .readingBits(bitIndex: 0, samplesInBit: 1, accumulator: freq, bits: [])
                } else {
                    reset()
                }

            case .readingBits(let bitIndex, let samplesInBit, let accumulator, var bits):
                let nextSamples = samplesInBit + 1
                let nextAccumulator = accumulator + freq
                if nextSamples >= bitSamples {
                    bits.append(nextAccumulator / Double(nextSamples) < 1200.0 ? 1 : 0)
                    state = bits.count < 8
                        ? .readingBits(bitIndex: bitIndex + 1, samplesInBit: 0, accumulator: 0.0, bits: bits)
                        : .readingStopBit(count: 0, good: 0, bits: bits)
                } else {
                    state = .readingBits(bitIndex: bitIndex, samplesInBit: nextSamples, accumulator: nextAccumulator, bits: bits)
                }

            case .readingStopBit(let count, let good, let bits):
                let nextCount = count + 1
                let nextGood = good + (breakFreqRange.contains(freq) ? 1 : 0)
                if nextCount < stopCheckSamples {
                    state = .readingStopBit(count: nextCount, good: nextGood, bits: bits)
                    break
                }
                reset()
                let parityOK = bits.reduce(0, +) % 2 == 0
                let stopOK = nextGood * 10 >= nextCount * 7
                guard parityOK, stopOK else { break }
                var code: UInt8 = 0
                for i in 0..<7 where bits[i] == 1 { code |= (1 << i) }
                if let mode = SSTVMode.from(visCode: code) {
                    lastDetectionIndex = index
                    return (mode, code)
                }
            }
        }
        return nil
    }
}

// MARK: - SSTV Decoder Engine

/// Vollständige SSTV-Bilddekodierungs-Engine für alle 11 Modi.
///
/// Ablauf: FM-Diskriminator → VIS-Erkennung → Sync-Verfolgung (Fenster um die erwartete Zeilenposition,
/// Flywheel bei Ausfall) → Abtastung der Zeilenabschnitte relativ zum Sync-Ende (auch vor dem Sync, wie bei Scottie)
/// → Farbkonvertierung → 32-Bit-Bild. Jede Zeile wird auf ihren eigenen Syncimpuls ausgerichtet, daher addiert sich
/// Taktabweichung (Slant) nicht über das Bild auf.
public final class SSTVDecoderEngine: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case receiving(line: Int, totalLines: Int)
        case complete
        case lost(line: Int, totalLines: Int)
    }

    public private(set) var state: State = .idle
    public private(set) var currentMode: SSTVMode?
    /// Manuelle Taktkorrektur in ppm der Abtastrate (−500…+500).
    public var slantPpm: Double = 0.0
    /// Syncimpulse jeder Zeile zur Nachführung nutzen (aus: nur der erste Impuls, danach freilaufend).
    public var autoSyncEnabled: Bool = true
    /// Abweichung der Signalmitte von 1750 Hz (Fehlabstimmung) – wird von der Frequenz abgezogen.
    public var frequencyOffsetHz: Double = 0.0

    public var onModeDetected: ((SSTVMode) -> Void)?
    public var onLineDecoded: ((Int, Int, CGImage?) -> Void)?
    public var onImageCompleted: ((CGImage, SSTVMode, Date) -> Void)?
    /// Empfang abgebrochen (Signal weg): (decodierte Zeilen, Gesamtzeilen, Teilbild).
    public var onReceptionLost: ((Int, Int, CGImage?) -> Void)?

    private let demodulator = SSTVFMDemodulator()
    private let visDetector = SSTVVISDetector()
    private static let syncThresholdHz = 1350.0
    private static let blackHz = 1500.0
    private static let minMissedLimit = 10
    private static let relockAfterMissed = 4

    // Bildpuffer (RGBX, 8 Bit)
    private var pixelBuffer: [UInt8] = []
    private var bufferWidth = 0
    private var bufferHeight = 0

    // Empfangszustand
    private var spec: SSTVModeSpec?
    private var manualStart = false
    private var lineIndex = 0
    private var freqBuf: [Double] = []      // Momentanfrequenzen ab absolutem Index `bufBase`
    private var bufBase = 0
    private var total = 0                    // Anzahl seit Empfangsbeginn verarbeiteter Samples
    private var pulseLen = 0
    private var syncRing: [Double] = [1500.0]   // Gleitmittel für die Syncerkennung (rauschfest)
    private var syncRingIndex = 0
    private var syncRingSum = 1500.0
    private var lastSyncEnd: Double?
    private var pendingSyncEnd: Int?
    private var missedLines = 0
    private var windowCandidates: [Int] = []       // Impulse im aktuellen Erwartungsfenster; der zur Erwartung nächste gewinnt
    private var acquisitionCandidate: Double?   // erster Impuls einer Erfassung ohne VIS, wartet auf Bestätigung
    private var allowLongFirstPulse = false  // Stopp-Bit des VIS verschmilzt mit dem ersten Syncimpuls
    private var visStarted = false

    // Robot 36: Chroma-Zustand
    private var lastV: [UInt8] = []
    private var lastU: [UInt8] = []
    private var prevY: [UInt8] = []

    public init() {}

    public func reset() {
        demodulator.reset()
        visDetector.reset()
        spec = nil
        manualStart = false
        currentMode = nil
        state = .idle
        pixelBuffer.removeAll()
        bufferWidth = 0
        bufferHeight = 0
        lineIndex = 0
        clearTracking()
    }

    /// Setzt manuell den Modus und startet sofort den Empfang (ohne auf VIS warten zu müssen).
    public func startManualMode(_ mode: SSTVMode) {
        setupMode(mode, fromVIS: false)
        manualStart = true
    }

    private func clearTracking() {
        freqBuf.removeAll(keepingCapacity: true)
        bufBase = 0
        total = 0
        pulseLen = 0
        lastSyncEnd = nil
        pendingSyncEnd = nil
        missedLines = 0
        acquisitionCandidate = nil
        windowCandidates.removeAll()
        allowLongFirstPulse = false
        visStarted = false
    }

    private func setupMode(_ mode: SSTVMode, fromVIS: Bool) {
        let s = mode.spec
        spec = s
        currentMode = mode
        manualStart = false
        bufferWidth = s.width
        bufferHeight = s.height
        pixelBuffer = [UInt8](repeating: 0, count: bufferWidth * bufferHeight * 4)
        for i in stride(from: 3, to: pixelBuffer.count, by: 4) { pixelBuffer[i] = 255 }
        lineIndex = 0
        clearTracking()
        visStarted = fromVIS
        allowLongFirstPulse = fromVIS && s.syncAtLineStart
        let win = max(1, Int((s.syncTime * SSTVFMDemodulator.sampleRate / 8.0).rounded()))
        syncRing = [Double](repeating: Self.blackHz, count: win)
        syncRingIndex = 0
        syncRingSum = Double(win) * Self.blackHz
        lastV = [UInt8](repeating: 128, count: s.width)
        lastU = lastV
        prevY = [UInt8](repeating: 0, count: s.width)
        state = .receiving(line: 0, totalLines: s.height)
    }

    /// Verarbeitet einen Stream von Audiosamples bei 12.000 Hz.
    public func process(audioSamples: [Float]) {
        guard !audioSamples.isEmpty else { return }
        let freqs = demodulator.process(samples: audioSamples)
        var start = 0

        if let (mode, _) = visDetector.process(frequencies: freqs) {
            let idx = visDetector.lastDetectionIndex
            if spec != nil { feed(freqs[0...idx]) }   // Rest des laufenden Bildes noch auswerten
            setupMode(mode, fromVIS: true)
            onModeDetected?(mode)
            start = idx + 1
        }
        if spec != nil, start < freqs.count {
            feed(freqs[start...])
        }
    }

    // MARK: - Sync-Verfolgung

    private var effectiveRate: Double { SSTVFMDemodulator.sampleRate * (1.0 + slantPpm * 1e-6) }

    private func feed(_ freqs: ArraySlice<Double>) {
        for raw in freqs {
            guard let s = spec else { return }
            let fs = effectiveRate
            let f = raw - frequencyOffsetHz
            freqBuf.append(f)
            let idx = total
            total += 1

            // Syncimpuls = geglättete Frequenz unter 1350 Hz. Das kausale Gleitmittel verzögert Anfang und Ende gleich;
            // die Flanke liegt beim Schwellendurchgang in der Fenstermitte.
            syncRingSum += f - syncRing[syncRingIndex]
            syncRing[syncRingIndex] = f
            syncRingIndex = (syncRingIndex + 1) % syncRing.count
            if syncRingSum / Double(syncRing.count) < Self.syncThresholdHz {
                pulseLen += 1
            } else if pulseLen > 0 {
                pulseEnded(length: pulseLen, endIndex: idx - syncRing.count / 2, spec: s, fs: fs)
                pulseLen = 0
            }

            if let p = pendingSyncEnd, Double(total) >= Double(p) + s.latestEnd * fs + 2 {
                pendingSyncEnd = nil
                decodeLine(syncEnd: p, spec: s, fs: fs)
                if self.spec == nil { return }   // Bild fertig
            }

            if lastSyncEnd == nil, freqBuf.count > Int(4.0 * s.lineTime * fs) {
                let n = freqBuf.count - Int(3.0 * s.lineTime * fs)
                freqBuf.removeFirst(n)
                bufBase += n
            }

            // Flywheel: Syncimpuls ausgeblieben → Zeile an der erwarteten Stelle dekodieren
            if pendingSyncEnd == nil, let last = lastSyncEnd {
                let lineN = s.lineTime * fs
                let expected = last + lineN
                if Double(total) > expected + syncTolerance(lineN: lineN, fs: fs) {
                    if let best = windowCandidates.min(by: { abs(Double($0) - expected) < abs(Double($1) - expected) }) {
                        windowCandidates.removeAll()
                        missedLines = 0
                        lastSyncEnd = Double(best)
                        pendingSyncEnd = best
                        continue
                    }
                    missedLines += 1
                    // Fading überbrücken: der Takt der Gegenstation ist stabil, die Zeilennummer folgt der Zeit.
                    // Im manuellen Modus wird nie abgebrochen; nach VIS-Start erst bei langem Ausfall (¼ Bild).
                    if autoSyncEnabled && !manualStart && missedLines > max(Self.minMissedLimit, (s.height / s.linesPerSync) / 4) {
                        receptionLost()
                        continue
                    }
                    lastSyncEnd = expected
                    pendingSyncEnd = Int(expected.rounded())
                }
            } else if lastSyncEnd == nil, visStarted, Double(total) > 2.0 * s.lineTime * fs + 0.5 * fs {
                receptionLost()
            }
        }
    }

    /// Erwartungsfenster um den Syncimpuls: ±10 % einer Zeile, höchstens ±25 ms. Echte Signale (Fading, Sample-Verluste
    /// in Mitschnitten, Sender mit Taktfehlern) zeigen Sprünge von mehreren Millisekunden; die Impulslänge (0,5…1,6 × Soll)
    /// hält Rauschimpulse fern, und innerhalb des Fensters gewinnt der zur Erwartung nächste Impuls.
    private func syncTolerance(lineN: Double, fs: Double) -> Double { min(0.1 * lineN, 0.025 * fs) }

    private func pulseEnded(length: Int, endIndex: Int, spec s: SSTVModeSpec, fs: Double) {
        let syncN = s.syncTime * fs
        let len = Double(length)
        let maxLen = allowLongFirstPulse ? 0.08 * fs : 1.6 * syncN
        guard len >= 0.5 * syncN, len <= maxLen else { return }

        if lastSyncEnd == nil && !visStarted {
            // Erfassung mitten im Bild: ein einzelner Impuls kann Rauschen sein → zwei gleichabständige Impulse nötig
            let lineN = s.lineTime * fs
            if let c = acquisitionCandidate, abs(Double(endIndex) - (c + lineN)) <= syncTolerance(lineN: lineN, fs: fs) {
                acquisitionCandidate = nil
                lastSyncEnd = Double(endIndex)
                missedLines = 0
                decodeLine(syncEnd: Int(c.rounded()), spec: s, fs: fs)   // Daten des ersten Impulses liegen noch im Puffer
                if spec != nil { pendingSyncEnd = endIndex }
            } else {
                acquisitionCandidate = Double(endIndex)
            }
            return
        }

        if let last = lastSyncEnd {
            guard autoSyncEnabled else { return }
            let lineN = s.lineTime * fs
            let tol = syncTolerance(lineN: lineN, fs: fs)
            guard abs(Double(endIndex) - (last + lineN)) <= tol else {
                // Außerhalb des Fensters: erst nach längerem Ausfall (Fading, Zeitsprung) wieder einrasten – dann genügen
                // zwei gleichabständige Impulse. Die Zeilennummer lief per Flywheel zeitgebunden weiter.
                guard missedLines >= Self.relockAfterMissed else { return }
                if let c = acquisitionCandidate, abs(Double(endIndex) - (c + lineN)) <= tol {
                    acquisitionCandidate = nil
                    windowCandidates.removeAll()
                    lastSyncEnd = Double(endIndex)
                    missedLines = 0
                    pendingSyncEnd = endIndex
                } else {
                    acquisitionCandidate = Double(endIndex)
                }
                return
            }
            acquisitionCandidate = nil
            windowCandidates.append(endIndex)   // Entscheidung fällt, wenn das Fenster schließt
            return
        }
        allowLongFirstPulse = false
        lastSyncEnd = Double(endIndex)
        missedLines = 0
        pendingSyncEnd = endIndex
    }

    private func receptionLost() {
        guard let s = spec else { return }
        let img = createCGImage()
        state = .lost(line: lineIndex, totalLines: s.height)
        onReceptionLost?(lineIndex, s.height, img)
        spec = nil
        currentMode = nil
        clearTracking()
    }

    // MARK: - Zeilendekodierung

    private func decodeLine(syncEnd: Int, spec s: SSTVModeSpec, fs: Double) {
        func channel(_ c: SSTVComponent) -> [UInt8]? {
            s.segments.first { $0.component == c }.map { sample($0, syncEnd: syncEnd, spec: s, fs: fs) }
        }

        switch s.mode {
        case .m1, .m2, .s1, .s2, .sdx, .w180:
            if let r = channel(.red), let g = channel(.green), let b = channel(.blue) {
                writeRGBLine(y: lineIndex, r: r, g: g, b: b)
            }
        case .r72:
            if let y = channel(.luma), let v = channel(.chromaV), let u = channel(.chromaU) {
                writeYUVLine(y: lineIndex, yVals: y, uVals: u, vVals: v)
            }
        case .r36:
            if let y = channel(.luma), let c = channel(.chromaAlt),
               let probe = s.segments.first(where: { $0.component == .parityProbe }) {
                let isV = meanFrequency(probe, syncEnd: syncEnd, fs: fs) < 1900.0
                if isV { lastV = c } else { lastU = c }
                writeYUVLine(y: lineIndex, yVals: y, uVals: lastU, vVals: lastV)
                // Zeilenpaar (2k, 2k+1) teilt R-Y und B-Y: die gerade Zeile erhält mit der ungeraden ihr zweites Chroma
                if !isV, lineIndex > 0 {
                    writeYUVLine(y: lineIndex - 1, yVals: prevY, uVals: lastU, vVals: lastV)
                }
                prevY = y
            }
        case .pd90, .pd120, .pd180:
            if let y0 = channel(.luma), let v = channel(.chromaV), let u = channel(.chromaU), let y1 = channel(.luma2) {
                writeYUVLine(y: lineIndex, yVals: y0, uVals: u, vVals: v)
                writeYUVLine(y: lineIndex + 1, yVals: y1, uVals: u, vVals: v)
            }
        }

        lineIndex += s.linesPerSync
        trimBuffer(after: syncEnd, spec: s, fs: fs)

        let image = createCGImage()
        if lineIndex >= s.height {
            state = .complete
            onLineDecoded?(s.height, s.height, image)
            if let image { onImageCompleted?(image, s.mode, Date()) }
            let mode = s.mode
            if manualStart {
                setupMode(mode, fromVIS: false)   // nächstes Bild im selben Modus erwarten
                manualStart = true
            } else {
                spec = nil
                currentMode = nil
                clearTracking()
            }
        } else {
            state = .receiving(line: lineIndex, totalLines: s.height)
            onLineDecoded?(lineIndex, s.height, image)
        }
    }

    private func trimBuffer(after syncEnd: Int, spec s: SSTVModeSpec, fs: Double) {
        let lineN = s.lineTime * fs
        let keepFrom = Int(Double(syncEnd) + lineN + s.earliestOffset * fs - syncTolerance(lineN: lineN, fs: fs)) - 16
        let drop = keepFrom - bufBase
        if drop > 0 {
            let n = min(drop, freqBuf.count)
            freqBuf.removeFirst(n)
            bufBase += n
        }
    }

    @inline(__always)
    private func freq(at absolute: Int) -> Double {
        let i = absolute - bufBase
        return (i >= 0 && i < freqBuf.count) ? freqBuf[i] : Self.blackHz
    }

    /// Mittelwert der Frequenz im Kernbereich [lo, hi) (in Samples); Ränder werden wegen der Flankenzeit ausgespart.
    private func averageFrequency(lo: Double, hi: Double) -> Double {
        let center = (lo + hi) / 2.0
        let half = max(0.5, (hi - lo) * 0.35)
        let i0 = Int((center - half).rounded())
        let i1 = max(i0 + 1, Int((center + half).rounded()))
        var sum = 0.0
        for i in i0..<i1 { sum += freq(at: i) }
        return sum / Double(i1 - i0)
    }

    private func meanFrequency(_ seg: SSTVSegment, syncEnd: Int, fs: Double) -> Double {
        let lo = Double(syncEnd) + seg.start * fs
        return averageFrequency(lo: lo, hi: lo + seg.duration * fs)
    }

    /// Tastet einen Zeilenabschnitt in `width` Bildpunkte ab.
    private func sample(_ seg: SSTVSegment, syncEnd: Int, spec s: SSTVModeSpec, fs: Double) -> [UInt8] {
        let w = s.width
        let origin = Double(syncEnd) + seg.start * fs
        let pixelN = seg.duration * fs / Double(w)
        var out = [UInt8](repeating: 0, count: w)
        for x in 0..<w {
            let lo = origin + Double(x) * pixelN
            out[x] = SSTVFMDemodulator.frequencyToPixelByte(averageFrequency(lo: lo, hi: lo + pixelN))
        }
        return out
    }

    // MARK: - Farbkonvertierung

    private func writeRGBLine(y: Int, r: [UInt8], g: [UInt8], b: [UInt8]) {
        guard y >= 0, y < bufferHeight else { return }
        let rowStart = y * bufferWidth * 4
        for x in 0..<bufferWidth {
            let o = rowStart + x * 4
            pixelBuffer[o] = r[x]; pixelBuffer[o + 1] = g[x]; pixelBuffer[o + 2] = b[x]; pixelBuffer[o + 3] = 255
        }
    }

    /// YUV (ITU-R BT.601, Vollbereich, Chroma um 128 zentriert) → RGB.
    private func writeYUVLine(y: Int, yVals: [UInt8], uVals: [UInt8], vVals: [UInt8]) {
        guard y >= 0, y < bufferHeight else { return }
        let rowStart = y * bufferWidth * 4
        for x in 0..<bufferWidth {
            let o = rowStart + x * 4
            let Y = Double(yVals[x]), U = Double(uVals[x]) - 128.0, V = Double(vVals[x]) - 128.0
            pixelBuffer[o]     = UInt8(min(max(Y + 1.402 * V, 0.0), 255.0).rounded())
            pixelBuffer[o + 1] = UInt8(min(max(Y - 0.344136 * U - 0.714136 * V, 0.0), 255.0).rounded())
            pixelBuffer[o + 2] = UInt8(min(max(Y + 1.772 * U, 0.0), 255.0).rounded())
            pixelBuffer[o + 3] = 255
        }
    }

    // MARK: - CGImage Export

    /// Erzeugt ein CGImage aus dem aktuellen Pixelpuffer.
    public func createCGImage() -> CGImage? {
        guard bufferWidth > 0, bufferHeight > 0, !pixelBuffer.isEmpty,
              let provider = CGDataProvider(data: Data(pixelBuffer) as CFData) else { return nil }
        return CGImage(
            width: bufferWidth, height: bufferHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bufferWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
