import Foundation

// ALE (Automatic Link Establishment, 2G) nach MIL-STD-188-141A/B Anhang A: 8-FSK, 125 Baud, Töne 750 … 2500 Hz im Abstand
// 250 Hz, ein Wort = 49 Symbole = 392 ms. Wort: 24 Bit (3 Bit Präambel + 3 × 7 Bit ASCII) → zwei Golay-(24,12)-Blöcke
// (Coder B mit invertierten Prüfbits) → 49 Bit verschachtelt (A/B abwechselnd) → dreifach wiederholt → 3 Bit je Symbol.
// Umsetzung nach der MIT-lizenzierten Referenz openALE (github.com/dl3hc/openALE, siehe Vendor/Ale/UPSTREAM_ALE.md).

// MARK: - Golay (24,12)

public enum ALEGolay {
    /// Prüfbits (12) zu den Einzelbits der Information (Bit 0 … 11), aus der Referenz; linear
    private static let basis: [UInt16] = [0x5C7, 0xB8D, 0x2DE, 0x5BC, 0xB78, 0x337, 0x66D, 0xCD9, 0xC76, 0xD2B, 0xF92, 0xAE3]

    public static func parity(_ info: UInt16) -> UInt16 {
        var p: UInt16 = 0
        for i in 0..<12 where info & (1 << i) != 0 { p ^= basis[i] }
        return p
    }

    /// 24-Bit-Codewort: Information in den oberen 12 Bit, Prüfbits unten
    public static func encode(_ info: UInt16) -> UInt32 { UInt32(info & 0xFFF) << 12 | UInt32(parity(info & 0xFFF)) }

    /// Syndrom → Fehlermuster (Gewicht ≤ 3); der erweiterte Golay-Code korrigiert 3 und erkennt 4 Fehler
    private static let syndromeTable: [UInt16: UInt32] = {
        var t: [UInt16: UInt32] = [0: 0]
        func add(_ e: UInt32) {
            let s = parity(UInt16(e >> 12)) ^ UInt16(e & 0xFFF)
            if t[s] == nil { t[s] = e }
        }
        for a in 0..<24 {
            add(1 << UInt32(a))
            for b in (a + 1)..<24 {
                add(1 << UInt32(a) | 1 << UInt32(b))
                for c in (b + 1)..<24 { add(1 << UInt32(a) | 1 << UInt32(b) | 1 << UInt32(c)) }
            }
        }
        return t
    }()

    /// Information und Zahl der korrigierten Fehler; nil = nicht korrigierbar
    public static func decode(_ word: UInt32) -> (info: UInt16, errors: Int)? {
        let info = UInt16((word >> 12) & 0xFFF)
        let s = parity(info) ^ UInt16(word & 0xFFF)
        guard let e = syndromeTable[s] else { return nil }
        return (info ^ UInt16(e >> 12), e.nonzeroBitCount)
    }
}

// MARK: - Wörter

public enum ALEPreamble: Int, Sendable, CaseIterable {
    case data = 0, thru, to, twas, from, tis, cmd, rep

    public var name: String { ["DATA", "THRU", "TO", "TWAS", "FROM", "TIS", "CMD", "REP"][rawValue] }
    /// DATA und REP tragen Text (Expanded 64), die übrigen Adressen (Basic 38); CMD enthält Befehlscodes
    var usesBasic38: Bool { self != .data && self != .rep }
}

public struct ALEWord: Sendable, Equatable {
    public var preamble: ALEPreamble
    public var chars: [UInt8]           // 3 Zeichen (7 Bit)
    /// Einstimmige Stimmen der 2-von-3-Mehrheit (0 … 48): 48 = fehlerfrei
    public var unanimous: Int
    public var golayErrors: Int
    /// Abtastwert-Index des Wortendes
    public var endSample: Int

    public var text: String {
        String(chars.map { Character(UnicodeScalar($0 >= 0x20 && $0 < 0x7F ? $0 : 0x2E)) })
    }
}

public enum ALECodec {
    public static let tonesHz: [Double] = [750, 1000, 1250, 1500, 1750, 2000, 2250, 2500]
    /// Töne (aufsteigend) → Symbolwert (Gray-codiert, A.5.1.2)
    public static let freqToSymbol: [Int] = [0, 1, 3, 2, 6, 7, 5, 4]
    public static let symbolToFreqIndex: [Int] = { var t = [Int](repeating: 0, count: 8); for (r, s) in freqToSymbol.enumerated() { t[s] = r }; return t }()

