import Foundation

/// Kern des EFR-Decoders (Europäische Funk-Rundsteuerung auf Langwelle: 129,1 kHz DCF49 / 139,0 kHz DCF39).
/// Demoduliert 200 Baud FSK (Hub ±170 Hz / Shift 340 Hz, Zeichenrahmen 8E1) und decodiert
/// DIN 19244 / FT1.2-Telegramme. Rahmen und Prüfsummen werden geprüft; Nutzdaten (Versacom, Semagyr u. a.) sind
/// herstellerspezifisch und werden als Hex ausgegeben, nicht gedeutet. Das Zeittelegramm (A1 = A2 = 0) ist dokumentiert
/// und wird ausgewertet (Format nach dcf39_decoder von mryndzionek, MIT, an echten Aufnahmen bestätigt).
public final class EFRCore: @unchecked Sendable {
    public static let sampleRate: Double = 8000.0
    public static let baudRate: Double = 200.0
    public static let defaultShift: Double = 340.0

    // MARK: - Datenstrukturen

    public enum FrameType: String, Equatable, Sendable {
        case variable = "DIN 19244 (0x68)"
        case fixed = "DIN 19244 (0x10)"
        case raw = "Unformatiert"
    }

    public struct DecodedTelegram: Equatable, Sendable, Identifiable {
        public let id = UUID()
        public var timestamp: Date
        public var frameType: FrameType
        public var rawBytes: [UInt8]
        public var controlByte: UInt8?
        /// Telegrammnummer (oberes Nibble des Steuerbytes)
        public var telegramNumber: Int?
        /// Adressfeld A1
        public var address: Int?
        /// Adressfeld A2
        public var address2: Int?
        public var asduType: UInt8?
        public var title: String
        public var summary: String
        public var isTimeSync: Bool
        public var decodedTime: Date?
        public var deltaMilliseconds: Double?

        public var rawHex: String {
            rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        public var formattedTime: String {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            return fmt.string(from: timestamp)
        }
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var markHz: Double
        public var spaceHz: Double
        public var signalLevel: Double        // 0..100 %
        public var markLevel: Double
        public var spaceLevel: Double
        public var snrDb: Double
        public var bytesReceived: Int
        public var telegramsDecoded: Int
        public var lastTelegram: DecodedTelegram?
        public var scope: [Float]             // Diskriminator-Kurve für Oszilloskop (letzte ~100 ms)
    }

    // Callbacks
    public var onTelegramDecoded: ((DecodedTelegram) -> Void)?
    public var onByteReceived: ((UInt8) -> Void)?

    // MARK: - Interne DSP-Zustände

    private var centerHz: Double
    private var shiftHz: Double = defaultShift
    // Mark liegt bei der unteren, Space bei der oberen Frequenz (DCF39: Mark 138,830 kHz, Space 139,170 kHz; DK8KW).
    // In USB (Dial unter der Sendefrequenz) ist Mark also der tiefere NF-Ton.
    private var markHz: Double { centerHz - shiftHz / 2.0 }
    private var spaceHz: Double { centerHz + shiftHz / 2.0 }

    // Oszillatoren
    private var markPhase: Double = 0.0
    private var spacePhase: Double = 0.0

    // I/Q-Tiefpässe (ca. 160 Hz Grenzfrequenz für 200 Baud)
    private let alpha: Double = 0.12
    private var markI: Double = 0.0
    private var markQ: Double = 0.0
    private var spaceI: Double = 0.0
    private var spaceQ: Double = 0.0

    // Pegelnachführung
    private var markPeak: Double = 0.01
    private var spacePeak: Double = 0.01

    // Rauschkanal: gleicher Mischer/Tiefpass abseits der beiden Töne (700 Hz über Space, sonst unter Mark)
    private var noisePhase: Double = 0.0
    private var noiseI1 = 0.0, noiseI2 = 0.0, noiseQ1 = 0.0, noiseQ2 = 0.0   // 2 Stufen: Leckage der Töne < −25 dB
    private var noiseLevel: Double = 0.001
    private var signalLevel: Double = 0.0      // Pegel des jeweils aktiven Tons (schneller Anstieg, langsamer Abfall)
    /// Träger liegt mindestens 6 dB über dem Rauschen – nur dann werden Bits in Bytes umgesetzt (kein Zufallsmüll im Rauschen)
    private var carrierPresent = false

