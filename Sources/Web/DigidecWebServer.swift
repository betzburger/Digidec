// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Network
import CryptoKit
import Combine
import os

/// Schnittstelle zum Host-Zustand (DigidecState oder Test-Host), um lose Kopplung zu garantieren
@MainActor
public protocol WebHostDelegate: AnyObject {
    var activeModuleId: String { get }
    var dialFrequencyHz: Int { get }
    var activeModeString: String { get }
    var connectedRigName: String { get }
    var waterfallRowData: Data? { get }
    func addAudioSink(rate: Double, _ sink: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) -> UUID
    func removeAudioSink(_ id: UUID)
    func selectModule(id: String)
    func tuneOffset(hz: Double)
}

/// Integrierter HTTP- und WebSocket-Server für den Web-Fernzugriff im RadioTheme.
/// Nutzt Apples natives Network.framework (`NWListener`) ohne externe Framework-Abhängigkeiten.
@MainActor
public final class DigidecWebServer: ObservableObject {
    public static let shared = DigidecWebServer()

    public weak var delegate: WebHostDelegate? {
        didSet {
            if isRunning && audioSinkId == nil, let delegate {
                audioSinkId = delegate.addAudioSink(rate: 8000) { [weak self] buffer in
                    self?.broadcastAudioChunk(buffer)
                }
            }
        }
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

    private init() {
        let savedPort = UserDefaults.standard.integer(forKey: "webServerPort")
        self.port = (savedPort > 1024 && savedPort < 65535) ? UInt16(savedPort) : 8080
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
        
        connections[id] = webConn
        clientCount = connections.count
        webConn.start()
        
        // Sofortigen Initial-Status senden
        sendStateUpdate(to: id)
    }

    private func startBackgroundStreaming() {
        // 1. Waterfall Streaming Timer (30 Hz)
        wfTimer?.invalidate()
        wfTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastWaterfallRow()
            }
        }

        // 2. Audio Pipeline Tap für Web Audio Streaming (8 kHz PCM 16-Bit)
        if audioSinkId == nil, let delegate = delegate {
            audioSinkId = delegate.addAudioSink(rate: 8000) { [weak self] buffer in
                self?.broadcastAudioChunk(buffer)
            }
        }
    }

    private func stopBackgroundStreaming() {
        wfTimer?.invalidate()
        wfTimer = nil
        if let id = audioSinkId {
            delegate?.removeAudioSink(id)
            audioSinkId = nil
        }
        cancellables.removeAll()
    }

    private func broadcastWaterfallRow() {
        guard isRunning, !connections.isEmpty, let rowData = delegate?.waterfallRowData else { return }
        let wsFrame = WebSocketFrame.makeBinaryFrame(rowData)
        for conn in connections.values where conn.isWebSocket {
            conn.sendRaw(wsFrame)
        }
    }

    nonisolated private func broadcastAudioChunk(_ buffer: UnsafeBufferPointer<Float>) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        
        // Format: [0x02 (Tag: PCM 16-Bit)] + [Int16 LE Samples]
        var data = Data()
        data.append(0x02)
        data.reserveCapacity(1 + buffer.count * 2)
        
        for i in 0..<buffer.count {
            let sample = max(-1.0, min(1.0, base[i]))
            let int16 = Int16(sample * 32767.0)
            var le = int16.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        
        let wsFrame = WebSocketFrame.makeBinaryFrame(data)
        Task { @MainActor in
            guard self.isRunning else { return }
            for conn in self.connections.values where conn.isWebSocket && conn.wantsAudio {
                conn.sendRaw(wsFrame)
            }
        }
    }

    public func broadcastDecodedText(_ text: String) {
        guard isRunning, !connections.isEmpty else { return }
        let payload: [String: Any] = ["type": "text", "text": text]
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: json, encoding: .utf8) {
            let frame = WebSocketFrame.makeTextFrame(str)
            for conn in connections.values where conn.isWebSocket {
                conn.sendRaw(frame)
            }
        }
    }

    public func broadcastStateUpdate() {
        for id in connections.keys {
            sendStateUpdate(to: id)
        }
    }

    private func sendStateUpdate(to connId: UUID) {
        guard let conn = connections[connId], conn.isWebSocket else { return }
        let payload: [String: Any] = [
            "type": "state",
            "module": delegate?.activeModuleId ?? "rtty",
            "dialHz": delegate?.dialFrequencyHz ?? 0,
            "mode": delegate?.activeModeString ?? "USB",
            "rig": delegate?.connectedRigName ?? "Kein Funkgerät"
        ]
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
        connection.send(content: data, completion: .contentProcessed { _ in })
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
            return
        }

        // 2. Statische Dashboard HTML für "/" oder "/index.html"
        let htmlData = Data(WebDashboardAssets.html.utf8)
        let response = "HTTP/1.1 200 OK\r\n" +
                       "Content-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(htmlData.count)\r\n" +
                       "Connection: close\r\n\r\n"
        
        var full = Data(response.utf8)
        full.append(htmlData)
        sendRaw(full)
        close()
    }
}
