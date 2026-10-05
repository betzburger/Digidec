// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// DSC (Digitaler Selektivruf) nach ITU-R M.493 für MF/HF: F1B/J2B, 170 Hz Hub, 100 Baud, Mitte 1700 Hz im NF (J2B).
// Der höhere Ton ist der B-Zustand (0), der tiefere der Y-Zustand (1) (M.493 § 1.4).
// Die Nachrichtenaufteilung folgt M.493 und wurde an echten Aufnahmen und Symbolfolgen der MIT-lizenzierten
// Referenz TAOSW.DSC_Decoder (github.com/alemassimo/TAOSW.DSC_Decoder) geprüft (siehe Vendor/Dsc/UPSTREAM_DSC.md).

// MARK: - Symbole (10-Bit-Code, M.493 Tabelle 1)

public enum DSCSymbolCode {
    public static let eosSymbols: Set<Int> = [117, 122, 127]

    /// Anzahl der B-Elemente (Nullen) in den 7 Informationsbits
    static func zeroCount(_ v: Int) -> Int { 7 - (v & 0x7F).nonzeroBitCount }

    /// 10 Bits eines Symbols: 7 Informationsbits (niederwertigstes zuerst, Y = 1), dann 3 Prüfbits (höchstwertiges zuerst)
    public static func bits(for v: Int) -> [UInt8] {
        var out: [UInt8] = (0..<7).map { UInt8((v >> $0) & 1) }
        let c = zeroCount(v)
        out += [UInt8((c >> 2) & 1), UInt8((c >> 1) & 1), UInt8(c & 1)]
        return out
    }

    /// Symbolnummer 0 … 127 oder nil, wenn die Prüfbits nicht stimmen
    public static func decode(_ bits: ArraySlice<UInt8>) -> Int? {
        guard bits.count == 10 else { return nil }
        let b = Array(bits)
        var v = 0
        for j in 0..<7 where b[j] != 0 { v |= 1 << j }
        let check = Int(b[7]) << 2 | Int(b[8]) << 1 | Int(b[9])
        return check == zeroCount(v) ? v : nil
    }
}

// MARK: - Nachricht

public struct DSCMessage: Identifiable, Sendable, Equatable {
    public enum Format: Int, Sendable {
        case geographicArea = 102, group = 114, allShips = 116, individual = 120, automatic = 123, distress = 112
        case unknown = -1

        public var name: String {
            switch self {
            case .distress: return "NOTRUF"
            case .allShips: return "ALLE SCHIFFE"
            case .group: return "GRUPPE"
            case .individual: return "EINZELRUF"
            case .geographicArea: return "GEBIET"
            case .automatic: return "AUTOMATIK"
            case .unknown: return "FEHLER"
            }
        }
    }

    public let id = UUID()
    public var receivedAt: Date
    /// NF-Mitte, auf der empfangen wurde
    public var centerHz: Double
    /// Zusammengeführte Symbole (DX, bei Fehler die Wiederholung RX; −1 = nicht lesbar), ab Formatspezifizierer
    public var symbols: [Int]
    public var format: Format
    public var category: String?
    public var to: String?
    public var from: String?
    public var firstCommand: String?
    public var secondCommand: String?
    public var nature: String?
    public var position: String?
    public var timeUTC: String?
    public var frequency: String?
    public var eos: String?
    public var ecc: Int?
    public var eccOK: Bool
    /// Symbole, die in DX und RX unlesbar waren
    public var unreadable: Int
    public var note: String?

    public var isDistress: Bool { format == .distress || category == "SEENOT" || firstCommand == "NOTRUF-QUITTUNG" || firstCommand == "NOTRUF-WEITERLEITUNG" }

    public static func == (a: DSCMessage, b: DSCMessage) -> Bool { a.id == b.id }

