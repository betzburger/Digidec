import Foundation
import Combine
import SwiftUI

/// Eine Nachricht mit aufgelöster Station, für Liste und Log
public struct NavtexEntry: Identifiable, Equatable, Sendable {
    public var message: NavtexMessage
    public var station: FldigiNavtexCore.Station?
    /// Gleiche Kennung und gleicher Text wurden in den letzten 24 h schon empfangen (NAVTEX wiederholt Meldungen)
    public var isRepeat: Bool
    public var id: UUID { message.id }

    /// „SA01 · Navigationswarnung · Pinneberg (DDH47) · 22:41 UTC“
    public var summary: String {
        var s = message.hasHeader ? "\(message.code) · \(message.subjectGerman)" : "Nachricht ohne Kopf"
        if let st = station { s += " · \(st.name) (\(st.callsign))" }
        s += " · \(NavtexController.timeFormat.string(from: message.receivedAt)) UTC"
        if isRepeat { s += " · Wiederholung" }
        return s
    }
}

/// Verbindet NAVTEX-Einstellungen, Decoder, Anzeige und Log.
@MainActor
public final class NavtexController: ObservableObject {
    public let decoder: NavtexDecoder
    public let textModel = ReceiveTextModel()
    public let logger = DecodeLogger(mode: "NAVTEX")

    @Published public private(set) var status: FldigiNavtexCore.Status?
    @Published public private(set) var entries: [NavtexEntry] = []
    @Published public private(set) var lastCharacterDate: Date?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "navtexLogEnabled") }
    }
    /// Tatsächliche HF laut rigctld (für die Stationssuche), sonst die gewählte NAVTEX-Frequenz
    public var rigFrequencyHz: Double?

    public static let maxEntries = 200
    private let settings: NavtexSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastManualCenter = Date.distantPast
    private var appliedOptions: FldigiNavtexCore.Options?
    private var appliedCenterRevision = -1
    private var stationsLoaded = false

    nonisolated static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: NavtexSettingsStore) {
        self.settings = settings
        decoder = NavtexDecoder(pipeline: pipeline)
        textModel.scansCallsigns = false
        logEnabled = UserDefaults.standard.object(forKey: "navtexLogEnabled") as? Bool ?? true
        decoder.configure(options: settings.options, centerHz: settings.centerHz)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    private func settingsChanged() {
        let o = settings.options
        if o != appliedOptions {
            appliedOptions = o
            decoder.configure(options: o, centerHz: settings.centerHz)
        }
        if settings.manualCenterRevision != appliedCenterRevision {
            appliedCenterRevision = settings.manualCenterRevision
            lastManualCenter = Date()
            decoder.setCenter(settings.centerHz)
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        if !out.text.isEmpty {
            let clean = RTTYController.displayText(out.text)
            if !clean.isEmpty {
                textModel.append(clean)
                lastCharacterDate = Date()
            }
        }
        for msg in out.messages {
            add(msg)
        }
        if let s = out.status {
            status = s
            if settings.afcOn, Date().timeIntervalSince(lastManualCenter) > 0.3 {
                settings.followAFC(s.centerHz)
            }
        }
    }

    private func add(_ msg: NavtexMessage) {
        if !stationsLoaded {
            stationsLoaded = FldigiNavtexCore.loadStations()
        }
        let freq = rigFrequencyHz ?? settings.frequency.hz
        let station = msg.hasHeader
            ? FldigiNavtexCore.findStation(origin: msg.origin, frequencyHz: freq, locator: settings.locator, message: msg.text)
            : nil
        let dayAgo = msg.receivedAt.addingTimeInterval(-86_400)
        let isRepeat = msg.hasHeader && entries.contains {
            $0.message.code == msg.code && $0.message.text == msg.text && $0.message.receivedAt > dayAgo
        }
        let entry = NavtexEntry(message: msg, station: station, isRepeat: isRepeat)
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }

        // Zusammenfassung in Amber unter dem laufenden Text
        textModel.append("▸ " + entry.summary + "\n", decoded: true)
        if logEnabled {
            logger.markSession(entry.summary)
            logger.append(msg.text + "\n")
        }
    }

    public func clearText() {
        textModel.clear()
    }
}
