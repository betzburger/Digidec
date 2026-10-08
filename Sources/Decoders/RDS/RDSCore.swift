// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// MARK: - RDS Grundkonstanten & Datenstrukturen nach EN 50067 / IEC 62106

public enum RDSOffset: UInt32, CaseIterable, Sendable {
    case a = 0x0FC       // Block A (PI-Code)
    case b = 0x198       // Block B (Gruppentyp, PTY, TP)
    case c = 0x168       // Block C (Version A Nutzdaten)
    case cPrime = 0x350  // Block C' (Version B, PI-Wiederholung)
    case d = 0x1B4       // Block D (PS-Name, Radiotext, CT)

    public var name: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .cPrime: return "C'"
        case .d: return "D"
        }
    }
}

public struct RDSBlock: Sendable, Equatable {
    public var data: UInt16
    public var offset: RDSOffset
    public var correctedBits: Int

    public init(data: UInt16, offset: RDSOffset, correctedBits: Int = 0) {
        self.data = data
        self.offset = offset
        self.correctedBits = correctedBits
    }
}

public struct RDSGroup: Sendable, Equatable {
    public var blockA: RDSBlock
    public var blockB: RDSBlock
    public var blockC: RDSBlock
    public var blockD: RDSBlock

    public var pi: UInt16 { blockA.data }
    public var groupType: Int { Int((blockB.data >> 12) & 0x0F) }
    public var isVersionB: Bool { ((blockB.data >> 11) & 0x01) == 1 }
    public var tp: Bool { ((blockB.data >> 10) & 0x01) == 1 }
    public var pty: Int { Int((blockB.data >> 5) & 0x1F) }

    public init(blockA: RDSBlock, blockB: RDSBlock, blockC: RDSBlock, blockD: RDSBlock) {
        self.blockA = blockA
        self.blockB = blockB
        self.blockC = blockC
        self.blockD = blockD
    }
}

// MARK: - Programmart (PTY) nach RBDS / RDS Europa (EN 50067)

public enum RDSPTY {
    public static let names: [String] = [
        "Kein Programm",
        "Nachrichten",
        "Aktuelles Zeitgeschehen",
        "Information",
        "Sport",
        "Bildung",
        "Hörspiel & Literatur",
        "Kultur & Religion",
        "Wissenschaft",
        "Unterhaltung",
        "Popmusik",
        "Rockmusik",
        "Leichte Musik",
        "Leichte Klassik",
        "Ernste Klassik",
        "Spezielle Musik",
        "Wetterbericht",
        "Wirtschaft",
        "Kinderprogramm",
        "Soziales",
        "Religion & Philosophie",
        "Anrufsendung",
        "Reise & Verkehr",
        "Freizeit & Hobby",
        "Jazzmusik",
        "Countrymusik",
        "Nationale Musik",
        "Oldies",
        "Folklore",
        "Dokumentation",
        "Alarmtest",
        "ALARM!"
    ]

    public static func name(for code: Int) -> String {
        guard code >= 0, code < names.count else { return "PTY \(code)" }
        return names[code]
    }
}

// MARK: - Ländercode aus dem PI-Code (erstes Nibble in ITU-Region 1 Europa)

public enum RDSCountry {
    public static func name(for pi: UInt16) -> String? {
        let countryNibble = (pi >> 12) & 0x0F
        switch countryNibble {
        case 0xD: return "Deutschland"
        case 0xF: return "Frankreich"
        case 0x1: return "Italien"
        case 0x2: return "Großbritannien"
        case 0x3: return "Österreich"
        case 0x4: return "Schweiz"
        case 0x5: return "Dänemark"
        case 0x6: return "Niederlande"
        case 0x7: return "Belgien"
        case 0x8: return "Schweden"
        case 0x9: return "Norwegen"
        case 0xA: return "Finnland"
        case 0xB: return "Polen"
        case 0xC: return "Tschechien"
        case 0xE: return "Spanien"
        default:  return nil
        }
    }
}

