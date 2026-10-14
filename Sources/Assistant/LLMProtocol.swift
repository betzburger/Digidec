// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// OpenAI-kompatible Schnittstelle (`/v1/chat/completions`), die llama-server, Ollama, LM Studio, OpenRouter und viele Agenten sprechen.
// Hier nur die reine Seite (Adressen, Anfrage, Antwortzeilen, Fehlertexte); das Netz ist `LLMClient`.

public enum LLMRole: String, Sendable { case system, user, assistant }

/// Eine Nachricht des Gesprächs; Bilder als PNG-Daten
public struct LLMMessage: Equatable, Sendable {
    public var role: LLMRole
    public var text: String
    public var images: [Data]

    public init(_ role: LLMRole, _ text: String, images: [Data] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

/// Zielserver
public enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case llamaServer, openRouter, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .llamaServer: return "LLAMA-SERVER"
        case .openRouter: return "OPENROUTER"
        case .custom: return "EIGENER"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .llamaServer: return "http://127.0.0.1:8080/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom: return "http://127.0.0.1:11434/v1"
        }
    }

    /// Läuft der Server im Internet (dann gehen Messwerte, Texte und Bilder an Dritte)?
    public var isCloud: Bool { self == .openRouter }
}

/// Verbindung zu einem Server
public struct LLMConfig: Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var temperature: Double
    /// false: Denkmodelle sollen nicht nachdenken (`chat_template_kwargs.enable_thinking`, wirkt bei llama-server mit passender Vorlage)
    public var thinking: Bool

    public init(baseURL: String, apiKey: String = "", model: String = "", maxTokens: Int = 4000, temperature: Double = 0.3, thinking: Bool = true) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinking = thinking
    }
}

/// Ereignis aus dem Antwortstrom
public enum LLMStreamEvent: Equatable, Sendable {
    case text(String)
    /// Gedankengang von Denkmodellen (`reasoning_content` bei llama-server, `reasoning` bei OpenRouter): wird nicht als Antwort gezeigt
    case reasoning(String)
    /// Grund des Endes („stop“, „length“ = Längengrenze erreicht)
    case finish(String)
    case done
    case error(String)
}

/// Ein Modell der Serverliste
public struct LLMModelInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Nimmt Bilder an (nur wenn der Server es meldet, OpenRouter: `input_modalities`)
    public var vision: Bool?
}

public enum LLMProtocol {
    /// Adresse der Chat-Schnittstelle zur eingegebenen Basisadresse („http://host:8080“, „…/v1“ oder schon „…/chat/completions“)
    public static func chatURL(base: String) -> URL? { endpoint(base: base, path: "chat/completions") }

    public static func modelsURL(base: String) -> URL? { endpoint(base: base, path: "models") }

    private static func endpoint(base: String, path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }
        if !b.contains("://") { b = "http://" + b }
        for tail in ["/chat/completions", "/models"] where b.hasSuffix(tail) { b.removeLast(tail.count) }
        guard let comps = URLComponents(string: b), let scheme = comps.scheme, ["http", "https"].contains(scheme), comps.host?.isEmpty == false else { return nil }
        if !(b.hasSuffix("/v1") || b.contains("/v1/")) { b += "/v1" }
        return URL(string: b + "/" + path)
    }

    /// Körper der Anfrage. Bilder gehen als `image_url` mit Datenadresse; ohne Modell fehlt das Feld (llama-server nimmt das geladene).
    public static func requestBody(config: LLMConfig, messages: [LLMMessage], stream: Bool) -> Data {
        var list: [[String: Any]] = []
        for m in messages {
            if m.images.isEmpty {
                list.append(["role": m.role.rawValue, "content": m.text])
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                for img in m.images {
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + img.base64EncodedString()]])
                }
                list.append(["role": m.role.rawValue, "content": parts])
            }
        }
        var body: [String: Any] = ["messages": list, "stream": stream, "temperature": config.temperature, "max_tokens": config.maxTokens]
        if !config.thinking { body["chat_template_kwargs"] = ["enable_thinking": false] }
        if !config.model.trimmingCharacters(in: .whitespaces).isEmpty { body["model"] = config.model.trimmingCharacters(in: .whitespaces) }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Eine Zeile des Ereignisstroms („data: {…}“). Kommentarzeilen (OpenRouter schickt „: OPENROUTER PROCESSING“) und leere Zeilen ergeben nichts.
    /// Eine Zeile kann Text und Ende-Grund zugleich tragen.
    public static func parseStreamEvents(_ raw: String) -> [LLMStreamEvent] {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }
        guard let data = payload.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if let err = obj["error"] as? [String: Any] { return [.error(err["message"] as? String ?? "Fehler vom Server")] }
        if let err = obj["error"] as? String { return [.error(err)] }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return [] }
        var out: [LLMStreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty { out.append(.reasoning(r)) }
            if let t = delta["content"] as? String, !t.isEmpty { out.append(.text(t)) }
        }
        if let err = choice["error"] as? [String: Any] { out.append(.error(err["message"] as? String ?? "Fehler vom Server")) }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { out.append(.finish(reason)) }
        return out
    }

    /// Das erste Ereignis einer Zeile (nil, wenn keines)
    public static func parseStreamLine(_ raw: String) -> LLMStreamEvent? { parseStreamEvents(raw).first }

    /// Antwort ohne Strom (`stream: false`)
    public static func parseResponse(_ data: Data) -> LLMStreamEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .error("Antwort nicht lesbar") }
        if let err = obj["error"] as? [String: Any] { return .error(err["message"] as? String ?? "Fehler vom Server") }
        if let msg = ((obj["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any], let t = msg["content"] as? String { return .text(t) }
        return .error("Antwort ohne Text")
    }

    /// Modellliste (`GET /models`): OpenAI-Form `{"data":[{"id":…}]}`, llama-server zusätzlich `{"models":[…]}`
    public static func parseModels(_ data: Data) -> [LLMModelInfo] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let list = (obj["data"] as? [[String: Any]]) ?? (obj["models"] as? [[String: Any]]) ?? []
        return list.compactMap { m in
            guard let id = (m["id"] as? String) ?? (m["model"] as? String) ?? (m["name"] as? String) else { return nil }
            var vision: Bool?
            if let arch = m["architecture"] as? [String: Any], let inputs = arch["input_modalities"] as? [String] { vision = inputs.contains("image") }
            return LLMModelInfo(id: id, name: (m["name"] as? String) ?? id, vision: vision)
        }
    }

    /// Verständlicher Text zu einem HTTP-Fehler
    public static func errorText(status: Int, body: Data) -> String {
        var detail = ""
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let e = obj["error"] as? [String: Any] { detail = (e["message"] as? String) ?? "" }
            else if let e = obj["error"] as? String { detail = e }
            else if let e = obj["message"] as? String { detail = e }
        }
        if detail.isEmpty { detail = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let head: String
        switch status {
        case 401, 403: head = "Zugriff abgelehnt (API-Schlüssel fehlt oder ist ungültig)"
        case 402: head = "Kein Guthaben beim Anbieter"
        case 404: head = "Adresse oder Modell nicht gefunden"
        case 408, 504: head = "Der Server antwortet zu langsam"
        case 429: head = "Zu viele Anfragen oder Kontingent erschöpft"
        case 500...599: head = "Fehler im Server"
        default: head = "HTTP-Fehler \(status)"
        }
        return detail.isEmpty ? head : head + ": " + detail
    }
}