    /// Einzeilige Zusammenfassung
    public var summary: String {
        var parts: [String] = []
        if let nature { parts.append(nature) }
        if let firstCommand, firstCommand != "KEINE ANGABE" { parts.append(firstCommand) }
        if let secondCommand, secondCommand != "KEINE ANGABE" { parts.append(secondCommand) }
        if let frequency { parts.append("\(frequency) kHz") }
        if let position { parts.append(position) }
        if let timeUTC { parts.append("\(timeUTC) UTC") }
        if let eos { parts.append(eos) }
        if let note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    // MARK: Bezeichnungen

    static func categoryName(_ s: Int) -> String? {
        switch s { case 100: return "ROUTINE"; case 108: return "SICHERHEIT"; case 110: return "DRINGLICHKEIT"; case 112: return "SEENOT"; default: return nil }
    }
    static func natureName(_ s: Int) -> String? {
        let n = [100: "Feuer/Explosion", 101: "Wassereinbruch", 102: "Kollision", 103: "Grundberührung", 104: "Kentergefahr",
                 105: "Sinken", 106: "Manövrierunfähig", 107: "Unbestimmt", 108: "Schiff wird verlassen",
                 109: "Piraterie/Überfall", 110: "Mann über Bord", 112: "EPIRB"]
        return n[s]
    }
    static func firstCommandName(_ s: Int) -> String? {
        let n = [100: "F3E/G3E alle Betriebsarten", 101: "F3E/G3E Duplex", 103: "ABFRAGE", 104: "KANN NICHT ENTSPRECHEN", 105: "ENDE DES RUFS",
                 106: "DATEN", 109: "J3E SPRECHFUNK", 110: "NOTRUF-QUITTUNG", 112: "NOTRUF-WEITERLEITUNG", 113: "F1B/J2B TTY-FEC",
                 115: "F1B/J2B TTY-ARQ", 118: "TEST", 121: "POSITIONSMELDUNG", 126: "KEINE ANGABE"]
        return n[s]
    }
    static func secondCommandName(_ s: Int) -> String? {
        let n = [100: "ohne Grund", 101: "Vermittlung überlastet", 102: "BESETZT", 103: "Warteschlange", 104: "Station gesperrt",
                 105: "kein Bediener", 106: "Bediener nicht erreichbar", 107: "Gerät ausgefallen", 108: "Kanal nicht nutzbar",
                 109: "Betriebsart nicht nutzbar", 110: "Schiffe neutraler Staaten", 111: "Sanitätstransport", 112: "Münzfernsprecher",
                 113: "Fax/Daten", 120: "keine weitere ACS-Aussendung", 121: "1 weitere ACS-Aussendung", 122: "2 weitere ACS-Aussendungen",
                 123: "3 weitere ACS-Aussendungen", 124: "4 weitere ACS-Aussendungen", 125: "5 weitere ACS-Aussendungen", 126: "KEINE ANGABE"]
        return n[s]
    }
    static func eosName(_ s: Int) -> String? {
        switch s { case 117: return "QUITTUNG ERBETEN"; case 122: return "QUITTUNG"; case 127: return "ENDE"; default: return nil }
    }

    // MARK: Ziffernfelder

    /// Zwei Ziffern je Symbol 0 … 99; nicht lesbar oder > 99 → „__“
    private static func digits(_ syms: ArraySlice<Int>) -> String {
        syms.map { (0...99).contains($0) ? String(format: "%02d", $0) : "__" }.joined()
    }

    /// MMSI: 5 Symbole = 10 Ziffern, die letzte (immer 0) entfällt
    static func mmsi(_ syms: ArraySlice<Int>) -> String {
        let d = digits(syms)
        return String(d.dropLast())
    }

    /// Position: Quadrant (0 NO, 1 NW, 2 SO, 3 SW), Breite GG MM, Länge LLL MM
    static func position(_ syms: ArraySlice<Int>) -> String? {
        let d = digits(syms)
        guard d.count == 10, !d.contains("_"), let q = Int(d.prefix(1)), q <= 3 else { return nil }
        let a = Array(d)
        let lat = String(a[1...2]) + "°" + String(a[3...4]) + "′" + (q < 2 ? "N" : "S")
        let lon = String(a[5...7]) + "°" + String(a[8...9]) + "′" + (q % 2 == 0 ? "O" : "W")
        return lat + " " + lon
    }

    /// Gebiet: Bezugspunkt ist die nordwestliche Ecke; das Rechteck reicht ΔBreite nach Süden und ΔLänge nach Osten (M.493 § 5.3)
    static func area(_ syms: ArraySlice<Int>) -> String? {
        let d = digits(syms)
        guard d.count == 10, !d.contains("_"), let q = Int(d.prefix(1)), q <= 3 else { return nil }
        let a = Array(d)
        let lat = Int(String(a[1...2]))!, lon = Int(String(a[3...5]))!, dv = Int(String(a[6...7]))!, dh = Int(String(a[8...9]))!
        return "Gebiet NW-Ecke \(lat)°\(q < 2 ? "N" : "S") \(String(format: "%03d", lon))°\(q % 2 == 0 ? "O" : "W"), \(dv)° nach Süden, \(dh)° nach Osten"
    }

    /// Frequenz/Kanal aus 6 Symbolen (12 Ziffern): MF/HF in 100-Hz-Schritten „ddddd.d[/ddddd.d]“ (kHz)
    static func frequency(_ syms: ArraySlice<Int>) -> String? {
        guard syms.count == 6 else { return nil }
        let d = digits(syms)
        guard let first = d.first else { return nil }
        switch first {
        case "0", "1", "2":
            let a = Array(d)
            guard !d.prefix(6).contains("_") else { return nil }
            let f1 = String(a[0..<5]) + "." + String(a[5])
            let rest = Array(syms)
            let f2 = rest[3...].allSatisfy { $0 > 99 } ? nil : String(a[6..<11]) + "." + String(a[11])
            return f2.map { "\(f1)/\($0)" } ?? f1
        case "3": return "Arbeitskanal \(d.dropFirst())"
        case "4": return "\(d) (10-Hz-Raster)"
        case "9" where d.dropFirst().first == "0": return "UKW-Kanal \(d)"
        default: return nil
        }
    }

    // MARK: Aufbau aus den Symbolen

    /// `symbols`: Formatspezifizierer (zweimal) bis Ende (EOS, ECC, EOS, EOS); ECC wird nicht geprüft (dazu `eccOK`)
    public static func parse(symbols s: [Int], receivedAt: Date = Date(), centerHz: Double = 1700, eccOK: Bool = true) -> DSCMessage {
        let fsValue = s.first(where: { $0 != -1 }) ?? -1
        var m = DSCMessage(receivedAt: receivedAt, centerHz: centerHz, symbols: s, format: Format(rawValue: fsValue) ?? .unknown,
                           eccOK: eccOK, unreadable: s.filter { $0 == -1 }.count)
        func at(_ i: Int) -> Int { i >= 0 && i < s.count ? s[i] : -1 }
        func sl(_ a: Int, _ n: Int) -> ArraySlice<Int> {
            let lo = max(0, min(a, s.count)), hi = max(lo, min(a + n, s.count))
            var r = Array(s[lo..<hi])
            while r.count < n { r.append(-1) }
            return r[...]
        }
        // Ende: erstes EOS-Symbol
        var eosIndex = s.indices.first(where: { $0 >= 3 && DSCSymbolCode.eosSymbols.contains(s[$0]) }) ?? -1
        if eosIndex == -1 { eosIndex = max(0, s.count - 4) }
        m.eos = eosName(at(eosIndex))
        m.ecc = at(eosIndex + 1) >= 0 ? at(eosIndex + 1) : nil

        switch m.format {
        case .distress:
            m.to = "ALLE SCHIFFE"
            m.category = "SEENOT"
            m.from = mmsi(sl(2, 5))
            m.nature = natureName(at(7)) ?? "Art \(at(7))"
            m.position = position(sl(8, 5))
            let t = digits(sl(13, 2))
            m.timeUTC = t.contains("_") ? nil : String(t.prefix(2)) + ":" + String(t.suffix(2))
            if let tc = firstCommandName(at(15)), at(15) != 126 { m.firstCommand = tc }
        case .allShips:
            m.to = "ALLE SCHIFFE"
            m.category = categoryName(at(2))
            m.from = mmsi(sl(3, 5))
            m.firstCommand = firstCommandName(at(8))
            m.secondCommand = secondCommandName(at(9))
            m.frequency = frequency(sl(10, 6))
            if m.firstCommand == "NOTRUF-QUITTUNG" || m.firstCommand == "NOTRUF-WEITERLEITUNG" { m.note = "Nutzdaten: Notruf-MMSI, Art, Position, Zeit" }
        case .individual:
            m.to = mmsi(sl(2, 5))
            m.category = categoryName(at(7))
            m.from = mmsi(sl(8, 5))
            m.firstCommand = firstCommandName(at(13))
            m.secondCommand = secondCommandName(at(14))
            switch at(15) {
            case 55: m.position = position(sl(16, 5))
            case 126: if m.firstCommand == "POSITIONSMELDUNG" { m.note = "Position erfragt" }
            default: m.frequency = frequency(sl(15, 6))
            }
        case .geographicArea:
            m.to = area(sl(2, 5)) ?? "Gebiet ?"
            m.category = categoryName(at(7))
            m.from = mmsi(sl(8, 5))
            m.firstCommand = firstCommandName(at(13))
            m.secondCommand = secondCommandName(at(14))
            m.frequency = frequency(sl(15, 6))
        case .group:
            m.to = mmsi(sl(2, 5))
            m.category = categoryName(at(7))
            m.from = mmsi(sl(8, 5))
            m.firstCommand = firstCommandName(at(13))
            m.secondCommand = secondCommandName(at(14))
            m.frequency = frequency(sl(15, 6))
        case .automatic:
            m.to = mmsi(sl(2, 5))
            m.category = categoryName(at(7))
            m.from = mmsi(sl(8, 5))
            m.note = "Halbautomatischer Dienst: Nutzdaten nicht gedeutet"
        case .unknown:
            m.note = "Formatspezifizierer nicht lesbar"
        }
        return m
    }
}

// MARK: - Rahmen: Bits → Rufe (Phasing, DX/RX, ECC)

/// Ein vollständig empfangener Ruf (Symbole ab Formatspezifizierer bis zum letzten EOS)
public struct DSCCall: Sendable, Equatable {
    public var symbols: [Int]
    public var eccOK: Bool
    public var unreadable: Int
}

/// Sucht im Bitstrom die Phasing-Folge (M.493 § 3: DX 125 und RX 111 … 104 abwechselnd), liest dann zeichenweise,
/// führt DX und RX (vier Zeichen später wiederholt) zusammen und prüft den ECC (gerade Längsparität).
public final class DSCFramer {
    private var bits: [UInt8] = []
    private var locked = false
    private var syms: [Int] = []          // alle Symbole ab dem ersten Phasing-Zeichen (-1 = Prüfbits falsch)
    private var pending: [UInt8] = []
    private var eosM: Int?
    private var junk = 0
    /// Zeichen im Phasing, die stimmen müssen (M.493: drei; hier etwas strenger gegen Fehlalarme)
    private let phasingMatchMinimum = 6

