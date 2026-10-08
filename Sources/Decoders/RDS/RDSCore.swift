// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// RDS (Radio Data System) nach EN 50067 / IEC 62106: Blockstruktur, Prüfwort (CRC), Fehlerkorrektur und Blocksynchronisation.
// Der Signalweg (57-kHz-Unterträger → Bits) steht in RDSDemodulator.swift, die Auswertung der Gruppen in RDSDecoder.swift.

// MARK: - Offset-Wörter und Blöcke

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

    /// Stelle in der Gruppe: 0 = A, 1 = B, 2 = C oder C', 3 = D
    public var position: Int {
        switch self {
        case .a: return 0
        case .b: return 1
        case .c, .cPrime: return 2
        case .d: return 3
        }
    }
}

public struct RDSBlock: Sendable, Equatable {
    public var data: UInt16
    public var offset: RDSOffset
    /// Anzahl der durch die Prüfbits reparierten Bitfehler (0 = fehlerfrei)
    public var correctedBits: Int

    public init(data: UInt16, offset: RDSOffset, correctedBits: Int = 0) {
        self.data = data
        self.offset = offset
        self.correctedBits = correctedBits
    }
}

/// Eine Gruppe aus vier Blöcken. Bei schwachem Empfang fehlen einzelne Blöcke (`nil`); der Decoder wertet trotzdem aus, was gültig ist.
public struct RDSGroup: Sendable, Equatable {
    /// A, B, C (oder C'), D
    public var blocks: [RDSBlock?]

    public init(blocks: [RDSBlock?]) {
        var b = blocks
        while b.count < 4 { b.append(nil) }
        self.blocks = Array(b.prefix(4))
    }

    /// Vollständige Gruppe
    public init(blockA: RDSBlock, blockB: RDSBlock, blockC: RDSBlock, blockD: RDSBlock) {
        blocks = [blockA, blockB, blockC, blockD]
    }

    public var blockA: RDSBlock? { blocks[0] }
    public var blockB: RDSBlock? { blocks[1] }
    public var blockC: RDSBlock? { blocks[2] }
    public var blockD: RDSBlock? { blocks[3] }

    public var isComplete: Bool { blocks.allSatisfy { $0 != nil } }
    public var validBlockCount: Int { blocks.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    /// Summe der reparierten Bitfehler aller gültigen Blöcke
    public var correctedBits: Int { blocks.reduce(0) { $0 + ($1?.correctedBits ?? 0) } }

    /// PI-Code aus Block A, bei Gruppen der Version B ersatzweise aus Block C'
    public var pi: UInt16? {
        if let a = blockA { return a.data }
        if let c = blockC, c.offset == .cPrime { return c.data }
        return nil
    }

    public var groupType: Int? { blockB.map { Int(($0.data >> 12) & 0x0F) } }
    public var isVersionB: Bool { blockB.map { (($0.data >> 11) & 0x01) == 1 } ?? false }
    public var tp: Bool? { blockB.map { (($0.data >> 10) & 0x01) == 1 } }
    public var pty: Int? { blockB.map { Int(($0.data >> 5) & 0x1F) } }

    /// Gruppenname wie 0A, 2B
    public var name: String? { groupType.map { "\($0)\(isVersionB ? "B" : "A")" } }
}

// MARK: - Programmart (PTY) nach RDS Europa (EN 50067)

public enum RDSPTY {
    public static let names: [String] = [
        "Kein Programm", "Nachrichten", "Aktuelles Zeitgeschehen", "Information", "Sport", "Bildung", "Hörspiel & Literatur",
        "Kultur", "Wissenschaft", "Unterhaltung", "Popmusik", "Rockmusik", "Leichte Musik", "Leichte Klassik", "Ernste Klassik",
        "Spezielle Musik", "Wetter", "Wirtschaft", "Kinderprogramm", "Soziales", "Religion", "Anrufsendung", "Reise & Verkehr",
        "Freizeit & Hobby", "Jazzmusik", "Countrymusik", "Nationale Musik", "Oldies", "Folklore", "Dokumentation", "Alarmtest", "ALARM!"
    ]

