// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI

// VDL Mode 2 (136,725 … 136,975 MHz): Modul. Digidec liest die I/Q-Daten (2 MS/s) selbst vom Gerät, wie bei ADS-B und den
// Funksensoren, demoduliert alle gewählten Kanäle gleichzeitig (D8PSK, 10 500 Bd) und zeigt Flugzeuge, Bodenstationen und Nachrichten.

// MARK: - Kanäle

public enum VDL2Channels {
    /// Übliche VDL-Mode-2-Frequenzen (MHz) weltweit; 136,975 ist der gemeinsame Signalisierungskanal
    public static let all: [Double] = [136.650, 136.700, 136.725, 136.750, 136.775, 136.800, 136.825, 136.850, 136.875, 136.900, 136.925, 136.950, 136.975]
    public static let europe: [Double] = [136.725, 136.775, 136.825, 136.875, 136.925, 136.975]
    public static let defaultSelection = europe

    public static func hz(_ mhz: Double) -> Double { (mhz * 1e6).rounded() }

    /// Mitte des Empfangsfensters: Mitte zwischen höchstem und niedrigstem Kanal, auf 25 kHz gerundet
    public static func center(of selection: [Double]) -> Double {
        guard let lo = selection.min(), let hi = selection.max() else { return hz(136.850) }
        return (hz((lo + hi) / 2) / 25_000).rounded() * 25_000
    }

    public static func title(_ hz: Double) -> String { String(format: "%.3f", hz / 1e6).replacingOccurrences(of: ".", with: ",") }
}

// MARK: - Einstellungen

@MainActor
public final class VDL2SettingsStore: ObservableObject {
    @Published public var source: ADSBSourceKind { didSet { UserDefaults.standard.set(source.rawValue, forKey: "vdlSource") } }
    /// Gewählte Kanäle in MHz
    @Published public var channels: [Double] { didSet { UserDefaults.standard.set(channels, forKey: "vdlChannels") } }
    @Published public var hackrfLNA: Int { didSet { UserDefaults.standard.set(hackrfLNA, forKey: "vdlHackrfLNA") } }
    @Published public var hackrfVGA: Int { didSet { UserDefaults.standard.set(hackrfVGA, forKey: "vdlHackrfVGA") } }
    @Published public var hackrfAmp: Bool { didSet { UserDefaults.standard.set(hackrfAmp, forKey: "vdlHackrfAmp") } }
    @Published public var hackrfBias: Bool { didSet { UserDefaults.standard.set(hackrfBias, forKey: "vdlHackrfBias") } }
    @Published public var rtlGain: Double { didSet { UserDefaults.standard.set(rtlGain, forKey: "vdlRtlGain") } }
    @Published public var rtlBias: Bool { didSet { UserDefaults.standard.set(rtlBias, forKey: "vdlRtlBias") } }
    @Published public var rtlPPM: Int { didSet { UserDefaults.standard.set(rtlPPM, forKey: "vdlRtlPPM") } }
    @Published public var sdrconnectHost: String { didSet { UserDefaults.standard.set(sdrconnectHost, forKey: "vdlSdrHost") } }
    @Published public var sdrconnectPort: Int { didSet { UserDefaults.standard.set(sdrconnectPort, forKey: "vdlSdrPort") } }
    @Published public var sdrplayLNAState: Int { didSet { UserDefaults.standard.set(sdrplayLNAState, forKey: "vdlSdrLNA") } }
    @Published public var sdrplayTuner: Int { didSet { UserDefaults.standard.set(sdrplayTuner, forKey: "vdlSdrTuner") } }
    @Published public var sdrplayIFGain: Int { didSet { UserDefaults.standard.set(sdrplayIFGain, forKey: "vdlSdrIFGain") } }
    @Published public var sdrplayAGC: Bool { didSet { UserDefaults.standard.set(sdrplayAGC, forKey: "vdlSdrAGC") } }
    @Published public var sdrplayBias: Bool { didSet { UserDefaults.standard.set(sdrplayBias, forKey: "vdlSdrBias") } }
    @Published public var sdrplayPPM: Int { didSet { UserDefaults.standard.set(sdrplayPPM, forKey: "vdlSdrPPM") } }
    @Published public var sdrplayRfNotch: Bool { didSet { UserDefaults.standard.set(sdrplayRfNotch, forKey: "vdlSdrRfNotch") } }
    @Published public var sdrplayDabNotch: Bool { didSet { UserDefaults.standard.set(sdrplayDabNotch, forKey: "vdlSdrDabNotch") } }
    /// Flugzeuge nach dieser Zeit ohne Meldung aus der Liste nehmen (Minuten, 0 = nie)
    @Published public var expireMinutes: Int { didSet { UserDefaults.standard.set(expireMinutes, forKey: "vdlExpireMinutes") } }