    private static let rxPhasing = [111, 110, 109, 108, 107, 106, 105, 104]

    public init() {}

    public var isLocked: Bool { locked }

    /// Nächstes Bit (1 = Y/tiefer Ton). Liefert einen Ruf, wenn einer fertig ist.
    public func push(_ bit: UInt8) -> DSCCall? {
        if !locked {
            bits.append(bit)
            if bits.count > 400 { bits.removeFirst(bits.count - 400) }
            guard bits.count >= 160 else { return nil }
            let window = bits.suffix(160)
            var decoded: [Int] = []
            var matches = 0, rxMatches = 0, dxMatches = 0
            let base = window.startIndex
            for i in 0..<16 {
                let v = DSCSymbolCode.decode(window[(base + 10 * i)..<(base + 10 * i + 10)]) ?? -1
                decoded.append(v)
                if i % 2 == 0 && i <= 10 && v == 125 { matches += 1; dxMatches += 1 }
                if i % 2 == 1 && v == Self.rxPhasing[i / 2] { matches += 1; rxMatches += 1 }
            }
            if matches >= phasingMatchMinimum && rxMatches >= 2 && dxMatches >= 2 {
                locked = true
                syms = decoded
                pending = []
                eosM = nil
                junk = 0
            }
            return nil
        }
        pending.append(bit)
        guard pending.count == 10 else { return nil }
        let v = DSCSymbolCode.decode(pending[...]) ?? -1
        pending = []
        syms.append(v)
        junk = v == -1 ? junk + 1 : 0
        if junk > 14 { reset(); return nil }

        let (dx, rx) = split()
        if eosM == nil {
            for m in 3..<max(3, dx.count) where DSCSymbolCode.eosSymbols.contains(dx[m]) { eosM = m; break }
            if eosM == nil {
                for m in 3..<max(3, rx.count) where DSCSymbolCode.eosSymbols.contains(rx[m]) { eosM = m; break }
            }
        }
        if syms.count > 12 + 2 * 70 { reset(); return nil }       // zu lang: kein Ruf
        if let e = eosM, syms.count > 2 * e + 23 {
            let call = finish(dx: dx, rx: rx, e: e)
            reset()
            return call
        }
        return nil
    }

