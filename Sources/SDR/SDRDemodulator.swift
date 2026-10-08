// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// Eingebauter SDR-Empfänger, Rechenkern: 8-Bit-I/Q → Mischer → Dezimierung auf 240 kS/s → je Betriebsart Kanalfilter und Demodulator → Audio (48 kHz, Mono).
// Reine Rechenlogik ohne Gerät und Oberfläche, damit sie sich mit Testsignalen prüfen lässt (Tools/SDRBench, Logiktests).

public enum SDRMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case wfm, nfm, am, usb, lsb, cw, cwr

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wfm: return "WFM"
        case .nfm: return "FM"
        case .am: return "AM"
        case .usb: return "USB"
        case .lsb: return "LSB"
        case .cw: return "CW"
        case .cwr: return "CWR"
        }
    }

    /// Name im Hamlib-Protokoll (so schicken die Module ihre Abstimmziele)
    public var hamlibName: String {
        switch self {
        case .wfm: return "WFM"
        case .nfm: return "FM"
        case .am: return "AM"
        case .usb: return "USB"
        case .lsb: return "LSB"
        case .cw: return "CW"
        case .cwr: return "CWR"
        }
    }

    /// Betriebsart zu einem Hamlib-Namen. RTTY und Paketbetrieb laufen wie im Funkgerät in der Seitenband-Lage ihres Namens
    /// (RTTY = Kehrlage wie LSB, PKTUSB = USB).
    public init?(hamlib name: String) {
        switch name.uppercased() {
        case "WFM": self = .wfm
        case "FM", "NFM": self = .nfm
        case "AM": self = .am
        case "USB", "PKTUSB", "RTTYR": self = .usb
        case "LSB", "PKTLSB", "RTTY": self = .lsb
        case "CW", "CWU": self = .cw
        case "CWR", "CWL": self = .cwr
        default: return nil
        }
    }

    public var isSSB: Bool { self == .usb || self == .lsb || self == .cw || self == .cwr }

    /// Vorgabe der Kanal- bzw. Durchlassbreite in Hz
    public var defaultBandwidthHz: Double {
        switch self {
        case .wfm: return 230_000
        case .nfm: return 15_000
        case .am: return 10_000
        case .usb, .lsb: return 3_000
        case .cw, .cwr: return 500
        }
    }

    /// Wählbare Breiten (Hz) in der Oberfläche
    public var bandwidthChoices: [Double] {
        switch self {
        case .wfm: return [150_000, 180_000, 200_000, 230_000, 256_000]
        case .nfm: return [8_000, 12_500, 25_000, 40_000]
        case .am: return [6_000, 10_000, 15_000]
        case .usb, .lsb: return [2_400, 3_000, 4_000, 5_000]
        case .cw, .cwr: return [250, 500, 1_000, 2_000]
        }
    }
}

/// Einstellungen des gerade gehörten Kanals
public struct SDRChannelConfig: Equatable, Sendable {
    public var mode: SDRMode = .nfm
    /// Kanalbreite (FM, AM) bzw. Durchlassbreite (SSB, CW) in Hz
    public var bandwidthHz: Double = SDRMode.nfm.defaultBandwidthHz
    public var cwPitchHz = 700.0
    /// Untere Grenze des SSB-Durchlassbereichs (Hz); der obere Rand ist `ssbLowCutHz + bandwidthHz`
    public var ssbLowCutHz = 100.0
    public var squelchEnabled = false
    /// Schwelle der Kanalleistung in dB zur Vollaussteuerung (−120 … 0)
    public var squelchDB = -60.0
    /// De-Emphase für Rundfunk (50 µs) und, falls gewählt, Sprache über FM (75 µs); aus für digitale Verfahren
    public var deemphasis = false
    /// Zeitkonstante der De-Emphase im UKW-Rundfunk: 50 µs (Europa) oder 75 µs (Amerika, Japan)
    public var wfmDeemphasisSeconds = 50e-6
    /// UKW-Stereo decodieren (aus: immer Mono)
    public var stereo = true
    /// Verstärkungsregelung für SSB und CW
    public var agc = true
    /// Gleichanteil des FM-Demodulators nachführen (Frequenzablage des Senders)
    public var afc = true

    public init() {}