    public init() {
        let d = UserDefaults.standard
        source = d.string(forKey: "vdlSource").flatMap(ADSBSourceKind.init(rawValue:)) ?? .rtlsdr
        let saved = (d.array(forKey: "vdlChannels") as? [Double]) ?? []
        channels = saved.isEmpty ? VDL2Channels.defaultSelection : saved
        hackrfLNA = d.object(forKey: "vdlHackrfLNA") as? Int ?? 32
        hackrfVGA = d.object(forKey: "vdlHackrfVGA") as? Int ?? 30
        hackrfAmp = d.object(forKey: "vdlHackrfAmp") as? Bool ?? false
        hackrfBias = d.object(forKey: "vdlHackrfBias") as? Bool ?? false
        rtlGain = d.object(forKey: "vdlRtlGain") as? Double ?? 40
        rtlBias = d.object(forKey: "vdlRtlBias") as? Bool ?? false
        rtlPPM = d.object(forKey: "vdlRtlPPM") as? Int ?? 0
        sdrconnectHost = d.string(forKey: "vdlSdrHost") ?? "127.0.0.1"
        sdrconnectPort = d.object(forKey: "vdlSdrPort") as? Int ?? 5454
        sdrplayLNAState = d.object(forKey: "vdlSdrLNA") as? Int ?? 0
        sdrplayTuner = d.object(forKey: "vdlSdrTuner") as? Int ?? 0
        sdrplayIFGain = d.object(forKey: "vdlSdrIFGain") as? Int ?? 40
        sdrplayAGC = d.object(forKey: "vdlSdrAGC") as? Bool ?? true
        sdrplayBias = d.object(forKey: "vdlSdrBias") as? Bool ?? false
        sdrplayPPM = d.object(forKey: "vdlSdrPPM") as? Int ?? 0
        sdrplayRfNotch = d.object(forKey: "vdlSdrRfNotch") as? Bool ?? false
        sdrplayDabNotch = d.object(forKey: "vdlSdrDabNotch") as? Bool ?? false
        expireMinutes = d.object(forKey: "vdlExpireMinutes") as? Int ?? 30
    }

    public var channelFrequencies: [Double] { channels.sorted().map(VDL2Channels.hz) }
    public var centerFrequency: Double { VDL2Channels.center(of: channels) }

    public func toggle(_ mhz: Double) {
        if let i = channels.firstIndex(of: mhz) {
            if channels.count > 1 { channels.remove(at: i) }
        } else {
            channels.append(mhz)
        }
    }

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
        g.sdrplayRfNotch = sdrplayRfNotch
        g.sdrplayDabNotch = sdrplayDabNotch
        return g
    }
}

// MARK: - Aufnahmen

/// Aufnahme als I/Q-Quelle: WAV (8 oder 16 Bit, stereo), `.cu8` oder `.cs16` (roh); wird auf 8 Bit vorzeichenlos gebracht
public final class VDL2FileSource: ADSBIQSource, @unchecked Sendable {
    public let url: URL
    private let realtime: Bool
    public private(set) var sampleRate: Int
    private let lock = NSLock()
    private var running = false

    public init(url: URL, realtime: Bool, sampleRate: Int? = nil) {
        self.url = url
        self.realtime = realtime
        self.sampleRate = sampleRate ?? VDL2FileSource.sampleRate(of: url) ?? 1_050_000
    }

    public var deviceDescription: String { url.lastPathComponent }