    // Bit-Takterfassung (DPLL 200 Hz)
    private var clockPhase: Double = 0.0
    private let clockPhaseIncrement: Double = baudRate / sampleRate  // 200 / 8000 = 0.025
    private var lastDiscriminator: Double = 0.0

    // UART 8E1 Zustandsautomat
    private enum UartState {
        case idle
        case data(bitIndex: Int, currentByte: UInt8, onesCount: Int)
        case parity(currentByte: UInt8, onesCount: Int)
        case stop(currentByte: UInt8)
    }

    /// Zwei Empfangszweige laufen parallel: normale und invertierte Bitpolarität. Telegramme mit Startzeichen, doppelter
    /// Länge, Prüfsumme und Stoppzeichen sind so eindeutig, dass nur der richtige Zweig sie liefert. Das fängt falsche
    /// Seitenbandwahl (LSB statt USB) und vertauschte Mark/Space-Zuordnung ab.
    private struct Branch {
        var uart: UartState = .idle
        var rx: [UInt8] = []
        var bytes = 0
        var frames = 0
        let inverted: Bool
    }
    private var branches = [Branch(inverted: false), Branch(inverted: true)]
    private let maxBufferCapacity = 512
    /// Polarität des Zweigs mit den meisten gültigen Telegrammen (nil = noch keines)
    public var polarityInverted: Bool? {
        let (n, i) = (branches[0].frames, branches[1].frames)
        return n == 0 && i == 0 ? nil : i > n
    }

    // Statistik
    private var telegramsDecodedCount: Int = 0
    private var lastDecodedTelegram: DecodedTelegram?

    // Oszilloskop-Puffer (120 Punkte = ~120 ms)
    private var scopeDecimator: Int = 0
    private let scopeSize = 120
    private var scopeBuffer: [Float] = Array(repeating: 0.0, count: 120)
    private var scopeWriteIndex: Int = 0

    // MARK: - Initialisierung & Steuerung

    public init(centerHz: Double = 1500.0, shiftHz: Double = defaultShift) {
        self.centerHz = centerHz
        self.shiftHz = shiftHz
    }

    public func setCenter(_ hz: Double) {
        centerHz = hz
    }

    public func setShift(_ hz: Double) {
        shiftHz = hz
    }

    public func reset() {
        markPhase = 0.0
        spacePhase = 0.0
        markI = 0.0
        markQ = 0.0
        spaceI = 0.0
        spaceQ = 0.0
        markPeak = 0.01
        spacePeak = 0.01
        noisePhase = 0.0
        noiseI1 = 0.0; noiseI2 = 0.0; noiseQ1 = 0.0; noiseQ2 = 0.0
        noiseLevel = 0.001
        signalLevel = 0.0
        carrierPresent = false
        clockPhase = 0.0
        lastDiscriminator = 0.0
        branches = [Branch(inverted: false), Branch(inverted: true)]
    }

    // MARK: - Audio-Verarbeitung (8 kHz)

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let twoPi = 2.0 * Double.pi
        let markInc = twoPi * markHz / Self.sampleRate
        let spaceInc = twoPi * spaceHz / Self.sampleRate
        let noiseHz = (spaceHz + 700.0 < 3800.0) ? spaceHz + 700.0 : max(150.0, markHz - 700.0)
        let noiseInc = twoPi * noiseHz / Self.sampleRate