    public init(mode: SDRMode) {
        self.mode = mode
        bandwidthHz = mode.defaultBandwidthHz
        deemphasis = mode == .wfm
    }
}

/// Messwerte des Empfängers
public struct SDRMetrics: Equatable, Sendable {
    /// Kanalleistung in dB zur Vollaussteuerung (geglättet)
    public var signalDB = -120.0
    public var squelchOpen = true
    /// UKW: Stereo-Pilot gefunden und Schleife eingerastet
    public var stereoLocked = false
    /// UKW: Pilot als Hub in kHz (nominal 6,75)
    public var pilotKHz = 0.0
    /// UKW: Anteil des Differenzsignals im Ausgang (0 = Mono, 1 = Stereo)
    public var stereoBlend = 0.0
    /// UKW: Rauschen im Stereo-Differenzsignal (Effektivwert, 1,0 = 75 kHz Hub)
    public var stereoNoise = 0.0
}

public final class SDRDemodulator {
    public static let audioRate = 48_000.0
    static let channelRate = 240_000.0
    /// UKW-Rundfunk rechnet mit 480 kS/s: die 57-kHz-Hilfsträger des Multiplexsignals (RDS) brauchen die Bandbreite
    static let wfmRate = 480_000.0
    static let ssbRate = 12_000.0

    public let sampleRate: Double
    public private(set) var config: SDRChannelConfig
    public private(set) var metrics = SDRMetrics()

    // Eingang
    private var mixer: SDRMixer
    private var tunedOffset = 0.0
    private var mixI: [Float] = [], mixQ: [Float] = []
    // Dezimierung auf 240 kS/s
    private var stage5: ComplexStreamFIR?
    private var stage2: ComplexStreamFIR?
    private var stageOne: ComplexRateConverter?
    private var s1I: [Float] = [], s1Q: [Float] = []
    private var cI: [Float] = [], cQ: [Float] = []
    // Kanal
    private var wfmFilter: ComplexStreamFIR?
    private let stereoDecoder = WFMStereoDecoder()
    private var monoBuf: [Float] = [], stereoBuf: [Float] = []
    private var deemphL: Float = 0, deemphR: Float = 0
    private var toAudioConv: ComplexRateConverter?
    private var toSSBConv: ComplexRateConverter?
    private var chanFilter: ComplexStreamFIR?
    private var bpRI: StreamFIR?, bpIQ: StreamFIR?, bpII: StreamFIR?, bpRQ: StreamFIR?
    private var ssbToAudio: SampleRateConverter?
    private var aI: [Float] = [], aQ: [Float] = [], fI: [Float] = [], fQ: [Float] = []
    private var t1: [Float] = [], t2: [Float] = [], t3: [Float] = [], t4: [Float] = []
    private var dem: [Float] = []
    // Demodulator-Zustand
    private var prevI: Float = 1, prevQ: Float = 0
    private var dcTracker: Float = 0
    private var carrier: Float = 0.1
    private var agcEnv: Float = 0.01
    private var deemphState: Float = 0
    private var squelchIsOpen = true
    private var powerAvg = 1e-12

    /// Verschachtelte Stereo-Abtastwerte (L, R, 48 kS/s), wenn `produceStereo` gesetzt ist; der Aufrufer leert die Liste
    public var stereoOut: [Float] = []
    public var produceStereo = false

    /// Optionaler Rückruf für das Multiplexsignal des UKW-Rundfunks (Diskriminator-Ausgang bei 480 kS/s, 1,0 = 75 kHz Hub), z. B. für RDS
    public var onDiscriminator: (@Sendable (UnsafeBufferPointer<Float>, Double) -> Void)?

    public init(sampleRate: Double, config: SDRChannelConfig = SDRChannelConfig()) {
        self.sampleRate = sampleRate
        self.config = config
        mixer = SDRMixer(sampleRate: sampleRate)
        buildFrontEnd()
        buildChannel()
    }

    // MARK: Einstellungen

    /// Abstand des gehörten Signals von der Mitte des I/Q-Fensters in Hz (gehört − Mitte)
    public func setOffset(_ hz: Double) {
        tunedOffset = hz
        applyOffset()
    }

    public var offsetHz: Double { tunedOffset }