    // Zeichensätze: Basic 38 = A–Z, 0–9, „@“, „?“; Expanded 64 = 0x20 … 0x5F
    public static func isBasic38(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x40 || c == 0x3F
    }
    public static func isExpanded64(_ c: UInt8) -> Bool { c >= 0x20 && c < 0x60 }

    public static func word24(preamble: ALEPreamble, chars: [UInt8]) -> UInt32 {
        UInt32(preamble.rawValue) << 21 | UInt32(chars[0] & 0x7F) << 14 | UInt32(chars[1] & 0x7F) << 7 | UInt32(chars[2] & 0x7F)
    }

    /// 24-Bit-Wort → 49 übertragene Bit (A/B verschachtelt, Bit 48 = 0)
    public static func tx49(word24: UInt32) -> UInt64 {
        let a = ALEGolay.encode(UInt16((word24 >> 12) & 0xFFF))
        let lowerCode = ALEGolay.encode(UInt16(word24 & 0xFFF))
        let b = (lowerCode & 0xFFF000) | (~lowerCode & 0xFFF)            // Prüfbits von Coder B invertiert
        var out: UInt64 = 0
        for k in 0..<24 {
            if (a >> UInt32(23 - k)) & 1 != 0 { out |= 1 << UInt64(2 * k) }
            if (b >> UInt32(23 - k)) & 1 != 0 { out |= 1 << UInt64(2 * k + 1) }
        }
        return out
    }

    /// 49 Symbole (0 … 7): der Datenstrom ist dreimal dasselbe 49-Bit-Wort, Symbol k trägt die Bits 3k, 3k+1, 3k+2
    public static func symbols(word24: UInt32) -> [UInt8] {
        let t = tx49(word24: word24)
        return (0..<49).map { k in
            var s: UInt8 = 0
            for b in 0..<3 where (t >> UInt64((3 * k + b) % 49)) & 1 != 0 { s |= 1 << UInt8(2 - b) }
            return s
        }
    }

    /// Wort aus 49 Symbolen: Mehrheit je Bit, Golay beider Hälften, Zeichenprüfung. nil = kein gültiges Wort
    public static func decode(symbols s: ArraySlice<UInt8>, minUnanimous: Int = 36) -> (word24: UInt32, unanimous: Int, errors: Int)? {
        guard s.count == 49 else { return nil }
        let sy = Array(s)
        var t: UInt64 = 0
        var unanimous = 0
        for bit in 0..<48 {
            var ones = 0
            for copy in 0..<3 {
                let p = bit + copy * 49
                ones += Int((sy[p / 3] >> UInt8(2 - p % 3)) & 1)
            }
            if ones == 0 || ones == 3 { unanimous += 1 }
            if ones >= 2 { t |= 1 << UInt64(bit) }
        }
        guard unanimous >= minUnanimous else { return nil }
        var a: UInt32 = 0, b: UInt32 = 0
        for k in 0..<24 {
            if (t >> UInt64(2 * k)) & 1 != 0 { a |= 1 << UInt32(23 - k) }
            if (t >> UInt64(2 * k + 1)) & 1 != 0 { b |= 1 << UInt32(23 - k) }
        }
        let bNatural = (b & 0xFFF000) | (~b & 0xFFF)
        guard let up = ALEGolay.decode(a), let low = ALEGolay.decode(bNatural) else { return nil }
        let w = UInt32(up.info) << 12 | UInt32(low.info)
        let pre = ALEPreamble(rawValue: Int((w >> 21) & 7))!
        let chars = [UInt8((w >> 14) & 0x7F), UInt8((w >> 7) & 0x7F), UInt8(w & 0x7F)]
        if pre != .cmd {
            let ok = pre.usesBasic38 ? chars.allSatisfy(isBasic38) : chars.allSatisfy(isExpanded64)
            guard ok else { return nil }
        }
        return (w, unanimous, up.errors + low.errors)
    }

    public static func word(from w24: UInt32, unanimous: Int, errors: Int, endSample: Int) -> ALEWord {
        ALEWord(preamble: ALEPreamble(rawValue: Int((w24 >> 21) & 7))!,
                chars: [UInt8((w24 >> 14) & 0x7F), UInt8((w24 >> 7) & 0x7F), UInt8(w24 & 0x7F)],
                unanimous: unanimous, golayErrors: errors, endSample: endSample)
    }
}

