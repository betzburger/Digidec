import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// UKW-Seefunkkanäle des AIS
public enum AISChannel: String, CaseIterable, Identifiable, Sendable {
    case a, b, both, free

    public var id: String { rawValue }

    /// Kanal 87B
    public static let frequencyA = 161_975_000.0
    /// Kanal 88B
    public static let frequencyB = 162_025_000.0

    public var frequencyHz: Double? {
        switch self {
        case .a: return Self.frequencyA
        case .b: return Self.frequencyB
        case .both, .free: return nil
        }
    }

    /// Beide Kanäle zugleich: links Kanal A, rechts Kanal B
    public var isDual: Bool { self == .both }

    public var label: String {
        switch self {
        case .a: return "161,975"
        case .b: return "162,025"
        case .both: return "161,975 + 162,025"
        case .free: return "frei"
        }
    }

    public var title: String {
        switch self {
        case .a: return "AIS 1 · 87B"
        case .b: return "AIS 2 · 88B"
        case .both: return "A + B · L/R"
        case .free: return "FREI"
        }
    }

    public var detail: String {
        switch self {
        case .a: return "161,975 MHz (Kanal 87B, „AIS 1“, NMEA-Kanal A)"
        case .b: return "162,025 MHz (Kanal 88B, „AIS 2“, NMEA-Kanal B)"
        case .both: return "Beide Kanäle zugleich: Audio links = Kanal A (161,975 MHz), rechts = Kanal B (162,025 MHz)"
        case .free: return "Frequenz von Hand einstellen"
        }
    }

    public var nmeaChannel: Character {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .both, .free: return "A"
        }
    }
}

// MARK: - Einstellungen

@MainActor
public final class AISSettingsStore: ObservableObject {
    @Published public var channel: AISChannel { didSet { UserDefaults.standard.set(channel.rawValue, forKey: "aisChannel") } }
    /// Bei A+B: links Kanal B und rechts Kanal A statt umgekehrt
    @Published public var swapChannels: Bool { didSet { UserDefaults.standard.set(swapChannels, forKey: "aisSwapChannels") } }
    /// Wie lange ein Schiff nach der letzten Meldung in Liste und Karte bleibt (Minuten)
    @Published public var keepMinutes: Double { didSet { UserDefaults.standard.set(keepMinutes, forKey: "aisKeepMinutes") } }
    @Published public var showShips: Bool { didSet { UserDefaults.standard.set(showShips, forKey: "aisShowShips") } }
    @Published public var showAids: Bool { didSet { UserDefaults.standard.set(showAids, forKey: "aisShowAids") } }
    @Published public var showBase: Bool { didSet { UserDefaults.standard.set(showBase, forKey: "aisShowBase") } }
    /// Gebietsmeldungen (Sperrgebiete, Warnungen) in Liste und Karte zeigen
    @Published public var showAreas: Bool { didSet { UserDefaults.standard.set(showAreas, forKey: "aisShowAreas") } }
    /// Bei einem Klick auf ein Schiff in der Karte das Fenster mit den Schiffsdaten öffnen
    @Published public var openInfoOnClick: Bool { didSet { UserDefaults.standard.set(openInfoOnClick, forKey: "aisOpenInfoOnClick") } }
    /// Bei der Abfrage im Netz (Wikidata, Wikimedia Commons) automatisch suchen, sobald ein Schiff gewählt wird
    @Published public var webLookup: Bool { didSet { UserDefaults.standard.set(webLookup, forKey: "aisWebLookup") } }

    public init() {
        let d = UserDefaults.standard
        channel = AISChannel(rawValue: d.string(forKey: "aisChannel") ?? "") ?? .a
        swapChannels = d.bool(forKey: "aisSwapChannels")
        let k = d.double(forKey: "aisKeepMinutes")
        keepMinutes = (5...1440).contains(k) ? k : 30
        showShips = d.object(forKey: "aisShowShips") as? Bool ?? true
        showAids = d.object(forKey: "aisShowAids") as? Bool ?? true
        showBase = d.object(forKey: "aisShowBase") as? Bool ?? true
        showAreas = d.object(forKey: "aisShowAreas") as? Bool ?? true
        openInfoOnClick = d.object(forKey: "aisOpenInfoOnClick") as? Bool ?? true
        webLookup = d.object(forKey: "aisWebLookup") as? Bool ?? true
    }
}

extension AISSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("AIS · Basisband (GMSK 9600 Bd, bis 4,8 kHz)") }
}