    /// CW: die angezeigte Frequenz ist der Träger; er soll als Ton in Höhe des CW-Tons hörbar sein, also wird um den Ton versetzt gemischt
    private func applyOffset() {
        switch config.mode {
        case .cw: mixer.setOffset(tunedOffset - config.cwPitchHz)
        case .cwr: mixer.setOffset(tunedOffset + config.cwPitchHz)
        default: mixer.setOffset(tunedOffset)
        }
    }

    public func configure(_ new: SDRChannelConfig) {
        let old = config
        config = new
        stereoDecoder.stereoEnabled = new.stereo
        if (old.mode == .wfm) != (new.mode == .wfm) { buildFrontEnd() }
        if old.mode != new.mode || old.bandwidthHz != new.bandwidthHz || old.cwPitchHz != new.cwPitchHz || old.ssbLowCutHz != new.ssbLowCutHz {
            buildChannel()
        }
        applyOffset()
    }

    // MARK: Aufbau

    private func buildFrontEnd() {
        stage5 = nil; stage2 = nil; stageOne = nil
        let ratio = sampleRate / 480_000
        // Abtastraten, die kein ganzes Vielfaches von 480 kS/s sind (HackRF mit 20 MS/s): erst ganzzahlig auf etwa 1 MS/s, dann der Wandler
        if sampleRate > 3_000_000, abs(ratio - ratio.rounded()) > 1e-9 {
            let d = Int(sampleRate / 960_000)
            let mid = sampleRate / Double(d)
            stage5 = ComplexStreamFIR(taps: SDRFilterDesign.lowpass(passband: 130_000 / sampleRate, stopband: (mid - 300_000) / sampleRate, attenuationDB: 60), decimation: d)
            stageOne = ComplexRateConverter(inputRate: mid, outputRate: config.mode == .wfm ? Self.wfmRate : Self.channelRate)
            return
        }
        if config.mode == .wfm {
            // Rundfunk: nur bis 480 kS/s, die weitere Verarbeitung hat die Bandbreite für das ganze Multiplexsignal
            if ratio >= 1, abs(ratio - ratio.rounded()) < 1e-9 {
                if ratio >= 2 {
                    stage5 = ComplexStreamFIR(taps: SDRFilterDesign.lowpass(passband: 130_000 / sampleRate, stopband: 350_000 / sampleRate, attenuationDB: 60), decimation: Int(ratio.rounded()))
                }
            } else {
                stageOne = ComplexRateConverter(inputRate: sampleRate, outputRate: Self.wfmRate)
            }
            return
        }
        if ratio >= 2, abs(ratio - ratio.rounded()) < 1e-9 {
            // ganzzahlig auf 480 kS/s (2,4 MS/s: /5; 4,8 MS/s: /10; 9,6 MS/s: /20), dann /2 auf 240 kS/s
            stage5 = ComplexStreamFIR(taps: SDRFilterDesign.lowpass(passband: 105_000 / sampleRate, stopband: 370_000 / sampleRate, attenuationDB: 60), decimation: Int(ratio.rounded()))
            stage2 = ComplexStreamFIR(taps: SDRFilterDesign.lowpass(passband: 105_000 / 480_000, stopband: 130_000 / 480_000, attenuationDB: 60), decimation: 2)
        } else if sampleRate != Self.channelRate {
            stageOne = ComplexRateConverter(inputRate: sampleRate, outputRate: Self.channelRate)
        }
    }

