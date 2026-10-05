// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Eine Sendefrequenz des DWD-Funkfernschreibens (Sender Pinneberg)
public struct RttyFrequency: Equatable, Codable, Sendable, Identifiable {
    /// 1 oder 2
    public let program: Int
    public let hz: Double
    /// z. B. „DDK 2“
    public let callsign: String
    /// Hub in Hz (±), z. B. 225 bzw. 42,5 (Langwelle)
    public let shiftHalfHz: Double

    public var id: String { "\(program)-\(Int(hz))" }
    public var isLongwave: Bool { hz < 1_000_000 }
    /// Voreinstellung des RTTY-Decoders für diese Frequenz (DWD LW: Hub 85 Hz, KW: 450 Hz)
    public var presetID: String { isLongwave ? "dwd-lw" : "dwd-kw" }

    /// „4583 kHz“, „147,3 kHz“
    public var label: String {
        let k = hz / 1000
        let s = k == k.rounded() ? String(format: "%.0f", k) : String(format: "%g", k)
        return s.replacingOccurrences(of: ".", with: ",") + " kHz"
    }
}

/// Eine Sendung im Plan des Seewetterdienstes (Funkfernschreiben, F1B 50 Baud)
public struct RttyBroadcast: Identifiable, Equatable, Codable, Sendable {
    public let program: Int
    /// Beginn in Minuten seit 00:00 UTC
    public let startMinute: Int
    /// bis zum Beginn der nächsten Sendung desselben Programms (höchstens 120 min)
    public var durationMinutes: Int
    public var title: String
    /// WMO-Kopfzeile, z. B. „FQEN70 EDZW 0000“; mehrere durch „ / “ getrennt
    public var header: String?

    public var id: String { String(format: "%d-%02d%02d", program, startMinute / 60, startMinute % 60) }
}

/// Plan der DWD-Funkfernschreiben-Ausstrahlungen (Programm 1 und 2), alle Zeiten UTC, täglich gleich
public struct RttySchedule: Equatable, Codable, Sendable {
    public var frequencies: [RttyFrequency]
    public var broadcasts: [RttyBroadcast]

    public init(frequencies: [RttyFrequency], broadcasts: [RttyBroadcast]) {
        self.frequencies = frequencies
        self.broadcasts = broadcasts
    }

    public static let empty = RttySchedule(frequencies: [], broadcasts: [])

    public func frequencies(forProgram p: Int) -> [RttyFrequency] { frequencies.filter { $0.program == p } }

    /// Plan in einheitlicher Form für Zeitrechnung und automatische Aufnahme
    public var items: [ScheduledItem] {
        broadcasts.map { ScheduledItem(service: .rtty, id: $0.id, startMinute: $0.startMinute, durationMinutes: $0.durationMinutes,
                                       title: "P\($0.program) · " + $0.title) }
    }

    // MARK: - Auslesen des DWD-PDFs (Textform)

