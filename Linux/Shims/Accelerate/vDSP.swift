// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für den Teil von Accelerate/vDSP, den Digidec nutzt (nur Linux). Reines Swift, gleiche Namen und Rechenvorschriften wie bei Apple.
import Foundation

public typealias vDSP_Length = UInt
public typealias vDSP_Stride = Int
public typealias FFTRadix = Int32
public typealias FFTDirection = Int32
public typealias FFTSetup = OpaquePointer

public let kFFTRadix2 = 0
public let kFFTRadix3 = 1
public let kFFTRadix5 = 2
public let FFT_FORWARD = 1
public let FFT_INVERSE = -1
public let kFFTDirection_Forward = 1
public let kFFTDirection_Inverse = -1
public let vDSP_HANN_NORM = 2
public let vDSP_HANN_DENORM = 0
public let vDSP_HALF_WINDOW = 1

public struct DSPComplex { public var real: Float; public var imag: Float
    public init(real: Float = 0, imag: Float = 0) { self.real = real; self.imag = imag } }

public struct DSPSplitComplex {
    public var realp: UnsafeMutablePointer<Float>
    public var imagp: UnsafeMutablePointer<Float>
    public init(realp: UnsafeMutablePointer<Float>, imagp: UnsafeMutablePointer<Float>) { self.realp = realp; self.imagp = imagp }
}

// MARK: - FFT

private final class FFTPlan {
    let log2n: Int
    let n: Int
    var cosT: [Float]
    var sinT: [Float]

