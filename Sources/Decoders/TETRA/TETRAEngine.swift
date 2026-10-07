// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Engine für TETRA: Digidec liest I/Q-Daten (2 MS/s) selbst vom Gerät, bringt je Träger Empfänger → Burst-Synchronisierer →
// MAC → Signalisierung zum Laufen (Träger parallel) und verfolgt die Gespräche über die Gebrauchskennung des Zeitschlitzes.
// Sprache wird nur ausgegeben, wenn der Ruf nicht als verschlüsselt gekennzeichnet ist und ein Sprachdecoder vorhanden ist.

/// Verbindung zum Sprachdecoder (Schnittstelle `TetraSpeechDecoder` im Modul VoiceCore), damit die Engine ohne dieses Modul testbar bleibt
public struct TETRASpeechAdapter: Sendable {
    public var name: String
    public var reset: @Sendable () -> Void
    public var decode: @Sendable ([UInt8], Bool) -> [Int16]
    public init(name: String, reset: @escaping @Sendable () -> Void, decode: @escaping @Sendable ([UInt8], Bool) -> [Int16]) {
        self.name = name
        self.reset = reset
        self.decode = decode
    }
}

// MARK: - Kanalplan

public enum TETRAChannelPlan {
    /// Nutzbare Breite um die Mitte bei 2 MS/s (Filterflanken und Gleichanteil abgezogen)
    public static let halfWindowHz = 880_000.0
    /// Abstand zwischen Mitte und dem ersten Träger, damit der Gleichanteil des Geräts nicht stört
    public static let dcGuardHz = 60_000.0

    public static func hz(_ mhz: Double) -> Double { (mhz * 1e6 / 6250).rounded() * 6250 }

    /// Mitte des Empfangsfensters: Mitte zwischen höchstem und niedrigstem Träger, bei einem einzelnen Träger 300 kHz darunter
    /// (ein Träger liegt dann bei +300 kHz, fern vom Gleichanteil; Nachbarkanäle des Netzes liegen im Fenster)
    public static func center(for carriers: [Double]) -> Double {
        let f = carriers.map(hz)
        guard let lo = f.min(), let hi = f.max() else { return 0 }
        var c = ((lo + hi) / 2 / 25_000).rounded() * 25_000
        if hi - lo < 100_000 { c = ((lo - 300_000) / 25_000).rounded() * 25_000 }
        if let nearest = f.min(by: { abs($0 - c) < abs($1 - c) }), abs(nearest - c) < dcGuardHz { c -= 200_000 }
        return c
    }

    public static func fits(_ frequency: Double, center: Double) -> Bool { abs(frequency - center) <= halfWindowHz }

    /// MHz-Schreibweise („426,7“ oder „426.7“), mehrere Werte durch Semikolon, Leerzeichen oder Zeilenwechsel getrennt
    public static func parseFrequencies(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "\n" })
            .compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            .filter { $0 >= 30 && $0 <= 1000 }
    }

    public static func parseGroups(_ text: String) -> Set<Int> {
        Set(text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" }).compactMap { Int($0) })
    }

    /// Namen für Kennungen: je Zeile „Kennung=Name“
    public static func parseLabels(_ text: String) -> [Int: String] {
        var m: [Int: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                m[n] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return m
    }

    public static func title(_ hz: Double) -> String { String(format: "%.4f", hz / 1e6).replacingOccurrences(of: ".", with: ",") }
}

// MARK: - Rufe

public struct TETRASpeechChunk: Sendable, Equatable {
    public var bits: [UInt8]
    public var badFrame: Bool
}

public struct TETRACall: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var callID: Int?
    public var usageMarker: Int
    /// Gerufene Gruppe oder Teilnehmer (GSSI/ISSI)
    public var target: Int?
    /// Rufender Teilnehmer aus dem Rufaufbau
    public var caller: Int?
    /// Zuletzt sendender Teilnehmer
    public var speaker: Int?
    public var speakers: [Int] = []
    public var isGroup = true
    public var carrierHz: Double?
    public var timeslot: Int?
    public var start: Date
    public var lastActivity: Date
    public var end: Date?
    public var frames = 0
    public var badFrames = 0
    public var missingFrames = 0
    /// Als verschlüsselt gekennzeichnet (Dienstangabe im Rufaufbau)
    public var encrypted = false
    /// Auffällig viele fehlerhafte Rahmen: verschlüsselt oder stark gestört
    public var suspect = false
    public var simplex = true
    public var released = false
    public var audio: [TETRASpeechChunk] = []
    public var decoded = false
    var speakerAnnounced = false

    public var isLive: Bool { end == nil }
    public var seconds: Double { Double(frames) * 0.03 }
}

