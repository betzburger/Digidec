// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Network
import CryptoKit
import Combine
import os
import SystemConfiguration

/// Schnittstelle zum Host-Zustand (DigidecState oder Test-Host), um lose Kopplung zu garantieren
@MainActor
public protocol WebHostDelegate: AnyObject {
    var activeModuleId: String { get }
    /// Frequenz, die der Kopfzeile der App entspricht (Funkgerät, SDR oder feste Frequenz des Moduls), 0 = unbekannt
    var dialFrequencyHz: Int { get }
    var activeModeString: String { get }
    var connectedRigName: String { get }
    /// Wer das Signal liefert: „SDR · HackRF“, „Audio-Eingang“ …
    var webSourceLabel: String { get }
    /// Betriebsarten, die der Browser umschalten darf (leer = fest)
    var webModeChoices: [String] { get }
    /// Darf der Browser die Frequenz setzen?
    var webFrequencyEditable: Bool { get }
    /// Alle verfügbaren Decoder-Module in der Reihenfolge der App-Modulleiste
    var webModules: [WebModuleEntry] { get }
    /// Karteninhalt des aktiven Moduls (nil = Modul ohne Ortsdaten)
    func webMapContent(now: Date) -> MapContent?
    /// Text bzw. Liste des aktiven Moduls
    var webTranscript: WebTranscript { get }
    /// Beschreibung des Wasserfalls (Bereich, Zoom, Marken)
    var webWaterfallInfo: WebWaterfallInfo { get }
    /// Neueste Zeile des Wasserfalls als Frame (Kennung 0x01 + Farbindizes), nil = keine neue
    var waterfallRowData: Data? { get }
    /// Audio für den Browser (Rate und Kanäle liefert die Quelle mit)
    func addWebAudio(_ sink: @escaping WebAudioSink) -> UUID
    func removeWebAudio(_ id: UUID)
    func selectModule(id: String)
    func tuneOffset(hz: Double)
    func setMode(_ mode: String)
    func setFrequency(hz: Double)
    /// Klick im Wasserfall: NF-Mitte des Decoders bzw. gehörte Frequenz des SDR
    func setCenter(hz: Double)
    func setRFZoom(_ zoom: Int)
    func setNFSpan(_ hz: Double)
    func setWaterfallRange(delta: Int)
    /// Auswahllisten des aktiven Moduls (Kanäle, Bänder, Betriebsarten, Sender)
    var webPresets: [WebPresetGroup] { get }
    func setPreset(key: String, id: String)

    // SDR-Status und Steuerung
    var isSDREnabled: Bool { get }
    var sdrSourceKind: String { get }
    var sdrSampleRate: Int { get }
    var sdrLNA: Int { get }
    var sdrVGA: Int { get }
    var sdrStatusMessage: String { get }
    var isRFWaterfall: Bool { get }
    func setSDREnabled(_ enabled: Bool)
    func setSDRSource(kind: String)
    func setSDRGain(lna: Int?, vga: Int?)
    func setWaterfallMode(rf: Bool)
}

/// Integrierter HTTP- und WebSocket-Server für den Web-Fernzugriff im RadioTheme.
/// Nutzt Apples natives Network.framework (`NWListener`) ohne externe Framework-Abhängigkeiten.
@MainActor
public final class DigidecWebServer: ObservableObject {
    public static let shared = DigidecWebServer()

    public weak var delegate: WebHostDelegate? {
        didSet { attachAudio() }
    }