    private func buildChannel() {
        let c = config
        wfmFilter = nil; toAudioConv = nil; toSSBConv = nil; chanFilter = nil
        bpRI = nil; bpIQ = nil; bpII = nil; bpRQ = nil; ssbToAudio = nil
        prevI = 1; prevQ = 0
        switch c.mode {
        case .wfm:
            // Kanalfilter bei 480 kS/s: Durchlass bis zur halben Kanalbreite, Flanke 55 kHz; 230 kHz erfassen den ganzen Hub samt Hilfsträgern
            let half = min(max(c.bandwidthHz / 2, 40_000), 150_000)
            let stop = min(half + 55_000, 232_000)
            wfmFilter = ComplexStreamFIR(taps: SDRFilterDesign.lowpass(passband: half / Self.wfmRate, stopband: stop / Self.wfmRate, attenuationDB: 60))
            stereoDecoder.reset()
            stereoDecoder.stereoEnabled = c.stereo
            deemphL = 0; deemphR = 0
        case .nfm, .am:
            toAudioConv = ComplexRateConverter(inputRate: Self.channelRate, outputRate: Self.audioRate)
            let half = min(c.bandwidthHz / 2, 21_000)
            let transition = max(1_500, half * 0.35)
            chanFilter = ComplexStreamFIR(taps: SDRFilterDesign.lowpass(passband: half / Self.audioRate, stopband: min(half + transition, 23_500) / Self.audioRate, attenuationDB: 55))
        case .usb, .lsb, .cw, .cwr:
            toSSBConv = ComplexRateConverter(inputRate: Self.channelRate, outputRate: Self.ssbRate)
            ssbToAudio = SampleRateConverter(inputRate: Self.ssbRate, outputRate: Self.audioRate)
            let center: Double, half: Double
            switch c.mode {
            case .usb: half = c.bandwidthHz / 2; center = c.ssbLowCutHz + half
            case .lsb: half = c.bandwidthHz / 2; center = -(c.ssbLowCutHz + half)
            case .cw: half = c.bandwidthHz / 2; center = c.cwPitchHz
            default: half = c.bandwidthHz / 2; center = -c.cwPitchHz
            }
            let transition = max(80, min(300, c.bandwidthHz * 0.15))
            let bp = SDRFilterDesign.complexBandpass(halfWidth: half / Self.ssbRate, transition: transition / Self.ssbRate, center: center / Self.ssbRate, attenuationDB: 55, maximum: 1501)
            bpRI = StreamFIR(taps: bp.re); bpIQ = StreamFIR(taps: bp.im)
            bpII = StreamFIR(taps: bp.im); bpRQ = StreamFIR(taps: bp.re)
        }
        dcTracker = 0
    }

    // MARK: Verarbeitung

    /// Rohdaten verarbeiten und das entstandene Audio (48 kHz) an `audio` anhängen
    public func process(_ bytes: UnsafeBufferPointer<UInt8>, audio: inout [Float]) {
        let pairs = bytes.count / 2
        var start = 0
        let chunk = 65_536
        while start < pairs {
            let n = min(chunk, pairs - start)
            let slice = UnsafeBufferPointer(rebasing: bytes[(2 * start)..<(2 * (start + n))])
            processChunk(slice, pairs: n, audio: &audio)
            start += n
        }
    }

    private func processChunk(_ bytes: UnsafeBufferPointer<UInt8>, pairs n: Int, audio: inout [Float]) {
        mixer.mix(bytes, pairs: n, i: &mixI, q: &mixQ)
        // auf 240 kS/s
        if let s5 = stage5 {
            s5.process(i: mixI, q: mixQ, outI: &s1I, outQ: &s1Q)
            if let s2 = stage2 {
                s2.process(i: s1I, q: s1Q, outI: &cI, outQ: &cQ)
            } else if let conv = stageOne {
                conv.process(i: s1I, q: s1Q, outI: &cI, outQ: &cQ)
            } else {
                cI = s1I; cQ = s1Q
            }
        } else if let conv = stageOne {
            conv.process(i: mixI, q: mixQ, outI: &cI, outQ: &cQ)
        } else {
            cI = mixI; cQ = mixQ
        }
        guard !cI.isEmpty else { return }

        switch config.mode {
        case .wfm: demodulateWFM(audio: &audio)
        case .nfm, .am: demodulateNarrow(audio: &audio)
        case .usb, .lsb, .cw, .cwr: demodulateSSB(audio: &audio)
        }
    }

    /// Leistung eines Blocks (I² + Q²) in dB, geglättet; Squelch mit 2 dB Hysterese
    private func updateMeter(i: [Float], q: [Float], rate: Double) {
        guard !i.isEmpty else { return }
        var pi: Float = 0, pq: Float = 0
        vDSP_svesq(i, 1, &pi, vDSP_Length(i.count))
        vDSP_svesq(q, 1, &pq, vDSP_Length(q.count))
        let p = Double(pi + pq) / Double(i.count)
        let blockSeconds = Double(i.count) / rate
        let alpha = min(1, blockSeconds / 0.1)
        powerAvg += (p - powerAvg) * alpha
        let db = 10 * log10(max(powerAvg, 1e-12))
        metrics.signalDB = db
        if config.squelchEnabled {
            squelchIsOpen = squelchIsOpen ? db > config.squelchDB - 2 : db > config.squelchDB
        } else {
            squelchIsOpen = true
        }
        metrics.squelchOpen = squelchIsOpen
    }