public struct TETRASubscriber: Identifiable, Sendable, Equatable {
    public var id: Int { ssi }
    public var ssi: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var count = 0
    public var calls = 0
    public var lastRole = ""
}

public struct TETRAEventRecord: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var tetraTime: String
    public var kind: String
    public var text: String
    public var frequency: Double
}

/// Verfolgt Gespräche über Rufaufbau und Zeitschlitz-Gebrauchskennungen (geteilt zwischen allen Trägern)
public final class TETRACallTracker: @unchecked Sendable {
    public static let maxCalls = 200
    public static let maxAudioFrames = 2_400                 // 72 s je Gespräch zum Wiederhören
    /// Gespräch gilt nach so langer Stille als beendet (Sekunden)
    public static let idleTimeout = 8.0

    private let lock = NSLock()
    private var calls: [TETRACall] = []
    private var subscribers: [Int: TETRASubscriber] = [:]
    private var events: [TETRAEventRecord] = []
    private var network: TETRANetworkInfo?
    private var listenGroups: Set<Int> = []
    private var audioMarker: Int?
    private var audioLast = Date.distantPast
    private var lastNetworkText = ""

    public init() {}

    public func configure(listenGroups: Set<Int>) { lock.withLock { self.listenGroups = listenGroups } }

    public func reset() {
        lock.withLock {
            calls.removeAll(); subscribers.removeAll(); events.removeAll(); audioMarker = nil; network = nil; lastNetworkText = ""
        }
    }

    public var currentNetwork: TETRANetworkInfo? { lock.withLock { network } }

    // MARK: Signalisierung

    private func touch(_ ssi: Int, role: String, now: Date, countCall: Bool = false) {
        var s = subscribers[ssi] ?? TETRASubscriber(ssi: ssi, firstSeen: now, lastSeen: now)
        s.lastSeen = now
        s.count += 1
        if countCall { s.calls += 1 }
        if !role.isEmpty { s.lastRole = role }
        subscribers[ssi] = s
    }

    private func record(_ kind: String, _ text: String, tetra: TETRATime, carrier: Double, now: Date) {
        events.append(TETRAEventRecord(time: now, tetraTime: tetra.description, kind: kind, text: text, frequency: carrier))
        if events.count > 600 { events.removeFirst(events.count - 600) }
    }

    private func activeIndex(callID: Int?, marker: Int?) -> Int? {
        if let id = callID, let i = calls.lastIndex(where: { $0.end == nil && $0.callID == id }) { return i }
        if let m = marker, let i = calls.lastIndex(where: { $0.end == nil && $0.usageMarker == m }) { return i }
        return nil
    }

    private func allocationHz(_ a: TETRAChannelAllocation) -> Double? {
        guard let n = network else { return nil }
        return TETRA.downlinkFrequencyHz(band: a.band ?? n.band, carrier: a.carrier, offsetIndex: a.offset ?? n.offsetIndex)
    }

    /// Wird nach jedem neuen Träger, der durch eine Kanalzuweisung auftaucht, aufgerufen (Hz); der Aufrufer richtet den Empfänger ein
    public var onNewCarrier: (@Sendable (Double) -> Void)?