// MARK: - Syndrom-Berechnung und 1-Bit-Fehlerkorrektur

public enum RDSSyndrome {
    /// Generatorpolynom g(x) = x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1
    public static let generatorPoly: UInt32 = 0x5B9

    /// Tabelle der Syndrome für jedes der 26 Einzelbit-Fehlermuster (Bit 0 bis 25)
    public static let singleBitSyndromes: [UInt32: Int] = {
        var dict = [UInt32: Int]()
        for i in 0..<26 {
            let syn = syndrome(of: 1 << i)
            dict[syn] = i
        }
        return dict
    }()

    /// Berechnet das 10-Bit-Syndrom eines 26-Bit-Wortes modulo g(x)
    public static func syndrome(of word26: UInt32) -> UInt32 {
        var reg = word26 & 0x03FF_FFFF
        for i in (0..<16).reversed() {
            if (reg & (1 << (i + 10))) != 0 {
                reg ^= (generatorPoly << i)
            }
        }
        return reg & 0x3FF
    }

    /// Berechnet die 10 Prüfbits für 16 Datenbits (ohne Offset-Wort)
    public static func checkBits(for data16: UInt16) -> UInt32 {
        syndrome(of: UInt32(data16) << 10)
    }

    /// Erzeugt ein 26-Bit-Blockwort aus 16 Datenbits und einem Offset-Wort
    public static func encodeBlock(data: UInt16, offset: RDSOffset) -> UInt32 {
        let m = UInt32(data)
        let check = checkBits(for: data)
        return (m << 10) | (check ^ offset.rawValue)
    }

    /// Prüft und decodiert ein 26-Bit-Wort für ein erwartetes Offset-Wort.
    /// Führt bei Bedarf eine 1-Bit-Fehlerkorrektur durch.
    public static func decode(word: UInt32, expected: RDSOffset) -> (data: UInt16, corrected: Int)? {
        let syn = syndrome(of: word)
        let diff = syn ^ expected.rawValue
        if diff == 0 {
            // Fehlerfrei
            return (UInt16((word >> 10) & 0xFFFF), 0)
        }
        // 1-Bit-Fehlerprüfung
        if let bitPos = singleBitSyndromes[diff] {
            let correctedWord = word ^ (1 << bitPos)
            return (UInt16((correctedWord >> 10) & 0xFFFF), 1)
        }
        return nil
    }

    /// Prüft, ob ein 26-Bit-Wort zu einem beliebigen der Offset-Wörter passt
    public static func detectOffset(word: UInt32) -> (offset: RDSOffset, data: UInt16, corrected: Int)? {
        let syn = syndrome(of: word)
        for offset in RDSOffset.allCases {
            let diff = syn ^ offset.rawValue
            if diff == 0 {
                return (offset, UInt16((word >> 10) & 0xFFFF), 0)
            }
            if let bitPos = singleBitSyndromes[diff] {
                let correctedWord = word ^ (1 << bitPos)
                return (offset, UInt16((correctedWord >> 10) & 0xFFFF), 1)
            }
        }
        return nil
    }
}

// MARK: - RDS Stream Decoder & Framer

public final class RDSStreamDecoder: @unchecked Sendable {
    public enum SyncState: String, Sendable {
        case search = "SUCHE"
        case syncing = "SYNCHRONISIERT …"
        case synced = "SYNCHRONISIERT"
    }

    public struct Stats: Sendable {
        public var syncState: SyncState
        public var groupsReceived: Int
        public var blocksReceived: Int
        public var blockErrors: Int

        public init(syncState: SyncState, groupsReceived: Int, blocksReceived: Int, blockErrors: Int) {
            self.syncState = syncState
            self.groupsReceived = groupsReceived
            self.blocksReceived = blocksReceived
            self.blockErrors = blockErrors
        }
    }

    public private(set) var syncState: SyncState = .search
    public private(set) var groupsReceived: Int = 0
    public private(set) var blocksReceived: Int = 0
    public private(set) var blockErrors: Int = 0

