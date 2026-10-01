import Foundation

/// Eine Wetterkarten-Ausstrahlung des DWD (Radiofax, Sender Pinneberg).
public struct WefaxBroadcast: Identifiable, Equatable, Codable, Sendable {
    /// Beginn in Minuten seit 00:00 UTC
    public let startMinute: Int
    /// Zeilen je Minute
    public let lpm: Int
    /// Modul (IOC × π), 576
    public let modul: Int
    /// Laufzeit in Minuten
    public let durationMinutes: Int
    /// Kartentermin (UTC-Stunde der Analyse, z. B. 0 für 00.00 UTC)
    public let chartHour: Int
    public var title: String

    /// Eindeutig je Tag, z. B. „1636“
    public var id: String { String(format: "%02d%02d", startMinute / 60, startMinute % 60) }
    public var endMinute: Int { startMinute + durationMinutes }
}

/// Sendepause für Sprachsendungen
public struct WefaxPause: Equatable, Codable, Sendable {
    public let startMinute: Int
    public let endMinute: Int
}

/// Tagesplan der Faksimile-Ausstrahlung (gilt täglich gleich; alle Zeiten UTC).
public struct WefaxSchedule: Equatable, Codable, Sendable {
    /// Sendefrequenzen in Hz (3855, 7880, 13882,5 kHz)
    public var frequenciesHz: [Double]
    public var broadcasts: [WefaxBroadcast]
    public var pauses: [WefaxPause]

    // MARK: - Auslesen des DWD-PDFs (Textform)

    /// Liest den aus dem PDF gezogenen Text. `nil`, wenn er nicht wie ein Sendeplan aussieht (Format geändert).
    /// Zeilen: `04.30 120 / 576 19 00.00 Bodenanalyse …` (Start, UpM / Modul, Laufzeit, Termin, Inhalt), Folgezeilen gehören
    /// zum Inhalt der vorigen; `05.55-06.35 Sendepause …`.
    public static func parse(text: String) -> WefaxSchedule? {
        let rowPattern = #"^(\d{2})\.(\d{2})\s+(\d{2,3})\s*/\s*(\d{3})\s+(\d{1,3})\s+(\d{2})\.(\d{2})\s+(.+)$"#
        let pausePattern = #"^(\d{2})\.(\d{2})\s*-\s*(\d{2})\.(\d{2})\s+Sendepause"#
        let freqPattern = #"(\d{4,5}(?:,\d)?)\s*kHz"#
        let row = try? NSRegularExpression(pattern: rowPattern)
        let pause = try? NSRegularExpression(pattern: pausePattern)
        let freq = try? NSRegularExpression(pattern: freqPattern)
        guard let row, let pause, let freq else { return nil }

        func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
            let range = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: range) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
        }

        var frequencies: [Double] = []
        var broadcasts: [WefaxBroadcast] = []
        var pauses: [WefaxPause] = []
        var started = false

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !started, line.range(of: #"^\d{4,5}(,\d)?\s*kHz"#, options: .regularExpression) != nil, let g = groups(freq, line) {
                frequencies.append(Double(g[0].replacingOccurrences(of: ",", with: ".")).map { $0 * 1000 } ?? 0)
                continue
            }
            if let g = groups(pause, line), g.count == 4, let a = Int(g[0]), let b = Int(g[1]), let c = Int(g[2]), let d = Int(g[3]) {
                started = true
                pauses.append(WefaxPause(startMinute: a * 60 + b, endMinute: c * 60 + d))
                continue
            }
            if let g = groups(row, line), g.count == 8,
               let h = Int(g[0]), let m = Int(g[1]), let lpm = Int(g[2]), let modul = Int(g[3]),
               let dur = Int(g[4]), let chart = Int(g[5]) {
                started = true
                guard h < 24, m < 60 else { return nil }
                broadcasts.append(WefaxBroadcast(startMinute: h * 60 + m, lpm: lpm, modul: modul, durationMinutes: dur,
                                                 chartHour: chart, title: g[7].trimmingCharacters(in: .whitespaces)))
                continue
            }
            // Fußzeile (Legende, Urheber) beendet die Tabelle; Folgezeilen gehören zum Inhalt der vorigen Karte
            if line.hasPrefix("H +T") || line.hasPrefix("©") { break }
            if started, !broadcasts.isEmpty, line.first?.isNumber == false {
                broadcasts[broadcasts.count - 1].title += " " + line
            }
        }

        // Plausibilität: ein Sendeplan hat Dutzende Ausstrahlungen in aufsteigender Zeit
        guard !frequencies.isEmpty, broadcasts.count >= 25,
              zip(broadcasts, broadcasts.dropFirst()).allSatisfy({ $0.startMinute < $1.startMinute }),
              broadcasts.allSatisfy({ (60...240).contains($0.lpm) && $0.modul == 576 && (1...60).contains($0.durationMinutes) })
        else { return nil }
        return WefaxSchedule(frequenciesHz: frequencies, broadcasts: broadcasts, pauses: pauses)
    }

    // MARK: - Abfragen (UTC)

    /// Beginn einer Ausstrahlung am UTC-Tag von `day`
    public static func startDate(of b: WefaxBroadcast, onDayOf day: Date) -> Date {
        utcCalendar.startOfDay(for: day).addingTimeInterval(Double(b.startMinute) * 60)
    }

    /// Nächste Ausstrahlung ab `date` (heute, sonst morgen)
    public func next(after date: Date) -> (broadcast: WefaxBroadcast, start: Date)? {
        for dayOffset in 0...1 {
            let day = date.addingTimeInterval(Double(dayOffset) * 86_400)
            for b in broadcasts {
                let start = Self.startDate(of: b, onDayOf: day)
                if start > date { return (b, start) }
            }
        }
        return nil
    }

    /// Läuft gerade eine Ausstrahlung?
    public func running(at date: Date) -> (broadcast: WefaxBroadcast, start: Date)? {
        for dayOffset in [-1, 0] {
            let day = date.addingTimeInterval(Double(dayOffset) * 86_400)
            for b in broadcasts {
                let start = Self.startDate(of: b, onDayOf: day)
                if date >= start && date < start.addingTimeInterval(Double(b.durationMinutes) * 60) { return (b, start) }
            }
        }
        return nil
    }

    /// Plan in einheitlicher Form für Zeitrechnung und automatische Aufnahme
    public var items: [ScheduledItem] {
        broadcasts.map { ScheduledItem(service: .wefax, id: $0.id, startMinute: $0.startMinute, durationMinutes: $0.durationMinutes, title: $0.title) }
    }

    public static func dayKey(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Voreinstellung nach Tageszeit (UTC): nachts und abends 3855 kHz, tagsüber 7880 kHz. 13882,5 kHz wird nie automatisch
    /// gewählt: für Entfernungen bis etwa 1000 km liegt sie meist in der toten Zone. Was an Ort und Jahreszeit besser geht,
    /// stellt der Nutzer je Sendung ein (Digidec merkt sich eine von Hand geänderte Frequenz).
    public static func recommendedFrequencyHz(at date: Date) -> Double {
        let hour = utcCalendar.component(.hour, from: date)
        return (7..<18).contains(hour) ? 7_880_000 : 3_855_000
    }
}

