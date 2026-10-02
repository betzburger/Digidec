import Foundation

// MARK: - BCH(31,21) mit Paritätsbit (POCSAG und FLEX)

/// Prüfung und Korrektur von Codewörtern: 21 Informationsbits, 10 BCH-Prüfbits (x¹⁰+x⁹+x⁸+x⁶+x⁵+x³+1), 1 gerades Paritätsbit.
/// Korrigiert bis zu zwei Bitfehler.
public enum PagerBCH {
    static let generator: UInt32 = 0x769

    /// Rest der Polynomdivision der 31 Bits (ohne Parität)
    static func remainder(_ word31: UInt32) -> UInt32 {
        var r = word31
        for i in stride(from: 30, through: 10, by: -1) where r & (1 << UInt32(i)) != 0 {
            r ^= generator << UInt32(i - 10)
        }
        return r & 0x3FF
    }

    /// Codewort aus 21 Informationsbits (Bit 20 = Flag): BCH und gerade Parität anhängen
    public static func encode(_ data21: UInt32) -> UInt32 {
        let d = data21 << 10
        let w31 = d | remainder(d)
        let parity = UInt32(w31.nonzeroBitCount & 1)
        return (w31 << 1) | parity
    }

    /// Fehlermuster (31 Bit) zu jedem Syndrom bei einem oder zwei Fehlern
    private static let table: [UInt32: UInt32] = {
        var t: [UInt32: UInt32] = [:]
        for i in 0..<31 {
            let e1 = UInt32(1) << UInt32(i)
            t[remainder(e1)] = t[remainder(e1)] ?? e1
        }
        for i in 0..<31 {
            for j in (i + 1)..<31 {
                let e = (UInt32(1) << UInt32(i)) | (UInt32(1) << UInt32(j))
                let s = remainder(e)
                if t[s] == nil { t[s] = e }
            }
        }
        return t
    }()

    /// Prüft und korrigiert ein 32-Bit-Codewort. Rückgabe: Wort (mit korrigierten Bits) und Zahl der korrigierten Bits;
    /// nil, wenn nicht korrigierbar (mehr als zwei Fehler oder Parität widerspricht der Korrektur).
    public static func correct(_ word: UInt32) -> (word: UInt32, errors: Int)? {
        let w31 = word >> 1
        let s = remainder(w31)
        if s == 0 {
            let parityOK = UInt32(w31.nonzeroBitCount & 1) == (word & 1)
            // nur das Paritätsbit war falsch: richtigstellen
            return (parityOK ? word : (w31 << 1) | UInt32(w31.nonzeroBitCount & 1), parityOK ? 0 : 1)
        }
        guard let e = table[s] else { return nil }
        let fixed = w31 ^ e
        let n = e.nonzeroBitCount
        let parityOK = UInt32(fixed.nonzeroBitCount & 1) == (word & 1)
        // Zwei korrigierte Bits plus falsche Parität wären drei Fehler: ablehnen
        if n == 2 && !parityOK { return nil }
        return ((fixed << 1) | UInt32(fixed.nonzeroBitCount & 1), n + (parityOK ? 0 : 1))
    }
}

// MARK: - POCSAG

public enum POCSAG {
    public static let sync: UInt32 = 0x7CD2_15D8
    public static let idle: UInt32 = 0x7A89_C197
    public static let rates = [512, 1200, 2400]

    /// Ziffern des Rufs (4 Bit, höchstwertiges Bit zuerst gelesen): „0 8 4 Leer 2 . 6 ] 1 9 5 - 3 U 7 [“
    static let numericTable = Array("084 2.6]195-3U7[")

    /// Zeichen < 0x20 und 0x7F, lesbar dargestellt
    static func printable(_ c: UInt8) -> String? {
        switch c {
        case 0x20...0x7E: return String(UnicodeScalar(c))
        case 0x0A: return "\n"
        case 0x0D: return ""
        case 0x00: return nil          // Füllzeichen
        default: return nil
        }
    }
}

