import Foundation
import Combine

/// Nimmt ausgewählte Wetterfax-Sendungen zur Sendezeit automatisch auf: schaltet auf WEFAX, wählt die Frequenz
/// (und stimmt das Funkgerät ab, wenn QSY AUTO an ist), lässt den Empfang die Bilder ablegen und kehrt danach zurück.
/// Digidec muss dafür laufen und der Mac wach sein (während einer Aufnahme verhindert Digidec den Ruhezustand).
@MainActor
public final class WefaxAutoRecorder: ObservableObject {
    public struct Session: Equatable {
        public let broadcast: WefaxBroadcast
        public let start: Date
        public let end: Date
        public let key: String
        public let previousModule: DecoderModuleInfo
    }

    @Published public private(set) var session: Session?
    @Published public private(set) var note: String?

    private unowned let state: DigidecState
    private let store: WefaxScheduleStore
    private let recorder: InputRecorder
    private var handled: Set<String> = []
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var recordingURL: URL?

    /// Sekunden nach dem Ende der Ausstrahlung, bis der Empfang beendet wird (APT-Ende, Nachlauf)
    private let tail: TimeInterval = 90

    public init(state: DigidecState, store: WefaxScheduleStore) {
        self.state = state
        self.store = store
        recorder = InputRecorder(pipeline: state.audio.pipeline)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Nächste ausgewählte Sendung (für die Anzeige)
    public func nextSelected(after date: Date = Date()) -> (broadcast: WefaxBroadcast, start: Date)? {
        guard !store.selected.isEmpty else { return nil }
        for dayOffset in 0...1 {
            let day = date.addingTimeInterval(Double(dayOffset) * 86_400)
            for b in store.schedule.broadcasts where store.selected.contains(b.id) {
                let start = WefaxSchedule.startDate(of: b, onDayOf: day)
                if start > date { return (b, start) }
            }
        }
        return nil
    }

    private func tick() {
        let now = Date()
        if let s = session {
            if state.activeModule != .wefax {
                finish(reason: "Modul gewechselt – Aufnahme beendet", returnToPrevious: false)
            } else if now > s.end.addingTimeInterval(tail) {
                finish(reason: "Aufnahme beendet: \(s.broadcast.title)", returnToPrevious: true)
            }
            return
        }
        guard store.autoEnabled,
              let due = store.schedule.due(selected: store.selected, at: now, handled: handled) else { return }
        guard state.audio.sourceKind == .live else {
            handled.insert(due.key)
            note = "Geplante Aufnahme übersprungen: es läuft keine Live-Quelle"
            return
        }
        begin(due.broadcast, start: due.start, end: due.end, key: due.key)
    }

    private func begin(_ b: WefaxBroadcast, start: Date, end: Date, key: String) {
        handled.insert(key)
        let previous = state.activeModule
        // Frequenz, Hub und Zeilenzahl für den DWD; QSY AUTO stimmt das Funkgerät beim Wechsel ab
        let station = store.frequencyChoice.station(at: start)
        if state.wefax.station != station { state.wefax.station = station }
        if state.wefax.options.lpm != b.lpm { state.wefax.options.lpm = b.lpm }
        state.wefaxController.scheduledLabel = b.title
        state.activeModule = .wefax
        session = Session(broadcast: b, start: start, end: end, key: key, previousModule: previous)
        note = "Aufnahme: \(b.title)"
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                          reason: "Wetterfax-Aufnahme \(b.id) UTC")
        if store.recordAudio {
            let url = InputRecorder.directory.appendingPathComponent(Self.audioName(b, start: start))
            recorder.start(url: url)
            recordingURL = url
        }
    }

    private func finish(reason: String, returnToPrevious: Bool) {
        guard let s = session else { return }
        // Ein noch unvollständiges Bild sichern, bevor der Empfang endet
        if state.wefaxController.status?.state == .image { state.wefaxController.saveNow() }
        if recorder.isRecording { recorder.stop() }
        recordingURL = nil
        state.wefaxController.scheduledLabel = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        session = nil
        note = reason
        if returnToPrevious && store.returnToPreviousModule && state.activeModule == .wefax && s.previousModule != .wefax {
            state.activeModule = s.previousModule
        }
    }

    /// Aufnahme jetzt abbrechen (Knopf)
    public func cancelSession() {
        finish(reason: "Aufnahme abgebrochen", returnToPrevious: true)
    }

    nonisolated static func audioName(_ b: WefaxBroadcast, start: Date) -> String {
        "wefax_\(WefaxSchedule.dayKey(start))_\(b.id)UTC.wav"
    }
}
