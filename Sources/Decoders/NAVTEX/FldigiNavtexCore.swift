// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Fldigi

/// Eine empfangene NAVTEX-Nachricht („ZCZC B1B2B3B4 … NNNN“)
public struct NavtexMessage: Equatable, Sendable, Identifiable {
    public let id = UUID()
    /// Text nach fldigis Bereinigung; ggf. mit „[Lost header]:“ / „:[Lost trailer]“ / „:<TIMEOUT>“
    public var text: String
    /// B1: Kennbuchstabe der Station (z. B. „S“), „?“ ohne Kopf
    public var origin: Character
    /// B2: Art der Nachricht (A Navigationswarnung, B Wetterwarnung, E Wettervorhersage …)
    public var subject: Character
    /// B3B4: laufende Nummer
    public var number: Int
    /// fldigis Beschreibung der Art (englisch)
    public var subjectText: String
    public var receivedAt: Date

    public var hasHeader: Bool { origin != "?" }
    /// „SA01“
    public var code: String { hasHeader ? "\(origin)\(subject)\(String(format: "%02d", number))" : "????" }

    public static func == (a: NavtexMessage, b: NavtexMessage) -> Bool {
        a.text == b.text && a.origin == b.origin && a.subject == b.subject && a.number == b.number
    }

    /// Deutsche Bezeichnung der Nachrichtenart (IMO NAVTEX Manual, B2-Kennung)
    public var subjectGerman: String {
        switch subject {
        case "A": return "Navigationswarnung"
        case "B": return "Wetterwarnung"
        case "C": return "Eisbericht"
        case "D": return "Such- und Rettungsdienst, Piraterie"
        case "E": return "Wettervorhersage"
        case "F": return "Lotsendienst"
        case "G": return "AIS"
        case "H": return "LORAN"
        case "J": return "Satellitennavigation"
        case "K": return "Andere Navigationshilfen"
        case "L": return "Navigationswarnungen (Fortsetzung)"
        case "T": return "Testsendung"
        case "V", "W", "X", "Y": return "Sonderdienst"
        case "Z": return "Keine Nachricht vorhanden"
        default: return "Unbekannte Art"
        }
    }
}

/// Swift-Hülle um den NAVTEX-Empfänger aus fldigi 4.2.13 (`Vendor/Fldigi/src/navtex`).
/// Nicht threadsicher: alle Aufrufe von derselben Queue (in der App: Verarbeitungs-Queue der Pipeline).
public final class FldigiNavtexCore {
    public static let sampleRate = Double(FLDIGI_NAVTEX_SAMPLE_RATE)
    /// Hub ±85 Hz (fldigi `deviation_f`)
    public static let deviation: Double = 85

    public struct Options: Equatable, Sendable {
        public var sitorBOnly = false
        /// Mark/Space vertauscht nach Seitenband-Korrektur
        public var reverse = false
        public var afcOn = true
        public var ita2 = false
        public var minMessageLength = 0
        public init() {}
    }