    @Published public private(set) var isRunning = false
    @Published public var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: "webServerPort") }
    }
    @Published public private(set) var clientCount = 0
    @Published public private(set) var lastError: String?

    private var listener: NWListener?
    private var connections: [UUID: WebConnection] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var wfTimer: Timer?
    private var audioSinkId: UUID?
    private var tickCount = 0
    private var lastStateModule: String?
    /// Grenze für noch nicht gesendete Bytes je Verbindung: darüber werden Wasserfall und Audio ausgelassen statt aufgestaut
    nonisolated static let maxPendingBytes = 768 * 1024

    private init() {
        let savedPort = UserDefaults.standard.integer(forKey: "webServerPort")
        self.port = (savedPort > 1024 && savedPort < 65535) ? UInt16(savedPort) : 8080
    }

    // MARK: - Netzwerk- und Zugriffsadressen
    /// Immer funktionierende lokale Adresse auf diesem Mac (localhost)
    public var localURL: String {
        "http://localhost:\(port)"
    }

    /// Alle im lokalen Netzwerk gefundenen IPv4-Adressen (z. B. ["192.168.1.150"])
    public var localIPv4Addresses: [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr != nil else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("wlan") || name.hasPrefix("ap") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = hostname.withUnsafeBufferPointer { ptr in
                            ptr.baseAddress.map { String(cString: $0) } ?? ""
                        }
                        if !ip.isEmpty && !ip.hasPrefix("127.") && !addrs.contains(ip) {
                            addrs.append(ip)
                        }
                    }
                }
            }
        }
        return addrs
    }

    /// Primäre LAN-Zugriffs-URL (z. B. "http://192.168.1.150:8080")
    public var lanURL: String? {
        if let primaryIP = localIPv4Addresses.first {
            return "http://\(primaryIP):\(port)"
        }
        return nil
    }

    /// Bonjour/mDNS-Hostadresse (z. B. "http://Mac-mini-von-Peter.local:8080"), sauber ermittelt ohne ISP-Reverse-DNS-Hashes
    public var bonjourURL: String? {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return "http://\(name).local:\(port)"
        }
        return nil
    }

    public func start() {
        guard !isRunning else { return }
        do {
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 8080)
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: nwPort)
            
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(conn)
                }
            }
            
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                        self?.startBackgroundStreaming()
                    case .failed(let err):
                        self?.isRunning = false
                        self?.lastError = err.localizedDescription
                        self?.stop()
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            l.start(queue: .main)
            self.listener = l
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        stopBackgroundStreaming()
        for (_, conn) in connections {
            conn.close()
        }
        connections.removeAll()
        clientCount = 0
    }

    public func toggle() {
        if isRunning {
            stop()
            UserDefaults.standard.set(false, forKey: "webServerEnabled")
        } else {
            start()
            UserDefaults.standard.set(true, forKey: "webServerEnabled")
        }
    }

    private func handleNewConnection(_ nwConn: NWConnection) {
        let id = UUID()
        let webConn = WebConnection(id: id, connection: nwConn) { [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: id)
                self?.clientCount = self?.connections.count ?? 0
            }
        } onClientMessage: { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleClientTextMessage(text, from: id)
            }
        }
        
        // Initial-Status erst nach dem WebSocket-Upgrade senden (vorher ist isWebSocket false)
        webConn.onUpgrade = { [weak self] in
            Task { @MainActor [weak self] in
                self?.sendModules(to: id)
                self?.sendStateUpdate(to: id)
                self?.sendInitialViews(to: id)
            }
        }
        connections[id] = webConn
        clientCount = connections.count
        webConn.start()
    }

    private func startBackgroundStreaming() {
        // 1. Takt mit 30 Hz: Wasserfallzeile; 5 Hz: Wasserfall-Beschreibung; 2 Hz: Text; 1 Hz: Karte
        wfTimer?.invalidate()
        wfTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.broadcastWaterfallRow()
                self.tickCount &+= 1
                if self.tickCount % 6 == 0 { self.broadcastWaterfallInfo(); self.broadcastPresets() }
                if self.tickCount % 15 == 0 { self.broadcastTranscript() }
                if self.tickCount % 30 == 0 { self.broadcastMap() }
            }
        }

        // 2. Audio für den Browser (die Quelle liefert Rate und Kanäle)
        attachAudio()
    }

    private func attachAudio() {
        guard isRunning, audioSinkId == nil, let delegate else { return }
        audioSinkId = delegate.addWebAudio { [weak self] buffer, rate, channels in
            self?.broadcastAudioChunk(buffer, rate: rate, channels: channels)
        }
    }

    private func stopBackgroundStreaming() {
        wfTimer?.invalidate()
        wfTimer = nil
        if let id = audioSinkId {
            delegate?.removeWebAudio(id)
            audioSinkId = nil
        }
        cancellables.removeAll()
    }

    private func broadcastWaterfallRow() {
        guard isRunning, !connections.isEmpty, let rowData = delegate?.waterfallRowData else { return }
        let wsFrame = WebSocketFrame.makeBinaryFrame(rowData)
        for conn in connections.values where conn.isWebSocket {
            conn.sendDroppable(wsFrame)
        }
    }

    /// Wasserfall-Beschreibung (Bereich, Zoom, Marken) an alle, deren Stand abweicht
    private func broadcastWaterfallInfo() {
        guard isRunning, !connections.isEmpty, let delegate, let json = delegate.webWaterfallInfo.json else { return }
        let frame = WebSocketFrame.makeTextFrame(json)
        for conn in connections.values where conn.isWebSocket && conn.lastWfJSON != json {
            conn.lastWfJSON = json
            conn.sendRaw(frame)
        }
    }

    /// Auswahllisten des aktiven Moduls an alle, deren Stand abweicht
    private func broadcastPresets() {
        guard isRunning, !connections.isEmpty, let delegate, let json = WebPresetGroup.json(delegate.webPresets) else { return }
        let frame = WebSocketFrame.makeTextFrame(json)
        for conn in connections.values where conn.isWebSocket && conn.lastPresetsJSON != json {
            conn.lastPresetsJSON = json
            conn.sendRaw(frame)
        }
    }

    /// Text des aktiven Moduls: je Verbindung nur die Zeilen ab der ersten Abweichung vom schon Gesendeten
    private func broadcastTranscript() {
        guard isRunning, let delegate else { return }
        let wanting = connections.values.filter { $0.isWebSocket }
        guard !wanting.isEmpty else { return }
        let moduleId = delegate.activeModuleId
        let t = delegate.webTranscript
        for conn in wanting { sendTranscript(t, module: moduleId, to: conn) }
    }

    private func sendTranscript(_ t: WebTranscript, module: String, to conn: WebConnection) {
        var from = webCommonPrefix(conn.sentLines, t.lines)
        if conn.sentModule != module || conn.sentKind != t.kind { from = 0 }
        let unchanged = from == conn.sentLines.count && from == t.lines.count
        if unchanged && conn.sentModule == module && conn.sentTitle == t.title { return }
        let payload: [String: Any] = [
            "type": "text", "module": module, "kind": t.kind.rawValue, "title": t.title,
            "from": from, "lines": Array(t.lines[from...])
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload), let str = String(data: json, encoding: .utf8) else { return }
        conn.sentLines = t.lines
        conn.sentModule = module
        conn.sentKind = t.kind
        conn.sentTitle = t.title
        conn.sendRaw(WebSocketFrame.makeTextFrame(str))
    }

    /// Format: [0x03] [Kanäle] [Rate in Hz, UInt16 LE] [Int16 LE verschachtelt]
    nonisolated private func broadcastAudioChunk(_ buffer: UnsafeBufferPointer<Float>, rate: Int, channels: Int) {
        guard let base = buffer.baseAddress, buffer.count > 0, channels == 1 || channels == 2, rate > 0, rate <= 65_535 else { return }
        var pcm = [Int16](repeating: 0, count: buffer.count)
        for i in 0..<buffer.count { pcm[i] = Int16(max(-1.0, min(1.0, base[i])) * 32767.0).littleEndian }
        var data = Data(capacity: 4 + buffer.count * 2)
        data.append(contentsOf: [0x03, UInt8(channels), UInt8(rate & 0xFF), UInt8((rate >> 8) & 0xFF)])
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        let wsFrame = WebSocketFrame.makeBinaryFrame(data)
        Task { @MainActor in
            guard self.isRunning else { return }
            for conn in self.connections.values where conn.isWebSocket && conn.wantsAudio {
                conn.sendDroppable(wsFrame)
            }
        }
    }

    public func broadcastStateUpdate() {
        for id in connections.keys {
            sendStateUpdate(to: id)
        }
        // Moduswechsel: Text, Wasserfall-Beschreibung und Karte sofort neu (nicht erst im Takt)
        if let mod = delegate?.activeModuleId, mod != lastStateModule {
            lastStateModule = mod
            broadcastTranscript()
            broadcastWaterfallInfo()
            broadcastPresets()
            broadcastMap()
        }
    }

    /// Vollständige Modulliste (alle Decoder wie in der Modulleiste der App); einmal je Verbindung nach dem Upgrade
    private func sendModules(to connId: UUID) {
        guard let conn = connections[connId], conn.isWebSocket, let delegate else { return }
        let list: [[String: Any]] = delegate.webModules.map {
            ["id": $0.id, "name": $0.name, "group": $0.group, "hasMap": $0.hasMap]
        }
        let payload: [String: Any] = ["type": "modules", "modules": list, "shapes": WebMapPayload.shapes]
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: json, encoding: .utf8) {
            conn.sendRaw(WebSocketFrame.makeTextFrame(str))
        }
    }

    /// Karte des aktiven Moduls an alle Clients, die sie sehen wollen; nur wenn sich der Inhalt geändert hat
    private func broadcastMap() {
        guard isRunning, let delegate else { return }
        let wanting = connections.values.filter { $0.isWebSocket && $0.wantsMap }
        guard !wanting.isEmpty else { return }
        let moduleId = delegate.activeModuleId
        let hasMap = delegate.webModules.first { $0.id == moduleId }?.hasMap ?? false
        let content = hasMap ? delegate.webMapContent(now: Date()) : nil
        guard let json = WebMapPayload.json(content: content, module: moduleId, hasMap: hasMap) else { return }
        let frame = WebSocketFrame.makeTextFrame(json)
        for conn in wanting where conn.lastMapJSON != json {
            conn.lastMapJSON = json
            conn.sendRaw(frame)
        }
    }

    /// Nach dem Upgrade sofort Wasserfall-Beschreibung und Text, nicht erst im nächsten Takt
    private func sendInitialViews(to connId: UUID) {
        guard let conn = connections[connId], conn.isWebSocket, let delegate else { return }
        if let json = delegate.webWaterfallInfo.json {
            conn.lastWfJSON = json
            conn.sendRaw(WebSocketFrame.makeTextFrame(json))
        }
        sendTranscript(delegate.webTranscript, module: delegate.activeModuleId, to: conn)
        if let json = WebPresetGroup.json(delegate.webPresets) {
            conn.lastPresetsJSON = json
            conn.sendRaw(WebSocketFrame.makeTextFrame(json))
        }
    }

    private func sendStateUpdate(to connId: UUID) {
        guard let conn = connections[connId], conn.isWebSocket else { return }
        var payload: [String: Any] = [
            "type": "state",
            "module": delegate?.activeModuleId ?? "rtty",
            "dialHz": delegate?.dialFrequencyHz ?? 0,
            "mode": delegate?.activeModeString ?? "USB",
            "rig": delegate?.connectedRigName ?? "Kein Funkgerät"
        ]
        if let d = delegate {
            payload["source"] = d.webSourceLabel
            payload["modes"] = d.webModeChoices
            payload["freqEditable"] = d.webFrequencyEditable
            payload["sdr"] = [
                "enabled": d.isSDREnabled,
                "source": d.sdrSourceKind,
                "rate": d.sdrSampleRate,
                "lna": d.sdrLNA,
                "vga": d.sdrVGA,
                "status": d.sdrStatusMessage,
                "rfWaterfall": d.isRFWaterfall
            ] as [String: Any]
        }
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: json, encoding: .utf8) {
            conn.sendRaw(WebSocketFrame.makeTextFrame(str))
        }
    }

    private func handleClientTextMessage(_ text: String, from connId: UUID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else { return }
        
        switch cmd {
        case "selectModule":
            if let modId = json["module"] as? String {
                delegate?.selectModule(id: modId)
            }
        case "tuneOffset":
            if let offsetHz = json["offsetHz"] as? Double {
                delegate?.tuneOffset(hz: offsetHz)
            }
        case "setAudioStream":
            if let enabled = json["enabled"] as? Bool {
                connections[connId]?.wantsAudio = enabled
            }
        case "setMap":
            if let enabled = json["enabled"] as? Bool {
                connections[connId]?.wantsMap = enabled
                connections[connId]?.lastMapJSON = nil   // beim Einschalten sofort den aktuellen Stand senden
                if enabled { broadcastMap() }
            }
        case "setMode":
            if let mode = json["mode"] as? String { delegate?.setMode(mode) }
        case "setFrequency":
            if let hz = (json["hz"] as? NSNumber)?.doubleValue { delegate?.setFrequency(hz: hz) }
        case "setCenter":
            if let hz = (json["hz"] as? NSNumber)?.doubleValue { delegate?.setCenter(hz: hz) }
        case "setRFZoom":
            if let z = (json["zoom"] as? NSNumber)?.intValue { delegate?.setRFZoom(z) }
        case "setNFSpan":
            if let hz = (json["hz"] as? NSNumber)?.doubleValue { delegate?.setNFSpan(hz) }
        case "setPreset":
            if let key = json["key"] as? String, let id = json["id"] as? String {
                delegate?.setPreset(key: key, id: id)
                broadcastPresets()
            }
        case "setRange":
            if let d = (json["delta"] as? NSNumber)?.intValue { delegate?.setWaterfallRange(delta: d) }
        case "setSDREnabled":
            if let enabled = json["enabled"] as? Bool {
                delegate?.setSDREnabled(enabled)
            }
        case "setSDRSource":
            if let kind = json["source"] as? String {
                delegate?.setSDRSource(kind: kind)
            }
        case "setSDRGain":
            let lna = json["lna"] as? Int
            let vga = json["vga"] as? Int
            delegate?.setSDRGain(lna: lna, vga: vga)
        case "setWaterfallMode":
            if let mode = json["mode"] as? String {
                delegate?.setWaterfallMode(rf: mode == "rf")
            }
        default:
            break
        }
    }
}

