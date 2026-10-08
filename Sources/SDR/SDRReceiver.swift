// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

/// Leistungsspektrum des I/Q-Fensters für den HF-Wasserfall: Blöcke zu 4096 Punkten (Hann-Fenster), über 40 ms gemittelt, Mitte = Fenstermitte
public final class SDRSpectrum {
    /// Punkte der FFT bei Abtastraten bis 5 MS/s; darüber 16384 (gleiche Auflösung von etwa 600 Hz je Bin, schmale Träger bleiben im Rauschen sichtbar)
    public static let size = 4096
    public static let rowsPerSecond = 25.0

    private let sampleRate: Double
    public let bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var re: [Float]
    private var im: [Float]
    private var power: [Float]
    private var acc: [Float]
    private var accBlocks = 0
    private var fill = 0
    private var inRow = 0
    private let rowLength: Int

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        bins = sampleRate > 5_000_000 ? 16_384 : Self.size
        log2n = bins == Self.size ? 12 : 14
        window = [Float](repeating: 0, count: bins)
        re = window; im = window; power = window; acc = window
        rowLength = Int(sampleRate / Self.rowsPerSecond)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(bins), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Rohdaten (8 Bit I/Q) aufnehmen; fertige Zeilen (dB zur Vollaussteuerung, −Fs/2 … +Fs/2) werden angehängt
    public func consume(_ bytes: UnsafeBufferPointer<UInt8>, rows: inout [[Float]]) {
        let n = bins
        let pairs = bytes.count / 2
        var k = 0
        while k < pairs {
            let take = min(n - fill, pairs - k)
            for j in 0..<take {
                re[fill + j] = (Float(bytes[2 * (k + j)]) - 127.5) / 127.5
                im[fill + j] = (Float(bytes[2 * (k + j) + 1]) - 127.5) / 127.5
            }
            fill += take
            k += take
            inRow += take
            if fill == n {
                fill = 0
                accumulateBlock()
            }
            if inRow >= rowLength {
                inRow = 0
                if accBlocks > 0 { rows.append(finishRow()) }
            }
        }
    }

    private func accumulateBlock() {
        let n = bins
        window.withUnsafeBufferPointer { w in
            re.withUnsafeMutableBufferPointer { r in vDSP_vmul(r.baseAddress!, 1, w.baseAddress!, 1, r.baseAddress!, 1, vDSP_Length(n)) }
            im.withUnsafeMutableBufferPointer { i in vDSP_vmul(i.baseAddress!, 1, w.baseAddress!, 1, i.baseAddress!, 1, vDSP_Length(n)) }
        }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n))
            }
        }
        for k in 0..<n { acc[k] += power[k] }
        accBlocks += 1
    }

    private func finishRow() -> [Float] {
        let n = bins
        var scale = 1 / Float(accBlocks) / Float(n) / Float(n)      // |X|² / N² (Fenster mit Summe N)
        var mean = [Float](repeating: 0, count: n)
        vDSP_vsmul(acc, 1, &scale, &mean, 1, vDSP_Length(n))
        acc = [Float](repeating: 0, count: n)
        accBlocks = 0
        var row = [Float](repeating: 0, count: n)
        // Frequenz −Fs/2 … +Fs/2 (Bin n/2 = Mitte)
        for k in 0..<n {
            let src = (k + n / 2) % n
            row[k] = 10 * log10f(max(mean[src], 1e-14))
        }
        // Gleichanteil-Spitze des Geräts nicht zeigen: die drei mittleren Bins durch den Nachbarn ersetzen
        let c = n / 2
        let neighbour = min(row[c - 4], row[c + 4])
        for k in (c - 2)...(c + 2) { row[k] = min(row[k], neighbour + 3) }
        return row
    }

    public func reset() {
        fill = 0; inRow = 0; accBlocks = 0
        acc = [Float](repeating: 0, count: bins)
    }
}

/// Der Empfänger auf eigenem Faden: nimmt I/Q-Blöcke vom Gerät entgegen, demoduliert sie und liefert Audio, Spektrumzeilen und Messwerte
public final class SDRReceiverEngine: @unchecked Sendable {
    public typealias AudioHandler = @Sendable (UnsafeBufferPointer<Float>) -> Void
    public typealias DiscriminatorHandler = @Sendable (UnsafeBufferPointer<Float>, Double) -> Void
    /// Verschachtelte Stereo-Abtastwerte (L, R) mit 48 kS/s
    public typealias StereoHandler = @Sendable (UnsafeBufferPointer<Float>) -> Void