        for sample in samples {
            let s = Double(sample)

            // 1. Mark-Mischer (untere Frequenz)
            let mCos = cos(markPhase)
            let mSin = sin(markPhase)
            markPhase += markInc
            if markPhase >= twoPi { markPhase -= twoPi }

            markI += alpha * (s * mCos - markI)
            markQ += alpha * (-s * mSin - markQ)
            let mEnv = sqrt(markI * markI + markQ * markQ)

            // 2. Space-Mischer (obere Frequenz)
            let sCos = cos(spacePhase)
            let sSin = sin(spacePhase)
            spacePhase += spaceInc
            if spacePhase >= twoPi { spacePhase -= twoPi }

            spaceI += alpha * (s * sCos - spaceI)
            spaceQ += alpha * (-s * sSin - spaceQ)
            let sEnv = sqrt(spaceI * spaceI + spaceQ * spaceQ)

            // Rauschkanal und Trägererkennung
            let nCos = cos(noisePhase), nSin = sin(noisePhase)
            noisePhase += noiseInc
            if noisePhase >= twoPi { noisePhase -= twoPi }
            noiseI1 += alpha * (s * nCos - noiseI1); noiseI2 += alpha * (noiseI1 - noiseI2)
            noiseQ1 += alpha * (-s * nSin - noiseQ1); noiseQ2 += alpha * (noiseQ1 - noiseQ2)
            // Zwei Stufen haben eine um √2 kleinere Rauschbandbreite als die einstufigen Tonfilter → ausgleichen
            noiseLevel += 0.0005 * (1.41 * sqrt(noiseI2 * noiseI2 + noiseQ2 * noiseQ2) - noiseLevel)
            let activeEnv = max(mEnv, sEnv)
            signalLevel += (activeEnv > signalLevel ? 0.01 : 0.002) * (activeEnv - signalLevel)
            carrierPresent = signalLevel > 2.5 * max(noiseLevel, 1e-5)
            if !carrierPresent { for k in 0..<2 { branches[k].uart = .idle } }

            // Pegelnachführung
            if mEnv > markPeak { markPeak += 0.005 * (mEnv - markPeak) } else { markPeak -= 0.0001 * markPeak }
            if sEnv > spacePeak { spacePeak += 0.005 * (sEnv - spacePeak) } else { spacePeak -= 0.0001 * spacePeak }
            if markPeak < 0.0001 { markPeak = 0.0001 }
            if spacePeak < 0.0001 { spacePeak = 0.0001 }

            // 3. Diskriminator (Mark = +1, Space = -1)
            let discr = mEnv - sEnv

            // Scope-Puffer aktualisieren (Dezimierung alle 8 Samples = 1 kHz Abtastung)
            scopeDecimator += 1
            if scopeDecimator >= 8 {
                scopeDecimator = 0
                let norm = Float(min(1.0, max(-1.0, discr / max(0.001, (markPeak + spacePeak) * 0.5))))
                scopeBuffer[scopeWriteIndex] = norm
                scopeWriteIndex = (scopeWriteIndex + 1) % scopeSize
            }

            // 4. Nulldurchgangs-Erkennung zur DPLL-Phasenkorrektur
            if (lastDiscriminator <= 0.0 && discr > 0.0) || (lastDiscriminator >= 0.0 && discr < 0.0) {
                // Phasenfehler zur nächsten Bitgrenze (0.0 oder 1.0)
                if clockPhase > 0.5 {
                    clockPhase += 0.15 * (1.0 - clockPhase)
                } else {
                    clockPhase -= 0.15 * clockPhase
                }
            }
            lastDiscriminator = discr

            // 5. Bit-Takt weiterschalten
            let prevPhase = clockPhase
            clockPhase += clockPhaseIncrement
            if clockPhase >= 1.0 {
                clockPhase -= 1.0
            }

            // Bei Phasenübertritt durch die Bitmitte (0.5) abtasten
            if prevPhase < 0.5 && clockPhase >= 0.5 && carrierPresent {
                let sampledBit = (discr > 0.0) // true = Mark (1), false = Space (0)
                handleBitSample(sampledBit, branch: 0)
                handleBitSample(!sampledBit, branch: 1)
            }
        }
    }

    // MARK: - UART 8E1 Dekodierung

    private func handleBitSample(_ bit: Bool, branch k: Int) {
        switch branches[k].uart {
        case .idle:
            // Warten auf Start-Bit (Space = false = 0)
            if !bit { branches[k].uart = .data(bitIndex: 0, currentByte: 0, onesCount: 0) }

        case .data(let idx, let byteVal, let ones):
            let newOnes = ones + (bit ? 1 : 0)
            let newByte = byteVal | (bit ? (1 << idx) : 0)
            branches[k].uart = idx == 7
                ? .parity(currentByte: newByte, onesCount: newOnes)
                : .data(bitIndex: idx + 1, currentByte: newByte, onesCount: newOnes)

        case .parity(let byteVal, let ones):
            // Gerade Parität: Gesamtzahl der Einsen (Daten + Parität) muss gerade sein
            branches[k].uart = ((ones + (bit ? 1 : 0)) % 2 == 0) ? .stop(currentByte: byteVal) : .idle

        case .stop(let byteVal):
            // Stopp-Bit muss Mark (1 = true) sein
            branches[k].uart = .idle
            if bit { consumeByte(byteVal, branch: k) }
        }
    }

