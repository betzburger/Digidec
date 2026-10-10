// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// Frequenzen für Funkruf (FM). Funkrufdienste sind sonst frei gewählt; hier die bekannte Amateurfunk-Frequenz.
public enum PagerChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case dapnet, free

    public var id: String { rawValue }

    public var frequencyHz: Double? {
        switch self {
        case .dapnet: return 439_987_500
        case .free: return nil
        }
    }

    public var name: String {
        switch self {
        case .dapnet: return "DAPNET"
        case .free: return "frei"
        }
    }

    public var label: String {
        frequencyHz.map { String(format: "%.4f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? "frei"
    }

    public var note: String {
        switch self {
        case .dapnet: return "DAPNET, Amateurfunk-Funkruf, 439,9875 MHz, POCSAG 1200 Baud"
        case .free: return "Funkgerät nicht abstimmen"
        }
    }
}

/// Frei konfigurierbarer Funkruf-Kanal
public struct PagerChannelItem: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var frequencyHz: Double?
    public var note: String

    public init(id: String = UUID().uuidString, name: String, frequencyHz: Double?, note: String = "") {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.note = note
    }

    public var label: String {
        frequencyHz.map { String(format: "%.4f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? "frei"
    }

    public static let standardChannels: [PagerChannelItem] = [
        PagerChannelItem(id: "dapnet", name: "DAPNET", frequencyHz: 439_987_500, note: "DAPNET Amateurfunk 439,9875 MHz POCSAG"),
        PagerChannelItem(id: "vhf-1", name: "VHF 1", frequencyHz: 153_125_000, note: "153,125 MHz POCSAG"),
        PagerChannelItem(id: "vhf-2", name: "VHF 2", frequencyHz: 153_350_000, note: "153,350 MHz POCSAG"),
        PagerChannelItem(id: "us-pocsag", name: "US 466M", frequencyHz: 466_075_000, note: "466,075 MHz US POCSAG"),
        PagerChannelItem(id: "free", name: "frei", frequencyHz: nil, note: "Funkgerät nicht abstimmen")
    ]
}

// MARK: - Einstellungen

@MainActor
public final class PagerSettingsStore: ObservableObject {
    @Published public private(set) var channels: [PagerChannelItem]
    @Published public var selectedChannelID: String { didSet { applySelectedChannel(); save() } }
    @Published public var channel: PagerChannel { didSet { save() } }
    /// Eingeschaltete POCSAG-Baudraten (512, 1200, 2400)
    @Published public var rates: Set<Int> { didSet { save() } }
    @Published public var flex: Bool { didSet { save() } }
    /// Rufnummern, die hervorgehoben werden (durch Komma getrennt)
    @Published public var watch: String { didSet { save() } }
    /// Deutsche Umlaute anzeigen: Funkrufempfänger (z. B. AlphaPoc) belegen `{ | } ~` mit ä ö ü ß, `[ \ ]` mit Ä Ö Ü (7-Bit-Zeichensatz DIN 66003)
    @Published public var umlauts: Bool { didSet { save() } }
    /// Skyper-Meldungen lesbar machen: jedes Zeichen ist um 1 nach oben verschoben (Leerzeichen = `!`), davor stehen Rubrik und Nummer
    @Published public var skyper: Bool { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let loadedChannels: [PagerChannelItem]
        if let data = d.data(forKey: "pagerCustomChannels"),
           let list = try? JSONDecoder().decode([PagerChannelItem].self, from: data), !list.isEmpty {
            loadedChannels = list
        } else {
            loadedChannels = PagerChannelItem.standardChannels
        }
        let savedID = d.string(forKey: "pagerSelectedChannelID")
        let initialID = loadedChannels.first(where: { $0.id == savedID })?.id ?? loadedChannels.first?.id ?? "dapnet"
        channels = loadedChannels
        selectedChannelID = initialID
        channel = PagerChannel(rawValue: initialID) ?? .dapnet
        let r = (d.array(forKey: "pagerRates") as? [Int]) ?? POCSAG.rates
        rates = Set(r).intersection(POCSAG.rates)
        flex = d.object(forKey: "pagerFlex") as? Bool ?? true
        watch = d.string(forKey: "pagerWatch") ?? ""
        umlauts = d.object(forKey: "pagerUmlauts") as? Bool ?? true
        skyper = d.object(forKey: "pagerSkyper") as? Bool ?? true
    }

    /// Hervorgehobene Rufnummern als Zahlen
    public var watched: Set<Int> {
        Set(watch.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
    }

    public var activeChannelItem: PagerChannelItem {
        channels.first { $0.id == selectedChannelID } ?? channels[0]
    }

    public var activeFrequencyHz: Double? { activeChannelItem.frequencyHz }

    public func selectChannel(id: String) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedChannelID = id
    }

    public func addChannel(_ item: PagerChannelItem) {
        channels.append(item)
        selectedChannelID = item.id
        save()
    }

    public func updateChannel(_ item: PagerChannelItem) {
        if let idx = channels.firstIndex(where: { $0.id == item.id }) {
            channels[idx] = item
            if selectedChannelID == item.id {
                applySelectedChannel()
            }
            save()
        }
    }

    public func removeChannel(id: String) {
        guard channels.count > 1 else { return }
        channels.removeAll { $0.id == id }
        if selectedChannelID == id {
            selectedChannelID = channels.first?.id ?? "free"
        }
        save()
    }

    public func resetChannelsToDefault() {
        channels = PagerChannelItem.standardChannels
        if !channels.contains(where: { $0.id == selectedChannelID }) {
            selectedChannelID = "dapnet"
        }
        save()
    }

    private func applySelectedChannel() {
        channel = PagerChannel(rawValue: activeChannelItem.id) ?? .free
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(channels) {
            d.set(data, forKey: "pagerCustomChannels")
        }
        d.set(selectedChannelID, forKey: "pagerSelectedChannelID")
        d.set(channel.rawValue, forKey: "pagerChannel")
        d.set(Array(rates), forKey: "pagerRates")
        d.set(flex, forKey: "pagerFlex")
        d.set(watch, forKey: "pagerWatch")
        d.set(umlauts, forKey: "pagerUmlauts")
        d.set(skyper, forKey: "pagerSkyper")
    }
}

extension PagerSettingsStore: TuningTarget {
    public var centerHz: Double { 1200 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 2400 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("FUNKRUF · Basisband (POCSAG bis 2,4 kHz, FLEX bis 3,2 kHz)") }
}

// MARK: - Decoder

/// POCSAG und FLEX als 24-kHz-Senke an der Pipeline
public final class PagerDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var messages: [PagerMessage]
        public var synced: [Bool]     // POCSAG 512, 1200, 2400, FLEX
        public var level: Double
        /// Zähler je POCSAG-Baudrate (512, 1200, 2400)
        public var stats: [POCSAGStats]
        /// Pegel des Eingangs (Effektivwert) in dBFS
        public var inputDB: Double
    }

    public static let sampleRate = 24_000.0

    private let pipeline: AudioPipeline
    private let pocsag = POCSAGReceiver(sampleRate: PagerDecoder.sampleRate)
    private let flexRx = FLEXReceiver(sampleRate: PagerDecoder.sampleRate)
    private var flexOn = true
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [PagerMessage] = []
    private var syncedNow = [false, false, false, false]
    private var levelNow = 0.0
    private var statsNow = [POCSAGStats](repeating: POCSAGStats(), count: 3)
    private var meanSquare = 0.0
    private var inputDBNow = -120.0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(rates: Set<Int>, flex: Bool) {
        pipeline.perform { [self] in
            pocsag.enabled = Set(rates.compactMap { POCSAG.rates.firstIndex(of: $0) })
            flexOn = flex
            if !flex { flexRx.reset() }
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { pocsag.reset(); flexRx.reset() }
        }
    }

    /// Zähler der Diagnose auf null (z. B. beim Leeren der Liste)
    public func resetStats() {
        pipeline.perform { [self] in
            pocsag.resetStats()
            lock.withLockUnchecked { statsNow = [POCSAGStats](repeating: POCSAGStats(), count: 3) }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(messages: pending, synced: syncedNow, level: levelNow, stats: statsNow, inputDB: inputDBNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [PagerMessage] = []
        let now = Date()
        pocsag.process(samples, now: now) { found.append($0) }
        if flexOn { flexRx.process(samples, now: now) { found.append($0) } }
        let level = pocsag.level
        let synced = pocsag.synced + [flexOn && flexRx.isSynced]
        // Effektivwert des Eingangs, geglättet über etwa 0,3 s
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let blockMS = samples.isEmpty ? 0 : sum / Double(samples.count)
        let k = min(1.0, Double(samples.count) / (0.3 * Self.sampleRate))
        meanSquare += k * (blockMS - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        let stats = pocsag.stats
        lock.withLockUnchecked {
            pending.append(contentsOf: found)
            syncedNow = synced
            levelNow = level
            statsNow = stats
            inputDBNow = db
        }
    }
}

// MARK: - Anzeige des Klartexts

public enum PagerText {
    /// Skyper-Meldung (Telekom-Funkruf, im DAPNET weiter üblich) im Klartext
    public struct SkyperText: Equatable, Sendable {
        /// Lesbarer Text ohne Kopf
        public var text: String
        /// Rubrik (aus dem ersten Zeichen) und laufende Nummer (aus dem zweiten)
        public var rubric: Int
        public var number: Int
    }

    /// Skyper sendet Klartext mit Kopf aus zwei Zeichen (Rubrik, Nummer) und jedes Zeichen um 1 nach oben verschoben: Leerzeichen kommt als `!`,
    /// „Astheim“ als „Btuifjn“, „z“ (UTC) als `{`. Erkannt wird nur, was sicher so aussieht: mindestens zwei `!`, kein einziges Leerzeichen,
    /// mindestens acht Zeichen, und nach dem Zurückschieben fast nur druckbare Zeichen. Anderer Text (auch mit Ausrufezeichen) bleibt, wie er ist.
    public static func skyper(_ raw: String) -> SkyperText? {
        let u = Array(raw.unicodeScalars)
        guard u.count >= 8 else { return nil }
        let bangs = u.filter { $0 == "!" }.count
        guard bangs >= 2, !u.contains(" ") else { return nil }
        guard u[0].value > 0x20, u[0].value < 0x7F, u[1].value >= 0x21, u[1].value < 0x7F else { return nil }
        var out = String.UnicodeScalarView()
        var printable = 0
        for c in u.dropFirst(2) {
            if c.value >= 0x21 && c.value < 0x7F, let shifted = Unicode.Scalar(c.value - 1) {
                out.append(shifted)
                if shifted.value >= 0x20 && shifted.value < 0x7F { printable += 1 }
            } else {
                out.append(c)
            }
        }
        let body = u.count - 2
        guard body > 0, Double(printable) >= 0.85 * Double(body) else { return nil }
        return SkyperText(text: String(out), rubric: Int(u[0].value) - 0x20, number: Int(u[1].value) - 0x21)
    }

    /// 7-Bit-Zeichensatz DIN 66003 (deutsche Belegung, wie AlphaPoc): `{ | } ~` = ä ö ü ß; `[ \ ]` = Ä Ö Ü, aber nur, wenn ein Kleinbuchstabe folgt
    /// („[rzte“) oder ein Großbuchstabe davor und danach steht („M]NCHEN“) – sonst sind es wirkliche Klammern („[ALARM]“).
    public static func germanUmlauts(_ text: String) -> String {
        let lower: [Character: Character] = ["{": "ä", "|": "ö", "}": "ü", "~": "ß"]
        let upper: [Character: Character] = ["[": "Ä", "\\": "Ö", "]": "Ü"]
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            if let m = lower[c] { out.append(m); continue }
            if let m = upper[c] {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let prev = i > 0 ? chars[i - 1] : nil
                let nextLower = next.map { $0.isLowercase && $0.isASCII } ?? false
                let inCapsWord = (prev.map { $0.isUppercase && $0.isASCII } ?? false) && (next.map { $0.isUppercase && $0.isASCII } ?? false)
                if nextLower || inCapsWord { out.append(m); continue }
            }
            out.append(c)
        }
        return out
    }
}

// MARK: - Diagnose

/// Beurteilt anhand der Zähler, was im Empfang schiefgeht (kein Audio, kein Signal, verzerrtes Signal, schwaches Signal)
public enum PagerDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    /// Unter diesem Pegel (dBFS, Effektivwert) kommt praktisch kein Audio an
    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: [POCSAGStats], enabled: Set<Int>) -> Result {
        let active = enabled.sorted().compactMap { stats.indices.contains($0) ? stats[$0] : nil }
        let preambles = active.reduce(0) { $0 + $1.preambles }
        let syncs = active.reduce(0) { $0 + $1.syncs }
        let good = active.reduce(0) { $0 + $1.batchesGood }
        let bad = active.reduce(0) { $0 + $1.batchesBad }
        let messages = active.reduce(0) { $0 + $1.messages }
        let equalized = active.reduce(0) { $0 + $1.equalized }
        if inputDB < silenceDB && preambles == 0 && syncs == 0 {
            return Result(severity: .problem, title: "KEIN AUDIO",
                          advice: "Am Eingang liegt kein Signal an. Rauschsperre des Funkgeräts offen? Richtiger Kanal (L, R oder L+R) und Eingang gewählt?")
        }
        if preambles == 0 && syncs == 0 {
            return Result(severity: .waiting, title: "WARTEN AUF FUNKRUF",
                          advice: "Audio kommt an, aber noch kein Funkrufsignal. DAPNET sendet nur zeitweise: weiter warten. Sonst Frequenz, Betriebsart FM (nicht schmal) und Diskriminator-Audio ohne Rauschsperre prüfen.")
        }
        if equalized > 0 && equalized * 2 >= messages {
            return Result(severity: .ok, title: "EMPFANG ENTZERRT",
                          advice: "Das Audio ist verbogen (Hochpass oder Bandpass im Audioweg): Digidec entzerrt es und liest die Meldungen nachträglich, einige Sekunden nach der Aussendung. Besser wäre Diskriminator-Audio ohne Hochpass.")
        }
        if syncs == 0 {
            return Result(severity: .problem, title: "VORSPANN OHNE SYNCHRONWORT",
                          advice: "Funkruf erkannt, aber das Synchronwort fehlt: Signal verzerrt oder übersteuert (Pegel senken), Betriebsart zu schmal, Audio nicht aus dem FM-Demodulator?")
        }
        if good == 0 && bad > 0 {
            return Result(severity: .problem, title: "SYNCHRON, ABER FEHLERHAFT",
                          advice: "Synchronwort gefunden, aber jeder Stapel hat zu viele Codewortfehler: Signal zu schwach oder gestört; Antenne, Pegel, Abstimmung prüfen.")
        }
        if bad > good {
            return Result(severity: .problem, title: "VIELE FEHLER",
                          advice: "Mehr fehlerhafte als gute Stapel: schwaches oder gestörtes Signal.")
        }
        if messages == 0 {
            return Result(severity: .ok, title: "EMPFANG GUT",
                          advice: "Stapel werden fehlerfrei gelesen; bisher keine Meldung (nur Leerstapel oder Rufe anderer Systeme).")
        }
        return Result(severity: .ok, title: "EMPFANG GUT", advice: "")
    }
}

