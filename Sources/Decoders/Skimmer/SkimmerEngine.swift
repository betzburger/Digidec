import Foundation

// MARK: - Öffentliche Datentypen

/// Ein vom Skimmer gefundenes und gelesenes Signal
public struct SkimChannelInfo: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable { case candidate, active }
    public var id: Int
    public var mode: SkimMode
    /// NF-Frequenz des Trägers in Hz
    public var frequencyHz: Double
    /// Signal über dem Rauschen in dB, bezogen auf 500 Hz Bandbreite (wie bei CW Skimmer und im Reverse Beacon Network)
    public var snrDB: Double
    /// Geschwindigkeit: WpM bei CW, Baud bei PSK
    public var speed: Double
    public var state: State
    /// Audiozeit (Sekunden) der Entdeckung und der letzten Aktivität (Tastung bzw. Zeichen)
    public var born: Double
    public var lastActive: Double
    /// Anteil plausibler Zeichen (0…1)
    public var quality: Double
    public var characters: Int
}

// MARK: - Engine

/// Sucht im Audio (8 kHz) alle Signale einer Betriebsart (CW, BPSK31, BPSK63) und liest jedes in einem eigenen Kanal.
///
/// Ablauf: Spektrum (1024 Punkte, gemittelt) → Spitzen über dem Rauschen → je Spitze ein Kanal (Mischer, Tiefpass, Decoder).
/// Kanäle, die sich als Dauerträger oder Rauschen erweisen (keine Tastung, keine Phasenumkehr), werden verworfen und für eine Weile nicht neu angelegt.
/// Alle Zustände gehören der Engine: Aufrufe nur von einer Queue.
public final class SkimmerEngine: @unchecked Sendable {
    public struct Config: Sendable {
        /// Abstand der Spitze zum Rauschen (dB je Bin), ab dem ein Signal gesucht wird
        public var thresholdDB = 8.0
        public var maxChannels = 48
        public var minHz = 200.0
        public var maxHz = 3300.0
        public init() {}
    }

    public let mode: SkimMode
    public var config = Config() {
        didSet {
            detector.config.thresholdDB = config.thresholdDB
            detector.config.minHz = config.minHz
            detector.config.maxHz = config.maxHz
        }
    }
    /// Text eines Kanals: (Kanal, Zeichen, Audiozeit in Sekunden)
    public var onText: ((Int, String, Double) -> Void)?
    /// Ein Kanal ist weggefallen (Signal verschwunden oder verworfen)
    public var onClosed: ((Int) -> Void)?
    /// Ein Kanal ist neu in die Liste gekommen (hat Tastung bzw. Phasenumkehr gezeigt)
    public var onActivated: ((Int) -> Void)?

    private let spectrum = SkimSpectrum()
    private let detector: SkimDetector
    private(set) var time = 0.0
    private var framesSinceDetect = 0
    private var framesSinceReview = 0

    private final class State {
        let id: Int
        let trackID: Int
        let born: Double
        var cw: SkimCWChannel?
        var psk: SkimPSKChannel?
        var active = false
        var lastActive: Double
        var lastKey = false
        var snrDB = 0.0
        var lastCharacters = 0
        /// Text, der vor der Aufnahme in die Liste gelesen wurde: wird mit der Aufnahme nachgeliefert
        var pending = ""
        /// Die letzten gelesenen Zeichen (zur Prüfung, ob es Text oder Rauschen ist)
        var recent = ""
        /// Seit wann liest der Kanal nur noch Unsinn (Audiozeit), nil = lesbar
        var gibberishSince: Double?
        init(id: Int, trackID: Int, born: Double) { self.id = id; self.trackID = trackID; self.born = born; lastActive = born }
    }

    private var states: [Int: State] = [:]
    private var blacklist: [(hz: Double, until: Double)] = []
    private var nextID = 1

    public init(mode: SkimMode) {
        self.mode = mode
        detector = SkimDetector(mode: mode, spectrum: spectrum)
        detector.config.minHz = config.minHz
        detector.config.maxHz = config.maxHz
    }

    public func reset() {
        spectrum.reset()
        detector.reset()
        for id in states.keys { onClosed?(id) }
        states.removeAll()
        blacklist.removeAll()
        time = 0
    }