    public func handle(_ signal: TETRASignal, time: TETRATime, carrier: Double, now: Date = Date()) {
        var newCarrier: Double?
        lock.withLock {
            switch signal {
            case .network(let n):
                network = n
                let t = String(format: "Netz MCC %d MNC %d · Farbcode %d · Träger %@ MHz · Standortbereich %d%@", n.mcc, n.mnc, n.colourCode, TETRAChannelPlan.title(n.downlinkHz), n.locationArea, n.airEncryption ? " · Luftverschlüsselung" : "")
                if t != lastNetworkText { lastNetworkText = t; record("NETZ", t, tetra: time, carrier: carrier, now: now) }
            case .address(let ssi, _):
                touch(ssi, role: "", now: now)
            case .encrypted(let a):
                record("VERSCHL.", "verschlüsselte Signalisierung an \(a.description)", tetra: time, carrier: carrier, now: now)
            case .note(let text):
                record("INFO", text, tetra: time, carrier: carrier, now: now)
            case .sds(let m):
                touch(m.from, role: "SDS", now: now)
                var t = "\(m.from) → \(m.to)"
                if let p = m.protocolID { t += String(format: " · Protokoll 0x%02X", p) }
                if let text = m.text { t += " · \u{201E}\(text)\u{201C}" } else if !m.data.isEmpty { t += " · " + m.data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ") }
                record("SDS", t, tetra: time, carrier: carrier, now: now)
            case .call(let s):
                handleCall(s, time: time, carrier: carrier, now: now, newCarrier: &newCarrier)
            }
        }
        if let f = newCarrier { onNewCarrier?(f) }
    }

    private func handleCall(_ s: TETRACallSignal, time: TETRATime, carrier: Double, now: Date, newCarrier: inout Double?) {
        switch s.kind {
        case .setup, .connect, .txGranted, .proceeding:
            let marker = s.usageMarker
            var index: Int?
            if s.kind == .setup {
                // Ein Rufaufbau gehört zum Ruf mit gleicher Kennung; sonst übernimmt er einen Verkehrsplatzhalter derselben Marke
                // (spätes Einsteigen) oder löst einen alten Ruf ab, der dieselbe Marke belegt hatte
                index = activeIndex(callID: s.callID, marker: nil)
                if index == nil, let m = marker, let j = calls.lastIndex(where: { $0.end == nil && $0.usageMarker == m }) {
                    if calls[j].callID == nil { index = j } else { calls[j].end = now }
                }
            } else {
                index = activeIndex(callID: s.callID, marker: marker)
            }
            var isNew = false
            var speakerChanged = false
            if index == nil && (s.kind == .setup || s.kind == .connect), let m = marker {
                isNew = true
                // Neuer Ruf (oder dieselbe Marke nach einem beendeten Ruf)
                calls.append(TETRACall(id: UUID(), callID: s.callID, usageMarker: m, start: now, lastActivity: now))
                index = calls.count - 1
                if calls.count > Self.maxCalls { calls.removeFirst(calls.count - Self.maxCalls) }
                index = calls.count - 1
            }
            guard let i = index else { return }
            calls[i].lastActivity = now
            calls[i].callID = s.callID
            if let m = marker { calls[i].usageMarker = m }
            if s.kind == .setup {
                calls[i].target = s.address.ssi
                calls[i].isGroup = (s.communicationType ?? 1) != 0
                calls[i].encrypted = calls[i].encrypted || s.encryptedCall
                calls[i].simplex = s.simplex
                if let p = s.party {
                    calls[i].caller = p
                    if calls[i].speaker == nil { calls[i].speaker = p; calls[i].speakers = [p] }
                    touch(p, role: "ruft", now: now, countCall: true)
                }
                if let g = s.address.ssi { touch(g, role: calls[i].isGroup ? "Gruppe" : "gerufen", now: now) }
            } else if s.kind == .txGranted {
                if let p = s.party, p != calls[i].speaker {
                    speakerChanged = true
                    calls[i].speaker = p
                    if !calls[i].speakers.contains(p) { calls[i].speakers.append(p) }
                    touch(p, role: "spricht", now: now)
                }
                if s.encryptedCall { calls[i].encrypted = true }
            }
            if let a = s.allocation {
                if let f = allocationHz(a) {
                    calls[i].carrierHz = f
                    if abs(f - carrier) > 1_000 { newCarrier = f }
                }
                if let t = a.timeslots.first { calls[i].timeslot = t }
            }
            let c = calls[i]
            let kindText = s.kind == .setup ? (c.isGroup ? "Gruppenruf" : "Einzelruf") : s.kind.rawValue
            var t = "\(kindText) Ruf \(s.callID)"
            if let g = c.target { t += " · an \(g)" }
            if let p = s.party { t += " · von \(p)" }
            t += " · Marke \(c.usageMarker)"
            if let f = c.carrierHz { t += " · \(TETRAChannelPlan.title(f)) MHz" }
            if let ts = c.timeslot { t += " TS\(ts)" }
            if c.encrypted { t += " · verschlüsselt" }
            if isNew {
                record("RUF", t, tetra: time, carrier: carrier, now: now)
                if c.speaker != nil { calls[i].speakerAnnounced = true }
            } else if s.kind == .txGranted && (speakerChanged || !calls[i].speakerAnnounced) {
                record("SPRECHER", t, tetra: time, carrier: carrier, now: now)
                calls[i].speakerAnnounced = true
            }
        case .txCeased:
            if let i = activeIndex(callID: s.callID, marker: s.usageMarker) { calls[i].lastActivity = now }
        case .release, .disconnect:
            if let i = activeIndex(callID: s.callID, marker: s.usageMarker) {
                calls[i].end = now
                calls[i].released = true
                record("ENDE", "Ruf \(s.callID) beendet (Ursache \(s.disconnectCause ?? 0)) · \(calls[i].frames) Rahmen", tetra: time, carrier: carrier, now: now)
                if audioMarker == calls[i].usageMarker { audioMarker = nil }
            }
        case .status:
            if let p = s.party { touch(p, role: "Status", now: now) }
            record("STATUS", "Status 0x\(String(s.status ?? 0, radix: 16)) von \(s.party ?? 0) an \(s.address.description)", tetra: time, carrier: carrier, now: now)
        case .info, .alert:
            break
        }
    }

    // MARK: Verkehr

    /// Sprachblock eines Verkehrsbursts; liefert die Rahmen, die jetzt abgespielt werden sollen (leer = nicht abspielen)
    public func traffic(_ block: TETRATrafficBlock, carrier: Double, now: Date = Date()) -> [TETRASpeechChunk] {
        lock.withLock {
            var index = activeIndex(callID: nil, marker: block.usageMarker)
            if index == nil {
                // Spätes Einsteigen: Ruf ohne Rufaufbau
                var c = TETRACall(id: UUID(), callID: nil, usageMarker: block.usageMarker, start: now, lastActivity: now)
                c.carrierHz = carrier
                calls.append(c)
                if calls.count > Self.maxCalls { calls.removeFirst(calls.count - Self.maxCalls) }
                index = calls.count - 1
            }
            guard let i = index else { return [] }
            calls[i].lastActivity = now
            calls[i].carrierHz = carrier
            calls[i].timeslot = block.time.tn
            var chunks: [TETRASpeechChunk] = []
            for f in block.frames {
                let chunk = f.map { TETRASpeechChunk(bits: $0.bits, badFrame: $0.badFrame) } ?? TETRASpeechChunk(bits: [UInt8](repeating: 0, count: 137), badFrame: true)
                if f == nil { calls[i].missingFrames += 1 }
                calls[i].frames += 1
                if chunk.badFrame { calls[i].badFrames += 1 }
                chunks.append(chunk)
                if calls[i].audio.count < Self.maxAudioFrames { calls[i].audio.append(chunk) }
            }
            // Verschlüsselung oder starke Störung: fast alle Rahmen fehlerhaft
            let c = calls[i]
            let usable = c.frames - c.missingFrames
            if usable >= 12 { calls[i].suspect = Double(c.badFrames - c.missingFrames) / Double(max(1, usable)) > 0.8 }
            if calls[i].encrypted || calls[i].suspect { return [] }
            // Nur ein Gespräch wird gehört: das, das zuerst Verkehr hatte
            if let m = audioMarker, m != block.usageMarker, now.timeIntervalSince(audioLast) < 0.8 { return [] }
            if !listenGroups.isEmpty {
                let ok = [c.target, c.caller, c.speaker].contains { $0 != nil && listenGroups.contains($0!) }
                if !ok { return [] }
            }
            if audioMarker != block.usageMarker { audioMarker = block.usageMarker }
            audioLast = now
            return chunks
        }
    }

    public var isFirstAudio: Bool { lock.withLock { audioMarker == nil } }

    /// Beendet Rufe ohne Verkehr seit `idleTimeout` Sekunden
    public func expire(now: Date = Date()) {
        lock.withLock {
            for i in calls.indices where calls[i].end == nil && now.timeIntervalSince(calls[i].lastActivity) > Self.idleTimeout {
                calls[i].end = now
                if audioMarker == calls[i].usageMarker { audioMarker = nil }
            }
        }
    }

    public func snapshot() -> (calls: [TETRACall], subscribers: [TETRASubscriber], events: [TETRAEventRecord], audioMarker: Int?) {
        lock.withLock { (calls, Array(subscribers.values), events, audioMarker) }
    }

    public func clear() {
        lock.withLock { calls.removeAll(); events.removeAll(); subscribers.removeAll() }
    }
}

// MARK: - Träger

/// Ein Träger: Empfänger → Burst-Synchronisierer → untere MAC → obere MAC
public final class TETRACarrier: @unchecked Sendable {
    public let frequency: Double
    public let receiver: TETRAReceiver
    public let framer = TETRAFramer()
    public let lowerMAC = TETRALowerMAC()
    public let upperMAC = TETRAUpperMAC()
    public var onSignal: (@Sendable (TETRASignal, TETRATime) -> Void)?
    public var onTraffic: (@Sendable (TETRATrafficBlock) -> Void)?
    public var onBlock: (@Sendable (TETRAMacBlock) -> Void)?
    public private(set) var syncInfo: TETRASyncInfo?
    public private(set) var trafficBlocks = 0
    private var lastSyncTime = Date.distantPast

