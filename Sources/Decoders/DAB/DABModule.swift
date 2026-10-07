// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import AVFoundation

// DAB und DAB+ (Eureka 147, Band III, 174 bis 240 MHz): Modul. Digidec liest die I/Q-Daten (2,048 MS/s) selbst vom Gerät (HackRF, RTL-SDR, SDRplay),
// decodiert das Ensemble (FIC) und spielt einen gewählten DAB+-Dienst (HE-AAC) über den Standard-Ausgang.

// MARK: - Kanäle (Blöcke) des Bandes III

public struct DABBlock: Identifiable, Hashable, Sendable {
    public let name: String
    public let frequencyHz: Double
    public var id: String { name }
    public var title: String { String(format: "%@ · %.3f MHz", name, frequencyHz / 1e6).replacingOccurrences(of: ".", with: ",") }

    public static let all: [DABBlock] = [
        ("5A", 174_928), ("5B", 176_640), ("5C", 178_352), ("5D", 180_064), ("6A", 181_936), ("6B", 183_648), ("6C", 185_360), ("6D", 187_072),
        ("7A", 188_928), ("7B", 190_640), ("7C", 192_352), ("7D", 194_064), ("8A", 195_936), ("8B", 197_648), ("8C", 199_360), ("8D", 201_072),
        ("9A", 202_928), ("9B", 204_640), ("9C", 206_352), ("9D", 208_064), ("10A", 209_936), ("10B", 211_648), ("10C", 213_360), ("10D", 215_072),
        ("11A", 216_928), ("11B", 218_640), ("11C", 220_352), ("11D", 222_064), ("12A", 223_936), ("12B", 225_648), ("12C", 227_360), ("12D", 229_072),
        ("13A", 230_784), ("13B", 232_496), ("13C", 234_208), ("13D", 235_776), ("13E", 237_488), ("13F", 239_200),
    ].map { DABBlock(name: $0.0, frequencyHz: Double($0.1) * 1000) }

    public static func named(_ n: String) -> DABBlock? { all.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
}

// MARK: - Einstellungen

@MainActor
public final class DABSettingsStore: ObservableObject {
    @Published public var blockName: String { didSet { UserDefaults.standard.set(blockName, forKey: "dabBlock") } }
    @Published public var source: ADSBSourceKind { didSet { UserDefaults.standard.set(source.rawValue, forKey: "dabSource") } }
    @Published public var hackrfLNA: Int { didSet { UserDefaults.standard.set(hackrfLNA, forKey: "dabHackrfLNA") } }
    @Published public var hackrfVGA: Int { didSet { UserDefaults.standard.set(hackrfVGA, forKey: "dabHackrfVGA") } }
    @Published public var hackrfAmp: Bool { didSet { UserDefaults.standard.set(hackrfAmp, forKey: "dabHackrfAmp") } }
    @Published public var hackrfBias: Bool { didSet { UserDefaults.standard.set(hackrfBias, forKey: "dabHackrfBias") } }
    @Published public var rtlGain: Double { didSet { UserDefaults.standard.set(rtlGain, forKey: "dabRtlGain") } }
    @Published public var rtlBias: Bool { didSet { UserDefaults.standard.set(rtlBias, forKey: "dabRtlBias") } }
    @Published public var rtlPPM: Int { didSet { UserDefaults.standard.set(rtlPPM, forKey: "dabRtlPPM") } }
    @Published public var sdrplayLNAState: Int { didSet { UserDefaults.standard.set(sdrplayLNAState, forKey: "dabSdrLNA") } }
    @Published public var sdrplayTuner: Int { didSet { UserDefaults.standard.set(sdrplayTuner, forKey: "dabSdrTuner") } }
    @Published public var sdrplayIFGain: Int { didSet { UserDefaults.standard.set(sdrplayIFGain, forKey: "dabSdrIFGain") } }
    @Published public var sdrplayAGC: Bool { didSet { UserDefaults.standard.set(sdrplayAGC, forKey: "dabSdrAGC") } }
    @Published public var sdrplayBias: Bool { didSet { UserDefaults.standard.set(sdrplayBias, forKey: "dabSdrBias") } }
    @Published public var sdrplayPPM: Int { didSet { UserDefaults.standard.set(sdrplayPPM, forKey: "dabSdrPPM") } }
    /// Kennung des zuletzt gehörten Dienstes (0 = keiner); er wird beim nächsten Start nach dem Empfang des Ensembles wieder gespielt
    @Published public var selectedSID: Int { didSet { UserDefaults.standard.set(selectedSID, forKey: "dabSID") } }
    @Published public var volume: Double { didSet { UserDefaults.standard.set(volume, forKey: "dabVolume") } }
    @Published public var muted: Bool { didSet { UserDefaults.standard.set(muted, forKey: "dabMuted") } }

