import Foundation

/// Kern des DCF77-Decoders (77,5 kHz, AM-Impulsbreiten-Modulation).
/// Verarbeitet 8-kHz-Audio (z. B. 1.000 Hz NF-Ton bei Empfänger-Dial 76,500 kHz USB).
/// Modulationsprinzip: Zu Beginn jeder Sekunde 0..58 wird die Trägeramplitude für
/// 100 ms (Bit 0) bzw. 200 ms (Bit 1) auf ca. 15–25 % abgesenkt. Sekunde 59 hat
/// keinen Impuls (Synchronisationslücke).
public final class DCF77Core: @unchecked Sendable {
    public static let sampleRate: Double = 8000.0

    public enum BitValue: Equatable, Sendable {
        case zero(durationMs: Double)
        case one(durationMs: Double)
        case minuteMarker   // Sekunde 59: fehlender Impuls
        case invalid(durationMs: Double)
        case empty

        public var binaryValue: Int? {
            switch self {
            case .zero: return 0
            case .one:  return 1
            default:    return nil
            }
        }
    }

    public struct DecodedTime: Equatable, Sendable {
        public var date: Date                 // Zeitstempel (Beginn der Minute)
        public var year: Int                  // Vierstellig, z. B. 2026
        public var month: Int                 // 1..12
        public var day: Int                   // 1..31
        public var weekday: Int               // 1..7 (1 = Mo ... 7 = So)
        public var weekdayName: String        // "Donnerstag"
        public var hour: Int                  // 0..23
        public var minute: Int                // 0..59
        public var second: Int                // 0..59
        public var isSummerTime: Bool         // true = MESZ (UTC+2), false = MEZ (UTC+1)
        public var timeZoneName: String       // "MESZ" bzw. "MEZ"
        public var timeChangeAnnounced: Bool  // Bit 16 (Wechsel zur nächsten Stunde)
        public var leapSecondAnnounced: Bool  // Bit 19
        public var backupAntenna: Bool        // Bit 15 (Reserveantenne)
        public var weatherBits: [Int]         // Bits 1..14 (Meteotime)
        public var deltaMilliseconds: Double  // Mac-Systemzeit minus DCF77-Zeit (ms)
        public var receivedAt: Date

        public var formattedTime: String {
            String(format: "%02d:%02d:%02d %@", hour, minute, second, timeZoneName)
        }

        public var formattedDate: String {
            String(format: "%@, %02d.%02d.%04d", weekdayName, day, month, year)
        }
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var signalLevel: Double        // 0..100 %
        public var carrierPeak: Double
        public var carrierDip: Double
        public var snrDb: Double
        public var currentSecond: Int         // 0..59 (-1 wenn nicht synchronisiert)
        public var isSynchronized: Bool
        public var minuteBits: [BitValue]     // 60 Elemente (Sekunden 0..59)
        public var lastDecodedTime: DecodedTime?
        public var scope: [Float]             // Letzte ~1,2 Sekunden Hüllkurve für Oszilloskop
    }

    public var onTimeDecoded: ((DecodedTime) -> Void)?
    public var onBitDecoded: ((Int, BitValue) -> Void)?

    private var centerHz: Double
    private var phase: Double = 0.0
    private let phaseIncrementFactor: Double = 2.0 * .pi / sampleRate

    // 2-stufiger IIR-Tiefpass für Basisband-I/Q (ca. 20 Hz Bandbreite)
    private let alpha: Double = 0.02
    private var iLp1: Double = 0.0
    private var iLp2: Double = 0.0
    private var qLp1: Double = 0.0
    private var qLp2: Double = 0.0

    // Pegelnachführung
    private var peakLevel: Double = 0.01
    private var dipLevel: Double = 0.002
    private var threshold: Double = 0.005

    // Zustandserkennung
    private var sampleIndex: Int64 = 0
    private var lastNegativeEdgeSample: Int64 = -1_000_000
    private var isLow: Bool = false
    private var inDip: Bool = false
    private var dipSampleCount: Int = 0

    // Frame-Synchronisation (60 Sekunden)
    private var isSynchronized: Bool = false
    private var currentSecond: Int = -1
    private var minuteBits: [BitValue] = Array(repeating: .empty, count: 60)
    private var lastDecodedTime: DecodedTime?

    // Scope-Puffer: 120 Punkte (1,2 s bei 100 Hz Dezimierung)
    private var scopeDecimator: Int = 0
    private let scopeSize = 120
    private var scopeBuffer: [Float] = Array(repeating: 0.0, count: 120)
    private var scopeWriteIndex: Int = 0

    public init(centerHz: Double = 1000.0) {
        self.centerHz = centerHz
    }

    public func setCenter(_ hz: Double) {
        centerHz = hz
    }

    public func reset() {
        phase = 0.0
        iLp1 = 0.0
        iLp2 = 0.0
        qLp1 = 0.0
        qLp2 = 0.0
        peakLevel = 0.01
        dipLevel = 0.002
        threshold = 0.005
        sampleIndex = 0
        lastNegativeEdgeSample = -1_000_000
        isLow = false
        inDip = false
        dipSampleCount = 0
        isSynchronized = false
        currentSecond = -1
        minuteBits = Array(repeating: .empty, count: 60)
    }

