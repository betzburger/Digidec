// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import os

// MARK: - Brücke zwischen Empfangsfäden und Web-Server

/// Zustand, den Empfangs- und Audiofäden lesen dürfen (ohne den Hauptakteur): letzte Spektrumzeile des SDR und Schalter für den Audio-Abzweig
final class WebBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var row: [Float] = []
    private var rowSerial = 0
    private var takenSerial = 0

    /// Glättung des Rauschteppichs der HF-Zeilen (wie in der App: unteres Fünftel, langsam nachgeführt)
    var rfFloorDB: Float = -90
    var rfFloorValid = false

    /// Liefert der SDR-Empfänger das Audio (sonst der Audio-Eingang)? Stereo nur bei UKW-Rundfunk mit Stereo.
    let sdrAudio = OSAllocatedUnfairLock(initialState: false)
    let sdrStereo = OSAllocatedUnfairLock(initialState: false)
    /// Kennung der Pipeline-Senke je Web-Audio-Abzweig
    var rawSinkIDs: [UUID: UUID] = [:]

    func push(row new: [Float]) {
        lock.lock(); row = new; rowSerial &+= 1; lock.unlock()
    }

    /// Neueste Zeile, falls seit dem letzten Abruf eine neue kam
    func takeRow() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard rowSerial != takenSerial else { return nil }
        takenSerial = rowSerial
        return row
    }

    func clearRows() {
        lock.lock(); row = []; takenSerial = rowSerial; lock.unlock()
        rfFloorValid = false
    }
}

/// Stereo auf Mono für Betriebsarten ohne Stereo (halbe Datenmenge zum Browser)
private final class WebMonoScratch: @unchecked Sendable {
    var samples: [Float] = []
}

// MARK: - WebHostDelegate

extension DigidecState: WebHostDelegate {
    public var activeModuleId: String { activeModule.id }

    // MARK: Quelle, Frequenz, Betriebsart

    /// Das Modul liest das Gerät selbst (ADS-B, Sensoren, VDL2, TETRA, DAB): kein NF-Wasserfall, keine Abstimmung
    private var webOwnsDevice: Bool { activeModule.usesOwnIQDevice }

    /// Der eingebaute SDR-Empfänger liefert das Signal des Moduls
    private var webUsesSDR: Bool { audio.sourceKind == .sdr && !webOwnsDevice && activeModule != .channels }

    /// Feste Frequenz eines Moduls mit eigenem I/Q-Eingang
    private var webOwnDeviceFrequencyHz: Double {
        switch activeModule {
        case .adsb:    return 1_090_000_000
        case .sensors: return sensors.band.frequencyHz
        case .dab:     return dab.block.frequencyHz
        case .vdl2:    return vdl2.centerFrequency
        case .tetra:   return tetra.centerFrequency
        default:       return 0
        }
    }

    public var dialFrequencyHz: Int {
        if webOwnsDevice { return Int(webOwnDeviceFrequencyHz.rounded()) }
        if webUsesSDR { return Int(sdr.frequencyHz.rounded()) }
        if let f = rig.state.frequencyHz, f > 0 { return f }
        return Int(rigTargetForActiveModule?.dialHz ?? 0)
    }

    public var activeModeString: String {
        if webOwnsDevice { return "I/Q" }
        if webUsesSDR { return sdr.mode.hamlibName }
        if let m = rig.state.mode, !m.isEmpty { return m }
        return rigTargetForActiveModule?.mode ?? "—"
    }

    public var connectedRigName: String {
        if webOwnsDevice || webUsesSDR { return "SDR \((webOwnSource ?? sdr.source).title)" }
        return rig.rigName ?? "Kein Funkgerät"
    }

    public var webSourceLabel: String {
        if webOwnsDevice {
            return "I/Q · \((webOwnSource ?? sdr.source).title)"
        }
        switch audio.sourceKind {
        case .sdr:   return "SDR · \(sdr.source.title)"
        case .file:  return "Datei"
        case .audio: return "Audio-Eingang"
        }
    }

    public var webModeChoices: [String] {
        if webOwnsDevice { return [] }
        if webUsesSDR { return SDRMode.allCases.map(\.hamlibName) }
        if rig.hasRig, rig.state.frequencyHz != nil { return ["USB", "LSB", "CW", "AM", "FM"] }
        return []
    }

    public var webFrequencyEditable: Bool {
        if webOwnsDevice { return false }
        if webUsesSDR { return true }
        return rig.hasRig && rig.state.frequencyHz != nil
    }