    /// Audioblock (8 kHz, Mono) verarbeiten
    public func process(_ samples: UnsafeBufferPointer<Float>) {
        for x in samples {
            if spectrum.push(x) {
                framesSinceDetect += 1
                if framesSinceDetect >= 4 {                  // alle 128 ms
                    framesSinceDetect = 0
                    detect()
                }
            }
        }
        for s in states.values {
            s.cw?.process(samples)
            s.psk?.process(samples)
        }
        time += Double(samples.count) / SkimDownconverter.sampleRate
        framesSinceReview += samples.count
        if framesSinceReview >= 8000 {
            framesSinceReview = 0
            review()
        }
    }

    // MARK: Erkennung

    private func detect() {
        let result = detector.update(time: time)
        for t in result.born {
            if blacklist.contains(where: { abs($0.hz - t.frequencyHz) < 20 && $0.until > time }) { continue }
            guard states.count < config.maxChannels else { continue }
            let id = nextID
            nextID += 1
            let st = State(id: id, trackID: t.id, born: time)
            st.snrDB = Self.snr500(track: t, mode: mode)
            switch mode {
            case .cw:
                let c = SkimCWChannel(frequencyHz: t.frequencyHz)
                c.onText = { [weak self, weak st] text in
                    guard let self, let st else { return }
                    st.lastActive = self.time
                    self.deliver(st, text)
                }
                st.cw = c
            case .psk31, .psk63:
                let c = SkimPSKChannel(mode: mode, frequencyHz: t.frequencyHz)
                c.onText = { [weak self, weak st] text in
                    guard let self, let st else { return }
                    st.lastActive = self.time
                    self.deliver(st, text)
                }
                st.psk = c
            }
            states[id] = st
        }
        for t in result.died {
            if let (id, _) = states.first(where: { $0.value.trackID == t.id }) {
                states.removeValue(forKey: id)
                onClosed?(id)
            }
        }
        // laufende Spuren: Frequenz und Rauschabstand nachführen
        for t in detector.tracks where t.confirmed {
            guard let st = states.values.first(where: { $0.trackID == t.id }) else { continue }
            // genau aus dem Pegel des Kanals (Trägeramplitude A = 2 · Basisbandpegel) gegen das Rauschen im Spektrum (σ² = N · P_Rauschen je Bin);
            // vor der Aufnahme in die Liste grob aus der Spur. In Sendepausen bleibt der letzte Wert stehen (die Spur fällt dann mit ab).
            var snr: Double?
            if let c = st.cw {
                if c.openRatio > 2.2 && c.isKeyDown { snr = Self.snr500(level: c.signalLevel, noiseBinDB: detector.noiseDB(at: t.frequencyHz)) }
                else if !st.active { snr = Self.snr500(track: t, mode: mode) }
            } else if let c = st.psk {
                if c.signalLevel > 0, c.carrierDetected { snr = Self.snr500(level: c.signalLevel, noiseBinDB: detector.noiseDB(at: t.frequencyHz)) }
                else if !st.active { snr = Self.snr500(track: t, mode: mode) }
            }
            if let snr { st.snrDB += 0.2 * (snr - st.snrDB) }
            if let c = st.cw, abs(t.frequencyHz - c.frequencyHz) > 2.5 { c.setFrequency(t.frequencyHz) }
            // PSK führt seine Frequenz selbst nach (Phasenfehler); nur bei großer Abweichung zur Spur folgen
            if let c = st.psk {
                if abs(t.frequencyHz - c.frequencyHz) > 14 { c.setFrequency(t.frequencyHz) } else { c.anchor(to: t.frequencyHz) }
            }
        }
    }

    private func deliver(_ st: State, _ text: String) {
        st.recent += text
        if st.recent.count > 80 { st.recent.removeFirst(st.recent.count - 80) }
        if st.active {
            onText?(st.id, text, time)
        } else {
            st.pending += text
            if st.pending.count > 300 { st.pending.removeFirst(st.pending.count - 300) }
        }
    }

    private func activate(_ st: State) {
        st.active = true
        onActivated?(st.id)
        if !st.pending.isEmpty {
            onText?(st.id, st.pending, time)
            st.pending = ""
        }
    }

    /// Rauschabstand in 500 Hz aus dem Basisbandpegel `level` (halbe Trägeramplitude) und der Rauschleistung je Bin des Spektrums:
    /// Träger A = 2·level, Rauschen σ² = N·P (N = 1024), Abstand 4·A²/σ² = level²/(64·P)
    static func snr500(level: Double, noiseBinDB: Double) -> Double {
        20 * log10(max(level, 1e-12)) - 10 * log10(64.0) - noiseBinDB
    }