    init(log2n: Int) {
        self.log2n = log2n
        n = 1 << log2n
        cosT = (0..<max(1, n / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(1 << log2n))) }
        sinT = (0..<max(1, n / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(1 << log2n))) }
    }

    /// Radix-2-FFT an Ort und Stelle; `sign` −1 = vorwärts (e^{−i…}), +1 = rückwärts; ohne Skalierung. Gilt für n = 2^k bis zur Größe des Plans.
    func transform(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, stride: Int, count: Int, sign: Float) {
        guard count > 1 else { return }
        var j = 0
        for i in 0..<count - 1 {
            if i < j { swap(&re[i * stride], &re[j * stride]); swap(&im[i * stride], &im[j * stride]) }
            var m = count >> 1
            while m >= 1 && j & m != 0 { j ^= m; m >>= 1 }
            j |= m
        }
        var len = 2
        while len <= count {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < count {
                for k in 0..<half {
                    let wr = cosT[k * step], wi = sign * sinT[k * step]
                    let a = (start + k) * stride, b = (start + k + half) * stride
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
    }
}

public func vDSP_create_fftsetup(_ log2n: vDSP_Length, _ radix: FFTRadix) -> FFTSetup? {
    guard radix == 0 else { return nil }
    return OpaquePointer(Unmanaged.passRetained(FFTPlan(log2n: Int(log2n))).toOpaque())
}

public func vDSP_destroy_fftsetup(_ setup: FFTSetup?) {
    guard let setup else { return }
    Unmanaged<FFTPlan>.fromOpaque(UnsafeRawPointer(setup)).release()
}

private func plan(_ setup: FFTSetup) -> FFTPlan { Unmanaged<FFTPlan>.fromOpaque(UnsafeRawPointer(setup)).takeUnretainedValue() }

/// Komplexe FFT an Ort und Stelle (Zerlegung in Real- und Imaginärteil). Vorwärts: e^{−i…}, ohne Skalierung.
public func vDSP_fft_zip(_ setup: FFTSetup, _ c: UnsafePointer<DSPSplitComplex>, _ stride: vDSP_Stride, _ log2n: vDSP_Length, _ direction: FFTDirection) {
    plan(setup).transform(c.pointee.realp, c.pointee.imagp, stride: stride, count: 1 << Int(log2n), sign: direction >= 0 ? -1 : 1)
}

/// Reelle FFT an Ort und Stelle. Eingang: gerade Werte in realp, ungerade in imagp (`vDSP_ctoz`); Ausgang gepackt:
/// realp[0] = Gleichanteil, imagp[0] = Nyquist, sonst Bin k; Vorwärtsergebnis ist wie bei Apple das 2-fache der DFT.
public func vDSP_fft_zrip(_ setup: FFTSetup, _ c: UnsafePointer<DSPSplitComplex>, _ stride: vDSP_Stride, _ log2n: vDSP_Length, _ direction: FFTDirection) {
    let p = plan(setup)
    let nReal = 1 << Int(log2n)
    let h = nReal / 2
    let re = c.pointee.realp, im = c.pointee.imagp
    guard h >= 1 else { return }
    if direction >= 0 {
        p.transform(re, im, stride: stride, count: h, sign: -1)
        let z0r = re[0], z0i = im[0]
        re[0] = 2 * (z0r + z0i)
        im[0] = 2 * (z0r - z0i)
        let twoPi = 2 * Double.pi / Double(nReal)
        if h > 1 {
            for k in 1..<(h / 2 + 1) {
                let k2 = h - k
                let ar = re[k * stride], ai = im[k * stride]
                let br = re[k2 * stride], bi = im[k2 * stride]
                let wr = Float(cos(twoPi * Double(k))), wi = -Float(sin(twoPi * Double(k)))
                // E = (Z[k] + conj(Z[h-k])), O = (Z[k] − conj(Z[h-k]))/i
                let er = ar + br, ei = ai - bi
                let dr = ar - br, di = ai + bi
                let orr = di, oi = -dr
                let tr = orr * wr - oi * wi, ti = orr * wi + oi * wr
                re[k * stride] = er + tr; im[k * stride] = ei + ti
                if k2 != k {
                    let wr2 = Float(cos(twoPi * Double(k2))), wi2 = -Float(sin(twoPi * Double(k2)))
                    // Für h−k: E' = conj(E), O' = conj(O)
                    let tr2 = orr * wr2 + oi * wi2, ti2 = orr * wi2 - oi * wr2
                    re[k2 * stride] = er + tr2; im[k2 * stride] = -ei + ti2
                }
            }
        }
    } else {
        fatalError("vDSP_fft_zrip rückwärts: nicht umgesetzt")
    }
}

/// Wandelt verschränkte komplexe Werte in getrennte Real- und Imaginärteile (`stride` in Gleitkommazahlen, 2 = lückenlos).
public func vDSP_ctoz(_ c: UnsafePointer<DSPComplex>, _ ic: vDSP_Stride, _ z: UnsafePointer<DSPSplitComplex>, _ iz: vDSP_Stride, _ n: vDSP_Length) {
    let step = ic / 2
    for i in 0..<Int(n) {
        z.pointee.realp[i * iz] = c[i * step].real
        z.pointee.imagp[i * iz] = c[i * step].imag
    }
}

// MARK: - Vektorrechnung

public func vDSP_vmul(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    for i in 0..<Int(n) { c[i * ic] = a[i * ia] * b[i * ib] }
}

public func vDSP_vadd(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    for i in 0..<Int(n) { c[i * ic] = a[i * ia] + b[i * ib] }
}

/// Wie bei Apple: C = B − A
public func vDSP_vsub(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    for i in 0..<Int(n) { c[i * ic] = b[i * ib] - a[i * ia] }
}

/// C = (A + B) · s
public func vDSP_vasm(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride, _ s: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    let k = s.pointee
    for i in 0..<Int(n) { c[i * ic] = (a[i * ia] + b[i * ib]) * k }
}

public func vDSP_vsmul(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ s: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    let k = s.pointee
    for i in 0..<Int(n) { c[i * ic] = a[i * ia] * k }
}

/// C = A, wenn A ≥ Schwelle, sonst Schwelle
public func vDSP_vthr(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    let t = b.pointee
    for i in 0..<Int(n) { let v = a[i * ia]; c[i * ic] = v >= t ? v : t }
}

/// C = 10·log10(A/Bezug) (flag 0, Leistung) bzw. 20·log10(A/Bezug) (flag 1, Amplitude)
public func vDSP_vdbcon(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length, _ flag: UInt32) {
    let ref = b.pointee
    let f: Float = flag == 0 ? 10 : 20
    for i in 0..<Int(n) { c[i * ic] = f * log10f(a[i * ia] / ref) }
}

/// Betragsquadrate: C = re² + im²
public func vDSP_zvmags(_ a: UnsafePointer<DSPSplitComplex>, _ ia: vDSP_Stride, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    let re = a.pointee.realp, im = a.pointee.imagp
    for i in 0..<Int(n) { let r = re[i * ia], q = im[i * ia]; c[i * ic] = r * r + q * q }
}

public func vDSP_dotpr(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride, _ result: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    var s: Float = 0
    for i in 0..<Int(n) { s += a[i * ia] * b[i * ib] }
    result.pointee = s
}

public func vDSP_sve(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ result: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    var s: Float = 0
    for i in 0..<Int(n) { s += a[i * ia] }
    result.pointee = s
}

public func vDSP_svesq(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ result: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    var s: Float = 0
    for i in 0..<Int(n) { let v = a[i * ia]; s += v * v }
    result.pointee = s
}

public func vDSP_measqv(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ result: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    guard n > 0 else { result.pointee = 0; return }
    vDSP_svesq(a, ia, result, n)
    result.pointee /= Float(n)
}

public func vDSP_rmsqv(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ result: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    vDSP_measqv(a, ia, result, n)
    result.pointee = result.pointee.squareRoot()
}

public func vDSP_maxmgv(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ result: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    var m: Float = 0
    for i in 0..<Int(n) { m = max(m, abs(a[i * ia])) }
    result.pointee = m
}

/// Hann-Fenster w[n] = 0,5·(1 − cos(2πn/N)). Die Skalierung von `vDSP_HANN_NORM` ist hier nicht nachgebildet: Digidec teilt die Pegel durch die Fenstersumme,
/// der Faktor kürzt sich also heraus. TODO: gegen einen Lauf am Mac prüfen, falls Fensterwerte anderswo direkt verwendet werden.
public func vDSP_hann_window(_ window: UnsafeMutablePointer<Float>, _ n: vDSP_Length, _ flags: Int32) {
    let count = Int(n)
    for i in 0..<count { window[i] = Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(count)))) }
}

/// Dezimierende Korrelation: C[n] = Σ A[n·DF + p] · F[p] (p < P)
public func vDSP_desamp(_ a: UnsafePointer<Float>, _ df: vDSP_Stride, _ f: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length, _ p: vDSP_Length) {
    let taps = Int(p)
    for i in 0..<Int(n) {
        var s: Float = 0
        let base = a + i * df
        for k in 0..<taps { s += base[k] * f[k] }
        c[i] = s
    }
}