    public init() {
        let d = UserDefaults.standard
        blockName = d.string(forKey: "dabBlock") ?? "11D"
        let kind = d.string(forKey: "dabSource").flatMap(ADSBSourceKind.init(rawValue:)) ?? .hackrf
        source = (kind == .sdrconnect || kind == .file) ? .hackrf : kind
        hackrfLNA = d.object(forKey: "dabHackrfLNA") as? Int ?? 16
        hackrfVGA = d.object(forKey: "dabHackrfVGA") as? Int ?? 16
        hackrfAmp = d.object(forKey: "dabHackrfAmp") as? Bool ?? false
        hackrfBias = d.object(forKey: "dabHackrfBias") as? Bool ?? false
        rtlGain = d.object(forKey: "dabRtlGain") as? Double ?? 0
        rtlBias = d.object(forKey: "dabRtlBias") as? Bool ?? false
        rtlPPM = d.object(forKey: "dabRtlPPM") as? Int ?? 0
        sdrplayLNAState = d.object(forKey: "dabSdrLNA") as? Int ?? 3
        sdrplayTuner = d.object(forKey: "dabSdrTuner") as? Int ?? 0
        sdrplayIFGain = d.object(forKey: "dabSdrIFGain") as? Int ?? 40
        sdrplayAGC = d.object(forKey: "dabSdrAGC") as? Bool ?? true
        sdrplayBias = d.object(forKey: "dabSdrBias") as? Bool ?? false
        sdrplayPPM = d.object(forKey: "dabSdrPPM") as? Int ?? 0
        selectedSID = d.object(forKey: "dabSID") as? Int ?? 0
        volume = d.object(forKey: "dabVolume") as? Double ?? 0.7
        muted = d.object(forKey: "dabMuted") as? Bool ?? false
    }

    public var block: DABBlock { DABBlock.named(blockName) ?? DABBlock.all[27] }

    public var gain: ADSBGainSettings {
        var g = ADSBGainSettings()
        g.centerFrequencyHz = block.frequencyHz
        g.sampleRateHz = DABMode1.sampleRate
        g.hackrfLNA = hackrfLNA
        g.hackrfVGA = hackrfVGA
        g.hackrfAmp = hackrfAmp
        g.hackrfBias = hackrfBias
        g.rtlGainDB = rtlGain > 0 ? rtlGain : nil
        g.rtlBias = rtlBias
        g.rtlPPM = rtlPPM
        g.sdrplayLNAState = sdrplayLNAState
        g.sdrplayTuner = sdrplayTuner
        g.sdrplayIFGainReduction = sdrplayIFGain
        g.sdrplayAGC = sdrplayAGC
        g.sdrplayBias = sdrplayBias
        g.sdrplayPPM = sdrplayPPM
        return g
    }
}

// MARK: - Ausgabe

/// Spielt die decodierten Abtastwerte (Mono oder Stereo, beliebige Rate) über den Standard-Ausgang
public final class DABPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var ring = FloatRingBuffer(capacity: 48_000 * 2 * 2)
    private let lock = NSLock()
    private var channels = 0
    private var rate = 0
    private var running = false
    private var primed = false
    private let gain = NSLock()
    private var volumeValue: Float = 0.7
    private var mutedValue = false
    private var peakValue: Float = 0

    public init() {}