    private func consumeByte(_ byte: UInt8, branch k: Int) {
        branches[k].bytes += 1
        branches[k].rx.append(byte)
        if branches[k].rx.count > maxBufferCapacity {
            branches[k].rx.removeFirst(branches[k].rx.count - maxBufferCapacity)
        }
        // Rohbytes melden nur für die Polarität, die bisher die meisten gültigen Telegramme lieferte (Gleichstand: normal)
        if (polarityInverted ?? false) == branches[k].inverted { onByteReceived?(byte) }
        checkAndParseFrames(branch: k)
    }

    // MARK: - DIN 19244 Frame-Parser

    private func checkAndParseFrames(branch k: Int) {
        while branches[k].rx.count >= 5 {
            // Nach Startzeichen suchen
            guard let startIndex = branches[k].rx.firstIndex(where: { $0 == 0x68 || $0 == 0x10 }) else {
                branches[k].rx.removeAll(keepingCapacity: true)
                return
            }
            if startIndex > 0 { branches[k].rx.removeFirst(startIndex) }
            guard let firstByte = branches[k].rx.first else { return }
            let buf = branches[k].rx

            if firstByte == 0x68 {
                // Variables Telegramm: 0x68, L, L, 0x68, L Nutzbytes (Nr., A1, A2, Daten), Prüfsumme, 0x16
                guard buf.count >= 4 else { return }
                let l1 = Int(buf[1])
                if l1 != Int(buf[2]) || buf[3] != 0x68 {
                    branches[k].rx.removeFirst()
                    continue
                }
                let totalLength = l1 + 6
                if buf.count < totalLength { return }   // noch nicht vollständig
                if buf[totalLength - 1] != 0x16 {
                    branches[k].rx.removeFirst()
                    continue
                }
                let userBytes = Array(buf[4..<(4 + l1)])
                let calculatedCS = userBytes.reduce(0) { ($0 + Int($1)) & 0xFF }
                if calculatedCS == Int(buf[4 + l1]) {
                    branches[k].rx.removeFirst(totalLength)
                    branches[k].frames += 1
                    parseVariableFrame(frameBytes: Array(buf[0..<totalLength]), userBytes: userBytes)
                } else {
                    branches[k].rx.removeFirst()
                }

            } else {
                // Telegramm fester Länge: 0x10, C, A, Prüfsumme (C + A), 0x16
                guard buf.count >= 5 else { return }
                if buf[4] != 0x16 {
                    branches[k].rx.removeFirst()
                    continue
                }
                if (Int(buf[1]) + Int(buf[2])) & 0xFF == Int(buf[3]) {
                    branches[k].rx.removeFirst(5)
                    branches[k].frames += 1
                    parseFixedFrame(frameBytes: Array(buf[0..<5]), control: buf[1], address: buf[2])
                } else {
                    branches[k].rx.removeFirst()
                }
            }
        }
    }

    /// Variables Telegramm: Steuerbyte (oberes Nibble = Telegrammnummer), Adressen A1/A2, Nutzdaten.
    private func parseVariableFrame(frameBytes: [UInt8], userBytes: [UInt8]) {
        guard userBytes.count >= 3 else { return }
        let control = userBytes[0]
        let a1 = userBytes[1], a2 = userBytes[2]
        let userData = Array(userBytes[3...])
        let number = Int(control >> 4)

        var title: String
        var summary: String
        var isTime = false
        var decodedDate: Date?
        var deltaMs: Double?
        let hex = userData.map { String(format: "%02X", $0) }.joined(separator: " ")

        if a1 == 0 && a2 == 0, let time = Self.parseTimeTelegram(userData) {
            isTime = true
            decodedDate = time.date
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "de_DE")
            fmt.timeZone = time.timeZone
            fmt.dateFormat = "EEE dd.MM.yyyy HH:mm:ss"
            title = "EFR Zeittelegramm"
            summary = "\(fmt.string(from: time.date)) \(time.isSummer ? "MESZ" : "MEZ")"
            // Δt nur sinnvoll, wenn die Sendung live empfangen wird (nicht bei alten Aufnahmen)
            let delta = Date().timeIntervalSince(time.date)
            if abs(delta) < 36 * 3600 {
                deltaMs = delta * 1000.0
                summary += " (Δt: \(String(format: "%+.0f", delta * 1000.0)) ms)"
            }
        } else {
            // Rundsteuer-Nutzdaten (Versacom, Semagyr u. a. sind herstellerspezifisch codiert und hier nicht entschlüsselt)
            title = String(format: "EFR Telegramm Nr. %d (A1 %02X, A2 %02X)", number, a1, a2)
            summary = userData.isEmpty ? "ohne Nutzdaten" : "Nutzdaten: [\(hex)] – Inhalt nicht entschlüsselt"
            if userData.count >= 4, userData.allSatisfy({ (0x20...0x7E).contains($0) }) {
                summary += " · Text: " + String(decoding: userData, as: UTF8.self)   // Sendername im Testtelegramm
            }
        }

