import Foundation
import Accelerate

// MARK: - Betriebsart des Skimmers

/// Was der Skimmer im Audio sucht. Eine Betriebsart je Durchgang: die Erkennung der Träger und die Prüfung der Kanäle unterscheiden sich.
public enum SkimMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case cw, psk31, psk63

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .cw:    return "CW"
        case .psk31: return "BPSK31"
        case .psk63: return "BPSK63"
        }
    }

    /// Schrittgeschwindigkeit der Kanalfolge (Baud) bei PSK
    var baud: Double { self == .psk63 ? 62.5 : 31.25 }

    /// Abtastwerte je Symbol bei 500 Hz Kanalrate (PSK)
    var symbolSamples: Int { self == .psk63 ? 8 : 16 }

    /// Glättung des gemittelten Spektrums in Bins (± Bins): breite Signale als ein Hügel
    var smoothBins: Int {
        switch self {
        case .cw: return 0
        case .psk31: return 2
        case .psk63: return 4
        }
    }

    /// Ein Träger gilt als Spitze, wenn er in dieser Umgebung (± Bins, 7,8 Hz je Bin) der höchste ist
    var peakRadius: Int {
        switch self {
        case .cw: return 3
        case .psk31: return 5
        case .psk63: return 8
        }
    }

    /// Spitzen näher als so viele Bins gehören zum selben Signal
    var matchBins: Int {
        switch self {
        case .cw: return 3
        case .psk31: return 5
        case .psk63: return 8
        }
    }

    /// Seitenbänder (Tastklicks, Verzerrung) eines starken Signals liegen bis zu so viel Hz neben ihm und lesen denselben Text
    var twinRadiusHz: Double {
        switch self {
        case .cw: return 160
        case .psk31: return 80
        case .psk63: return 140
        }
    }

    /// Ein Kanal lebt noch so lange ohne Spitze (Sekunden)
    var deathSeconds: Double {
        switch self {
        case .cw: return 12
        case .psk31, .psk63: return 20
        }
    }
}

// MARK: - Spektrum

/// Leistungsspektrum des Audios (1024-Punkt-FFT mit Hann-Fenster, Schritt 256 Abtastwerte = 32 ms bei 8 kHz), je Bin zeitlich gemittelt.
/// 7,8125 Hz je Bin. Dient nur der Erkennung der Signale; die Kanäle arbeiten auf dem Zeitsignal.
final class SkimSpectrum: @unchecked Sendable {
    let sampleRate: Double
    let fftSize: Int
    let hop: Int
    let binCount: Int
    let binHz: Double
    /// Gemittelte Leistung je Bin (linear)
    private(set) var average: [Float]
    private(set) var frames = 0
    private let alpha: Float
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private var sinceFrame = 0
    private var frame: [Float]
    private var re: [Float]
    private var im: [Float]

    init(sampleRate: Double = 8000, fftSize: Int = 1024, hop: Int = 256, averageSeconds: Double = 1.0) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = hop
        binCount = fftSize / 2
        binHz = sampleRate / Double(fftSize)
        average = [Float](repeating: 0, count: fftSize / 2)
        alpha = Float(1 - exp(-Double(hop) / sampleRate / averageSeconds))
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }
        ring = [Float](repeating: 0, count: fftSize)
        frame = [Float](repeating: 0, count: fftSize)
        re = [Float](repeating: 0, count: fftSize / 2)
        im = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        average = [Float](repeating: 0, count: binCount)
        ring = [Float](repeating: 0, count: fftSize)
        ringPos = 0
        sinceFrame = 0
        frames = 0
    }

    /// Abtastwert aufnehmen; `true`, wenn damit ein Spektrum fertig wurde
    func push(_ x: Float) -> Bool {
        ring[ringPos] = x
        ringPos += 1
        if ringPos == fftSize { ringPos = 0 }
        sinceFrame += 1
        guard sinceFrame >= hop else { return false }
        sinceFrame = 0
        compute()
        return true
    }

    private func compute() {
        // letzte fftSize Abtastwerte in zeitlicher Reihenfolge mit Fenster
        for i in 0..<fftSize {
            var p = ringPos + i
            if p >= fftSize { p -= fftSize }
            frame[i] = ring[p] * window[i]
        }
        var power = [Float](repeating: 0, count: binCount)
        frame.withUnsafeBufferPointer { fp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    // |X|² mit der Skalierung der Zerlegung (Faktor 2) und der Fensterleistung entfernt
                    var scale = Float(1.0 / (4.0 * Double(fftSize) * Double(fftSize) * 0.375))
                    power.withUnsafeMutableBufferPointer { pp in
                        vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(binCount))
                        vDSP_vsmul(pp.baseAddress!, 1, &scale, pp.baseAddress!, 1, vDSP_Length(binCount))
                    }
                }
            }
        }
        power[0] = power[1]                  // Bin 0 trägt Gleichanteil und Nyquist gepackt
        frames += 1
        let a = max(alpha, 1 / Float(frames))
        for k in 0..<binCount { average[k] += a * (power[k] - average[k]) }
    }
}