// MARK: - Decoder

/// Zähler und Pegel eines Kanals (A oder B)
public struct AISChannelInfo: Equatable, Sendable {
    public var letter: Character
    public var stats: AISStats
    public var level: Double
    /// Pegel des Eingangs (Effektivwert) in dBFS
    public var inputDB: Double
}

/// AIS-Empfänger als 48-kHz-Senke an der Pipeline: ein Kanal aus dem gewählten Audiokanal, oder zwei (links A, rechts B)
public final class AISDecoder: @unchecked Sendable {
    public struct Frame: Sendable {
        public var bits: [UInt8]
        public var letter: Character
        public var rescued: Bool
    }

    public struct Output: Sendable {
        public var frames: [Frame]
        public var channels: [AISChannelInfo]

        /// Zähler aller Kanäle zusammen
        public var stats: AISStats {
            var t = AISStats()
            for c in channels {
                t.bursts += c.stats.bursts; t.frames += c.stats.frames; t.failed += c.stats.failed
                t.rescued += c.stats.rescued; t.implausible += c.stats.implausible
                if let l = c.stats.lastFrameTime { t.lastFrameTime = max(t.lastFrameTime ?? 0, l) }
            }
            return t
        }
        public var level: Double { channels.map(\.level).max() ?? 0 }
        public var inputDB: Double { channels.map(\.inputDB).max() ?? -120 }
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let first = AISReceiver(sampleRate: AISDecoder.sampleRate)
    private let second = AISReceiver(sampleRate: AISDecoder.sampleRate)
    // Nur auf der Verarbeitungs-Queue
    private var enabled = false
    private var dual = false
    private var letters: (Character, Character) = ("A", "B")
    private var meanSquare = (0.0, 0.0)

    private let lock = OSAllocatedUnfairLock()
    private var pending: [Frame] = []
    private var infos: [AISChannelInfo] = [.init(letter: "A", stats: AISStats(), level: 0, inputDB: -120)]
    private var infoLetters: (Character, Character) = ("A", "B")

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        first.onFrame = { [weak self] f in self?.deliver(f, second: false) }
        second.onFrame = { [weak self] f in self?.deliver(f, second: true) }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
        pipeline.addStereoSink(rate: Self.sampleRate) { [weak self] l, r in self?.consumeStereo(l, r) }
    }

    /// Betriebsart: ein Audiokanal (Kanal A oder B laut Einstellung) oder zwei (A links, B rechts; mit `swap` umgekehrt)
    public func configure(enabled on: Bool, channel: AISChannel, swap: Bool) {
        pipeline.perform { [self] in
            let wantDual = channel.isDual
            if on != enabled || wantDual != dual { first.reset(); second.reset() }
            enabled = on
            dual = wantDual
            letters = wantDual ? (swap ? ("B", "A") : ("A", "B")) : (channel.nmeaChannel, "B")
            meanSquare = (0, 0)
            lock.withLockUnchecked {
                infoLetters = letters
                infos = wantDual ? [.init(letter: letters.0, stats: AISStats(), level: 0, inputDB: -120), .init(letter: letters.1, stats: AISStats(), level: 0, inputDB: -120)]
                                 : [.init(letter: letters.0, stats: AISStats(), level: 0, inputDB: -120)]
            }
        }
        pipeline.wantsStereo = on && channel.isDual
    }

    public func resetStats() {
        pipeline.perform { [self] in
            first.resetStats()
            second.resetStats()
            lock.withLockUnchecked { for i in infos.indices { infos[i].stats = AISStats() } }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(frames: pending, channels: infos)
        }
    }

    private func deliver(_ f: AISReceiver.Decoded, second isSecond: Bool) {
        let letter = isSecond ? infoLetters.1 : infoLetters.0
        lock.withLockUnchecked { pending.append(Frame(bits: f.bits, letter: letter, rescued: f.rescued)) }
    }

    private func db(_ samples: UnsafeBufferPointer<Float>, _ ms: inout Double) -> Double {
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let blockMS = samples.isEmpty ? 0 : sum / Double(samples.count)
        let k = min(1.0, Double(samples.count) / (0.3 * Self.sampleRate))
        ms += k * (blockMS - ms)
        return ms > 1e-12 ? max(-120, 10 * log10(ms)) : -120
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, !dual else { return }
        first.process(samples)
        let d = db(samples, &meanSquare.0)
        let stats = first.stats, level = first.level
        lock.withLockUnchecked {
            if infos.count >= 1 { infos[0].stats = stats; infos[0].level = level; infos[0].inputDB = d }
        }
    }

