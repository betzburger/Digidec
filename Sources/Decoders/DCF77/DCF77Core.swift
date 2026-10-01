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
        /// Parität/Bits waren gestört; die Zeit ergibt sich aus der Vorhersage der Folgeminute und passt bis auf wenige Bits
        public var confirmedByPrediction: Bool = false

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
        /// Von der Frequenznachführung gefundene Abweichung des Trägers von der eingestellten Mitte (Hz)
        public var afcOffsetHz: Double = 0
    }

    public var onTimeDecoded: ((DecodedTime) -> Void)?
    public var onBitDecoded: ((Int, BitValue) -> Void)?

    private var centerHz: Double
    /// Frequenznachführung: führt die Mischfrequenz dem Träger nach (Fangbereich ±100 Hz)
    public var afcEnabled = true
    private static let afcLimitHz = 100.0
    private var afcOffsetHz = 0.0
    // Breiter Kanal (≈ 100 Hz) nur zur Frequenzmessung: Phasendrehung des Trägers = Abweichung von der Mischfrequenz
    private let wideAlpha = 0.08
    private var wI = 0.0, wQ = 0.0
    // Frequenz aus der Phasendrehung über 16 Samples (statt über 1): Phasenrauschen wirkt 16-fach schwächer
    private static let afcLag = 16
    private var wiRing = [Double](repeating: 0, count: 16), wqRing = [Double](repeating: 0, count: 16)
    private var wPos = 0
    private var widePeak = 0.0
    private var phase: Double = 0.0
    private let phaseIncrementFactor: Double = 2.0 * .pi / sampleRate

    // 2-stufiger IIR-Tiefpass für Basisband-I/Q (ca. 15 Hz Bandbreite je Stufe)
    private let alpha: Double = 0.012
    private var iLp1: Double = 0.0
    private var iLp2: Double = 0.0
    private var qLp1: Double = 0.0
    private var qLp2: Double = 0.0

    // Rauschkanal: gleicher Mischer/Tiefpass bei centerHz + 120 Hz (dort liegt kein Träger) → Rauschpegel in ~20 Hz
    private static let noiseOffsetHz = 120.0
    private var noisePhase: Double = 0.0
    private var nI1 = 0.0, nI2 = 0.0, nQ1 = 0.0, nQ2 = 0.0
    private var noiseLevel: Double = 0.001

    // Pegelnachführung
    private var peakLevel: Double = 0.01
    private var carrierMean: Double = 0.0       // Mittelwert der Hüllkurve außerhalb der Absenkung (folgt nicht den Rauschspitzen)
    private var primedSamples: Int = 0
    private var lowRunSamples: Int = 0
    private var dipLevel: Double = 0.002
    private var lowThreshold: Double = 0.005    // Schmitt-Trigger: unter 50 % des Trägers beginnt die Absenkung
    private var highThreshold: Double = 0.006   // über 62 % endet sie

    /// Verzögerung, mit der die 50-%-Schwelle nach der echten Flanke anspricht (2 Stufen, τ = 1/α Samples)
    private static let edgeLatencySeconds = 1.6 / 0.012 / sampleRate

    // Zustandserkennung
    private var sampleIndex: Int64 = 0
    private var lastNegativeEdgeSample: Int64 = -1_000_000
    private var lastRisingEdgeSample: Int64 = -1_000_000
    private var lastMarkerSample: Int64 = -1_000_000       // Beginn der Minute (Falls-Flanke nach der Lücke)
    private var lastIgnoredGapSample: Int64 = -1_000_000
    private var isLow: Bool = false
    private var inDip: Bool = false
    private var dipSampleCount: Int = 0

    // Frame-Synchronisation (60 Sekunden)
    private var isSynchronized: Bool = false
    private var currentSecond: Int = -1
    private var minuteBits: [BitValue] = Array(repeating: .empty, count: 60)
    private var lastDecodedTime: DecodedTime?
    private var referenceFrame: DecodedTime?      // letztes sicher decodiertes Telegramm (Basis der Vorhersage)
    private var minutesSinceReference = 0

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
        afcOffsetHz = 0   // neue Bezugsfrequenz, Nachführung beginnt von vorn
    }

    public func reset() {
        phase = 0.0
        iLp1 = 0.0
        iLp2 = 0.0
        qLp1 = 0.0
        qLp2 = 0.0
        noisePhase = 0.0
        afcOffsetHz = 0.0
        wI = 0; wQ = 0; widePeak = 0
        for k in 0..<Self.afcLag { wiRing[k] = 0; wqRing[k] = 0 }
        wPos = 0
        nI1 = 0.0; nI2 = 0.0; nQ1 = 0.0; nQ2 = 0.0
        noiseLevel = 0.001
        peakLevel = 0.01
        carrierMean = 0.0
        primedSamples = 0
        lowRunSamples = 0
        dipLevel = 0.002
        lowThreshold = 0.005
        highThreshold = 0.006
        sampleIndex = 0
        lastNegativeEdgeSample = -1_000_000
        lastRisingEdgeSample = -1_000_000
        lastMarkerSample = -1_000_000
        lastIgnoredGapSample = -1_000_000
        isLow = false
        inDip = false
        dipSampleCount = 0
        isSynchronized = false
        currentSecond = -1
        minuteBits = Array(repeating: .empty, count: 60)
        referenceFrame = nil
        minutesSinceReference = 0
    }

    /// Verarbeitet einen Block von 8-kHz-Audio-Samples
    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let twoPi = 2.0 * .pi

        for sample in samples {
            let s = Double(sample)
            let lo = centerHz + afcOffsetHz
            let phaseInc = twoPi * lo / Self.sampleRate
            let noiseInc = twoPi * (lo + Self.noiseOffsetHz) / Self.sampleRate
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

            // Frequenznachführung: Phasendrehung des Trägers im breiten Kanal, nur bei vollem Träger (nicht in der Absenkung)
            wI += wideAlpha * (inI - wI)
            wQ += wideAlpha * (inQ - wQ)
            let wEnv = sqrt(wI * wI + wQ * wQ)
            if wEnv > widePeak { widePeak += 0.01 * (wEnv - widePeak) } else { widePeak -= 0.00003 * widePeak }
            let oldI = wiRing[wPos], oldQ = wqRing[wPos]    // Wert von vor 16 Samples
            if afcEnabled && wEnv > 0.85 * widePeak && widePeak > 1e-4 && primedSamples > 8_000 {
                let cross = wQ * oldI - wI * oldQ
                let dot = wI * oldI + wQ * oldQ
                let offsetHz = atan2(cross, dot) * Self.sampleRate / (twoPi * Double(Self.afcLag))
                afcOffsetHz = min(max(afcOffsetHz + 0.0004 * offsetHz, -Self.afcLimitHz), Self.afcLimitHz)
            }
            wiRing[wPos] = wI; wqRing[wPos] = wQ
            wPos = (wPos + 1) % Self.afcLag

            // Rauschkanal
            let nCos = cos(noisePhase), nSin = sin(noisePhase)
            noisePhase += noiseInc
            if noisePhase >= twoPi { noisePhase -= twoPi }
            nI1 += alpha * (s * nCos - nI1); nI2 += alpha * (nI1 - nI2)
            nQ1 += alpha * (-s * nSin - nQ1); nQ2 += alpha * (nQ1 - nQ2)
            let nEnv = sqrt(nI2 * nI2 + nQ2 * nQ2)
            noiseLevel += 0.0005 * (nEnv - noiseLevel)

            // Pegelnachführung (schnelle Annäherung nach oben, langsamer Abfall)
            if env > peakLevel {
                peakLevel += 0.01 * (env - peakLevel)
            } else {
                peakLevel -= 0.00003 * peakLevel
            }
            if peakLevel < 0.0001 { peakLevel = 0.0001 }

            // Schmitt-Trigger-Schwellen. In den ersten 2 s dient der Spitzenwert zum Einschwingen; danach der Mittelwert des
            // Trägers (Rauschspitzen würden den Spitzenwert und damit die Schwelle anheben).
            primedSamples = min(primedSamples + 1, 1_000_000)
            let reference = primedSamples > 16_000 && carrierMean > 0 ? carrierMean : peakLevel
            lowThreshold = reference * 0.50
            highThreshold = reference * 0.62
            if !isLow {
                carrierMean += (primedSamples < 16_000 ? 0.01 : 0.001) * (env - carrierMean)
                lowRunSamples = 0
            } else {
                lowRunSamples += 1
                // Länger als jede gültige Absenkung (max. 200 ms): Referenz stimmt nicht mehr, neu einschwingen
                if lowRunSamples > 3200 { carrierMean = peakLevel; primedSamples = 0; lowRunSamples = 0 }
            }

            // Scope-Puffer befüllen (100 Hz Dezimierung = alle 80 Samples)
            scopeDecimator += 1
            if scopeDecimator >= 80 {
                scopeDecimator = 0
                let normalized = Float(min(1.0, max(0.0, env / (peakLevel * 1.2))))
                scopeBuffer[scopeWriteIndex] = normalized
                scopeWriteIndex = (scopeWriteIndex + 1) % scopeSize
            }

            // Slicing mit Hysterese
            let sampleLow = isLow ? (env < highThreshold) : (env < lowThreshold)

            if !isLow && sampleLow {
                // FALLENDE FLANKE: Neuer Sekundenimpuls beginnt
                let deltaSamples = sampleIndex - lastNegativeEdgeSample
                let deltaSeconds = Double(deltaSamples) / Self.sampleRate

                // Zerfällt eine Absenkung durch Rauschen in zwei Teile, ist das keine neue Sekunde:
                // zusammenfügen (die Lücke zählt zur Impulsdauer).
                if deltaSeconds < 0.5 && lastRisingEdgeSample >= 0 {
                    isLow = true
                    inDip = true
                    dipSampleCount += Int(sampleIndex - lastRisingEdgeSample)
                    sampleIndex += 1
                    continue
                }

                isLow = true
                inDip = true
                dipSampleCount = 0
                lastNegativeEdgeSample = sampleIndex

                // Lücke von ≈ 2 s: Minutenmarke (Sekunde 59 ohne Impuls) – oder ein einzelner verpasster Impuls mitten in der
                // Minute. Als Marke gilt sie, wenn wir noch nicht synchron sind, die Sekundenzählung bei 55…59 steht oder
                // sie genau eine Minute nach der letzten Marke bzw. der letzten ignorierten Lücke kommt.
                let isGap = deltaSeconds >= 1.7 && deltaSeconds <= 2.3
                let minute = Double(60) * Self.sampleRate
                func nearMinute(_ since: Int64) -> Bool { abs(Double(sampleIndex - since) - minute) < 1.5 * Self.sampleRate }
                if isGap && (!isSynchronized || currentSecond >= 55 || nearMinute(lastMarkerSample) || nearMinute(lastIgnoredGapSample)) {
                    // Die vorangehende Lücke war Sekunde 59!
                    if isSynchronized {
                        minuteBits[59] = .minuteMarker
                        decodeFrame()
                    }
                    isSynchronized = true
                    currentSecond = 0
                    lastMarkerSample = sampleIndex
                    minuteBits = Array(repeating: .empty, count: 60)
                } else if isSynchronized {
                    if isGap { lastIgnoredGapSample = sampleIndex }
                    if deltaSeconds >= 0.8 && deltaSeconds <= 1.2 {
                        currentSecond = (currentSecond + 1) % 60
                    } else {
                        // Bei verpassten Impulsen anhand der Zeit weiterspringen
                        currentSecond = (currentSecond + max(1, Int(deltaSeconds.rounded()))) % 60
                    }
                }
            } else if isLow && !sampleLow {
                // STEIGENDE FLANKE: Absenkung beendet
                isLow = false
                inDip = false
                lastRisingEdgeSample = sampleIndex

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
                // Restträger während der Absenkung: gleitender Mittelwert, erst nach dem Einschwingen (30 ms)
                if dipSampleCount > 240 {
                    dipLevel += 0.01 * (env - dipLevel)
                }
            }

            // Träger weg (länger als 5 s keine Flanke): Synchronisation verwerfen, Minutenbits sind nicht mehr zuzuordnen
            if isSynchronized && sampleIndex - lastNegativeEdgeSample > Int64(5.0 * Self.sampleRate) {
                isSynchronized = false
                currentSecond = -1
                minuteBits = Array(repeating: .empty, count: 60)
            }

            sampleIndex += 1
        }
    }

    /// Statusabfrage für UI
    public func getStatus() -> Status {
        // Träger gegen Rauschen in ~20 Hz Bandbreite (Rauschkanal bei centerHz + 120 Hz)
        let snr = min(60.0, max(0.0, 20.0 * log10(peakLevel / max(noiseLevel, 1e-6))))
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
            scope: orderedScope,
            afcOffsetHz: afcOffsetHz
        )
    }

    // MARK: - Frame-Decodierung & Plausibilität

    private func decodeFrame() {
        if referenceFrame != nil { minutesSinceReference += 1 }
        let received: [Int?] = (0...58).map { minuteBits[$0].binaryValue }

        // 1. Alle 59 Bits gültig und Paritäten stimmen
        if !received.contains(where: { $0 == nil }),
           let decoded = Self.parseFrame(received.map { $0! }, referenceDate: Date(), latencyMs: Self.edgeLatencySeconds * 1000.0) {
            accept(decoded)
            return
        }

        // 2. Gestörtes Telegramm: gegen die Vorhersage prüfen (Bits 17, 18 und 20…58 enthalten Zeitzone, Minute, Stunde, Datum)
        guard let ref = referenceFrame, minutesSinceReference <= 15 else { return }
        let predictedDate = ref.date.addingTimeInterval(Double(minutesSinceReference) * 60.0)
        let predicted = Self.encodeFrame(date: predictedDate, summer: ref.isSummerTime)
        var mismatches = 0, unknown = 0
        for i in [17, 18] + Array(20...58) {
            if let bit = received[i] { if bit != predicted[i] { mismatches += 1 } } else { unknown += 1 }
        }
        // Zufällig passende Bits: 39 Bits, ≤ 2 Abweichungen → Wahrscheinlichkeit < 1e-8
        guard mismatches <= 2, unknown <= 10 else { return }
        if var decoded = Self.parseFrame(predicted, referenceDate: Date(), latencyMs: Self.edgeLatencySeconds * 1000.0) {
            decoded.confirmedByPrediction = true
            accept(decoded)
        }
    }

    private func accept(_ decoded: DecodedTime) {
        referenceFrame = decoded
        minutesSinceReference = 0
        lastDecodedTime = decoded
        onTimeDecoded?(decoded)
    }

    /// Baut die 59 Bits des Telegramms für eine Minute (Bits 0…16 und 19 bleiben 0, Paritäten gerade).
    static func encodeFrame(date: Date, summer: Bool) -> [Int] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: summer ? 7200 : 3600) ?? .current
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        var bits = [Int](repeating: 0, count: 59)
        bits[17] = summer ? 1 : 0
        bits[18] = summer ? 0 : 1
        bits[20] = 1
        func put(_ value: Int, _ start: Int, _ weights: [Int]) {
            var rest = value
            for i in (0..<weights.count).reversed() where rest >= weights[i] {
                bits[start + i] = 1
                rest -= weights[i]
            }
        }
        func parity(_ r: ClosedRange<Int>) -> Int { bits[r].reduce(0, +) % 2 }
        put(c.minute ?? 0, 21, [1, 2, 4, 8, 10, 20, 40]); bits[28] = parity(21...27)
        put(c.hour ?? 0, 29, [1, 2, 4, 8, 10, 20]); bits[35] = parity(29...34)
        put(c.day ?? 1, 36, [1, 2, 4, 8, 10, 20])
        let weekday = c.weekday ?? 1
        put(weekday == 1 ? 7 : weekday - 1, 42, [1, 2, 4])
        put(c.month ?? 1, 45, [1, 2, 4, 8, 10])
        put((c.year ?? 2000) % 100, 50, [1, 2, 4, 8, 10, 20, 40, 80])
        bits[58] = parity(36...57)
        return bits
    }

    /// Parst die 59 Rohbits eines vollständigen DCF77-Minuten-Telegramms
    /// - Parameter latencyMs: Ansprechverzögerung der Flankenerkennung, wird vom Zeitunterschied abgezogen.
    public static func parseFrame(_ bits: [Int], referenceDate: Date = Date(), latencyMs: Double = 0) -> DecodedTime? {
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

        // BCD: jede Dezimalstelle muss ≤ 9 sein (Einerstelle Bits 1,2,4,8; Zehner folgen)
        func validBCD(_ range: ClosedRange<Int>, ones: Int) -> Bool {
            let low = bits[range.lowerBound..<(range.lowerBound + ones)].enumerated().reduce(0) { $0 + $1.element * (1 << $1.offset) }
            return low <= 9
        }
        guard validBCD(21...27, ones: 4), validBCD(29...34, ones: 4),
              validBCD(36...41, ones: 4), validBCD(45...49, ones: 4), validBCD(50...57, ones: 4) else { return nil }
        // Jahr: Zehnerstelle ebenfalls ≤ 9
        guard bits[54] + 2 * bits[55] + 4 * bits[56] + 8 * bits[57] <= 9 else { return nil }

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

        // Ungültiges Datum (z. B. 31. April) würde von Calendar still weitergerollt: Rückprüfung
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute], from: dcfDate)
        guard back.year == fullYear, back.month == month, back.day == day, back.hour == hour, back.minute == minute else { return nil }

        // Plausibilitätsprüfung des Wochentags
        let weekdayNames = ["", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
        let calWeekday = cal.component(.weekday, from: dcfDate) // 1 = Sonntag, 2 = Montag ...
        let expectedDcfWeekday = (calWeekday == 1) ? 7 : (calWeekday - 1)
        guard weekday == expectedDcfWeekday else { return nil }

        // Der Decoder löst am Beginn der Folgeminute aus; die 50-%-Schwelle spricht ca. 10 ms nach der Flanke an.
        let deltaMs = referenceDate.timeIntervalSince(dcfDate) * 1000.0 - latencyMs

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