    public init(frequency: Double, inputRate: Double, centerFrequency: Double) {
        self.frequency = frequency
        receiver = TETRAReceiver(inputRate: inputRate, nominalOffsetHz: frequency - centerFrequency)
        receiver.onBits = { [weak self] bits in self?.framer.feed(bits) }
        framer.onBurst = { [weak self] burst in self?.lowerMAC.process(burst) }
        framer.onEmptySlot = { [weak self] in self?.lowerMAC.skipSlot() }
        framer.onLock = { [weak self] on in
            guard let self else { return }
            if !on {
                self.lowerMAC.reset()
                self.upperMAC.reset()
                self.receiver.reacquire()
            }
        }
        lowerMAC.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .sync(let info, _):
                self.syncInfo = info
                self.lastSyncTime = Date()
                self.upperMAC.setCell(mcc: info.mcc, mnc: info.mnc, colourCode: info.colourCode)
            case .block(let b):
                self.onBlock?(b)
                self.upperMAC.process(b)
            case .traffic(let t):
                self.trafficBlocks += 1
                self.onTraffic?(t)
            case .access:
                break
            }
        }
        upperMAC.onSignal = { [weak self] signal, time in self?.onSignal?(signal, time) }
    }

    public func reset() {
        receiver.reset()
        framer.reset()
        lowerMAC.reset()
        upperMAC.reset()
        syncInfo = nil
    }
}