/// Eine empfangene Funkrufmeldung
public struct PagerMessage: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var time: Date
    /// „POCSAG 1200“, „FLEX 1600“
    public var protocolName: String
    /// Rufnummer (RIC bei POCSAG, Capcode bei FLEX)
    public var address: Int
    public var function: Int
    /// Ziffernfolge (bei Funktion 0 üblich)
    public var numeric: String
    /// Klartext (7-Bit-ASCII)
    public var alpha: String
    /// Korrigierte Bitfehler
    public var corrected: Int
    /// Nicht korrigierbare Codewörter innerhalb der Meldung
    public var damaged: Int
    /// FLEX: Rahmennummer und Zyklus, „02.045“
    public var detail: String?

    public init(time: Date, protocolName: String, address: Int, function: Int, numeric: String, alpha: String,
                corrected: Int = 0, damaged: Int = 0, detail: String? = nil) {
        self.time = time
        self.protocolName = protocolName
        self.address = address
        self.function = function
        self.numeric = numeric
        self.alpha = alpha
        self.corrected = corrected
        self.damaged = damaged
        self.detail = detail
    }

    public static func == (a: PagerMessage, b: PagerMessage) -> Bool { a.id == b.id }

    /// Anteil lesbarer Zeichen im Klartext
    private var alphaQuality: Double {
        guard !alpha.isEmpty else { return 0 }
        let good = alpha.unicodeScalars.filter { ($0.value >= 0x20 && $0.value < 0x7F) || $0 == "\n" }.count
        return Double(good) / Double(alpha.unicodeScalars.count)
    }

    /// Was angezeigt wird: Funktion 0 → Ziffern, sonst Klartext; bei unlesbarem Klartext die Ziffern
    public var text: String {
        if function == 0 { return numeric.isEmpty ? alpha : numeric }
        if alpha.isEmpty { return numeric }
        return alphaQuality >= 0.8 ? alpha : (numeric.isEmpty ? alpha : numeric)
    }

    /// Die andere Lesart (für den Tooltip)
    public var alternative: String? {
        let main = text
        if main == numeric, !alpha.isEmpty { return "Klartext: " + alpha }
        if main == alpha, !numeric.isEmpty { return "Ziffern: " + numeric }
        return nil
    }
}

/// Setzt Codewörter zu Meldungen zusammen: Adresswort beginnt, Nachrichtenwörter hängen an, Adress- oder Leerwort beendet
struct POCSAGMessageBuilder {
    private var active = false
    private var address = 0
    private var function = 0
    private var bits: [UInt8] = []
    private var corrected = 0
    private var damaged = 0
    private var started = Date()

    /// Ein Codewort verarbeiten. `frame` = Rahmen 0…7 im Stapel. Liefert eine fertige Meldung, wenn sie hier endet.
    mutating func push(word: UInt32?, errors: Int, frame: Int, rate: Int, now: Date) -> PagerMessage? {
        guard let word else {
            if active { damaged += 1; bits += [UInt8](repeating: 0, count: 20) }
            return nil
        }
        if word == POCSAG.idle {
            return finish(rate: rate)
        }
        if word & 0x8000_0000 == 0 {
            // Adresswort: vorherige Meldung abschließen, neue beginnen
            let done = finish(rate: rate)
            active = true
            address = Int((word >> 13) & 0x3FFFF) << 3 | frame
            function = Int((word >> 11) & 3)
            bits.removeAll(keepingCapacity: true)
            corrected = errors
            damaged = 0
            started = now
            return done
        }
        guard active else { return nil }
        corrected += errors
        let data = (word >> 11) & 0xFFFFF
        for i in stride(from: 19, through: 0, by: -1) { bits.append(UInt8((data >> UInt32(i)) & 1)) }
        return nil
    }

    /// Übertragung zu Ende (Synchronisation verloren)
    mutating func flush(rate: Int) -> PagerMessage? { finish(rate: rate) }

    private mutating func finish(rate: Int) -> PagerMessage? {
        guard active else { return nil }
        active = false
        defer { bits.removeAll(keepingCapacity: true) }
        // Zufallstreffer (falsch synchronisierte Baudrate, Rauschen): überwiegend unlesbare oder stark „korrigierte“ Wörter
        let words = bits.count / 20
        if damaged > 0 && damaged * 2 >= words { return nil }
        if corrected > max(3, words) { return nil }
        // Ein reiner Ruf ohne Text muss fehlerfrei sein: sonst ist es meist ein Zufallstreffer
        if words == 0 && corrected > 0 { return nil }
        // Ziffern: 4 Bit je Zeichen, MSB zuerst gelesen
        var num = ""
        var i = 0
        while i + 4 <= bits.count {
            let n = Int(bits[i]) << 3 | Int(bits[i + 1]) << 2 | Int(bits[i + 2]) << 1 | Int(bits[i + 3])
            num.append(POCSAG.numericTable[n])
            i += 4
        }
        // Klartext: 7 Bit je Zeichen, das zuerst gesendete Bit ist das niedrigstwertige
        var text = ""
        i = 0
        while i + 7 <= bits.count {
            var c: UInt8 = 0
            for k in 0..<7 { c |= bits[i + k] << UInt8(k) }
            if let s = POCSAG.printable(c) { text += s }
            else if c != 0 { text += "·" }
            i += 7
        }
        // Zifferndarstellung: abschließende Leerstellen (Füllung) abschneiden
        while num.hasSuffix(" ") { num.removeLast() }
        while text.hasSuffix("·") { text.removeLast() }
        return PagerMessage(time: started, protocolName: "POCSAG \(rate)", address: address, function: function,
                            numeric: num, alpha: text, corrected: corrected, damaged: damaged)
    }
}

