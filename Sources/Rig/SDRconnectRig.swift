// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// SDRconnect (SDRplay) als steuerbares Funkgerät: Digidec liest Frequenz, Mode und Zustand über die WebSocket-Schnittstelle von SDRconnect
// (Beschreibung 1.0.3, https://sdrplay.com/websocket-api/) und stellt auf Wunsch Frequenz, Mode, Bandbreite, Verstärkungsstufe und den
// Gerätestrom ein. Es werden nur Eigenschaften gesetzt (`set_property`), nie Aufnahmen gestartet; I/Q-, Audio- und Spektrumströme bleiben aus.

/// Zustand von SDRconnect (Eigenschaften der Schnittstelle)
public struct SDRconnectStatus: Equatable, Sendable {
    public var connected = false
    public var apiVersion: String?
    public var deviceName: String?
    /// Strom des Geräts läuft (`started`)
    public var started: Bool?
    public var centerHz: Double?
    public var sampleRate: Double?
    public var vfoHz: Double?
    /// AM, USB, LSB, CW, SAM, NFM, WFM
    public var demodulator: String?
    public var bandwidthHz: Int?
    public var lnaState: Int?
    public var lnaMin: Int?
    public var lnaMax: Int?
    public var overload: Bool?
    public var canControl: Bool?
    public var signalPowerDB: Double?
    public var snrDB: Double?
    public var validDevices: [String] = []

    public init() {}

    /// Eine Eigenschaft (Name und Wert als Text, wie die Schnittstelle sie liefert) übernehmen; `true`, wenn sie bekannt ist
    @discardableResult
    public mutating func apply(property: String, value: String) -> Bool {
        func number() -> Double? { Double(value.trimmingCharacters(in: .whitespaces)) }
        func bool() -> Bool { ["true", "1", "yes"].contains(value.lowercased()) }
        switch property {
        case "api_version": apiVersion = value
        case "active_device": deviceName = value.isEmpty ? nil : value
        case "valid_devices": validDevices = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "started": started = bool()
        case "device_center_frequency": centerHz = number()
        case "device_sample_rate": sampleRate = number()
        case "device_vfo_frequency": vfoHz = number()
        case "demodulator": demodulator = value.uppercased()
        case "filter_bandwidth": bandwidthHz = number().map { Int($0.rounded()) }
        case "lna_state": lnaState = number().map { Int($0.rounded()) }
        case "lna_state_min": lnaMin = number().map { Int($0.rounded()) }
        case "lna_state_max": lnaMax = number().map { Int($0.rounded()) }
        case "overload": overload = bool()
        case "can_control": canControl = bool()
        case "signal_power": signalPowerDB = number()
        case "signal_snr": snrDB = number()
        default: return false
        }
        return true
    }

    /// Dieselben Angaben als Frequenz und Mode im Stil der übrigen Funkgeräte (Hamlib-Namen)
    public var rigState: RigState {
        var s = RigState()
        s.connected = connected
        s.frequencyHz = vfoHz.map { Int($0.rounded()) }
        if let d = demodulator { s.mode = Self.hamlibMode(forDemodulator: d) }
        s.passbandHz = bandwidthHz
        return s
    }

    /// SDRconnect → Hamlib: NFM heißt dort FM, SAM (synchrones AM) AM
    public static func hamlibMode(forDemodulator d: String) -> String {
        switch d.uppercased() {
        case "NFM": return "FM"
        case "SAM": return "AM"
        default: return d.uppercased()
        }
    }

    /// Ablesbare Frequenz, „7.074,000 kHz“ bzw. „145,500 MHz“
    public var vfoText: String? {
        guard let f = vfoHz else { return nil }
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "de_DE")
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 3
        fmt.maximumFractionDigits = 3
        return f >= 30_000_000 ? (fmt.string(from: NSNumber(value: f / 1e6)) ?? "") + " MHz" : (fmt.string(from: NSNumber(value: f / 1e3)) ?? "") + " kHz"
    }
}

/// Mode-Namen von SDRconnect und die Hamlib-Namen, die sich darauf abbilden lassen
public enum SDRconnectModes {
    public static let all = ["AM", "SAM", "USB", "LSB", "CW", "NFM", "WFM"]

