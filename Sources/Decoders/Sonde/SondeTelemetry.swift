// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Telemetrie

/// Ein gelesener Rahmen einer Radiosonde (eine Sekunde Flug). Felder ohne Wert fehlen, wenn der zugehörige Block ungültig war oder noch Kalibrierdaten fehlen.
public struct SondeTelemetry: Equatable, Sendable {
    public var serial: String
    public var frame: Int
    /// UTC aus GPS-Woche und -Zeit (Schaltsekunden abgezogen)
    public var time: Date?
    public var latitude: Double?
    public var longitude: Double?
    /// Höhe über dem Ellipsoid in m
    public var altitude: Double?
    /// Horizontale Geschwindigkeit (m/s), Richtung (Grad, woher es geht: Kurs über Grund) und Steigen (m/s)
    public var speed: Double?
    public var heading: Double?
    public var climb: Double?
    public var satellites: Int?
    public var battery: Double?
    public var temperature: Double?
    public var humidity: Double?
    public var pressure: Double?
    /// Sendefrequenz laut Sonde (kHz; nur RS41 meldet sie) und Typ („RS41-SG“, „DFM-09“, „M10“, „M20“ …)
    public var frequencyKHz: Int?
    public var model: String?
    /// Zähler bis zum Abschalten (Burst-/Kill-Timer), Sekunden (nur RS41)
    public var killCountdown: Int?
    /// Anzahl der von der Fehlerkorrektur behobenen Bytes (RS41) oder Bits (DFM) in diesem Rahmen; −1: nur Teile des Rahmens gültig
    public var correctedBytes = 0

    public var hasPosition: Bool { latitude != nil && longitude != nil && altitude != nil }
}

/// Zähler für die Anzeige und die Diagnose
public struct SondeStats: Equatable, Sendable {
    /// Kopf (Synchronwort) gefunden
    public var headers = 0
    /// Rahmen mit bestandener Fehlerkorrektur
    public var frames = 0
    /// Nur Teile mit gültiger Prüfsumme lesbar (Fehlerkorrektur scheiterte)
    public var partial = 0
    /// Kopf gefunden, aber nichts Lesbares
    public var failed = 0
    /// Von der Fehlerkorrektur behobene Bytes (Summe)
    public var corrected = 0
    /// Zeitpunkt (Audiozeit in s) des letzten Rahmens
    public var lastFrameTime: Double?
}

// MARK: - Empfänger

/// Ein Empfänger für eine Sondenart: nimmt FM-Diskriminator-Audio und liefert Telemetrie
protocol SondeReceiving: AnyObject {
    var onTelemetry: ((SondeTelemetry) -> Void)? { get set }
    var stats: SondeStats { get }
    /// Eingangspegel (Mittelwert des Betrags nach Abzug des Gleichanteils)
    var level: Double { get }
    func process(_ samples: UnsafeBufferPointer<Float>)
    func reset()
    func resetStats()
}

extension SondeStats {
    /// Zähler mehrerer Empfänger zusammenfassen
    static func + (a: SondeStats, b: SondeStats) -> SondeStats {
        var s = SondeStats()
        s.headers = a.headers + b.headers
        s.frames = a.frames + b.frames
        s.partial = a.partial + b.partial
        s.failed = a.failed + b.failed
        s.corrected = a.corrected + b.corrected
        s.lastFrameTime = [a.lastFrameTime, b.lastFrameTime].compactMap { $0 }.max()
        return s
    }
}
