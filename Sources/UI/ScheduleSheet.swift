// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - Zeitformate

enum ScheduleTime {
    static let utc: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    static let local: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .current; return f
    }()
    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; f.locale = Locale(identifier: "de_DE"); return f
    }()

    /// „in 29 min“, „in 1 h 05 min“
    static func countdown(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60))
        return m >= 60 ? String(format: "in %d h %02d min", m / 60, m % 60) : "in \(m) min"
    }

    static func hhmm(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// Beginn einer Sendung heute (UTC-Tag) für die Anzeige der Ortszeit
    static func startToday(_ minute: Int, now: Date) -> Date {
        ScheduleCalc.start(of: ScheduledItem(service: .wefax, id: "", startMinute: minute, durationMinutes: 1, title: ""), onDayOf: now)
    }
}

// MARK: - Statuszeile

/// Laufende Aufnahme bzw. nächste ausgewählte Aufnahme; `fallback` zeigt sonst die nächste Sendung des Plans
struct ScheduleNextLine: View {
    @ObservedObject var auto: ScheduleAutoRecorder
    var fallback: ((Date) -> (title: String, start: Date)?)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 2) {
                if let s = auto.session {
                    Label("AUFNAHME \(s.service.label) · \(s.title) · bis \(ScheduleTime.utc.string(from: s.end)) UTC", systemImage: "record.circle.fill")
                        .foregroundColor(RadioTheme.ledRed)
                } else if let n = auto.nextSelected(after: now) {
                    Label("Nächste Aufnahme \(ScheduleTime.utc.string(from: n.start)) UTC (\(ScheduleTime.local.string(from: n.start))) · \(ScheduleTime.countdown(n.start.timeIntervalSince(now)))",
                          systemImage: "clock.badge.checkmark")
                        .foregroundColor(RadioTheme.vfdAmber)
                    Text("\(n.service.label) · \(n.title)").foregroundColor(RadioTheme.textDim)
                } else if let n = fallback?(now) {
                    Label("Nächste Sendung \(ScheduleTime.utc.string(from: n.start)) UTC (\(ScheduleTime.local.string(from: n.start))) · \(ScheduleTime.countdown(n.start.timeIntervalSince(now)))",
                          systemImage: "clock")
                        .foregroundColor(RadioTheme.textDim)
                    Text(n.title).foregroundColor(RadioTheme.textMuted)
                }
                if let note = auto.note {
                    Text(note).foregroundColor(RadioTheme.textMuted)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Statuszeile im WEFAX-Panel (zeigt auch die nächste Sendung des Faxplans, wenn nichts aufgenommen wird)
struct WefaxNextLine: View {
    @ObservedObject var store: WefaxScheduleStore
    @ObservedObject var auto: ScheduleAutoRecorder

    var body: some View {
        ScheduleNextLine(auto: auto) { now in
            store.schedule.next(after: now).map { (title: $0.broadcast.title, start: $0.start) }
        }
    }
}

// MARK: - Gemeinsame Bausteine

private struct PlanHeader: View {
    let title: String
    let lines: [String]
    var message: String?
    var isUpdating = false
    var updateHelp = "Holt den aktuellen Sendeplan von dwd.de (PDF) und merkt ihn sich"
    var onUpdate: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                Spacer()
                if let onUpdate {
                    Button(action: onUpdate) {
                        HStack(spacing: 5) {
                            if isUpdating { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                            Text("AKTUALISIEREN")
                        }
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(isUpdating)
                    .help(updateHelp)
                }
                Button("SCHLIESSEN", action: onClose).buttonStyle(ModeButtonStyle(isSelected: false))
            }
            ForEach(lines, id: \.self) { l in
                Text(l)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            if let m = message {
                Text(m)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(m.hasPrefix("Aktualisiert") || m.hasPrefix("Plan unverändert") ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
            }
        }
    }
}

private struct ColumnTitle: View {
    let text: String
    let width: CGFloat?
    var alignment: Alignment = .leading
    var body: some View {
        Text(text)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

private func checkbox(_ on: Bool) -> some View {
    Image(systemName: on ? "checkmark.square.fill" : "square").foregroundColor(on ? RadioTheme.vfdAmber : RadioTheme.textDim)
}

private let rowFont = Font.system(size: 10, weight: .medium, design: .monospaced)

// MARK: - Fenster

struct ScheduleSheet: View {
    @ObservedObject var state: DigidecState
    @State var tab: BroadcastService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(BroadcastService.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScheduleNextLine(auto: state.autoRecorder)
                .padding(8)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)

            switch tab {
            case .wefax:  WefaxScheduleTab(store: state.wefaxSchedule, auto: state.autoRecorder, close: { dismiss() })
            case .rtty:   RttyScheduleTab(store: state.rttySchedule, auto: state.autoRecorder, close: { dismiss() })
            case .navtex: NavtexScheduleTab(store: state.navtexPlan, auto: state.autoRecorder, close: { dismiss() })
            case .sonde:  SondeScheduleTab(store: state.sondePlan, auto: state.autoRecorder, home: state.home, settings: state.sonde,
                                           tune: { kHz in
                                               state.sonde.frequencyKHz = kHz
                                               state.activeModule = .sonde
                                           },
                                           close: { dismiss() })
            }
        }
        .padding(16)
        .frame(width: 900, height: 720)
        .background(RadioTheme.bgPanel)
    }
}

// MARK: - Fußzeile mit Hauptschalter

private struct AutoFooter: View {
    @Binding var autoEnabled: Bool
    @Binding var returnToPrevious: Bool
    let selectedCount: Int
    let auto: ScheduleAutoRecorder
    var extra: AnyView?
    var onAll: (() -> Void)?
    var onNone: (() -> Void)?
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: $autoEnabled) {
                    Text("Ausgewählte Sendungen automatisch aufnehmen")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .toggleStyle(.switch)
                Spacer()
                Text("\(selectedCount) gewählt")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                if let onAll { Button("ALLE", action: onAll).buttonStyle(ModeButtonStyle(isSelected: false)) }
                if let onNone { Button("KEINE", action: onNone).buttonStyle(ModeButtonStyle(isSelected: false)) }
            }
            HStack(spacing: 14) {
                if let extra { extra }
                Toggle("danach zurück zum vorigen Modul", isOn: $returnToPrevious)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            Text(note)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            if auto.session != nil {
                Button("LAUFENDE AUFNAHME ABBRECHEN") { auto.cancelSession() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .foregroundColor(RadioTheme.ledRed)
            }
        }
    }
}

// MARK: - Reiter WEFAX

struct WefaxScheduleTab: View {
    @ObservedObject var store: WefaxScheduleStore
    @ObservedObject var auto: ScheduleAutoRecorder
    let close: () -> Void
    /// `false` nur für die Offscreen-Vorschau (ImageRenderer zeichnet keine ScrollView)
    var scrolls = true

    private enum Row: Identifiable {
        case broadcast(WefaxBroadcast)
        case pause(WefaxPause)
        var id: String {
            switch self {
            case .broadcast(let b): return "b" + b.id
            case .pause(let p): return "p\(p.startMinute)"
            }
        }
        var minute: Int {
            switch self {
            case .broadcast(let b): return b.startMinute
            case .pause(let p): return p.startMinute
            }
        }
    }

    private var rows: [Row] {
        (store.schedule.broadcasts.map(Row.broadcast) + store.schedule.pauses.map(Row.pause)).sorted { $0.minute < $1.minute }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let freqs = store.schedule.frequenciesHz.map { String(format: "%g", $0 / 1000).replacingOccurrences(of: ".", with: ",") }.joined(separator: " · ")
            PlanHeader(title: "DWD RADIOFAX-SENDEPLAN",
                       lines: ["Sender Pinneberg: \(freqs) kHz · 120 UpM · Modul 576 · täglich gleich · Zeiten UTC",
                               "Quelle: \(store.sourceName)" + (store.updatedAt.map { " · abgerufen \(ScheduleTime.stamp.string(from: $0))" } ?? "")],
                       message: store.message, isUpdating: store.isUpdating,
                       onUpdate: { Task { await store.update() } }, onClose: close)
            Divider()
            list
            Divider()
            AutoFooter(autoEnabled: $store.autoEnabled, returnToPrevious: $store.returnToPreviousModule,
                       selectedCount: store.selected.count, auto: auto,
                       extra: AnyView(HStack(spacing: 14) {
                           Picker("Standardfrequenz", selection: $store.frequencyChoice) {
                               ForEach(WefaxFrequencyChoice.allCases) { Text($0.label).tag($0) }
                           }
                           .frame(width: 420)
                           Toggle("Audio als WAV mitschneiden", isOn: $store.recordAudio)
                               .help("Zusätzlich das Eingangssignal speichern (ca. 100 MB je Sendung bei 48 kHz)")
                       }),
                       onAll: { store.selectAll() }, onNone: { store.selectNone() },
                       note: "Orange Frequenzen sind für die Sendung fest gewählt – das passiert auch, wenn du während der Aufnahme von Hand umstellst. Zur Sendezeit schaltet Digidec auf WEFAX, wählt die Frequenz (mit QSY AUTO stimmt es auch das Funkgerät ab) und legt die Bilder als PNG ab. Digidec muss laufen und der Mac wach sein; während einer Aufnahme verhindert Digidec den Ruhezustand.")
        }
    }

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let now = context.date
            let running = ScheduleCalc.running(items: store.schedule.items, at: now)?.item.id
            let next = ScheduleCalc.next(items: store.schedule.items, after: now)?.item.id
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ColumnTitle(text: "", width: 22)
                    ColumnTitle(text: "UTC", width: 46)
                    ColumnTitle(text: TimeZone.current.abbreviation() ?? "LOKAL", width: 56)
                    ColumnTitle(text: "MIN", width: 34, alignment: .trailing)
                    ColumnTitle(text: "TERMIN", width: 56)
                    ColumnTitle(text: "KARTENINHALT", width: nil)
                    ColumnTitle(text: "kHz", width: 62, alignment: .trailing)
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                if scrolls { ScrollView { rowsView(running: running, next: next, now: now) } } else { rowsView(running: running, next: next, now: now) }
            }
        }
    }

    private func rowsView(running: String?, next: String?, now: Date) -> some View {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                switch row {
                case .broadcast(let b): broadcastRow(b, running: b.id == running, next: b.id == next, now: now)
                case .pause(let p): pauseRow(p)
                }
            }
        }
    }

    private func broadcastRow(_ b: WefaxBroadcast, running: Bool, next: Bool, now: Date) -> some View {
        let start = WefaxSchedule.startDate(of: b, onDayOf: now)
        let selected = store.selected.contains(b.id)
        return HStack(spacing: 8) {
            Button { store.toggle(b) } label: { checkbox(selected) }
                .buttonStyle(.plain)
                .frame(width: 22)
                .help(selected ? "Wird automatisch aufgenommen (wenn der Hauptschalter an ist)" : "Zur automatischen Aufnahme vormerken")
            Text(ScheduleTime.utc.string(from: start)).frame(width: 46, alignment: .leading)
            Text(ScheduleTime.local.string(from: start)).frame(width: 56, alignment: .leading).foregroundColor(RadioTheme.textDim)
            Text("\(b.durationMinutes)").frame(width: 34, alignment: .trailing).foregroundColor(RadioTheme.textDim)
            Text(String(format: "%02d UTC", b.chartHour)).frame(width: 56, alignment: .leading).foregroundColor(RadioTheme.textDim)
            Text(b.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            frequencyMenu(for: b, start: start)
            statusTag(running: running, next: next)
        }
        .font(rowFont)
        .foregroundColor(RadioTheme.textBright)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(running ? RadioTheme.vfdGreen.opacity(0.12) : (selected ? RadioTheme.vfdAmber.opacity(0.08) : RadioTheme.bgDeep.opacity(0.6)))
        .cornerRadius(4)
    }

    private func frequencyMenu(for b: WefaxBroadcast, start: Date) -> some View {
        let override = store.frequencyOverrides[b.id]
        let khz: String = {
            switch store.choice(for: b).station(at: start) {
            case .dwd3855: return "3855"
            case .dwd13882: return "13882,5"
            default: return "7880"
            }
        }()
        return Menu {
            Button("Standard (\(store.frequencyChoice.label))") { store.setOverride(nil, for: b) }
            Divider()
            ForEach([WefaxFrequencyChoice.f3855, .f7880, .f13882]) { c in Button(c.label) { store.setOverride(c, for: b) } }
        } label: {
            Text(khz).foregroundColor(override == nil ? RadioTheme.textDim : RadioTheme.vfdAmber)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 62, alignment: .trailing)
        .help(override == nil ? "Standardfrequenz – klicken, um für diese Sendung eine feste Frequenz zu wählen"
                              : "Feste Frequenz für diese Sendung (Digidec merkt sich auch eine von Hand geänderte Frequenz)")
    }

    private func pauseRow(_ p: WefaxPause) -> some View {
        HStack(spacing: 8) {
            Text("").frame(width: 22)
            Text("\(ScheduleTime.hhmm(p.startMinute))–\(ScheduleTime.hhmm(p.endMinute))")
            Text("Sendepause (Sprachsendung auf 5905 und 6180 kHz)")
            Spacer()
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundColor(RadioTheme.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

@ViewBuilder
private func statusTag(running: Bool, next: Bool) -> some View {
    if running {
        Text("LÄUFT").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen).frame(width: 44)
    } else if next {
        Text("NÄCHSTE").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(RadioTheme.vfdAmber).frame(width: 44)
    } else {
        Color.clear.frame(width: 44, height: 1)
    }
}

// MARK: - Reiter RTTY

struct RttyScheduleTab: View {
    @ObservedObject var store: RttyScheduleStore
    @ObservedObject var auto: ScheduleAutoRecorder
    let close: () -> Void
    var scrolls = true
    @State private var programFilter = 0     // 0 = alle
    @State private var textFilter = ""

    private var visible: [RttyBroadcast] {
        store.schedule.broadcasts.filter { b in
            (programFilter == 0 || b.program == programFilter)
                && (textFilter.isEmpty || b.title.localizedCaseInsensitiveContains(textFilter) || (b.header ?? "").localizedCaseInsensitiveContains(textFilter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let p1 = store.schedule.frequencies(forProgram: 1).map(\.label).joined(separator: " · ")
            let p2 = store.schedule.frequencies(forProgram: 2).map(\.label).joined(separator: " · ")
            PlanHeader(title: "DWD FUNKFERNSCHREIBEN (RTTY)",
                       lines: ["Programm 1: \(p1)   ·   Programm 2: \(p2)",
                               "Sender Pinneberg · F1B 50 Baud · Hub ±225 Hz (Langwelle ±42,5 Hz) · täglich gleich · Zeiten UTC",
                               "Quelle: \(store.sourceName)" + (store.updatedAt.map { " · abgerufen \(ScheduleTime.stamp.string(from: $0))" } ?? "")],
                       message: store.message, isUpdating: store.isUpdating,
                       onUpdate: { Task { await store.update() } }, onClose: close)
            HStack(spacing: 10) {
                Picker("Programm", selection: $programFilter) {
                    Text("Beide").tag(0); Text("1").tag(1); Text("2").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                TextField("Filter (z. B. Seewetter, WODL45)", text: $textFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                Text("\(visible.count) Sendungen")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            Divider()
            list
            Divider()
            AutoFooter(autoEnabled: $store.autoEnabled, returnToPrevious: $store.returnToPreviousModule,
                       selectedCount: store.selected.count, auto: auto,
                       extra: AnyView(HStack(spacing: 14) {
                           defaultMenu(program: 1)
                           defaultMenu(program: 2)
                       }),
                       onAll: { store.selected.formUnion(visible.map(\.id)) },
                       onNone: { store.selected.subtract(visible.map(\.id)) },
                       note: "ALLE/KEINE betreffen die gefilterte Liste. Zur Sendezeit schaltet Digidec auf RTTY, wählt Voreinstellung (DWD KW bzw. LW) und Frequenz (mit QSY AUTO stimmt es auch das Funkgerät ab) und schreibt das Log. Digidec muss laufen und der Mac wach sein.")
        }
    }

    private func defaultMenu(program: Int) -> some View {
        let current = store.defaultFrequencyHz[program] ?? 0
        let label = current > 0 ? (store.schedule.frequencies(forProgram: program).first { $0.hz == current }?.label ?? "Automatisch") : "Automatisch"
        return Menu {
            Button("Automatisch") { store.setDefaultFrequency(nil, program: program) }
            Divider()
            ForEach(store.schedule.frequencies(forProgram: program)) { f in Button(f.label) { store.setDefaultFrequency(f.hz, program: program) } }
        } label: {
            Text("Programm \(program): \(label)")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 200, alignment: .leading)
        .help("Standardfrequenz für Programm \(program); Automatisch: Programm 1 nachts 4583 / tags 7646 kHz, Programm 2 Langwelle 147,3 kHz")
    }

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let now = context.date
            let running = ScheduleCalc.running(items: store.schedule.items, at: now)?.item.id
            let next = ScheduleCalc.next(items: store.schedule.items, after: now)?.item.id
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ColumnTitle(text: "", width: 22)
                    ColumnTitle(text: "UTC", width: 46)
                    ColumnTitle(text: TimeZone.current.abbreviation() ?? "LOKAL", width: 56)
                    ColumnTitle(text: "MIN", width: 34, alignment: .trailing)
                    ColumnTitle(text: "P", width: 18)
                    ColumnTitle(text: "INHALT", width: nil)
                    ColumnTitle(text: "KOPFZEILE", width: 150)
                    ColumnTitle(text: "kHz", width: 62, alignment: .trailing)
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                if scrolls { ScrollView { rows(running: running, next: next, now: now) } } else { rows(running: running, next: next, now: now) }
            }
        }
    }

    private func rows(running: String?, next: String?, now: Date) -> some View {
        VStack(spacing: 2) {
            ForEach(visible) { b in row(b, running: b.id == running, next: b.id == next, now: now) }
        }
    }

    private func row(_ b: RttyBroadcast, running: Bool, next: Bool, now: Date) -> some View {
        let start = ScheduleTime.startToday(b.startMinute, now: now)
        let selected = store.selected.contains(b.id)
        let freq = store.frequency(for: b, at: start)
        let overridden = store.frequencyOverrides[b.id] != nil
        return HStack(spacing: 8) {
            Button { store.toggle(b) } label: { checkbox(selected) }
                .buttonStyle(.plain)
                .frame(width: 22)
            Text(ScheduleTime.hhmm(b.startMinute)).frame(width: 46, alignment: .leading)
            Text(ScheduleTime.local.string(from: start)).frame(width: 56, alignment: .leading).foregroundColor(RadioTheme.textDim)
            Text("\(b.durationMinutes)").frame(width: 34, alignment: .trailing).foregroundColor(RadioTheme.textDim)
            Text("\(b.program)").frame(width: 18, alignment: .leading).foregroundColor(RadioTheme.vfdCyan)
            Text(b.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2).help(b.title)
            Text(b.header ?? "").frame(width: 150, alignment: .leading).foregroundColor(RadioTheme.textDim).lineLimit(2)
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
            Menu {
                Button("Standard") { store.setOverride(nil, for: b) }
                Divider()
                ForEach(store.schedule.frequencies(forProgram: b.program)) { f in Button(f.label) { store.setOverride(f.hz, for: b) } }
            } label: {
                Text(freq.map { $0.label.replacingOccurrences(of: " kHz", with: "") } ?? "–")
                    .foregroundColor(overridden ? RadioTheme.vfdAmber : RadioTheme.textDim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 62, alignment: .trailing)
            statusTag(running: running, next: next)
        }
        .font(rowFont)
        .foregroundColor(RadioTheme.textBright)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(running ? RadioTheme.vfdGreen.opacity(0.12) : (selected ? RadioTheme.vfdAmber.opacity(0.08) : RadioTheme.bgDeep.opacity(0.6)))
        .cornerRadius(4)
    }
}

// MARK: - Reiter NAVTEX

struct NavtexScheduleTab: View {
    @ObservedObject var store: NavtexPlanStore
    @ObservedObject var auto: ScheduleAutoRecorder
    let close: () -> Void
    var scrolls = true
    @State private var text = ""
    @State private var frequencyFilter = 0.0      // 0 = alle
    @State private var onlySelected = false

    private var visible: [NavtexStation] {
        store.plan.stations.filter { s in
            (frequencyFilter == 0 || s.frequencyKHz == frequencyFilter)
                && (!onlySelected || store.selectedStationIDs.contains(s.id))
                && (text.isEmpty || s.name.localizedCaseInsensitiveContains(text) || s.country.localizedCaseInsensitiveContains(text)
                    || s.countryCode.localizedCaseInsensitiveContains(text) || String(s.letter).caseInsensitiveCompare(text) == .orderedSame)
        }
        .sorted { a, b in
            // gewählte Stationen oben, dann nach Land, Frequenz und Kennung
            let (sa, sb) = (store.selectedStationIDs.contains(a.id), store.selectedStationIDs.contains(b.id))
            if sa != sb { return sa }
            return (a.country, a.frequencyKHz, a.letter) < (b.country, b.frequencyKHz, b.letter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanHeader(title: "NAVTEX-SENDEFENSTER",
                       lines: ["Nach dem IMO-Raster berechnet: sechs Blöcke zu vier Stunden (00, 04, 08, 12, 16, 20 UTC), darin je Station ein 10-Minuten-Fenster (A = +0, B = +10 … X = +230 min).",
                               "Die Zeiten sind international festgelegt, ein Abruf aus dem Netz ist nicht nötig. Einzelne Stationen weichen ab; eine Station sendet nur, wenn Meldungen vorliegen. Pinneberg: 518 kHz = S (03:00 …), 490 kHz = L (01:50 …)."],
                       message: nil, onUpdate: nil, onClose: close)
            HStack(spacing: 10) {
                TextField("Station, Land oder Kennbuchstabe", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                Picker("", selection: $frequencyFilter) {
                    Text("Alle Frequenzen").tag(0.0)
                    Text("518 kHz").tag(518.0)
                    Text("490 kHz").tag(490.0)
                    Text("4209,5 kHz").tag(4209.5)
                }
                .labelsHidden()
                .frame(width: 150)
                Toggle("nur gewählte", isOn: $onlySelected).font(.system(size: 10, design: .monospaced))
                Text("\(visible.count) von \(store.plan.stations.count) Stationen")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            Divider()
            stationList
            Divider()
            upcoming
            Divider()
            AutoFooter(autoEnabled: $store.autoEnabled, returnToPrevious: $store.returnToPreviousModule,
                       selectedCount: store.selectedStationIDs.count, auto: auto, extra: nil,
                       onAll: nil, onNone: { store.selectedStationIDs = [] },
                       note: "Zur Sendezeit der gewählten Stationen schaltet Digidec auf NAVTEX, wählt 518/490/4209,5 kHz (mit QSY AUTO stimmt es auch das Funkgerät ab) und schreibt das Log. Digidec muss laufen und der Mac wach sein.")
        }
    }

    private var stationList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ColumnTitle(text: "", width: 22)
                    ColumnTitle(text: "ID", width: 22)
                    ColumnTitle(text: "STATION", width: nil)
                    ColumnTitle(text: "LAND", width: 120)
                    ColumnTitle(text: "kHz", width: 56)
                    ColumnTitle(text: "AREA", width: 34)
                    ColumnTitle(text: "NÄCHSTE (UTC)", width: 110, alignment: .trailing)
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                if scrolls {
                    ScrollView { rows(now: now) }.frame(maxHeight: 250)
                } else {
                    rows(now: now)
                }
            }
        }
    }

    private func rows(now: Date) -> some View {
        VStack(spacing: 2) {
            ForEach(visible) { s in
                let selected = store.selectedStationIDs.contains(s.id)
                let next = ScheduleCalc.next(items: store.plan.items(forStationIDs: [s.id]), after: now)
                HStack(spacing: 8) {
                    Button { store.toggle(s) } label: { checkbox(selected) }.buttonStyle(.plain).frame(width: 22)
                    Text(String(s.letter)).frame(width: 22, alignment: .leading).foregroundColor(RadioTheme.vfdCyan)
                    Text(s.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(s.country).frame(width: 120, alignment: .leading).foregroundColor(RadioTheme.textDim).lineLimit(1)
                    Text(s.frequencyLabel.replacingOccurrences(of: " kHz", with: "")).frame(width: 56, alignment: .leading).foregroundColor(RadioTheme.textDim)
                    Text(s.navarea).frame(width: 34, alignment: .leading).foregroundColor(RadioTheme.textDim)
                    Text(next.map { ScheduleTime.hhmm($0.item.startMinute) + " (" + ScheduleTime.local.string(from: $0.start) + ")" } ?? "–")
                        .frame(width: 110, alignment: .trailing)
                        .foregroundColor(selected ? RadioTheme.vfdAmber : RadioTheme.textDim)
                }
                .font(rowFont)
                .foregroundColor(RadioTheme.textBright)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? RadioTheme.vfdAmber.opacity(0.08) : RadioTheme.bgDeep.opacity(0.6))
                .cornerRadius(4)
            }
        }
    }

    /// Die nächsten Sendefenster der gewählten Stationen
    private var upcoming: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let items = store.items
            VStack(alignment: .leading, spacing: 3) {
                Text("NÄCHSTE FENSTER DER GEWÄHLTEN STATIONEN")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                if items.isEmpty {
                    Text("Keine Station gewählt").font(rowFont).foregroundColor(RadioTheme.textMuted)
                } else {
                    ForEach(Array(upcomingSlots(items: items, now: now).enumerated()), id: \.offset) { _, slot in
                        HStack(spacing: 8) {
                            Text("\(ScheduleTime.utc.string(from: slot.start)) UTC").frame(width: 70, alignment: .leading)
                            Text(ScheduleTime.local.string(from: slot.start)).frame(width: 46, alignment: .leading).foregroundColor(RadioTheme.textDim)
                            Text(ScheduleTime.countdown(slot.start.timeIntervalSince(now))).frame(width: 110, alignment: .leading).foregroundColor(RadioTheme.textDim)
                            Text(slot.item.title)
                        }
                        .font(rowFont)
                        .foregroundColor(RadioTheme.textBright)
                    }
                }
            }
        }
    }

    private func upcomingSlots(items: [ScheduledItem], now: Date) -> [(item: ScheduledItem, start: Date)] {
        var out: [(ScheduledItem, Date)] = []
        for dayOffset in 0...1 {
            let day = now.addingTimeInterval(Double(dayOffset) * 86_400)
            for item in items {
                let s = ScheduleCalc.start(of: item, onDayOf: day)
                if s > now { out.append((item, s)) }
            }
        }
        return out.sorted { $0.1 < $1.1 }.prefix(5).map { (item: $0.0, start: $0.1) }
    }
}

// MARK: - Reiter SONDE

/// Startorte der Wettersonden (SondeHub) in der Umgebung des Standorts: Zeiten, Frequenz, Entfernung; Auswahl für den automatischen Empfang
struct SondeScheduleTab: View {
    @ObservedObject var store: SondePlanStore
    @ObservedObject var auto: ScheduleAutoRecorder
    @ObservedObject var home: HomeLocation
    @ObservedObject var settings: SondeSettingsStore
    let tune: (Int) -> Void
    let close: () -> Void
    var scrolls = true
    @State private var textFilter = ""
    @State private var onlyUsable = false

    private var ranked: [SondePlan.Ranked] {
        guard let point = home.point else { return [] }
        return SondePlan.nearby(store.sites, home: point, radiusKm: Double(store.radiusKm)).filter { r in
            (!onlyUsable || (!r.site.launches.isEmpty && store.frequencyKHz(for: r.site) != nil))
                && (textFilter.isEmpty || r.site.name.localizedCaseInsensitiveContains(textFilter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanHeader(title: "WETTERSONDEN-STARTS (RS41)",
                       lines: ["Startorte, Zeiten und Frequenzen aus der SondeHub-Datenbank (von Nutzern gepflegt, CC BY-SA 2.0) · Standort \(home.locator.uppercased()) · nur Stationen mit RS41, die Digidec lesen kann",
                               "Zeiten UTC und nominal: die Sonde startet meist vor dem Termin (z. B. 11:15 UTC für 12:00). Nicht jeder Eintrag hat Zeit und Frequenz; Alter des Eintrags (Jahr) beachten. Es wird nichts geraten.",
                               "Quelle: \(store.sourceName)" + (store.updatedAt.map { " · abgerufen \(ScheduleTime.stamp.string(from: $0))" } ?? "")],
                       message: store.message, isUpdating: store.isUpdating,
                       updateHelp: "Holt die Startortliste von api.v2.sondehub.org und merkt sie sich",
                       onUpdate: { Task { await store.update() } }, onClose: close)
            HStack(spacing: 10) {
                Menu {
                    ForEach(SondePlanStore.radiusOptions, id: \.self) { km in Button("bis \(km) km") { store.radiusKm = km } }
                } label: {
                    Text("Umkreis bis \(store.radiusKm) km")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150, alignment: .leading)
                .help("Nur Startorte bis zu dieser Entfernung vom Standort anzeigen")
                TextField("Filter (Name)", text: $textFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                Toggle("nur mit Zeit und Frequenz", isOn: $onlyUsable).font(.system(size: 10, design: .monospaced))
                Text("\(ranked.count) Startorte")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            Divider()
            list
            Divider()
            AutoFooter(autoEnabled: $store.autoEnabled, returnToPrevious: $store.returnToPreviousModule,
                       selectedCount: store.selectedSiteIDs.count, auto: auto,
                       extra: AnyView(HStack(spacing: 14) {
                           leadMenu
                           windowMenu
                       }),
                       onAll: { store.selectedSiteIDs.formUnion(ranked.filter { !$0.site.launches.isEmpty }.map(\.site.id)) },
                       onNone: { store.selectedSiteIDs.subtract(ranked.map(\.site.id)) },
                       note: "Zu den Startzeiten der gewählten Stationen schaltet Digidec auf SONDE und stellt die Frequenz aus der Liste ein (mit QSY AUTO auch das Funkgerät; nur der PCR-1500 empfängt 400 … 406 MHz). Stationen ohne Frequenz werden übersprungen: dort die Frequenz von Hand eintragen. Es empfängt immer nur eine Station; bei Überschneidung läuft die zuerst begonnene weiter. Digidec muss laufen und der Mac wach sein.")
        }
    }

    private var leadMenu: some View {
        Menu {
            ForEach(SondePlanStore.leadOptions, id: \.self) { m in Button("\(m) min vor dem Termin") { store.leadMinutes = m } }
        } label: {
            Text("Beginn \(store.leadMinutes) min vorher")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 170, alignment: .leading)
        .help("Wie viele Minuten vor der nominalen Startzeit der Empfang beginnt")
    }

    private var windowMenu: some View {
        Menu {
            ForEach(SondePlanStore.windowOptions, id: \.self) { m in Button("\(m) min") { store.windowMinutes = m } }
        } label: {
            Text("Dauer \(store.windowMinutes) min")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 130, alignment: .leading)
        .help("So lange bleibt Digidec im Modul SONDE; ein Ballon steigt etwa 1½ bis 2 Stunden")
    }

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ColumnTitle(text: "", width: 22)
                    ColumnTitle(text: "ENTFERNUNG", width: 84)
                    ColumnTitle(text: "STARTORT", width: nil)
                    ColumnTitle(text: "MHz", width: 70)
                    ColumnTitle(text: "STARTZEITEN (UTC)", width: 190)
                    ColumnTitle(text: "NÄCHSTER (UTC)", width: 112)
                    ColumnTitle(text: "STAND", width: 38)
                    ColumnTitle(text: "", width: 26)
                    ColumnTitle(text: "", width: 44)
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                if home.point == nil {
                    Text("Der Standort-Locator ist ungültig – in den Karteneinstellungen korrigieren.")
                        .font(rowFont).foregroundColor(RadioTheme.ledYellow)
                } else if store.sites.isEmpty {
                    Text("Keine Liste vorhanden – AKTUALISIEREN holt sie von SondeHub.")
                        .font(rowFont).foregroundColor(RadioTheme.textMuted)
                }
                if scrolls { ScrollView { rows(now: now) } } else { rows(now: now) }
            }
        }
    }

    private func rows(now: Date) -> some View {
        VStack(spacing: 2) {
            ForEach(ranked) { r in row(r, now: now) }
        }
    }

    private func row(_ r: SondePlan.Ranked, now: Date) -> some View {
        let site = r.site
        let selected = store.selectedSiteIDs.contains(site.id)
        let usable = !site.launches.isEmpty
        let kHz = store.frequencyKHz(for: site)
        let overridden = store.frequencyOverridesKHz[site.id] != nil
        let next = ScheduleCalc.next(items: store.nominalItems(for: site), after: now)
        let running = ScheduleCalc.running(items: store.items(for: site), at: now) != nil
        var nextText = "–"
        if let n = next {
            let day = SondeLaunchTime.weekdayNames[ScheduleCalc.isoWeekday(n.start) - 1]
            nextText = "\(day) \(ScheduleTime.utc.string(from: n.start)) (\(ScheduleTime.local.string(from: n.start)))"
        }
        return HStack(spacing: 8) {
            Button { store.toggle(site) } label: { checkbox(selected) }
                .buttonStyle(.plain)
                .frame(width: 22)
                .disabled(!usable)
                .help(usable ? "Für den automatischen Empfang wählen" : "Keine feste Startzeit eingetragen")
            Text(Geo.formatKm(r.km) + " " + Geo.compass(r.bearing)).frame(width: 84, alignment: .leading)
            Text(site.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).help(siteHelp(site))
            frequencyMenu(site, kHz: kHz, overridden: overridden)
            Text(usable ? SondeLaunchTime.summary(site.launches) : (site.timeNotes.first ?? "keine Zeit eingetragen"))
                .frame(width: 190, alignment: .leading)
                .foregroundColor(usable ? RadioTheme.textBright : RadioTheme.textMuted)
                .lineLimit(2)
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                .help(site.timeNotes.joined(separator: "\n"))
            Text(nextText).frame(width: 112, alignment: .leading)
                .foregroundColor(selected ? RadioTheme.vfdAmber : RadioTheme.textDim)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            Text(site.updated.map { String($0.prefix(4)) } ?? "–").frame(width: 38, alignment: .leading)
                .foregroundColor(RadioTheme.textDim)
                .help(site.updated.map { "Eintrag zuletzt geändert: \($0)" } ?? "Kein Datum im Eintrag")
            Button { if let kHz { tune(kHz) } } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                .buttonStyle(.plain)
                .frame(width: 26)
                .disabled(kHz == nil)
                .help(kHz == nil ? "Keine Frequenz bekannt" : "Jetzt auf \(SondeSettingsStore.text(kHz ?? 0)) abstimmen (Modul SONDE)")
            statusTag(running: running, next: false)
        }
        .font(rowFont)
        .foregroundColor(RadioTheme.textBright)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(running ? RadioTheme.vfdGreen.opacity(0.12) : (selected ? RadioTheme.vfdAmber.opacity(0.08) : RadioTheme.bgDeep.opacity(0.6)))
        .cornerRadius(4)
    }

    private func frequencyMenu(_ site: SondeSite, kHz: Int?, overridden: Bool) -> some View {
        Menu {
            Button("Wie in der Liste" + (site.frequencyKHz.map { " (\(SondeSettingsStore.text($0)))" } ?? " (keine)")) {
                store.setFrequency(nil, for: site)
            }
            Button("Frequenz des Moduls SONDE übernehmen (\(SondeSettingsStore.text(settings.frequencyKHz)))") {
                store.setFrequency(settings.frequencyKHz, for: site)
            }
        } label: {
            Text(kHz.map { String(format: "%.3f", Double($0) / 1000).replacingOccurrences(of: ".", with: ",") } ?? "–")
                .foregroundColor(overridden ? RadioTheme.vfdAmber : RadioTheme.textDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 70, alignment: .leading)
        .help(kHz == nil ? "Keine Frequenz in der Liste – hier eintragen (erst im Modul SONDE einstellen)" : (overridden ? "Eigene Frequenz" : "Frequenz laut Liste"))
    }

    private func siteHelp(_ site: SondeSite) -> String {
        var lines = [site.name, Geo.format(site.point) + " · " + Maidenhead.locator(site.point)]
        if let a = site.altitude { lines.append("Höhe \(a) m") }
        lines.append("Typ laut Eintrag: " + (site.types.isEmpty ? "–" : site.types.joined(separator: ", ")) + "  (41 = Vaisala RS41)")
        if let b = site.burstAltitude { lines.append(String(format: "Platzhöhe etwa %.0f m", b)) }
        if let n = site.notes { lines.append(n) }
        return lines.joined(separator: "\n")
    }
}