// MARK: - Demodulator

/// Streaming-8-FSK-Demodulator bei 8 kHz: Die Symbolgrenze ist unbekannt, deshalb laufen 16 Taktlagen (4 Abtastwerte Versatz)
/// parallel; jede entscheidet je Symbol den stärksten der acht Töne (Goertzel über 64 Abtastwerte, orthogonal) und versucht bei
/// jedem neuen Symbol, die letzten 49 als Wort zu lesen.
public final class ALEDemodulator {
    public static let sampleRate = 8000.0
    public static let samplesPerSymbol = 64
    public static let phaseCount = 16
    private static let phaseStep = 4

    /// Verstimmung der Töne in Hz (Funkgerät oder Aufnahme nicht genau abgestimmt)
    public var offsetHz: Double { didSet { if offsetHz != oldValue { updateCoefficients() } } }
    /// Mindestzahl einstimmiger Bit (von 48) für ein gültiges Wort (36 = streng genug gegen Rauschen)
    public var minUnanimous = 36

    private var coeff = [Double](repeating: 0, count: 8)
    private var s1: [[Double]]      // [Phase][Ton]
    private var s2: [[Double]]
    private var history: [[UInt8]]  // je Taktlage die letzten Symbole
    private var n = 0
    /// Pegel des stärksten Tons (gleitend)
    public private(set) var level = 0.0
    /// Bester Rauschabstand-Ersatz: Anteil der Energie im Siegerton (gleitend, 0,125 … 1)
    public private(set) var purity = 0.0

    public init(offsetHz: Double = 0) {
        self.offsetHz = offsetHz
        s1 = Array(repeating: Array(repeating: 0, count: 8), count: Self.phaseCount)
        s2 = s1
        history = Array(repeating: [], count: Self.phaseCount)
        updateCoefficients()
    }

    private func updateCoefficients() {
        for k in 0..<8 { coeff[k] = 2 * cos(2 * .pi * (ALECodec.tonesHz[k] + offsetHz) / Self.sampleRate) }
    }

    /// Verarbeitet Abtastwerte; `onWord` bekommt jedes gelesene Wort (ein Wort kann in mehreren Taktlagen auftreten)
    public func process(_ samples: UnsafeBufferPointer<Float>, onWord: (ALEWord, Int) -> Void) {
        let sps = Self.samplesPerSymbol
        for x in samples {
            let v = Double(x)
            for p in 0..<Self.phaseCount {
                for k in 0..<8 {
                    let s0 = v + coeff[k] * s1[p][k] - s2[p][k]
                    s2[p][k] = s1[p][k]
                    s1[p][k] = s0
                }
            }
            n += 1
            // Fenster der Taktlage p endet, wenn (n - 4p) durch 64 teilbar ist
            for p in 0..<Self.phaseCount where (n - Self.phaseStep * p) >= sps && (n - Self.phaseStep * p) % sps == 0 {
                var best = 0, bestE = -1.0, total = 0.0
                for k in 0..<8 {
                    let e = s1[p][k] * s1[p][k] + s2[p][k] * s2[p][k] - coeff[k] * s1[p][k] * s2[p][k]
                    total += e
                    if e > bestE { bestE = e; best = k }
                    s1[p][k] = 0; s2[p][k] = 0
                }
                if p == 0 {
                    level += (sqrt(bestE) / Double(sps) - level) * 0.01
                    purity += ((total > 0 ? bestE / total : 0) - purity) * 0.02
                }
                var h = history[p]
                h.append(UInt8(ALECodec.freqToSymbol[best]))
                if h.count > 49 { h.removeFirst(h.count - 49) }
                history[p] = h
                if h.count == 49, let d = ALECodec.decode(symbols: h[...], minUnanimous: minUnanimous) {
                    onWord(ALECodec.word(from: d.word24, unanimous: d.unanimous, errors: d.errors, endSample: n), p)
                }
            }
        }
    }

    /// Alle Taktlagen leeren (z. B. nach einer Pause)
    public func resetHistory() {
        history = Array(repeating: [], count: Self.phaseCount)
    }
}

// MARK: - Wörter zusammenführen