    public func setMode(_ mode: String) {
        guard !webOwnsDevice else { return }
        if webUsesSDR {
            if let m = SDRMode(hamlib: mode) {
                sdr.select(mode: m)
                if m != .wfm { sdr.deemphasis = false }
            }
        } else if rig.hasRig, let f = rig.state.frequencyHz, f > 0, webModeChoices.contains(mode) {
            rig.tune(to: RigTuneTarget(dialHz: Int64(f), mode: mode))
        }
    }

    public func setFrequency(hz: Double) {
        guard hz.isFinite, hz > 0, !webOwnsDevice else { return }
        if webUsesSDR {
            sdrController.tune(frequencyHz: hz)
        } else if rig.hasRig, rig.state.frequencyHz != nil {
            rig.tune(to: RigTuneTarget(dialHz: Int64(max(100_000, hz.rounded())), mode: rig.state.mode ?? "USB"))
        }
    }

    public func tuneOffset(hz: Double) {
        guard !webOwnsDevice else { return }
        if webUsesSDR {
            sdrController.tune(frequencyHz: sdr.frequencyHz + hz)
        } else if let cur = rig.state.frequencyHz {
            let newHz = max(100_000, Int64(cur) + Int64(hz))
            rig.tune(to: RigTuneTarget(dialHz: newHz, mode: rig.state.mode ?? "USB"))
        }
    }

    public func selectModule(id: String) {
        if let mod = DecoderModuleInfo.allCases.first(where: { $0.id == id && $0 != .channels }) {
            select(module: mod)
        }
    }

    // MARK: SDR-Steuerung

    public var isSDREnabled: Bool { audio.sourceKind == .sdr }

    /// Gerät, das das Modul mit eigenem I/Q-Eingang liest (jedes dieser Module hat seine eigene Geräte-Einstellung)
    private var webOwnSource: ADSBSourceKind? {
        switch activeModule {
        case .adsb: return adsbController.settings.source
        case .dab: return dab.source
        case .vdl2: return vdl2.source
        case .sensors: return sensors.source
        case .tetra: return tetra.source
        default: return nil
        }
    }

    public var sdrSourceKind: String { (webOwnSource ?? sdr.source).rawValue }

    public var sdrSampleRate: Int { sdr.effectiveSampleRate }

    public var sdrLNA: Int { sdr.source == .hackrf ? sdr.hackrfLNA : sdr.sdrplayLNAState }

    public var sdrVGA: Int { sdr.hackrfVGA }

    public var sdrStatusMessage: String {
        if let name = webOwnModuleStatus {
            return name
        }
        if audio.sourceKind == .sdr {
            switch sdrController.status {
            case .idle: return sdrController.isSuspended ? "SDR pausiert: das Modul liest das Gerät selbst" : "SDR bereit (\(sdr.source.title))"
            case .running(let d): return "SDR aktiv (\(d))"
            case .error(let msg): return "SDR Fehler: \(msg)"
            }
        }
        return audio.statusText
    }

    /// Zustandszeile des Moduls mit eigenem I/Q-Gerät
    private var webOwnModuleStatus: String? {
        func text(_ name: String, _ st: ADSBStatus, _ source: ADSBSourceKind) -> String {
            switch st {
            case .idle: return "\(name) bereit (\(source.title))"
            case .running(let d): return "\(name) aktiv (\(d))"
            case .error(let msg): return "\(name) Fehler: \(msg)"
            }
        }
        switch activeModule {
        case .adsb: return text("ADS-B", adsbController.status, adsbController.settings.source)
        case .dab: return text("DAB", dabController.status, dab.source)
        case .vdl2: return text("VDL2", vdl2Controller.status, vdl2.source)
        case .sensors: return text("SENSOREN", sensorsController.status, sensors.source)
        case .tetra: return text("TETRA", tetraController.status, tetra.source)
        default: return nil
        }
    }

    public var isRFWaterfall: Bool { webRFActive }

    public func setSDREnabled(_ enabled: Bool) {
        if enabled { audio.selectSDR() } else { audio.switchToAudio() }
    }

    public func setSDRSource(kind: String) {
        guard let s = ADSBSourceKind(rawValue: kind) else { return }
        switch activeModule {
        case .adsb: adsbController.settings.source = s; adsbController.startSource()
        case .dab: dab.source = s
        case .vdl2: vdl2.source = s
        case .sensors: sensors.source = s
        case .tetra: tetra.source = s
        default:
            sdr.source = s
            if audio.sourceKind == .sdr { sdrController.startSource() }
        }
    }