    private func consumeStereo(_ l: UnsafeBufferPointer<Float>, _ r: UnsafeBufferPointer<Float>) {
        guard enabled, dual else { return }
        first.process(l)
        // Mono-Quelle: rechts ist dasselbe Signal wie links, dann gibt es keinen zweiten Kanal
        let hasSecond = pipeline.sourceChannels >= 2
        if hasSecond { second.process(r) }
        let d0 = db(l, &meanSquare.0)
        let d1 = hasSecond ? db(r, &meanSquare.1) : -120
        let s0 = first.stats, l0 = first.level, s1 = second.stats, l1 = second.level
        lock.withLockUnchecked {
            if infos.count >= 2 {
                infos[0].stats = s0; infos[0].level = l0; infos[0].inputDB = d0
                infos[1].stats = s1; infos[1].level = l1; infos[1].inputDB = d1
            }
        }
    }
}

// MARK: - Diagnose

public enum AISDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    /// Beurteilung bei zwei Kanälen (A links, B rechts): fehlt das Audio eines Kanals, sagt die Anzeige, welcher
    public static func assess(channels: [AISChannelInfo]) -> Result {
        guard channels.count == 2 else {
            return assess(inputDB: channels.first?.inputDB ?? -120, stats: channels.first?.stats ?? AISStats())
        }
        let silent = channels.filter { $0.inputDB < silenceDB && $0.stats.bursts == 0 }
        if silent.count == 2 { return assess(inputDB: -120, stats: AISStats()) }
        if let s = silent.first {
            let side = s.letter == channels[0].letter ? "links" : "rechts"
            return Result(severity: .waiting, title: "KANAL \(s.letter) OHNE AUDIO",
                          advice: "Auf dem \(side) liegt kein Signal an (Kanal \(s.letter)). Im SDR-Programm den zweiten Empfänger (162,025 bzw. 161,975 MHz) anlegen und seine Ausgabe ganz nach \(side) legen (Pan/Balance). Ist die Quelle mono, gibt es nur einen Kanal.")
        }
        var total = AISStats()
        for c in channels { total.bursts += c.stats.bursts; total.frames += c.stats.frames; total.failed += c.stats.failed }
        return assess(inputDB: channels.map(\.inputDB).max() ?? -120, stats: total)
    }

    public static func assess(inputDB: Double, stats: AISStats) -> Result {
        if inputDB < silenceDB && stats.bursts == 0 {
            return Result(severity: .problem, title: "KEIN AUDIO",
                          advice: "Am Eingang liegt kein Signal an. Richtiger Kanal (L, R oder L+R) und Eingang (VALHost) gewählt? Im SDR-Programm Ausgabe auf dieses Gerät gelegt, Rauschsperre offen?")
        }
        if stats.frames == 0 && stats.failed == 0 {
            return Result(severity: .waiting, title: "SUCHE AIS",
                          advice: "Audio kommt an, aber noch kein AIS-Burst. Im SDR-Programm: 161,975 oder 162,025 MHz, FM mit mindestens 15 kHz Bandbreite (besser 25 kHz), Audio ohne Rauschsperre, ohne De-Emphase und ohne Sprachfilter (Audio bis mindestens 6 kHz). In Gegenden mit wenig Schiffsverkehr dauert es Minuten.")
        }
        if stats.frames == 0 {
            return Result(severity: .problem, title: "BURSTS, ABER NICHTS LESBAR",
                          advice: "Der Burst-Anfang wird gefunden, aber die Daten sind nicht lesbar: Signal zu schwach oder verzerrt. FM-Bandbreite 15 … 25 kHz, Audio-Tiefpass im SDR-Programm mindestens 6 kHz, Antenne (Marine-Antenne, Sicht zum Wasser), Verstärkung.")
        }
        if stats.failed > 3 * stats.frames && stats.failed > 8 {
            return Result(severity: .waiting, title: "VIELE UNLESBARE BURSTS",
                          advice: "Neben den gelesenen Meldungen bleiben viele Bursts unlesbar: entfernte, schwache Schiffe sind normal. Treten sie auch bei starken Signalen auf, ist das Audio verfälscht (Sprachfilter, De-Emphase, Übersteuerung); Pegel um −30 … −10 dBFS.")
        }
        return Result(severity: .ok, title: "EMPFANG GUT", advice: "")
    }
}