    public var volume: Float {
        get { gain.withLock { volumeValue } }
        set { gain.withLock { volumeValue = max(0, min(1, newValue)) } }
    }

    public var muted: Bool {
        get { gain.withLock { mutedValue } }
        set { gain.withLock { mutedValue = newValue } }
    }

    /// Spitzenpegel seit dem letzten Aufruf (0 … 1)
    public func takePeak() -> Float { gain.withLock { defer { peakValue = 0 }; return peakValue } }

    private func start(channels c: Int, rate r: Int) {
        stop()
        channels = c
        rate = r
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(r), channels: AVAudioChannelCount(c))!
        let capacity = r * c * 2
        ring = FloatRingBuffer(capacity: capacity)
        let ring = self.ring
        let channelsCopy = c
        let me = self
        var scratch = [Float](repeating: 0, count: 8192 * c)
        let n = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let count = min(Int(frames), 8192)
            let want = count * channelsCopy
            let got = scratch.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: want) }
            if got < want { for k in got..<want { scratch[k] = 0 } }
            let (volume, muted) = me.gain.withLock { (me.volumeValue, me.mutedValue) }
            let g: Float = muted ? 0 : volume
            // Verschachtelt (L R L R …) in je einen Puffer je Kanal
            for ch in 0..<min(channelsCopy, buffers.count) {
                guard let out = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for k in 0..<count { out[k] = scratch[k * channelsCopy + ch] * g }
                if Int(frames) > count { (out + count).update(repeating: 0, count: Int(frames) - count) }
            }
            return noErr
        }
        node = n
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            running = true
        } catch {
            engine.detach(n)
            node = nil
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        engine.stop()
        if let n = node { engine.detach(n) }
        node = nil
        primed = false
    }

    /// Abtastwerte abgeben; ändert sich Kanalzahl oder Rate, wird die Ausgabe neu aufgebaut
    public func write(_ samples: [Float], channels c: Int, rate r: Int) {
        guard !samples.isEmpty, c > 0, r > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if !running || c != channels || r != rate { start(channels: c, rate: r) }
        guard running else { return }
        var peak: Float = 0
        for x in samples { peak = max(peak, abs(x)) }
        gain.withLock { peakValue = max(peakValue, peak) }
        // Rückstau (Takte von Sender und Ausgabegerät laufen auseinander): auf kurze Verzögerung zurück
        if ring.available > r * c / 2 {
            var skip = [Float](repeating: 0, count: ring.available - r * c / 5)
            _ = skip.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: $0.count) }
        }
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        ring.clear()
    }
}

// MARK: - Engine

