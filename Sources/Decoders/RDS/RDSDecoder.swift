// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Auswertung der RDS-Gruppen: Programmkennung, Programmname (PS), Radiotext (RT, RT+), Programmtyp, Uhrzeit, Alternativfrequenzen und mehr.
// Bei schwachem Empfang rutschen falsch reparierte Blöcke durch die Prüfbits. Darum gilt: Werte aus fehlerfreien Blöcken bei guter Empfangslage
// werden sofort übernommen, alles andere erst, wenn es zweimal in Folge gleich ankommt. Fehlende Blöcke einer Gruppe sind kein Hindernis:
// Was gültig ist, wird verwendet.

// MARK: - Ergebnis

public struct RDSInfo: Sendable, Equatable {
    public var pi: UInt16?
    public var ecc: UInt8?
    public var languageCode: UInt8?
    public var programService: String = ""
    /// Alle acht Zeichen des Programmnamens sind gesichert
    public var programServiceComplete = false
    public var radioText: String = ""
    public var radioTextComplete = false
    public var radioTextHistory: [String] = []
    /// RT+: Beschriftung und Text, z. B. („Titel“, „…“), („Interpret“, „…“)
    public var radioTextPlus: [RDSTag] = []
    public var programTypeName: String = ""
    public var pty: Int?
    public var tp: Bool = false
    public var ta: Bool = false
    public var music: Bool?
    /// Decoder-Kennungen aus Gruppe 0: Stereo, Kunstkopf, komprimiert, dynamischer PTY
    public var diStereo: Bool?
    public var diArtificialHead: Bool?
    public var diCompressed: Bool?
    public var diDynamicPTY: Bool?
    /// Uhrzeit der Gruppe 4A (UTC) und örtlicher Versatz in halben Stunden
    public var clockUTC: Date?
    public var clockOffsetHalfHours: Int = 0
    public var alternativeFrequencies: [Double] = []
    /// Angekündigte Zusatzanwendungen (Anwendungskennungen, z. B. 4BD0 = RT+, CD46 = TMC)
    public var applications: [UInt16] = []
    public var groupCounts: [String: Int] = [:]
    public var totalGroups = 0

    public init() {}

    public var piHex: String? { pi.map { String(format: "%04X", $0) } }
    public var country: String? { pi.flatMap { RDSCountry.name(for: $0, ecc: ecc) } }
    public var countryIsGuess: Bool { RDSCountry.isGuess(ecc: ecc) }
    public var language: String? { languageCode.flatMap(RDSDecoder.languageName) }
    public var ptyName: String? { pty.map(RDSPTY.name(for:)) }
    public var applicationNames: [String] { applications.map(RDSDecoder.applicationName) }

    /// Uhrzeit als Text in der Ortszeit des Senders
    public var clockFormatted: String? {
        guard let utc = clockUTC else { return nil }
        let local = utc.addingTimeInterval(Double(clockOffsetHalfHours) * 1800)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        let off = clockOffsetHalfHours
        let sign = off < 0 ? "-" : "+"
        return String(format: "%02d.%02d.%04d %02d:%02d (UTC%@%d%@)", c.day ?? 0, c.month ?? 0, c.year ?? 0, c.hour ?? 0, c.minute ?? 0,
                      sign, abs(off) / 2, abs(off) % 2 == 1 ? ":30" : "")
    }
}

public struct RDSTag: Sendable, Equatable {
    public var label: String
    public var text: String
}

// MARK: - Bestätigung durch Wiederholung

/// Ein Wert, der übernommen wird, wenn er aus sicherer Quelle kommt oder zweimal hintereinander gleich ist
private struct Confirmed<T: Equatable> {
    private(set) var value: T?
    private var candidate: T?
    private var hits = 0

