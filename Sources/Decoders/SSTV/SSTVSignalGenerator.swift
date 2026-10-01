import Foundation

/// Synthetischer Testsignal-Generator für SSTV (Slow Scan Television).
/// Erzeugt bit- und phasengetreue 12-kHz-Audiosignale für:
/// - Kalibrierungs-Header (1900 Hz Leader, 1200 Hz Break, 1900 Hz Leader, 1200 Hz Start-Bit)
/// - VIS-Code (7 Datenbits + gerade Parität + Stopp-Bit)
/// - Vollständige Testbilder oder Zeilen (verschobenes 8-Farbbalken-Muster in GBR, RGB oder YUV)
public final class SSTVSignalGenerator: @unchecked Sendable {
    public static let sampleRate: Double = 12000.0

    private var currentPhase: Double = 0.0

    public init() {}

    public func reset() {
        currentPhase = 0.0
    }

    // MARK: - Grundlegende Töne

    /// Erzeugt einen phasenstetigen Sinuston gegebener Frequenz und Dauer.
    public func generateTone(freqHz: Double, durationSec: Double, amplitude: Float = 0.8) -> [Float] {
        let sampleCount = Int((durationSec * Self.sampleRate).rounded())
        guard sampleCount > 0 else { return [] }

        var samples = [Float](repeating: 0.0, count: sampleCount)
        let twoPi = 2.0 * Double.pi
        let phaseInc = twoPi * freqHz / Self.sampleRate

        for i in 0..<sampleCount {
            samples[i] = Float(sin(currentPhase)) * amplitude
            currentPhase += phaseInc
            if currentPhase >= twoPi { currentPhase -= twoPi }
        }

        return samples
    }

    // MARK: - VIS Header

    /// Erzeugt den kompletten SSTV-Header inklusive VIS-Code für einen Modus.
    public func generateVISHeader(mode: SSTVMode, corruptParity: Bool = false) -> [Float] {
        return generateVISHeader(visCode: mode.spec.visCode, corruptParity: corruptParity)
    }