    /// Liest den Text eines Programmplans. `nil`, wenn er nicht wie ein Sendeplan aussieht (Format geändert).
    public static func parse(text: String, program: Int) -> RttySchedule? {
        let freqPattern = #"^(\d{3,5}(?:,\d)?)\s*kHz\s+(DD[HK]\s*\d+)\s+\d{2}[.:]\d{2}\s*-\s*\d{2}[.:]\d{2}\s+UTC\s+[\d,]+\s*kW\s+F1B\s+(\d+)\s*Baud\s*\+\s*/\s*-\s*(\d+(?:,\d)?)\s*Hz"#
        let rowPattern = #"^(\d{2})[.:](\d{2})\s+(.+)$"#
        let headerPattern = #"\s([A-Z]{4}\d{2}(?:-\d{2})?)\s+([A-Z]{4})\s+(\d{4}|GGgg)\s*$"#
        guard let freqRE = try? NSRegularExpression(pattern: freqPattern),
              let rowRE = try? NSRegularExpression(pattern: rowPattern),
              let headerRE = try? NSRegularExpression(pattern: headerPattern) else { return nil }

        func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
            let range = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: range) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
        }
        /// zerlegt „Inhalt FQEN70 EDZW 0000“ in Inhalt und Kopfzeile
        func splitHeader(_ s: String) -> (String, String?) {
            guard let g = groups(headerRE, s), g.count == 3, let r = headerRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let whole = Range(r.range, in: s) else { return (s, nil) }
            return (String(s[s.startIndex..<whole.lowerBound]).trimmingCharacters(in: .whitespaces), "\(g[0]) \(g[1]) \(g[2])")
        }
        /// Bereinigt Textartefakte des PDFs: „Synop- Stationen“ → „Synop-Stationen“, „bisShetlands“ → „bis Shetlands“
        func tidy(_ s: String) -> String {
            var t = s.replacingOccurrences(of: #"(?<=\p{L})- (?=\p{Lu})"#, with: "-", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?<=[a-zäöüß]{2})(?=[A-ZÄÖÜ][a-zäöüß])"#, with: " ", options: .regularExpression)
            return t
        }
        /// hängt eine Folgezeile an: ein Trennstrich am Zeilenende vor Kleinbuchstaben fällt weg („Verschlüs-“ + „selte“)
        func join(_ a: String, _ b: String) -> String {
            if a.hasSuffix("-"), let f = b.first, f.isLowercase { return String(a.dropLast()) + b }
            return a.isEmpty ? b : a + " " + b
        }

        var frequencies: [RttyFrequency] = []
        var list: [RttyBroadcast] = []
        var started = false

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !started, let g = groups(freqRE, line), g.count == 4,
               let khz = Double(g[0].replacingOccurrences(of: ",", with: ".")), let half = Double(g[3].replacingOccurrences(of: ",", with: ".")) {
                frequencies.append(RttyFrequency(program: program, hz: khz * 1000, callsign: g[1].replacingOccurrences(of: "  ", with: " "), shiftHalfHz: half))
                continue
            }
            // Seitenkopf (wiederholt sich je Seite) und Hinweise „bei Bedarf“ gehören nicht zum Plan
            if line.range(of: #"^[12]\. Progr\."#, options: .regularExpression) != nil { continue }
            if line.lowercased().hasPrefix("bei bedarf") { break }
            if let g = groups(rowRE, line), g.count == 3, let h = Int(g[0]), let m = Int(g[1]), h < 24, m < 60 {
                started = true
                let (title, header) = splitHeader(g[2])
                list.append(RttyBroadcast(program: program, startMinute: h * 60 + m, durationMinutes: 0, title: title, header: header))
                continue
            }
            guard started, !list.isEmpty else { continue }
            // Folgezeile: gehört zur vorigen Sendung (ggf. mit eigener Kopfzeile, z. B. zweite Meldung ohne eigene Uhrzeit)
            let (extra, header) = splitHeader(line)
            if !extra.isEmpty { list[list.count - 1].title = join(list[list.count - 1].title, extra) }
            if let header { list[list.count - 1].header = (list[list.count - 1].header.map { $0 + " / " } ?? "") + header }
        }

        // Dauer: bis zur nächsten Sendung (letzte bis zur ersten des nächsten Tages), höchstens 120 min
        guard list.count >= 25, !frequencies.isEmpty,
              zip(list, list.dropFirst()).allSatisfy({ $0.startMinute < $1.startMinute }) else { return nil }
        for i in list.indices {
            list[i].title = tidy(list[i].title)
            let next = i + 1 < list.count ? list[i + 1].startMinute : list[0].startMinute + 1440
            list[i].durationMinutes = min(120, max(1, next - list[i].startMinute))
        }
        return RttySchedule(frequencies: frequencies, broadcasts: list)
    }

    /// Fügt zwei Programmpläne zusammen (sortiert nach Beginn, bei gleichem Beginn Programm 1 zuerst)
    public static func merged(_ parts: [RttySchedule]) -> RttySchedule {
        RttySchedule(frequencies: parts.flatMap(\.frequencies),
                     broadcasts: parts.flatMap(\.broadcasts).sorted { ($0.startMinute, $0.program) < ($1.startMinute, $1.program) })
    }
}

/// Auslesen der Download-Links aus der DWD-Seite „Funkausstrahlung Sender Pinneberg“
public enum RttyScheduleSource {
    /// URL des Programmplans (1 oder 2) aus dem HTML der Seite; `jsessionid` wird entfernt.
    public static func pdfURL(program: Int, inHTML html: String, base: URL = WefaxScheduleSource.pageURL) -> URL? {
        DWDScheduleLinks.pdfURL(namePattern: "sendeplan_rtty_0\(program)_\\d+\\.pdf", inHTML: html, base: base)
    }
}