    public var stats: Stats {
        lock.withLock {
            Stats(syncState: syncState, groupsReceived: groupsReceived, blocksReceived: blocksReceived, blockErrors: blockErrors)
        }
    }

    // Callback bei fertig zusammengestellter Gruppe
    public var onGroup: (@Sendable (RDSGroup) -> Void)?

    private let lock = NSLock()
    private var shiftReg: UInt32 = 0
    private var bitCountInSync: Int = 0
    private var expectedOffset: RDSOffset = .a
    private var consecutiveErrors: Int = 0
    private var syncCandidateBlock: RDSBlock?
    private var currentGroupBlocks: [RDSOffset: RDSBlock] = [:]

    public init() {}

    public func reset() {
        lock.withLock {
            resetInternal()
        }
    }

    private func resetInternal() {
        syncState = .search
        shiftReg = 0
        bitCountInSync = 0
        expectedOffset = .a
        consecutiveErrors = 0
        syncCandidateBlock = nil
        currentGroupBlocks.removeAll()
    }

    /// Verarbeitet ein einzelnes decodiertes Bit (0 oder 1)
    public func process(bit: Int) {
        lock.withLock {
            processInternal(bit: bit)
        }
    }

    private func processInternal(bit: Int) {
        shiftReg = ((shiftReg << 1) | UInt32(bit & 1)) & 0x03FF_FFFF

        switch syncState {
        case .search:
            // Bit-weise Suche nach Block A
            if let detected = RDSSyndrome.detectOffset(word: shiftReg), detected.offset == .a {
                syncCandidateBlock = RDSBlock(data: detected.data, offset: .a, correctedBits: detected.corrected)
                syncState = .syncing
                bitCountInSync = 0
                expectedOffset = .b
            }

        case .syncing:
            bitCountInSync += 1
            if bitCountInSync == 26 {
                bitCountInSync = 0
                if let decoded = RDSSyndrome.decode(word: shiftReg, expected: expectedOffset) {
                    let block = RDSBlock(data: decoded.data, offset: expectedOffset, correctedBits: decoded.corrected)
                    if expectedOffset == .b {
                        currentGroupBlocks[.a] = syncCandidateBlock
                        currentGroupBlocks[.b] = block
                        expectedOffset = .c
                    } else if expectedOffset == .c {
                        currentGroupBlocks[.c] = block
                        expectedOffset = .d
                    } else if expectedOffset == .d {
                        currentGroupBlocks[.d] = block
                        syncState = .synced
                        expectedOffset = .a
                        consecutiveErrors = 0
                        emitGroup()
                    }
                } else {
                    // Fehlgeschlagen -> Zurück zur Suche
                    resetInternal()
                }
            }

        case .synced:
            bitCountInSync += 1
            if bitCountInSync == 26 {
                bitCountInSync = 0
                // In Block C kann auch Offset C' vorkommen (Gruppe 15B)
                var decoded: (data: UInt16, corrected: Int)?
                var matchedOffset = expectedOffset

                if expectedOffset == .c {
                    decoded = RDSSyndrome.decode(word: shiftReg, expected: .c)
                    if decoded == nil {
                        decoded = RDSSyndrome.decode(word: shiftReg, expected: .cPrime)
                        if decoded != nil { matchedOffset = .cPrime }
                    }
                } else {
                    decoded = RDSSyndrome.decode(word: shiftReg, expected: expectedOffset)
                }

                if let res = decoded {
                    blocksReceived += 1
                    consecutiveErrors = 0
                    let block = RDSBlock(data: res.data, offset: matchedOffset, correctedBits: res.corrected)
                    currentGroupBlocks[matchedOffset] = block
                    advanceExpectedOffset()
                    if matchedOffset == .d { emitGroup() }
                } else {
                    blockErrors += 1
                    consecutiveErrors += 1
                    advanceExpectedOffset()
                    if consecutiveErrors >= 6 {
                        // Zu viele Fehler hintereinander -> Sync verloren
                        resetInternal()
                    }
                }
            }
        }
    }

