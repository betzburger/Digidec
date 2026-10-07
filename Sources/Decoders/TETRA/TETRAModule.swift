// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import VoiceCore

// TETRA (380 … 470 MHz, π/4-DQPSK, 18 000 Symbole/s, 25-kHz-Raster): Modul. Digidec liest die I/Q-Daten (2 MS/s) selbst vom Gerät,
// verfolgt den Hauptträger (und, sobald ein Ruf auf einen anderen Träger verweist, auch diesen), zeigt Netz, Gespräche, Teilnehmer und
// Kurznachrichten und gibt unverschlüsselte Sprache aus. Es wird nur das Netz empfangen, dessen Hauptträger man einträgt: das eigene Firmennetz.

// MARK: - Einstellungen

@MainActor
public final class TETRASettingsStore: ObservableObject {
    @Published public var source: ADSBSourceKind { didSet { UserDefaults.standard.set(source.rawValue, forKey: "tetraSource") } }
    /// Träger in MHz; der erste ist der Hauptträger mit dem Steuerkanal
    @Published public var carriers: [Double] { didSet { UserDefaults.standard.set(carriers, forKey: "tetraCarriers") } }
    /// Gruppen, die gehört werden (GSSI, durch Komma getrennt); leer = alle unverschlüsselten
    @Published public var listenGroups: String { didSet { UserDefaults.standard.set(listenGroups, forKey: "tetraListenGroups") } }
    /// Namen für Kennungen: je Zeile „Kennung=Name“
    @Published public var labels: String { didSet { UserDefaults.standard.set(labels, forKey: "tetraLabels") } }
    @Published public var autoFollow: Bool { didSet { UserDefaults.standard.set(autoFollow, forKey: "tetraAutoFollow") } }
    @Published public var hackrfLNA: Int { didSet { UserDefaults.standard.set(hackrfLNA, forKey: "tetraHackrfLNA") } }
    @Published public var hackrfVGA: Int { didSet { UserDefaults.standard.set(hackrfVGA, forKey: "tetraHackrfVGA") } }
    @Published public var hackrfAmp: Bool { didSet { UserDefaults.standard.set(hackrfAmp, forKey: "tetraHackrfAmp") } }
    @Published public var hackrfBias: Bool { didSet { UserDefaults.standard.set(hackrfBias, forKey: "tetraHackrfBias") } }
    @Published public var rtlGain: Double { didSet { UserDefaults.standard.set(rtlGain, forKey: "tetraRtlGain") } }
    @Published public var rtlBias: Bool { didSet { UserDefaults.standard.set(rtlBias, forKey: "tetraRtlBias") } }
    @Published public var rtlPPM: Int { didSet { UserDefaults.standard.set(rtlPPM, forKey: "tetraRtlPPM") } }
    @Published public var sdrconnectHost: String { didSet { UserDefaults.standard.set(sdrconnectHost, forKey: "tetraSdrHost") } }
    @Published public var sdrconnectPort: Int { didSet { UserDefaults.standard.set(sdrconnectPort, forKey: "tetraSdrPort") } }
    @Published public var sdrplayLNAState: Int { didSet { UserDefaults.standard.set(sdrplayLNAState, forKey: "tetraSdrLNA") } }
    @Published public var sdrplayTuner: Int { didSet { UserDefaults.standard.set(sdrplayTuner, forKey: "tetraSdrTuner") } }
    @Published public var sdrplayIFGain: Int { didSet { UserDefaults.standard.set(sdrplayIFGain, forKey: "tetraSdrIFGain") } }
    @Published public var sdrplayAGC: Bool { didSet { UserDefaults.standard.set(sdrplayAGC, forKey: "tetraSdrAGC") } }
    @Published public var sdrplayBias: Bool { didSet { UserDefaults.standard.set(sdrplayBias, forKey: "tetraSdrBias") } }
    @Published public var sdrplayPPM: Int { didSet { UserDefaults.standard.set(sdrplayPPM, forKey: "tetraSdrPPM") } }

