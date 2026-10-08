// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import AVFoundation
import os

// Eingebauter SDR-Empfänger: Digidec liest die I/Q-Daten selbst vom Gerät (HackRF, RTL-SDR, SDRplay) und liefert das demodulierte Audio an die
// Eingangs-Pipeline wie sonst eine virtuelle Soundkarte. Frequenz und Betriebsart stellt Digidec (QSY AUTO der Module) oder der Nutzer ein.

// MARK: - Einstellungen

@MainActor
public final class SDRSettingsStore: ObservableObject {
    public static let sampleRate = 2_400_000
    /// Wählbare Abtastraten des HackRF (RTL-SDR läuft mit 2,4 MS/s, SDRplay hat eine eigene Liste, `SDRplayPlan.sampleRates`). Vielfache von 480 kS/s teilen sich ganzzahlig herunter;
    /// 20 MS/s (Höchstwert des HackRF) geht erst auf 1 MS/s und dann über den Wandler.
    public static let sampleRateChoices = [2_400_000, 4_800_000, 9_600_000, 14_400_000, 19_200_000, 20_000_000]

    /// Abtastraten, die ein Gerät bietet (RTL-SDR ist nur mit 2,4 MS/s geprüft); SDRplay: 62,5 kS/s bis 10 MS/s
    public static func sampleRateChoices(for source: ADSBSourceKind) -> [Int] {
        switch source {
        case .hackrf: return sampleRateChoices
        case .sdrplay: return SDRplayPlan.sampleRates
        default: return [sampleRate]
        }
    }
    /// Wie weit sich die gehörte Frequenz von der Mitte des I/Q-Fensters entfernen darf, bevor das Gerät umgestimmt wird
    static let window = 850_000.0
    /// Nutzbare halbe Fensterbreite bei einer Abtastrate (bei 2,4 MS/s 850 kHz: die Ränder des Geräts fallen ab)
    static func window(forRate rate: Int) -> Double { Double(rate) * 850_000.0 / 2_400_000.0 }
    /// Abstand der Gerätemitte von der gehörten Frequenz nach dem Umstimmen (die Gleichanteil-Spitze liegt auf der Mitte)
    static let loOffset = 300_000.0
    /// Abstand bei einer Abtastrate: ein Achtel der Rate, höchstens 300 kHz (62,5 kS/s: knapp 8 kHz)
    static func loOffset(forRate rate: Int) -> Double { min(loOffset, Double(rate) / 8) }
    /// Mindestabstand der gehörten Frequenz von der Mitte (Gleichanteil): 40 kHz bei 2,4 MS/s, bei kleineren Raten weniger
    static func dcGuard(forRate rate: Int) -> Double { min(40_000, Double(rate) / 60) }

    @Published public var source: ADSBSourceKind { didSet { save(source.rawValue, "sdrSource") } }
    @Published public var hackrfLNA: Int { didSet { save(hackrfLNA, "sdrHackrfLNA") } }
    @Published public var hackrfVGA: Int { didSet { save(hackrfVGA, "sdrHackrfVGA") } }
    /// Abtastrate des I/Q-Stroms (nur HackRF über 2,4 MS/s; für den Mehrkanalbetrieb mit breitem Fenster)
    @Published public var sampleRateHz: Int { didSet { save(sampleRateHz, "sdrSampleRate") } }
    @Published public var hackrfAmp: Bool { didSet { save(hackrfAmp, "sdrHackrfAmp") } }
    @Published public var hackrfBias: Bool { didSet { save(hackrfBias, "sdrHackrfBias") } }
    @Published public var rtlGain: Double { didSet { save(rtlGain, "sdrRtlGain") } }
    @Published public var rtlBias: Bool { didSet { save(rtlBias, "sdrRtlBias") } }
    @Published public var rtlPPM: Int { didSet { save(rtlPPM, "sdrRtlPPM") } }
    @Published public var sdrplayLNAState: Int { didSet { save(sdrplayLNAState, "sdrSdrLNA") } }
    @Published public var sdrplayTuner: Int { didSet { save(sdrplayTuner, "sdrSdrTuner") } }
    @Published public var sdrplayIFGain: Int { didSet { save(sdrplayIFGain, "sdrSdrIFGain") } }
    @Published public var sdrplayAGC: Bool { didSet { save(sdrplayAGC, "sdrSdrAGC") } }
    @Published public var sdrplayBias: Bool { didSet { save(sdrplayBias, "sdrSdrBias") } }
    @Published public var sdrplayPPM: Int { didSet { save(sdrplayPPM, "sdrSdrPPM") } }
    @Published public var sdrplayRfNotch: Bool { didSet { save(sdrplayRfNotch, "sdrSdrRfNotch") } }
    @Published public var sdrplayDabNotch: Bool { didSet { save(sdrplayDabNotch, "sdrSdrDabNotch") } }
    /// Analoger ZF-Filter in kHz, 0 = automatisch nach der Abtastrate
    @Published public var sdrplayBandwidth: Int { didSet { save(sdrplayBandwidth, "sdrSdrBandwidth") } }