    private func advanceExpectedOffset() {
        switch expectedOffset {
        case .a: expectedOffset = .b
        case .b: expectedOffset = .c
        case .c, .cPrime: expectedOffset = .d
        case .d: expectedOffset = .a
        }
    }

    private func emitGroup() {
        guard let a = currentGroupBlocks[.a],
              let b = currentGroupBlocks[.b],
              let c = currentGroupBlocks[.c] ?? currentGroupBlocks[.cPrime],
              let d = currentGroupBlocks[.d] else { return }
        groupsReceived += 1
        currentGroupBlocks.removeAll()
        let grp = RDSGroup(blockA: a, blockB: b, blockC: c, blockD: d)
        onGroup?(grp)
    }
}

// MARK: - RDS Demodulator (DSP: 240 kS/s Diskriminator-Audio -> RDS-Bits)

public final class RDSDemodulator: @unchecked Sendable {
    public let streamDecoder = RDSStreamDecoder()

    // Resampler von 24 kS/s auf 19 kS/s (16 Samples pro Bit bei 1187,5 Baud)
    private let resamplerI: SampleRateConverter
    private let resamplerQ: SampleRateConverter

    // Kaiser-Tiefpass für 2,4 kHz bei 240 kS/s mit 10-facher Dezimierung
    private let filterI: StreamFIR
    private let filterQ: StreamFIR

    // 57-kHz-Oszillator (57/240 = 19/80)
    private var ncoPhase80: Int = 0
    private static let cosTable80: [Float] = {
        (0..<80).map { Float(cos(2.0 * Double.pi * Double($0) / 80.0)) }
    }()
    private static let sinTable80: [Float] = {
        (0..<80).map { Float(sin(2.0 * Double.pi * Double($0) / 80.0)) }
    }()

    // Costas-Schleife zur Trägerrückgewinnung bei 19 kHz
    private var costasPhase: Float = 0
    private var costasFreq: Float = 0
    private let costasAlpha: Float = 0.05
    private let costasBeta: Float = 0.001

    // Biphase-Matched-Filter (16 Samples bei 19 kHz für Manchester-Halbimpulse)
    // Halbbit 0: +1 (8 Samples), Halbbit 1: -1 (8 Samples)
    private static let biphaseTaps: [Float] = {
        var t = [Float](repeating: 0, count: 16)
        for i in 0..<8 { t[i] = 1.0 }
        for i in 8..<16 { t[i] = -1.0 }
        return t
    }()
    private var biphaseHistory = [Float](repeating: 0, count: 16)

    // Takt- und Abtastphasen-Nachführung
    private var sampleCounter: Int = 0
    private var phaseEnergies = [Float](repeating: 0, count: 16)
    private var bestPhase: Int = 5
    private var prevSymbolDecision: Int = 0

    // Puffer für Resampling und Faltung
    private var rawMixI: [Float] = []
    private var rawMixQ: [Float] = []
    private var decI: [Float] = []
    private var decQ: [Float] = []

    private let lock = NSLock()

    public init() {
        // Tiefpass: Passband 2,4 kHz, Stopband 8 kHz bei 240 kS/s, Dämpfung 50 dB
        let taps = SDRFilterDesign.lowpass(passband: 2400.0 / 240000.0, stopband: 8000.0 / 240000.0, attenuationDB: 50.0)
        filterI = StreamFIR(taps: taps, decimation: 10)
        filterQ = StreamFIR(taps: taps, decimation: 10)
        resamplerI = SampleRateConverter(inputRate: 24000.0, outputRate: 19000.0)!
        resamplerQ = SampleRateConverter(inputRate: 24000.0, outputRate: 19000.0)!
    }