/// Holt aus einem Bitstrom Synchronwort, Stapel und Meldungen (eine Baudrate, beide Polaritäten)
struct POCSAGFramer {
    let rate: Int
    private var shift: UInt32 = 0
    private var inverted = false
    private var synced = false
    private var wordBits = 0
    private var word: UInt32 = 0
    private var wordIndex = 0         // 0…16: 0 = Synchronwort erwartet
    private var builder = POCSAGMessageBuilder()
    private var holdOff = 0
    /// Meldungen des laufenden Stapels: erst nach der Stapelprüfung ausgeben
    private var queued: [PagerMessage] = []
    private var validWords = 0

    init(rate: Int) { self.rate = rate }

    var isSynced: Bool { synced }

    /// Bit hereingeben; `emit` für jede fertige Meldung
    mutating func push(_ rawBit: Int, now: Date, emit: (PagerMessage) -> Void) {
        let bit = inverted ? 1 - rawBit : rawBit
        shift = (shift << 1) | UInt32(bit)
        if holdOff > 0 { holdOff -= 1 }
        if !synced {
            // Synchronwort in beiden Polaritäten, bis zu zwei Bitfehler
            let d = (shift ^ POCSAG.sync).nonzeroBitCount
            let di = (shift ^ ~POCSAG.sync).nonzeroBitCount
            if d <= 2 || di <= 2 {
                if di < d { inverted.toggle(); shift = ~shift }
                synced = true
                wordBits = 0
                word = 0
                wordIndex = 1
            }
            return
        }
        word = (word << 1) | UInt32(bit)
        wordBits += 1
        guard wordBits == 32 else { return }
        wordBits = 0
        defer { word = 0 }
        if wordIndex == 0 {
            // Synchronwort des nächsten Stapels
            if (word ^ POCSAG.sync).nonzeroBitCount <= 4 {
                wordIndex = 1
                validWords = 0
            } else {
                // Kein Synchronwort: Übertragung zu Ende (Stille liest sich sonst als Nullwörter)
                if let m = builder.flush(rate: rate) { queued.append(m) }
                for m in queued { emit(m) }
                queued.removeAll()
                synced = false
                shift = 0
            }
            return
        }
        let frame = (wordIndex - 1) / 2
        // Konstante Wörter (Stille oder Rauschen am Pegelrand) sind keine Daten, obwohl 0 ein gültiges Codewort ist
        let fixed = (word == 0 || word == 0xFFFF_FFFF) ? nil : PagerBCH.correct(word)
        if fixed != nil { validWords += 1 }
        // Adresswörter mit zwei korrigierten Bits sind zu unsicher (falsche Rufnummern aus Rauschen)
        var usable = fixed
        if let f = fixed, f.errors >= 2, f.word & 0x8000_0000 == 0, f.word != POCSAG.idle { usable = nil }
        if let m = builder.push(word: usable?.word, errors: usable?.errors ?? 0, frame: frame, rate: rate, now: now) { queued.append(m) }
        wordIndex += 1
        if wordIndex > 16 {
            wordIndex = 0
            // Stapelprüfung: bei Rauschen sind rund ein Viertel aller Zufallswörter „korrigierbar“; ein echter Stapel hat fast alle
            if validWords >= 10 {
                for m in queued { emit(m) }
                queued.removeAll()
            } else {
                queued.removeAll()
                builder = POCSAGMessageBuilder()
                synced = false
                shift = 0
            }
        }
    }

    /// Angefangene Meldung ausgeben (Ende der Aufnahme)
    mutating func flushMessage() -> [PagerMessage] {
        var out = queued
        queued.removeAll()
        if let m = builder.flush(rate: rate) { out.append(m) }
        return out
    }

    mutating func reset() {
        shift = 0
        synced = false
        inverted = false
        wordBits = 0
        wordIndex = 0
        builder = POCSAGMessageBuilder()
        queued.removeAll()
        validWords = 0
    }
}

// MARK: - Demodulator (NRZ-Basisband aus dem FM-Diskriminator)