    /// Name für `set_property demodulator`; `nil` = gibt es dort nicht
    public static func name(forHamlib mode: String) -> String? {
        switch mode.uppercased() {
        case "USB", "RTTY", "RTTYR", "PKTUSB": return "USB"       // Töne im NF, den Rest macht Digidec
        case "LSB", "PKTLSB": return "LSB"
        case "CW", "CWR": return "CW"
        case "AM": return "AM"
        case "FM": return "NFM"
        case "WFM": return "WFM"
        default: return nil
        }
    }

    /// Grundbandbreite je Mode in Hz (Vorgabe, wenn nichts verlangt ist)
    public static func defaultBandwidth(_ mode: String) -> Int {
        switch mode { case "USB", "LSB": return 2700; case "CW": return 500; case "AM", "SAM": return 6000; case "NFM": return 12_500; case "WFM": return 150_000; default: return 3000 }
    }
}

/// Verbindung zu SDRconnect (WebSocket, Standardport 5454): fragt den Zustand jede Sekunde ab, nimmt Meldungen von SDRconnect entgegen
/// und setzt auf Anfrage Eigenschaften. Wie `RigctlClient`: Verbinden und Trennen über `setEndpoint`, Abstimmen über `tune`.
public final class SDRconnectRigClient: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 1.0
    static let pollProperties = ["device_vfo_frequency", "demodulator", "filter_bandwidth", "device_center_frequency", "device_sample_rate",
                                 "lna_state", "started", "overload", "can_control", "signal_power", "signal_snr", "active_device"]
    static let infoProperties = ["api_version", "lna_state_min", "lna_state_max", "valid_devices"]

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.sdrconnectrig", qos: .utility)
    private let onUpdate: @Sendable (RigState, SDRconnectStatus) -> Void
    // Nur auf `queue`
    private var endpoint: RigEndpoint?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var timer: DispatchSourceTimer?
    private var status = SDRconnectStatus()
    private var lastReceive = Date.distantPast
    private var nextConnectAttempt = Date.distantPast
    private var infoRequested = false

    public init(onUpdate: @escaping @Sendable (RigState, SDRconnectStatus) -> Void) { self.onUpdate = onUpdate }

    deinit { task?.cancel(with: .goingAway, reason: nil) }

    public func setEndpoint(_ newEndpoint: RigEndpoint?) {
        queue.async { [self] in
            guard newEndpoint != endpoint else { return }
            disconnect()
            endpoint = newEndpoint
            status = SDRconnectStatus()
            nextConnectAttempt = .distantPast
            publish()
            if newEndpoint == nil {
                timer?.cancel()
                timer = nil
            } else if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(100))
                t.setEventHandler { [weak self] in self?.poll() }
                timer = t
                t.resume()
            }
        }
    }

    // MARK: Befehle

    /// Eine Eigenschaft setzen (z. B. `lna_state`, `filter_bandwidth`). Die Rückmeldung kommt als Meldung von SDRconnect.
    public func set(_ property: String, _ value: String, completion: (@Sendable (RigTuneResult) -> Void)? = nil) {
        queue.async { [self] in
            guard task != nil, status.connected else { completion?(.notConnected); return }
            send(["event_type": "set_property", "property": property, "value": value])
            completion?(.ok)
        }
    }

    /// Gerätestrom von SDRconnect einschalten oder anhalten
    public func streamDevice(_ on: Bool) {
        queue.async { [self] in
            guard task != nil, status.connected else { return }
            send(["event_type": "device_stream_enable", "property": "", "value": on ? "true" : "false"])
        }
    }

    /// Stellt Frequenz, Mode und Bandbreite ein: liegt die Frequenz außerhalb des Empfangsbereichs (±40 % der Abtastrate um die Mitte), wandert zuerst die Mitte
    public func tune(frequencyHz: Int64, mode: String?, passbandHz: Int?, dialect: RigDialect = .sdrconnect, completion: @escaping @Sendable (RigTuneResult) -> Void) {
        queue.async { [self] in
            guard task != nil, status.connected else { completion(.notConnected); return }
            guard RigCommand.frequency(frequencyHz) != nil else { completion(.rejected("Frequenz außerhalb des Bereichs")); return }
            var name: String?
            if let mode {
                guard RigCommand.allowedModes.contains(mode.uppercased()) || mode.uppercased() == "WFM", let n = SDRconnectModes.name(forHamlib: mode) else {
                    completion(.rejected("Mode \(mode) nicht erlaubt oder bei SDRconnect unbekannt")); return
                }
                name = n
            }
            let target = Double(frequencyHz)
            let span = (status.sampleRate ?? 2_000_000) * 0.4
            if let c = status.centerHz, abs(target - c) <= span {
                // Mitte bleibt
            } else {
                send(["event_type": "set_property", "property": "device_center_frequency", "value": String(frequencyHz)])
            }
            send(["event_type": "set_property", "property": "device_vfo_frequency", "value": String(frequencyHz)])
            if let name { send(["event_type": "set_property", "property": "demodulator", "value": name]) }
            if let pb = passbandHz, pb > 0 { send(["event_type": "set_property", "property": "filter_bandwidth", "value": String(min(pb, 1_000_000))]) }
            completion(.ok)
            requestState()
        }
    }

    /// Einmaliger Test: verbinden, Zustand abfragen, trennen
    public static func probe(_ endpoint: RigEndpoint, completion: @escaping @Sendable (RigProbeResult) -> Void) {
        let client = SDRconnectRigClient { _, _ in }
        let q = DispatchQueue(label: "com.peterbetz.digidec.sdrconnectprobe")
        client.queue.async { client.endpoint = endpoint; client.openConnection(); client.requestState() }
        q.asyncAfter(deadline: .now() + 2.5) {
            client.queue.async {
                let st = client.status
                client.disconnect()
                guard client.lastReceive != .distantPast else { completion(.unreachable); return }
                guard st.vfoHz != nil || st.demodulator != nil else { completion(.noAnswer); return }
                var rs = st.rigState
                rs.host = endpoint.host
                rs.port = endpoint.port
                completion(.ok(rs))
            }
        }
    }

    // MARK: - Nur auf `queue`

    private func poll() {
        guard let endpoint else { return }
        if task == nil {
            guard Date() >= nextConnectAttempt else { return }
            nextConnectAttempt = Date().addingTimeInterval(3)
            self.endpoint = endpoint
            openConnection()
        }
        // Keine Antwort seit vier Sekunden: Verbindung gilt als verloren
        if status.connected, Date().timeIntervalSince(lastReceive) > 4 {
            disconnect()
            status = SDRconnectStatus()
            publish()
            return
        }
        requestState()
    }

    private func openConnection() {
        guard let endpoint, let url = URL(string: "ws://\(endpoint.host.contains(":") && !endpoint.host.hasPrefix("[") ? "[\(endpoint.host)]" : endpoint.host):\(endpoint.port)") else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        let s = URLSession(configuration: cfg)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        generation += 1
        infoRequested = false
        lastReceive = .distantPast
        t.resume()
        receive(t, generation: generation)
    }

    private func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        generation += 1
    }

    private func receive(_ t: URLSessionWebSocketTask, generation gen: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch result {
                case .failure:
                    self.disconnect()
                    if self.status.connected || self.status.vfoHz != nil { self.status = SDRconnectStatus(); self.publish() }
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(t, generation: gen)
                }
            }
        }
    }

    func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event_type"] as? String, let property = obj["property"] as? String else { return }
        lastReceive = Date()
        // Zweites Gerät (RSPduo): nur das erste zählt
        if let device = obj["device"] as? String, device.lowercased() == "secondary" { return }
        guard event == "property_changed" || event == "get_property_response" else { return }
        let value = obj["value"].map { "\($0)" } ?? ""
        var new = status
        new.connected = true
        new.apply(property: property, value: value)
        if new != status {
            status = new
            publish()
        }
    }

    private func requestState() {
        guard task != nil else { return }
        for p in Self.pollProperties { send(["event_type": "get_property", "property": p, "value": ""]) }
        if !infoRequested {
            infoRequested = true
            for p in Self.infoProperties { send(["event_type": "get_property", "property": p, "value": ""]) }
        }
    }

    private func send(_ object: [String: String]) {
        guard let t = task, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    private func publish() {
        var s = status
        s.connected = status.connected
        var rs = s.rigState
        rs.host = endpoint?.host
        rs.port = endpoint?.port
        onUpdate(rs, s)
    }
}