    public struct Snapshot: Sendable {
        public var metrics = SDRMetrics()
        public var droppedBlocks = 0
        /// Mittlere Auslenkung der I/Q-Werte (0 … 127) und Anteil übersteuerter Abtastwerte
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var audioSamples = 0
    }

    /// Zusätzlicher Kanal der Kanalbank: eigener Mischer und Demodulator über denselben I/Q-Strom, eigenes Audio
    private final class ExtraChannel {
        var demod: SDRDemodulator
        var config: SDRChannelConfig
        var offsetHz: Double
        var handler: AudioHandler?
        var scratch: [Float] = []
        init(demod: SDRDemodulator, config: SDRChannelConfig, offsetHz: Double, handler: AudioHandler?) {
            self.demod = demod; self.config = config; self.offsetHz = offsetHz; self.handler = handler
        }
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.sdr", qos: .userInitiated)
    private let lock = NSLock()
    private var demod: SDRDemodulator
    private var spectrum: SDRSpectrum
    private var onAudio: AudioHandler?
    private var onDiscriminator: DiscriminatorHandler?
    private var onStereo: StereoHandler?
    private var channel = SDRChannelConfig()
    private var offsetHz = 0.0
    private var pendingBytes = 0
    private var droppedBlocks = 0
    private var rows: [[Float]] = []
    private var metrics = SDRMetrics()
    private var activity = 0.0
    private var clipped = 0, total = 0
    private var audioSamples = 0
    private var audioScratch: [Float] = []
    private var stereoScratch: [Float] = []
    // Kanalbank (nur auf `queue` verändert; Messwerte über `lock` weitergegeben)
    private var extras: [Int: ExtraChannel] = [:]
    private var primaryEnabled = true
    private var extraMetrics: [Int: SDRMetrics] = [:]
    static let maxPending = 6 * 1024 * 1024
    public private(set) var sampleRate: Double

    public init(sampleRate: Double = 2_400_000) {
        self.sampleRate = sampleRate
        let d = SDRDemodulator(sampleRate: sampleRate)
        demod = d
        spectrum = SDRSpectrum(sampleRate: sampleRate)
        wireDemodulator(d)
    }

    public func setAudioHandler(_ handler: AudioHandler?) {
        lock.withLock { onAudio = handler }
    }

    public func setDiscriminatorHandler(_ handler: DiscriminatorHandler?) {
        lock.withLock { onDiscriminator = handler }
    }

    /// Stereo-Audio des Hörkanals (Mithören); UKW-Rundfunk liefert echtes Stereo, alle anderen Betriebsarten Mono auf beiden Kanälen
    public func setStereoHandler(_ handler: StereoHandler?) {
        lock.withLock { onStereo = handler }
    }

    private func wireDemodulator(_ d: SDRDemodulator) {
        d.onDiscriminator = { [weak self] buf, rate in
            guard let self else { return }
            let handler = self.lock.withLock { self.onDiscriminator }
            handler?(buf, rate)
        }
    }

    /// Neu aufsetzen (neue Abtastrate oder neuer Strom); Kanal und Abstand bleiben
    public func configure(sampleRate: Double) {
        queue.async { [self] in
            self.sampleRate = sampleRate
            let d = SDRDemodulator(sampleRate: sampleRate, config: channel)
            d.setOffset(offsetHz)
            wireDemodulator(d)
            demod = d
            for (_, e) in extras {
                let nd = SDRDemodulator(sampleRate: sampleRate, config: e.config)
                nd.setOffset(e.offsetHz)
                e.demod = nd
            }
            spectrum = SDRSpectrum(sampleRate: sampleRate)
            lock.withLock { rows.removeAll(); droppedBlocks = 0; clipped = 0; total = 0; audioSamples = 0 }
        }
    }

    public func setChannel(_ config: SDRChannelConfig) {
        queue.async { [self] in
            channel = config
            demod.configure(config)
        }
    }

    /// Abstand des gehörten Signals von der Mitte des I/Q-Fensters
    public func setOffset(_ hz: Double) {
        queue.async { [self] in
            offsetHz = hz
            demod.setOffset(hz)
        }
    }

    // MARK: Kanalbank

    /// Der erste Kanal (Hörkanal) wird nicht gerechnet, solange die Kanalbank arbeitet
    public func setPrimaryEnabled(_ on: Bool) {
        queue.async { [self] in primaryEnabled = on }
    }