    public func setSDRGain(lna: Int?, vga: Int?) {
        if let lna {
            if sdr.source == .hackrf { sdr.hackrfLNA = max(0, min(40, lna)) }
            else if sdr.source == .sdrplay { sdr.sdrplayLNAState = max(0, min(9, lna)) }
        }
        if let vga { sdr.hackrfVGA = max(0, min(62, vga)) }
    }

    public func setWaterfallMode(rf: Bool) {
        sdr.showRFWaterfall = rf
        webBridge.clearRows()
    }

    // MARK: Wasserfall

    /// HF-Wasserfall des SDR-Empfängers statt des NF-Wasserfalls
    private var webRFActive: Bool { webUsesSDR && sdr.showRFWaterfall }

    /// Abstimmziel des NF-Wasserfalls (Mitte, Töne) je Modul wie in der Wasserfallansicht der App; nil = Modul ohne NF-Wasserfall
    private var webTuning: (any TuningTarget)? {
        switch activeModule {
        case .navtex: return navtex
        case .cw: return cw
        case .olivia: return olivia
        case .mt63: return mt63
        case .mfsk: return mfsk
        case .hell: return hell
        case .dsc: return dsc
        case .ale: return ale
        case .aprs: return aprs
        case .rds: return rds
        case .packet: return packet
        case .acars: return acars
        case .ais: return ais
        case .dstar: return dstar
        case .ysf: return ysf
        case .dmr: return dmr
        case .dpmr: return dpmr
        case .nxdn: return nxdn
        case .p25: return p25
        case .m17: return m17
        case .freedv: return freedv
        case .drm: return drm
        case .hfdl: return hfdl
        case .sonde: return sonde
        case .pager: return pager
        case .tones: return tones
        case .psk: return psk
        case .skimmer: return skimmer
        case .wefax: return wefax
        case .ft8: return ft8
        case .ft4: return ft4
        case .ft2: return ft2
        case .wspr: return wspr
        case .js8: return js8
        case .ndb: return ndb
        case .dcf77: return dcf77
        case .efr: return efr
        case .sstv: return sstv
        case .rtty: return rtty
        case .adsb, .sensors, .tetra, .dab, .vdl2, .vor, .channels: return nil
        }
    }

    private var webSDRZoom: SDRZoomFactor {
        SDRZoomFactor(rawValue: UserDefaults.standard.integer(forKey: "sdrZoomFactor")) ?? .x1
    }

    private var webSDRRangeDB: Float {
        let v = UserDefaults.standard.float(forKey: "sdrRangeDB")
        return (20...90).contains(v) ? v : 55
    }

