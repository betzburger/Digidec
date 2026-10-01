import Foundation

/// Kern des EFR-Decoders (Europäische Funk-Rundsteuerung auf Langwelle: 129,1 kHz DCF49 / 139,0 kHz DCF39).
/// Demoduliert 200 Baud FSK (Hub ±170 Hz / Shift 340 Hz, Zeichenrahmen 8E1) und decodiert
/// DIN 19244 / FT1.2-Telegramme (Versacom, Semagyr, Zeittelegramme, EEG-Abregelung).
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
        public var address: Int?
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
    private var markHz: Double { centerHz + shiftHz / 2.0 }
    private var spaceHz: Double { centerHz - shiftHz / 2.0 }

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
    private var uartState: UartState = .idle
    private var samplesSinceLastBit: Int = 0

    // Telegramm-Assembler (DIN 19244)
    private var rxBuffer: [UInt8] = []
    private let maxBufferCapacity = 512

    // Statistik
    private var bytesReceivedCount: Int = 0
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
        clockPhase = 0.0
        lastDiscriminator = 0.0
        uartState = .idle
        samplesSinceLastBit = 0
        rxBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Audio-Verarbeitung (8 kHz)

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let twoPi = 2.0 * Double.pi
        let markInc = twoPi * markHz / Self.sampleRate
        let spaceInc = twoPi * spaceHz / Self.sampleRate

        for sample in samples {
            let s = Double(sample)

            // 1. Mark-Mischer (1670 Hz)
            let mCos = cos(markPhase)
            let mSin = sin(markPhase)
            markPhase += markInc
            if markPhase >= twoPi { markPhase -= twoPi }

            markI += alpha * (s * mCos - markI)
            markQ += alpha * (-s * mSin - markQ)
            let mEnv = sqrt(markI * markI + markQ * markQ)

            // 2. Space-Mischer (1330 Hz)
            let sCos = cos(spacePhase)
            let sSin = sin(spacePhase)
            spacePhase += spaceInc
            if spacePhase >= twoPi { spacePhase -= twoPi }

            spaceI += alpha * (s * sCos - spaceI)
            spaceQ += alpha * (-s * sSin - spaceQ)
            let sEnv = sqrt(spaceI * spaceI + spaceQ * spaceQ)

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
            if prevPhase < 0.5 && clockPhase >= 0.5 {
                let sampledBit = (discr > 0.0) // true = Mark (1), false = Space (0)
                handleBitSample(sampledBit)
            }
        }
    }

    // MARK: - UART 8E1 Dekodierung

    private func handleBitSample(_ bit: Bool) {
        samplesSinceLastBit = 0

        switch uartState {
        case .idle:
            // Warten auf Start-Bit (Space = false = 0)
            if !bit {
                uartState = .data(bitIndex: 0, currentByte: 0, onesCount: 0)
            }

        case .data(let idx, let byteVal, let ones):
            let newOnes = ones + (bit ? 1 : 0)
            let newByte = byteVal | (bit ? (1 << idx) : 0)
            if idx == 7 {
                uartState = .parity(currentByte: newByte, onesCount: newOnes)
            } else {
                uartState = .data(bitIndex: idx + 1, currentByte: newByte, onesCount: newOnes)
            }

        case .parity(let byteVal, let ones):
            // Gerade Parität (Even Parity): Gesamtzahl der Einsen (Daten + Parität) muss gerade sein
            let parityBit = bit ? 1 : 0
            let parityValid = ((ones + parityBit) % 2 == 0)
            if parityValid {
                uartState = .stop(currentByte: byteVal)
            } else {
                // Paritätsfehler: Byte verwerfen
                uartState = .idle
            }

        case .stop(let byteVal):
            // Stopp-Bit muss Mark (1 = true) sein
            if bit {
                consumeByte(byteVal)
            }
            uartState = .idle
        }
    }

    private func consumeByte(_ byte: UInt8) {
        bytesReceivedCount += 1
        onByteReceived?(byte)

        rxBuffer.append(byte)
        if rxBuffer.count > maxBufferCapacity {
            rxBuffer.removeFirst(rxBuffer.count - maxBufferCapacity)
        }

        checkAndParseFrames()
    }

    // MARK: - DIN 19244 Frame-Parser

    private func checkAndParseFrames() {
        while rxBuffer.count >= 5 {
            // Nach Startzeichen suchen
            guard let startIndex = rxBuffer.firstIndex(where: { $0 == 0x68 || $0 == 0x10 }) else {
                rxBuffer.removeAll(keepingCapacity: true)
                return
            }

            if startIndex > 0 {
                rxBuffer.removeFirst(startIndex)
            }

            guard let firstByte = rxBuffer.first else { return }

            if firstByte == 0x68 {
                // Variables Telegramm:
                // [0] 0x68, [1] L, [2] L, [3] 0x68, [4..4+L-1] Daten, [4+L] Checksumme, [5+L] 0x16
                guard rxBuffer.count >= 4 else { return }
                let l1 = Int(rxBuffer[1])
                let l2 = Int(rxBuffer[2])

                if l1 != l2 || rxBuffer[3] != 0x68 {
                    // Ungültiger Kopf: erstes Byte verwerfen und weitersuchen
                    rxBuffer.removeFirst()
                    continue
                }

                let totalLength = l1 + 6
                if rxBuffer.count < totalLength {
                    // Noch nicht vollständig empfangen
                    return
                }

                // Prüfen ob Stop-Byte 0x16 ist
                if rxBuffer[totalLength - 1] != 0x16 {
                    rxBuffer.removeFirst()
                    continue
                }

                // Prüfsumme prüfen (Summe der L Bytes modulo 256)
                let userBytes = Array(rxBuffer[4..<(4 + l1)])
                let calculatedCS = userBytes.reduce(0) { ($0 + Int($1)) & 0xFF }
                let receivedCS = Int(rxBuffer[4 + l1])

                if calculatedCS == receivedCS {
                    let frameBytes = Array(rxBuffer[0..<totalLength])
                    rxBuffer.removeFirst(totalLength)
                    parseVariableFrame(frameBytes: frameBytes, userBytes: userBytes)
                } else {
                    rxBuffer.removeFirst()
                }

            } else if firstByte == 0x10 {
                // Telegramm mit fester Länge:
                // [0] 0x10, [1] C, [2] A, [3] CS, [4] 0x16
                guard rxBuffer.count >= 5 else { return }

                if rxBuffer[4] != 0x16 {
                    rxBuffer.removeFirst()
                    continue
                }

                let c = rxBuffer[1]
                let a = rxBuffer[2]
                let calculatedCS = (Int(c) + Int(a)) & 0xFF
                let receivedCS = Int(rxBuffer[3])

                if calculatedCS == receivedCS {
                    let frameBytes = Array(rxBuffer[0..<5])
                    rxBuffer.removeFirst(5)
                    parseFixedFrame(frameBytes: frameBytes, control: c, address: a)
                } else {
                    rxBuffer.removeFirst()
                }
            }
        }
    }

    private func parseVariableFrame(frameBytes: [UInt8], userBytes: [UInt8]) {
        guard userBytes.count >= 2 else { return }
        let control = userBytes[0]
        let address = Int(userBytes[1])
        let asdu = Array(userBytes[2...])

        var title = "EFR-Schaltbefehl"
        var summary = ""
        var isTime = false
        var decodedDate: Date?
        var deltaMs: Double?

        // Prüfung auf Uhrzeittelegramm
        // EFR Zeit-Telegramme enthalten typischerweise Zeitinformationen (Sekunden, Minuten, Stunden, Tag, Monat, Jahr)
        if let time = parseEFRTime(asdu) {
            isTime = true
            decodedDate = time
            let now = Date()
            deltaMs = now.timeIntervalSince(time) * 1000.0

            let fmt = DateFormatter()
            fmt.dateFormat = "dd.MM.yyyy HH:mm:ss"
            title = "EFR Zeit- & Datumssynchronisation"
            summary = "Zeit: \(fmt.string(from: time)) (Δt: \(String(format: "%+.1f", deltaMs ?? 0)) ms)"
        } else {
            // Versacom / Semagyr Schalttelegramm
            let hexASDU = asdu.map { String(format: "%02X", $0) }.joined(separator: " ")
            if asdu.count >= 2 {
                title = "EFR Rundsteuertelegramm (Adr: \(address))"
                summary = "Kommando-Bytes: [\(hexASDU)]"

                // Erkennung von EEG-Abregelung oder Standard-Relais
                if asdu.contains(0x64) {
                    summary += " · Leistungsstufe 100 % (Freigabe)"
                } else if asdu.contains(0x3C) {
                    summary += " · Leistungsstufe 60 %"
                } else if asdu.contains(0x1E) {
                    summary += " · Leistungsstufe 30 %"
                } else if asdu.contains(0x00) && asdu.count > 3 {
                    summary += " · Abregelung 0 % (Abschaltung)"
                }
            } else {
                title = "EFR Daten-Telegramm (Adr: \(address))"
                summary = "Nutzdaten: [\(hexASDU)]"
            }
        }

        let telegram = DecodedTelegram(
            timestamp: Date(),
            frameType: .variable,
            rawBytes: frameBytes,
            controlByte: control,
            address: address,
            asduType: asdu.first,
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
            address: Int(address),
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

    /// Parst EFR Zeitstempel im ASDU (DIN EN 60870-5 CP56Time2a oder Versacom-Format)
    public static func parseEFRTime(_ bytes: [UInt8]) -> Date? {
        // CP56Time2a benötigt 7 Bytes:
        // [0..1] Millisekunden (0..59999, Little Endian)
        // [2] Minuten (0..59, Bit 7 = Invalid Flag)
        // [3] Stunden (0..23, Bit 7 = Summer Time Flag)
        // [4] Tag (1..31, Bits 0..4) + Wochentag (Bits 5..7)
        // [5] Monat (1..12, Bits 0..3)
        // [6] Jahr (0..99, Bits 0..6)
        guard bytes.count >= 7 else { return nil }

        // Starten bei Offset 0 oder 1 falls Typbyte vorangestellt ist
        for offset in 0...(bytes.count - 7) {
            let b = Array(bytes[offset..<(offset + 7)])

            let ms = Int(b[0]) | (Int(b[1]) << 8)
            let sec = ms / 1000
            let min = Int(b[2] & 0x3F)
            let hour = Int(b[3] & 0x1F)
            let isSummer = (b[3] & 0x80) != 0
            let day = Int(b[4] & 0x1F)
            let month = Int(b[5] & 0x0F)
            let year2 = Int(b[6] & 0x7F)

            guard (0...59).contains(sec),
                  (0...59).contains(min),
                  (0...23).contains(hour),
                  (1...31).contains(day),
                  (1...12).contains(month),
                  (0...99).contains(year2) else {
                continue
            }

            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: isSummer ? 7200 : 3600) ?? .current

            var comp = DateComponents()
            comp.year = 2000 + year2
            comp.month = month
            comp.day = day
            comp.hour = hour
            comp.minute = min
            comp.second = sec
            comp.timeZone = cal.timeZone

            if let date = cal.date(from: comp) {
                return date
            }
        }

        return nil
    }

    private func parseEFRTime(_ bytes: [UInt8]) -> Date? {
        Self.parseEFRTime(bytes)
    }

    // MARK: - Status für UI

    public func getStatus() -> Status {
        let snr = spacePeak > 0.0001 ? 20.0 * log10(max(1.0, markPeak / spacePeak)) : 0.0
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
            bytesReceived: bytesReceivedCount,
            telegramsDecoded: telegramsDecodedCount,
            lastTelegram: lastDecodedTelegram,
            scope: orderedScope
        )
    }
}