    /// Zusätzlichen Kanal anlegen oder ändern: Abstand von der Mitte des I/Q-Fensters, Betriebsart, Audio (48 kHz) an `handler`
    public func setExtraChannel(id: Int, config: SDRChannelConfig, offsetHz: Double, handler: AudioHandler?) {
        queue.async { [self] in
            if let e = extras[id] {
                e.demod.configure(config)
                e.demod.setOffset(offsetHz)
                e.config = config; e.offsetHz = offsetHz
                e.handler = handler
            } else {
                let d = SDRDemodulator(sampleRate: sampleRate, config: config)
                d.setOffset(offsetHz)
                extras[id] = ExtraChannel(demod: d, config: config, offsetHz: offsetHz, handler: handler)
            }
        }
    }

    public func removeExtraChannel(id: Int) {
        queue.async { [self] in
            extras[id] = nil
            lock.withLock { extraMetrics[id] = nil }
        }
    }

    public func removeAllExtraChannels() {
        queue.async { [self] in
            extras.removeAll()
            lock.withLock { extraMetrics.removeAll() }
        }
    }

    /// Kanalleistung und Rauschsperre der zusätzlichen Kanäle
    public func extraChannelMetrics() -> [Int: SDRMetrics] {
        lock.withLock { extraMetrics }
    }

    /// Neue I/Q-Daten (vom Faden der Quelle): kopieren und weitergeben, bei Rückstau verwerfen
    public func feed(_ buffer: UnsafeBufferPointer<UInt8>, wait: Bool = false) {
        let n = buffer.count
        if wait { while lock.withLock({ pendingBytes + n > Self.maxPending }) { Thread.sleep(forTimeInterval: 0.002) } }
        let over = lock.withLock { () -> Bool in
            if pendingBytes + n > Self.maxPending { droppedBlocks += 1; return true }
            pendingBytes += n
            return false
        }
        if over { return }
        let copy = Data(buffer: buffer)
        queue.async { [self] in
            process(copy)
            lock.withLock { pendingBytes -= n }
        }
    }

    private func process(_ data: Data) {
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            var sum = 0, clip = 0, i = 0
            while i < buf.count {
                sum += abs(Int(buf[i]) - 128)
                if buf[i] == 0 || buf[i] == 255 { clip += 1 }
                i += 8
            }
            let counted = max(1, (buf.count + 7) / 8)
            var newRows: [[Float]] = []
            spectrum.consume(buf, rows: &newRows)
            audioScratch.removeAll(keepingCapacity: true)
            let stereoHandler = lock.withLock { onStereo }
            demod.produceStereo = stereoHandler != nil
            demod.stereoOut.removeAll(keepingCapacity: true)
            if primaryEnabled { demod.process(buf, audio: &audioScratch) }
            swap(&stereoScratch, &demod.stereoOut)
            // Kanalbank: jeder Kanal rechnet für sich, mehrere zugleich auf allen Kernen
            if !extras.isEmpty {
                let list = Array(extras.values)
                let ids = Array(extras.keys)
                nonisolated(unsafe) let work = list
                nonisolated(unsafe) let input = buf
                DispatchQueue.concurrentPerform(iterations: work.count) { n in
                    let e = work[n]
                    e.scratch.removeAll(keepingCapacity: true)
                    e.demod.process(input, audio: &e.scratch)
                    if let h = e.handler, !e.scratch.isEmpty { e.scratch.withUnsafeBufferPointer { h($0) } }
                }
                let m = Dictionary(uniqueKeysWithValues: zip(ids, list.map { $0.demod.metrics }))
                lock.withLock { extraMetrics = m }
            }
            let handler = lock.withLock { () -> AudioHandler? in
                activity += (Double(sum) / Double(counted) - activity) * 0.2
                clipped += clip; total += counted
                metrics = demod.metrics
                audioSamples += audioScratch.count
                rows.append(contentsOf: newRows)
                if rows.count > 200 { rows.removeFirst(rows.count - 200) }
                return onAudio
            }
            if let handler, !audioScratch.isEmpty {
                audioScratch.withUnsafeBufferPointer { handler($0) }
            }
            if let stereoHandler, !stereoScratch.isEmpty {
                stereoScratch.withUnsafeBufferPointer { stereoHandler($0) }
            }
        }
    }

    /// Seit dem letzten Aufruf entstandene Zeilen des Spektrums
    public func takeSpectrumRows() -> [[Float]] {
        lock.withLock { () -> [[Float]] in defer { rows.removeAll() }; return rows }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            var s = Snapshot()
            s.metrics = metrics
            s.droppedBlocks = droppedBlocks
            s.activity = activity
            s.clippedFraction = total > 0 ? Double(clipped) / Double(total) : 0
            s.audioSamples = audioSamples
            return s
        }
    }

    public func resetClipping() {
        lock.withLock { clipped = 0; total = 0 }
    }
}