    public func reset() {
        lock.withLock {
            streamDecoder.reset()
            filterI.reset()
            filterQ.reset()
            resamplerI.reset()
            resamplerQ.reset()
            ncoPhase80 = 0
            costasPhase = 0
            costasFreq = 0
            biphaseHistory = [Float](repeating: 0, count: 16)
            sampleCounter = 0
            phaseEnergies = [Float](repeating: 0, count: 16)
            bestPhase = 5
            prevSymbolDecision = 0
        }
    }

    /// Verarbeitet einen Block von MPX-Abtastwerten bei 240 kS/s
    public func process(mpx: UnsafeBufferPointer<Float>) {
        lock.withLock {
            processInternal(mpx: mpx)
        }
    }

    private func processInternal(mpx: UnsafeBufferPointer<Float>) {
        let count = mpx.count
        guard count > 0 else { return }

        if rawMixI.count < count {
            rawMixI = [Float](repeating: 0, count: count)
            rawMixQ = [Float](repeating: 0, count: count)
        }

        // 1. Mischen von 57 kHz auf 0 Hz (komplexes Mischen)
        var phase = ncoPhase80
        let cosTab = Self.cosTable80
        let sinTab = Self.sinTable80
        for i in 0..<count {
            let s = mpx[i]
            rawMixI[i] = s * cosTab[phase]
            rawMixQ[i] = -s * sinTab[phase]
            phase = (phase + 19) % 80
        }
        ncoPhase80 = phase

        // 2. Tiefpass & Dezimierung von 240 kS/s auf 24 kS/s (Faktor 10)
        decI.removeAll(keepingCapacity: true)
        decQ.removeAll(keepingCapacity: true)
        rawMixI.withUnsafeBufferPointer { b in
            filterI.process(UnsafeBufferPointer(rebasing: b[0..<count]), into: &decI)
        }
        rawMixQ.withUnsafeBufferPointer { b in
            filterQ.process(UnsafeBufferPointer(rebasing: b[0..<count]), into: &decQ)
        }

        guard !decI.isEmpty else { return }

        // 3. Wandlung von 24 kS/s auf exakt 19 kS/s (16 Samples/Bit bei 1187,5 Baud)
        var rate19I = [Float]()
        var rate19Q = [Float]()
        decI.withUnsafeBufferPointer { b in resamplerI.process(b) { rate19I.append(contentsOf: $0) } }
        decQ.withUnsafeBufferPointer { b in resamplerQ.process(b) { rate19Q.append(contentsOf: $0) } }

        let n19 = min(rate19I.count, rate19Q.count)
        guard n19 > 0 else { return }

        // 4. Costas-Schleife, Biphase-Matched-Filter und Abtastentscheidung
        for i in 0..<n19 {
            let inI = rate19I[i]
            let inQ = rate19Q[i]

            // Trägerdrehung
            let c = cos(costasPhase)
            let s = sin(costasPhase)
            let rotI = inI * c - inQ * s
            let rotQ = inI * s + inQ * c

            // Phasenfehler für BPSK (sign(I) * Q)
            let signI: Float = rotI >= 0 ? 1.0 : -1.0
            let phaseError = signI * rotQ
            costasFreq += costasBeta * phaseError
            costasPhase += costasFreq + costasAlpha * phaseError
            if costasPhase > Float.pi { costasPhase -= 2 * Float.pi }
            else if costasPhase < -Float.pi { costasPhase += 2 * Float.pi }

            // Biphase-Matched-Filter (Schieberegister 16 Werte)
            biphaseHistory.removeFirst()
            biphaseHistory.append(rotI)

            // Korrelation mit Biphase-Impulsform
            var corr: Float = 0
            for k in 0..<16 { corr += biphaseHistory[k] * Self.biphaseTaps[k] }

            // Takt- und Energieverfolgung für die 16 Abtastphasen
            let p = sampleCounter % 16
            let absCorr = abs(corr)
            phaseEnergies[p] += (absCorr - phaseEnergies[p]) * 0.02

            // Bester Abtastzeitpunkt: Nur alle 256 Samples (16 Symbole) prüfen,
            // und nur wechseln, wenn die neue Phase spürbar besser ist (> 30%)
            if (sampleCounter & 0xFF) == 0 {
                var maxE: Float = -1
                var maxP = bestPhase
                for k in 0..<16 {
                    if phaseEnergies[k] > maxE {
                        maxE = phaseEnergies[k]
                        maxP = k
                    }
                }
                let curE = phaseEnergies[bestPhase]
                if curE <= 0 || maxE > curE * 1.3 {
                    bestPhase = maxP
                }
            }

            // Symbol-Entscheidung bei bester Phase
            if p == bestPhase {
                let symbolDecision = corr >= 0 ? 1 : 0
                // Differenzielle Decodierung: dataBit = symbol ^ prevSymbol
                let dataBit = symbolDecision ^ prevSymbolDecision
                prevSymbolDecision = symbolDecision
                streamDecoder.process(bit: dataBit)
            }

            sampleCounter &+= 1
        }
    }
}

