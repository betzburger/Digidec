// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI

/// Empfangstext für die Anzeige. Die Textansicht hängt neuen Text direkt an (kein Neuaufbau des ganzen Texts).
@MainActor
public final class ReceiveTextModel: ObservableObject {
    public static let maxCharacters = 200_000

    public private(set) var text = ""
    /// Wird von der Textansicht gesetzt: hängt neuen Text an bzw. leert die Anzeige
    var onAppend: ((String, Bool) -> Void)?
    var onClear: (() -> Void)?
    @Published public private(set) var characterCount = 0
    /// Rufzeichen und SYNOP-Meldungen aus dem Text, für die Karte
    public let calls = CallsignLog()
    public let synop = SynopLog()
    /// Seewetterberichte und Sturmwarnungen aus dem Text, für die Karte
    public let sea = SeaLog()
    /// Rufzeichen im Text suchen (aus bei NAVTEX)
    public var scansCallsigns = true

    /// Von der Textansicht gesetzt: sucht die Station im angezeigten Text, hebt die Meldung hervor und meldet, ob sie gefunden wurde
    var onReveal: ((String) -> Bool)?

    /// `decoded`: Klartext einer SYNOP-Meldung (andere Farbe).
    /// `shown`: was die Anzeige bekommt, wenn ein Textfilter etwas weglässt (nil = alles); die Auswertung für die Karten
    /// bekommt immer den ganzen Text `s`.
    func append(_ s: String, decoded: Bool = false, shown: String? = nil) {
        guard !s.isEmpty else { return }
        if scansCallsigns && !decoded { calls.feed(s) }
        synop.feed(s, decoded: decoded)
        sea.feed(s, decoded: decoded)
        show(shown ?? s, decoded: decoded)
    }

    /// Nur anzeigen, nicht auswerten (zurückgehaltener Rest des Filters: die Auswertung kennt ihn schon)
    func show(_ display: String, decoded: Bool = false) {
        guard !display.isEmpty else { return }
        text += display
        if text.count > Self.maxCharacters {
            text = String(text.suffix(Self.maxCharacters * 3 / 4))
            onClear?()
            onAppend?(text, false)
        } else {
            onAppend?(display, decoded)
        }
        characterCount = text.count
    }

    /// Die Rohmeldung der Station (WMO-Nummer bzw. Kennung) im Text finden und in der Ansicht hervorheben.
    /// Rückgabe false, wenn sie nicht (mehr) im Text steht, etwa weil der Filter sie ausgelassen hat.
    @discardableResult
    func reveal(station id: String) -> Bool {
        onReveal?(id) ?? false
    }

    public func clear() {
        text = ""
        characterCount = 0
        calls.clear()
        synop.clear()
        sea.clear()
        onClear?()
    }
}

/// Verbindet Einstellungen, Decoder, Textanzeige und Log des RTTY-Moduls.
@MainActor
public final class RTTYController: ObservableObject {
    public let decoder: RTTYDecoder
    public let textModel = ReceiveTextModel()
    public let logger = DecodeLogger(mode: "RTTY")
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    /// Frequenz und Mode für Dateiname und Begleitdatei der Aufnahme (vom App-Zustand gesetzt)
    public var rigState: RigState?

    @Published public private(set) var status: FldigiRTTYCore.Status?
    @Published public private(set) var scope: [CGPoint] = []
    /// Zeitpunkt des letzten decodierten Zeichens (für die Aktivitätsanzeige)
    @Published public private(set) var lastCharacterDate: Date?
    @Published public var logEnabled: Bool {
        didSet {
            UserDefaults.standard.set(logEnabled, forKey: "rttyLogEnabled")
            if logEnabled { markSession() } else { logger.close() }
        }
    }
    /// Meldungen als CSV ablegen (`SYNOP-JJJJ-MM-TT.csv` neben dem Log)
    @Published public var csvEnabled: Bool {
        didSet { UserDefaults.standard.set(csvEnabled, forKey: "rttySynopCSVEnabled") }
    }
    public let csvWriter = SynopCSVWriter()
    /// Textfilter für Anzeige und Log (die Karten bekommen den ganzen Text)
    @Published public var textFilter: ReceiveTextFilter {
        didSet {
            guard textFilter != oldValue else { return }
            if let data = try? JSONEncoder().encode(textFilter) { UserDefaults.standard.set(data, forKey: "rttyTextFilter") }
            filterRunner.configure(textFilter)
        }
    }
    private var filterRunner = ReceiveTextFilterRunner()
    private var lastTextAt = Date.distantPast

    private let settings: RTTYSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastManualCenter = Date.distantPast
    /// Beschreibung der Quelle für die Log-Kopfzeile (wird vom App-Zustand gesetzt)
    public var sourceDescription: String? {
        didSet { if sourceDescription != oldValue { markSession() } }
    }
    /// Funkgerät mit Frequenz und Mode (rigctld) für die Log-Kopfzeile
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public init(pipeline: AudioPipeline, settings: RTTYSettingsStore) {
        self.settings = settings
        decoder = RTTYDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "rttyLogEnabled") as? Bool ?? true
        csvEnabled = UserDefaults.standard.object(forKey: "rttySynopCSVEnabled") as? Bool ?? true
        let savedFilter = UserDefaults.standard.data(forKey: "rttyTextFilter").flatMap { try? JSONDecoder().decode(ReceiveTextFilter.self, from: $0) }
        textFilter = savedFilter ?? ReceiveTextFilter()
        filterRunner.configure(textFilter)
        textModel.synop.onObservationClosed = { [weak self] obs in
            // Aufrufe kommen aus der Textauswertung auf dem Hauptthread
            MainActor.assumeIsolated {
                guard let self, self.csvEnabled else { return }
                self.csvWriter.append(obs)
            }
        }