// MARK: - Engine

public final class TETRAEngine: @unchecked Sendable {
    public struct ChannelStatus: Sendable, Equatable {
        public var frequency: Double
        public var powerDB: Double
        public var offsetHz: Double
        public var locked: Bool
        public var inverted: Bool
        public var syncBursts: Int
        public var normalBursts: Int
        public var crcOK: Int
        public var crcBad: Int
        public var trafficBlocks: Int
        public var coherence: Double
        public var tetraTime: String
        public var sync: TETRASyncInfo?
    }

    public struct Snapshot: Sendable {
        public var channels: [ChannelStatus] = []
        public var calls: [TETRACall] = []
        public var subscribers: [TETRASubscriber] = []
        public var events: [TETRAEventRecord] = []
        public var network: TETRANetworkInfo?
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var droppedBlocks = 0
        public var sampleRate = 0
        public var center = 0.0
        public var audioMarker: Int?
        public var decoderName: String?
    }

    public let tracker = TETRACallTracker()
    /// Sprachdecoder (nil = nur Rufdaten)
    public var speech: TETRASpeechAdapter? {
        get { lock.withLock { _speech } }
        set { lock.withLock { _speech = newValue } }
    }
    /// Ton aus (160 oder 240 Abtastwerte je Rahmen, 8 kHz)
    public var audioSink: (@Sendable ([Int16]) -> Void)?
    public var audioEnabled: Bool {
        get { lock.withLock { _audioEnabled } }
        set { lock.withLock { _audioEnabled = newValue } }
    }
    /// Träger, die durch Kanalzuweisungen auftauchen, automatisch zuschalten
    public var autoFollow = true

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.tetra", qos: .userInitiated)
    private let lock = NSLock()
    private var _speech: TETRASpeechAdapter?
    private var _audioEnabled = true
    private var carriers: [TETRACarrier] = []
    private var sampleRate = 2_000_000
    private var center = 0.0
    private var levels = [Float](repeating: 0, count: 256)
    private var iBuf: [Float] = [], qBuf: [Float] = []
    private var pendingBytes = 0
    private var droppedBlocks = 0
    private var activity = 0.0
    private var clipped = 0, total = 0
    private var countClipping = true
    private var aliases: [Double: Double] = [:]
    private var noted: Set<Int> = []
    private var lastPlayedMarker: Int?
    static let maxPending = 8 * 1024 * 1024
    static let maxCarriers = 8