    private func reset() {
        locked = false
        bits = []
        pending = []
        syms = []
        eosM = nil
    }

    /// Info-Symbol m: DX auf Platz 12 + 2m, Wiederholung RX auf Platz 17 + 2m
    private func split() -> (dx: [Int], rx: [Int]) {
        var dx: [Int] = [], rx: [Int] = []
        var i = 12
        while i < syms.count { dx.append(syms[i]); i += 2 }
        i = 17
        while i < syms.count { rx.append(syms[i]); i += 2 }
        return (dx, rx)
    }

    private func finish(dx: [Int], rx: [Int], e: Int) -> DSCCall {
        let last = e + 3                       // EOS, ECC, EOS, EOS
        var merged: [Int] = []
        var both: [Int] = []                   // Plätze, an denen DX und RX lesbar sind, aber verschieden
        for m in 0...last {
            let d = m < dx.count ? dx[m] : -1
            let r = m < rx.count ? rx[m] : -1
            if d != -1 { merged.append(d); if r != -1 && r != d { both.append(m) } } else { merged.append(r) }
        }
        func eccOK(_ s: [Int]) -> Bool {
            guard s.count > e + 1, !s[1...(e + 1)].contains(-1) else { return false }
            var x = 0
            for m in 1...e { x ^= s[m] }
            return x == s[e + 1]
        }
        var ok = eccOK(merged)
        if !ok && !both.isEmpty && both.count <= 8 {
            // Bei Widerspruch zwischen DX und RX die Wiederholung probieren, bis der ECC stimmt
            for mask in 1..<(1 << both.count) {
                var t = merged
                for (k, m) in both.enumerated() where mask & (1 << k) != 0 { t[m] = rx[m] }
                if eccOK(t) { merged = t; ok = true; break }
            }
        }
        return DSCCall(symbols: merged, eccOK: ok, unreadable: merged.filter { $0 == -1 }.count)
    }
}

// MARK: - Mitte nachführen

/// Findet das Tonpaar im Abstand 170 Hz (Goertzel über 4096 Abtastwerte, 5-Hz-Raster, 300 … 3500 Hz) und schlägt eine neue
/// Mitte vor, wenn sie zweimal hintereinander ähnlich gemessen wurde.
public struct DSCAutoTuner {
    public static let blockSize = 4096
    private var candidate: Double?