/// Download-Links auf den DWD-Seiten (HTML → PDF-Adresse)
public enum DWDScheduleLinks {
    /// Erster Link, dessen Dateiname auf `namePattern` (regulärer Ausdruck, z. B. `sendeplan_fax_\d+\.pdf`) passt.
    /// `jsessionid` wird entfernt, relative Adressen werden zu `base` aufgelöst.
    public static func pdfURL(namePattern: String, inHTML html: String, base: URL) -> URL? {
        guard let re = try? NSRegularExpression(pattern: "href=\"([^\"]*" + namePattern + "[^\"]*)\"") else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, range: range), let r = Range(m.range(at: 1), in: html) else { return nil }
        var link = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
        if let semi = link.range(of: #";jsessionid=[^?]*"#, options: .regularExpression) { link.removeSubrange(semi) }
        return URL(string: link, relativeTo: base)?.absoluteURL
    }
}

/// Auslesen des Download-Links aus der DWD-Seite „Funkausstrahlung Sender Pinneberg“
public enum WefaxScheduleSource {
    public static let pageURL = URL(string: "https://www.dwd.de/DE/fachnutzer/schifffahrt/funkausstrahlung/_node.html")!

    /// URL des aktuellen Faksimile-Sendeplans (PDF) aus dem HTML der Seite; `jsessionid` wird entfernt.
    public static func faxPDFURL(inHTML html: String, base: URL = pageURL) -> URL? {
        DWDScheduleLinks.pdfURL(namePattern: #"sendeplan_fax_\d+\.pdf"#, inHTML: html, base: base)
    }
}