    public init() {
        for i in 0..<256 { levels[i] = (Float(i) - 127.5) / 127.5 }
        tracker.onNewCarrier = { [weak self] hz in self?.followCarrier(hz) }
    }

    public func configure(sampleRate: Int, centerFrequency: Double, frequencies: [Double], countClipping: Bool) {
        queue.async { [self] in
            self.sampleRate = sampleRate
            self.center = centerFrequency
            self.countClipping = countClipping
            carriers = []
            lock.withLock { aliases.removeAll(); noted.removeAll() }
            for f in frequencies { addCarrierLocked(f) }
        }
    }

    private func addCarrierLocked(_ f: Double) {
        guard carriers.count < Self.maxCarriers, !carriers.contains(where: { abs($0.frequency - f) < 1_000 }) else { return }
        guard TETRAReceiver.isSupported(sampleRate: Double(sampleRate)), TETRAChannelPlan.fits(f, center: center) || center == 0 else { return }
        let c = TETRACarrier(frequency: f, inputRate: Double(sampleRate), centerFrequency: center)
        c.onSignal = { [weak self, f] signal, time in
            guard let self else { return }
            if case .network(let n) = signal { self.lock.withLock { self.aliases[f] = n.downlinkHz } }
            self.tracker.handle(signal, time: time, carrier: self.displayFrequency(f))
        }
        c.onTraffic = { [weak self, f] block in self?.handleTraffic(block, carrier: self?.displayFrequency(f) ?? f) }
        carriers.append(c)
    }