    public init() {}

    /// `measured`: Mitte des erkannten Tonpaars (nil = keins); `newCenter`: Mitte, auf die umgestellt werden soll
    public mutating func update(recent: [Float], current: Double) -> (measured: Double?, newCenter: Double?) {
        guard recent.count >= Self.blockSize else { return (nil, nil) }
        let x = recent.suffix(Self.blockSize)
        let step = 5.0, lo = 300.0, count = 640
        var power = [Double](repeating: 0, count: count)
        for k in 0..<count {
            let w = 2 * Double.pi * (lo + Double(k) * step) / DSCDemodulator.sampleRate
            let coeff = 2 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for v in x {
                let s0 = Double(v) + coeff * s1 - s2
                s2 = s1; s1 = s0
            }
            power[k] = s1 * s1 + s2 * s2 - coeff * s1 * s2
        }
        let half = Int((DSCDemodulator.shift / 2 / step).rounded())      // 17 Schritte = 85 Hz
        var best = 0.0, bestK = -1
        var mins: [Double] = []
        for k in half..<(count - half) {
            let m = min(power[k - half], power[k + half])
            mins.append(m)
            if m > best { best = m; bestK = k }
        }
        guard bestK >= 0 else { return (nil, nil) }
        let median = mins.sorted()[mins.count / 2]
        let floor = power.sorted()[count / 2]
        let a = power[bestK - half], b = power[bestK + half]
        // Rauschen liefert zufällig ein „bestes“ Paar: es muss deutlich über dem Rauschboden und über allen anderen Paaren liegen
        let valid = best > 8 * median && min(a, b) > 20 * floor && min(a, b) > 0.15 * max(a, b)
        guard valid else { candidate = nil; return (nil, nil) }
        // Jeder Ton hat eine Keule um seine Frequenz: Spitze mit parabolischer Interpolation (genauer als das Raster)
        func peak(_ around: Int) -> Double {
            var k = around, m = power[around]
            for d in -8...8 where around + d >= 1 && around + d < count - 1 && power[around + d] > m { m = power[around + d]; k = around + d }
            let l = power[k - 1], c = power[k], r = power[k + 1]
            let den = l - 2 * c + r
            let off = den == 0 ? 0 : 0.5 * (l - r) / den
            return lo + (Double(k) + max(-0.5, min(0.5, off))) * step
        }
        let fLow = peak(bestK - half), fHigh = peak(bestK + half)
        let freq = abs(fHigh - fLow - DSCDemodulator.shift) <= 20 ? (fLow + fHigh) / 2 : lo + Double(bestK) * step
        defer { candidate = freq }
        if let c = candidate, abs(c - freq) <= 6, abs(current - freq) >= 4 { return (freq, freq) }
        return (freq, nil)
    }
}

// MARK: - Zusammenführen der Taktlagen

/// Dieselbe Aussendung kommt aus mehreren Taktlagen mit unterschiedlicher Qualität. Rufe innerhalb von `window` Sekunden
/// gelten als dieselbe Aussendung; es bleibt der beste (ECC stimmt, wenig unlesbare Symbole). Stark beschädigte Rufe entfallen.
public struct DSCCallCollector {
    public var window = 3.5
    /// ECC falsch und mehr unlesbare Symbole als das: verwerfen
    public var maxUnreadable = 6
    private var staged: [(time: Double, call: DSCCall)] = []