    public enum SyncState: Int, Sendable {
        case setup = 0, sync = 1, reading = 2
        public var label: String {
            switch self {
            case .setup: return "SUCHE"
            case .sync: return "SYNC"
            case .reading: return "EMPFANG"
            }
        }
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var snrDB: Double
        public var state: SyncState
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    public init(options: Options = Options(), centerHz: Double,
                onChar: @escaping (Character) -> Void, onMessage: @escaping (NavtexMessage) -> Void) {
        self.options = options
        sink = Sink(onChar: onChar, onMessage: onMessage)
        var cfg = Self.config(options)
        handle = fldigi_navtex_create(&cfg, centerHz, { ctx, c in
            guard let ctx, let scalar = Unicode.Scalar(UInt32(UInt8(truncatingIfNeeded: c))) else { return }
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onChar(Character(scalar))
        }, { ctx, text, origin, subject, number, subjectText in
            guard let ctx else { return }
            let msg = NavtexMessage(
                text: text.map { String(cString: $0) } ?? "",
                origin: Character(Unicode.Scalar(UInt8(bitPattern: origin))),
                subject: Character(Unicode.Scalar(UInt8(bitPattern: subject))),
                number: Int(number),
                subjectText: subjectText.map { String(cString: $0) } ?? "",
                receivedAt: Date())
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onMessage(msg)
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_navtex_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_navtex_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_navtex_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_navtex_set_center(handle, hz)
    }

    public var status: Status {
        var s = fldigi_navtex_status()
        fldigi_navtex_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, snrDB: s.snr_db,
                      state: SyncState(rawValue: Int(s.state)) ?? .setup)
    }

    // MARK: - Stationen

    public struct Station: Equatable, Sendable {
        public var name: String
        public var callsign: String
        public var country: String
        public var latitude: Double
        public var longitude: Double
    }

    @discardableResult
    public static func loadStations(from directory: URL? = SynopDecoder.stationDirectory) -> Bool {
        guard let dir = directory else { return false }
        return fldigi_navtex_load_stations(dir.path + "/") == 1
    }

    /// Station zur Kennung wie fldigi `NavtexCatalog::FindStation` (nächstgelegene Station mit dieser Kennung
    /// auf der Frequenz, bei Mehrdeutigkeit Namensvergleich mit dem Text)
    public static func findStation(origin: Character, frequencyHz: Double, locator: String, message: String) -> Station? {
        guard let o = origin.asciiValue else { return nil }
        var buf = [CChar](repeating: 0, count: 512)
        guard fldigi_navtex_find_station(CChar(bitPattern: o), frequencyHz, locator, message, &buf, Int32(buf.count)) == 1 else {
            return nil
        }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let parts = String(decoding: bytes, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else { return nil }
        return Station(name: parts[0], callsign: parts[1], country: parts[2],
                       latitude: Double(parts[3]) ?? 0, longitude: Double(parts[4]) ?? 0)
    }

    // MARK: - Testsignal

    /// Text → 7-Bit-Codes mit FEC wie fldigis NAVTEX-Sender
    public static func encode(_ text: String, ita2: Bool = false) -> [UInt8] {
        var codes = [UInt8](repeating: 0, count: max(64, text.utf8.count * 6 + 64))
        let n = Int(fldigi_navtex_encode(text, ita2 ? 1 : 0, &codes, Int32(codes.count)))
        return Array(codes.prefix(n))
    }

    private static func config(_ o: Options) -> fldigi_navtex_config {
        var c = fldigi_navtex_default_config()
        c.sitor_b_only = o.sitorBOnly ? 1 : 0
        c.reverse = o.reverse ? 1 : 0
        c.afc_on = o.afcOn ? 1 : 0
        c.ita2 = o.ita2 ? 1 : 0
        c.min_message_length = Int32(o.minMessageLength)
        return c
    }

    private final class Sink {
        let onChar: (Character) -> Void
        let onMessage: (NavtexMessage) -> Void
        init(onChar: @escaping (Character) -> Void, onMessage: @escaping (NavtexMessage) -> Void) {
            self.onChar = onChar
            self.onMessage = onMessage
        }
    }
}

/// NAVTEX-Testsignal: Phasing (rep/alpha), Nachricht mit FEC wie fldigis Sender, 100 Bd, ±85 Hz.
/// Bit 1 = Mark = Mitte + 85 Hz (fldigi `send_bit`).
public struct NavtexSignalGenerator {
    public var centerHz: Double = 1000
    public var sampleRate: Double = FldigiNavtexCore.sampleRate
    public var amplitude: Double = 0.5
    public var phasingSeconds: Double = 10
    public var reverse = false

    public init() {}

    /// Vollständige Aussendung „ZCZC <kopf>\r\n<text>\r\nNNNN\r\n“ mit Phasing davor und danach
    public func samples(header: String, text: String, ita2: Bool = false) -> [Float] {
        let body = "ZCZC \(header)\r\n\(text)\r\nNNNN\r\n"
        let phasing = Array(repeating: [UInt8(0x66), UInt8(0x0F)], count: Int(phasingSeconds * 100 / 14)).flatMap { $0 }
        let tail = Array(repeating: [UInt8(0x66), UInt8(0x0F)], count: 100).flatMap { $0 }
        return modulate(phasing + FldigiNavtexCore.encode(body, ita2: ita2) + tail)
    }

    public func modulate(_ codes: [UInt8]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Int(Double(codes.count * 7) / 100 * sampleRate) + 16)
        var phase = 0.0
        var bits = 0.0
        for code in codes {
            var c = code
            for _ in 0..<7 {
                let mark = (c & 1 == 1) != reverse
                c >>= 1
                let f = mark ? centerHz + FldigiNavtexCore.deviation : centerHz - FldigiNavtexCore.deviation
                bits += 1
                let end = Int((bits / 100 * sampleRate).rounded())
                let dphi = 2 * Double.pi * f / sampleRate
                while out.count < end {
                    out.append(Float(amplitude * sin(phase)))
                    phase += dphi
                    if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                }
            }
        }
        return out
    }
}