// MARK: - RDS Prüfsignal-Generator (für Logiktests und Simulation)

public final class RDSSignalGenerator {
    public static func makeGroup0A(pi: UInt16, ps: String, tp: Bool = true, ta: Bool = false, pty: Int = 10, afMHz: [Double] = [98.0]) -> [RDSGroup] {
        var groups: [RDSGroup] = []
        let cleanPS = (ps + "        ").prefix(8)
        let psBytes = Array(cleanPS.utf8)

        // 4 Segmente für den 8-stelligen PS-Namen
        for seg in 0..<4 {
            let bA = RDSBlock(data: pi, offset: .a)
            let bB_data = UInt16((0 << 12) | (0 << 11) | ((tp ? 1 : 0) << 10) | ((pty & 0x1F) << 5) | ((ta ? 1 : 0) << 4) | (1 << 3) | (seg & 0x03))
            let bB = RDSBlock(data: bB_data, offset: .b)

            // Block C: AF
            let afCode: UInt16
            if seg < afMHz.count {
                let code = Int(((afMHz[seg] - 87.5) * 10.0).rounded())
                afCode = UInt16(min(204, max(1, code)))
            } else {
                afCode = 205 // No AF
            }
            let bC = RDSBlock(data: (afCode << 8) | 205, offset: .c)

            // Block D: 2 Zeichen des PS-Namens
            let c0 = UInt16(psBytes[seg * 2])
            let c1 = UInt16(psBytes[seg * 2 + 1])
            let bD = RDSBlock(data: (c0 << 8) | c1, offset: .d)

            groups.append(RDSGroup(blockA: bA, blockB: bB, blockC: bC, blockD: bD))
        }
        return groups
    }

    public static func makeGroup2A(pi: UInt16, text: String, tp: Bool = true, pty: Int = 10, textAB: Bool = false) -> [RDSGroup] {
        var groups: [RDSGroup] = []
        let cleanText = (text + String(repeating: " ", count: 64)).prefix(64)
        let bytes = Array(cleanText.utf8)
        let segCount = min(16, (bytes.count + 3) / 4)

        for seg in 0..<segCount {
            let bA = RDSBlock(data: pi, offset: .a)
            let bB_data = UInt16((2 << 12) | (0 << 11) | ((tp ? 1 : 0) << 10) | ((pty & 0x1F) << 5) | ((textAB ? 1 : 0) << 4) | (seg & 0x0F))
            let bB = RDSBlock(data: bB_data, offset: .b)

            let c0 = UInt16(bytes[seg * 4])
            let c1 = UInt16(bytes[seg * 4 + 1])
            let bC = RDSBlock(data: (c0 << 8) | c1, offset: .c)

            let c2 = UInt16(bytes[seg * 4 + 2])
            let c3 = UInt16(bytes[seg * 4 + 3])
            let bD = RDSBlock(data: (c2 << 8) | c3, offset: .d)

            groups.append(RDSGroup(blockA: bA, blockB: bB, blockC: bC, blockD: bD))
        }
        return groups
    }

