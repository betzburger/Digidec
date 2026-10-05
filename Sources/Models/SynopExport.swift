import Foundation

// MARK: - CSV-Ablage der decodierten SYNOP-Meldungen

/// Eine Zeile je vollständiger Meldung: für Tabellenkalkulation, Auswertung und Verlaufsgrafiken.
/// Trennzeichen Semikolon, Dezimalpunkt, UTF-8; leere Felder, wo die Meldung nichts enthält.
public enum SynopCSV {
    public static let columns = [
        "empfangen_utc", "art", "kennung", "name", "breite", "laenge", "beobachtung", "temperatur_c", "taupunkt_c", "feuchte_pct",
        "druck_hpa", "druck_art", "windrichtung_grad", "wind_kn", "wind_einheit_angenommen", "sicht_km", "niederschlag_mm",
        "niederschlag_h", "kopfzeile_fehlte"
    ]

    public static var header: String { columns.joined(separator: ";") }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Zahl mit Dezimalpunkt; leer bei fehlendem Wert
    static func number(_ v: Double?, digits: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    /// Textfeld: bei Semikolon, Anführungszeichen oder Zeilenumbruch in Anführungszeichen, innere Anführungszeichen verdoppelt
    static func text(_ s: String) -> String {
        guard s.contains(";") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func row(_ o: SynopObservation) -> String {
        let pressureKind = o.seaLevelPressureHPa != nil ? "Meereshoehe" : (o.pressureHPa != nil ? "Station" : "")
        let fields: [String] = [
            timeFormat.string(from: o.received),
            text(o.kind),
            text(o.wmo),
            text(o.name),
            number(o.position?.lat, digits: 3),
            number(o.position?.lon, digits: 3),
            text(o.time ?? ""),
            number(o.temperatureC, digits: 1),
            number(o.dewpointC, digits: 1),
            number(o.humidityPct, digits: 0),
            number(o.pressureHPa, digits: 1),
            pressureKind,
            number(o.windDirectionDeg, digits: 0),
            number(o.windSpeedKn, digits: 1),
            o.windSpeedKn == nil ? "" : (o.windUnitAssumed ? "ja" : "nein"),
            number(o.visibilityKm, digits: 1),
            number(o.precipitationMm, digits: 1),
            number(o.precipitationHours, digits: 0),
            o.headerGuessed ? "ja" : "nein"
        ]
        return fields.joined(separator: ";")
    }
}

/// Schreibt die Meldungen in Tagesdateien: `~/Documents/Digidec/Logs/SYNOP-2026-10-05.csv` (UTC-Datum), Kopfzeile in neuen Dateien
public final class SynopCSVWriter {
    public let directory: URL

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/Logs", isDirectory: true)
    }

    public func fileURL(for date: Date = Date()) -> URL {
        directory.appendingPathComponent("SYNOP-\(Self.dayFormat.string(from: date)).csv")
    }

    /// Eine Zeile anhängen (Datei und Kopfzeile werden bei Bedarf angelegt). Rückgabe: geschrieben ja/nein.
    @discardableResult
    public func append(_ o: SynopObservation) -> Bool {
        let url = fileURL(for: o.received)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var out = ""
            let exists = FileManager.default.fileExists(atPath: url.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            if !exists || (size?.intValue ?? 0) == 0 {
                out += SynopCSV.header + "\n"
                if !exists { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            }
            out += SynopCSV.row(o) + "\n"
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(out.utf8))
            return true
        } catch {
            return false
        }
    }
}