/// Dasselbe Wort kommt aus mehreren benachbarten Taktlagen; es bleibt das mit den meisten einstimmigen Stimmen.
public struct ALEWordCollector {
    private var staged: [ALEWord] = []
    public init() {}

    public mutating func add(_ w: ALEWord) {
        if let i = staged.firstIndex(where: { abs($0.endSample - w.endSample) < 72 && $0.chars == w.chars && $0.preamble == w.preamble }) {
            if w.unanimous > staged[i].unanimous { staged[i] = w }
            return
        }
        staged.append(w)
    }

    /// Wörter, deren Ende mehr als `margin` Abtastwerte zurückliegt (dann kommt keine bessere Taktlage mehr)
    public mutating func take(now: Int, margin: Int = 80, force: Bool = false) -> [ALEWord] {
        let ready = staged.filter { force || now - $0.endSample > margin }.sorted { $0.endSample < $1.endSample }
        staged.removeAll { w in ready.contains { $0.endSample == w.endSample && $0.chars == w.chars && $0.preamble == w.preamble } }
        return ready
    }
}

// MARK: - Raster

/// Wörter einer Aussendung folgen im Abstand von genau 49 Symbolen. Um Fehlalarme zu vermeiden (ein um einige Symbole
/// verschobenes Fenster ergibt oft auch ein „gültiges“ Wort, weil der Datenstrom periodisch ist), gelten Wörter erst,
/// wenn sie ins Raster passen: Das erste Wort einer Aussendung muss sehr sauber sein und mit TO, TWAS, TIS, FROM oder THRU
/// beginnen; danach genügen weniger einstimmige Stimmen, solange der Abstand zum vorigen Wort ein Vielfaches (1 … 3) von
/// 3136 Abtastwerten ist. Nach mehr als drei Rasterschritten ohne Wort ist die Aussendung zu Ende.
public struct ALEGridTracker {
    public var lockedMinimum = 36
    public var firstMinimum = 44
    public var firstMaxErrors = 3
    private var lastEnd: Int?

    public init() {}

    public var isLocked: Bool { lastEnd != nil }

    /// Wörter in der Reihenfolge ihres Endes
    public mutating func accept(_ w: ALEWord) -> Bool {
        let step = ALEMessageBuilder.wordSamples
        if let last = lastEnd {
            let gap = w.endSample - last
            if gap > 3 * step + 80 { lastEnd = nil }
            else {
                let k = Int((Double(gap) / Double(step)).rounded())
                if k >= 1 && k <= 3 && abs(gap - k * step) <= 48 && w.unanimous >= lockedMinimum {
                    lastEnd = w.endSample
                    return true
                }
                return false
            }
        }
        let starts: Set<ALEPreamble> = [.to, .twas, .tis, .from, .thru]
        guard starts.contains(w.preamble), w.unanimous >= firstMinimum, w.golayErrors <= firstMaxErrors else { return false }
        lastEnd = w.endSample
        return true
    }

    /// Release, wenn lange kein Wort mehr kam
    public mutating func idle(now: Int) {
        if let last = lastEnd, now - last > 3 * ALEMessageBuilder.wordSamples + 80 { lastEnd = nil }
    }
}

// MARK: - Frequenzfehler messen

/// Entscheidungsgestützte Frequenznachführung: Von einem bekannten Wort sind alle 49 Töne bekannt. Je Symbol werden die
/// Energien 15 Hz über und unter dem Ton verglichen; das Verhältnis ist (bei kleinen Fehlern) linear im Frequenzfehler.
public enum ALEFrequencyError {
    private static let delta = 15.0

    private static func energy(_ x: ArraySlice<Float>, _ f: Double) -> Double {
        var re = 0.0, im = 0.0
        var ph = 0.0
        let step = 2 * Double.pi * f / ALEDemodulator.sampleRate
        for v in x { re += Double(v) * cos(ph); im -= Double(v) * sin(ph); ph += step }
        return re * re + im * im
    }

    /// Verhältnis (E+ − E−)/(E+ + E−) für einen reinen Ton mit Fehler `eps` (Kalibrierkurve)
    private static let curve: [(eps: Double, r: Double)] = {
        var out: [(Double, Double)] = []
        let n = 64
        for e in stride(from: -50.0, through: 50.0, by: 5.0) {
            let f = 1500.0
            let x = (0..<n).map { Float(sin(2 * .pi * (f + e) * Double($0) / ALEDemodulator.sampleRate)) }
            let ep = energy(x[...], f + delta), em = energy(x[...], f - delta)
            out.append((e, (ep - em) / (ep + em)))
        }
        return out
    }()

