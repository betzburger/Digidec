import SwiftUI

// MARK: - Zeitformate

private enum ScheduleTime {
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
}

// MARK: - Statuszeile im WEFAX-Panel

/// Nächste Sendung bzw. laufende Aufnahme
struct WefaxNextLine: View {
    @ObservedObject var store: WefaxScheduleStore
    @ObservedObject var auto: WefaxAutoRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 2) {
                if let s = auto.session {
                    Label("AUFNAHME · \(s.broadcast.title) · bis \(ScheduleTime.utc.string(from: s.end)) UTC", systemImage: "record.circle.fill")
                        .foregroundColor(RadioTheme.ledRed)
                } else if store.autoEnabled, let n = auto.nextSelected(after: now) {
                    Label("Nächste Aufnahme \(ScheduleTime.utc.string(from: n.start)) UTC (\(ScheduleTime.local.string(from: n.start))) · \(ScheduleTime.countdown(n.start.timeIntervalSince(now)))",
                          systemImage: "clock.badge.checkmark")
                        .foregroundColor(RadioTheme.vfdAmber)
                    Text(n.broadcast.title).foregroundColor(RadioTheme.textDim)
                } else if let n = store.schedule.next(after: now) {
                    Label("Nächste Sendung \(ScheduleTime.utc.string(from: n.start)) UTC (\(ScheduleTime.local.string(from: n.start))) · \(ScheduleTime.countdown(n.start.timeIntervalSince(now)))",
                          systemImage: "clock")
                        .foregroundColor(RadioTheme.textDim)
                    Text(n.broadcast.title).foregroundColor(RadioTheme.textMuted)
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

// MARK: - Sendeplan-Fenster

struct WefaxScheduleSheet: View {
    @ObservedObject var store: WefaxScheduleStore
    @ObservedObject var auto: WefaxAutoRecorder
    /// `false` nur für die Offscreen-Vorschau (ImageRenderer zeichnet keine ScrollView)
    var scrolls = true
    @Environment(\.dismiss) private var dismiss

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
            header
            nextBanner
            Divider()
            list
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 820, height: scrolls ? 640 : nil)
        .background(RadioTheme.bgPanel)
    }

    // MARK: Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("DWD RADIOFAX-SENDEPLAN")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                Spacer()
                Button {
                    Task { await store.update() }
                } label: {
                    HStack(spacing: 5) {
                        if store.isUpdating { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        Text("AKTUALISIEREN")
                    }
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(store.isUpdating)
                .help("Holt den aktuellen Sendeplan von dwd.de (PDF) und merkt ihn sich")
                Button("SCHLIESSEN") { dismiss() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
            }
            let freqs = store.schedule.frequenciesHz.map { String(format: "%g", $0 / 1000).replacingOccurrences(of: ".", with: ",") }.joined(separator: " · ")
            Text("Sender Pinneberg: \(freqs) kHz · 120 UpM · Modul 576 · täglich gleich · Zeiten UTC")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text("Quelle: \(store.sourceName)" + (store.updatedAt.map { " · abgerufen \(ScheduleTime.stamp.string(from: $0))" } ?? ""))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            if let m = store.message {
                Text(m)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(m.hasPrefix("Aktualisiert") || m.hasPrefix("Plan unverändert") ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
            }
        }
    }

    private var nextBanner: some View {
        WefaxNextLine(store: store, auto: auto)
            .padding(8)
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
    }

    // MARK: Liste

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let now = context.date
            let running = store.schedule.running(at: now)?.broadcast.id
            let next = store.schedule.next(after: now)?.broadcast.id
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("").frame(width: 22)
                    Text("UTC").frame(width: 46, alignment: .leading)
                    Text(TimeZone.current.abbreviation() ?? "LOKAL").frame(width: 56, alignment: .leading)
                    Text("MIN").frame(width: 34, alignment: .trailing)
                    Text("TERMIN").frame(width: 56, alignment: .leading)
                    Text("KARTENINHALT").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                if scrolls {
                    ScrollView { rowsView(running: running, next: next, now: now) }
                } else {
                    rowsView(running: running, next: next, now: now)
                }
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
            Button { store.toggle(b) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundColor(selected ? RadioTheme.vfdAmber : RadioTheme.textDim)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .help(selected ? "Wird automatisch aufgenommen (wenn der Hauptschalter an ist)" : "Zur automatischen Aufnahme vormerken")
            Text(ScheduleTime.utc.string(from: start)).frame(width: 46, alignment: .leading)
            Text(ScheduleTime.local.string(from: start)).frame(width: 56, alignment: .leading).foregroundColor(RadioTheme.textDim)
            Text("\(b.durationMinutes)").frame(width: 34, alignment: .trailing).foregroundColor(RadioTheme.textDim)
            Text(String(format: "%02d UTC", b.chartHour)).frame(width: 56, alignment: .leading).foregroundColor(RadioTheme.textDim)
            Text(b.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            if running {
                Text("LÄUFT").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
            } else if next {
                Text("NÄCHSTE").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(RadioTheme.vfdAmber)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(RadioTheme.textBright)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(running ? RadioTheme.vfdGreen.opacity(0.12) : (selected ? RadioTheme.vfdAmber.opacity(0.08) : RadioTheme.bgDeep.opacity(0.6)))
        .cornerRadius(4)
    }

    private func pauseRow(_ p: WefaxPause) -> some View {
        let fmt: (Int) -> String = { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
        return HStack(spacing: 8) {
            Text("").frame(width: 22)
            Text("\(fmt(p.startMinute))–\(fmt(p.endMinute))")
            Text("Sendepause (Sprachsendung auf 5905 und 6180 kHz)")
            Spacer()
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundColor(RadioTheme.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: Fuß

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: $store.autoEnabled) {
                    Text("Ausgewählte Sendungen automatisch aufnehmen")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .toggleStyle(.switch)
                Spacer()
                Text("\(store.selected.count) gewählt")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Button("ALLE") { store.selectAll() }.buttonStyle(ModeButtonStyle(isSelected: false))
                Button("KEINE") { store.selectNone() }.buttonStyle(ModeButtonStyle(isSelected: false))
            }
            HStack(spacing: 14) {
                Picker("Frequenz", selection: $store.frequencyChoice) {
                    ForEach(WefaxFrequencyChoice.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 300)
                Toggle("Audio als WAV mitschneiden", isOn: $store.recordAudio)
                    .help("Zusätzlich das Eingangssignal speichern (ca. 100 MB je Sendung bei 48 kHz)")
                Toggle("danach zurück zum vorigen Modul", isOn: $store.returnToPreviousModule)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            Text("Zur Sendezeit schaltet Digidec auf WEFAX, wählt die Frequenz (mit QSY AUTO stimmt es auch das Funkgerät ab) und legt die Bilder als PNG ab. Digidec muss laufen und der Mac wach sein; während einer Aufnahme verhindert Digidec den Ruhezustand.")
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
