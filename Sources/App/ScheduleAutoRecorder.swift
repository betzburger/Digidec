import Foundation
import Combine

/// Nimmt ausgewählte Sendungen (Wetterfax, RTTY, NAVTEX) zur Sendezeit automatisch auf: schaltet auf das Modul, wählt Frequenz
/// und Voreinstellung (mit QSY AUTO stimmt es auch das Funkgerät ab), sorgt für Log bzw. Bildablage und kehrt danach zurück.
/// Digidec muss dafür laufen und der Mac wach sein (während einer Aufnahme verhindert Digidec den Ruhezustand).
/// Es empfängt immer nur ein Dienst gleichzeitig: bei Überschneidung läuft die zuerst begonnene Sendung weiter.
@MainActor
public final class ScheduleAutoRecorder: ObservableObject {
    public struct Session: Equatable {
        public let service: BroadcastService
        public let itemID: String
        public let title: String
        public let start: Date
        public let end: Date
        public let key: String
        /// Modul vor der ersten geplanten Aufnahme (bei aufeinanderfolgenden Sendungen bleibt es erhalten)
        public let previousModule: DecoderModuleInfo
        /// Erwartete Einstellung des Funkgeräts (für die Warnung)
        public let target: RigTuneTarget?
    }

    @Published public private(set) var session: Session?
    @Published public private(set) var note: String?

    private unowned let state: DigidecState
    private let wefaxStore: WefaxScheduleStore
    private let rttyStore: RttyScheduleStore
    private let navtexStore: NavtexPlanStore
    private let recorder: InputRecorder
    private var handled: Set<String> = []
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    /// WEFAX: Station, die Digidec gewählt hat; eine andere Wahl stammt vom Nutzer und wird gemerkt
    private var chosenStation: WefaxStation?
    /// RTTY/NAVTEX: Log war vor der Aufnahme aus und wird danach wieder ausgeschaltet
    private var restoreLogOff = false