/// Die Empfangskette auf eigenem Faden: I/Q → OFDM → FIC und Hauptdienstkanal → AAC → Ton
public final class DABEngine: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var synced = false
        public var snrDB = 0.0
        public var frames = 0
        public var fibGood = 0
        public var fibBad = 0
        public var fibRatio = 0.0
        public var coarseHz = 0.0
        public var fineHz = 0.0
        public var clockPPM = 0.0
        public var superframes = 0
        public var correctedBytes = 0
        public var uncorrectable = 0
        public var badAUs = 0
        public var formatText = ""
        public var audioLevel = 0.0
        public var ensembleLabel = ""
        public var ensembleId = 0
        public var ecc = 0
        public var ensembleTime: Date?
        public var services: [DABService] = []
        public var subchannels: [Int: DABSubchannel] = [:]
        public var revision = 0
        public var dropped = 0
        /// Mittlere Auslenkung der I/Q-Werte und Anteil übersteuerter Abtastwerte
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var playing = false
        public var unsupportedReason = ""
        /// Dynamic Label des gespielten Dienstes (laufender Titel)
        public var dynamicLabel = ""
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.dab", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingBytes = 0
    private var droppedBlocks = 0
    private var rows: [[Float]] = []
    private var shared = Snapshot()
    private var activity = 0.0
    private var clipped = 0, total = 0

    private let rx = DABOFDMReceiver()
    private let fic = DABFICDecoder()
    private let cif = DABCIFAssembler()
    private let ensemble = DABEnsemble()
    private var sub: DABSubchannelDecoder?
    private var superframe = DABSuperframeDecoder()
    private var aac: DABAACDecoder?
    private let spectrum = SDRSpectrum(sampleRate: Double(DABMode1.sampleRate))
    private let pad = DABPADDecoder()
    private var dynamicLabel = ""
    public let player = DABPlayer()

    private var wantedSID: UInt32 = 0
    private var activeSubchannel: DABSubchannel?
    private var lastRevision = -1
    private var unsupported = ""
    private var formatText = ""
    private static let maxPending = 6 * 1024 * 1024

    public init() {
        rx.onSymbol = { [unowned self] k, bits in
            if k <= 3 { fic.process(symbol: k, bits: bits) } else { cif.process(symbol: k, bits: bits) }
        }
        fic.onFIB = { [unowned self] fib, _ in ensemble.process(fib: fib) }
        rx.onFrame = { [unowned self] in checkSelection() }
        rx.onSyncChange = { [unowned self] synced in
            if synced { rebuildSubchannel() }
        }
        cif.onCIF = { [unowned self] c in sub?.process(cif: c) }
        wire(superframe)
        pad.onLabel = { [unowned self] t in dynamicLabel = t }
    }

    /// Neu aufsetzen (Kanal gewechselt oder Gerät neu geöffnet)
    public func reset() {
        queue.async { [self] in
            rx.reset()
            ensemble.reset()
            sub = nil
            activeSubchannel = nil
            superframe = DABSuperframeDecoder()
            wire(superframe)
            aac = nil
            pad.reset(); dynamicLabel = ""
            player.flush()
            lastRevision = -1
            lock.withLock { rows.removeAll(); droppedBlocks = 0; clipped = 0; total = 0; shared = Snapshot() }
        }
    }

    private func wire(_ sf: DABSuperframeDecoder) {
        sf.onFormat = { [unowned self] f in
            formatText = "\(f.codecName) \(f.channelsText) \(f.outputRate / 1000) kHz"
            aac = try? DABAACDecoder(format: f)
        }
        sf.onAU = { [unowned self] au, f in
            pad.process(accessUnit: au)
            if aac == nil { aac = try? DABAACDecoder(format: f) }
            guard let a = aac else { return }
            let pcm = a.decode(au)
            if !pcm.isEmpty { player.write(pcm, channels: a.outputChannels, rate: a.outputRate) }
        }
    }

    /// Dienst zum Hören wählen (0 = keiner)
    public func select(sid: UInt32) {
        queue.async { [self] in
            wantedSID = sid
            unsupported = ""
            sub = nil
            activeSubchannel = nil
            superframe = DABSuperframeDecoder()
            wire(superframe)
            aac = nil
            formatText = ""
            pad.reset(); dynamicLabel = ""
            player.flush()
        }
    }

    public var volume: Float { get { player.volume } set { player.volume = newValue } }
    public var muted: Bool { get { player.muted } set { player.muted = newValue } }

    public func feed(_ buffer: UnsafeBufferPointer<UInt8>, wait: Bool = false) {
        let n = buffer.count
        if wait { while lock.withLock({ pendingBytes + n > Self.maxPending }) { Thread.sleep(forTimeInterval: 0.002) } }
        let over = lock.withLock { () -> Bool in
            if pendingBytes + n > Self.maxPending { droppedBlocks += 1; return true }
            pendingBytes += n
            return false
        }
        if over { return }
        let copy = Data(buffer: buffer)
        queue.async { [self] in
            process(copy)
            lock.withLock { pendingBytes -= n }
        }
    }

    private func process(_ data: Data) {
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            var sum = 0, clip = 0, i = 0
            while i < buf.count {
                sum += abs(Int(buf[i]) - 128)
                if buf[i] == 0 || buf[i] == 255 { clip += 1 }
                i += 8
            }
            var newRows: [[Float]] = []
            spectrum.consume(buf, rows: &newRows)
            rx.process(buf)
            let counted = max(1, (buf.count + 7) / 8)
            lock.withLock {
                activity += (Double(sum) / Double(counted) - activity) * 0.2
                clipped += clip; total += counted
                rows.append(contentsOf: newRows)
                if rows.count > 100 { rows.removeFirst(rows.count - 100) }
            }
        }
        publish()
    }

    // MARK: Auswahl

    private func rebuildSubchannel() {
        // nach einer Lücke im Signal ist die Zeitverschachtelung ungültig
        guard let s = activeSubchannel else { return }
        sub = DABSubchannelDecoder(subchannel: s)
        sub?.onFrame = { [unowned self] f in superframe.feed(frame: f) }
    }

    private func checkSelection() {
        guard wantedSID != 0, let service = ensemble.services[wantedSID] else { return }
        guard let comp = service.primaryAudio else { return }
        guard comp.audioType == 63 else {
            unsupported = comp.audioType == 0 ? "DAB (MPEG Layer II) wird noch nicht unterstützt" : "Dienstart nicht unterstützt"
            return
        }
        guard let s = ensemble.subchannels[comp.subchannelId] else { return }
        if activeSubchannel != s || sub == nil {
            activeSubchannel = s
            superframe = DABSuperframeDecoder()
            wire(superframe)
            aac = nil
            sub = DABSubchannelDecoder(subchannel: s)
            sub?.onFrame = { [unowned self] f in superframe.feed(frame: f) }
            if sub == nil { unsupported = "Schutzprofil dieses Dienstes nicht unterstützt" }
        }
    }

    // MARK: Messwerte

    private func publish() {
        var s = Snapshot()
        s.synced = rx.isSynced
        s.snrDB = rx.snrDB
        s.frames = rx.frameCount
        s.fibGood = fic.fibsGood
        s.fibBad = fic.fibsBad
        s.fibRatio = fic.recentRatio
        s.coarseHz = rx.coarseHz
        s.fineHz = rx.fineHz
        s.clockPPM = rx.clockOffsetPPM
        s.superframes = superframe.syncedSuperframes
        s.correctedBytes = superframe.correctedBytes
        s.uncorrectable = superframe.uncorrectable
        s.badAUs = superframe.badAUs
        s.formatText = formatText
        s.audioLevel = Double(player.takePeak())
        s.ensembleLabel = ensemble.label
        s.ensembleId = Int(ensemble.ensembleId)
        s.ecc = ensemble.ecc
        s.ensembleTime = ensemble.time
        s.revision = ensemble.revision
        s.unsupportedReason = unsupported
        s.dynamicLabel = dynamicLabel
        s.playing = wantedSID != 0 && superframe.isSynced
        let revisionChanged = ensemble.revision != lastRevision
        if revisionChanged {
            lastRevision = ensemble.revision
        }
        lock.withLock {
            s.dropped = droppedBlocks
            s.activity = activity
            s.clippedFraction = total > 0 ? Double(clipped) / Double(total) : 0
            if revisionChanged {
                s.services = ensemble.serviceList
                s.subchannels = ensemble.subchannels
            } else {
                s.services = shared.services
                s.subchannels = shared.subchannels
            }
            shared = s
        }
    }

    public func snapshot() -> Snapshot { lock.withLock { shared } }

    public func takeSpectrumRows() -> [[Float]] {
        lock.withLock { () -> [[Float]] in defer { rows.removeAll() }; return rows }
    }

    public func resetClipping() { lock.withLock { clipped = 0; total = 0 } }
}

