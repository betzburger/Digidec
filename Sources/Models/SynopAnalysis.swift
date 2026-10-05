// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Auswertung der SYNOP-Beobachtungen: Messwerte je Ebene, Extremwerte, Überlagerungen (Isobaren, Farbfläche)

extension SynopLog.Layer {
    /// Ebenen mit einem Zahlenwert je Station (ohne SYMBOL und SEE)
    public static let measured: [SynopLog.Layer] = [.temperature, .pressure, .wind, .visibility, .humidity, .precipitation]

    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .pressure: return "hPa"
        case .wind: return "kn"
        case .visibility: return "km"
        case .humidity: return "%"
        case .precipitation: return "mm"
        case .symbol, .sea: return ""
        }
    }

    /// Name des Messwerts für Überschriften
    public var quantity: String {
        switch self {
        case .temperature: return "Temperatur"
        case .pressure: return "Luftdruck"
        case .wind: return "Wind"
        case .visibility: return "Sicht"
        case .humidity: return "Luftfeuchte"
        case .precipitation: return "Niederschlag"
        case .symbol, .sea: return ""
        }
    }

    /// Der Messwert der Ebene in der Beobachtung (Wind in Knoten, Sicht in km); nil, wenn nicht gemeldet
    public func value(of o: SynopObservation) -> Double? {
        switch self {
        case .temperature: return o.temperatureC
        case .pressure: return o.pressureHPa
        case .wind: return o.windSpeedKn
        case .visibility: return o.visibilityKm
        case .humidity: return o.humidityPct
        case .precipitation: return o.precipitationMm
        case .symbol, .sea: return nil
        }
    }

    /// Wert mit Einheit, Dezimalkomma („-12,3 °C“, „1013 hPa“)
    public func text(_ v: Double) -> String {
        let digits: Int
        switch self {
        case .temperature: digits = 1
        case .pressure: digits = v == v.rounded() ? 0 : 1
        case .wind, .humidity: digits = 0
        case .visibility: digits = v >= 10 ? 0 : 1
        case .precipitation: digits = v >= 10 ? 0 : 1
        case .symbol, .sea: digits = 0
        }
        return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",") + " " + unit
    }

    /// Hat die Ebene sinnvolle niedrigste Werte? (Wind und Niederschlag: Windstille und Trockenheit sind es nicht.)
    public var hasLowest: Bool { self != .wind && self != .precipitation }
}

// MARK: - Extremwerte

public struct SynopExtremeEntry: Identifiable, Equatable, Sendable {
    /// Kennung des Kartenpunkts („synop-10655“), damit ein Klick die Station auswählen kann
    public var id: String
    public var name: String
    public var kind: String
    public var value: Double
    public var text: String
}

/// Höchste und niedrigste Werte einer Ebene
public struct SynopExtremes: Equatable, Sendable {
    public var layer: SynopLog.Layer
    /// Stationen mit Wert und Ort
    public var stations: Int
    public var highest: [SynopExtremeEntry]
    public var lowest: [SynopExtremeEntry]
}

extension SynopLog {
    /// Die höchsten und niedrigsten Werte der Ebene unter allen Stationen mit Ort; nil ohne Messwert-Ebene oder ohne Daten
    public func extremes(layer: Layer, count: Int = 5, now: Date = Date()) -> SynopExtremes? {
        guard Layer.measured.contains(layer), count > 0 else { return nil }
        flush(at: now)
        var items: [SynopExtremeEntry] = []
        for o in observations.values {
            guard let p = o.position, p.isValid, let v = layer.value(of: o) else { continue }
            items.append(SynopExtremeEntry(id: "synop-" + o.id, name: o.name, kind: o.kind, value: v, text: layer.text(v)))
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
        let highest = Array(items.prefix(count))
        let lowest = layer.hasLowest && items.count > 1 ? Array(items.suffix(count).reversed()) : []
        return SynopExtremes(layer: layer, stations: items.count, highest: highest, lowest: lowest)
    }
}

// MARK: - Überlagerungen: Isobaren, Hoch/Tief, Temperaturfläche

/// Was zusätzlich zu den Stationswerten auf die Karte kommt
public struct SynopOverlayOptions: Equatable, Sendable {
    /// Abstand der Isobaren in hPa; 0 = keine
    public var isobarStepHPa: Int
    /// Temperaturverteilung als Farbfläche
    public var temperatureField: Bool

