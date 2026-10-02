import Foundation

// MARK: - UKW-DSC (Kanal 70)

/// DSC auf UKW (ITU-R M.493, Kanal 70, 156,525 MHz, FM): 1200 Bd, Y = 1300 Hz (tiefer, Bit 1), B = 2100 Hz (höher, Bit 0).
/// Zeichen, Phasing, DX/RX-Verschachtelung und ECC sind dieselben wie auf MF/HF; deshalb liest dieselbe `DSCFramer`-Logik.
/// Die Demodulation ist der AFSK-Demodulator (mehrere Entscheider, Taktrückgewinnung) im Rohbit-Betrieb.
public final class DSCVHFReceiver {
    public static let sampleRate = 12_000.0
    public static let baud = 1200.0
    public static let yHz = 1300.0
    public static let bHz = 2100.0

    private struct Path {
        let demod: AFSKDemodulator
        var framers: [DSCFramer]
    }

    private var paths: [Path] = []
    private let slicerCount = 5

    public init(sampleRate: Double = DSCVHFReceiver.sampleRate) {
        for pre in [0.0, AFSKReceiver.emphasisAmount] {
            var o = AFSKDemodulator.Options()
            o.slicers = slicerCount
            o.repairBits = false
            o.preEmphasis = pre
            let d = AFSKDemodulator(sampleRate: sampleRate, options: o, baud: Self.baud, markHz: Self.yHz, spaceHz: Self.bHz)
            paths.append(Path(demod: d, framers: (0..<slicerCount).map { _ in DSCFramer() }))
        }
    }

    /// Mindestens ein Rahmensucher hat die Phasing-Folge erkannt
    public var isLocked: Bool { paths.contains { $0.framers.contains { $0.isLocked } } }
    public var level: Double { paths.map { $0.demod.levelPeak }.max() ?? 0 }

    public func reset() {
        for i in paths.indices {
            paths[i].demod.reset()
            paths[i].framers = (0..<slicerCount).map { _ in DSCFramer() }
        }
    }

    /// Verarbeitet 12-kHz-Audio; `onCall` für jeden fertig gelesenen Ruf (derselbe Ruf kommt meist mehrfach aus
    /// verschiedenen Entscheidern: der `DSCCallCollector` behält den besten)
    public func process(_ samples: UnsafeBufferPointer<Float>, onCall: (DSCCall) -> Void) {
        for p in 0..<paths.count {
            var found: [DSCCall] = []
            let framers = paths[p].framers
            paths[p].demod.onRawBit = { slicer, bit in
                if let c = framers[slicer].push(bit) { found.append(c) }
            }
            paths[p].demod.process(samples) { _ in }
            paths[p].demod.onRawBit = nil
            found.forEach(onCall)
        }
    }
}

// MARK: - Testsignal

extension DSCSignalGenerator {
    /// UKW-DSC-Audio (nur für Tests): 1200 Bd, Y (1) = 1300 Hz, B (0) = 2100 Hz, stetige Phase
    public static func audioVHF(bits: [UInt8], sampleRate: Double = DSCVHFReceiver.sampleRate, amplitude: Double = 0.5,
                                lead: Double = 0.3, tail: Double = 0.3, baudError: Double = 0) -> [Float] {
        let perBit = sampleRate / (DSCVHFReceiver.baud * (1 + baudError))
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        var phase = 0.0
        var produced = 0.0
        for (n, b) in bits.enumerated() {
            let f = b == 1 ? DSCVHFReceiver.yHz : DSCVHFReceiver.bHz
            let end = perBit * Double(n + 1)
            while produced < end {
                out.append(Float(amplitude * sin(phase)))
                phase += 2 * .pi * f / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
                produced += 1
            }
        }
        out += [Float](repeating: 0, count: Int(tail * sampleRate))
        return out
    }
}