// MARK: - Controller

@MainActor
public final class DABController: ObservableObject {
    public let engine = DABEngine()
    public let logger = DecodeLogger(mode: "DAB")
    @Published public private(set) var status = ADSBStatus.idle
    @Published public private(set) var snapshot = DABEngine.Snapshot()
    @Published public private(set) var scanResults: [DABScanResult] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var scanText = ""
    /// Aufnahme als Quelle (Entwicklung, Prüfung)
    public var fileOverride: URL?
    public var fileRealtime = true
    /// Die Aufnahme enthält vorzeichenbehaftete Bytes (HackRF-Rohdaten)
    public var fileSigned = false
    /// Entwicklungshilfe: Dienst mit diesem Namensteil automatisch wählen, sobald er gehört wird
    public var autoSelectName: String?
    var sourceFactory: ((DABSettingsStore) -> ADSBIQSource?)?

    private let settings: DABSettingsStore
    private var source: ADSBIQSource?
    private var sourceToken = UUID()
    private var startedGain: ADSBGainSettings?
    private var timer: Timer?
    private var active = false
    private var cancellables: Set<AnyCancellable> = []
    private var restartWork: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?

    public init(settings: DABSettingsStore) {
        self.settings = settings
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
        engine.volume = Float(settings.volume)
        engine.muted = settings.muted
    }