    public static func name(for code: Int) -> String {
        guard code >= 0, code < names.count else { return "PTY \(code)" }
        return names[code]
    }
}

// MARK: - Ländercode (PI-Code und Erweiterter Ländercode ECC aus Gruppe 1A)

public enum RDSCountry {
    /// Länder nach ECC (E0 … E4) und erstem Nibble des PI-Codes (EN 50067, Tabelle D.1); nicht belegte Felder fehlen
    private static let table: [UInt8: [Character: String]] = [
        0xE0: ["1": "Deutschland", "2": "Algerien", "3": "Andorra", "4": "Israel", "5": "Italien", "6": "Belgien", "7": "Russland",
               "8": "Palästina", "9": "Albanien", "A": "Österreich", "B": "Ungarn", "C": "Malta", "D": "Deutschland", "E": "Ägypten"],
        0xE1: ["1": "Griechenland", "2": "Zypern", "3": "San Marino", "4": "Schweiz", "5": "Jordanien", "6": "Finnland", "7": "Luxemburg",
               "8": "Bulgarien", "9": "Dänemark", "A": "Gibraltar", "B": "Irak", "C": "Großbritannien", "D": "Libyen", "E": "Rumänien",
               "F": "Frankreich"],
        0xE2: ["1": "Marokko", "2": "Tschechien", "3": "Polen", "4": "Vatikan", "5": "Slowakei", "6": "Syrien", "7": "Tunesien",
               "9": "Liechtenstein", "A": "Island", "B": "Monaco", "C": "Litauen", "D": "Serbien", "E": "Spanien", "F": "Norwegen"],
        0xE3: ["1": "Montenegro", "2": "Irland", "3": "Türkei", "8": "Niederlande", "9": "Lettland", "A": "Libanon", "B": "Aserbaidschan",
               "C": "Kroatien", "D": "Kasachstan", "E": "Schweden", "F": "Weißrussland"],
        0xE4: ["1": "Moldau", "2": "Estland", "3": "Kirgisistan", "6": "Ukraine", "7": "Nordmazedonien", "8": "Portugal", "9": "Slowenien",
               "A": "Armenien", "B": "Usbekistan", "C": "Georgien", "F": "Bosnien-Herzegowina"]
    ]

    /// Land aus ECC und PI. Ohne ECC (noch keine Gruppe 1A empfangen) gilt der Block E0 als Vermutung für die westeuropäischen Länder.
    public static func name(for pi: UInt16, ecc: UInt8? = nil) -> String? {
        let nibble = Character(String(format: "%X", (pi >> 12) & 0x0F))
        return table[ecc ?? 0xE0]?[nibble]
    }

    /// Trifft die Auflösung nur eine Vermutung (ECC fehlt)?
    public static func isGuess(ecc: UInt8?) -> Bool { ecc == nil }
}

// MARK: - Zeichensatz (EN 50067, Anhang E)

public enum RDSCharset {
    /// Obere Hälfte (0x80 … 0xFF) des RDS-Zeichensatzes
    private static let upper: [Character] = Array(
        "áàéèíìóòúùÑÇŞß¡Ĳ" + "âäêëîïôöûüñçşğıĳ" + "ªα©‰Ğěňő" + "π€£$←↑→↓" +
        "º¹²³±İńű" + "µ¿÷°¼½¾§" + "ÁÀÉÈÍÌÓÒÚÙŘČŠŽÐĿ" + "ÂÄÊËÎÏÔÖÛÜřčšžđŀ" +
        "ÃÅÆŒŷÝÕØÞŊŔĆŚŹŤð" + "ãåæœŵýõøþŋŕćśźť\u{AD}")

    /// Zeichen des RDS-Zeichensatzes; Steuerzeichen werden zum Leerzeichen
    public static func character(_ code: UInt8) -> Character {
        switch code {
        case 0x20...0x7D:
            return code == 0x24 ? "¤" : Character(UnicodeScalar(code))
        case 0x7E: return "¯"
        case 0x80...0xFF:
            let i = Int(code) - 0x80
            return i < upper.count ? upper[i] : " "
        default:
            return " "
        }
    }
}

// MARK: - Prüfwort und Fehlerkorrektur

public enum RDSSyndrome {
    /// Generatorpolynom g(x) = x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1
    public static let generatorPoly: UInt32 = 0x5B9

    /// Einzel- und Doppelbitfehler (zwei benachbarte Bits) mit ihrem Syndrom; überschneidet sich ein Doppelfehler mit einem anderen Muster, entfällt er
    private static let errorPatterns: [UInt32: (mask: UInt32, burst: Int)] = {
        var dict = [UInt32: (mask: UInt32, burst: Int)]()
        for i in 0..<26 { dict[syndrome(of: 1 << i)] = (1 << i, 1) }
        var clash = Set<UInt32>()
        for i in 0..<25 {
            let mask: UInt32 = 3 << i
            let syn = syndrome(of: mask)
            if dict[syn] != nil { clash.insert(syn) } else { dict[syn] = (mask, 2) }
        }
        for syn in clash where dict[syn]?.burst == 2 { dict[syn] = nil }
        return dict
    }()