    public init(isobarStepHPa: Int = 0, temperatureField: Bool = false) {
        self.isobarStepHPa = isobarStepHPa
        self.temperatureField = temperatureField
    }

    public static let off = SynopOverlayOptions()
    public var isActive: Bool { isobarStepHPa > 0 || temperatureField }
}

public struct SynopOverlay: Sendable {
    public var contours: [MapContour] = []
    public var patches: [MapPatch] = []
    /// Hochs und Tiefs als Kartenpunkte
    public var centers: [MapMarker] = []
    public var note: String?
}

extension SynopLog {
    /// Beobachtungen älter als dies fließen nicht in Isobaren und Farbflächen ein (Meldungen vom Vortag passen nicht zur Lage)
    public static let overlayMaxAge: TimeInterval = 9 * 3600

    /// Isobaren, Hoch/Tief und Farbfläche aus den Beobachtungen. Das Ergebnis bleibt gespeichert, bis sich Beobachtungen,
    /// Einstellung oder (im 15-Minuten-Raster) die Zeit ändern; die Berechnung ist aufwendig.
    public func overlay(options: SynopOverlayOptions, now: Date) -> SynopOverlay {
        guard options.isActive else { return SynopOverlay() }
        let key = "\(revision)|\(options.isobarStepHPa)|\(options.temperatureField)|\(Int(now.timeIntervalSince1970 / 900))"
        if let cached = overlayCache, cached.key == key { return cached.overlay }

        var result = SynopOverlay()
        var notes: [String] = []
        let recent = observations.values.filter { o in
            guard let p = o.position, p.isValid else { return false }
            return now.timeIntervalSince(o.received) <= Self.overlayMaxAge
        }

        if options.isobarStepHPa > 0 {
            // Nur Druck auf Meereshöhe: der Stationsdruck hängt von der Höhe der Station ab
            let samples = recent.compactMap { o -> FieldSample? in
                guard let p = o.seaLevelPressureHPa, p > 900, p < 1090, let pos = o.position else { return nil }
                return FieldSample(point: pos, value: p)
            }
            if let grid = WeatherField.grid(samples: samples) {
                var index = 0
                for line in WeatherField.contourLines(of: grid, step: Double(options.isobarStepHPa)) {
                    let long = line.points.count >= 12
                    result.contours.append(MapContour(id: "iso-\(Int(line.level.rounded()))-\(index)", level: line.level, points: line.points,
                                                      label: long ? String(Int(line.level.rounded())) : nil,
                                                      labelPoint: long ? line.points[line.points.count / 2] : nil))
                    index += 1
                }
                for (i, e) in WeatherField.extrema(of: grid).enumerated() {
                    let value = Int(e.value.rounded())
                    result.centers.append(MapMarker(id: "hl-\(i)", coordinate: e.point, title: e.isHigh ? "Hoch" : "Tief",
                                                    subtitle: "\(value) hPa · berechnet",
                                                    details: [Geo.format(e.point), "Aus \(samples.count) Stationen berechnet (Näherung)"],
                                                    tone: .weather, valueText: (e.isHigh ? "H " : "T ") + String(value),
                                                    valueLevel: e.isHigh ? 0.0 : 1.0))
                }
                if result.contours.isEmpty { notes.append("Isobaren: kein Druckgefälle im Gebiet") }
            } else {
                notes.append("Isobaren: mindestens 5 Stationen mit Druck auf Meereshöhe nötig (jetzt \(samples.count))")
            }
        }

        if options.temperatureField {
            let samples = recent.compactMap { o -> FieldSample? in
                guard let t = o.temperatureC, t > -60, t < 60, let pos = o.position else { return nil }
                return FieldSample(point: pos, value: t)
            }
            if let grid = WeatherField.grid(samples: samples) {
                result.patches = WeatherField.patches(of: grid, bandWidth: 2.5) { min(max(($0 + 20) / 55, 0), 1) }
            } else {
                notes.append("Temperaturfläche: mindestens 5 Stationen mit Temperatur nötig (jetzt \(samples.count))")
            }
        }

        result.note = notes.isEmpty ? nil : notes.joined(separator: " · ")
        overlayCache = (key, result)
        return result
    }
}