// MARK: - Erkennung der Signale

/// Ein erkannter Träger im gemittelten Spektrum
struct SkimTrack: Equatable {
    var id: Int
    var frequencyHz: Double
    /// Höhe über dem Rauschen in dB (je Bin, gemittelt)
    var snrDB: Double
    var firstSeen: Double
    var lastSeen: Double
    /// Aufeinanderfolgende Auswertungen mit Spitze (bis zur Bestätigung)
    var hits: Int
    var confirmed: Bool
}

/// Sucht im gemittelten Spektrum nach Spitzen, die deutlich über dem örtlichen Rauschen liegen, und führt sie als Spuren.
/// Rauschen = unteres Quantil der gemittelten Leistung (dB) in ±500 Hz Umgebung; so stören Ränder des Durchlassbereichs und breite Störer wenig.
final class SkimDetector {
    struct Config {
        var thresholdDB = 8.0
        /// Eine Spitze muss so viele Auswertungen hintereinander da sein, bevor sie eine Spur wird
        var birthHits = 4
        var minHz = 150.0
        var maxHz = 3500.0
    }

    var config = Config()
    let mode: SkimMode
    private let spectrum: SkimSpectrum
    private(set) var tracks: [SkimTrack] = []
    /// Rauschen je Bin (dB) und Spektrum in dB (nach der Glättung) der letzten Auswertung
    private(set) var floorDB: [Float]
    private(set) var levelDB: [Float]
    private var nextID = 1
    private var lastFloorFrame = -1000
    private let radius: Int

    init(mode: SkimMode, spectrum: SkimSpectrum) {
        self.mode = mode
        self.spectrum = spectrum
        floorDB = [Float](repeating: -120, count: spectrum.binCount)
        levelDB = [Float](repeating: -120, count: spectrum.binCount)
        radius = mode.peakRadius
    }

    func reset() {
        tracks.removeAll()
        floorDB = [Float](repeating: -120, count: spectrum.binCount)
        levelDB = floorDB
        lastFloorFrame = -1000
    }

    /// Rauschpegel (dB je Bin) an einer Frequenz
    func noiseDB(at hz: Double) -> Double {
        let k = min(max(Int((hz / spectrum.binHz).rounded()), 0), spectrum.binCount - 1)
        return Double(floorDB[k])
    }