    public var webWaterfallInfo: WebWaterfallInfo {
        var w = WebWaterfallInfo()
        if webOwnsDevice || activeModule == .channels {
            w.kind = .none
            w.title = "EMPFANG"
            w.note = "I/Q DIREKT VOM GERÄT · KEIN NF-WASSERFALL"
            return w
        }
        if webRFActive {
            let rate = Double(sdr.effectiveSampleRate)
            let lo = sdrController.loHz
            let zoom = webSDRZoom
            w.kind = .rf
            w.title = String(format: "HF-WASSERFALL · %@ · %.1f MS/s", sdr.source.title, rate / 1e6).replacingOccurrences(of: ".", with: ",")
            w.fullLo = lo - rate / 2
            w.fullHi = lo + rate / 2
            let vis = zoom.visibleRange(center: sdr.frequencyHz, sampleRate: rate, loHz: lo)
            w.visLo = vis.lowerBound
            w.visHi = vis.upperBound
            w.centerHz = sdr.frequencyHz
            w.bandwidthHz = sdr.bandwidthHz
            // Durchlassbereich wie in der App: USB nur oberhalb, LSB nur unterhalb der Frequenz, sonst um die Frequenz
            let f = sdr.frequencyHz, bw = sdr.bandwidthHz
            switch sdr.mode {
            case .usb: w.bandLo = f + 100; w.bandHi = f + 100 + bw
            case .lsb: w.bandLo = f - 100 - bw; w.bandHi = f - 100
            default: w.bandLo = f - bw / 2; w.bandHi = f + bw / 2
            }
            w.markerStyle = "dial"
            w.markerText = SDRFormat.frequency(sdr.frequencyHz) + " MHz " + sdr.mode.title
            w.zoom = Double(zoom.rawValue)
            w.zoomChoices = SDRZoomFactor.allCases.map { .init(label: $0.label, value: Double($0.rawValue)) }
            w.rangeDB = Int(webSDRRangeDB)
            w.tunable = true
            if case .running = sdrController.status {} else {
                switch sdrController.status {
                case .error(let m): w.note = m
                default: w.note = sdrController.isSuspended ? "SDR PAUSIERT: DAS MODUL LIEST DAS GERÄT SELBST" : "SDR-EMPFÄNGER STARTET …"
                }
            }
            return w
        }
        w.kind = .af
        w.title = "NF-WASSERFALL"
        w.fullLo = 0
        w.fullHi = waterfall.nyquist
        let tuning = webTuning
        let center = tuning?.centerHz ?? 1000
        let vis = waterfall.visibleRange(center: center)
        w.visLo = vis.lowerBound
        w.visHi = vis.upperBound
        w.centerHz = center
        w.zoom = waterfall.span.rawValue
        w.zoomChoices = WaterfallModel.Span.allCases.map { .init(label: $0.label, value: $0.rawValue) }
        w.rangeDB = Int(waterfall.rangeDB)
        w.tunable = tuning != nil
        if !audio.isRunning { w.note = "KEIN EINGANGSSIGNAL" }
        if let tuning {
            w.bandwidthHz = tuning.markerBandwidth
            switch tuning.markerStyle {
            case .tones:
                w.markerStyle = "tones"
                w.markHz = tuning.tones.mark
                w.spaceHz = tuning.tones.space
                w.markerText = "MITTE \(Int(tuning.centerHz.rounded())) Hz"
            case .band(let text):
                w.markerStyle = "band"
                w.markerText = text
            case .none(let text):
                w.markerStyle = "none"
                w.markerText = text
            case .channels(let marks):
                w.markerStyle = "channels"
                w.channels = marks.map { .init(frequency: $0.frequency, label: $0.label, selected: $0.selected, active: $0.active) }
                w.markerText = "SKIMMER · \(marks.count) " + (marks.count == 1 ? "Signal" : "Signale")
            }
        }
        return w
    }

    public var waterfallRowData: Data? {
        if webRFActive {
            guard let row = webBridge.takeRow(), row.count > 16 else { return nil }
            let rate = Double(sdr.effectiveSampleRate)
            let lo = sdrController.loHz
            let fullLo = lo - rate / 2
            let zoom = webSDRZoom
            let vis = zoom.visibleRange(center: sdr.frequencyHz, sampleRate: rate, loHz: lo)
            // Nur den sichtbaren Bereich mit Rand senden: bei starkem Zoom sind das wenige Bytes statt aller Bins
            let span = vis.upperBound - vis.lowerBound
            let margin = zoom == .x1 ? 0 : span / 2
            let cropLo = max(fullLo, vis.lowerBound - margin)
            let cropHi = min(fullLo + rate, vis.upperBound + margin)
            let binHz = rate / Double(row.count)
            let first = max(0, min(row.count - 1, Int(((cropLo - fullLo) / binHz).rounded(.down))))
            let last = max(first + 1, min(row.count, Int(((cropHi - fullLo) / binHz).rounded(.up))))
            // Rauschteppich: unteres Fünftel der Werte, langsam nachgeführt (wie die App)
            let sorted = row.sorted()
            let floor = sorted[sorted.count / 5]
            webBridge.rfFloorDB += (floor - webBridge.rfFloorDB) * (webBridge.rfFloorValid ? 0.05 : 1)
            webBridge.rfFloorValid = true
            let lowDB = webBridge.rfFloorDB - 6
            let range = webSDRRangeDB
            var frame = Data(capacity: 10 + last - first)
            Self.appendRowHeader(&frame, kind: 1, lo: fullLo + Double(first) * binHz, hi: fullLo + Double(last) * binHz)
            for i in first..<last {
                frame.append(UInt8(WaterfallColorMap.index(db: row[i], floorDB: lowDB, rangeDB: range)))
            }
            return frame
        }
        let snap = waterfall.processor.snapshot()
        let spec = snap.spectrum.isEmpty ? waterfall.spectrum : snap.spectrum
        guard !spec.isEmpty else { return nil }
        var frame = Data(capacity: 10 + spec.count)
        Self.appendRowHeader(&frame, kind: 0, lo: 0, hi: waterfall.nyquist)
        // Rauschen etwas über Schwarz wie in der App
        let floorDB = waterfall.noiseFloor - 8
        let rangeDB = waterfall.rangeDB
        for db in spec {
            frame.append(UInt8(WaterfallColorMap.index(db: db, floorDB: floorDB, rangeDB: rangeDB)))
        }
        return frame
    }

