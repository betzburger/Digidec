// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Nachgebauter WebSocket-Server von SDRconnect für die Logiktests (nur macOS, Network-Framework): hört auf 127.0.0.1, beantwortet
// get_property, setzt Eigenschaften bei set_property und meldet die Änderung wie SDRconnect als property_changed. Nicht Teil der App.
import Foundation
import Network

final class FakeSDRconnect: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.sdrconnect")
    private let lock = NSLock()
    private var props: [String: String] = [
        "device_vfo_frequency": "7074000", "device_center_frequency": "7074000", "device_sample_rate": "2000000", "demodulator": "USB",
        "filter_bandwidth": "2700", "lna_state": "4", "lna_state_min": "0", "lna_state_max": "9", "started": "true", "overload": "false",
        "can_control": "true", "signal_power": "-80.5", "signal_snr": "12.0", "active_device": "RSPdx 1234", "api_version": "1.0.3", "valid_devices": "RSPdx 1234",
    ]
    private var log: [String] = []
    private(set) var port: UInt16 = 0
    /// Antwortet auf nichts (Gegenprobe: Verbindung steht, aber keine Meldungen)
    var silent = false

    var received: [String] { lock.withLock { log } }
    func property(_ name: String) -> String? { lock.withLock { props[name] } }

    init?() {
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let p = l.port?.rawValue else { return nil }
        port = p
    }

    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(obj, c) }
            self.receive(c)
        }
    }

    private func send(_ c: NWConnection, _ event: String, _ property: String, _ value: String) {
        let obj: [String: String] = ["event_type": event, "property": property, "device": "primary", "value": value]
        guard !silent, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ obj: [String: Any], _ c: NWConnection) {
        guard let event = obj["event_type"] as? String else { return }
        let property = obj["property"] as? String ?? ""
        let value = obj["value"] as? String ?? ""
        switch event {
        case "get_property":
            if let v = lock.withLock({ props[property] }) { send(c, "get_property_response", property, v) }
        case "set_property":
            lock.withLock { log.append("set \(property)=\(value)"); props[property] = value }
            send(c, "property_changed", property, value)
        case "device_stream_enable":
            lock.withLock { log.append("stream \(value)"); props["started"] = value }
            send(c, "property_changed", "started", value)
        default:
            lock.withLock { log.append("\(event) \(property)=\(value)") }
        }
    }
}