// MARK: - Einzelne HTTP / WebSocket Client-Verbindung

private final class WebConnection: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    let onClose: @Sendable () -> Void
    let onClientMessage: @Sendable (String) -> Void

    var isWebSocket = false
    var wantsAudio = false
    var wantsMap = false
    var lastMapJSON: String?
    var lastWfJSON: String?
    var lastPresetsJSON: String?
    /// Zuletzt gesendeter Text dieser Verbindung (für Differenzen)
    var sentLines: [String] = []
    var sentModule: String?
    var sentKind: WebTranscript.Kind?
    var sentTitle: String?
    /// Noch nicht von der Netzwerkschicht angenommene Bytes (nur auf der Main Queue)
    private var pendingBytes = 0
    var onUpgrade: (@Sendable () -> Void)?
    private var buffer = Data()
    private let lock = NSLock()

    init(id: UUID, connection: NWConnection, onClose: @escaping @Sendable () -> Void, onClientMessage: @escaping @Sendable (String) -> Void) {
        self.id = id
        self.connection = connection
        self.onClose = onClose
        self.onClientMessage = onClientMessage
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: .main)
        readNext()
    }

    func close() {
        connection.cancel()
        onClose()
    }

    func sendRaw(_ data: Data) {
        if Thread.isMainThread {
            sendNow(data)
        } else {
            DispatchQueue.main.async { [weak self] in self?.sendNow(data) }
        }
    }

    /// Wasserfall und Audio: lässt Pakete aus, wenn die Verbindung zu langsam ist (sonst wächst der Rückstau und der Ton läuft nach)
    func sendDroppable(_ data: Data) {
        if Thread.isMainThread {
            if pendingBytes > DigidecWebServer.maxPendingBytes { return }
            sendNow(data)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingBytes <= DigidecWebServer.maxPendingBytes else { return }
                self.sendNow(data)
            }
        }
    }

    private func sendNow(_ data: Data) {
        pendingBytes += data.count
        let n = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] err in
            DispatchQueue.main.async {
                self?.pendingBytes -= n
                if err != nil { self?.close() }
            }
        })
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.handleIncomingData(data)
            }
            if isComplete || err != nil {
                self.close()
            } else {
                self.readNext()
            }
        }
    }

    private func handleIncomingData(_ incoming: Data) {
        lock.lock()
        buffer.append(incoming)
        let cur = buffer
        lock.unlock()

        if !isWebSocket {
            // Prüfen auf HTTP Request
            guard let headerEnd = cur.range(of: Data("\r\n\r\n".utf8)) else { return }
            let requestData = cur.subdata(in: cur.startIndex..<headerEnd.upperBound)
            guard let requestStr = String(data: requestData, encoding: .utf8) else {
                close(); return
            }

            lock.lock()
            buffer.removeSubrange(cur.startIndex..<headerEnd.upperBound)
            lock.unlock()

            handleHttpRequest(requestStr)
        } else {
            // Eingehende WebSocket Frames verarbeiten
            while true {
                lock.lock()
                let available = buffer
                lock.unlock()
                
                guard let frame = WebSocketFrame.parseClientFrame(from: available) else { break }
                
                lock.lock()
                buffer.removeSubrange(available.startIndex..<(available.startIndex + frame.consumedBytes))
                lock.unlock()

                switch frame.opcode {
                case .text:
                    if let text = String(data: frame.payload, encoding: .utf8) {
                        onClientMessage(text)
                    }
                case .close:
                    close()
                    return
                case .ping:
                    sendRaw(WebSocketFrame.makeFrame(opcode: .pong, payload: frame.payload))
                default:
                    break
                }
            }
        }
    }

    private func handleHttpRequest(_ request: String) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { close(); return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { close(); return }
        
        let path = parts[1]

        // 1. WebSocket Upgrade Request prüfen (/ws)
        if path == "/ws" && request.lowercased().contains("upgrade: websocket") {
            var wsKey: String?
            for line in lines {
                if line.lowercased().hasPrefix("sec-websocket-key:") {
                    wsKey = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
            }
            guard let key = wsKey else { close(); return }
            
            // Handshake Response nach RFC 6455
            let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let hash = Insecure.SHA1.hash(data: Data((key + magic).utf8))
            let accept = Data(hash).base64EncodedString()
            
            let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                           "Upgrade: websocket\r\n" +
                           "Connection: Upgrade\r\n" +
                           "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            
            sendRaw(Data(response.utf8))
            isWebSocket = true
            onUpgrade?()
            return
        }

        // 2. Statische Dashboard HTML für "/" oder "/index.html"
        let htmlData = Data(WebDashboardAssets.html.utf8)
        let response = "HTTP/1.1 200 OK\r\n" +
                       "Content-Type: text/html; charset=utf-8\r\n" +
                       "Cache-Control: no-store\r\n" +
                       "Content-Length: \(htmlData.count)\r\n" +
                       "Connection: close\r\n\r\n"
        
        var full = Data(response.utf8)
        full.append(htmlData)
        connection.send(content: full, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}