    /// Syndrom eines 26-Bit-Wortes modulo g(x); bei fehlerfreiem Block gleich dem Offset-Wort
    public static func syndrome(of word26: UInt32) -> UInt32 {
        var reg = word26 & 0x03FF_FFFF
        for i in (0..<16).reversed() {
            if (reg & (1 << (i + 10))) != 0 {
                reg ^= (generatorPoly << i)
            }
        }
        return reg & 0x3FF
    }

    /// Prüfbits für 16 Datenbits (ohne Offset-Wort)
    public static func checkBits(for data16: UInt16) -> UInt32 {
        syndrome(of: UInt32(data16) << 10)
    }

    /// 26-Bit-Blockwort aus 16 Datenbits und Offset-Wort
    public static func encodeBlock(data: UInt16, offset: RDSOffset) -> UInt32 {
        let m = UInt32(data)
        let check = checkBits(for: data)
        return (m << 10) | (check ^ offset.rawValue)
    }

    /// Prüft ein 26-Bit-Wort gegen ein erwartetes Offset-Wort. `maxBurst` = 0: nur fehlerfreie Blöcke, 1: ein Bitfehler wird repariert,
    /// 2: auch zwei benachbarte Bitfehler. Jede Reparatur erhöht die Gefahr eines falschen Blocks (bei 2: etwa 5 % eines zufälligen Wortes).
    public static func decode(word: UInt32, expected: RDSOffset, maxBurst: Int = 1) -> (data: UInt16, corrected: Int)? {
        let diff = syndrome(of: word) ^ expected.rawValue
        if diff == 0 { return (UInt16((word >> 10) & 0xFFFF), 0) }
        guard maxBurst > 0, let p = errorPatterns[diff], p.burst <= maxBurst else { return nil }
        let fixed = word ^ p.mask
        return (UInt16((fixed >> 10) & 0xFFFF), p.mask.nonzeroBitCount)
    }

    /// Welcher Offset passt zu dem Wort (fehlerfrei, `maxBurst` wie bei `decode`)?
    public static func detectOffset(word: UInt32, maxBurst: Int = 1) -> (offset: RDSOffset, data: UInt16, corrected: Int)? {
        for offset in RDSOffset.allCases {
            if let r = decode(word: word, expected: offset, maxBurst: maxBurst) { return (offset, r.data, r.corrected) }
        }
        return nil
    }
}

// MARK: - Blocksynchronisation und Gruppenbildung

/// Nimmt die Bits hinter der differentiellen Entscheidung entgegen, findet den Blocktakt und liefert Gruppen.
///
/// Suche: zwei fehlerfreie Blöcke im richtigen Abstand und in der richtigen Reihenfolge (A→B→C→D, auch mit einem fehlenden Block dazwischen).
/// Betrieb: Block für Block gegen das erwartete Offset-Wort, Reparatur von Ein- und Zweibitfehlern nur bei guter Empfangslage.
/// Verlust: nach 12 schlechten Blöcken in Folge oder mehr als 45 schlechten unter den letzten 50. Läuft der Takt weg (Bitschlupf), wird
/// über einen zweiten Block-Pfad auf den neuen Takt umgeschaltet, sobald der alte ausfällt.
public final class RDSStreamDecoder: @unchecked Sendable {
    public enum SyncState: String, Sendable {
        case search = "SUCHE"
        case syncing = "SYNCHRONISIERT …"
        case synced = "SYNCHRON"
    }

    public struct Stats: Sendable {
        public var syncState: SyncState
        /// Gruppen mit mindestens einem gültigen Block, die ausgewertet wurden
        public var groupsReceived: Int
        /// Gruppen, in denen alle vier Blöcke gültig waren
        public var completeGroups: Int
        public var blocksReceived: Int
        public var blockErrors: Int
        /// Blöcke, die erst nach einer Reparatur gültig waren
        public var correctedBlocks: Int
        /// Anteil gültiger Blöcke unter den letzten 50 (0 … 1)
        public var quality: Double
        /// Wie oft der Blocktakt verloren oder neu gefunden wurde
        public var resyncs: Int

        public init(syncState: SyncState = .search, groupsReceived: Int = 0, completeGroups: Int = 0, blocksReceived: Int = 0,
                    blockErrors: Int = 0, correctedBlocks: Int = 0, quality: Double = 0, resyncs: Int = 0) {
            self.syncState = syncState
            self.groupsReceived = groupsReceived
            self.completeGroups = completeGroups
            self.blocksReceived = blocksReceived
            self.blockErrors = blockErrors
            self.correctedBlocks = correctedBlocks
            self.quality = quality
            self.resyncs = resyncs
        }
    }

