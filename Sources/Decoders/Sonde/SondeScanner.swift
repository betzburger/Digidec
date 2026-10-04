import Foundation
import Combine

/// Suchlauf nach Sonden mit dem Funkgerät: stellt Frequenz für Frequenz ein (über die Abstimmung des Moduls, also QSY AUTO und rigctld
/// des Commanders) und bleibt stehen, sobald ein RS41-Rahmen lesbar ist.
@MainActor
public final class SondeScanner: ObservableObject {
    public enum Status: Equatable, Sendable { case idle, scanning, found, notFound, failed }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var message: String?
    @Published public private(set) var currentKHz: Int?
    @Published public private(set) var done = 0
    @Published public private(set) var total = 0

    private let settings: SondeSettingsStore
    private let controller: SondeController
    /// Darf und kann das Funkgerät abgestimmt werden? (QSY AUTO an, Verbindung zum Commander)
    private let rigReady: @MainActor () -> Bool
    /// Läuft das Modul SONDE?
    private let isActive: @MainActor () -> Bool
    /// Frequenzen, die zuerst versucht werden (kHz)
    private let knownFrequencies: @MainActor () -> [Int]
    private var engine = SondeScanEngine(frequencies: [])
    private var timer: Timer?
    private var restoreKHz: Int?

    public init(settings: SondeSettingsStore, controller: SondeController, rigReady: @escaping @MainActor () -> Bool,
                isActive: @escaping @MainActor () -> Bool, knownFrequencies: @escaping @MainActor () -> [Int]) {
        self.settings = settings
        self.controller = controller
        self.rigReady = rigReady
        self.isActive = isActive
        self.knownFrequencies = knownFrequencies
    }

    public var isScanning: Bool { status == .scanning }

    /// Voraussichtliche Dauer in Minuten für die Anzeige
    public func estimatedMinutes(_ mode: SondeScanEngine.Mode) -> Int {
        let list = SondeScanEngine.frequencies(mode: mode, known: knownFrequencies(), filterKHz: settings.filterKHz)
        return max(1, Int((SondeScanEngine.duration(count: list.count) / 60).rounded(.up)))
    }

    public func start(_ mode: SondeScanEngine.Mode) {
        guard !isScanning else { return }
        guard isActive() else {
            finish(.failed, "Suchlauf nur im Modul SONDE")
            return
        }
        guard rigReady() else {
            finish(.failed, "Suchlauf braucht QSY AUTO und ein verbundenes Funkgerät (PCR-1500)")
            return
        }
        // Die aktuelle Frequenz zuerst (falls dort schon eine Sonde sendet), dann die bekannten
        var known = [settings.frequencyKHz]
        known += knownFrequencies()
        engine = SondeScanEngine(frequencies: SondeScanEngine.frequencies(mode: mode, known: known, filterKHz: settings.filterKHz))
        restoreKHz = settings.frequencyKHz
        total = engine.frequencies.count
        done = 0
        status = .scanning
        message = "Suche …"
        handle(engine.start(now: Date()))
        guard isScanning else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Abbrechen; die vorherige Frequenz wird wieder eingestellt
    public func stop() {
        guard isScanning else { return }
        restore()
        finish(.idle, "Suchlauf abgebrochen")
    }

    private func tick() {
        guard isScanning else { return }
        if !isActive() {
            finish(.idle, "Suchlauf beendet: anderes Modul")
            return
        }
        if !rigReady() {
            restore()
            finish(.failed, "Suchlauf abgebrochen: Funkgerät nicht mehr erreichbar")
            return
        }
        let st = controller.stats
        if let event = engine.advance(now: Date(), decoded: st.frames + st.partial) { handle(event) }
    }

    private func handle(_ event: SondeScanEngine.Event) {
        switch event {
        case .tune(let f):
            currentKHz = f
            done = engine.index
            message = "Suche \(SondeSettingsStore.text(f)) (\(engine.index + 1) von \(total))"
            if settings.frequencyKHz != f { settings.frequencyKHz = f }
        case .found(let f):
            finish(.found, "Sonde gefunden auf \(SondeSettingsStore.text(f))")
        case .finished:
            restore()
            finish(.notFound, "Keine Sonde gefunden (\(total) Frequenzen)")
        }
    }

    private func restore() {
        if let f = restoreKHz, settings.frequencyKHz != f { settings.frequencyKHz = f }
    }

    private func finish(_ newStatus: Status, _ text: String) {
        timer?.invalidate()
        timer = nil
        restoreKHz = nil
        status = newStatus
        message = text
        if newStatus != .scanning { done = engine.index }
    }
}