    /// Gehörte Frequenz (Dial) in Hz
    @Published public var frequencyHz: Double { didSet { save(frequencyHz, "sdrFrequency") } }
    @Published public var mode: SDRMode { didSet { save(mode.rawValue, "sdrMode") } }
    @Published public var bandwidthHz: Double { didSet { save(bandwidthHz, "sdrBandwidth") } }
    @Published public var squelchEnabled: Bool { didSet { save(squelchEnabled, "sdrSquelchOn") } }
    @Published public var squelchDB: Double { didSet { save(squelchDB, "sdrSquelchDB") } }
    @Published public var deemphasis: Bool { didSet { save(deemphasis, "sdrDeemphasis") } }
    @Published public var agc: Bool { didSet { save(agc, "sdrAGC") } }
    @Published public var afc: Bool { didSet { save(afc, "sdrAFC") } }
    /// UKW-Rundfunk: Stereo decodieren (aus: Mono)
    @Published public var wfmStereo: Bool { didSet { save(wfmStereo, "sdrWfmStereo") } }
    /// UKW-Rundfunk: De-Emphase 75 µs (Amerika, Japan) statt 50 µs (Europa)
    @Published public var wfmDeemphasis75: Bool { didSet { save(wfmDeemphasis75, "sdrWfmDeemph75") } }
    @Published public var cwPitchHz: Double { didSet { save(cwPitchHz, "sdrCwPitch") } }
    /// Schrittweite der Abstimmung in Hz
    @Published public var stepHz: Double { didSet { save(stepHz, "sdrStep") } }
    /// Mithören über den Lautsprecher
    @Published public var monitor: Bool { didSet { save(monitor, "sdrMonitor") } }
    @Published public var volume: Double { didSet { save(volume, "sdrVolume") } }
    /// Module (QSY AUTO) dürfen den Empfänger auf ihre Frequenz und Betriebsart stellen
    @Published public var followModules: Bool { didSet { save(followModules, "sdrFollow") } }
    /// Beim Programmstart den SDR-Empfänger als Quelle wählen
    @Published public var autoStart: Bool { didSet { save(autoStart, "sdrAutoStart") } }
    /// HF-Wasserfall statt des NF-Wasserfalls zeigen
    @Published public var showRFWaterfall: Bool { didSet { save(showRFWaterfall, "sdrShowRF") } }
    /// FFT-Auflösung des HF-Wasserfalls: Auto (folgt dem Zoom) oder feste Bins
    @Published public var waterfallResolution: SDRWaterfallResolution { didSet { save(waterfallResolution.rawValue, "sdrWaterfallResolution") } }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    public init() {
        let d = UserDefaults.standard
        let kind = d.string(forKey: "sdrSource").flatMap(ADSBSourceKind.init(rawValue:)) ?? .hackrf
        source = kind == .sdrconnect ? .hackrf : kind
        hackrfLNA = d.object(forKey: "sdrHackrfLNA") as? Int ?? 32
        hackrfVGA = d.object(forKey: "sdrHackrfVGA") as? Int ?? 30
        let savedRate = d.object(forKey: "sdrSampleRate") as? Int ?? Self.sampleRate
        sampleRateHz = Self.sampleRateChoices.contains(savedRate) || SDRplayPlan.sampleRates.contains(savedRate) ? savedRate : Self.sampleRate
        hackrfAmp = d.object(forKey: "sdrHackrfAmp") as? Bool ?? false
        hackrfBias = d.object(forKey: "sdrHackrfBias") as? Bool ?? false
        rtlGain = d.object(forKey: "sdrRtlGain") as? Double ?? 0
        rtlBias = d.object(forKey: "sdrRtlBias") as? Bool ?? false
        rtlPPM = d.object(forKey: "sdrRtlPPM") as? Int ?? 0
        sdrplayLNAState = d.object(forKey: "sdrSdrLNA") as? Int ?? 3
        sdrplayTuner = d.object(forKey: "sdrSdrTuner") as? Int ?? 0
        sdrplayIFGain = d.object(forKey: "sdrSdrIFGain") as? Int ?? 40
        sdrplayAGC = d.object(forKey: "sdrSdrAGC") as? Bool ?? true
        sdrplayBias = d.object(forKey: "sdrSdrBias") as? Bool ?? false
        sdrplayPPM = d.object(forKey: "sdrSdrPPM") as? Int ?? 0
        sdrplayRfNotch = d.object(forKey: "sdrSdrRfNotch") as? Bool ?? false
        sdrplayDabNotch = d.object(forKey: "sdrSdrDabNotch") as? Bool ?? false
        sdrplayBandwidth = d.object(forKey: "sdrSdrBandwidth") as? Int ?? 0
        frequencyHz = d.object(forKey: "sdrFrequency") as? Double ?? 145_500_000
        mode = d.string(forKey: "sdrMode").flatMap(SDRMode.init(rawValue:)) ?? .nfm
        bandwidthHz = d.object(forKey: "sdrBandwidth") as? Double ?? SDRMode.nfm.defaultBandwidthHz
        squelchEnabled = d.object(forKey: "sdrSquelchOn") as? Bool ?? false
        squelchDB = d.object(forKey: "sdrSquelchDB") as? Double ?? -50
        deemphasis = d.object(forKey: "sdrDeemphasis") as? Bool ?? false
        agc = d.object(forKey: "sdrAGC") as? Bool ?? true
        afc = d.object(forKey: "sdrAFC") as? Bool ?? true
        wfmStereo = d.object(forKey: "sdrWfmStereo") as? Bool ?? true
        wfmDeemphasis75 = d.object(forKey: "sdrWfmDeemph75") as? Bool ?? false
        cwPitchHz = d.object(forKey: "sdrCwPitch") as? Double ?? 700
        stepHz = d.object(forKey: "sdrStep") as? Double ?? 12_500
        monitor = d.object(forKey: "sdrMonitor") as? Bool ?? false
        volume = d.object(forKey: "sdrVolume") as? Double ?? 0.6
        followModules = d.object(forKey: "sdrFollow") as? Bool ?? true
        autoStart = d.object(forKey: "sdrAutoStart") as? Bool ?? false
        showRFWaterfall = d.object(forKey: "sdrShowRF") as? Bool ?? true
        let savedRes = d.string(forKey: "sdrWaterfallResolution").flatMap(SDRWaterfallResolution.init(rawValue:))
        waterfallResolution = savedRes ?? .auto
        // Bis 0.81 hörte der UKW-Empfänger mit höchstens 180 kHz; der Rundfunk braucht rund 230 kHz für Stereo und RDS
        if mode == .wfm, !d.bool(forKey: "sdrWfmBandwidthV2") {
            if bandwidthHz < 230_000 { bandwidthHz = 230_000; d.set(230_000.0, forKey: "sdrBandwidth") }
            d.set(true, forKey: "sdrWfmBandwidthV2")
        }
    }