    public init() {}

    private static func quality(_ c: DSCCall) -> Int { (c.eccOK ? 0 : 1000) + c.unreadable }

    public mutating func add(_ call: DSCCall, at time: Double) {
        if !call.eccOK && call.unreadable > maxUnreadable { return }
        if let i = staged.firstIndex(where: { abs($0.time - time) < window }) {
            if Self.quality(call) < Self.quality(staged[i].call) { staged[i] = (staged[i].time, call) }
            return
        }
        staged.append((time, call))
    }

    /// Rufe, deren Zeitfenster abgelaufen ist (`force`: alle, z. B. am Ende einer Datei)
    public mutating func take(now: Double, force: Bool = false) -> [DSCCall] {
        let ready = staged.filter { force || now - $0.time >= window }
        staged.removeAll { c in ready.contains { $0.time == c.time } }
        return ready.map(\.call)
    }
}

// MARK: - Demodulator: Audio (8 kHz) → Bits (100 Bd, mehrere Taktlagen)

/// FSK-Demodulator mit gleitender Integration über ein Bit (80 Abtastwerte) auf beiden Tönen. Die Taktlage ist unbekannt:
/// acht Bitströme mit je 10 Abtastwerten Versatz laufen parallel; der Rahmen-Suchlauf findet die brauchbaren.
public final class DSCDemodulator {
    public static let sampleRate = 8000.0
    public static let baud = 100.0
    public static let shift = 170.0
    public static let phases = 8
    private let spb = 80

    public var centerHz: Double { didSet { if centerHz != oldValue { retune() } } }
    /// Seitenband umgekehrt (LSB): Y und B vertauscht
    public var reversed = false

    private var phaseLo = 0.0, phaseHi = 0.0
    private var stepLo = 0.0, stepHi = 0.0
    private var ringLo: [(Double, Double)]
    private var ringHi: [(Double, Double)]
    private var sumLo = (0.0, 0.0), sumHi = (0.0, 0.0)
    private var n = 0
    /// Pegel der beiden Töne (gleitend), 0 … 1 relativ zum Gesamtpegel
    public private(set) var toneBalance = 0.0
    public private(set) var energy = 0.0

    public init(centerHz: Double = 1700) {
        self.centerHz = centerHz
        ringLo = Array(repeating: (0, 0), count: spb)
        ringHi = Array(repeating: (0, 0), count: spb)
        retune()
    }