    public init(state: DigidecState, wefax: WefaxScheduleStore, rtty: RttyScheduleStore, navtex: NavtexPlanStore) {
        self.state = state
        wefaxStore = wefax
        rttyStore = rtty
        navtexStore = navtex
        recorder = InputRecorder(pipeline: state.audio.pipeline)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Stellt der Nutzer während einer WEFAX-Aufnahme eine andere Frequenz ein, hat er etwas Besseres gefunden: merken
        state.wefax.$station
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] station in self?.userChangedStation(station) }
            .store(in: &cancellables)
    }

    // MARK: - Pläne

    private func items(_ service: BroadcastService) -> [ScheduledItem] {
        switch service {
        case .wefax:  return wefaxStore.schedule.items
        case .rtty:   return rttyStore.schedule.items
        case .navtex: return navtexStore.items
        }
    }

    private func selected(_ service: BroadcastService) -> Set<String> {
        switch service {
        case .wefax:  return wefaxStore.selected
        case .rtty:   return rttyStore.selected
        case .navtex: return navtexStore.selectedItemIDs
        }
    }

    private func isEnabled(_ service: BroadcastService) -> Bool {
        switch service {
        case .wefax:  return wefaxStore.autoEnabled
        case .rtty:   return rttyStore.autoEnabled
        case .navtex: return navtexStore.autoEnabled
        }
    }

    private func returnsToPrevious(_ service: BroadcastService) -> Bool {
        switch service {
        case .wefax:  return wefaxStore.returnToPreviousModule
        case .rtty:   return rttyStore.returnToPreviousModule
        case .navtex: return navtexStore.returnToPreviousModule
        }
    }

    /// Sekunden nach dem Ende der Sendung, bis der Empfang beendet wird (Fax: APT-Ende und Nachlauf)
    private func tail(_ service: BroadcastService) -> TimeInterval { service == .wefax ? 90 : 60 }

    /// Nächste ausgewählte Aufnahme aller eingeschalteten Dienste (für die Anzeige)
    public func nextSelected(after date: Date = Date()) -> (service: BroadcastService, title: String, start: Date)? {
        var best: (BroadcastService, String, Date)?
        for service in BroadcastService.allCases where isEnabled(service) {
            let ids = selected(service)
            guard !ids.isEmpty, let n = ScheduleCalc.next(items: items(service).filter { ids.contains($0.id) }, after: date) else { continue }
            if best == nil || n.start < best!.2 { best = (service, n.item.title, n.start) }
        }
        return best.map { (service: $0.0, title: $0.1, start: $0.2) }
    }

    /// Die früheste fällige Aufnahme über alle eingeschalteten Dienste
    private func nextDue(at now: Date) -> ScheduleCalc.Due? {
        var best: ScheduleCalc.Due?
        for service in BroadcastService.allCases where isEnabled(service) {
            guard let d = ScheduleCalc.due(items: items(service), selected: selected(service), at: now, handled: handled) else { continue }
            if best == nil || d.start < best!.start { best = d }
        }
        return best
    }

    // MARK: - Zeitsteuerung

    private func tick() {
        let now = Date()
        if let s = session {
            warnIfRigOff()
            if state.activeModule != s.service.module {
                finish(reason: "Modul gewechselt – Aufnahme beendet", returnToPrevious: false)
                return
            }
        }
        let due = nextDue(at: now)
        switch ScheduleCalc.decide(sessionEnd: session?.end, tail: session.map { tail($0.service) } ?? 0, due: due, now: now) {
        case .idle, .keep:
            break
        case .begin:
            guard let due else { return }
            guard state.audio.sourceKind == .live else {
                handled.insert(due.key)
                note = "Geplante Aufnahme übersprungen: es läuft keine Live-Quelle"
                return
            }
            begin(due, previous: state.activeModule)
        case .chain:
            guard let s = session, let due else { return }
            finish(reason: nil, returnToPrevious: false, keepAwake: true)
            begin(due, previous: s.previousModule)
            if session == nil {
                // Die Folgesendung ließ sich nicht starten: Ruhezustand-Schutz beenden und zum vorigen Modul zurück
                if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
                if returnsToPrevious(s.service) && state.activeModule == s.service.module && s.previousModule != s.service.module {
                    state.activeModule = s.previousModule
                }
            }
        case .skipConflict:
            guard let s = session, let due else { return }
            handled.insert(due.key)
            note = "Übersprungen (überschneidet sich mit \(s.title)): \(due.item.title)"
        case .end:
            guard let s = session else { return }
            finish(reason: "Aufnahme beendet: \(s.title)", returnToPrevious: true)
        }
    }

    private func begin(_ due: ScheduleCalc.Due, previous: DecoderModuleInfo) {
        handled.insert(due.key)
        let item = due.item
        var target: RigTuneTarget?
        switch item.service {
        case .wefax:
            guard let b = wefaxStore.schedule.broadcasts.first(where: { $0.id == item.id }) else { return }
            // Frequenz, Hub und Zeilenzahl für den DWD
            let station = wefaxStore.choice(for: b).station(at: due.start)
            chosenStation = station
            if state.wefax.station != station { state.wefax.station = station }
            if state.wefax.options.lpm != b.lpm { state.wefax.options.lpm = b.lpm }
            state.wefaxController.scheduledLabel = b.title
            target = RigTuneTarget.wefax(station: station, centerHz: state.wefax.centerHz)
            if wefaxStore.recordAudio {
                recorder.start(url: InputRecorder.directory.appendingPathComponent("wefax_\(ScheduleCalc.dayKey(due.start))_\(b.id)UTC.wav"))
            }
        case .rtty:
            guard let b = rttyStore.schedule.broadcasts.first(where: { $0.id == item.id }),
                  let f = rttyStore.frequency(for: b, at: due.start) else {
                note = "RTTY-Aufnahme übersprungen: keine Frequenz für \(item.title)"
                return
            }
            state.rtty.select(presetID: f.presetID)
            enableLog(state.rttyController.logEnabled) { state.rttyController.logEnabled = true }
            state.rttyController.logger.markSession("Sendeplan: \(item.title) · \(f.label) · \(b.header ?? "")")
            target = RigTuneTarget(dialHz: Int64(f.hz) - Int64(state.rtty.centerHz.rounded()), mode: "USB")
        case .navtex:
            guard let station = navtexStore.plan.station(forItemID: item.id), let f = station.frequency else {
                note = "NAVTEX-Aufnahme übersprungen: unbekannte Station für \(item.title)"
                return
            }
            if state.navtex.frequency != f { state.navtex.frequency = f }
            enableLog(state.navtexController.logEnabled) { state.navtexController.logEnabled = true }
            target = RigTuneTarget.navtex(frequency: f, centerHz: state.navtex.centerHz)
        }
        state.activeModule = item.service.module
        session = Session(service: item.service, itemID: item.id, title: item.title, start: due.start, end: due.end,
                          key: due.key, previousModule: previous, target: target)
        note = "Aufnahme: \(item.title)"
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                              reason: "Geplante Aufnahme \(item.service.label)")
        }
        if let target { state.tuneRig(to: target) }
    }

    /// Schaltet das Log für die Dauer der Aufnahme ein und merkt, ob es danach wieder aus soll
    private func enableLog(_ wasEnabled: Bool, enable: () -> Void) {
        restoreLogOff = !wasEnabled
        if !wasEnabled { enable() }
    }

    /// - Parameter keepAwake: bei nahtlos folgender Sendung bleibt der Ruhezustand-Schutz bestehen
    private func finish(reason: String?, returnToPrevious: Bool, keepAwake: Bool = false) {
        guard let s = session else { return }
        switch s.service {
        case .wefax:
            // Ein noch unvollständiges Bild sichern, bevor der Empfang endet
            if state.wefaxController.status?.state == .image { state.wefaxController.saveNow() }
            if recorder.isRecording { recorder.stop() }
            state.wefaxController.scheduledLabel = nil
            chosenStation = nil
        case .rtty:
            if restoreLogOff { state.rttyController.logEnabled = false }
        case .navtex:
            if restoreLogOff { state.navtexController.logEnabled = false }
        }
        restoreLogOff = false
        session = nil
        if !keepAwake, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if returnToPrevious {
            if returnsToPrevious(s.service) && state.activeModule == s.service.module && s.previousModule != s.service.module {
                state.activeModule = s.previousModule
            }
        }
        if let reason { note = reason }
    }

    /// Aufnahme jetzt abbrechen (Knopf)
    public func cancelSession() {
        finish(reason: "Aufnahme abgebrochen", returnToPrevious: true)
    }

    // MARK: - Hinweise

    /// WEFAX: Stellt der Nutzer während der Aufnahme eine andere Frequenz ein, hat er etwas Besseres gefunden: merken
    private func userChangedStation(_ station: WefaxStation) {
        guard let s = session, s.service == .wefax, let chosen = chosenStation, station != chosen,
              let b = wefaxStore.schedule.broadcasts.first(where: { $0.id == s.itemID }) else { return }
        let choice: WefaxFrequencyChoice
        switch station {
        case .dwd3855: choice = .f3855
        case .dwd7880: choice = .f7880
        case .dwd13882: choice = .f13882
        case .custom: return
        }
        wefaxStore.setOverride(choice, for: b)
        chosenStation = station
        note = "Frequenz für \(b.id.prefix(2)):\(b.id.suffix(2)) UTC gemerkt: \(choice.label)"
    }

    /// Steht das Funkgerät (laut rigctld) nicht auf der erwarteten Dial-Frequenz, wird gewarnt – etwa wenn QSY AUTO aus ist
    /// und das Gerät noch auf einer anderen Frequenz steht.
    private func warnIfRigOff() {
        guard let s = session, let target = s.target, let rig = state.rig.state.frequencyHz, state.rig.state.connected else { return }
        if abs(Int64(rig) - target.dialHz) > 2_000 {
            note = "Achtung: Funkgerät steht auf \(rig / 1000) kHz, Soll \(target.label) (\(s.title))"
        } else if note?.hasPrefix("Achtung") == true {
            note = "Aufnahme: \(s.title)"
        }
    }
}