// MARK: - Darstellung der Werte

public enum AISFormat {
    public static func decimal(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    public static func knots(_ v: Double?) -> String { v.map { decimal($0, 1) } ?? "–" }

    public static func course(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "–" }

    public static func age(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : s < 172_800 ? "\(Int(s / 3600)) h" : "\(Int(s / 86_400)) d"
    }

    public static func seaMiles(km: Double) -> String { decimal(km / 1.852, km < 10 ? 2 : 1) + " sm" }

    public static func mmsiText(_ mmsi: UInt32) -> String { String(format: "%09d", mmsi) }
}

// MARK: - Karte

public enum AISMapBuilder {
    public struct Filter: Equatable, Sendable {
        public var ships = true
        public var aids = true
        public var base = true
        public var areas = true
        public init(ships: Bool = true, aids: Bool = true, base: Bool = true, areas: Bool = true) { self.ships = ships; self.aids = aids; self.base = base; self.areas = areas }
    }

    public static func id(_ mmsi: UInt32) -> String { "ais-\(mmsi)" }

    public static func mmsi(fromID id: String) -> UInt32? {
        id.hasPrefix("ais-") ? UInt32(id.dropFirst(4)) : nil
    }

    static func symbol(_ v: AISVessel) -> String {
        switch v.kind {
        case .aid: return v.meteo != nil ? "wind" : v.virtualAton ? "diamond" : "diamond.fill"
        case .base: return v.meteo != nil ? "wind" : "antenna.radiowaves.left.and.right"
        case .aircraft: return "airplane"
        case .sart: return "exclamationmark.triangle.fill"
        case .craft: return "smallcircle.filled.circle"
        default:
            switch AISShipType.group(v.shipType ?? 0) {
            case .sailing, .pleasure: return "sailboat.fill"
            case .tug, .special: return "ferry"
            default: return "ferry.fill"
            }
        }
    }

    static func tone(_ v: AISVessel, age: Double) -> MapTone {
        if v.kind == .sart { return .alert }
        if age > 600 && v.kind != .aid && v.kind != .base { return .dim }
        if v.meteo != nil && (v.kind == .aid || v.kind == .base) { return age > 6 * 3600 ? .dim : .weather }
        switch v.kind {
        case .aid: return .dim
        case .base: return .info
        case .aircraft: return .alert
        default: break
        }
        switch AISShipType.group(v.shipType ?? 0) {
        case .passenger: return .highlight
        case .tanker: return .weather
        case .cargo: return .normal
        case .fishing, .sailing, .pleasure, .tug, .special, .highSpeed: return .info
        case .other, .unknown: return v.shipType == nil ? .dim : .normal
        }
    }


    /// Zeilen zu den binären Telegrammen (Wetter, Binnenschiff, Pegel, EMMA, VTS)
    static func binaryLines(_ v: AISVessel) -> [String] {
        var out: [String] = []
        if let w = v.meteo { out += w.lines }
        if let i = v.inland {
            var t = ["ENI \(i.eni)", i.shipTypeText]
            if let l = i.length, let b = i.beam { t.append(String(format: "%.1f × %.1f m", l, b).replacingOccurrences(of: ".", with: ",")) }
            out.append(t.joined(separator: " · "))
            let extra = [i.hazardText, i.loadedText, i.draught.map { String(format: "Tiefgang %.2f m", $0).replacingOccurrences(of: ".", with: ",") }].compactMap { $0 }
            if !extra.isEmpty { out.append(extra.joined(separator: " · ")) }
        }
        if let w = v.waterLevels { out.append(w.summary) }
        if let e = v.emma { out.append(e.text) }
        if let s = v.trafficSignal { out += s.lines }
        if let m = v.monitoring { out += m.lines }
        if let e = v.extended { out += e.lines }
        if let p = v.persons { out.append(p.text) }
        if v.isSynthetic { out.append("Position aus künstlichem Ziel der Verkehrszentrale (kein eigenes AIS-Signal)") }
        return out
    }