    /// Tatsächliche Abtastrate: die gewählte, wenn das Gerät sie bietet (HackRF, SDRplay), sonst 2,4 MS/s
    public var effectiveSampleRate: Int { Self.sampleRateChoices(for: source).contains(sampleRateHz) ? sampleRateHz : Self.sampleRate }

    public var channelConfig: SDRChannelConfig {
        var c = SDRChannelConfig(mode: mode)
        c.bandwidthHz = bandwidthHz
        c.squelchEnabled = squelchEnabled
        c.squelchDB = squelchDB
        c.deemphasis = deemphasis
        c.agc = agc
        c.afc = afc
        c.cwPitchHz = cwPitchHz
        c.stereo = wfmStereo
        c.wfmDeemphasisSeconds = wfmDeemphasis75 ? 75e-6 : 50e-6
        return c
    }

    /// Gerätewerte; die Mitte kommt vom Controller
    public func gain(centerHz: Double) -> ADSBGainSettings {
        var g = ADSBGainSettings()
        g.centerFrequencyHz = centerHz
        g.sampleRateHz = effectiveSampleRate
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
        g.sdrplayRfNotch = sdrplayRfNotch
        g.sdrplayDabNotch = sdrplayDabNotch
        g.sdrplayBandwidthKHz = sdrplayBandwidth
        g.sdrplayFixedScale = true
        return g
    }