    /// Rückgabe: Wert hat sich geändert
    @discardableResult
    mutating func offer(_ v: T, trusted: Bool) -> Bool {
        if v == candidate { hits += 1 } else { candidate = v; hits = 1 }
        guard trusted || hits >= 2, value != v else { return false }
        value = v
        return true
    }

    mutating func clear() { value = nil; candidate = nil; hits = 0 }
}

/// Zeichenfeld (PS, RT, PTYN) mit Bestätigung je Stelle
private struct TextField {
    var chars: [UInt8?]
    private var candidate: [UInt8?]
    private var hits: [Int]

    init(length: Int) {
        chars = [UInt8?](repeating: nil, count: length)
        candidate = chars
        hits = [Int](repeating: 0, count: length)
    }

    mutating func clear() {
        let n = chars.count
        self = TextField(length: n)
    }

    mutating func put(_ c: UInt8, at i: Int, trusted: Bool) {
        guard i >= 0, i < chars.count else { return }
        if candidate[i] == c { hits[i] += 1 } else { candidate[i] = c; hits[i] = 1 }
        if trusted || hits[i] >= 2 { chars[i] = c }
    }
}

// MARK: - Decoder

public final class RDSDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var info = RDSInfo()

    private var pi = Confirmed<UInt16>()
    private var piAlt: UInt16?
    private var piAltHits = 0
    private var ecc = Confirmed<UInt8>()
    private var lang = Confirmed<UInt8>()
    private var ptyV = Confirmed<Int>()
    private var tpV = Confirmed<Bool>()
    private var taV = Confirmed<Bool>()
    private var musicV = Confirmed<Bool>()
    private var diStereo = Confirmed<Bool>()
    private var diHead = Confirmed<Bool>()
    private var diComp = Confirmed<Bool>()
    private var diDyn = Confirmed<Bool>()

    private var ps = TextField(length: 8)
    private var ptyn = TextField(length: 8)
    private var rt = TextField(length: 64)
    private var rtFlag: Bool?
    private var rtLastShown = ""

    private var afCounts: [Double: Int] = [:]
    private var afRemaining = 0
    private var afLFMFNext = false

    private var ctCandidate: (utc: Date, offset: Int)?

    private var rtPlusType: Int?
    private var rtPlusToggle: Bool?
    private var rtPlusTags: [(type: Int, start: Int, length: Int)] = []

    /// Frequenz, auf die der Empfänger abgestimmt ist (MHz); sie erscheint nicht in der Liste der Alternativen
    public var tunedMHz: Double?

    public init() {}

    public func reset() {
        lock.withLock { resetAll() }
    }

    public var snapshot: RDSInfo { lock.withLock { info } }

    /// Eine Gruppe auswerten. `quality`: Anteil gültiger Blöcke unter den letzten 50 (0 … 1).
    public func handle(_ group: RDSGroup, quality: Double) {
        lock.withLock { process(group, quality: quality) }
    }

    private func resetAll() {
        info = RDSInfo()
        pi = Confirmed(); piAlt = nil; piAltHits = 0
        ecc = Confirmed(); lang = Confirmed(); ptyV = Confirmed(); tpV = Confirmed(); taV = Confirmed(); musicV = Confirmed()
        diStereo = Confirmed(); diHead = Confirmed(); diComp = Confirmed(); diDyn = Confirmed()
        ps.clear(); ptyn.clear(); rt.clear(); rtFlag = nil; rtLastShown = ""
        afCounts = [:]; afRemaining = 0; afLFMFNext = false
        ctCandidate = nil
        rtPlusType = nil; rtPlusToggle = nil; rtPlusTags = []
    }

    /// Der Sender wechselt: alles bisher Gelernte gehört zum alten Programm
    private func stationChanged() {
        let counts = info.groupCounts, total = info.totalGroups
        resetAll()
        info.groupCounts = counts
        info.totalGroups = total
    }

    // MARK: Gruppen

    private func process(_ g: RDSGroup, quality: Double) {
        info.totalGroups += 1
        if let name = g.name { info.groupCounts[name, default: 0] += 1 }

        let good = quality >= 0.85
        // PI-Code aus Block A oder C'
        if let v = g.pi {
            let src = g.blockA ?? g.blockC
            let tr = good && (src?.correctedBits ?? 1) == 0
            if info.pi == nil {
                if pi.offer(v, trusted: tr) { info.pi = v }
            } else if v == info.pi {
                piAlt = nil; piAltHits = 0
            } else {
                // anderer Sender: erst nach drei gleichen Beobachtungen umschalten
                if v == piAlt { piAltHits += 1 } else { piAlt = v; piAltHits = 1 }
                if piAltHits >= 3 {
                    stationChanged()
                    pi.offer(v, trusted: true)
                    info.pi = v
                }
            }
        }
        guard let b = g.blockB, info.pi != nil else { return }
        // Nur Gruppen des gerade gültigen Senders auswerten
        if let v = g.pi, v != info.pi { return }

        let trustedB = good && b.correctedBits == 0
        if tpV.offer(((b.data >> 10) & 1) == 1, trusted: trustedB) { info.tp = tpV.value ?? false }
        if ptyV.offer(Int((b.data >> 5) & 0x1F), trusted: trustedB) { info.pty = ptyV.value }

        let type = Int((b.data >> 12) & 0x0F)
        let versionB = ((b.data >> 11) & 1) == 1
        switch (type, versionB) {
        case (0, _): group0(g, b, versionB: versionB, good: good)
        case (1, false): group1A(g, good: good)
        case (2, _): group2(g, b, versionB: versionB, good: good)
        case (3, false): group3A(g, b)
        case (4, false): group4A(g, b, good: good)
        case (10, false): group10A(g, b, good: good)
        default: break
        }
        // RT+ steht in einer Gruppe, deren Typ in 3A angekündigt wurde
        if let announced = rtPlusType, announced == (type << 1 | (versionB ? 1 : 0)), type != 3 {
            groupRTPlus(g, b)
        }
        publishText()
    }

    private func trusted(_ block: RDSBlock?, good: Bool) -> Bool { good && (block?.correctedBits ?? 1) == 0 }

    // MARK: 0A / 0B

    private func group0(_ g: RDSGroup, _ b: RDSBlock, versionB: Bool, good: Bool) {
        let trB = trusted(b, good: good)
        if taV.offer(((b.data >> 4) & 1) == 1, trusted: trB) { info.ta = taV.value ?? false }
        if musicV.offer(((b.data >> 3) & 1) == 1, trusted: trB) { info.music = musicV.value }
        let seg = Int(b.data & 3)
        let diBit = ((b.data >> 2) & 1) == 1
        switch seg {
        case 0: if diDyn.offer(diBit, trusted: trB) { info.diDynamicPTY = diDyn.value }
        case 1: if diComp.offer(diBit, trusted: trB) { info.diCompressed = diComp.value }
        case 2: if diHead.offer(diBit, trusted: trB) { info.diArtificialHead = diHead.value }
        default: if diStereo.offer(diBit, trusted: trB) { info.diStereo = diStereo.value }
        }
        if let d = g.blockD {
            let tr = trusted(d, good: good) && trB
            ps.put(RDSDecoder.psCode(d.data >> 8), at: seg * 2, trusted: tr)
            ps.put(RDSDecoder.psCode(d.data & 0xFF), at: seg * 2 + 1, trusted: tr)
        }
        if !versionB, let c = g.blockC, c.correctedBits == 0 {
            feedAF(UInt8(c.data >> 8))
            feedAF(UInt8(c.data & 0xFF))
        }
    }

    /// Alternativfrequenzen nach Methode A: Zählcode 225 … 249, danach die Frequenzcodes (1 … 204 = 87,6 … 107,9 MHz)
    private func feedAF(_ t: UInt8) {
        if afLFMFNext {
            afLFMFNext = false
            if afRemaining > 0 { afRemaining -= 1 }
            return
        }
        switch t {
        case 225...249:
            afRemaining = Int(t) - 224
        case 250:
            afLFMFNext = true
        case 1...204:
            guard afRemaining > 0 else { return }
            afRemaining -= 1
            let mhz = ((87.5 + Double(t) * 0.1) * 10).rounded() / 10
            afCounts[mhz, default: 0] += 1
            publishAF()
        default:
            break
        }
    }

    private func publishAF() {
        let tuned = tunedMHz
        info.alternativeFrequencies = afCounts.filter { $0.value >= 2 && (tuned == nil || abs($0.key - tuned!) > 0.05) }.keys.sorted()
    }

    // MARK: 1A

    private func group1A(_ g: RDSGroup, good: Bool) {
        guard let c = g.blockC, c.offset == .c, c.correctedBits == 0 else { return }
        let variant = Int((c.data >> 12) & 7)
        if variant == 0, ecc.offer(UInt8(c.data & 0xFF), trusted: false) { info.ecc = ecc.value }
        if variant == 3, lang.offer(UInt8(c.data & 0xFF), trusted: false) { info.languageCode = lang.value }
    }

    // MARK: 2A / 2B (Radiotext)

    private func group2(_ g: RDSGroup, _ b: RDSBlock, versionB: Bool, good: Bool) {
        let flag = ((b.data >> 4) & 1) == 1
        let seg = Int(b.data & 0x0F)
        let trB = trusted(b, good: good)
        if let cur = rtFlag, cur != flag {
            // Neue Nachricht: die alte in den Verlauf
            if !info.radioText.isEmpty { pushHistory(info.radioText) }
            rt.clear()
            info.radioText = ""
            rtLastShown = ""
            info.radioTextPlus = []
            rtPlusTags = []
        }
        rtFlag = flag
        if !versionB {
            if let c = g.blockC, c.offset == .c {
                let tr = trusted(c, good: good) && trB
                rt.put(UInt8(c.data >> 8), at: seg * 4, trusted: tr)
                rt.put(UInt8(c.data & 0xFF), at: seg * 4 + 1, trusted: tr)
            }
            if let d = g.blockD {
                let tr = trusted(d, good: good) && trB
                rt.put(UInt8(d.data >> 8), at: seg * 4 + 2, trusted: tr)
                rt.put(UInt8(d.data & 0xFF), at: seg * 4 + 3, trusted: tr)
            }
        } else if let d = g.blockD {
            let tr = trusted(d, good: good) && trB
            rt.put(UInt8(d.data >> 8), at: seg * 2, trusted: tr)
            rt.put(UInt8(d.data & 0xFF), at: seg * 2 + 1, trusted: tr)
        }
    }

    private func pushHistory(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, info.radioTextHistory.first != t else { return }
        info.radioTextHistory.insert(t, at: 0)
        if info.radioTextHistory.count > 40 { info.radioTextHistory.removeLast() }
    }

    // MARK: 3A / RT+

    private func group3A(_ g: RDSGroup, _ b: RDSBlock) {
        guard let d = g.blockD, d.correctedBits == 0 else { return }
        let aid = d.data
        if !info.applications.contains(aid) { info.applications.append(aid) }
        if aid == 0x4BD7 { rtPlusType = Int(b.data & 0x1F) }
    }

    private func groupRTPlus(_ g: RDSGroup, _ b: RDSBlock) {
        guard let c = g.blockC, let d = g.blockD, c.correctedBits == 0, d.correctedBits == 0 else { return }
        let toggle = ((b.data >> 4) & 1) == 1
        let running = ((b.data >> 3) & 1) == 1
        if let t = rtPlusToggle, t != toggle { rtPlusTags = [] }
        rtPlusToggle = toggle
        guard running else { rtPlusTags = []; return }
        let t1 = (type: Int(((b.data & 7) << 3) | (c.data >> 13)), start: Int((c.data >> 7) & 0x3F), length: Int((c.data >> 1) & 0x3F) + 1)
        let t2 = (type: Int(((c.data & 1) << 5) | (d.data >> 11)), start: Int((d.data >> 5) & 0x3F), length: Int(d.data & 0x1F) + 1)
        rtPlusTags = [t1, t2].filter { $0.type != 0 }
    }

    // MARK: 4A

    private func group4A(_ g: RDSGroup, _ b: RDSBlock, good: Bool) {
        guard let c = g.blockC, let d = g.blockD, c.correctedBits == 0, d.correctedBits == 0 else { return }
        let mjd = (UInt32(b.data & 3) << 15) | UInt32(c.data >> 1)
        let hour = Int(((c.data & 1) << 4) | (d.data >> 12))
        let minute = Int((d.data >> 6) & 0x3F)
        var off = Int(d.data & 0x1F)
        if (d.data >> 5) & 1 == 1 { off = -off }
        guard hour < 24, minute < 60, mjd > 40_587, abs(off) <= 28 else { return }
        let utc = Date(timeIntervalSince1970: Double(Int(mjd) - 40_587) * 86_400 + Double(hour * 3600 + minute * 60))
        // Die Uhrzeit kommt nur einmal je Minute: bei guter Lage gleich übernehmen, sonst erst, wenn zwei Meldungen zueinander passen
        let consistent = ctCandidate.map { abs($0.utc.timeIntervalSince(utc)) <= 150 && $0.offset == off } ?? false
        if good || consistent {
            info.clockUTC = utc
            info.clockOffsetHalfHours = off
        }
        ctCandidate = (utc, off)
    }

    // MARK: 10A (Programmtyp-Name)

    private func group10A(_ g: RDSGroup, _ b: RDSBlock, good: Bool) {
        let seg = Int(b.data & 1)
        let trB = trusted(b, good: good)
        if let c = g.blockC, c.offset == .c {
            let tr = trusted(c, good: good) && trB
            ptyn.put(RDSDecoder.psCode(c.data >> 8), at: seg * 4, trusted: tr)
            ptyn.put(RDSDecoder.psCode(c.data & 0xFF), at: seg * 4 + 1, trusted: tr)
        }
        if let d = g.blockD {
            let tr = trusted(d, good: good) && trB
            ptyn.put(RDSDecoder.psCode(d.data >> 8), at: seg * 4 + 2, trusted: tr)
            ptyn.put(RDSDecoder.psCode(d.data & 0xFF), at: seg * 4 + 3, trusted: tr)
        }
    }

    // MARK: Text zusammensetzen

    /// Programmname und Zeichenketten mit Steuerzeichen bereinigen (0x0D beendet den Radiotext)
    private static func psCode(_ v: UInt16) -> UInt8 { UInt8(v & 0xFF) }

    private func string(of chars: [UInt8?], length: Int? = nil, stopAtReturn: Bool = false) -> (text: String, complete: Bool) {
        var out = ""
        var complete = true
        var end = length ?? chars.count
        if stopAtReturn, let cr = chars.firstIndex(where: { $0 == 0x0D }) { end = min(end, cr) }
        for i in 0..<end {
            if let c = chars[i] { out.append(RDSCharset.character(c)) } else { out.append(" "); complete = false }
        }
        if stopAtReturn, !chars.contains(where: { $0 == 0x0D }), chars.contains(where: { $0 == nil }) { complete = false }
        return (out, complete)
    }

    private func publishText() {
        let p = string(of: ps.chars)
        info.programService = p.text.trimmingCharacters(in: .whitespaces)
        info.programServiceComplete = p.complete
        let n = string(of: ptyn.chars)
        info.programTypeName = n.text.trimmingCharacters(in: .whitespaces)
        let r = string(of: rt.chars, stopAtReturn: true)
        let text = r.text.trimmingCharacters(in: .whitespaces)
        info.radioText = text
        info.radioTextComplete = r.complete && !text.isEmpty
        if r.complete, !text.isEmpty, text != rtLastShown {
            rtLastShown = text
            pushHistory(text)
        }
        // RT+ gilt nur für gesicherte Textstellen
        if !rtPlusTags.isEmpty {
            let full = Array(string(of: rt.chars, stopAtReturn: false).text)
            var tags: [RDSTag] = []
            for t in rtPlusTags {
                let end = t.start + t.length
                guard end <= full.count, let label = RDSDecoder.rtPlusLabel(t.type) else { continue }
                let known = (t.start..<end).allSatisfy { rt.chars[$0] != nil }
                if known { tags.append(RDSTag(label: label, text: String(full[t.start..<end]).trimmingCharacters(in: .whitespaces))) }
            }
            info.radioTextPlus = tags
        }
    }

    // MARK: Tabellen

    static func rtPlusLabel(_ type: Int) -> String? {
        switch type {
        case 1: return "Titel"
        case 2: return "Album"
        case 3: return "Titelnummer"
        case 4: return "Interpret"
        case 5: return "Komposition"
        case 6: return "Satz"
        case 7: return "Dirigent"
        case 8: return "Komponist"
        case 9: return "Band"
        case 10: return "Kommentar"
        case 11: return "Genre"
        case 12: return "Nachrichten"
        case 13: return "Lokale Nachrichten"
        case 14: return "Börse"
        case 15: return "Sport"
        case 16: return "Lotterie"
        case 17: return "Horoskop"
        case 18: return "Tagesinfo"
        case 19: return "Gesundheit"
        case 20: return "Veranstaltung"
        case 21: return "Szene"
        case 22: return "Kino"
        case 23: return "Fernsehen"
        case 24: return "Kultur"
        case 25: return "Wetter"
        case 26: return "Verkehr"
        case 27: return "Werbung"
        case 28: return "Sender-Info"
        case 29: return "Telefon"
        case 30: return "SMS"
        case 31: return "E-Mail"
        case 32: return "Kurzname des Senders"
        case 33: return "Langname des Senders"
        case 34: return "Programm"
        case 35: return "Beitrag"
        case 36: return "Gastgeber"
        case 37: return "Redaktion"
        case 38: return "Anrufer"
        case 39: return "Studio"
        case 40: return "Webadresse"
        case 41: return "Rückkanal"
        default: return nil
        }
    }

    static func applicationName(_ aid: UInt16) -> String {
        switch aid {
        case 0x4BD7: return "RT+"
        case 0xCD46, 0xCD47: return "TMC"
        case 0x4B01: return "TMC"
        case 0x6552: return "eRT"
        case 0x0093: return "DAB-Querverweis"
        case 0xE911: return "EWS"
        default: return String(format: "ODA %04X", aid)
        }
    }

    static func languageName(_ code: UInt8) -> String? {
        let names = ["unbekannt", "Albanisch", "Bretonisch", "Katalanisch", "Kroatisch", "Walisisch", "Tschechisch", "Dänisch", "Deutsch",
                     "Englisch", "Spanisch", "Esperanto", "Estnisch", "Baskisch", "Färöisch", "Französisch", "Friesisch", "Irisch", "Gälisch",
                     "Galicisch", "Isländisch", "Italienisch", "Lappisch", "Lateinisch", "Lettisch", "Luxemburgisch", "Litauisch", "Ungarisch",
                     "Maltesisch", "Niederländisch", "Norwegisch", "Okzitanisch", "Polnisch", "Portugiesisch", "Rumänisch", "Rätoromanisch",
                     "Serbisch", "Slowakisch", "Slowenisch", "Finnisch", "Schwedisch", "Türkisch", "Flämisch", "Wallonisch"]
        return Int(code) < names.count ? names[Int(code)] : nil
    }
}