    public func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { startSource() } else { stopSource() }
    }

    // MARK: Gerät

    public func startSource() {
        stopSource()
        let src: ADSBIQSource
        let gain = settings.gain
        if let made = sourceFactory?(settings) {
            src = made
        } else if let url = fileOverride {
            src = DABFileSource(url: url, signed: fileSigned, realtime: fileRealtime)
        } else {
            switch settings.source {
            case .hackrf: src = HackRFSource(settings: gain)
            case .rtlsdr: src = RTLSDRSource(settings: gain)
            case .sdrplay: src = SDRplayAPISource(settings: gain)
            case .sdrconnect, .file:
                status = .error("Quelle nicht verfügbar: HackRF, RTL-SDR oder SDRplay wählen")
                return
            }
        }
        engine.reset()
        engine.select(sid: UInt32(settings.selectedSID))
        let engine = self.engine
        let wait = fileOverride != nil && !fileRealtime
        let token = UUID()
        sourceToken = token
        do {
            try src.start(onData: { engine.feed($0, wait: wait) }, onStop: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sourceStopped(reason, token: token) } }
            })
            source = src
            startedGain = gain
            status = .running(src.deviceDescription)
            logger.markSession("DAB · Block \(settings.block.title) · \(src.deviceDescription)")
        } catch {
            status = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func stopSource() {
        scanTask?.cancel()
        scanning = false
        sourceToken = UUID()
        restartWork?.cancel()
        source?.stop()
        source = nil
        startedGain = nil
        engine.player.stop()
        if case .running = status { status = .idle }
    }

    private func sourceStopped(_ reason: String?, token: UUID) {
        guard token == sourceToken, source != nil else { return }
        source = nil
        status = reason.map { .error($0) } ?? .idle
    }

    // MARK: Einstellungen

    private func settingsChanged() {
        engine.volume = Float(settings.volume)
        engine.muted = settings.muted
        guard active, source != nil else { return }
        if let started = startedGain {
            let now = settings.gain
            if now.centerFrequencyHz != started.centerFrequencyHz {
                // Block gewechselt: das Gerät im Betrieb umstimmen, sonst neu öffnen
                if let tunable = source as? SDRTunableSource, tunable.retune(centerHz: now.centerFrequencyHz) {
                    startedGain = now
                    engine.reset()
                    engine.select(sid: UInt32(settings.selectedSID))
                } else if fileOverride == nil {
                    scheduleRestart()
                }
            } else if now != started {
                scheduleRestart()
            }
        }
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self, self.active { self.startSource() } }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func select(service: DABService?) {
        settings.selectedSID = service.map { Int($0.sid) } ?? 0
        engine.select(sid: service?.sid ?? 0)
    }

    public func tune(block: DABBlock) {
        guard block.name != settings.blockName else { return }
        settings.blockName = block.name
    }

    // MARK: Messwerte

    private func poll() {
        guard active || fileOverride != nil else { return }
        snapshot = engine.snapshot()
        // Entwicklungshilfe: einen Dienst nach Namen wählen
        if let name = autoSelectName, settings.selectedSID == 0, let s = snapshot.services.first(where: { $0.label.lowercased().contains(name.lowercased()) }) {
            select(service: s)
        }
    }

    public var selectedService: DABService? {
        snapshot.services.first { Int($0.sid) == settings.selectedSID }
    }

    public func subchannel(of service: DABService) -> DABSubchannel? {
        service.primaryAudio.flatMap { snapshot.subchannels[$0.subchannelId] }
    }

    // MARK: Suchlauf

    /// Alle Blöcke des Bandes III nacheinander abhören und die gefundenen Ensembles sammeln
    public func startScan() {
        guard active, !scanning, source is SDRTunableSource else {
            if active, !scanning { scanText = "Der Suchlauf braucht ein Gerät, das sich im Betrieb umstimmen lässt" }
            return
        }
        scanning = true
        scanResults = []
        let original = settings.blockName
        engine.select(sid: 0)
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for block in DABBlock.all {
                if Task.isCancelled { break }
                self.scanText = "Suchlauf: \(block.title)"
                guard let tunable = self.source as? SDRTunableSource, tunable.retune(centerHz: block.frequencyHz) else { break }
                self.engine.reset()
                // bis zu 6 s auf Synchronisation und Ensemble; fertig, wenn die Dienstliste 1,5 s unverändert ist
                var waited = 0.0
                var found: DABEngine.Snapshot?
                var lastRevision = -1
                var stable = 0.0
                while waited < 6.0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waited += 0.25
                    let s = self.engine.snapshot()
                    if !s.synced && waited >= 1.5 { break }
                    if s.synced && !s.ensembleLabel.isEmpty && !s.services.isEmpty {
                        if s.revision == lastRevision { stable += 0.25 } else { stable = 0; lastRevision = s.revision }
                        if stable >= 1.5 { found = s; break }
                    }
                }
                if let f = found {
                    self.scanResults.append(DABScanResult(block: block.name, label: f.ensembleLabel, ensembleId: f.ensembleId, serviceCount: f.services.count, snrDB: f.snrDB))
                }
            }
            if let tunable = self.source as? SDRTunableSource, let b = DABBlock.named(original) {
                _ = tunable.retune(centerHz: b.frequencyHz)
                self.engine.reset()
                self.engine.select(sid: UInt32(self.settings.selectedSID))
            }
            self.scanning = false
            self.scanText = "Suchlauf beendet: \(self.scanResults.count) Ensembles"
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
    }
}

