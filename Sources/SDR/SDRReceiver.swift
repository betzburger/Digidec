// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

/// Leistungsspektrum des I/Q-Fensters für den HF-Wasserfall: Blöcke zu 4096 Punkten (Hann-Fenster), über 40 ms gemittelt, Mitte = Fenstermitte
public final class SDRSpectrum {
    public static let size = 4096
    public static let rowsPerSecond = 25.0

    private let sampleRate: Double
    private let log2n = vDSP_Length(12)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SDRSpectrum.size)
    private var re = [Float](repeating: 0, count: SDRSpectrum.size)
    private var im = [Float](repeating: 0, count: SDRSpectrum.size)
    private var power = [Float](repeating: 0, count: SDRSpectrum.size)
    private var acc = [Float](repeating: 0, count: SDRSpectrum.size)
    private var accBlocks = 0
    private var fill = 0
    private var inRow = 0
    private let rowLength: Int

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        rowLength = Int(sampleRate / Self.rowsPerSecond)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Rohdaten (8 Bit I/Q) aufnehmen; fertige Zeilen (dB zur Vollaussteuerung, −Fs/2 … +Fs/2) werden angehängt
    public func consume(_ bytes: UnsafeBufferPointer<UInt8>, rows: inout [[Float]]) {
        let n = Self.size
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
        let n = Self.size
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
        let n = Self.size
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
        acc = [Float](repeating: 0, count: Self.size)
    }
}

/// Der Empfänger auf eigenem Faden: nimmt I/Q-Blöcke vom Gerät entgegen, demoduliert sie und liefert Audio, Spektrumzeilen und Messwerte
public final class SDRReceiverEngine: @unchecked Sendable {
    public typealias AudioHandler = @Sendable (UnsafeBufferPointer<Float>) -> Void

    public struct Snapshot: Sendable {
        public var metrics = SDRMetrics()
        public var droppedBlocks = 0
        /// Mittlere Auslenkung der I/Q-Werte (0 … 127) und Anteil übersteuerter Abtastwerte
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var audioSamples = 0
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.sdr", qos: .userInitiated)
    private let lock = NSLock()
    private var demod: SDRDemodulator
    private var spectrum: SDRSpectrum
    private var onAudio: AudioHandler?
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
    static let maxPending = 6 * 1024 * 1024
    public private(set) var sampleRate: Double

    public init(sampleRate: Double = 2_400_000) {
        self.sampleRate = sampleRate
        demod = SDRDemodulator(sampleRate: sampleRate)
        spectrum = SDRSpectrum(sampleRate: sampleRate)
    }

    public func setAudioHandler(_ handler: AudioHandler?) {
        lock.withLock { onAudio = handler }
    }

    /// Neu aufsetzen (neue Abtastrate oder neuer Strom); Kanal und Abstand bleiben
    public func configure(sampleRate: Double) {
        queue.async { [self] in
            self.sampleRate = sampleRate
            let d = SDRDemodulator(sampleRate: sampleRate, config: channel)
            d.setOffset(offsetHz)
            demod = d
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
            demod.process(buf, audio: &audioScratch)
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