    /// Erzeugt den kompletten SSTV-Header inklusive 7-Bit VIS-Code mit gerader Parität.
    public func generateVISHeader(visCode: UInt8, corruptParity: Bool = false) -> [Float] {
        var samples: [Float] = []

        // 1. 1900 Hz Leader (300 ms)
        samples.append(contentsOf: generateTone(freqHz: 1900.0, durationSec: 0.300))
        // 2. 1200 Hz Break (10 ms)
        samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.010))
        // 3. 1900 Hz Leader (300 ms)
        samples.append(contentsOf: generateTone(freqHz: 1900.0, durationSec: 0.300))
        // 4. 1200 Hz Start-Bit (30 ms)
        samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.030))

        // 5. 7 Datenbits (LSB zuerst, je 30 ms; 1100 Hz = 1, 1300 Hz = 0)
        var onesCount = 0
        for i in 0..<7 {
            let bit = (visCode >> i) & 1
            if bit == 1 { onesCount += 1 }
            let freq = (bit == 1) ? 1100.0 : 1300.0
            samples.append(contentsOf: generateTone(freqHz: freq, durationSec: 0.030))
        }

        // 6. Paritätsbit (gerade Parität: Summe aller 8 Bits mod 2 == 0)
        var parityBit = (onesCount % 2 == 0) ? 0 : 1
        if corruptParity { parityBit ^= 1 }
        let parityFreq = (parityBit == 1) ? 1100.0 : 1300.0
        samples.append(contentsOf: generateTone(freqHz: parityFreq, durationSec: 0.030))

        // 7. 1200 Hz Stopp-Bit (30 ms)
        samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.030))

        return samples
    }

    // MARK: - Farbbalken Testbild

    /// Standard-8-Farbbalken: Weiß, Gelb, Cyan, Grün, Magenta, Rot, Blau, Schwarz.
    public static let standardColorBars: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (255, 255, 255), // Weiß
        (255, 255, 0),   // Gelb
        (0, 255, 255),   // Cyan
        (0, 255, 0),     // Grün
        (255, 0, 255),   // Magenta
        (255, 0, 0),     // Rot
        (0, 0, 255),     // Blau
        (0, 0, 0)        // Schwarz
    ]

    /// Mappt einen 0...255 Pixelwert auf SSTV-Frequenz (1500 Hz...2300 Hz).
    @inline(__always)
    public static func pixelByteToFrequency(_ val: UInt8) -> Double {
        return 1500.0 + (Double(val) / 255.0) * 800.0
    }

    /// Testmuster: 8 Farbbalken, die sich alle 32 Bildzeilen um einen Balken verschieben.
    /// Damit fallen Zeilenversatz, doppelte oder fehlende Zeilen und Spaltenverschiebung auf.
    public static func testPatternColor(x: Int, line: Int, width: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let bar = ((x * standardColorBars.count) / width + line / 32) % standardColorBars.count
        return standardColorBars[bar]
    }

    private func rowValues(width: Int, line: Int) -> (r: [UInt8], g: [UInt8], b: [UInt8]) {
        var r = [UInt8](repeating: 0, count: width)
        var g = r, b = r
        for x in 0..<width {
            let c = Self.testPatternColor(x: x, line: line, width: width)
            r[x] = c.r; g[x] = c.g; b[x] = c.b
        }
        return (r, g, b)
    }

    /// Erzeugt Testsignal-Audiodaten für eine Zeile (PD: ein Zeilenpaar `lineIndex`, `lineIndex+1`) nach dem Testmuster.
    public func generateColorBarLine(mode: SSTVMode, lineIndex: Int) -> [Float] {
        var samples: [Float] = []
        let spec = mode.spec
        let W = spec.width
        let (rVals, gVals, bVals) = rowValues(width: W, line: lineIndex)
        let sync = spec.syncTime
        let sep = 0.0015

        switch mode {
        case .m1, .m2:
            // Sync (1200 Hz), Porch (1500 Hz), Green, Sep (1500 Hz), Blue, Sep (1500 Hz), Red, Sep (1500 Hz)
            let scan = mode == .m1 ? 320 * 0.0004576 : 320 * 0.0002288
            let m = 0.000572
            samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: sync))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: m))
            samples.append(contentsOf: generatePixelStream(values: gVals, totalDuration: scan))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: m))
            samples.append(contentsOf: generatePixelStream(values: bVals, totalDuration: scan))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: m))
            samples.append(contentsOf: generatePixelStream(values: rVals, totalDuration: scan))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: m))

        case .s1, .s2, .sdx:
            // Sep (1500 Hz), Green, Sep, Blue, Sync (1200 Hz), Porch (1500 Hz), Red – Sync liegt vor Rot
            let scan: Double = mode == .s1 ? 320 * 0.000432 : (mode == .s2 ? 320 * 0.0002752 : 320 * 0.00108)
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: sep))
            samples.append(contentsOf: generatePixelStream(values: gVals, totalDuration: scan))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: sep))
            samples.append(contentsOf: generatePixelStream(values: bVals, totalDuration: scan))
            samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.009))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: sep))
            samples.append(contentsOf: generatePixelStream(values: rVals, totalDuration: scan))

        case .w180:
            // Sync (1200 Hz, 5,5225 ms), Porch (1500 Hz, 0,5 ms), Red, Green, Blue (je 235 ms, ohne Trennimpulse)
            samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: sync))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: 0.0005))
            samples.append(contentsOf: generatePixelStream(values: rVals, totalDuration: 0.235))
            samples.append(contentsOf: generatePixelStream(values: gVals, totalDuration: 0.235))
            samples.append(contentsOf: generatePixelStream(values: bVals, totalDuration: 0.235))

        case .r36:
            // Robot 36 (YUV): Sync (1200 Hz, 9ms), Porch (1500 Hz, 3ms), Y (88ms), Sep (4.5ms), Porch (1900 Hz, 1.5ms), Chroma (44ms)
            let isEven = (lineIndex % 2 == 0)
            let yVals = convertToY(r: rVals, g: gVals, b: bVals)
            let chromaVals = isEven ? convertToV(r: rVals, g: gVals, b: bVals) : convertToU(r: rVals, g: gVals, b: bVals)
            let sepFreq = isEven ? 1500.0 : 2300.0

            samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.009))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: 0.003))
            samples.append(contentsOf: generatePixelStream(values: yVals, totalDuration: 0.088))
            samples.append(contentsOf: generateTone(freqHz: sepFreq, durationSec: 0.0045))
            samples.append(contentsOf: generateTone(freqHz: 1900.0, durationSec: 0.0015))
            samples.append(contentsOf: generatePixelStream(values: chromaVals, totalDuration: 0.044))

        case .r72:
            // Robot 72: Sync (1200 Hz), Porch (1500 Hz), Y (138ms), Sep1 (1500 Hz, 4.5ms), Porch1 (1900 Hz, 1.5ms), R-Y (69ms), Sep2 (2300 Hz, 4.5ms), Porch2 (1900 Hz, 1.5ms), B-Y (69ms)
            let yVals = convertToY(r: rVals, g: gVals, b: bVals)
            let vVals = convertToV(r: rVals, g: gVals, b: bVals)
            let uVals = convertToU(r: rVals, g: gVals, b: bVals)

            samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.009))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: 0.003))
            samples.append(contentsOf: generatePixelStream(values: yVals, totalDuration: 0.138))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: 0.0045))
            samples.append(contentsOf: generateTone(freqHz: 1900.0, durationSec: 0.0015))
            samples.append(contentsOf: generatePixelStream(values: vVals, totalDuration: 0.069))
            samples.append(contentsOf: generateTone(freqHz: 2300.0, durationSec: 0.0045))
            samples.append(contentsOf: generateTone(freqHz: 1900.0, durationSec: 0.0015))
            samples.append(contentsOf: generatePixelStream(values: uVals, totalDuration: 0.069))

        case .pd120, .pd90, .pd180:
            // PD: Sync (20 ms), Porch (2,08 ms), Y(n), R-Y, B-Y, Y(n+1) – Chroma aus Zeile n
            let scanTime = Double(W) * (mode == .pd90 ? 0.000532 : (mode == .pd120 ? 0.00019 : 0.000286))
            let row2 = rowValues(width: W, line: lineIndex + 1)
            let y0 = convertToY(r: rVals, g: gVals, b: bVals)
            let y1 = convertToY(r: row2.r, g: row2.g, b: row2.b)
            let vVals = convertToV(r: rVals, g: gVals, b: bVals)
            let uVals = convertToU(r: rVals, g: gVals, b: bVals)

            samples.append(contentsOf: generateTone(freqHz: 1200.0, durationSec: 0.020))
            samples.append(contentsOf: generateTone(freqHz: 1500.0, durationSec: 0.00208))
            samples.append(contentsOf: generatePixelStream(values: y0, totalDuration: scanTime))
            samples.append(contentsOf: generatePixelStream(values: vVals, totalDuration: scanTime))
            samples.append(contentsOf: generatePixelStream(values: uVals, totalDuration: scanTime))
            samples.append(contentsOf: generatePixelStream(values: y1, totalDuration: scanTime))
        }

        return samples
    }

    /// Erzeugt ein vollständiges SSTV-Audiosignal inklusive VIS-Header und N Zeilen Farbbalken.
    public func generateFullTestSignal(mode: SSTVMode, lines: Int? = nil) -> [Float] {
        var audio: [Float] = []
        audio.append(contentsOf: generateVISHeader(mode: mode))

        let totalLines = lines ?? mode.spec.height
        let step = mode.spec.linesPerSync

        for line in stride(from: 0, to: totalLines, by: step) {
            audio.append(contentsOf: generateColorBarLine(mode: mode, lineIndex: line))
        }

        return audio
    }

    // MARK: - Private Hilfsfunktionen

    private func generatePixelStream(values: [UInt8], totalDuration: Double) -> [Float] {
        guard !values.isEmpty else { return [] }
        let totalSamples = Int((totalDuration * Self.sampleRate).rounded())
        guard totalSamples > 0 else { return [] }

        var samples = [Float](repeating: 0.0, count: totalSamples)
        let twoPi = 2.0 * Double.pi
        let countDbl = Double(values.count)
        let totalSamplesDbl = Double(totalSamples)

        for s in 0..<totalSamples {
            let pxIdx = min(Int(Double(s) / totalSamplesDbl * countDbl), values.count - 1)
            let freq = Self.pixelByteToFrequency(values[pxIdx])
            let phaseInc = twoPi * freq / Self.sampleRate

            samples[s] = Float(sin(currentPhase)) * 0.8
            currentPhase += phaseInc
            if currentPhase >= twoPi { currentPhase -= twoPi }
        }
        return samples
    }

    private func generatePixelStream(values: [UInt8], pixelTime: Double) -> [Float] {
        return generatePixelStream(values: values, totalDuration: Double(values.count) * pixelTime)
    }

    private func convertToY(r: [UInt8], g: [UInt8], b: [UInt8]) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: r.count)
        for i in 0..<r.count {
            let Y = 0.299 * Double(r[i]) + 0.587 * Double(g[i]) + 0.114 * Double(b[i])
            y[i] = UInt8(min(max(Y, 0.0), 255.0).rounded())
        }
        return y
    }

    private func convertToU(r: [UInt8], g: [UInt8], b: [UInt8]) -> [UInt8] {
        var u = [UInt8](repeating: 0, count: r.count)
        for i in 0..<r.count {
            let Y = 0.299 * Double(r[i]) + 0.587 * Double(g[i]) + 0.114 * Double(b[i])
            let U = ((Double(b[i]) - Y) / 1.772) + 128.0
            u[i] = UInt8(min(max(U, 0.0), 255.0).rounded())
        }
        return u
    }

    private func convertToV(r: [UInt8], g: [UInt8], b: [UInt8]) -> [UInt8] {
        var v = [UInt8](repeating: 0, count: r.count)
        for i in 0..<r.count {
            let Y = 0.299 * Double(r[i]) + 0.587 * Double(g[i]) + 0.114 * Double(b[i])
            let V = ((Double(r[i]) - Y) / 1.402) + 128.0
            v[i] = UInt8(min(max(V, 0.0), 255.0).rounded())
        }
        return v
    }
}