/// Wandelt Audio in Bits: Tiefpass, Schwelle aus dem laufenden Mittelwert, Taktrückgewinnung auf den Nulldurchgängen
final class PagerBitSlicer {
    let sampleRate: Double
    let baud: Double
    private var lp: Float = 0
    private let lpCoef: Float
    private var mean: Float = 0
    private let meanCoef: Float
    private var pll: Int32 = 0
    private let step: Int32
    private var lastRaw = false
    private var locked = 0
    private var samples = 0
    private var peak: Float = 0
    private var stepPeak: Float = 0
    private let peakDecay: Float
    private var state = false
    /// Kanten erkennen statt Pegel: Verlauf der letzten Abtastwerte
    private var history: [Float]
    private var historyIndex = 0
    private let edgeSpan: Int
    private(set) var level: Float = 0

    init(sampleRate: Double, baud: Double) {
        self.sampleRate = sampleRate
        self.baud = baud
        // Tiefpass bei etwa 0,7·Baudrate; Schwelle = langsamer Mittelwert (wechselstromgekoppeltes Audio hat 0, Gleichstrom-Versatz folgt)
        lpCoef = Float(1 - exp(-2 * .pi * 0.7 * baud / sampleRate))
        meanCoef = Float(1 - exp(-1 / (max(0.1 * sampleRate, 48 * sampleRate / baud))))
        step = Int32(truncatingIfNeeded: Int64((4_294_967_296.0 * baud / sampleRate).rounded()))
        peakDecay = Float(1 - exp(-1 / (0.4 * sampleRate)))
        edgeSpan = max(2, Int((0.4 * sampleRate / baud).rounded()))
        history = [Float](repeating: 0, count: edgeSpan)
    }

    /// Verarbeitet einen Block; `bit` je Takt
    func process(_ block: UnsafeBufferPointer<Float>, bit: (Int) -> Void) {
        for x in block {
            samples += 1
            lp += lpCoef * (x - lp)
            mean += meanCoef * (lp - mean)
            level += 0.0005 * (abs(lp - mean) - level)
            // Entscheider: Ist der Pegel deutlich von der Schwelle weg, entscheidet das Vorzeichen. Bei Wechselstromkopplung sinkt
            // der Pegel nach einer langen Folge gleicher Bits gegen Null, die Information steckt dann nur noch in den Sprüngen:
            // im unsicheren Bereich setzt ein Sprung nach oben „1“, einer nach unten „0“.
            let d = lp - mean
            let delta = lp - history[historyIndex]
            history[historyIndex] = lp
            historyIndex = historyIndex + 1 == edgeSpan ? 0 : historyIndex + 1
            let a = abs(d)
            if a > peak { peak += 0.2 * (a - peak) } else { peak -= peakDecay * peak }
            let sa = abs(delta)
            if sa > stepPeak { stepPeak += 0.2 * (sa - stepPeak) } else { stepPeak -= peakDecay * stepPeak }
            if a >= 0.3 * peak {
                state = d > 0
            } else if delta > 0.6 * stepPeak && stepPeak > 0.2 * peak {
                state = true
            } else if delta < -0.6 * stepPeak && stepPeak > 0.2 * peak {
                state = false
            }
            let raw = state
            let previous = pll
            pll = previous &+ step
            if raw != lastRaw {
                pll = Int32(Double(pll) * (locked > 0 ? 0.70 : 0.45))
                if locked > 0 { locked -= 1 }
            }
            lastRaw = raw
            if pll < 0 && previous >= 0 { bit(raw ? 1 : 0) }
        }
    }

    func markLocked() { locked = 64 }

    func reset() {
        lp = 0; mean = 0; pll = 0; lastRaw = false; locked = 0; level = 0; peak = 0; stepPeak = 0; state = false
        history = [Float](repeating: 0, count: edgeSpan); historyIndex = 0
    }
}

/// POCSAG 512, 1200 und 2400 gleichzeitig
public final class POCSAGReceiver {
    public let sampleRate: Double
    private var slicers: [PagerBitSlicer]
    private var framers: [POCSAGFramer]
    public private(set) var synced: [Bool]
    /// Zuletzt gute Meldung: andere Baudraten mit zweifelhaften Meldungen werden danach kurz ignoriert
    private var lastGood: (rate: Int, sample: Int)?
    private var sampleCount = 0