        decoder.configure(parameters: settings.decoderParameters, options: settings.options, centerHz: settings.centerHz)
        markSession()

        // Übertragungsparameter, Reverse und Optionen → Decoder neu konfigurieren
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private var appliedParameters: RTTYParameters?
    private var appliedOptions: RTTYDecodeOptions?
    private var appliedCenterRevision = -1

    private func settingsChanged() {
        let p = settings.decoderParameters
        let o = settings.options
        if p != appliedParameters || o != appliedOptions {
            appliedParameters = p
            appliedOptions = o
            decoder.configure(parameters: p, options: o, centerHz: settings.centerHz)
            markSession()
        }
        if settings.manualCenterRevision != appliedCenterRevision {
            appliedCenterRevision = settings.manualCenterRevision
            lastManualCenter = Date()
            decoder.setCenter(settings.centerHz)
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        for seg in out.segments {
            let clean = seg.decoded ? Self.displayDecoded(seg.text) : Self.displayText(seg.text)
            guard !clean.isEmpty else { continue }
            // Der Filter bestimmt, was angezeigt und geloggt wird; die Auswertung (Karten, CSV) sieht alles
            let shown = seg.decoded ? (filterRunner.allowsDecoded() ? clean : "") : filterRunner.process(clean)
            textModel.append(clean, decoded: seg.decoded, shown: shown)
            if logEnabled { logger.append(shown) }
            if !seg.decoded { lastCharacterDate = Date() }
            lastTextAt = Date()
        }
        // Ein vom Filter zurückgehaltener Rest („RY“ am Ende) erscheint, wenn eine Weile nichts mehr kommt
        if textFilter.enabled, Date().timeIntervalSince(lastTextAt) > 1.5 {
            let rest = filterRunner.flush()
            if !rest.isEmpty {
                textModel.show(rest)
                if logEnabled { logger.append(rest) }
            }
        }
        if let s = out.status {
            status = s
            // AFC nachführen – aber nicht direkt nach einer Mittenwahl von Hand, solange der Decoder sie noch nicht kennt
            if Date().timeIntervalSince(lastManualCenter) > 0.3 {
                settings.followAFC(s.centerHz)
            }
        }
        if !out.scope.isEmpty {
            scope = out.scope
        }
        if isRecording {
            recordingDuration = recorder.duration
        }
    }

    // MARK: - Aufnahme

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let rig = rigState?.connected == true ? rigState : nil
        let name = InputRecorder.fileName(frequencyHz: rig?.frequencyHz, mode: rig?.mode, preset: settings.presetID)
        let url = InputRecorder.directory.appendingPathComponent(name)
        recorder.start(url: url)
        writeSidecar(for: url, rig: rig)
        recordingDuration = 0
        isRecording = true
        lastRecording = url
    }

    /// Begleitdatei `<Aufnahme>.json` mit allen Einstellungen, damit Digidec-Offline und fldigi exakt gleich decodieren
    private func writeSidecar(for url: URL, rig: RigState?) {
        let info = RecordingInfo(presetID: settings.presetID, parameters: settings.parameters,
                                 decoderParameters: settings.decoderParameters, options: settings.options,
                                 centerHz: settings.centerHz, lsb: settings.effectiveLSB,
                                 frequencyHz: rig?.frequencyHz, mode: rig?.mode, startedAt: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(info) {
            try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    public func clearText() {
        textModel.clear()
    }

    public func markSession() {
        let p = settings.parameters
        var header = "RTTY \(settings.preset.name) · \(p.summary)\(p.reverse ? " · REV" : "")"
        header += " · \(settings.effectiveLSB ? "LSB" : "USB")\(settings.sidebandMode == .auto ? "" : " (fest)")"
        header += " · Mitte \(Int(settings.centerHz.rounded())) Hz"
        if let rig = rigDescription { header += " · \(rig)" }
        if let src = sourceDescription { header += " · via \(src)" }
        logger.markSession(header)
    }

    /// RTTY-Steuerzeichen für die Anzeige: CR entfällt (LF bricht um), Klingel und andere Steuerzeichen entfallen.
    /// Klartextblock des SYNOP-Decoders: fldigi rückt mit Tabulator ein und hängt Leerzeichen an
    nonisolated static func displayDecoded(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "\t", with: "    ")
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        return displayText(lines.joined(separator: "\n"))
    }

    /// Skalarweise, weil Swift „\r\n“ als ein einziges Character behandelt.
    nonisolated static func displayText(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\n" {
                out.append(scalar)
            } else if scalar.value >= 0x20 {
                out.append(scalar)
            }
            // CR, Klingel (BEL), NUL und andere Steuerzeichen entfallen
        }
        return String(out)
    }
}
