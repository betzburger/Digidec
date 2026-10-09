// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Diskrete Fourier-Transformation beliebiger Länge mit kleinen Primfaktoren (die DRM-Längen 1152, 1024, 704 und 448 haben die Faktoren 2, 3, 7 und 11).
/// Rekursiv zerlegt (Decimation in Time), Twiddle-Tabelle für die Länge N.
final class DRMFFT {
    let n: Int
    private let factors: [Int]
    private let cosT: [Float]
    private let sinT: [Float]
    private var scratchRe: [Float]
    private var scratchIm: [Float]

    init(size: Int) {
        n = size
        var f: [Int] = []
        var m = size
        for p in [2, 3, 5, 7, 11, 13] { while m % p == 0 { f.append(p); m /= p } }
        precondition(m == 1, "DRMFFT: Länge \(size) hat zu große Primfaktoren")
        // größere Faktoren zuerst (weniger Rekursionstiefe bei den teuren Stufen)
        factors = f.sorted(by: >)
        cosT = (0..<size).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinT = (0..<size).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }     // exp(−j 2π k / N)
        scratchRe = [Float](repeating: 0, count: size)
        scratchIm = [Float](repeating: 0, count: size)
    }

    /// X[k] = Σ x[n] exp(−j 2π n k / N); Ergebnis in `outRe`/`outIm`
    func forward(re: UnsafePointer<Float>, im: UnsafePointer<Float>, outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) {
        recurse(re, im, 1, n, outRe, outIm, 0)
    }

    func forward(_ re: [Float], _ im: [Float]) -> (re: [Float], im: [Float]) {
        var oRe = [Float](repeating: 0, count: n), oIm = [Float](repeating: 0, count: n)
        re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in
            oRe.withUnsafeMutableBufferPointer { a in oIm.withUnsafeMutableBufferPointer { b in
                forward(re: r.baseAddress!, im: i.baseAddress!, outRe: a.baseAddress!, outIm: b.baseAddress!)
            } }
        } }
        return (oRe, oIm)
    }

    /// Inverse Transformation (ohne 1/N): x[n] = Σ X[k] exp(+j 2π n k / N)
    func inverse(_ re: [Float], _ im: [Float]) -> (re: [Float], im: [Float]) {
        let r = forward(im, re)          // Vertauschen von Real- und Imaginärteil ergibt die inverse Transformation
        return (r.im, r.re)
    }

    private func recurse(_ inRe: UnsafePointer<Float>, _ inIm: UnsafePointer<Float>, _ stride: Int, _ len: Int,
                         _ outRe: UnsafeMutablePointer<Float>, _ outIm: UnsafeMutablePointer<Float>, _ level: Int) {
        if len == 1 { outRe[0] = inRe[0]; outIm[0] = inIm[0]; return }
        let p = factors[level]
        let m = len / p
        for r in 0..<p {
            recurse(inRe + r * stride, inIm + r * stride, stride * p, m, outRe + r * m, outIm + r * m, level + 1)
        }
        // Zusammenfassen: X[k + q m] = Σ_r W_len^{r (k + q m)} Y_r[k]
        let base = n / len
        scratchRe.withUnsafeMutableBufferPointer { sr in scratchIm.withUnsafeMutableBufferPointer { si in
            var tr = [Float](repeating: 0, count: p), ti = [Float](repeating: 0, count: p)
            for k in 0..<m {
                for r in 0..<p {
                    let idx = (r * k * base) % n
                    let yr = outRe[r * m + k], yi = outIm[r * m + k]
                    tr[r] = yr * cosT[idx] - yi * sinT[idx]
                    ti[r] = yr * sinT[idx] + yi * cosT[idx]
                }
                for q in 0..<p {
                    var ar = tr[0], ai = ti[0]
                    if p == 2 {
                        ar = q == 0 ? tr[0] + tr[1] : tr[0] - tr[1]
                        ai = q == 0 ? ti[0] + ti[1] : ti[0] - ti[1]
                    } else {
                        for r in 1..<p {
                            let idx = (r * q * m * base) % n
                            ar += tr[r] * cosT[idx] - ti[r] * sinT[idx]
                            ai += tr[r] * sinT[idx] + ti[r] * cosT[idx]
                        }
                    }
                    sr[k + q * m] = ar; si[k + q * m] = ai
                }
            }
            for i in 0..<len { outRe[i] = sr[i]; outIm[i] = si[i] }
        } }
    }
}
