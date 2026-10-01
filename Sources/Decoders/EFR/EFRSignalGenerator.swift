import Foundation

/// Erzeugt synthetische 8-kHz-Audiosignale für EFR (200 Baud FSK, Shift 340 Hz, 8E1, DIN 19244).
public enum EFRSignalGenerator {
    public static let sampleRate: Double = 8000.0
    public static let baudRate: Double = 200.0

    /// Baut ein DIN 19244 variables Telegramm (0x68 ... 0x16)
    public static func buildVariableFrame(control: UInt8, address: UInt8, asdu: [UInt8]) -> [UInt8] {
        var userBytes: [UInt8] = [control, address]
        userBytes.append(contentsOf: asdu)

        let length = UInt8(userBytes.count)
        var frame: [UInt8] = [0x68, length, length, 0x68]
        frame.append(contentsOf: userBytes)

        let cs = userBytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        frame.append(UInt8(cs))
        frame.append(0x16)

        return frame
    }

    /// Baut ein DIN 19244 Telegramm fester Länge (0x10 ... 0x16)
    public static func buildFixedFrame(control: UInt8, address: UInt8) -> [UInt8] {
        let cs = (Int(control) + Int(address)) & 0xFF
        return [0x10, control, address, UInt8(cs), 0x16]
    }

    /// Kodiert Datum/Uhrzeit in ein CP56Time2a 7-Byte Feld
    public static func encodeCP56Time2a(date: Date, isSummer: Bool = false) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: isSummer ? 7200 : 3600) ?? .current

        let comp = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second, .nanosecond], from: date)
        let sec = comp.second ?? 0
        let ms = sec * 1000 + (comp.nanosecond ?? 0) / 1_000_000
        let min = comp.minute ?? 0
        let hour = comp.hour ?? 0
        let day = comp.day ?? 1
        let weekday = comp.weekday ?? 1 // 1 = So, 2 = Mo ...
        let efrWeekday = (weekday == 1) ? 7 : (weekday - 1) // 1 = Mo ... 7 = So
        let month = comp.month ?? 1
        let year2 = (comp.year ?? 2026) % 100

        var bytes = [UInt8](repeating: 0, count: 7)
        bytes[0] = UInt8(ms & 0xFF)
        bytes[1] = UInt8((ms >> 8) & 0xFF)
        bytes[2] = UInt8(min & 0x3F)
        bytes[3] = UInt8(hour & 0x1F) | (isSummer ? 0x80 : 0x00)
        bytes[4] = UInt8(day & 0x1F) | (UInt8(efrWeekday & 0x07) << 5)
        bytes[5] = UInt8(month & 0x0F)
        bytes[6] = UInt8(year2 & 0x7F)

        return bytes
    }

    /// Wandelt Bytes in ein 8E1-Bitmuster (Start=0, 8 Datenbits LSB-first, Even Parity, Stop=1)
    public static func bytesTo8E1Bits(_ bytes: [UInt8], leadBits: Int = 10, tailBits: Int = 10) -> [Bool] {
        var bits = [Bool]()

        // Vorlauf: Mark (1 = true)
        bits.append(contentsOf: Array(repeating: true, count: leadBits))

        for byte in bytes {
            // Start-Bit (Space = false = 0)
            bits.append(false)

            // 8 Datenbits LSB-first
            var ones = 0
            for i in 0..<8 {
                let bit = ((byte >> i) & 1) == 1
                bits.append(bit)
                if bit { ones += 1 }
            }

            // Gerade Parität (Even Parity): Paritätsbit so wählen, dass Gesamt-Einsen gerade ist
            let parityBit = (ones % 2 != 0)
            bits.append(parityBit)

            // Stopp-Bit (Mark = true = 1)
            bits.append(true)
        }

        // Nachlauf: Mark
        bits.append(contentsOf: Array(repeating: true, count: tailBits))
        return bits
    }

    /// Erzeugt 8-kHz-FSK-Audiosignal aus den 8E1-Bits
    public static func generateFSKAudio(bits: [Bool], centerHz: Double = 1500.0, shiftHz: Double = 340.0,
                                        amplitude: Float = 0.8, snrDb: Double? = nil) -> [Float] {
        let samplesPerBit = Int(sampleRate / baudRate) // 8000 / 200 = 40 Samples
        let totalSamples = bits.count * samplesPerBit
        var samples = [Float](repeating: 0.0, count: totalSamples)

        let markHz = centerHz + shiftHz / 2.0
        let spaceHz = centerHz - shiftHz / 2.0
        let twoPi = 2.0 * Double.pi

        var phase: Double = 0.0

        for (bitIndex, bit) in bits.enumerated() {
            let freq = bit ? markHz : spaceHz
            let phaseInc = twoPi * freq / sampleRate
            let startIdx = bitIndex * samplesPerBit

            for n in 0..<samplesPerBit {
                let idx = startIdx + n
                samples[idx] = amplitude * Float(cos(phase))
                phase += phaseInc
                if phase >= twoPi { phase -= twoPi }
            }
        }

        // Rauschen hinzufügen, falls gewünscht
        if let snr = snrDb {
            let signalPower = Double(amplitude * amplitude) / 2.0
            let noisePower = signalPower / pow(10.0, snr / 10.0)
            let noiseSigma = sqrt(noisePower)

            for i in 0..<samples.count {
                let u1 = max(1e-10, Double.random(in: 0...1))
                let u2 = Double.random(in: 0...1)
                let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
                samples[i] += Float(z * noiseSigma)
            }
        }

        return samples
    }
}