    public init() {
        let d = UserDefaults.standard
        source = d.string(forKey: "tetraSource").flatMap(ADSBSourceKind.init(rawValue:)) ?? .rtlsdr
        carriers = (d.array(forKey: "tetraCarriers") as? [Double]) ?? []
        listenGroups = d.string(forKey: "tetraListenGroups") ?? ""
        labels = d.string(forKey: "tetraLabels") ?? ""
        autoFollow = d.object(forKey: "tetraAutoFollow") as? Bool ?? true
        hackrfLNA = d.object(forKey: "tetraHackrfLNA") as? Int ?? 32
        hackrfVGA = d.object(forKey: "tetraHackrfVGA") as? Int ?? 30
        hackrfAmp = d.object(forKey: "tetraHackrfAmp") as? Bool ?? false
        hackrfBias = d.object(forKey: "tetraHackrfBias") as? Bool ?? false
        rtlGain = d.object(forKey: "tetraRtlGain") as? Double ?? 40
        rtlBias = d.object(forKey: "tetraRtlBias") as? Bool ?? false
        rtlPPM = d.object(forKey: "tetraRtlPPM") as? Int ?? 0
        sdrconnectHost = d.string(forKey: "tetraSdrHost") ?? "127.0.0.1"
        sdrconnectPort = d.object(forKey: "tetraSdrPort") as? Int ?? 5454
        sdrplayLNAState = d.object(forKey: "tetraSdrLNA") as? Int ?? 0
        sdrplayTuner = d.object(forKey: "tetraSdrTuner") as? Int ?? 0
        sdrplayIFGain = d.object(forKey: "tetraSdrIFGain") as? Int ?? 40
        sdrplayAGC = d.object(forKey: "tetraSdrAGC") as? Bool ?? true
        sdrplayBias = d.object(forKey: "tetraSdrBias") as? Bool ?? false
        sdrplayPPM = d.object(forKey: "tetraSdrPPM") as? Int ?? 0
    }

    public var carrierFrequencies: [Double] { carriers.map(TETRAChannelPlan.hz) }
    public var centerFrequency: Double { TETRAChannelPlan.center(for: carriers) }

    public static func parseFrequencies(_ text: String) -> [Double] { TETRAChannelPlan.parseFrequencies(text) }
    public var listenSet: Set<Int> { TETRAChannelPlan.parseGroups(listenGroups) }
    public var labelMap: [Int: String] { TETRAChannelPlan.parseLabels(labels) }

    public var gain: ADSBGainSettings {
        var g = ADSBGainSettings()
        g.centerFrequencyHz = centerFrequency
        g.hackrfLNA = hackrfLNA
        g.hackrfVGA = hackrfVGA
        g.hackrfAmp = hackrfAmp
        g.hackrfBias = hackrfBias
        g.rtlGainDB = rtlGain > 0 ? rtlGain : nil
        g.rtlBias = rtlBias
        g.rtlPPM = rtlPPM
        g.sdrconnectHost = sdrconnectHost
        g.sdrconnectPort = sdrconnectPort
        g.sdrplayLNAState = sdrplayLNAState
        g.sdrplayTuner = sdrplayTuner
        g.sdrplayIFGainReduction = sdrplayIFGain
        g.sdrplayAGC = sdrplayAGC
        g.sdrplayBias = sdrplayBias
        g.sdrplayPPM = sdrplayPPM
        return g
    }
}

// MARK: - Aufnahmen

/// Aufnahme als I/Q-Quelle: WAV (8 oder 16 Bit, stereo, ab 48 kS/s), `.cu8` (roh, Rate im Namen) oder `.cs16`; 16-Bit-Werte werden auf 8 Bit
/// vorzeichenlos gebracht, leise Aufnahmen vorher angehoben (Spitze auf etwa 80 % der Aussteuerung)
public final class TETRAFileSource: ADSBIQSource, @unchecked Sendable {
    public let url: URL
    private let realtime: Bool
    public private(set) var sampleRate: Int
    private let lock = NSLock()
    private var running = false