// MARK: - Controller

@MainActor
public final class PagerController: ObservableObject {
    public let decoder: PagerDecoder
    public let logger = DecodeLogger(mode: "PAGER")
    @Published public private(set) var messages: [PagerMessage] = []
    @Published public private(set) var synced = [false, false, false, false]
    @Published public private(set) var level = 0.0
    @Published public private(set) var count = 0
    /// Diagnose: Zähler je Baudrate (512, 1200, 2400) und Eingangspegel in dBFS
    @Published public private(set) var stats = [POCSAGStats](repeating: POCSAGStats(), count: 3)
    @Published public private(set) var inputDB = -120.0
    /// Aufnahme des Eingangs (zur Fehlersuche und zum Nachdecodieren mit `decode_file.sh --pager`)
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "pagerLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxMessages = 1000
    private let settings: PagerSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: PagerSettingsStore) {
        self.settings = settings
        decoder = PagerDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "pagerLogEnabled") as? Bool ?? true
        decoder.configure(rates: settings.rates, flex: settings.flex)
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.decoder.configure(rates: self.settings.rates, flex: self.settings.flex)
                self.markSession()
            }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        messages.removeAll()
        decoder.resetStats()
        stats = [POCSAGStats](repeating: POCSAGStats(), count: 3)
    }

    /// Eingang aufnehmen (WAV in Quell-Abtastrate unter ~/Documents/Digidec/Recordings)
    public func toggleRecording(frequencyHz: Int? = nil, mode: String? = nil) {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: frequencyHz ?? settings.channel.frequencyHz.map { Int($0) }, mode: mode, preset: settings.channel.name,
                                          prefix: "PAGER")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    /// Beurteilung des Empfangs aus Zählern und Pegel
    public var diagnosis: PagerDiagnosis.Result {
        PagerDiagnosis.assess(inputDB: inputDB, stats: stats, enabled: Set(settings.rates.compactMap { POCSAG.rates.firstIndex(of: $0) }))
    }

    public func markSession() {
        var h = "PAGER · \(settings.channel.label) MHz · POCSAG " + POCSAG.rates.filter(settings.rates.contains).map(String.init).joined(separator: "/")
        if settings.flex { h += " · FLEX" }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    /// Eine Meldung aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ m: PagerMessage, at now: Date = Date()) {
        count += 1
        messages.append(m)
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
        if logEnabled { logger.append(Self.logLine(m) + "\n", now: now) }
    }

    private func poll() {
        let out = decoder.takeOutput()
        synced = out.synced
        level = out.level
        if out.stats != stats { stats = out.stats }
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        if isRecording { recordingDuration = recorder.duration }
        for m in out.messages { ingest(m) }
    }

    /// „08:15:02  POCSAG 1200  RIC 1234567 F3  Hallo Welt“
    nonisolated public static func logLine(_ m: PagerMessage) -> String {
        var s = utc.string(from: m.time) + "  " + m.protocolName + "  RIC " + String(m.address) + " F\(m.function)"
        if let d = m.detail { s += " " + d }
        s += "  " + m.text.replacingOccurrences(of: "\n", with: " ⏎ ")
        if m.corrected > 0 { s += "  [\(m.corrected) Bit korrigiert]" }
        if m.damaged > 0 { s += "  [\(m.damaged) Wörter fehlerhaft]" }
        return s
    }

    public var isWatched: (PagerMessage) -> Bool {
        let w = settings.watched
        return { w.contains($0.address) }
    }
}