    @inline(__always) private func clamp(_ x: Float, _ limit: Float) -> Float { max(-limit, min(limit, x)) }

    // Rundfunk-FM: Kanalfilter und Diskriminator bei 480 kS/s, Stereodecoder, De-Emphase
    private func demodulateWFM(audio: inout [Float]) {
        guard let filt = wfmFilter else { return }
        filt.process(i: cI, q: cQ, outI: &fI, outQ: &fQ)
        let n = fI.count
        guard n > 0, fQ.count == n else { return }
        updateMeter(i: fI, q: fQ, rate: Self.wfmRate)
        if dem.count != n { dem = [Float](repeating: 0, count: n) }
        let scale = Float(Self.wfmRate / (2 * Double.pi) / 75_000)
        var pi = prevI, pq = prevQ
        for k in 0..<n {
            let re = fI[k] * pi + fQ[k] * pq
            let im = fQ[k] * pi - fI[k] * pq
            dem[k] = atan2f(im, re) * scale
            pi = fI[k]; pq = fQ[k]
        }
        prevI = pi; prevQ = pq
        dem.withUnsafeBufferPointer { b in
            onDiscriminator?(b, Self.wfmRate)
        }
        monoBuf.removeAll(keepingCapacity: true)
        stereoBuf.removeAll(keepingCapacity: true)
        dem.withUnsafeBufferPointer { stereoDecoder.process(mpx: $0, mono: &monoBuf, stereo: &stereoBuf, wantStereo: produceStereo) }
        let st = stereoDecoder.status
        metrics.stereoLocked = st.locked && config.stereo
        metrics.pilotKHz = st.pilotKHz
        metrics.stereoBlend = st.blend
        metrics.stereoNoise = st.noiseRMS
        if config.deemphasis {
            let tau = config.wfmDeemphasisSeconds
            applyDeemphasis(&monoBuf, tau: tau)
            if produceStereo {
                let a = Float(1 - exp(-1 / (tau * Self.audioRate)))
                var l = deemphL, r = deemphR
                var k = 0
                while k + 1 < stereoBuf.count {
                    l += (stereoBuf[k] - l) * a
                    r += (stereoBuf[k + 1] - r) * a
                    stereoBuf[k] = l; stereoBuf[k + 1] = r
                    k += 2
                }
                deemphL = l; deemphR = r
            }
        }
        if squelchIsOpen {
            audio.append(contentsOf: monoBuf)
            if produceStereo { stereoOut.append(contentsOf: stereoBuf) }
        } else {
            audio.append(contentsOf: [Float](repeating: 0, count: monoBuf.count))
            if produceStereo { stereoOut.append(contentsOf: [Float](repeating: 0, count: stereoBuf.count)) }
        }
    }

    // FM und AM schmalbandig: auf 48 kS/s, Kanalfilter, Demodulator
    private func demodulateNarrow(audio: inout [Float]) {
        guard let conv = toAudioConv, let filt = chanFilter else { return }
        conv.process(i: cI, q: cQ, outI: &aI, outQ: &aQ)
        guard !aI.isEmpty else { return }
        filt.process(i: aI, q: aQ, outI: &fI, outQ: &fQ)
        guard !fI.isEmpty else { return }
        updateMeter(i: fI, q: fQ, rate: Self.audioRate)
        let n = fI.count
        var out = [Float](repeating: 0, count: n)
        if config.mode == .nfm {
            let scale = Float(Self.audioRate / (2 * Double.pi) / 5_000)
            var pi = prevI, pq = prevQ
            let alpha = Float(1.0 / (1.0 * Self.audioRate))                       // Gleichanteil: Zeitkonstante 1 s
            var dc = dcTracker
            for k in 0..<n {
                let re = fI[k] * pi + fQ[k] * pq
                let im = fQ[k] * pi - fI[k] * pq
                var x = atan2f(im, re) * scale
                pi = fI[k]; pq = fQ[k]
                if config.afc {
                    dc += (x - dc) * alpha
                    x -= dc
                }
                out[k] = clamp(x, 4)
            }
            prevI = pi; prevQ = pq; dcTracker = dc
            if config.deemphasis { applyDeemphasis(&out, tau: 75e-6) }
        } else {
            var c = carrier
            let alpha = Float(1.0 / (0.3 * Self.audioRate))
            for k in 0..<n {
                let env = (fI[k] * fI[k] + fQ[k] * fQ[k]).squareRoot()
                c += (env - c) * alpha
                out[k] = clamp(env / max(c, 0.003) - 1, 2)
            }
            carrier = c
        }
        appendOutput(out, to: &audio)
    }

