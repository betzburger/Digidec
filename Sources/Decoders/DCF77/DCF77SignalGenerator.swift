import Foundation

/// Erzeugt synthetische DCF77-Audiosignale (8 kHz) für automatische Tests und Offline-Prüfungen.
public enum DCF77SignalGenerator {
    public static let sampleRate: Double = 8000.0

    /// Kodiert eine Zeitangabe in das 59-Bit-DCF77-Muster (Sekunden 0..58)
    public static func encodeBits(year: Int, month: Int, day: Int, weekday: Int, hour: Int, minute: Int,
                                  isSummer: Bool, backupAntenna: Bool = false) -> [Int] {
        var bits = Array(repeating: 0, count: 59)

        // Bit 0 = 0
        bits[0] = 0

        // Bits 1..14 = 0 (Wetterdaten vorerst 0)
        // Bit 15: Reserveantenne
        bits[15] = backupAntenna ? 1 : 0
        // Bit 16: Ankündigung Zeitumstellung
        bits[16] = 0
        // Bits 17/18: MESZ / MEZ
        bits[17] = isSummer ? 1 : 0
        bits[18] = isSummer ? 0 : 1
        // Bit 19: Schaltsekunde
        bits[19] = 0
        // Bit 20: Start Zeitinfo
        bits[20] = 1

        // Minute (Bits 21..27) BCD [1, 2, 4, 8, 10, 20, 40]
        encodeBCD(minute, weights: [1, 2, 4, 8, 10, 20, 40], into: &bits, startIndex: 21)
        // P1 (Bit 28)
        let p1 = bits[21...27].reduce(0, +) % 2
        bits[28] = p1

        // Stunde (Bits 29..34) BCD [1, 2, 4, 8, 10, 20]
        encodeBCD(hour, weights: [1, 2, 4, 8, 10, 20], into: &bits, startIndex: 29)
        // P2 (Bit 35)
        let p2 = bits[29...34].reduce(0, +) % 2
        bits[35] = p2

        // Tag (Bits 36..41) BCD [1, 2, 4, 8, 10, 20]
        encodeBCD(day, weights: [1, 2, 4, 8, 10, 20], into: &bits, startIndex: 36)

        // Wochentag (Bits 42..44) BCD [1, 2, 4]
        encodeBCD(weekday, weights: [1, 2, 4], into: &bits, startIndex: 42)

        // Monat (Bits 45..49) BCD [1, 2, 4, 8, 10]
        encodeBCD(month, weights: [1, 2, 4, 8, 10], into: &bits, startIndex: 45)

        // Jahr 2-stellig (Bits 50..57) BCD [1, 2, 4, 8, 10, 20, 40, 80]
        let y2 = year % 100
        encodeBCD(y2, weights: [1, 2, 4, 8, 10, 20, 40, 80], into: &bits, startIndex: 50)

        // P3 (Bit 58)
        let p3 = bits[36...57].reduce(0, +) % 2
        bits[58] = p3

        return bits
    }

    /// Erzeugt ein vollständiges 60-Sekunden-Audiosignal (480.000 Samples bei 8 kHz)
    public static func generateMinuteAudio(bits: [Int], centerHz: Double = 1000.0,
                                           carrierAmplitude: Float = 0.8,
                                           dipFraction: Float = 0.2,
                                           snrDb: Double? = nil) -> [Float] {
        let totalSamples = Int(sampleRate * 60.0)
        var samples = [Float](repeating: 0.0, count: totalSamples)

        let twoPi = 2.0 * Double.pi
        let phaseInc = twoPi * centerHz / sampleRate
        var phase: Double = 0.0

        for sec in 0..<60 {
            let startIdx = Int(Double(sec) * sampleRate)
            let bit = (sec < bits.count) ? bits[sec] : -1 // sec 59 = keine Absenkung

            // Absenkungsdauer: Bit 0 -> 100 ms (800 Samples), Bit 1 -> 200 ms (1600 Samples)
            let dipSamples: Int
            if bit == 0 {
                dipSamples = Int(0.100 * sampleRate)
            } else if bit == 1 {
                dipSamples = Int(0.200 * sampleRate)
            } else {
                dipSamples = 0 // Sekunde 59: unmoduliert
            }

            for n in 0..<Int(sampleRate) {
                let idx = startIdx + n
                guard idx < totalSamples else { break }

                let amp: Float = (n < dipSamples) ? (carrierAmplitude * dipFraction) : carrierAmplitude
                samples[idx] = amp * Float(cos(phase))

                phase += phaseInc
                if phase >= twoPi { phase -= twoPi }
            }
        }

        // Rauschen hinzufügen, falls gewünscht
        if let snr = snrDb {
            let signalPower = Double(carrierAmplitude * carrierAmplitude) / 2.0
            let noisePower = signalPower / pow(10.0, snr / 10.0)
            let noiseSigma = sqrt(noisePower)

            for i in 0..<samples.count {
                // Box-Muller für Normalverteilung
                let u1 = max(1e-10, Double.random(in: 0...1))
                let u2 = Double.random(in: 0...1)
                let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
                samples[i] += Float(z * noiseSigma)
            }
        }

        return samples
    }

    private static func encodeBCD(_ value: Int, weights: [Int], into bits: inout [Int], startIndex: Int) {
        var rem = value
        // Von höchster Wertigkeit nach unten
        for i in (0..<weights.count).reversed() {
            let w = weights[i]
            if rem >= w {
                bits[startIndex + i] = 1
                rem -= w
            } else {
                bits[startIndex + i] = 0
            }
        }
    }
}