    /// Zeile: [0x01] [0 = NF, 1 = HF] [unterste Frequenz Float32 LE] [oberste Frequenz Float32 LE] [Farbindizes]
    private static func appendRowHeader(_ data: inout Data, kind: UInt8, lo: Double, hi: Double) {
        data.append(0x01)
        data.append(kind)
        for v in [Float(lo), Float(hi)] {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
    }

    public func setCenter(hz: Double) {
        guard hz.isFinite else { return }
        if webRFActive {
            let step = sdr.stepHz >= 1000 ? sdr.stepHz : 100
            sdrController.tune(frequencyHz: (hz / step).rounded() * step)
        } else if let t = webTuning {
            t.setCenter(hz)
        }
    }

    public func setRFZoom(_ zoom: Int) {
        guard let z = SDRZoomFactor(rawValue: zoom), webRFActive else { return }
        UserDefaults.standard.set(z.rawValue, forKey: "sdrZoomFactor")
        sdrController.engine.setSpectrumBins(sdr.waterfallResolution.effectiveBins(sampleRate: Double(sdr.effectiveSampleRate), zoom: z))
        webBridge.clearRows()
    }

    public func setNFSpan(_ hz: Double) {
        if let s = WaterfallModel.Span(rawValue: hz) { waterfall.span = s }
    }

    public func setWaterfallRange(delta: Int) {
        if webRFActive {
            let v = max(20, min(90, webSDRRangeDB + Float(delta)))
            UserDefaults.standard.set(v, forKey: "sdrRangeDB")
        } else {
            waterfall.rangeDB = max(20, min(90, waterfall.rangeDB + Float(delta)))
        }
    }

    // MARK: Audio

    public func addWebAudio(_ sink: @escaping WebAudioSink) -> UUID {
        let id = UUID()
        let bridge = webBridge
        // Audio-Eingang (Funkgerät, Mikrofon, Datei): so wie er ankommt, einkanalig
        let rawID = audio.pipeline.addRawSink { block, rate in
            if bridge.sdrAudio.withLock({ $0 }) { return }
            sink(block, Int(rate.rounded()), 1)
        }
        bridge.rawSinkIDs[id] = rawID
        // SDR: Stereo-Audio des Hörkanals mit 48 kS/s, unabhängig vom Lautsprecher; ohne Stereo-Betrieb einkanalig
        let scratch = WebMonoScratch()
        sdrController.webAudioTap.set { buffer in
            guard bridge.sdrAudio.withLock({ $0 }) else { return }
            if bridge.sdrStereo.withLock({ $0 }) {
                sink(buffer, 48_000, 2)
            } else {
                let n = buffer.count / 2
                if scratch.samples.count < n { scratch.samples = [Float](repeating: 0, count: n) }
                for i in 0..<n { scratch.samples[i] = buffer[2 * i] }
                scratch.samples.withUnsafeBufferPointer { sink(UnsafeBufferPointer(rebasing: $0[0..<n]), 48_000, 1) }
            }
        }
        // DAB: der decodierte Ton (Mono oder Stereo, meist 48 kHz) kommt nicht über die Pipeline
        dabController.engine.player.webTap.set { buffer, rate, channels in sink(buffer, rate, channels) }
        refreshWebAudioFlags()
        return id
    }

    public func removeWebAudio(_ id: UUID) {
        if let raw = webBridge.rawSinkIDs.removeValue(forKey: id) { audio.pipeline.removeSink(raw) }
        sdrController.webAudioTap.set(nil)
        dabController.engine.player.webTap.set(nil)
    }

    /// Schalter für die Fäden aus dem Zustand nachführen (Quelle, Betriebsart)
    func refreshWebAudioFlags() {
        let fromSDR = audio.sourceKind == .sdr
        let stereo = sdr.mode == .wfm && sdr.wfmStereo
        webBridge.sdrAudio.withLock { $0 = fromSDR }
        webBridge.sdrStereo.withLock { $0 = stereo }
    }

    /// Einmal beim Start: Spektrumzeilen abgreifen und Schalter für das Audio nachführen
    func installWebBridge() {
        let bridge = webBridge
        sdrController.engine.setSpectrumTap { row in bridge.push(row: row) }
        refreshWebAudioFlags()
        audio.$sourceKind
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshWebAudioFlags() }
            .store(in: &cancellables)
        sdr.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshWebAudioFlags() }
            .store(in: &cancellables)
    }
}