    /// Fehler in Hz (positiv: Signal liegt höher als angenommen); nil bei zu wenig Signal
    /// `samples`: Abtastwerte ab Wortbeginn (mindestens 3136), `symbols`: die 49 bekannten Symbole, `offset`: aktuell angenommene Verstimmung
    public static func estimate(samples: [Float], symbols: [UInt8], offset: Double) -> Double? {
        guard samples.count >= 49 * 64, symbols.count == 49 else { return nil }
        var sum = 0.0
        var used = 0
        for k in 0..<49 {
            let f = ALECodec.tonesHz[ALECodec.symbolToFreqIndex[Int(symbols[k])]] + offset
            let w = samples[(k * 64)..<(k * 64 + 64)]
            let ep = energy(w, f + delta), em = energy(w, f - delta)
            if ep + em > 1e-9 { sum += (ep - em) / (ep + em); used += 1 }
        }
        guard used >= 30 else { return nil }
        let r = sum / Double(used)
        // Kurve umkehren (monoton im Bereich ±50 Hz)
        let c = curve
        if r <= c.first!.r { return c.first!.eps }
        if r >= c.last!.r { return c.last!.eps }
        for i in 1..<c.count where r <= c[i].r {
            let a = c[i - 1], b = c[i]
            return a.eps + (b.eps - a.eps) * (r - a.r) / (b.r - a.r)
        }
        return nil
    }
}

// MARK: - Aussendungen

/// Eine Aussendung: aufeinanderfolgende Wörter im Raster von 392 ms. Adressen: erstes Wort TO/TIS/TWAS/FROM/THRU, Fortsetzungen
/// abwechselnd DATA und REP (je 3 Zeichen, „@“ füllt auf; REP nach einem einzelnen Wort beginnt einen neuen Empfänger).
public struct ALEMessage: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var receivedAt: Date
    public var words: [ALEWord]
    public var offsetHz: Double

    public static func == (a: ALEMessage, b: ALEMessage) -> Bool { a.id == b.id }

    /// Ein Eintrag der Wortfolge: Präambel und zusammengesetzte Adresse oder Text
    public struct Part: Sendable, Equatable {
        public var preamble: ALEPreamble
        public var text: String
    }

    public var quality: Int { words.map(\.unanimous).min() ?? 0 }
    public var meanErrors: Double { words.isEmpty ? 0 : Double(words.map(\.golayErrors).reduce(0, +)) / Double(words.count) }

    /// Adressen und Texte in Reihenfolge. Adresse: erstes Wort TO/TIS/TWAS/FROM/THRU, dann DATA, REP, DATA … (je 3 Zeichen);
    /// ein REP direkt nach dem ersten Wort beginnt einen weiteren Empfänger. Wörter ohne laufende Adresse (nach CMD) sind Text.
    public var parts: [Part] {
        var out: [Part] = []
        var addr: Int?              // Index der laufenden Adresse in `out`
        var addrWords = 0
        var anchor = ALEPreamble.to
        var text: Int?              // Index des laufenden Textes
        func chunk(_ w: ALEWord) -> String { w.text }
        for w in words {
            switch w.preamble {
            case .to, .tis, .twas, .from, .thru:
                out.append(Part(preamble: w.preamble, text: chunk(w)))
                addr = out.count - 1; addrWords = 1; anchor = w.preamble; text = nil
            case .data, .rep:
                if let a = addr {
                    if w.preamble == .rep && addrWords == 1 {
                        out.append(Part(preamble: anchor, text: chunk(w)))
                        addr = out.count - 1; addrWords = 1
                    } else {
                        out[a].text += chunk(w)
                        addrWords += 1
                    }
                } else if let t = text {
                    out[t].text += chunk(w)
                } else {
                    out.append(Part(preamble: .data, text: chunk(w)))
                    text = out.count - 1
                }
            case .cmd:
                out.append(Part(preamble: .cmd, text: chunk(w)))
                addr = nil; text = nil
            }
        }
        return out.map { p in
            var q = p
            if p.preamble != .data && p.preamble != .rep && p.preamble != .cmd {
                q.text = String(p.text.reversed().drop(while: { $0 == "@" || $0 == " " }).reversed())
            }
            return q
        }
    }

    public func addresses(_ pre: ALEPreamble) -> [String] { parts.filter { $0.preamble == pre }.map(\.text) }

    /// „ANRUF“, „SOUNDING“, „ANTWORT“ …
    public var kind: String {
        let types = Set(words.map(\.preamble))
        if types.contains(.cmd) { return types.contains(.data) || types.contains(.rep) ? "NACHRICHT" : "BEFEHL" }
        if types.contains(.to) && types.contains(.tis) { return "ANRUF" }
        if types.contains(.to) && types.contains(.twas) { return "ABSCHLUSS" }
        if types.contains(.twas) { return "SOUNDING" }
        if types.contains(.tis) { return "KENNUNG" }
        if types.contains(.to) { return "RUF AN" }
        if types.contains(.data) || types.contains(.rep) { return "DATEN" }
        return "ALE"
    }

    public var summary: String {
        parts.map { p in
            switch p.preamble {
            case .data, .rep: return "„\(p.text)“"
            case .cmd: return "CMD \(p.text)"
            default: return "\(p.preamble.name) \(p.text)"
            }
        }.joined(separator: " · ")
    }
}