    /// Betriebsart wechseln und die Breite auf deren Vorgabe setzen
    public func select(mode new: SDRMode) {
        guard new != mode else { return }
        mode = new
        bandwidthHz = new.defaultBandwidthHz
        deemphasis = new == .wfm
        if new == .wfm { stepHz = 100_000 } else if stepHz == 100_000 { stepHz = new.isSSB ? 1_000 : 12_500 }
    }
}

// MARK: - Mithören

/// Das demodulierte Audio über den Standard-Ausgang hörbar machen (Stereo; Mono läuft auf beiden Kanälen)
public final class SDRSpeaker: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    /// Verschachtelt L, R: 0,5 s
    private let ring = FloatRingBuffer(capacity: 96_000)
    private let gain = OSAllocatedUnfairLock(initialState: Float(0.6))
    private let chunkFrames = 4096
    private let scratch: UnsafeMutablePointer<Float>
    private var duplicated: [Float] = []
    private var running = false

    public init() {
        scratch = .allocate(capacity: 2 * chunkFrames)
        scratch.initialize(repeating: 0, count: 2 * chunkFrames)
    }

    deinit { scratch.deallocate() }

    public var volume: Float {
        get { gain.withLock { $0 } }
        set { gain.withLock { $0 = max(0, min(1, newValue)) } }
    }

    public func start() {
        guard !running else { return }
        ring.clear()
        let ring = self.ring
        let gain = self.gain
        let scratch = self.scratch
        let chunk = chunkFrames
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let n = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            // Staut sich zu viel an (Takte von Gerät und Ausgang laufen auseinander): auf eine kurze Verzögerung zurück
            if ring.available > 28_800 {
                var skip = [Float](repeating: 0, count: ring.available - 9_600)
                _ = skip.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: $0.count) }
            }
            let g = gain.withLock { $0 }
            var done = 0
            let total = Int(frames)
            while done < total {
                let nFrames = min(chunk, total - done)
                let got = ring.read(into: scratch, maxCount: 2 * nFrames) / 2
                for k in 0..<got {
                    left[done + k] = scratch[2 * k] * g
                    right[done + k] = scratch[2 * k + 1] * g
                }
                if got < nFrames {
                    (left + done + got).update(repeating: 0, count: nFrames - got)
                    (right + done + got).update(repeating: 0, count: nFrames - got)
                }
                done += nFrames
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
        ring.clear()
    }

    /// Mono: auf beide Kanäle
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard running, !samples.isEmpty else { return }
        if duplicated.count < 2 * samples.count { duplicated = [Float](repeating: 0, count: 2 * samples.count) }
        for k in 0..<samples.count {
            duplicated[2 * k] = samples[k]
            duplicated[2 * k + 1] = samples[k]
        }
        duplicated.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 2 * samples.count) }
    }

    /// Verschachtelt L, R
    public func writeStereo(_ samples: UnsafeBufferPointer<Float>) {
        guard running, let base = samples.baseAddress, samples.count >= 2 else { return }
        ring.write(base, count: samples.count & ~1)
    }
}