    public static func makeGroup4A(pi: UInt16, date: Date, offsetHalfHours: Int = 2) -> RDSGroup {
        let bA = RDSBlock(data: pi, offset: .a)
        let bB_data = UInt16((4 << 12) | (0 << 11) | (1 << 10) | (10 << 5))
        let unix = date.timeIntervalSince1970
        let days = Int(floor(unix / 86400.0))
        let mjd = UInt32(days + 40587)
        let daySecs = Int(unix.truncatingRemainder(dividingBy: 86400.0))
        let hour = (daySecs / 3600) % 24
        let minute = (daySecs % 3600) / 60

        let mjdHigh = UInt16((mjd >> 15) & 0x03)
        let mjdLow = UInt16(mjd & 0x7FFF)
        let hourHigh = UInt16((hour >> 4) & 0x01)
        let hourLow = UInt16(hour & 0x0F)
        let minVal = UInt16(minute & 0x3F)
        let signBit: UInt16 = offsetHalfHours < 0 ? 1 : 0
        let absOffset = UInt16(abs(offsetHalfHours) & 0x1F)

        let bB = RDSBlock(data: bB_data | mjdHigh, offset: .b)
        let bC_data = (mjdLow << 1) | hourHigh
        let bC = RDSBlock(data: bC_data, offset: .c)
        let bD_data = (hourLow << 12) | (minVal << 6) | (signBit << 5) | absOffset
        let bD = RDSBlock(data: bD_data, offset: .d)

        return RDSGroup(blockA: bA, blockB: bB, blockC: bC, blockD: bD)
    }

    /// Erzeugt ein 240-kS/s-MPX-Signal mit 57-kHz-RDS-Unterträger aus einer Liste von Gruppen
    public static func modulate(groups: [RDSGroup], sampleRate: Double = 240000.0) -> [Float] {
        // 1. Bitstrom aus allen Blöcken mit Checkword und Offset zusammensetzen
        var rawBits: [Int] = []
        for g in groups {
            let words = [
                RDSSyndrome.encodeBlock(data: g.blockA.data, offset: g.blockA.offset),
                RDSSyndrome.encodeBlock(data: g.blockB.data, offset: g.blockB.offset),
                RDSSyndrome.encodeBlock(data: g.blockC.data, offset: g.blockC.offset),
                RDSSyndrome.encodeBlock(data: g.blockD.data, offset: g.blockD.offset)
            ]
            for w in words {
                for i in (0..<26).reversed() {
                    rawBits.append(Int((w >> i) & 1))
                }
            }
        }

        // 2. Differenzielle Codierung: d_k = bit_k ^ d_{k-1}
        var diffBits: [Int] = []
        var prev = 0
        for b in rawBits {
            prev ^= b
            diffBits.append(prev)
        }

        // 3. Manchester / Biphase Signal bei 19 kHz erzeugen (16 Samples/Bit)
        var biphase19k: [Float] = []
        for d in diffBits {
            let sign: Float = d == 1 ? 1.0 : -1.0
            for _ in 0..<8 { biphase19k.append(sign) }
            for _ in 0..<8 { biphase19k.append(-sign) }
        }

        // 4. Resampling auf 240 kS/s und Modulation auf 57 kHz
        guard let resampler = SampleRateConverter(inputRate: 19000.0, outputRate: 240000.0) else { return [] }
        var baseband240k: [Float] = []
        biphase19k.withUnsafeBufferPointer { b in resampler.process(b) { baseband240k.append(contentsOf: $0) } }

        var output = [Float](repeating: 0, count: baseband240k.count)
        let carrierFreq = 57000.0
        for i in 0..<baseband240k.count {
            let carrier = Float(cos(2.0 * Double.pi * carrierFreq * Double(i) / sampleRate))
            output[i] = baseband240k[i] * carrier * 0.1 // 10% Unterträger-Hub
        }
        return output
    }
}
