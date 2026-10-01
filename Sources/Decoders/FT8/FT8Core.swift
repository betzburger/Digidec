import Foundation
import FT8

/// Eine decodierte FT8-Meldung
public struct FT8Decode: Identifiable, Sendable, Equatable {
    public let id = UUID()
    /// Beginn des 15-s-Zyklus (UTC)
    public var cycleStart: Date
    public var text: String
    /// S/N in 2500 Hz wie WSJT-X
    public var snrDB: Int
    /// Zeitversatz gegen 0,5 s nach Zyklusbeginn
    public var dt: Double
    /// NF-Frequenz des untersten Tons
    public var freqHz: Double
    /// Bits, die nach LDPC/OSD mit der Prüfsumme übereinstimmen (von 174); unter 140 meist Fehldecodierung
    public var correctBits: Int
    /// Durchgang (> 0: erst nach Subtraktion stärkerer Signale gefunden)
    public var pass: Int

    public static let uncertainBelow = 140

    public var message: FT8Message { FT8Message(text) }

    /// Wie WSJT-X „?“: wenig übereinstimmende Bits oder unplausible Rufzeichen
    public var isUncertain: Bool {
        correctBits < Self.uncertainBelow || !message.isPlausible
    }

    public static func == (a: FT8Decode, b: FT8Decode) -> Bool {
        a.cycleStart == b.cycleStart && a.text == b.text && a.snrDB == b.snrDB && a.freqHz == b.freqHz
    }
}

/// Aufbau einer FT8-Standardmeldung (WSJT-X-Konventionen)
public struct FT8Message: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// „CQ [DX|NA|EU|123] RUF [LOC]“
        case cq(modifier: String?, call: String, grid: String?)
        /// „AN VON [LOC|Rapport|R-xx|RRR|RR73|73]“
        case exchange(to: String, from: String, info: String?)
        case other
    }

    public let text: String
    public let tokens: [String]
    public let kind: Kind

    public init(_ text: String) {
        self.text = text
        tokens = text.split(separator: " ").map(String.init)
        kind = Self.parse(tokens)
    }

    private static func parse(_ t: [String]) -> Kind {
        guard let first = t.first else { return .other }
        if first == "CQ" {
            switch t.count {
            case 2: return .cq(modifier: nil, call: t[1], grid: nil)
            case 3:
                if isGrid(t[2]) || !isCall(t[1]) { return .cq(modifier: isCall(t[1]) ? nil : t[1], call: isCall(t[1]) ? t[1] : t[2], grid: isGrid(t[2]) ? t[2] : nil) }
                return .cq(modifier: t[1], call: t[2], grid: nil)
            case 4: return .cq(modifier: t[1], call: t[2], grid: isGrid(t[3]) ? t[3] : nil)
            default: return .other
            }
        }
        if t.count >= 2 && t.count <= 3 {
            return .exchange(to: t[0], from: t[1], info: t.count == 3 ? t[2] : nil)
        }
        return .other
    }

    public var isCQ: Bool { if case .cq = kind { return true }; return false }

    /// Absender (bei CQ der Rufer, sonst das zweite Rufzeichen)
    public var sender: String? {
        switch kind {
        case .cq(_, let call, _): return call
        case .exchange(_, let from, _): return from
        case .other: return nil
        }
    }

    public var grid: String? {
        switch kind {
        case .cq(_, _, let g): return g
        case .exchange(_, _, let info): return info.flatMap { Self.isGrid($0) && $0 != "RR73" ? $0 : nil }
        case .other: return nil
        }
    }

    /// Alle Rufzeichen der Meldung
    public var calls: [String] {
        switch kind {
        case .cq(_, let c, _): return [c]
        case .exchange(let a, let b, _): return [a, b]
        case .other: return []
        }
    }

    /// Rufzeichen und Typ plausibel (verwirft Fehldecodierungen wie „005JVQ/R“ oder „i3=5 n3=3“)
    public var isPlausible: Bool {
        if text.contains("i3=") { return false }
        switch kind {
        case .cq(_, let c, _): return Self.isCall(c) || Self.isHashed(c)
        case .exchange(let a, let b, _):
            return (Self.isCall(a) || Self.isHashed(a)) && (Self.isCall(b) || Self.isHashed(b))
        case .other: return true   // Freitext, Telemetrie
        }
    }

    /// Amateurfunk-Rufzeichen: ITU-Präfix (Buchstabe/Buchstabe, Buchstabe/Ziffer oder Ziffer 2–9/Buchstabe), Ziffer,
    /// Suffix mit Buchstabe am Ende; optional /P, /R, /QRP, /MM usw. oder Länderpräfix davor
    public static func isCall(_ s: String) -> Bool {
        let parts = s.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 2 else { return false }
        let base = parts.count == 2 && parts[0].count > parts[1].count ? parts[0] : (parts.count == 2 ? parts[1] : parts[0])
        if parts.count == 2 {
            let other = base == parts[0] ? parts[1] : parts[0]
            guard other.range(of: "^[A-Z0-9]{1,4}$", options: .regularExpression) != nil else { return false }
        }
        return base.range(of: "^([A-Z]{1,2}|[2-9][A-Z]|[A-Z][0-9])[0-9][A-Z0-9]{0,3}[A-Z]$", options: .regularExpression) != nil
    }

    /// Rufzeichen, das nur als Hash übertragen wurde: „<...>“ oder „<DL1ABC>“
    public static func isHashed(_ s: String) -> Bool { s.hasPrefix("<") && s.hasSuffix(">") }

    /// Vierstelliger Maidenhead-Locator (RR73 ist keiner)
    public static func isGrid(_ s: String) -> Bool {
        s != "RR73" && s.range(of: "^[A-R]{2}[0-9]{2}$", options: .regularExpression) != nil
    }
}