/// Fasst Wörter im 392-ms-Raster zu Aussendungen zusammen
public struct ALEMessageBuilder {
    public static let wordSamples = 49 * ALEDemodulator.samplesPerSymbol
    private var current: [ALEWord] = []

    public init() {}

    /// Neues Wort (nach Endzeit sortiert). Liefert die vorige Aussendung, wenn das Wort nicht mehr dazugehört.
    public mutating func add(_ w: ALEWord, offsetHz: Double, now: Date = Date()) -> ALEMessage? {
        var done: ALEMessage?
        if let last = current.last, w.endSample - last.endSample > Self.wordSamples + 400 {
            done = ALEMessage(receivedAt: now, words: current, offsetHz: offsetHz)
            current = []
        }
        current.append(w)
        return done
    }

    /// Aussendung abschließen, wenn seit dem letzten Wort mehr als ein Rasterschritt vergangen ist
    public mutating func flush(nowSample: Int, offsetHz: Double, force: Bool = false, now: Date = Date()) -> ALEMessage? {
        guard let last = current.last, force || nowSample - last.endSample > Self.wordSamples + 400 else { return nil }
        let m = ALEMessage(receivedAt: now, words: current, offsetHz: offsetHz)
        current = []
        return m
    }
}

// MARK: - Testsignal

/// ALE-Aussendung (nur für Tests, Digidec sendet nie): Wörter als 8-FSK mit stetiger Phase
public enum ALESignalGenerator {
    public static func words(address first: ALEPreamble, _ address: String) -> [(ALEPreamble, [UInt8])] {
        var chunks: [[UInt8]] = []
        var bytes = Array(address.uppercased().utf8)
        if bytes.isEmpty { bytes = [0x40] }
        while bytes.count % 3 != 0 { bytes.append(0x40) }
        for i in stride(from: 0, to: bytes.count, by: 3) { chunks.append(Array(bytes[i..<(i + 3)])) }
        var out: [(ALEPreamble, [UInt8])] = []
        for (i, c) in chunks.enumerated() {
            out.append((i == 0 ? first : (i % 2 == 1 ? .data : .rep), c))
        }
        return out
    }

    public static func audio(words: [(ALEPreamble, [UInt8])], offsetHz: Double = 0, amplitude: Double = 0.5, sampleRate: Double = 8000,
                             lead: Double = 0.4, tail: Double = 0.4) -> [Float] {
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        var phase = 0.0
        for (pre, chars) in words {
            for s in ALECodec.symbols(word24: ALECodec.word24(preamble: pre, chars: chars)) {
                let f = ALECodec.tonesHz[ALECodec.symbolToFreqIndex[Int(s)]] + offsetHz
                for _ in 0..<Int(sampleRate / 125) {
                    out.append(Float(amplitude * sin(phase)))
                    phase += 2 * .pi * f / sampleRate
                    if phase > 2 * .pi { phase -= 2 * .pi }
                }
            }
        }
        out += [Float](repeating: 0, count: Int(tail * sampleRate))
        return out
    }
}