    public init(url: URL, realtime: Bool, sampleRate: Int? = nil) {
        self.url = url
        self.realtime = realtime
        self.sampleRate = sampleRate ?? VDL2FileSource.sampleRate(of: url).map { $0 } ?? 1_000_000
        if sampleRate == nil, url.pathExtension.lowercased() == "wav", let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: 44), d.count == 44 {
                let rate = Int(d[24]) | Int(d[25]) << 8 | Int(d[26]) << 16 | Int(d[27]) << 24
                if rate >= 48_000 { self.sampleRate = rate }
            }
        }
    }

    public var deviceDescription: String { url.lastPathComponent }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44 else {
            throw ADSBSourceError.failed("Datei nicht lesbar: \(url.lastPathComponent)")
        }
        let ext = url.pathExtension.lowercased()
        var offset = 0
        var bytesPerSample = 1
        if ext == "wav" {
            var pos = 12
            var found = false
            while pos + 8 <= data.count {
                let id = String(decoding: data[pos..<(pos + 4)], as: UTF8.self)
                let size = Int(data[pos + 4]) | Int(data[pos + 5]) << 8 | Int(data[pos + 6]) << 16 | Int(data[pos + 7]) << 24
                if id == "fmt ", pos + 22 <= data.count { bytesPerSample = max(1, (Int(data[pos + 22]) | Int(data[pos + 23]) << 8) / 8) }
                if id == "data" { offset = pos + 8; found = true; break }
                pos += 8 + size + (size & 1)
            }
            guard found, bytesPerSample == 1 || bytesPerSample == 2 else { throw ADSBSourceError.failed("WAV-Format nicht unterstützt (nur 8 oder 16 Bit, I/Q stereo)") }
        } else if ext == "cs16" || ext == "s16" || ext == "raw16" {
            bytesPerSample = 2
        }
        let rate = Double(sampleRate)
        let bps = bytesPerSample, firstByte = offset
        // Verstärkung der 16-Bit-Aufnahme: Spitze der ersten Sekunden auf 100 von 127 Stufen
        var gain = 1.0
        if bps == 2 {
            var peak = 1
            data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self)
                var p = firstByte
                var n = 0
                while p + 1 < data.count && n < 400_000 {
                    let v = abs(Int(Int16(bitPattern: UInt16(base[p]) | UInt16(base[p + 1]) << 8)))
                    if v > peak { peak = v }
                    p += 2; n += 1
                }
            }
            gain = 100.0 / Double(peak)
        }
        lock.withLock { running = true }
        let g = gain
        let t = Thread { [self] in
            let frames = 32_768
            var pos = firstByte
            let start = Date()
            var sent = 0.0
            var out = [UInt8](repeating: 0, count: frames * 2)
            while lock.withLock({ running }), pos + 2 * bps <= data.count {
                let n = min(frames, (data.count - pos) / (2 * bps))
                data.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: UInt8.self)
                    if bps == 1 {
                        for k in 0..<(2 * n) { out[k] = base[pos + k] }
                    } else {
                        for k in 0..<(2 * n) {
                            let v = Double(Int16(bitPattern: UInt16(base[pos + 2 * k]) | UInt16(base[pos + 2 * k + 1]) << 8))
                            out[k] = UInt8(max(0, min(255, (v * g + 128).rounded())))
                        }
                    }
                }
                out.withUnsafeBufferPointer { onData(UnsafeBufferPointer(rebasing: $0[0..<(2 * n)])) }
                pos += 2 * n * bps
                sent += Double(n) / rate
                if realtime {
                    let wait = sent - Date().timeIntervalSince(start)
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
            }
            lock.withLock { running = false }
            onStop(nil)
        }
        t.name = "tetra-file"
        t.start()
    }

    public func stop() { lock.withLock { running = false } }
}