    /// Abtastrate aus dem Dateinamen („…_1050kHz.wav“, „…_2M.cu8“) oder aus dem WAV-Kopf (ab 105 kS/s)
    public static func sampleRate(of url: URL) -> Int? {
        let name = url.lastPathComponent
        if let r = name.range(of: #"(\d+(?:\.\d+)?)\s*(?:kHz|kS|k)(?=[._\W]|$)"#, options: .regularExpression) {
            let digits = name[r].prefix { $0.isNumber || $0 == "." }
            if let k = Double(digits), k >= 105 { return Int(k * 1000) }
        }
        if let r = name.range(of: #"(\d+(?:\.\d+)?)M(?=[._\W]|$)"#, options: .regularExpression) {
            let digits = name[r].prefix { $0.isNumber || $0 == "." }
            if let m = Double(digits) { return Int(m * 1_000_000) }
        }
        if url.pathExtension.lowercased() == "wav", let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: 44), d.count == 44 {
                let rate = Int(d[24]) | Int(d[25]) << 8 | Int(d[26]) << 16 | Int(d[27]) << 24
                if rate >= 105_000 { return rate }
            }
        }
        return nil
    }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44 else {
            throw ADSBSourceError.failed("Datei nicht lesbar: \(url.lastPathComponent)")
        }
        let ext = url.pathExtension.lowercased()
        var offset = 0
        var bytesPerSample = 1
        if ext == "wav" {
            // Nach dem Abschnitt „data“ suchen; Bitbreite aus „fmt “
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
        lock.withLock { running = true }
        let t = Thread { [self] in
            let frames = 32_768                                     // I/Q-Paare je Block
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
                            let v = Int16(bitPattern: UInt16(base[pos + 2 * k]) | UInt16(base[pos + 2 * k + 1]) << 8)
                            out[k] = UInt8(max(0, min(255, (Int(v) + 128 + 32768) >> 8)))
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
        t.name = "vdl2-file"
        t.start()
    }

    public func stop() { lock.withLock { running = false } }
}

// MARK: - Engine

/// Verarbeitet die I/Q-Daten auf einem eigenen Faden: Je Kanal Mischen, Filtern, Demodulation, Decodierung (Kanäle parallel)
public final class VDL2Engine: @unchecked Sendable {
    public struct ChannelInfo: Sendable, Equatable {
        public var frequency: Double
        public var powerDB: Double
        public var noiseDB: Double
        public var statistics: VDL2Statistics
    }

    public struct Snapshot: Sendable {
        public var bursts: [VDL2Burst] = []
        public var channels: [ChannelInfo] = []
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var droppedBlocks = 0
        public var sampleRate = 0
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.vdl2", qos: .userInitiated)
    private let lock = NSLock()
    private var channels: [VDL2Channel] = []
    private var sampleRate = 2_000_000
    private var levels = [Float](repeating: 0, count: 256)
    private var iBuf: [Float] = [], qBuf: [Float] = []
    private var pendingBytes = 0
    private var droppedBlocks = 0
    private var bursts: [VDL2Burst] = []
    private var activity = 0.0
    private var clipped = 0, total = 0
    static let maxPending = 8 * 1024 * 1024
    /// Aufnahmen (ein Kanal in der Mitte) und Geräte unterscheiden sich in der Zählung übersteuerter Werte
    private var countClipping = true

    public init() {
        for i in 0..<256 { levels[i] = (Float(i) - 127.5) / 127.5 }
    }

    /// - Parameters:
    ///   - frequencies: Kanalfrequenzen (Hz); bei einer Aufnahme mit nur einem Kanal in der Mitte ist `centerFrequency` gleich der Kanalfrequenz
    public func configure(sampleRate: Int, centerFrequency: Double, frequencies: [Double], countClipping: Bool) {
        queue.async { [self] in
            self.sampleRate = sampleRate
            self.countClipping = countClipping
            channels = frequencies.map { f in
                let ch = VDL2Channel(frequency: f, centerFrequency: centerFrequency, sampleRate: Double(sampleRate))
                ch.onBurst = { [weak self] b in self?.lock.withLock { self?.bursts.append(b) } }
                return ch
            }
        }
    }