    /// Spuren-SNR (dB je Bin über dem Rauschen) → Signal-Rausch-Abstand in 500 Hz
    static func snr500(track t: SkimTrack, mode: SkimMode) -> Double {
        switch mode {
        case .cw:
            // je Bin (Hann: 1,5 Bin = 11,7 Hz Rauschbandbreite) ist der Abstand um 10·lg(500/11,7) = 16,3 dB größer als in 500 Hz;
            // getastet liegt der Mittelwert etwa 3 dB unter dem Zeichenpegel
            return t.snrDB - 10 * log10(500 / 11.72) + 3
        case .psk31, .psk63:
            // geglättetes Spektrum über 5 bzw. 9 Bins (39 bzw. 70 Hz)
            let width = mode == .psk63 ? 70.3 : 39.1
            return t.snrDB + 10 * log10(width / 500)
        }
    }

    // MARK: Auswertung der Kanäle (einmal je Sekunde)

    private func review() {
        var closed: [Int] = []
        // stärkste zuerst: Seitenbänder sehen dann ihren Träger schon in der Liste
        for st in states.values.sorted(by: { $0.snrDB > $1.snrDB }) {
            let age = time - st.born
            switch mode {
            case .cw:
                guard let c = st.cw else { continue }
                if c.isKeyDown { st.lastActive = time }
                if !st.active {
                    // Dauerträger oder Rauschen: keine Tastung nach 15 s, oder 30 s ohne verständliche Zeichen
                    if age > 15 && c.markCount < 4 { closed.append(st.id); reject(st); continue }
                    if age > 30 && c.plausibility < 0.35 && c.knownPatterns + c.unknownPatterns >= 6 { closed.append(st.id); reject(st); continue }
                    if c.markCount >= 10 && c.plausibility >= 0.7 && c.wpm >= 6 && c.wpm <= 48 && c.characters >= 6
                        && st.snrDB >= 4 && Self.looksLikeText(st.recent, mode: mode) {
                        switch twin(of: st) {
                        case .none: activate(st)
                        case .undecided: break
                        case .twin: closed.append(st.id); reject(st); continue
                        }
                    }
                } else if twin(of: st) == .twin {
                    closed.append(st.id); reject(st); continue
                } else if !Self.looksLikeText(st.recent, mode: mode) || c.wpm > 50 || c.wpm < 6 {
                    // ein aktiver Kanal, der nur noch Unsinn liest (Signal weg, Rauschen, Störer): aus der Liste nehmen
                    if st.gibberishSince == nil { st.gibberishSince = time }
                    if time - (st.gibberishSince ?? time) > 20 { closed.append(st.id); reject(st); continue }
                } else {
                    st.gibberishSince = nil
                }
            case .psk31, .psk63:
                guard let c = st.psk else { continue }
                if !st.active {
                    if age > 14 && !c.carrierDetected { closed.append(st.id); reject(st); continue }
                    if age > 40 && c.characters < 3 { closed.append(st.id); reject(st); continue }
                    if c.carrierDetected && c.printable >= 8 && c.plausibility >= 0.6 && st.snrDB >= 3 && Self.looksLikeText(st.recent, mode: mode) {
                        switch twin(of: st) {
                        case .none: activate(st)
                        case .undecided: break
                        case .twin: closed.append(st.id); reject(st); continue
                        }
                    }
                } else if twin(of: st) == .twin {
                    closed.append(st.id); reject(st); continue
                } else if !Self.looksLikeText(st.recent, mode: mode) {
                    if st.gibberishSince == nil { st.gibberishSince = time }
                    if time - (st.gibberishSince ?? time) > 30 { closed.append(st.id); reject(st); continue }
                } else {
                    st.gibberishSince = nil
                }
            }
        }
        for id in closed {
            states.removeValue(forKey: id)
            onClosed?(id)
        }
        blacklist.removeAll { $0.until < time }
    }