        let telegram = DecodedTelegram(
            timestamp: Date(),
            frameType: .variable,
            rawBytes: frameBytes,
            controlByte: control,
            telegramNumber: number,
            address: Int(a1),
            address2: Int(a2),
            asduType: userData.first,
            title: title,
            summary: summary,
            isTimeSync: isTime,
            decodedTime: decodedDate,
            deltaMilliseconds: deltaMs
        )

        telegramsDecodedCount += 1
        lastDecodedTelegram = telegram
        onTelegramDecoded?(telegram)
    }

    private func parseFixedFrame(frameBytes: [UInt8], control: UInt8, address: UInt8) {
        let telegram = DecodedTelegram(
            timestamp: Date(),
            frameType: .fixed,
            rawBytes: frameBytes,
            controlByte: control,
            telegramNumber: nil,
            address: Int(address),
            address2: nil,
            asduType: nil,
            title: "EFR Statusabfrage / Quittung",
            summary: String(format: "Steuerung: 0x%02X, Adresse: %d", control, address),
            isTimeSync: false,
            decodedTime: nil,
            deltaMilliseconds: nil
        )

        telegramsDecodedCount += 1
        lastDecodedTelegram = telegram
        onTelegramDecoded?(telegram)
    }

    /// Zeittelegramm (A1 = A2 = 0): 7 Nutzbytes `00, Sekunde << 2, Minute, Stunde | Sommerzeit << 7,
    /// Wochentag << 5 | Tag, Monat, Jahr`. Wochentag 0 = Sonntag. Quelle: dcf39_decoder (mryndzionek, MIT),
    /// bestätigt an Aufnahmen von DCF39 (WebSDR).
    public static func parseTimeTelegram(_ b: [UInt8]) -> (date: Date, isSummer: Bool, timeZone: TimeZone)? {
        guard b.count >= 7, b[0] == 0 else { return nil }
        let second = Int(b[1] >> 2), minute = Int(b[2])
        let hour = Int(b[3] & 0x7F), isSummer = (b[3] & 0x80) != 0
        let dow = Int(b[4] >> 5), day = Int(b[4] & 0x1F)
        let month = Int(b[5]), year = 2000 + Int(b[6])
        guard second < 60, minute < 60, hour < 24, (1...31).contains(day), (1...12).contains(month), dow < 7,
              b[6] < 100 else { return nil }

        guard let tz = TimeZone(secondsFromGMT: isSummer ? 7200 : 3600) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var comp = DateComponents()
        comp.year = year; comp.month = month; comp.day = day
        comp.hour = hour; comp.minute = minute; comp.second = second
        comp.timeZone = tz
        guard let date = cal.date(from: comp) else { return nil }
        // Calendar rollt ungültige Daten (31. April) weiter; außerdem muss der Wochentag stimmen (1 = Sonntag)
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute,
              back.second == second, back.weekday == dow + 1 else { return nil }
        return (date, isSummer, tz)
    }

    // MARK: - Status für UI

    public func getStatus() -> Status {
        // Aktiver Ton gegen Rauschen in der Kanalbandbreite (Rauschkanal abseits der Töne)
        let snr = min(60.0, max(0.0, 20.0 * log10(max(signalLevel, 1e-6) / max(noiseLevel, 1e-6))))
        let level = min(100.0, max(0.0, (markPeak + spacePeak) * 100.0))

        var orderedScope: [Float] = []
        orderedScope.reserveCapacity(scopeSize)
        for i in 0..<scopeSize {
            let idx = (scopeWriteIndex + i) % scopeSize
            orderedScope.append(scopeBuffer[idx])
        }

        return Status(
            centerHz: centerHz,
            markHz: markHz,
            spaceHz: spaceHz,
            signalLevel: level,
            markLevel: markPeak,
            spaceLevel: spacePeak,
            snrDb: snr,
            bytesReceived: branches[(polarityInverted ?? false) ? 1 : 0].bytes,
            telegramsDecoded: telegramsDecodedCount,
            lastTelegram: lastDecodedTelegram,
            scope: orderedScope
        )
    }
}