    /// Auswertung nach einem Spektrum. `time` in Sekunden Audiozeit. Liefert die Spuren, die mit dieser Auswertung entstanden (neu bestätigt) oder starben.
    @discardableResult
    func update(time: Double) -> (born: [SkimTrack], died: [SkimTrack]) {
        let n = spectrum.binCount
        let avg = spectrum.average
        // Glättung über die Breite des Signals (PSK: ein Hügel)
        let sb = mode.smoothBins
        var lin = avg
        if sb > 0 {
            var run: Float = 0
            var out = [Float](repeating: 0, count: n)
            for k in 0..<n {
                let hi = min(n - 1, k + sb), lo = max(0, k - sb)
                if k == 0 { for j in lo...hi { run += avg[j] } } else {
                    if k + sb < n { run += avg[k + sb] }
                    if k - sb - 1 >= 0 { run -= avg[k - sb - 1] }
                }
                out[k] = run / Float(2 * sb + 1)
            }
            lin = out
        }
        for k in 0..<n { levelDB[k] = 10 * log10(max(lin[k], 1e-20)) }
        // Rauschen alle 16 Auswertungen neu (0,5 s)
        if spectrum.frames - lastFloorFrame >= 16 || lastFloorFrame < 0 {
            lastFloorFrame = spectrum.frames
            computeFloor()
        }
        let lo = max(1 + radius, Int(config.minHz / spectrum.binHz)), hi = min(n - 2 - radius, Int(config.maxHz / spectrum.binHz))
        guard hi > lo, spectrum.frames > 40 else { return ([], []) }
        // Spitzen
        struct Candidate { var bin: Int; var snr: Float; var freq: Double }
        var candidates: [Candidate] = []
        var k = lo
        while k <= hi {
            let v = levelDB[k]
            let snr = v - floorDB[k]
            if snr >= Float(config.thresholdDB) {
                var isMax = true
                for j in (k - radius)...(k + radius) where j != k {
                    if levelDB[j] > v || (levelDB[j] == v && j < k) { isMax = false; break }
                }
                if isMax {
                    candidates.append(Candidate(bin: k, snr: snr, freq: refine(k)))
                    k += radius          // Nachbarn sind keine eigene Spitze
                }
            }
            k += 1
        }
        // Zuordnung zu den bestehenden Spuren
        var born: [SkimTrack] = []
        var used = Set<Int>()
        for t in tracks.indices {
            var best: (idx: Int, dist: Double)?
            for (i, c) in candidates.enumerated() where !used.contains(i) {
                let d = abs(c.freq - tracks[t].frequencyHz)
                if d <= Double(mode.matchBins) * spectrum.binHz, best == nil || d < best!.dist { best = (i, d) }
            }
            if let b = best {
                used.insert(b.idx)
                let c = candidates[b.idx]
                tracks[t].frequencyHz += 0.3 * (c.freq - tracks[t].frequencyHz)
                tracks[t].snrDB += 0.3 * (Double(c.snr) - tracks[t].snrDB)
                tracks[t].lastSeen = time
                tracks[t].hits += 1
                if !tracks[t].confirmed && tracks[t].hits >= config.birthHits {
                    tracks[t].confirmed = true
                    born.append(tracks[t])
                }
            } else if !tracks[t].confirmed {
                tracks[t].hits = -1            // zum Entfernen
            }
        }
        for (i, c) in candidates.enumerated() where !used.contains(i) {
            // keine neue Spur dicht neben einer bestehenden
            if tracks.contains(where: { abs($0.frequencyHz - c.freq) < Double(mode.matchBins) * spectrum.binHz }) { continue }
            tracks.append(SkimTrack(id: nextID, frequencyHz: c.freq, snrDB: Double(c.snr), firstSeen: time, lastSeen: time, hits: 1, confirmed: false))
            nextID += 1
        }
        var died: [SkimTrack] = []
        tracks.removeAll { t in
            if t.hits < 0 { return true }
            if t.confirmed && time - t.lastSeen > mode.deathSeconds { died.append(t); return true }
            return false
        }
        return (born, died)
    }

    /// Frequenz der Spitze mit Interpolation (CW: Parabel durch dB-Werte; PSK: Schwerpunkt über dem Rauschen)
    private func refine(_ k: Int) -> Double {
        if mode == .cw {
            let a = Double(levelDB[k - 1]), b = Double(levelDB[k]), c = Double(levelDB[k + 1])
            let d = a - 2 * b + c
            let off = d < -1e-9 ? 0.5 * (a - c) / d : 0
            return (Double(k) + max(-0.5, min(0.5, off))) * spectrum.binHz
        }
        // Schwerpunkt der Leistung über dem Rauschen im Bereich der Signalbreite (PSK31 ± 31 Hz, PSK63 ± 62 Hz)
        let half = Int((mode == .psk63 ? 62.5 : 31.25) / spectrum.binHz)
        var sw = 0.0, sx = 0.0
        for j in max(1, k - half)...min(spectrum.binCount - 2, k + half) {
            let p = Double(spectrum.average[j]) - pow(10, Double(floorDB[j]) / 10)
            if p > 0 { sw += p; sx += p * Double(j) }
        }
        return (sw > 0 ? sx / sw : Double(k)) * spectrum.binHz
    }

    /// Rauschen = unteres Fünftel (20-%-Quantil) der gemittelten Leistung in ±64 Bins (±500 Hz), um 0,5 dB angehoben (Quantil des Rauschens liegt unter dem Mittel).
    /// Der Median wäre in dichtem Band (viele Signale) zu hoch und ergäbe zu kleine Rauschabstände.
    private func computeFloor() {
        let n = spectrum.binCount
        let w = 64
        var tmp = [Float](repeating: 0, count: 2 * w + 1)
        for k in 0..<n {
            let lo = max(0, k - w), hi = min(n - 1, k + w)
            let count = hi - lo + 1
            for j in 0..<count { tmp[j] = levelDB[lo + j] }
            tmp.withUnsafeMutableBufferPointer { p in
                var s = UnsafeMutableBufferPointer(rebasing: p[0..<count])
                s.sort()
            }
            floorDB[k] = tmp[count / 5] + 0.5
        }
    }
}