    public func reset() {
        queue.async { [self] in
            for c in channels { c.reset() }
            lock.withLock { bursts.removeAll(); droppedBlocks = 0 }
        }
    }

    /// Neue I/Q-Daten (vom Faden der Quelle): kopieren und weitergeben, bei Rückstau verwerfen
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
        let n = data.count / 2
        guard n > 0, !channels.isEmpty else { return }
        if iBuf.count < n { iBuf = [Float](repeating: 0, count: n); qBuf = [Float](repeating: 0, count: n) }
        var sum = 0, clip = 0
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            levels.withUnsafeBufferPointer { lv in
                iBuf.withUnsafeMutableBufferPointer { ip in
                    qBuf.withUnsafeMutableBufferPointer { qp in
                        for k in 0..<n {
                            let a = b[2 * k], c = b[2 * k + 1]
                            ip[k] = lv[Int(a)]; qp[k] = lv[Int(c)]
                            if k & 3 == 0 {
                                sum += abs(Int(a) - 128)
                                if a == 0 || a == 255 { clip += 1 }
                            }
                        }
                    }
                }
            }
        }
        let counted = max(1, (n + 3) / 4)
        lock.withLock {
            activity += (Double(sum) / Double(counted) - activity) * 0.2
            if countClipping { clipped += clip; total += counted }
        }
        let chans = channels
        iBuf.withUnsafeBufferPointer { ip in
            qBuf.withUnsafeBufferPointer { qp in
                nonisolated(unsafe) let i = UnsafeBufferPointer(rebasing: ip[0..<n])
                nonisolated(unsafe) let q = UnsafeBufferPointer(rebasing: qp[0..<n])
                if chans.count == 1 {
                    chans[0].process(i: i, q: q)
                } else {
                    DispatchQueue.concurrentPerform(iterations: chans.count) { chans[$0].process(i: i, q: q) }
                }
            }
        }
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot()
        queue.sync { [self] in
            s.sampleRate = sampleRate
            s.channels = channels.map { ChannelInfo(frequency: $0.frequency, powerDB: $0.powerDB, noiseDB: $0.noiseDB, statistics: $0.statistics) }
        }
        lock.withLock {
            s.bursts = bursts
            bursts.removeAll()
            s.activity = activity
            s.clippedFraction = total > 0 ? Double(clipped) / Double(total) : 0
            s.droppedBlocks = droppedBlocks
        }
        return s
    }
}

// MARK: - Auswertung der Rahmen

public struct VDL2Aircraft: Identifiable, Equatable, Sendable {
    public var id: String { address.text }
    public var address: VDL2Address
    public var registration: String?
    public var flight: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var frames = 0
    public var acarsMessages = 0
    public var groundStation: String?
    public var frequency: Double
    public var levelDB: Double
    public var lastText: String
    /// Flugzeug in der Luft (Zustand der Zieladresse im Aufwärtsrahmen) oder am Boden
    public var onGround: Bool?
}

public struct VDL2GroundStation: Identifiable, Equatable, Sendable {
    public var id: String { address.text }
    public var address: VDL2Address
    public var frames = 0
    public var lastSeen: Date
    public var frequencies: Set<Double>
}

public struct VDL2LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var frame: AVLCFrame
    public var summary: String
}

public enum VDL2Format {
    /// Druckbarer Auszug der Nutzdaten (Steuerzeichen als Punkt)
    public static func printable(_ bytes: [UInt8], limit: Int = 200) -> String {
        String(bytes.prefix(limit).map { b -> Character in b >= 0x20 && b < 0x7F ? Character(UnicodeScalar(b)) : (b == 0x0A || b == 0x0D ? " " : ".") })
    }

    public static func summary(_ f: AVLCFrame) -> String {
        switch f.kind {
        case .supervisory:
            return f.command
        case .unnumbered:
            return f.payload.isEmpty ? f.command : "\(f.command) · \(f.payload.count) Byte"
        case .information:
            if let a = f.acars {
                var s = "ACARS \(a.registration.isEmpty ? "-" : a.registration) \(a.label)"
                if let n = a.flightID, !n.isEmpty { s += " \(n)" }
                let t = a.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { s += " · " + t }
                return s
            }
            return "Daten \(f.payload.count) Byte · " + printable(f.payload, limit: 120)
        }
    }