// MARK: - Controller

@MainActor
public final class SDRController: ObservableObject {
    public let engine = SDRReceiverEngine(sampleRate: Double(SDRSettingsStore.sampleRate))
    /// Abtastrate des laufenden I/Q-Stroms
    public var sampleRateHz: Double { engine.sampleRate }
    public let speaker = SDRSpeaker()
    public let settings: SDRSettingsStore
    /// Kanalbank: mehrere Kanäle zugleich aus dem I/Q-Fenster (Modul KANÄLE)
    public let bank = SDRChannelBank()
    /// Audio-Ziel je Kanal der Bank (setzt der Programmzustand: die Pipeline des Decoders dieses Kanals)
    public var slotAudio: ((Int) -> SDRReceiverEngine.AudioHandler?)?
    @Published public private(set) var status = ADSBStatus.idle
    /// Mitte des I/Q-Fensters (Gerät) in Hz
    @Published public private(set) var loHz = 0.0
    @Published public private(set) var snapshot = SDRReceiverEngine.Snapshot()
    @Published public private(set) var tuneMessage: String?
    /// Quelle ist gewählt (Eingangswahl „SDR“)
    @Published public private(set) var isSelected = false
    /// Gerät ist abgegeben, weil ein Modul mit eigenem I/Q-Eingang es braucht (ADS-B, SENSOREN, VDL2, TETRA)
    @Published public private(set) var isSuspended = false

    /// Zustand für die Eingangswahl: läuft, Text, Warnung
    public var onStatus: ((Bool, String, Bool) -> Void)?
    /// Frequenz und Betriebsart als Funkgerät (für Module und Kopfzeile)
    public var onRigState: ((RigState?) -> Void)?
    /// Hat gerade ein Modul mit eigenem I/Q-Eingang das Gerät (dann bleibt der Empfänger zurück)?
    public var shouldYield: (() -> Bool)?
    /// Rückruf für unfiltriertes FM-Diskriminator-Audio bei 240 kS/s (z. B. für RDS)
    public var onDiscriminator: SDRReceiverEngine.DiscriminatorHandler? {
        didSet { engine.setDiscriminatorHandler(onDiscriminator) }
    }
    /// Aufnahme als Quelle (Entwicklung und Prüfung)
    public var fileOverride: URL?
    public var fileRealtime = true
    public var fileSampleRate = 2_400_000
    /// Mitte der Aufnahme in Hz (0 = so, dass die gehörte Frequenz 300 kHz neben der Mitte liegt)
    public var fileCenterHz = 0.0
    var sourceFactory: ((SDRSettingsStore, Double) -> ADSBIQSource?)?

    private let pipeline: AudioPipeline
    private var source: ADSBIQSource?
    private var sourceToken = UUID()
    private var startedGain: ADSBGainSettings?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastTunedFrequency = 0.0
    private var restartWork: DispatchWorkItem?
    private var retryCount = 0

