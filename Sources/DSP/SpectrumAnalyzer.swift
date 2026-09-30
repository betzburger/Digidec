import Foundation
import Accelerate

/// Leistungsspektrum eines reellen Blocks (Hann-Fenster, vDSP-FFT) in dBFS.
/// Skaliert so, dass ein Sinus mit Amplitude 1 genau auf seiner Frequenz 0 dB ergibt.
public final class SpectrumAnalyzer {
    public let size: Int
    public let sampleRate: Double
    public var binCount: Int { size / 2 }
    public var binWidth: Double { sampleRate / Double(size) }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    /// Faktor, der die Fenster- und FFT-Verstärkung aufhebt
    private let scale: Float

    public init?(size: Int, sampleRate: Double) {
        guard size >= 64, size & (size - 1) == 0 else { return nil }
        self.size = size
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(size)))
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        setup = s
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
        // vDSP_fft_zrip liefert das 2-fache der DFT; Hann-Fenster hat die Summe size/2
        let windowSum = window.reduce(0, +)
        scale = 1 / (windowSum * windowSum)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    public func frequency(ofBin bin: Int) -> Double { Double(bin) * binWidth }

    /// Berechnet das Spektrum von `size` Samples und schreibt `binCount` dB-Werte nach `out`.
    public func process(_ samples: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let n = vDSP_Length(size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, n)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, n / 2)
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Bin 0 enthält in imag den Nyquist-Anteil – für die Anzeige verwerfen
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, n / 2)
            }
        }
        // zrip liefert 2·DFT; ein Sinus der Amplitude A ergibt |2·X|² = A²·(Σw)² → nach `scale` genau A²
        var s = scale
        vDSP_vsmul(power, 1, &s, &power, 1, n / 2)
        var floorPower: Float = 1e-14
        vDSP_vthr(power, 1, &floorPower, &power, 1, n / 2)
        var reference: Float = 1
        vDSP_vdbcon(power, 1, &reference, out, 1, n / 2, 0)
    }
}
