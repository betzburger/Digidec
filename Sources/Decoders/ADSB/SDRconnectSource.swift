// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// SDRplay-Geräte (RSP1B, RSPdx, RSPduo …) über die WebSocket-Schnittstelle von SDRconnect (Version 1.0.3 der Beschreibung,
/// https://sdrplay.com/websocket-api/): Textnachrichten sind JSON mit `event_type`, `property` und `value`; Binärnachrichten beginnen
/// mit einer 16-Bit-Kennung (Little Endian), Kennung 2 = vorzeichenbehaftete 16-Bit-I/Q-Daten des Hauptempfängers.
/// SDRconnect muss laufen (auch ohne Fenster als „Headless“), das Gerät muss dort frei sein und der Server eingeschaltet.
/// **Noch nicht am Gerät geprüft** (der Nutzer hat den RSPduo, er war beim Schreiben nicht angeschlossen).
public final class SDRconnectSource: ADSBIQSource, @unchecked Sendable {
    private let settings: ADSBGainSettings
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var running = false
    private var onData: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private var onStop: (@Sendable (String?) -> Void)?
    private var out = [UInt8]()
    private var scaler = IQ16Scaler()
    public private(set) var deviceDescription = "SDRconnect"

    public init(settings: ADSBGainSettings) { self.settings = settings }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let url = URL(string: "ws://\(settings.sdrconnectHost):\(settings.sdrconnectPort)") else {
            throw ADSBSourceError.failed("SDRconnect: Adresse ungültig")
        }
        self.onData = onData
        self.onStop = onStop
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        lock.withLock { running = true }
        t.resume()
        deviceDescription = "SDRconnect \(settings.sdrconnectHost):\(settings.sdrconnectPort)"
        // Einstellungen: Frequenz aus den Einstellungen, 2 MS/s, Verstärkungsstufe, dann I/Q-Strom einschalten
        send("set_property", "device_center_frequency", String(Int(settings.centerFrequencyHz.rounded())))
        send("set_property", "device_sample_rate", "2000000")
        send("set_property", "lna_state", "\(settings.sdrplayLNAState)")
        send("get_property", "device_sample_rate", "")
        send("iq_stream_enable", "", "true")
        send("device_stream_enable", "", "true")
        receive()
    }

    /// Nur für Tests: Empfänger der umgesetzten Daten setzen, ohne zu verbinden
    func setTestHandler(_ h: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) { onData = h }

    private func send(_ event: String, _ property: String, _ value: String) {
        var obj: [String: String] = ["event_type": event, "property": property, "value": value]
        if event == "iq_stream_enable" || event == "device_stream_enable" { obj["property"] = ""; obj["value"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.finish("SDRconnect: Senden fehlgeschlagen (\(error.localizedDescription))") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, self.lock.withLock({ self.running }) else { return }
            switch result {
            case .failure(let error):
                self.finish("SDRconnect nicht erreichbar: \(error.localizedDescription). Läuft SDRconnect mit eingeschaltetem Server (Port \(self.settings.sdrconnectPort))?")
            case .success(let message):
                switch message {
                case .data(let d): self.handleBinary(d)
                case .string(let s): self.handleText(s)
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handleText(_ s: String) {
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let property = obj["property"] as? String else { return }
        let value = "\(obj["value"] ?? "")"
        if property == "device_sample_rate", let rate = Double(value), abs(rate - 2_000_000) > 1 {
            finish("SDRconnect liefert \(Int(rate)) statt 2 000 000 Abtastwerte/s: bitte 2 MS/s einstellen")
        }
        if property == "active_device", !value.isEmpty { deviceDescription = "SDRconnect: \(value)" }
    }

    func handleBinary(_ d: Data) {
        guard d.count > 4 else { return }
        let type = Int(d[d.startIndex]) | Int(d[d.startIndex + 1]) << 8
        guard type == 2 else { return }                      // nur I/Q des Hauptempfängers
        let count = (d.count - 2) / 2
        if out.count < count { out = [UInt8](repeating: 0, count: count) }
        var maxAbs = 0
        d.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: 2).assumingMemoryBound(to: Int16.self)
            for i in 0..<count { maxAbs = max(maxAbs, abs(Int(Int16(littleEndian: p[i])))) }
            let factor = scaler.factor(maxAbs: maxAbs)
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<count { o[i] = IQ16Scaler.byte(Int16(littleEndian: p[i]), factor: factor) }
            }
        }
        out.withUnsafeBufferPointer { onData?(UnsafeBufferPointer(start: $0.baseAddress, count: count)) }
    }

    private func finish(_ reason: String?) {
        let was = lock.withLock { () -> Bool in defer { running = false }; return running }
        guard was else { return }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        onStop?(reason)
    }

    public func stop() {
        let was = lock.withLock { () -> Bool in defer { running = false }; return running }
        guard was else { return }
        send("iq_stream_enable", "", "false")
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        onStop?(nil)
    }
}