    // SSB und CW: auf 12 kS/s, komplexer Bandpass, Realteil, Verstärkungsregelung, zurück auf 48 kS/s
    private func demodulateSSB(audio: inout [Float]) {
        guard let conv = toSSBConv, let a = bpRI, let b = bpIQ, let c = bpII, let d = bpRQ, let up = ssbToAudio else { return }
        conv.process(i: cI, q: cQ, outI: &aI, outQ: &aQ)
        guard !aI.isEmpty else { return }
        a.process(aI, into: &t1)      // I * hr
        b.process(aQ, into: &t2)      // Q * hi
        c.process(aI, into: &t3)      // I * hi
        d.process(aQ, into: &t4)      // Q * hr
        let n = t1.count
        guard n > 0 else { return }
        var yr = [Float](repeating: 0, count: n), yi = [Float](repeating: 0, count: n)
        vDSP_vsub(t2, 1, t1, 1, &yr, 1, vDSP_Length(n))      // yr = I*hr − Q*hi
        vDSP_vadd(t3, 1, t4, 1, &yi, 1, vDSP_Length(n))      // yi = I*hi + Q*hr
        // Kanalleistung aus dem gefilterten komplexen Signal
        var ps: Float = 0, pt: Float = 0
        vDSP_svesq(yr, 1, &ps, vDSP_Length(n))
        vDSP_svesq(yi, 1, &pt, vDSP_Length(n))
        let p = Double(ps + pt) / Double(n)
        let blockSeconds = Double(n) / Self.ssbRate
        powerAvg += (p - powerAvg) * min(1, blockSeconds / 0.1)
        let db = 10 * log10(max(powerAvg, 1e-12))
        metrics.signalDB = db
        squelchIsOpen = config.squelchEnabled ? (squelchIsOpen ? db > config.squelchDB - 2 : db > config.squelchDB) : true
        metrics.squelchOpen = squelchIsOpen
        // Verstärkungsregelung: schneller Anstieg (5 ms), langsamer Abfall (400 ms)
        if config.agc {
            let attack = Float(1 - exp(-1 / (0.005 * Self.ssbRate)))
            let decay = Float(1 - exp(-1 / (0.4 * Self.ssbRate)))
            var env = agcEnv
            for k in 0..<n {
                let m = (yr[k] * yr[k] + yi[k] * yi[k]).squareRoot()
                env += (m - env) * (m > env ? attack : decay)
                yr[k] *= 0.25 / max(env, 0.0003)
            }
            agcEnv = env
        } else {
            for k in 0..<n { yr[k] *= 10 }
        }
        var a48 = [Float]()
        yr.withUnsafeBufferPointer { b in up.process(b) { a48.append(contentsOf: $0) } }
        for k in a48.indices { a48[k] = clamp(a48[k], 1) }
        appendOutput(a48, to: &audio)
    }

    private func applyDeemphasis(_ x: inout [Float], tau: Double) {
        let a = Float(1 - exp(-1 / (tau * Self.audioRate)))
        var s = deemphState
        for k in x.indices {
            s += (x[k] - s) * a
            x[k] = s
        }
        deemphState = s
    }

    private func appendOutput(_ x: [Float], to audio: inout [Float]) {
        let out = squelchIsOpen ? x : [Float](repeating: 0, count: x.count)
        audio.append(contentsOf: out)
        if produceStereo {
            stereoOut.reserveCapacity(stereoOut.count + 2 * out.count)
            for v in out { stereoOut.append(v); stereoOut.append(v) }
        }
    }
}