public struct DABScanResult: Identifiable, Equatable, Sendable {
    public var id: String { block }
    public var block: String
    public var label: String
    public var ensembleId: Int
    public var serviceCount: Int
    public var snrDB: Double
}

// MARK: - Aufnahme als Quelle

/// Aufnahme (8-Bit-I/Q, 2,048 MS/s) als Quelle, in Echtzeit oder schneller; HackRF-Rohdaten sind vorzeichenbehaftet
public final class DABFileSource: ADSBIQSource, @unchecked Sendable {
    private let url: URL
    private let signed: Bool
    private let realtime: Bool
    private let lock = NSLock()
    private var running = false

    public init(url: URL, signed: Bool, realtime: Bool) {
        self.url = url
        self.signed = signed
        self.realtime = realtime
    }

    public var deviceDescription: String { url.lastPathComponent }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 4 else {
            throw ADSBSourceError.failed("Datei nicht lesbar: \(url.lastPathComponent)")
        }
        lock.withLock { running = true }
        let signed = self.signed, realtime = self.realtime
        let t = Thread { [self] in
            let block = 65_536
            var offset = 0
            var buffer = [UInt8](repeating: 0, count: block)
            let start = Date()
            var sent = 0.0
            while lock.withLock({ running }) {
                if offset >= data.count { offset = 0 }
                let end = min(offset + block, data.count)
                let n = end - offset
                data.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: UInt8.self)
                    for i in 0..<n { buffer[i] = signed ? src[offset + i] ^ 0x80 : src[offset + i] }
                }
                buffer.withUnsafeBufferPointer { onData(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                sent += Double(n) / Double(2 * DABMode1.sampleRate)
                offset = end
                if realtime {
                    let wait = sent - Date().timeIntervalSince(start)
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
            }
            onStop(nil)
        }
        t.name = "dab-file"
        t.start()
    }

    public func stop() { lock.withLock { running = false } }
}