    private func retune() {
        stepLo = 2 * .pi * (centerHz - Self.shift / 2) / Self.sampleRate
        stepHi = 2 * .pi * (centerHz + Self.shift / 2) / Self.sampleRate
    }

    /// Verarbeitet Abtastwerte; `onBit(phase, bit)` kommt je Taktlage einmal pro Bit
    public func process(_ samples: UnsafeBufferPointer<Float>, onBit: (Int, UInt8) -> Void) {
        for x in samples {
            let xv = Double(x)
            let zl = (xv * cos(phaseLo), -xv * sin(phaseLo))
            let zh = (xv * cos(phaseHi), -xv * sin(phaseHi))
            phaseLo += stepLo; if phaseLo > 2 * .pi { phaseLo -= 2 * .pi }
            phaseHi += stepHi; if phaseHi > 2 * .pi { phaseHi -= 2 * .pi }
            let slot = n % spb
            sumLo.0 += zl.0 - ringLo[slot].0; sumLo.1 += zl.1 - ringLo[slot].1
            sumHi.0 += zh.0 - ringHi[slot].0; sumHi.1 += zh.1 - ringHi[slot].1
            ringLo[slot] = zl
            ringHi[slot] = zh
            n += 1
            if n % 10 == 0 {
                let elo = sumLo.0 * sumLo.0 + sumLo.1 * sumLo.1
                let ehi = sumHi.0 * sumHi.0 + sumHi.1 * sumHi.1
                energy += ((elo + ehi) - energy) * 0.001
                let y = reversed ? ehi > elo : elo > ehi        // tiefer Ton = Y = 1
                onBit((n / 10) % Self.phases, y ? 1 : 0)
            }
        }
    }
}

// MARK: - Testsignal

/// DSC-Aussendung (nur für Tests, Digidec sendet nie): Punktmuster, Phasing, Informationssymbole mit Wiederholung, FSK 100 Bd
public enum DSCSignalGenerator {
    /// Symbole eines Rufs ab Formatspezifizierer (zweimal) bis EOS, ECC, EOS, EOS; ECC wird berechnet
    public static func call(format: Int, body: [Int], eos: Int = 127) -> [Int] {
        var s = [format, format] + body + [eos]
        var x = 0
        for v in s[1...] { x ^= v }
        s.append(x)
        s += [eos, eos]
        return s
    }

    /// Bitfolge: Punktmuster (alternierend, mit B beginnend), Phasing, Informationssymbole DX + RX
    public static func bits(info: [Int], dotBits: Int = 200) -> [UInt8] {
        var out: [UInt8] = (0..<dotBits).map { $0 % 2 == 0 ? 0 : 1 }
        let rxPhasing = [111, 110, 109, 108, 107, 106, 105, 104]
        let total = 12 + 2 * info.count + 5 + 2          // Platz 0 … letzter RX-Platz
        var slots = [Int](repeating: 125, count: total)
        for i in 0..<8 { slots[1 + 2 * i] = rxPhasing[i] }
        for (m, v) in info.enumerated() {
            slots[12 + 2 * m] = v
            if 17 + 2 * m < slots.count { slots[17 + 2 * m] = v }
        }
        // Freie DX-Plätze am Ende: letztes Zeichen (EOS)
        var i = 12 + 2 * info.count
        while i < slots.count { if i % 2 == 0 { slots[i] = info.last ?? 127 }; i += 2 }
        for v in slots { out += DSCSymbolCode.bits(for: v) }
        return out
    }

    /// FSK-Audio: B = höherer Ton, Y = tieferer Ton; Mitte `centerHz`; `lead`/`tail` Stille in Sekunden
    public static func audio(bits: [UInt8], centerHz: Double = 1700, sampleRate: Double = 8000, amplitude: Double = 0.5,
                             lead: Double = 0.5, tail: Double = 0.5, reversed: Bool = false) -> [Float] {
        let spb = Int(sampleRate / DSCDemodulator.baud)
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        var phase = 0.0
        for b in bits {
            let high = reversed ? b == 1 : b == 0
            let f = centerHz + (high ? 1 : -1) * DSCDemodulator.shift / 2
            for _ in 0..<spb {
                out.append(Float(amplitude * sin(phase)))
                phase += 2 * .pi * f / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }
        out += [Float](repeating: 0, count: Int(tail * sampleRate))
        return out
    }
}