    static func details(_ v: AISVessel, home: GeoPoint?, age: Double) -> [String] {
        var d: [String] = []
        var head = AISCountry.name(ofMMSI: v.mmsi) ?? ""
        let flag = AISCountry.flag(ofMMSI: v.mmsi)
        if !flag.isEmpty { head = flag + " " + head }
        var ids = ["MMSI " + AISFormat.mmsiText(v.mmsi)]
        if let i = v.imo { ids.append("IMO \(i)") }
        if let c = v.callsign { ids.append(c) }
        d.append((head.isEmpty ? "" : head + " · ") + ids.joined(separator: " · "))
        if v.kind == .aid {
            if let t = v.atonType { d.append(AISAtonType.text(t) + (v.offPosition ? " · AUSSER POSITION" : "") + (v.virtualAton ? " · virtuell" : "")) }
        } else if v.kind == .shipA || v.kind == .shipB || v.kind == .craft {
            var t = [v.shipType.map(AISShipType.text) ?? v.kind.title]
            if let l = v.length, let b = v.beam { t.append("\(l) × \(b) m") } else if let l = v.length { t.append("\(l) m") }
            if let dr = v.draught { t.append("Tiefgang \(AISFormat.decimal(dr)) m") }
            d.append(t.joined(separator: " · "))
        }
        // Messstationen: Wetter vor der Position (die Auswahl in der Karte zeigt höchstens 8 Zeilen)
        let stationLines = (v.kind == .aid || v.kind == .base) ? binaryLines(v) : []
        d += stationLines
        if let p = v.point { d.append(Geo.format(p)) }
        var move: [String] = []
        if let s = v.sog { move.append("\(AISFormat.decimal(s)) kn") }
        if let c = v.cog { move.append("Kurs \(Int(c.rounded()))°") }
        if let h = v.heading { move.append("Steven \(h)°") }
        if let n = v.navStatus, v.kind == .shipA { move.append(AISNavStatus.text(n)) }
        if !move.isEmpty { d.append(move.joined(separator: " · ")) }
        if let dest = v.destination { d.append("Ziel \(dest)" + (v.etaText.map { " · ETA \($0)" } ?? "")) }
        if stationLines.isEmpty { d += binaryLines(v) }
        if let t = v.lastText, v.kind != .shipA { d.append("Text: \(t)") }
        if let h = home, let p = v.point {
            let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
            d.append("\(Geo.formatKm(km)) (\(AISFormat.seaMiles(km: km))) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
        }
        let ch = v.heardOnA && v.heardOnB ? "A + B" : v.heardOnB ? "B" : "A"
        d.append("\(v.messages) Meldungen auf Kanal \(ch) · zuletzt vor \(AISFormat.age(age))")
        return d
    }

    public static func areaID(_ a: AISAreaNotice) -> String { "ais-area-\(a.mmsi)-\(a.linkage)" }

    static func areaTone(_ a: AISAreaNotice) -> MapTone {
        switch a.category {
        case .caution, .instruction, .chart: return .highlight
        case .environment: return .weather
        case .restricted, .distress: return .alert
        case .anchorage, .information: return .info
        case .other: return .normal
        }
    }

    static func areaDetails(_ a: AISAreaNotice, home: GeoPoint?, now: Date) -> [String] {
        var d = [a.title]
        if let t = a.displayText { d.append(t) }
        var when: [String] = []
        if let s = a.start { when.append("ab " + areaTime.string(from: s) + " UTC") }
        if let e = a.end { when.append("bis " + areaTime.string(from: e) + " UTC") } else if a.durationMinutes == nil { when.append("Dauer unbefristet oder unbekannt") }
        if !when.isEmpty { d.append(when.joined(separator: " · ")) }
        var src = "Absender MMSI " + AISFormat.mmsiText(a.mmsi)
        if let f = AISCountry.name(ofMMSI: a.mmsi) { src += " (\(f))" }
        d.append(src + " · Meldung \(a.linkage)")
        if let h = home, let p = a.points.first {
            let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
            d.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
        }
        d.append("zuletzt vor \(AISFormat.age(max(0, now.timeIntervalSince(a.receivedAt))))")
        return d
    }

    private static let areaTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    /// Gebietsmeldungen: ein Punkt je Meldung (Warnzeichen), Kreise mit Radius, Rechtecke, Sektoren, Linien und Vielecke als Linien
    static func areaContent(_ areas: [AISAreaNotice], home: GeoPoint?, now: Date) -> (markers: [MapMarker], lines: [MapLine]) {
        var markers: [MapMarker] = [], lines: [MapLine] = []
        for a in areas.prefix(300) {
            guard let anchor = a.points.first else { continue }
            let tone = areaTone(a)
            let id = areaID(a)
            var sub = a.category == .distress ? "SEENOT" : "Gebietsmeldung"
            if let e = a.end { sub += " · bis " + areaTime.string(from: e) + " UTC" }
            markers.append(MapMarker(id: id, coordinate: anchor, title: a.displayText.map { String($0.prefix(24)) } ?? String(a.title.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces),
                                     subtitle: sub, details: areaDetails(a, home: home, now: now), symbol: a.category == .distress ? "lifepreserver.fill" : "exclamationmark.triangle.fill",
                                     tone: tone, heardAt: a.receivedAt))
            for (k, shape) in a.shapes.enumerated() {
                let lid = "\(id)-s\(k)"
                switch shape {
                case .circle(let c, let r):
                    if r > 0 { markers.append(MapMarker(id: lid, coordinate: c, title: "", symbol: "scope", tone: tone, radiusKm: r / 1000)) }
                case .rectangle(let p), .polygon(let p):
                    lines.append(MapLine(id: lid, points: p + [p[0]], tone: tone))
                case .polyline(let p):
                    lines.append(MapLine(id: lid, points: p, tone: tone))
                case .sector(let c, let r, let left, let right):
                    var end = right
                    if end <= left { end += 360 }
                    var pts = [c]
                    var b = left
                    while b < end { pts.append(Geo.destination(from: c, bearing: b, km: r / 1000)); b += 5 }
                    pts.append(Geo.destination(from: c, bearing: end, km: r / 1000))
                    pts.append(c)
                    lines.append(MapLine(id: lid, points: pts, tone: tone))
                case .text: break
                }
            }
        }
        return (markers, lines)
    }

    public static func content(_ vessels: [AISVessel], home: GeoPoint?, now: Date, filter: Filter, selection: String?, areas: [AISAreaNotice] = []) -> MapContent {
        var markers: [MapMarker] = []
        for v in vessels {
            guard let p = v.point else { continue }
            switch v.kind {
            case .aid: if !filter.aids { continue }
            case .base: if !filter.base { continue }
            default: if !filter.ships { continue }
            }
            let age = now.timeIntervalSince(v.lastHeard)
            var sub = [v.shipType.map(AISShipType.short) ?? v.kind.title.split(separator: " ").first.map(String.init) ?? ""]
            if v.kind == .aid, let t = v.atonType { sub = [AISAtonType.text(t)] }
            if let s = v.sog, s >= 0.5 { sub.append("\(AISFormat.decimal(s)) kn") }
            if v.kind != .aid, v.kind != .base { sub.append("vor \(AISFormat.age(age))") }
            let moving = v.isMoving && v.kind != .aid && v.kind != .base
            var heading: Double?
            if moving { heading = v.heading.map(Double.init) ?? v.cog }
            // Weg: nur bewegte Schiffe, höchstens 300 Punkte
            var track: [GeoPoint] = []
            if moving, v.track.count > 1 {
                let stride = max(1, (v.track.count + 298) / 299)
                track = v.track.enumerated().filter { $0.offset % stride == 0 }.map(\.element.point)
                if let last = v.track.last?.point, track.last != last { track.append(last) }
            }

            var marker = MapMarker(id: id(v.mmsi), coordinate: p, title: v.displayName, subtitle: sub.filter { !$0.isEmpty }.joined(separator: " · "),
                                   details: details(v, home: home, age: age), symbol: symbol(v), tone: tone(v, age: age), heardAt: v.lastHeard,
                                   track: track, headingDeg: heading)
            // Messstation: Windstärke in Knoten als Wert im Punkt, Pfeil in Windrichtung (wie bei den SYNOP-Stationen)
            if (v.kind == .aid || v.kind == .base), let w = v.meteo, let kn = w.windKn, age < 6 * 3600 {
                marker.valueText = "\(kn)"
                marker.valueLevel = min(max(Double(kn) / 50, 0), 1)
                marker.headingDeg = w.windDir.map { Double(($0 + 180) % 360) }
                marker.subtitle = "Messstation · " + w.summary
            }
            markers.append(marker)

        }
        var lines: [MapLine] = []
        if filter.areas && !areas.isEmpty {
            let a = areaContent(areas, home: home, now: now)
            markers = a.markers + markers
            lines = a.lines
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: "Noch kein Schiff mit Position empfangen")
    }
}

// MARK: - Controller

@MainActor
public final class AISController: ObservableObject {
    public let decoder: AISDecoder
    public let logger = DecodeLogger(mode: "AIS")
    @Published public private(set) var ships: [AISVessel] = []
    @Published public var selection: String?
    @Published public private(set) var stats = AISStats()
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var level = 0.0
    /// Zähler und Pegel je Kanal (ein Eintrag, bei A+B zwei)
    @Published public private(set) var channelInfo: [AISChannelInfo] = []
    /// Meldungen insgesamt, nach Typ und in der letzten Minute
    @Published public private(set) var messageCount = 0
    @Published public private(set) var typeCounts: [Int: Int] = [:]
    @Published public private(set) var perMinute = 0
    /// Gültige Gebietsmeldungen (Sperrgebiete, Warnungen), neueste zuerst
    @Published public private(set) var areas: [AISAreaNotice] = []
    /// Binärtelegramme nach „DAC/FI“
    @Published public private(set) var binaryCounts: [String: Int] = [:]
    /// Weitestes empfangenes Schiff vom Standort
    @Published public private(set) var farthest: (mmsi: UInt32, km: Double)?
    /// Schiff, dessen Daten im Fenster „Schiffsdaten“ stehen
    @Published public var infoMMSI: UInt32?
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "aisLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }
    /// Standort für Entfernungen (vom Hauptfenster gesetzt)
    public var homePoint: GeoPoint?

