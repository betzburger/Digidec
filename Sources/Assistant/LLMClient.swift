// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if canImport(Darwin)
import Foundation

// Netzseite der KI-Anbindung: Anfrage an einen OpenAI-kompatiblen Server, Antwort als Strom.

public enum LLMClientError: Error, LocalizedError, Sendable {
    case badAddress
    case modelMissing
    case server(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badAddress: return "Die Serveradresse ist ungültig"
        case .modelMissing: return "Es ist kein Modell eingetragen"
        case .server(let t): return t
        case .network(let t): return t
        }
    }
}

public struct LLMClient: Sendable {
    public var session: URLSession
    /// Zeit bis zum ersten Byte und zwischen zwei Teilen der Antwort
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 180) {
        self.session = session
        self.timeout = timeout
    }

    private func request(_ url: URL, config: LLMConfig, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        if let body {
            r.httpMethod = "POST"
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !config.apiKey.isEmpty { r.setValue("Bearer " + config.apiKey, forHTTPHeaderField: "Authorization") }
        // OpenRouter zeigt damit die Herkunft der Anfragen an
        r.setValue("Digidec", forHTTPHeaderField: "X-Title")
        return r
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost: return "Keine Verbindung zum Server (läuft er, stimmen Adresse und Port?)"
            case .timedOut: return "Der Server antwortet nicht rechtzeitig"
            case .notConnectedToInternet: return "Keine Netzverbindung"
            case .appTransportSecurityRequiresSecureConnection: return "Unverschlüsselte Verbindung nicht erlaubt (Adresse mit https verwenden)"
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Frage senden, Antwort als Strom von Teilen. Das Ende kommt als `.done`; Fehler als `.error` oder als geworfener Fehler.
    public func stream(config: LLMConfig, messages: [LLMMessage]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = LLMProtocol.chatURL(base: config.baseURL) else { throw LLMClientError.badAddress }
                    let body = LLMProtocol.requestBody(config: config, messages: messages, stream: true)
                    let (bytes, response) = try await session.bytes(for: request(url, config: config, body: body))
                    guard let http = response as? HTTPURLResponse else { throw LLMClientError.network("Keine Antwort vom Server") }
                    guard http.statusCode == 200 else {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 4000 { break } }
                        throw LLMClientError.server(LLMProtocol.errorText(status: http.statusCode, body: data))
                    }
                    var finished = false
                    for try await line in bytes.lines {
                        for event in LLMProtocol.parseStreamEvents(line) {
                            continuation.yield(event)
                            if case .done = event { finished = true }
                            if case .error = event { finished = true }
                        }
                        if finished { break }
                    }
                    if !finished { continuation.yield(.done) }
                    continuation.finish()
                } catch let e as LLMClientError {
                    continuation.finish(throwing: e)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if (error as? URLError)?.code == .cancelled { continuation.finish() } else { continuation.finish(throwing: LLMClientError.network(describe(error))) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Modelle des Servers (`GET /models`)
    public func models(config: LLMConfig) async throws -> [LLMModelInfo] {
        guard let url = LLMProtocol.modelsURL(base: config.baseURL) else { throw LLMClientError.badAddress }
        do {
            let (data, response) = try await session.data(for: request(url, config: config))
            guard let http = response as? HTTPURLResponse else { throw LLMClientError.network("Keine Antwort vom Server") }
            guard http.statusCode == 200 else { throw LLMClientError.server(LLMProtocol.errorText(status: http.statusCode, body: data)) }
            return LLMProtocol.parseModels(data)
        } catch let e as LLMClientError {
            throw e
        } catch {
            throw LLMClientError.network(describe(error))
        }
    }
}
#endif
