// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
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

    /// Nutzbytes eines Zeittelegramms: `00, Sekunde << 2, Minute, Stunde | Sommerzeit << 7, Wochentag << 5 | Tag, Monat, Jahr`
    /// (Wochentag 0 = Sonntag). Format nach dcf39_decoder (mryndzionek, MIT) und echten DCF39-Aufnahmen.
    public static func timeTelegramUserData(date: Date, isSummer: Bool = false) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: isSummer ? 7200 : 3600) ?? .current
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        return [
            0,
            UInt8(((c.second ?? 0) << 2) & 0xFF),
            UInt8(c.minute ?? 0),
            UInt8((c.hour ?? 0) & 0x7F) | (isSummer ? 0x80 : 0),
            UInt8((((c.weekday ?? 1) - 1) & 0x07) << 5) | UInt8((c.day ?? 1) & 0x1F),
            UInt8(c.month ?? 1),
            UInt8((c.year ?? 2000) % 100),
        ]
    }

    /// Vollständiges Zeittelegramm (A1 = A2 = 0) mit Telegrammnummer im oberen Nibble des Steuerbytes
    public static func buildTimeTelegram(date: Date, isSummer: Bool = false, number: UInt8 = 3) -> [UInt8] {
        buildVariableFrame(control: (number << 4) | 0x07, address: 0, asdu: [0] + timeTelegramUserData(date: date, isSummer: isSummer))
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
                                        amplitude: Float = 0.8, snrDb: Double? = nil, inverted: Bool = false) -> [Float] {
        let samplesPerBit = Int(sampleRate / baudRate) // 8000 / 200 = 40 Samples
        let totalSamples = bits.count * samplesPerBit
        var samples = [Float](repeating: 0.0, count: totalSamples)

        // Mark = untere, Space = obere Frequenz (DCF39: 138,830 / 139,170 kHz); `inverted` simuliert die falsche Seitenbandlage
        let markHz = inverted ? centerHz + shiftHz / 2.0 : centerHz - shiftHz / 2.0
        let spaceHz = inverted ? centerHz - shiftHz / 2.0 : centerHz + shiftHz / 2.0
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