    /// Frequenz, unter der ein Träger im Netz bekannt ist (bei einer Aufnahme ist der Träger „in der Mitte“, das Netz nennt die echte Frequenz)
    private func displayFrequency(_ f: Double) -> Double { lock.withLock { aliases[f] ?? f } }

    private func followCarrier(_ hz: Double) {
        guard autoFollow else { return }
        queue.async { [self] in
            guard !carriers.contains(where: { abs($0.frequency - hz) < 1_000 }) else { return }
            if lock.withLock({ aliases.values.contains { abs($0 - hz) < 1_000 } }) { return }
            if TETRAChannelPlan.fits(hz, center: center) {
                addCarrierLocked(hz)
                tracker.handle(.note("Träger \(TETRAChannelPlan.title(hz)) MHz zugeschaltet (Kanalzuweisung)"), time: TETRATime(), carrier: hz)
            } else if lock.withLock({ noted.insert(Int(hz / 1_000)).inserted }) {
                tracker.handle(.note("Träger \(TETRAChannelPlan.title(hz)) MHz liegt außerhalb des Empfangsfensters"), time: TETRATime(), carrier: hz)
            }
        }
    }

    public func reset() {
        queue.async { [self] in
            for c in carriers { c.reset() }
            tracker.reset()
            lock.withLock { droppedBlocks = 0; aliases.removeAll(); noted.removeAll() }
        }
    }

    // MARK: Ton

    private func handleTraffic(_ block: TETRATrafficBlock, carrier: Double) {
        let chunks = tracker.traffic(block, carrier: carrier)
        guard !chunks.isEmpty else { return }
        let decoder = speech
        guard audioEnabled, let decoder, let sink = audioSink else { return }
        lock.withLock {
            if lastPlayedMarker != block.usageMarker {
                lastPlayedMarker = block.usageMarker
                decoder.reset()
            }
        }
        for chunk in chunks {
            sink(decoder.decode(chunk.bits, chunk.badFrame))
        }
    }

    // MARK: Eingang

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
        guard n > 0, !carriers.isEmpty else { return }
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
        let chans = carriers
        iBuf.withUnsafeBufferPointer { ip in
            qBuf.withUnsafeBufferPointer { qp in
                nonisolated(unsafe) let i = UnsafeBufferPointer(rebasing: ip[0..<n])
                nonisolated(unsafe) let q = UnsafeBufferPointer(rebasing: qp[0..<n])
                if chans.count == 1 {
                    chans[0].receiver.process(i: i, q: q)
                } else {
                    DispatchQueue.concurrentPerform(iterations: chans.count) { chans[$0].receiver.process(i: i, q: q) }
                }
            }
        }
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot()
        tracker.expire()
        queue.sync { [self] in
            s.sampleRate = sampleRate
            s.center = center
            s.channels = carriers.map { c in
                ChannelStatus(frequency: c.frequency, powerDB: c.receiver.powerDB, offsetHz: c.receiver.tuneHz - c.receiver.nominalOffsetHz,
                              locked: c.framer.locked, inverted: c.framer.inverted, syncBursts: c.framer.statistics.syncBursts,
                              normalBursts: c.framer.statistics.normalBursts, crcOK: c.lowerMAC.crcOK, crcBad: c.lowerMAC.crcBad,
                              trafficBlocks: c.trafficBlocks, coherence: c.receiver.coherence, tetraTime: c.lowerMAC.timeKnown ? c.lowerMAC.time.description : "–",
                              sync: c.syncInfo)
            }
        }
        let t = tracker.snapshot()
        s.calls = t.calls
        s.subscribers = t.subscribers
        s.events = t.events
        s.audioMarker = t.audioMarker
        s.network = tracker.currentNetwork
        lock.withLock {
            s.activity = activity
            s.clippedFraction = total > 0 ? Double(clipped) / Double(total) : 0
            s.droppedBlocks = droppedBlocks
        }
        s.decoderName = speech?.name
        return s
    }
}