    /// Rückruf bei jeder ausgewerteten Gruppe (auf dem Faden, der die Bits liefert, außerhalb der Sperre)
    public var onGroup: (@Sendable (RDSGroup) -> Void)?

    private let lock = NSLock()
    private var state: SyncState = .search
    private var shiftReg: UInt32 = 0
    private var bitCount: UInt64 = 0
    private var recent: [(index: UInt64, kind: Int)] = []
    private var altMatch: (index: UInt64, kind: Int)?
    private var nextBlockEnd: UInt64 = 0
    private var position = 0
    private var groupBlocks: [RDSBlock?] = [nil, nil, nil, nil]
    private var versionB: Bool?
    private var window = [Bool](repeating: false, count: 50)   // true = schlechter Block
    private var windowIndex = 0
    private var windowBad = 0
    private var windowFill = 0
    private var badRun = 0
    private var goodRun = 0
    private var stats = Stats()

    public init() {}

    public var syncState: SyncState { lock.withLock { state } }
    public var groupsReceived: Int { lock.withLock { stats.groupsReceived } }
    public var blocksReceived: Int { lock.withLock { stats.blocksReceived } }
    public var blockErrors: Int { lock.withLock { stats.blockErrors } }

    public var currentStats: Stats {
        lock.withLock {
            var s = stats
            s.syncState = state
            s.quality = windowFill > 0 ? 1 - Double(windowBad) / Double(windowFill) : 0
            return s
        }
    }

    public func reset() {
        lock.withLock {
            stats = Stats()
            shiftReg = 0
            bitCount = 0
            loseSync(count: false)
        }
    }

    /// Ein entschiedenes Bit (0 oder 1) aus dem differentiellen Decoder
    public func process(bit: Int) {
        var emitted: RDSGroup?
        lock.lock()
        emitted = step(bit)
        lock.unlock()
        if let g = emitted { onGroup?(g) }
    }

    // MARK: Innenleben

    /// Art des fehlerfreien Blocks (0 A, 1 B, 2 C, 3 D, 4 C') aus dem Syndrom, sonst −1
    @inline(__always)
    private static func kind(ofSyndrome s: UInt32) -> Int {
        switch s {
        case RDSOffset.a.rawValue: return 0
        case RDSOffset.b.rawValue: return 1
        case RDSOffset.c.rawValue: return 2
        case RDSOffset.d.rawValue: return 3
        case RDSOffset.cPrime.rawValue: return 4
        default: return -1
        }
    }

    /// Stelle in der Gruppe zu einer Blockart
    @inline(__always)
    private static func slot(ofKind k: Int) -> Int { k == 4 ? 2 : k }

    /// Passt `second` im Abstand von `blocks` Blöcken auf `first`?
    private static func consistent(_ first: Int, _ second: Int, blocks: Int) -> Bool {
        (slot(ofKind: first) + blocks) % 4 == slot(ofKind: second)
    }

    private func step(_ bit: Int) -> RDSGroup? {
        shiftReg = ((shiftReg << 1) | UInt32(bit & 1)) & 0x03FF_FFFF
        bitCount &+= 1
        guard bitCount >= 26 else { return nil }

        let syn = RDSSyndrome.syndrome(of: shiftReg)
        let kind = Self.kind(ofSyndrome: syn)

        if state == .search {
            guard kind >= 0 else { return nil }
            recent.removeAll { bitCount - $0.index > 52 }
            for m in recent {
                let dist = bitCount - m.index
                if (dist == 26 || dist == 52) && Self.consistent(m.kind, kind, blocks: Int(dist / 26)) {
                    acquire(kind: kind)
                    return nil
                }
            }
            recent.append((bitCount, kind))
            return nil
        }

        // Im Betrieb: Block-Pfad prüfen, Takt verfolgen
        if kind >= 0 && bitCount != nextBlockEnd && (bitCount % 26) != (nextBlockEnd % 26) {
            // fehlerfreier Block mit anderem Takt: Kandidat für einen neuen Blocktakt (Bitschlupf)
            if let am = altMatch, bitCount - am.index == 26, Self.consistent(am.kind, kind, blocks: 1), badRun >= 3 {
                stats.resyncs += 1
                acquire(kind: kind)
                return nil
            }
            altMatch = (bitCount, kind)
        }
        guard bitCount == nextBlockEnd else { return nil }
        return finishBlock()
    }