/// Maidenhead-Locator: Mittelpunkt, Entfernung, Richtung
public enum Maidenhead {
    /// Mittelpunkt des Feldes (4 oder 6 Zeichen) in Grad
    public static func coordinate(_ locator: String) -> (lat: Double, lon: Double)? {
        let l = Array(locator.uppercased())
        guard l.count == 4 || l.count == 6,
              let a = l[0].asciiValue, let b = l[1].asciiValue, let c = l[2].wholeNumberValue, let d = l[3].wholeNumberValue,
              (65...82).contains(a), (65...82).contains(b) else { return nil }
        var lon = Double(Int(a) - 65) * 20 - 180 + Double(c) * 2
        var lat = Double(Int(b) - 65) * 10 - 90 + Double(d)
        if l.count == 6, let e = l[4].asciiValue, let f = l[5].asciiValue, (65...88).contains(e), (65...88).contains(f) {
            lon += Double(Int(e) - 65) * (2.0 / 24) + 1.0 / 24
            lat += Double(Int(f) - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }

    /// Großkreis-Entfernung in km und Richtung in Grad (0 = Nord)
    public static func distance(from a: String, to b: String) -> (km: Double, bearing: Double)? {
        guard let p = coordinate(a), let q = coordinate(b) else { return nil }
        let r = 6371.0
        let φ1 = p.lat * .pi / 180, φ2 = q.lat * .pi / 180
        let Δφ = φ2 - φ1, Δλ = (q.lon - p.lon) * .pi / 180
        let h = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let km = 2 * r * asin(min(1, sqrt(h)))
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let bearing = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (km, bearing)
    }
}

/// Swift-Hülle um ft8mon (`Vendor/FT8`): ein Aufruf decodiert einen 15-s-Zyklus.
/// ft8mon hält seine Parameter global → Aufrufe werden in der C-Schnittstelle nacheinander ausgeführt.
public enum FT8Core {
    public static let sampleRate = 12_000.0
    public static let cycleSeconds = 15.0

    public struct Settings: Equatable, Sendable, Codable {
        public var minHz = 150.0
        public var maxHz = 3600.0
        /// Rechenzeit je Zyklus (ft8mon „budget“); mehr = gründlicher, 3 s reichen für ~90 % der WSJT-X-Decodes
        public var budgetSeconds = 3.0
        public var threads = 4
        public init() {}
    }

    /// Decodiert einen Zyklus. `samples` beginnen beim Zyklusbeginn (Sekunde 0, 15, 30, 45).
    /// Blockiert bis zum Ende (höchstens etwa `budgetSeconds`).
    public static func decode(_ samples: [Float], rate: Int = 12_000, cycleStart: Date = Date(),
                              settings: Settings = Settings()) -> [FT8Decode] {
        final class Box { var list: [FT8Decode] = []; let start: Date; init(_ s: Date) { start = s } }
        let box = Box(cycleStart)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        samples.withUnsafeBufferPointer { buf in
            _ = ft8dd_decode_cycle(buf.baseAddress, Int32(buf.count), Int32(rate), settings.minHz, settings.maxHz,
                                   settings.budgetSeconds, Int32(settings.threads), { ctx, d in
                guard let ctx, let d else { return }
                let b = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let text = withUnsafeBytes(of: d.pointee.text) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                // WSJT-X zeigt doppelte Leerzeichen nicht
                let clean = text.split(separator: " ").joined(separator: " ")
                if clean.contains("i3=") { return }   // nicht unterstützter Typ: fast immer Fehldecodierung
                b.list.append(FT8Decode(cycleStart: b.start, text: clean, snrDB: Int(d.pointee.snr_db.rounded()),
                                        dt: d.pointee.dt, freqHz: d.pointee.freq_hz,
                                        correctBits: Int(d.pointee.correct_bits), pass: Int(d.pointee.pass)))
            }, ctx)
        }
        return box.list.sorted { $0.freqHz < $1.freqHz }
    }

    /// FT8-Testsignal (nur für Tests): Aussendung des Klartexts, unterster Ton bei `frequency`, Amplitude 1
    public static func synthesize(_ text: String, frequency: Double, rate: Int = 12_000) -> [Float]? {
        var out = [Float](repeating: 0, count: rate * 13)
        let n = out.withUnsafeMutableBufferPointer { ft8dd_synthesize(text, frequency, Int32(rate), $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }
        return Array(out.prefix(Int(n)))
    }

    /// Zyklus mit mehreren Signalen: (Text, Frequenz, Startzeit nach Zyklusbeginn, Amplitude)
    public static func cycle(_ signals: [(text: String, hz: Double, start: Double, amplitude: Double)],
                             rate: Int = 12_000) -> [Float] {
        var out = [Float](repeating: 0, count: Int(cycleSeconds) * rate)
        for s in signals {
            guard let wave = synthesize(s.text, frequency: s.hz, rate: rate) else { continue }
            let i0 = Int(s.start * Double(rate))
            for (k, v) in wave.enumerated() where i0 + k >= 0 && i0 + k < out.count {
                out[i0 + k] += Float(s.amplitude) * v
            }
        }
        return out
    }
}