// MARK: - Controller

@MainActor
public final class TETRAController: ObservableObject {
    public let engine = TETRAEngine()
    public let logger = DecodeLogger(mode: "TETRA")
    @Published public private(set) var status = ADSBStatus.idle
    @Published public private(set) var snapshot = TETRAEngine.Snapshot()
    @Published public private(set) var activityHistory: [Double] = []
    @Published public private(set) var playing: UUID?
    @Published public var selection: UUID?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "tetraLogEnabled") } }
    public let output = VoiceOutput.shared
    /// Aufnahme als Quelle (Prüfung und „Datei“)
    public var fileOverride: URL?
    public var fileRealtime = true
    var sourceFactory: ((TETRASettingsStore) -> ADSBIQSource?)?

    private let settings: TETRASettingsStore
    private var source: ADSBIQSource?
    private var sourceToken = UUID()
    private var timer: Timer?
    private var active = false
    private var cancellables: Set<AnyCancellable> = []
    private var lastLoggedEvent: UUID?
    private var livePlayer: VoicePlayer?
    private let sinkState = TETRASinkState()

    public init(settings: TETRASettingsStore) {
        self.settings = settings
        logEnabled = UserDefaults.standard.object(forKey: "tetraLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let triggers: [AnyPublisher<Void, Never>] = [
            settings.$source.map { _ in () }.eraseToAnyPublisher(), settings.$carriers.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfLNA.map { _ in () }.eraseToAnyPublisher(), settings.$hackrfVGA.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfAmp.map { _ in () }.eraseToAnyPublisher(), settings.$hackrfBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlGain.map { _ in () }.eraseToAnyPublisher(), settings.$rtlBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlPPM.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayLNAState.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayTuner.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayIFGain.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayAGC.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayPPM.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .dropFirst(triggers.count)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.active else { return }
                self.stopSource()
                self.startSource()
            }
            .store(in: &cancellables)
        settings.$listenGroups
            .sink { [weak self] _ in self?.applyFilters() }
            .store(in: &cancellables)
        settings.$autoFollow
            .sink { [weak self] on in self?.engine.autoFollow = on }
            .store(in: &cancellables)
    }

    private func applyFilters() {
        engine.tracker.configure(listenGroups: settings.listenSet)
    }

    /// Namen aus den Einstellungen zu einer Kennung
    public func label(_ ssi: Int?) -> String {
        guard let ssi else { return "–" }
        if let name = settings.labelMap[ssi] { return "\(ssi) \(name)" }
        return String(ssi)
    }

    public func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { startSource() } else { stopSource() }
    }

    public func clear() {
        engine.reset()
        engine.tracker.clear()
        snapshot = TETRAEngine.Snapshot()
        activityHistory.removeAll()
        selection = nil
    }

    // MARK: Ton

    private func prepareSpeech() {
        output.refresh()
        if let decoder = VoiceRegistry.shared.tetraDecoder {
            engine.speech = TETRASpeechAdapter(name: decoder.name, reset: { decoder.reset() }, decode: { decoder.decode(bits: $0, badFrame: $1) })
        } else {
            engine.speech = nil
        }
        engine.audioEnabled = output.playAudio
        let state = sinkState
        engine.audioSink = { [weak self] pcm in
            // Vor dem ersten Rahmen nach einer Pause etwas Vorlauf, damit die Wiedergabe nicht stottert
            state.lock.lock()
            let now = Date()
            let gap = now.timeIntervalSince(state.last) > 0.4
            state.last = now
            let player = state.player
            state.lock.unlock()
            guard let player else { return }
            if gap { player.enqueue([Int16](repeating: 0, count: 960)) }
            player.enqueue(pcm)
            _ = self
        }
    }

    private func ensurePlayer() {
        if livePlayer == nil, output.tetraAvailable {
            livePlayer = output.startLivePlayer()
            sinkState.lock.withLock { sinkState.player = livePlayer }
        }
    }

    /// Ein vergangenes Gespräch noch einmal abspielen
    public func replay(_ call: TETRACall) {
        output.playTetra(call.audio)
        playing = call.id
    }

    // MARK: Quelle

    public func startSource() {
        stopSource()
        prepareSpeech()
        ensurePlayer()
        applyFilters()
        engine.autoFollow = settings.autoFollow
        let src: ADSBIQSource
        var sampleRate = 2_000_000
        var center = settings.centerFrequency
        var frequencies = settings.carrierFrequencies
        var device = true
        if let made = sourceFactory?(settings) {
            src = made
        } else if let url = fileOverride {
            let file = TETRAFileSource(url: url, realtime: fileRealtime)
            sampleRate = file.sampleRate
            // Aufnahme: ein Träger in der Mitte
            let f = frequencies.first ?? 400_000_000
            center = f
            frequencies = [f]
            device = false
            src = file
        } else {
            guard !frequencies.isEmpty else {
                status = .error("Hauptträger eintragen (Frequenz des Steuerkanals des eigenen Netzes, in MHz)")
                return
            }
            switch settings.source {
            case .hackrf: src = HackRFSource(settings: settings.gain)
            case .rtlsdr: src = RTLSDRSource(settings: settings.gain)
            case .sdrplay: src = SDRplayAPISource(settings: settings.gain)
            case .sdrconnect: src = SDRconnectSource(settings: settings.gain)
            case .file:
                status = .error("Keine Aufnahme gewählt (Knopf ÖFFNEN)")
                return
            }
        }
        engine.configure(sampleRate: sampleRate, centerFrequency: center, frequencies: frequencies, countClipping: device)
        let engine = self.engine
        let wait = fileOverride != nil && !fileRealtime
        let token = UUID()
        sourceToken = token
        do {
            try src.start(onData: { engine.feed($0, wait: wait) }, onStop: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sourceStopped(reason, token: token) } }
            })
            source = src
            status = .running(src.deviceDescription)
            logger.markSession("TETRA · \(frequencies.map { TETRAChannelPlan.title($0) }.joined(separator: " ")) MHz · \(src.deviceDescription)")
        } catch {
            status = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func stopSource() {
        sourceToken = UUID()
        source?.stop()
        source = nil
        if case .running = status { status = .idle }
    }

    private func sourceStopped(_ reason: String?, token: UUID) {
        guard token == sourceToken, source != nil else { return }
        source = nil
        status = reason.map { .error($0) } ?? .idle
    }

    // MARK: Abfrage

    private func poll() {
        guard active || fileOverride != nil else { return }
        let s = engine.snapshot()
        snapshot = s
        activityHistory.append(s.activity)
        if activityHistory.count > 240 { activityHistory.removeFirst(activityHistory.count - 240) }
        if let m = s.audioMarker, let c = s.calls.last(where: { $0.usageMarker == m && $0.isLive }) { playing = c.id } else if s.audioMarker == nil { playing = nil }
        if logEnabled { logNewEvents(s.events) }
    }

    private func logNewEvents(_ events: [TETRAEventRecord]) {
        var start = 0
        if let last = lastLoggedEvent, let i = events.firstIndex(where: { $0.id == last }) { start = i + 1 }
        guard start < events.count else { return }
        for e in events[start...] {
            logger.append("\(TETRAController.timeFormatter.string(from: e.time))  \(TETRAChannelPlan.title(e.frequency))  \(e.tetraTime)  \(e.kind)  \(e.text)\n", now: e.time)
        }
        lastLoggedEvent = events.last?.id
    }

    nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated public static func time(_ d: Date) -> String { timeFormatter.string(from: d) + " UTC" }
}

/// Zustand der Tonausgabe, auf den der Faden der Engine zugreift
final class TETRASinkState: @unchecked Sendable {
    let lock = NSLock()
    var last = Date.distantPast
    var player: VoicePlayer?
}
