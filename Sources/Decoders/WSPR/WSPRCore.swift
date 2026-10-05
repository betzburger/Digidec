// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Wspr

/// Eine decodierte WSPR-Meldung (2-Minuten-Zyklus, 4-FSK 1,4648 Baud)
public struct WSPRDecode: Identifiable, Sendable, Equatable {
    public let id = UUID()
    /// Beginn des 2-Minuten-Zyklus (UTC)
    public var slotStart: Date
    /// Klartext wie wsprd: „DL1ABC JO30 37“
    public var text: String
    /// S/N in 2500 Hz wie WSJT-X
    public var snrDB: Int
    /// Zeitversatz in Sekunden gegen 1 s nach Zyklusbeginn
    public var dt: Double
    /// NF-Frequenz der Signalmitte (nominal 1500 ± 100 Hz)
    public var freqHz: Double
    /// Drift in Hz/Minute
    public var drift: Int
    public var sync: Double
    /// Durchgang (> 1 nach Subtraktion stärkerer Signale)
    public var pass: Int

    public static func == (a: WSPRDecode, b: WSPRDecode) -> Bool {
        a.slotStart == b.slotStart && a.text == b.text && a.freqHz == b.freqHz
    }

    /// Zerlegte Meldung
    public var message: WSPRMessage { WSPRMessage(text) }
}

/// Inhalt einer WSPR-Aussendung: Rufzeichen, Locator (4 Stellen), Leistung in dBm.
/// Typ 1 „DL1ABC JO30 37“, Typ 2 „PJ4/K1ABC 37“ (Zusatz, kein Locator), Typ 3 „<DL1ABC> JO30 37“ (Hash).
public struct WSPRMessage: Sendable, Equatable {
    public var call: String
    public var grid: String?
    public var powerDBm: Int?
    /// Rufzeichen kam nur als Hash an (`<…>`)
    public var isHashed: Bool { call.hasPrefix("<") }

    public init(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        call = parts.first ?? ""
        switch parts.count {
        case 3:
            grid = parts[1]
            powerDBm = Int(parts[2])
        case 2:
            powerDBm = Int(parts[1])
        default:
            break
        }
    }

    /// Rufzeichen ohne `<>`
    public var plainCall: String { call.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }

    /// Sendeleistung in Watt, „5 W“, „1,5 W“, „200 mW“
    public var powerLabel: String {
        guard let dbm = powerDBm else { return "" }
        let mw = pow(10.0, Double(dbm) / 10.0)
        func number(_ v: Double) -> String {
            v >= 10 || abs(v - v.rounded()) < 0.05 ? String(format: "%.0f", v) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
        }
        return mw >= 1000 ? number(mw / 1000) + " W" : number(mw) + " mW"
    }
}

/// Swift-Hülle um den WSPR-Decoder (`Vendor/Wspr`, wsprd aus WSJT-X): decodiert eine 2-Minuten-Aufnahme.
public enum WSPRCore {
    public static let sampleRate = 12_000.0
    public static let slotSeconds = 120.0
    /// Länge der Aufnahme, die wsprd auswertet
    public static let usedSeconds = 114.0

    public struct Settings: Equatable, Sendable, Codable {
        /// ± 150 Hz statt ± 110 Hz um 1500 Hz suchen
        public var wide = false
        /// Mehr Kandidaten (wsprd „-d“): langsamer, ein paar Decodes mehr
        public var deep = false
        public init(wide: Bool = false, deep: Bool = false) { self.wide = wide; self.deep = deep }
    }

    /// Decodiert einen Zyklus. `samples` beginnen beim Zyklusbeginn (gerade UTC-Minute), 12 000 Hz.
    public static func decode(_ samples: [Float], slotStart: Date = Date(), settings: Settings = Settings()) -> [WSPRDecode] {
        final class Box { var list: [WSPRDecode] = []; let start: Date; init(_ s: Date) { start = s } }
        let box = Box(slotStart)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        samples.withUnsafeBufferPointer { buf in
            _ = wsprdd_decode_slot(buf.baseAddress, Int32(buf.count), settings.wide ? 1 : 0, settings.deep ? 1 : 0, { ctx, d in
                guard let ctx, let d else { return }
                let b = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let text = withUnsafeBytes(of: d.pointee.message) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                b.list.append(WSPRDecode(slotStart: b.start, text: text.split(separator: " ").joined(separator: " "),
                                         snrDB: Int(d.pointee.snr_db.rounded()), dt: Double(d.pointee.dt),
                                         freqHz: d.pointee.freq_hz, drift: Int(d.pointee.drift.rounded()),
                                         sync: Double(d.pointee.sync), pass: Int(d.pointee.pass)))
            }, ctx)
        }
        return removeResiduals(box.list)
    }

    /// Sehr starke Signale hinterlassen nach der Subtraktion einen Rest, den wsprd ein zweites Mal als dieselbe Meldung
    /// mit viel kleinerem S/N findet, wenige Hz daneben (wsprd prüft nur ±4 Hz). Das stärkere bleibt.
    /// (ABWEICHUNG wsprd (Digidec): Nachbearbeitung in Swift, der C-Kern bleibt unverändert.)
    public static func removeResiduals(_ list: [WSPRDecode], withinHz: Double = 10) -> [WSPRDecode] {
        list.filter { d in
            !list.contains { o in
                o.id != d.id && o.text == d.text && abs(o.freqHz - d.freqHz) < withinHz
                    && (o.snrDB > d.snrDB || (o.snrDB == d.snrDB && (o.freqHz, o.id.uuidString) < (d.freqHz, d.id.uuidString)))
            }
        }
    }

    /// WSPR-Testsignal (nur für Tests, Digidec sendet nie): „CALL GRID DBM“, Mitte bei `frequency`, Beginn `start` s nach Zyklusbeginn,
    /// Amplitude 1, 120 s lang.
    public static func synthesize(_ message: String, frequency: Double = 1500, start: Double = 1.0) -> [Float]? {
        var out = [Float](repeating: 0, count: 120 * 12_000)
        let n = out.withUnsafeMutableBufferPointer { wsprdd_synthesize(message, frequency, start, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? out : nil
    }

    /// Hashtabelle für Typ-3-Meldungen (Textdatei wie wsprd `hashtable.txt`)
    @discardableResult public static func loadHashes(from url: URL) -> Bool { wsprdd_hash_load(url.path) == 0 }
    @discardableResult public static func saveHashes(to url: URL) -> Bool { wsprdd_hash_save(url.path) == 0 }
}