    /// Liest der Kanal Text oder Rauschen? Rauschen ergibt in Morse fast nur E, T, I, S, H und „*“, in PSK Zeichen außerhalb von Schrift.
    static func looksLikeText(_ text: String, mode: SkimMode) -> Bool {
        let chars = Array(text.uppercased())
        guard chars.count >= 12 else { return true }
        switch mode {
        case .cw:
            let letters = chars.filter { $0.isLetter || $0.isNumber }
            guard letters.count >= 8 else { return false }
            let noise = Set("ETISH")
            let share = Double(letters.filter { noise.contains($0) }.count) / Double(letters.count)
            let unknown = Double(chars.filter { $0 == "*" }.count) / Double(chars.count)
            let distinct = Set(letters).count
            return share < 0.66 && unknown < 0.2 && distinct >= 4
        case .psk31, .psk63:
            let ok = chars.filter { $0.isLetter || $0.isNumber || " .,?/:'-+=()!\n".contains($0) }.count
            let letters = chars.filter { $0.isLetter || $0.isNumber }.count
            return Double(ok) / Double(chars.count) > 0.88 && letters >= 6
        }
    }

    private enum TwinCheck { case none, undecided, twin }

    private func frequency(of st: State) -> Double { st.cw?.frequencyHz ?? st.psk?.frequencyHz ?? 0 }

    /// Ist `st` ein Seitenband oder Verzerrungsprodukt eines stärkeren Signals nebenan? Das erkennt man am Text: Es liest dasselbe wie sein Träger.
    /// `undecided`: ein stärkeres Signal ist in der Nähe, aber es gibt noch nicht genug Text für ein Urteil.
    private func twin(of st: State) -> TwinCheck {
        let hz = frequency(of: st)
        var undecided = false
        for other in states.values where other.id != st.id && other.active && other.snrDB > st.snrDB && abs(frequency(of: other) - hz) <= mode.twinRadiusHz {
            let mine = Self.compact(st.recent)
            if mine.count < 14 { undecided = true; continue }
            let needle = Array(mine.suffix(24))
            if Self.approxContains(Self.compact(other.recent), needle: needle, maxErrors: max(2, needle.count / 6)) { return .twin }
        }
        return undecided ? .undecided : .none
    }

    /// Text ohne Zwischenräume in Großbuchstaben (Wortabstände und Zeilenwechsel unterscheiden sich zwischen Träger und Seitenband)
    static func compact(_ text: String) -> [Character] {
        text.uppercased().filter { !$0.isWhitespace }.map { $0 }
    }

    /// Kommt `needle` mit höchstens `maxErrors` Fehlern (Ersetzen, Einfügen, Weglassen) irgendwo in `haystack` vor? (Sellers)
    static func approxContains(_ haystack: [Character], needle: [Character], maxErrors: Int) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        var previous = [Int](repeating: 0, count: haystack.count + 1)       // Zeile 0: freier Anfang im Heuhaufen
        var current = previous
        for i in 1...needle.count {
            current[0] = i
            for j in 1...haystack.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (needle[i - 1] == haystack[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return (previous.min() ?? needle.count) <= maxErrors
    }

    private func reject(_ st: State) {
        let hz = st.cw?.frequencyHz ?? st.psk?.frequencyHz ?? 0
        blacklist.append((hz, time + 90))
    }

    // MARK: Abfrage

    /// Alle Kanäle (zunächst nur Kandidaten, danach „aktiv“), nach Frequenz sortiert
    public func channels() -> [SkimChannelInfo] {
        states.values.map { st -> SkimChannelInfo in
            if let c = st.cw {
                return SkimChannelInfo(id: st.id, mode: mode, frequencyHz: c.frequencyHz, snrDB: st.snrDB, speed: c.wpm,
                                       state: st.active ? .active : .candidate, born: st.born, lastActive: st.lastActive,
                                       quality: c.plausibility, characters: c.characters)
            }
            let c = st.psk!
            return SkimChannelInfo(id: st.id, mode: mode, frequencyHz: c.frequencyHz, snrDB: st.snrDB, speed: mode.baud,
                                   state: st.active ? .active : .candidate, born: st.born, lastActive: st.lastActive,
                                   quality: c.carrierDetected ? 0.5 + 0.5 * c.plausibility : 0.2, characters: c.characters)
        }.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    /// Noch nicht ausgewertete Spuren (für Anzeige im Wasserfall): NF-Frequenz und Rauschabstand
    public var trackCount: Int { detector.tracks.filter(\.confirmed).count }

    /// Rauschpegel an einer Frequenz (dB je Bin, nur zum Vergleich)
    public func noiseDB(at hz: Double) -> Double { detector.noiseDB(at: hz) }
}