    public static func direction(_ f: AVLCFrame) -> String {
        if f.source.isAircraft { return f.destination.isAircraft ? "FZ→FZ" : f.destination.isBroadcast ? "FZ→ALLE" : "FZ→BODEN" }
        if f.source.isGroundStation { return f.destination.isAircraft ? "BODEN→FZ" : f.destination.isBroadcast ? "BODEN→ALLE" : "BODEN→BODEN" }
        return "?"
    }
}

// MARK: - Controller

@MainActor
public final class VDL2Controller: ObservableObject {
    public let engine = VDL2Engine()
    public let logger = DecodeLogger(mode: "VDL2")
    @Published public private(set) var aircraft: [VDL2Aircraft] = []
    @Published public private(set) var groundStations: [VDL2GroundStation] = []
    @Published public private(set) var recent: [VDL2LogEntry] = []
    @Published public private(set) var status = ADSBStatus.idle
    @Published public private(set) var stats = VDL2Engine.Snapshot()
    @Published public private(set) var activityHistory: [Double] = []
    @Published public private(set) var totalFrames = 0
    @Published public private(set) var acarsCount = 0
    @Published public var selection: String?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "vdlLogEnabled") } }
    /// Aufnahme als Quelle (Prüfung und „Datei“)
    public var fileOverride: URL?
    public var fileRealtime = true
    var sourceFactory: ((VDL2SettingsStore) -> ADSBIQSource?)?

    private let settings: VDL2SettingsStore
    private var source: ADSBIQSource?
    private var sourceToken = UUID()
    private var timer: Timer?
    private var active = false
    private var cancellables: Set<AnyCancellable> = []
    public static let maxRecent = 400

    public init(settings: VDL2SettingsStore) {
        self.settings = settings
        logEnabled = UserDefaults.standard.object(forKey: "vdlLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let triggers: [AnyPublisher<Void, Never>] = [
            settings.$source.map { _ in () }.eraseToAnyPublisher(), settings.$channels.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfLNA.map { _ in () }.eraseToAnyPublisher(), settings.$hackrfVGA.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfAmp.map { _ in () }.eraseToAnyPublisher(), settings.$hackrfBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlGain.map { _ in () }.eraseToAnyPublisher(), settings.$rtlBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlPPM.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayLNAState.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayTuner.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayIFGain.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayAGC.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayPPM.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayRfNotch.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayDabNotch.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .dropFirst(triggers.count)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.active else { return }
                self.stopSource()
                self.startSource()
            }
            .store(in: &cancellables)
    }

    public func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { startSource() } else { stopSource() }
    }

    public func clear() {
        engine.reset()
        aircraft.removeAll()
        groundStations.removeAll()
        recent.removeAll()
        activityHistory.removeAll()
        totalFrames = 0
        acarsCount = 0
        selection = nil
    }

    public func startSource() {
        stopSource()
        let src: ADSBIQSource
        var sampleRate = 2_000_000
        var center = settings.centerFrequency
        var frequencies = settings.channelFrequencies
        var device = true
        if let made = sourceFactory?(settings) {
            src = made
        } else if let url = fileOverride {
            let file = VDL2FileSource(url: url, realtime: fileRealtime)
            sampleRate = file.sampleRate
            // Aufnahme: ein Kanal in der Mitte (wie bei dumpvdl2); angezeigt wird der gewählte Kanal, sonst der Signalisierungskanal
            center = settings.channelFrequencies.count == 1 ? settings.channelFrequencies[0] : VDL2.commonSignallingChannel
            frequencies = [center]
            device = false
            src = file
        } else {
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
            logger.markSession("VDL Mode 2 · \(frequencies.map { VDL2Channels.title($0) }.joined(separator: " ")) MHz · \(src.deviceDescription)")
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

    private func poll() {
        guard active || fileOverride != nil else { return }
        let s = engine.snapshot()
        stats = s
        activityHistory.append(s.activity)
        if activityHistory.count > 240 { activityHistory.removeFirst(activityHistory.count - 240) }
        let now = Date()
        for b in s.bursts { for f in b.frames { ingest(f, now: now) } }
        if settings.expireMinutes > 0 {
            let limit = Double(settings.expireMinutes) * 60
            aircraft.removeAll { now.timeIntervalSince($0.lastSeen) > limit }
        }
    }

    /// Einen Rahmen aufnehmen (auch für Tests)
    public func ingest(_ f: AVLCFrame, now: Date = Date()) {
        totalFrames += 1
        if f.acars != nil { acarsCount += 1 }
        let summary = VDL2Format.summary(f)
        // Flugzeug: Quelle bei Abwärtsrahmen, Ziel bei Aufwärtsrahmen
        let plane: VDL2Address? = f.source.isAircraft ? f.source : f.destination.isAircraft ? f.destination : nil
        let ground: VDL2Address? = f.source.isGroundStation ? f.source : f.destination.isGroundStation ? f.destination : nil
        if let p = plane {
            if let i = aircraft.firstIndex(where: { $0.address == p }) {
                aircraft[i].lastSeen = now
                aircraft[i].frames += 1
                aircraft[i].frequency = f.frequency
                aircraft[i].levelDB = f.levelDB
                if let g = ground { aircraft[i].groundStation = g.text }
                if let a = f.acars { Self.apply(a, to: &aircraft[i]) } else if let t = Self.readable(f) { aircraft[i].lastText = t }
                if f.source.isGroundStation { aircraft[i].onGround = f.destination.status == 1 }
            } else {
                var a = VDL2Aircraft(address: p, firstSeen: now, lastSeen: now, frames: 1, groundStation: ground?.text, frequency: f.frequency, levelDB: f.levelDB, lastText: "")
                if let m = f.acars { Self.apply(m, to: &a) } else if let t = Self.readable(f) { a.lastText = t }
                if f.source.isGroundStation { a.onGround = f.destination.status == 1 }
                aircraft.append(a)
            }
            aircraft.sort { ($0.lastSeen, $0.id) > ($1.lastSeen, $1.id) }
        }
        if let g = ground {
            if let i = groundStations.firstIndex(where: { $0.address == g }) {
                groundStations[i].frames += 1
                groundStations[i].lastSeen = now
                groundStations[i].frequencies.insert(f.frequency)
            } else {
                groundStations.append(VDL2GroundStation(address: g, frames: 1, lastSeen: now, frequencies: [f.frequency]))
            }
            groundStations.sort { ($0.frames, $0.id) > ($1.frames, $1.id) }
        }
        recent.append(VDL2LogEntry(time: now, frame: f, summary: summary))
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
        if logEnabled { logger.append(Self.logLine(f, summary: summary, time: now), now: now) }
    }

    /// Nutzdaten eines Datenrahmens ohne ACARS, wenn sie überwiegend aus Text bestehen
    private static func readable(_ f: AVLCFrame) -> String? {
        guard f.kind == .information, f.payload.count >= 8 else { return nil }
        let text = VDL2Format.printable(f.payload, limit: 160)
        let printable = text.filter { $0 != "." }.count
        return Double(printable) / Double(text.count) > 0.8 ? text : nil
    }

    private static func apply(_ m: ACARSMessage, to a: inout VDL2Aircraft) {
        a.acarsMessages += 1
        if !m.registration.isEmpty { a.registration = m.registration }
        if let f = m.flightID, !f.isEmpty { a.flight = f }
        let t = m.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { a.lastText = t }
    }

    nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated public static func time(_ d: Date) -> String { timeFormatter.string(from: d) + " UTC" }

    /// „08:15:02  136,975  FZ→BODEN  3C6444 → 123456  I  ACARS D-AIXC H1 …“
    nonisolated public static func logLine(_ f: AVLCFrame, summary: String, time: Date) -> String {
        "\(timeFormatter.string(from: time))  \(VDL2Channels.title(f.frequency))  \(VDL2Format.direction(f))  \(f.source.text) → \(f.destination.text)  \(f.command)  \(summary)\n"
    }
}