    /// Verarbeitet einen Block von 8-kHz-Audio-Samples
    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let phaseInc = 2.0 * .pi * centerHz / Self.sampleRate
        let twoPi = 2.0 * .pi

        for sample in samples {
            let s = Double(sample)
            let cosP = cos(phase)
            let sinP = sin(phase)
            phase += phaseInc
            if phase >= twoPi { phase -= twoPi }

            let inI = s * cosP
            let inQ = -s * sinP

            // 2-stufiger Tiefpass
            iLp1 += alpha * (inI - iLp1)
            iLp2 += alpha * (iLp1 - iLp2)
            qLp1 += alpha * (inQ - qLp1)
            qLp2 += alpha * (qLp1 - qLp2)

            let env = sqrt(iLp2 * iLp2 + qLp2 * qLp2)

            // Pegelnachführung (schnelle Annäherung nach oben, langsamer Abfall)
            if env > peakLevel {
                peakLevel += 0.01 * (env - peakLevel)
            } else {
                peakLevel -= 0.00003 * peakLevel
            }
            if peakLevel < 0.0001 { peakLevel = 0.0001 }

            // Schwelle: 55 % des Träger-Spitzenwerts
            threshold = peakLevel * 0.55

            // Scope-Puffer befüllen (100 Hz Dezimierung = alle 80 Samples)
            scopeDecimator += 1
            if scopeDecimator >= 80 {
                scopeDecimator = 0
                let normalized = Float(min(1.0, max(0.0, env / (peakLevel * 1.2))))
                scopeBuffer[scopeWriteIndex] = normalized
                scopeWriteIndex = (scopeWriteIndex + 1) % scopeSize
            }

            // Slicing
            let sampleLow = (env < threshold)

            if !isLow && sampleLow {
                // FALLENDE FLANKE: Neuer Sekundenimpuls beginnt
                isLow = true
                inDip = true
                dipSampleCount = 0

                let deltaSamples = sampleIndex - lastNegativeEdgeSample
                let deltaSeconds = Double(deltaSamples) / Self.sampleRate
                lastNegativeEdgeSample = sampleIndex

                // Minutenmarke (Sekunde 59 fehlte -> Abstand ca. 1,75 .. 2,25 s)
                if deltaSeconds >= 1.7 && deltaSeconds <= 2.3 {
                    // Die vorangehende Lücke war Sekunde 59!
                    if isSynchronized {
                        minuteBits[59] = .minuteMarker
                        decodeFrame()
                    }
                    isSynchronized = true
                    currentSecond = 0
                    minuteBits = Array(repeating: .empty, count: 60)
                } else if isSynchronized {
                    if deltaSeconds >= 0.8 && deltaSeconds <= 1.2 {
                        currentSecond = (currentSecond + 1) % 60
                    } else {
                        // Bei verpassten Impulsen anhand der Zeit weiterspringen
                        let steps = Int((deltaSeconds + 0.5).rounded())
                        currentSecond = (currentSecond + max(1, steps)) % 60
                    }
                }
            } else if isLow && !sampleLow {
                // STEIGENDE FLANKE: Absenkung beendet
                isLow = false
                inDip = false

                let dipMs = Double(dipSampleCount) * 1000.0 / Self.sampleRate

                let bit: BitValue
                if dipMs >= 55.0 && dipMs <= 145.0 {
                    bit = .zero(durationMs: dipMs)
                } else if dipMs >= 155.0 && dipMs <= 255.0 {
                    bit = .one(durationMs: dipMs)
                } else {
                    bit = .invalid(durationMs: dipMs)
                }

                if isSynchronized && currentSecond >= 0 && currentSecond < 60 {
                    minuteBits[currentSecond] = bit
                    onBitDecoded?(currentSecond, bit)
                }
            } else if inDip {
                dipSampleCount += 1
                if env < dipLevel {
                    dipLevel += 0.05 * (env - dipLevel)
                }
            }

            sampleIndex += 1
        }
    }

    /// Statusabfrage für UI
    public func getStatus() -> Status {
        let snr = dipLevel > 0.00001 ? 20.0 * log10(max(1.0, peakLevel / dipLevel)) : 0.0
        let level = min(100.0, max(0.0, peakLevel * 200.0))

        // Scope geordnet nach Zeit (ältester Punkt zuerst)
        var orderedScope: [Float] = []
        orderedScope.reserveCapacity(scopeSize)
        for i in 0..<scopeSize {
            let idx = (scopeWriteIndex + i) % scopeSize
            orderedScope.append(scopeBuffer[idx])
        }

        return Status(
            centerHz: centerHz,
            signalLevel: level,
            carrierPeak: peakLevel,
            carrierDip: dipLevel,
            snrDb: snr,
            currentSecond: currentSecond,
            isSynchronized: isSynchronized,
            minuteBits: minuteBits,
            lastDecodedTime: lastDecodedTime,
            scope: orderedScope
        )
    }

    // MARK: - Frame-Decodierung & Plausibilität

    private func decodeFrame() {
        // Prüfen, ob Bits 0..58 vorhanden sind
        var rawBits: [Int] = []
        rawBits.reserveCapacity(59)
        for i in 0...58 {
            guard let b = minuteBits[i].binaryValue else { return }
            rawBits.append(b)
        }

        guard let decoded = Self.parseFrame(rawBits, referenceDate: Date()) else {
            return
        }

        lastDecodedTime = decoded
        onTimeDecoded?(decoded)
    }

    /// Parst die 59 Rohbits eines vollständigen DCF77-Minuten-Telegramms
    public static func parseFrame(_ bits: [Int], referenceDate: Date = Date()) -> DecodedTime? {
        guard bits.count >= 59 else { return nil }

        // 1. Grundregeln
        // Bit 0 = immer 0 (Start of Minute)
        // Bit 20 = immer 1 (Start der Zeitinformation)
        guard bits[0] == 0, bits[20] == 1 else { return nil }

        // Zeitzone: Bit 17 (MESZ) xor Bit 18 (MEZ) muss 1 sein
        let isSummer = (bits[17] == 1)
        let isWinter = (bits[18] == 1)
        guard isSummer != isWinter else { return nil }

        // 2. Paritätsprüfungen
        // P1: Minute (Bits 21..27) + Bit 28 gerade Parität
        let p1Sum = bits[21...28].reduce(0, +)
        guard p1Sum % 2 == 0 else { return nil }

        // P2: Stunde (Bits 29..34) + Bit 35 gerade Parität
        let p2Sum = bits[29...35].reduce(0, +)
        guard p2Sum % 2 == 0 else { return nil }

        // P3: Datum (Bits 36..57) + Bit 58 gerade Parität
        let p3Sum = bits[36...58].reduce(0, +)
        guard p3Sum % 2 == 0 else { return nil }

        // 3. BCD-Werte berechnen
        let minute = bcd(Array(bits[21...27]), weights: [1, 2, 4, 8, 10, 20, 40])
        let hour   = bcd(Array(bits[29...34]), weights: [1, 2, 4, 8, 10, 20])
        let day    = bcd(Array(bits[36...41]), weights: [1, 2, 4, 8, 10, 20])
        let weekday = bcd(Array(bits[42...44]), weights: [1, 2, 4])
        let month  = bcd(Array(bits[45...49]), weights: [1, 2, 4, 8, 10])
        let year2  = bcd(Array(bits[50...57]), weights: [1, 2, 4, 8, 10, 20, 40, 80])

        // Plausibilitätsprüfungen
        guard (0...59).contains(minute) else { return nil }
        guard (0...23).contains(hour) else { return nil }
        guard (1...31).contains(day) else { return nil }
        guard (1...7).contains(weekday) else { return nil }
        guard (1...12).contains(month) else { return nil }
        guard (0...99).contains(year2) else { return nil }

        let fullYear = 2000 + year2

        // Date-Objekt bilden (in MEZ = GMT+1 bzw. MESZ = GMT+2)
        let tzOffsetSeconds = isSummer ? 7200 : 3600
        let timeZone = TimeZone(secondsFromGMT: tzOffsetSeconds) ?? .current

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        var comp = DateComponents()
        comp.year = fullYear
        comp.month = month
        comp.day = day
        comp.hour = hour
        comp.minute = minute
        comp.second = 0
        comp.timeZone = timeZone

        guard let dcfDate = cal.date(from: comp) else { return nil }

        // Plausibilitätsprüfung des Wochentags
        let weekdayNames = ["", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
        let calWeekday = cal.component(.weekday, from: dcfDate) // 1 = Sonntag, 2 = Montag ...
        let expectedDcfWeekday = (calWeekday == 1) ? 7 : (calWeekday - 1)
        guard weekday == expectedDcfWeekday else { return nil }

        let deltaMs = referenceDate.timeIntervalSince(dcfDate) * 1000.0

        return DecodedTime(
            date: dcfDate,
            year: fullYear,
            month: month,
            day: day,
            weekday: weekday,
            weekdayName: weekdayNames[weekday],
            hour: hour,
            minute: minute,
            second: 0,
            isSummerTime: isSummer,
            timeZoneName: isSummer ? "MESZ" : "MEZ",
            timeChangeAnnounced: bits[16] == 1,
            leapSecondAnnounced: bits[19] == 1,
            backupAntenna: bits[15] == 1,
            weatherBits: Array(bits[1...14]),
            deltaMilliseconds: deltaMs,
            receivedAt: referenceDate
        )
    }

    private static func bcd(_ bits: [Int], weights: [Int]) -> Int {
        var total = 0
        for i in 0..<min(bits.count, weights.count) {
            if bits[i] == 1 { total += weights[i] }
        }
        return total
    }
}