    public init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
        slicers = POCSAG.rates.map { PagerBitSlicer(sampleRate: sampleRate, baud: Double($0)) }
        framers = POCSAG.rates.map { POCSAGFramer(rate: $0) }
        synced = [false, false, false]
    }

    /// Welche Baudraten sind eingeschaltet (Index in `POCSAG.rates`)
    public var enabled: Set<Int> = [0, 1, 2]

    public var level: Double { Double(slicers.map(\.level).max() ?? 0) }

    /// Angefangene Meldungen ausgeben (z. B. am Ende einer Datei)
    public func flush(emit: (PagerMessage) -> Void) {
        for i in framers.indices { for m in framers[i].flushMessage() { emit(m) } }
    }

    public func reset() {
        slicers.forEach { $0.reset() }
        for i in framers.indices { framers[i].reset() }
        synced = [false, false, false]
    }

    public func process(_ block: UnsafeBufferPointer<Float>, now: Date = Date(), emit: (PagerMessage) -> Void) {
        for i in slicers.indices where enabled.contains(i) {
            slicers[i].process(block) { bit in
                framers[i].push(bit, now: now) { m in
                    let clean = m.damaged == 0 && m.corrected == 0 && !(m.alpha.isEmpty && m.numeric.isEmpty)
                    if clean { lastGood = (POCSAG.rates[i], sampleCount) }
                    // falsche Baudrate neben einer gerade gelesenen guten Meldung: nur makellose Meldungen zulassen
                    if let g = lastGood, g.rate != POCSAG.rates[i], Double(sampleCount - g.sample) < 3 * sampleRate, !clean { return }
                    emit(m)
                }
                if framers[i].isSynced { slicers[i].markLocked() }
            }
            synced[i] = framers[i].isSynced
        }
        sampleCount += block.count
    }
}

// MARK: - Testsignal

public enum POCSAGSignalGenerator {
    /// Bits eines POCSAG-Aufrufs: Vorspann, Stapel mit Synchronwort, Adress- und Nachrichtenwörtern, Leerwörter
    public static func bits(address: Int, function: Int, numeric: String? = nil, alpha: String? = nil, preamble: Int = 576) -> [UInt8] {
        var data: [UInt32] = []   // Nachrichtenwörter (21 Bit, Flag gesetzt)
        var msgBits: [UInt8] = []
        if let numeric {
            for ch in numeric {
                let n = POCSAG.numericTable.firstIndex(of: ch) ?? 3
                for k in stride(from: 3, through: 0, by: -1) { msgBits.append(UInt8((n >> k) & 1)) }
            }
        } else if let alpha {
            for u in alpha.utf8 { for k in 0..<7 { msgBits.append((u >> UInt8(k)) & 1) } }
        }
        while msgBits.count % 20 != 0 { msgBits.append(0) }
        for w in stride(from: 0, to: msgBits.count, by: 20) {
            var v: UInt32 = 1 << 20
            for k in 0..<20 { v |= UInt32(msgBits[w + k]) << UInt32(19 - k) }
            data.append(v)
        }
        let frame = address & 7
        var words: [UInt32] = []
        // Rahmen vor der Zieladresse mit Leerwörtern füllen
        for _ in 0..<(frame * 2) { words.append(POCSAG.idle) }
        let addr = (UInt32((address >> 3) & 0x3FFFF) << 2) | UInt32(function & 3)
        words.append(PagerBCH.encode(addr))
        for d in data { words.append(PagerBCH.encode(d)) }
        while words.count % 16 != 0 { words.append(POCSAG.idle) }
        var out: [UInt8] = []
        for i in 0..<preamble { out.append(UInt8(i & 1 == 0 ? 1 : 0)) }
        for b in stride(from: 0, to: words.count, by: 16) {
            for k in stride(from: 31, through: 0, by: -1) { out.append(UInt8((POCSAG.sync >> UInt32(k)) & 1)) }
            for w in words[b..<(b + 16)] { for k in stride(from: 31, through: 0, by: -1) { out.append(UInt8((w >> UInt32(k)) & 1)) } }
        }
        return out
    }

    /// NRZ-Audio (±`amplitude`) mit schwach gerundeten Flanken, wie nach dem Diskriminator
    public static func audio(bits: [UInt8], baud: Int, sampleRate: Double = 24_000, amplitude: Float = 0.5,
                             inverted: Bool = false, baudError: Double = 0) -> [Float] {
        var out: [Float] = []
        let per = sampleRate / (Double(baud) * (1 + baudError))
        var acc = 0.0
        var lp: Float = 0
        let k = Float(1 - exp(-2 * .pi * 1.5 * Double(baud) / sampleRate))
        for b in bits {
            let level: Float = (b == 1) != inverted ? amplitude : -amplitude
            acc += per
            while acc >= 1 {
                lp += k * (level - lp)
                out.append(lp)
                acc -= 1
            }
        }
        return out
    }
}
