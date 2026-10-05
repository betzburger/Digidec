// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Dienste mit Sendeplan (alle Zeiten UTC, Plan gilt täglich gleich)
public enum BroadcastService: String, CaseIterable, Identifiable, Codable, Sendable {
    case wefax, rtty, navtex, sonde

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .wefax:  return "WEFAX"
        case .rtty:   return "RTTY"
        case .navtex: return "NAVTEX"
        case .sonde:  return "SONDE"
        }
    }

    public var module: DecoderModuleInfo {
        switch self {
        case .wefax:  return .wefax
        case .rtty:   return .rtty
        case .navtex: return .navtex
        case .sonde:  return .sonde
        }
    }
}

/// Eine Sendung eines Plans in einheitlicher Form (für Zeitrechnung und automatische Aufnahme)
public struct ScheduledItem: Identifiable, Equatable, Sendable {
    public let service: BroadcastService
    /// eindeutig innerhalb des Dienstes (WEFAX „1636“, RTTY „1-0005“, NAVTEX „DEU-518-S-Pinneberg@0300“, SONDE „10771|0|1045“)
    public let id: String
    /// Beginn in Minuten seit 00:00 UTC
    public let startMinute: Int
    public let durationMinutes: Int
    public let title: String
    /// Wochentag (UTC) des Beginns: 1 = Montag … 7 = Sonntag; nil = täglich (alle Pläne außer SONDE)
    public let weekday: Int?
    /// Wie spät (Sekunden nach dem Beginn) die automatische Aufnahme noch einsteigen darf; nil = Vorgabe von `ScheduleCalc.due`.
    /// Eine Sonde fliegt über Stunden, ein später Einstieg verliert nichts.
    public let joinLate: TimeInterval?

    public init(service: BroadcastService, id: String, startMinute: Int, durationMinutes: Int, title: String,
                weekday: Int? = nil, joinLate: TimeInterval? = nil) {
        self.service = service
        self.id = id
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.title = title
        self.weekday = weekday
        self.joinLate = joinLate
    }
}

/// Zeitrechnung für tägliche Pläne (rein, ohne Zustand)
public enum ScheduleCalc {
    public struct Due: Equatable, Sendable {
        public let item: ScheduledItem
        public let start: Date
        public let end: Date
        /// „JJJJMMTT-<Dienst>-<id>“, einmalig je Tag und Sendung
        public let key: String
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func dayKey(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func start(of item: ScheduledItem, onDayOf day: Date) -> Date {
        utcCalendar.startOfDay(for: day).addingTimeInterval(Double(item.startMinute) * 60)
    }

    /// Wochentag (UTC) eines Zeitpunkts: 1 = Montag … 7 = Sonntag
    public static func isoWeekday(_ date: Date) -> Int {
        (utcCalendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// Gilt die Sendung an dem (UTC-)Tag von `day`? Pläne ohne Wochentag gelten täglich.
    public static func applies(_ item: ScheduledItem, onDayOf day: Date) -> Bool {
        item.weekday.map { $0 == isoWeekday(day) } ?? true
    }

    /// Nächste Sendung nach `date` (heute, sonst morgen, bei Wochentagsplänen bis in die nächste Woche); bei gleichem Beginn die zuerst gelistete
    public static func next(items: [ScheduledItem], after date: Date) -> (item: ScheduledItem, start: Date)? {
        var best: (ScheduledItem, Date)?
        for dayOffset in 0...7 {
            let day = date.addingTimeInterval(Double(dayOffset) * 86_400)
            for item in items where applies(item, onDayOf: day) {
                let s = start(of: item, onDayOf: day)
                if s > date, best == nil || s < best!.1 { best = (item, s) }
            }
            if best != nil { break }
        }
        return best.map { (item: $0.0, start: $0.1) }
    }

    /// Läuft gerade eine Sendung? (die zuletzt begonnene)
    public static func running(items: [ScheduledItem], at date: Date) -> (item: ScheduledItem, start: Date)? {
        var best: (ScheduledItem, Date)?
        for dayOffset in [-1, 0] {
            let day = date.addingTimeInterval(Double(dayOffset) * 86_400)
            for item in items where applies(item, onDayOf: day) {
                let s = start(of: item, onDayOf: day)
                if date >= s && date < s.addingTimeInterval(Double(item.durationMinutes) * 60), best == nil || s > best!.1 { best = (item, s) }
            }
        }
        return best.map { (item: $0.0, start: $0.1) }
    }

    /// Ausgewählte Sendung, die jetzt aufgenommen werden soll: ab `lead` Sekunden vor dem Beginn; Einstieg höchstens
    /// `maxLate` Sekunden nach dem Beginn (später gäbe es nur Reste) und nur vor dem Ende + `tail`. `handled` enthält die
    /// Schlüssel bereits begonnener Aufnahmen. Bei mehreren Treffern gewinnt der früheste Beginn.
    public static func due(items: [ScheduledItem], selected: Set<String>, at date: Date, handled: Set<String>,
                           lead: TimeInterval = 90, tail: TimeInterval = 60, maxLate: TimeInterval = 120) -> Due? {
        var best: Due?
        for dayOffset in [-1, 0, 1] {
            let day = date.addingTimeInterval(Double(dayOffset) * 86_400)
            for item in items where selected.contains(item.id) && applies(item, onDayOf: day) {
                let s = start(of: item, onDayOf: day)
                let e = s.addingTimeInterval(Double(item.durationMinutes) * 60)
                let key = dayKey(s) + "-" + item.service.rawValue + "-" + item.id
                guard date >= s.addingTimeInterval(-lead), date < min(e.addingTimeInterval(tail), s.addingTimeInterval(item.joinLate ?? maxLate)),
                      !handled.contains(key) else { continue }
                if best == nil || s < best!.start { best = Due(item: item, start: s, end: e, key: key) }
            }
        }
        return best
    }

    /// Was die Aufnahmesteuerung in diesem Takt tun soll
    public enum Decision: Equatable, Sendable {
        /// nichts zu tun
        case idle
        /// eine fällige Aufnahme beginnen (keine läuft)
        case begin
        /// die laufende Aufnahme geht weiter
        case keep
        /// die laufende ist zu Ende; die fällige Folgesendung nahtlos beginnen (ohne Rückkehr zum vorigen Modul)
        case chain
        /// die fällige Sendung überschneidet sich mit der laufenden: überspringen
        case skipConflict
        /// die laufende Aufnahme beenden (Nachlauf abgelaufen) und zum vorigen Modul zurückkehren
        case end
    }

    /// Entscheidung je Takt. Eine Folgesendung wartet, bis die laufende zu Ende ist (kein Abschneiden); beginnt sie vor dem
    /// Ende der laufenden (mehr als 60 s), ist es eine Überschneidung. Es läuft immer nur ein Dienst.
    public static func decide(sessionEnd: Date?, tail: TimeInterval, due: Due?, now: Date) -> Decision {
        guard let end = sessionEnd else { return due == nil ? .idle : .begin }
        if let due {
            if due.start >= end.addingTimeInterval(-60) { return now >= end.addingTimeInterval(-5) ? .chain : .keep }
            return .skipConflict
        }
        return now > end.addingTimeInterval(tail) ? .end : .keep
    }
}