    private static func offset(ofKind k: Int) -> RDSOffset {
        switch k {
        case 0: return .a
        case 1: return .b
        case 2: return .c
        case 3: return .d
        default: return .cPrime
        }
    }

    /// Takt gefunden: der Block, der gerade endete, hat die Art `kind`; der nächste folgt nach 26 Bit
    private func acquire(kind: Int) {
        state = .syncing
        goodRun = 0
        badRun = 0
        altMatch = nil
        recent.removeAll()
        versionB = nil
        groupBlocks = [nil, nil, nil, nil]
        let slot = Self.slot(ofKind: kind)
        let off = Self.offset(ofKind: kind)
        if let r = RDSSyndrome.decode(word: shiftReg, expected: off, maxBurst: 0) {
            groupBlocks[slot] = RDSBlock(data: r.data, offset: off)
            if slot == 1 { versionB = ((r.data >> 11) & 1) == 1 }
        }
        position = (slot + 1) % 4
        nextBlockEnd = bitCount + 26
        if slot == 3 { groupBlocks = [nil, nil, nil, nil] }
    }

    private func loseSync(count: Bool = true) {
        if count && state != .search { stats.resyncs += 1 }
        state = .search
        recent.removeAll()
        altMatch = nil
        groupBlocks = [nil, nil, nil, nil]
        versionB = nil
        position = 0
        badRun = 0
        goodRun = 0
        window = [Bool](repeating: false, count: 50)
        windowIndex = 0
        windowBad = 0
        windowFill = 0
    }

    private func recordWindow(bad: Bool) {
        if windowFill == 50 {
            if window[windowIndex] { windowBad -= 1 }
        } else {
            windowFill += 1
        }
        window[windowIndex] = bad
        if bad { windowBad += 1 }
        windowIndex = (windowIndex + 1) % 50
    }

    /// Der Block an der erwarteten Stelle ist vollständig im Schieberegister
    private func finishBlock() -> RDSGroup? {
        let word = shiftReg
        nextBlockEnd = bitCount + 26
        // Reparatur nur bei guter Lage und nach gesichertem Takt; sonst steigt die Zahl falscher Blöcke
        let burst: Int
        if state != .synced { burst = 0 } else if windowFill >= 10 && Double(windowBad) / Double(windowFill) > 0.25 { burst = 1 } else { burst = 2 }

        var candidates: [RDSOffset]
        switch position {
        case 0: candidates = [.a]
        case 1: candidates = [.b]
        case 2:
            if let vb = versionB { candidates = vb ? [.cPrime] : [.c] } else { candidates = [.c, .cPrime] }
        default: candidates = [.d]
        }
        var found: RDSBlock?
        // erst fehlerfrei über alle Kandidaten, dann mit Reparatur
        search: for b in 0...burst {
            for off in candidates {
                if let r = RDSSyndrome.decode(word: word, expected: off, maxBurst: b) {
                    found = RDSBlock(data: r.data, offset: off, correctedBits: r.corrected)
                    break search
                }
            }
        }

        let bad = found == nil
        if let blk = found {
            groupBlocks[position] = blk
            stats.blocksReceived += 1
            if blk.correctedBits > 0 { stats.correctedBlocks += 1 }
            if position == 1 { versionB = ((blk.data >> 11) & 1) == 1 }
            goodRun += 1
            badRun = 0
        } else {
            stats.blockErrors += 1
            badRun += 1
            goodRun = 0
            if position == 1 { versionB = nil }
        }
        recordWindow(bad: bad)

        // Provisorischer Takt: gleich beim ersten Fehler zurück zur Suche, nach drei guten Blöcken gesichert
        if state == .syncing {
            if bad {
                loseSync(count: false)
                return nil
            }
            if goodRun >= 3 { state = .synced }
        } else if badRun >= 12 || (windowFill >= 50 && windowBad > 45) {
            let out = completeGroupIfAny()
            loseSync()
            return out
        }

        var out: RDSGroup?
        if position == 3 {
            out = completeGroupIfAny()
        }
        position = (position + 1) % 4
        return out
    }

    /// Gruppe abschließen und zurücksetzen. Eine Gruppe ohne Block B und ohne PI-Quelle trägt nichts bei und entfällt.
    private func completeGroupIfAny() -> RDSGroup? {
        defer {
            groupBlocks = [nil, nil, nil, nil]
            versionB = nil
        }
        let g = RDSGroup(blocks: groupBlocks)
        guard g.validBlockCount > 0, g.blockB != nil || g.pi != nil else { return nil }
        stats.groupsReceived += 1
        if g.isComplete { stats.completeGroups += 1 }
        return g
    }
}