    private let settings: AISSettingsStore
    private var vessels: [UInt32: AISVessel] = [:]
    private var dirty = false
    private var timer: Timer?
    private var recentTimes: [Date] = []
    private var areaTable: [String: AISAreaNotice] = [:]
    private var linkedTexts: [String: String] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var isActive = false

    public init(pipeline: AudioPipeline, settings: AISSettingsStore) {
        self.settings = settings
        decoder = AISDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "aisLogEnabled") as? Bool ?? true
        markSession()
        settings.$channel
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.markSession(); self?.applyDecoder() }
            .store(in: &cancellables)
        settings.$swapChannels
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyDecoder() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        isActive = active
        applyDecoder()
    }

    private func applyDecoder() {
        decoder.configure(enabled: isActive, channel: settings.channel, swap: settings.swapChannels)
    }

    public func clear() {
        vessels.removeAll()
        ships.removeAll()
        selection = nil
        messageCount = 0
        typeCounts = [:]
        binaryCounts = [:]
        areas = []
        areaTable = [:]
        linkedTexts = [:]
        recentTimes.removeAll()
        farthest = nil
        decoder.resetStats()
        stats = AISStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let hz = Int(settings.channel.frequencyHz ?? 162_000_000)
        let name = InputRecorder.fileName(frequencyHz: hz, mode: "FM", preset: "AIS", prefix: "AIS")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: AISDiagnosis.Result { channelInfo.isEmpty ? AISDiagnosis.assess(inputDB: inputDB, stats: stats) : AISDiagnosis.assess(channels: channelInfo) }

    public func markSession() {
        var h = "AIS · \(settings.channel.label) MHz FM · GMSK 9600 Bd" + (settings.channel.isDual ? (settings.swapChannels ? " · links B, rechts A" : " · links A, rechts B") : "")
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    public var selectedMMSI: UInt32? { selection.flatMap(AISMapBuilder.mmsi(fromID:)) }

    public func vessel(_ mmsi: UInt32) -> AISVessel? { vessels[mmsi] }

    public var selectedVessel: AISVessel? { selectedMMSI.flatMap { vessels[$0] } }

    /// Für Tests: gültige Gebietsmeldungen zu einem Zeitpunkt (ohne den Zeitgeber)
    public func areasForTesting(at now: Date) -> [AISAreaNotice] {
        areaTable.values.filter { $0.isActive(at: now) }.sorted { $0.receivedAt > $1.receivedAt }
    }

    public var selectedArea: AISAreaNotice? { selection.flatMap { id in areas.first { AISMapBuilder.areaID($0) == id } } }

    private func poll() {
        let out = decoder.takeOutput()
        if out.stats != stats { stats = out.stats }
        level = out.level
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        let rounded = out.channels.map { c -> AISChannelInfo in var x = c; x.inputDB = (c.inputDB / 2).rounded() * 2; x.level = (c.level * 50).rounded() / 50; return x }
        if rounded != channelInfo { channelInfo = rounded }
        if isRecording { recordingDuration = recorder.duration }
        let now = Date()
        for f in out.frames { ingest(bits: f.bits, at: now, letter: f.letter) }
        // alte Einträge entfernen
        let keep = settings.keepMinutes * 60
        var removed = false
        for (id, v) in vessels {
            let limit = (v.kind == .aid || v.kind == .base) ? max(keep, 6 * 3600) : keep
            if now.timeIntervalSince(v.lastHeard) > limit { vessels[id] = nil; removed = true }
        }
        recentTimes.removeAll { now.timeIntervalSince($0) > 60 }
        if perMinute != recentTimes.count { perMinute = recentTimes.count }
        let activeAreas = areaTable.values.filter { $0.isActive(at: now) }
        if activeAreas.count != areaTable.count {
            areaTable = Dictionary(uniqueKeysWithValues: activeAreas.map { ($0.id, $0) })
            dirty = true
        }
        if dirty || removed {
            dirty = false
            areas = areaTable.values.sorted { $0.receivedAt > $1.receivedAt }
            ships = vessels.values.sorted { $0.lastHeard > $1.lastHeard }
            if let s = selectedMMSI, vessels[s] == nil { selection = nil }
        }
    }

    /// Eine empfangene Nachricht aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(bits: [UInt8], at now: Date = Date(), letter: Character? = nil) {
        let channelLetter = letter ?? settings.channel.nmeaChannel
        messageCount += 1
        recentTimes.append(now)
        let type = Int(AISBits(bits).u(0, 6))
        typeCounts[type, default: 0] += 1
        if logEnabled {
            let lines = AISNMEA.sentences(for: bits, channel: channelLetter)
            logger.append(lines.joined(separator: "\n") + "\n", now: now)
        }

        guard let m = AISMessage.decode(AISBits(bits)) else { return }
        if let dac = m.dac, let fid = m.fid { binaryCounts["\(dac)/\(fid)", default: 0] += 1 }
        // Verkehrszentralen senden Ziele mit Position (FI 17): wie Positionsmeldungen führen, solange das Schiff nicht selbst zu hören ist
        if case .targets(let list)? = m.binary {
            for t in list where t.idType == 0 && t.latitude != nil {
                let id = UInt32(truncatingIfNeeded: t.idNumber)
                guard AISCountry.isValidMMSI(id) else { continue }
                var tv = vessels[id] ?? AISVessel(mmsi: id, now: now)
                if tv.positions > 0, !tv.isSynthetic, now.timeIntervalSince(tv.lastPositionDate ?? .distantPast) < 300 { continue }
                var pm = AISMessage(type: 1, mmsi: id)
                pm.latitude = t.latitude
                pm.longitude = t.longitude
                pm.sog = t.sog
                pm.cog = t.cog
                pm.synthetic = true
                tv.ingest(pm, at: now)
                vessels[id] = tv
                dirty = true
            }
        }
        // Gebietsmeldungen: eigene Liste; Aufhebung durch Kennung 126 oder Dauer 0; Texte mit gleicher Verknüpfung gehören dazu
        if case .area(var a)? = m.binary {
            a.receivedAt = now
            let key = a.id
            if a.isCancellation { areaTable[key] = nil } else {
                a.linkedText = linkedTexts[key]
                areaTable[key] = a
            }
            dirty = true
        }
        if case .text(let linkage, let t)? = m.binary {
            let key = "\(m.mmsi)-\(linkage)"
            linkedTexts[key] = t
            if var a = areaTable[key] { a.linkedText = t; areaTable[key] = a; dirty = true }
        }
        var v = vessels[m.mmsi] ?? AISVessel(mmsi: m.mmsi, now: now)
        v.ingest(m, at: now)
        if channelLetter == "B" { v.heardOnB = true } else { v.heardOnA = true }
        vessels[m.mmsi] = v
        dirty = true
        if let p = v.point, let h = homePoint {
            let km = Geo.distanceKm(h, p)
            // Weiteste Verbindung: Satellitenmeldungen (Typ 27) und Ausreißer über 1500 km zählen nicht
            let best = farthest?.km ?? 0
            if m.type != 27 && km <= 1_500 && km > best { farthest = (v.mmsi, km) }
        }
    }

    /// Schiffsdaten-Fenster für dieses Schiff
    public func showInfo(for mmsi: UInt32) {
        infoMMSI = mmsi
    }

    public func mapContent(home: GeoPoint?, now: Date) -> MapContent {
        AISMapBuilder.content(ships, home: home, now: now,
                              filter: .init(ships: settings.showShips, aids: settings.showAids, base: settings.showBase, areas: settings.showAreas), selection: selection,
                              areas: areas)
    }
}