    public init(pipeline: AudioPipeline, settings: SDRSettingsStore) {
        self.pipeline = pipeline
        self.settings = settings
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
        bank.onChange = { [weak self] in self?.bankChanged() }
        bank.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Auswahl und Betrieb

    /// Eingangswahl „SDR“: Gerät öffnen
    public func select() {
        isSelected = true
        // Läuft gerade ein Modul mit eigenem I/Q-Eingang, gehört ihm das Gerät: erst nach dem Verlassen des Moduls öffnen
        if shouldYield?() == true {
            isSuspended = true
            status = .idle
            onStatus?(false, "SDR-Empfänger pausiert: das Modul liest das Gerät selbst", false)
            return
        }
        isSuspended = false
        startSource()
    }

    /// Eingangswahl verlassen: Gerät freigeben
    public func deselect() {
        isSelected = false
        stopSource()
        status = .idle
        onRigState?(nil)
    }

    /// Ein Modul mit eigenem I/Q-Eingang braucht das Gerät
    public func suspend() {
        guard isSelected, !isSuspended else { return }
        isSuspended = true
        stopSource()
        status = .idle
        onStatus?(false, "SDR-Empfänger pausiert: das Modul liest das Gerät selbst", false)
        onRigState?(nil)
    }

    /// Das Modul mit eigenem I/Q-Eingang ist beendet: Gerät wieder öffnen
    public func resume() {
        guard isSelected, isSuspended else { return }
        isSuspended = false
        retryCount = 0
        startSource()
    }

    public func startSource() {
        stopSource()
        let f = settings.frequencyHz
        // Mitte: gehörte Frequenz 300 kHz neben der Mitte (dort liegt keine Gleichanteil-Spitze)
        var lo = f + SDRSettingsStore.loOffset(forRate: settings.effectiveSampleRate)
        var rate = Double(settings.effectiveSampleRate)
        let src: ADSBIQSource
        let usesFile = fileOverride != nil
        if usesFile {
            rate = Double(fileSampleRate)
            if fileCenterHz > 0 { lo = fileCenterHz }
        }
        if bank.isActive {
            let plan = bank.replan(sampleRate: Int(rate), currentLoHz: nil)
            if !plan.covered.isEmpty { lo = usesFile && fileCenterHz > 0 ? fileCenterHz : plan.loHz }
        }
        let gain = settings.gain(centerHz: lo)
        if let made = sourceFactory?(settings, lo) {
            src = made
        } else if let url = fileOverride {
            src = ADSBFileSource(url: url, realtime: fileRealtime, loop: true, sampleRate: fileSampleRate)
        } else {
            switch settings.source {
            case .hackrf: src = HackRFSource(settings: gain)
            case .rtlsdr: src = RTLSDRSource(settings: gain)
            case .sdrplay: src = SDRplayAPISource(settings: gain)
            case .sdrconnect, .file:
                fail("Quelle nicht verfügbar: HackRF, RTL-SDR oder SDRplay wählen")
                return
            }
        }
        let initialBins = settings.waterfallResolution.effectiveBins(sampleRate: rate, zoom: .x1)
        engine.configure(sampleRate: rate, bins: initialBins)
        engine.setChannel(settings.channelConfig)
        engine.setOffset(f - lo)
        loHz = lo
        lastTunedFrequency = f
        pushBank()
        let engine = self.engine
        let wait = usesFile && !fileRealtime
        let token = UUID()
        sourceToken = token
        let pipeline = self.pipeline
        let speaker = self.speaker
        pipeline.sourceChannels = 1
        pipeline.start(inputRate: SDRDemodulator.audioRate)
        engine.setAudioHandler { buf in
            if let base = buf.baseAddress { pipeline.ring.write(base, count: buf.count) }
        }
        engine.setStereoHandler { buf in speaker.writeStereo(buf) }
        do {
            try src.start(onData: { engine.feed($0, wait: wait) }, onStop: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sourceStopped(reason, token: token) } }
            })
            source = src
            startedGain = gain
            status = .running(src.deviceDescription)
            retryCount = 0
            publishStatus()
            publishRig()
            applySpeaker()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Das Gerät wird nach einem Moduswechsel manchmal erst verspätet frei (RTL-SDR schließt asynchron): ein paar Versuche
            if isSelected, retryCount < 3, !usesFile {
                retryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    MainActor.assumeIsolated { if let self, self.isSelected, !self.isSuspended, self.source == nil { self.startSource() } }
                }
                return
            }
            fail(message)
        }
    }

    private func fail(_ message: String) {
        status = .error(message)
        onStatus?(false, message, true)
        onRigState?(nil)
        pipeline.stop()
    }

    public func stopSource() {
        sourceToken = UUID()
        restartWork?.cancel()
        source?.stop()
        source = nil
        startedGain = nil
        engine.setAudioHandler(nil)
        engine.setStereoHandler(nil)
        engine.removeAllExtraChannels()
        engine.setPrimaryEnabled(true)
        speaker.stop()
        pipeline.stop()
    }

    private func sourceStopped(_ reason: String?, token: UUID) {
        guard token == sourceToken, source != nil else { return }
        source = nil
        if let reason {
            fail(reason)
        } else {
            status = .idle
            onStatus?(false, "SDR-Empfänger angehalten", false)
        }
    }

    private func publishStatus() {
        if case .running(let name) = status {
            onStatus?(true, "SDR · \(name) · \(String(format: "%.1f", Double(settings.effectiveSampleRate) / 1e6).replacingOccurrences(of: ".", with: ",")) MS/s", false)
        }
    }

    // MARK: Abstimmung

    /// Frequenz und Betriebsart nach den Einstellungen anwenden
    private func settingsChanged() {
        engine.setChannel(settings.channelConfig)
        applySpeaker()
        if isSelected, source != nil {
            if settings.frequencyHz != lastTunedFrequency && !bank.isActive { applyFrequency() }
            publishRig()
            // Verstärkung des Geräts geändert: neu öffnen
            if let started = startedGain, started != settings.gain(centerHz: started.centerFrequencyHz) {
                restartWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { if let self, self.isSelected, !self.isSuspended { self.startSource() } }
                }
                restartWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
    }

    private func applySpeaker() {
        speaker.volume = Float(settings.volume)
        let wanted = bank.isActive ? bank.monitorID != nil : settings.monitor
        if wanted && source != nil { speaker.start() } else { speaker.stop() }
    }

    /// Gehörte Frequenz geändert: im Fenster nur den Mischer verschieben, sonst das Gerät umstimmen
    private func applyFrequency() {
        let f = settings.frequencyHz
        lastTunedFrequency = f
        var offset = f - loHz
        let outside = abs(offset) > SDRSettingsStore.window(forRate: settings.effectiveSampleRate) || abs(offset) < SDRSettingsStore.dcGuard(forRate: settings.effectiveSampleRate)
        if outside {
            let target = f + SDRSettingsStore.loOffset(forRate: settings.effectiveSampleRate)
            if let tunable = source as? SDRTunableSource {
                if tunable.retune(centerHz: target) {
                    loHz = target
                    offset = f - target
                    tuneMessage = nil
                } else {
                    tuneMessage = "Frequenz \(Self.format(f)) nicht einstellbar (außerhalb des Bereichs des Geräts)"
                    return
                }
            } else if fileOverride == nil {
                // Aufnahme: die Mitte steht fest
                tuneMessage = nil
            }
        } else {
            tuneMessage = nil
        }
        engine.setOffset(offset)
        publishRig()
    }

    public func tune(frequencyHz f: Double) {
        settings.frequencyHz = max(1_000, min(6_000_000_000, f.rounded()))
    }

    public func step(_ direction: Int, multiplier: Double = 1) {
        tune(frequencyHz: settings.frequencyHz + Double(direction) * settings.stepHz * multiplier)
    }

    /// Abstimmziel eines Moduls (QSY AUTO): Dial, Betriebsart und Breite
    @discardableResult
    public func tune(to target: RigTuneTarget) -> RigTuneResult {
        guard source != nil || isSelected else { return .notConnected }
        guard let mode = SDRMode(hamlib: target.mode) else { return .rejected("Betriebsart \(target.mode) kennt der SDR-Empfänger nicht") }
        if mode != settings.mode { settings.select(mode: mode) }
        let bw: Double? = target.passbandHz.flatMap { $0 > 0 ? Double($0) : nil }
        settings.bandwidthHz = bw.map { min(max($0, mode.bandwidthChoices.first ?? 0), mode.bandwidthChoices.last ?? $0) } ?? mode.defaultBandwidthHz
        // Digitalverfahren: die Deemphase gehört nicht ins Signal
        if mode != .wfm { settings.deemphasis = false }
        settings.frequencyHz = Double(target.dialHz)
        return .ok
    }

    static func format(_ hz: Double) -> String {
        String(format: "%.4f MHz", hz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Messwerte und Funkgerät

    private func poll() {
        guard isSelected, source != nil else { return }
        snapshot = engine.snapshot()
        if bank.isActive { bank.setLevels(engine.extraChannelMetrics().mapValues(\.signalDB)) }
    }

    // MARK: Kanalbank

    /// Kanäle geändert oder die Bank ein- bzw. ausgeschaltet: Gerätemitte neu planen, Kanäle an die Engine geben
    private func bankChanged() {
        objectWillChange.send()
        guard isSelected, !isSuspended else { return }
        guard source != nil else { return }
        if !bank.isActive {
            // Bank beendet: der Hörkanal braucht wieder ein Fenster um seine Frequenz
            applyFrequency()
        } else {
            let plan = bank.replan(sampleRate: Int(engine.sampleRate), currentLoHz: loHz)
            defer { publishRig() }
            if !plan.covered.isEmpty, abs(plan.loHz - loHz) > 1 {
                if let tunable = source as? SDRTunableSource {
                    if tunable.retune(centerHz: plan.loHz) {
                        loHz = plan.loHz
                        tuneMessage = nil
                    } else {
                        tuneMessage = "Mitte \(Self.format(plan.loHz)) nicht einstellbar"
                    }
                }
            }
        }
        pushBank()
    }

    /// Kanäle der Bank in die Engine übernehmen: je Kanal Abstand von der Gerätemitte, Betriebsart und Audio-Ziel
    private func pushBank() {
        guard bank.isActive else {
            engine.removeAllExtraChannels()
            engine.setPrimaryEnabled(true)
            return
        }
        engine.setPrimaryEnabled(false)
        let plan = bank.plan
        let speaker = self.speaker
        let monitor = bank.monitorID
        for slot in bank.slots {
            if slot.enabled, plan.covered.contains(slot.id) {
                let sink = slotAudio?(slot.id)
                var handler = sink
                if slot.id == monitor {
                    handler = { @Sendable buf in sink?(buf); speaker.write(buf) }
                }
                engine.setExtraChannel(id: slot.id, config: slot.channelConfig, offsetHz: slot.frequencyHz - loHz, handler: handler)
            } else {
                engine.removeExtraChannel(id: slot.id)
            }
        }
        applySpeaker()
    }

    private func publishRig() {
        guard isSelected, source != nil else { return }
        var s = RigState()
        s.connected = true
        // Kanalbank: das Gerät steht auf der Mitte des Fensters
        s.frequencyHz = Int((bank.isActive ? loHz : settings.frequencyHz).rounded())
        s.mode = bank.isActive ? "FM" : settings.mode.hamlibName
        s.passbandHz = bank.isActive ? Int(engine.sampleRate) : Int(settings.bandwidthHz.rounded())
        onRigState?(s)
    }

    public var rigName: String {
        if case .running(let name) = status { return "SDR \(name)" }
        return "SDR"
    }
}
