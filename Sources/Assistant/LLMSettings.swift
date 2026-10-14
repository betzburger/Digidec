// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Einstellungen der KI-Anbindung. Adresse und Modell werden je Server gemerkt, damit der Wechsel zwischen
// llama-server und OpenRouter nichts verstellt. Der API-Schlüssel liegt nicht hier, sondern im Schlüsselbund (`LLMKeychain`).

public final class LLMSettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var provider: LLMProvider {
        get { LLMProvider(rawValue: defaults.string(forKey: "llm.provider") ?? "") ?? .llamaServer }
        set { defaults.set(newValue.rawValue, forKey: "llm.provider") }
    }

    public func baseURL(for p: LLMProvider) -> String { defaults.string(forKey: "llm.\(p.rawValue).baseURL") ?? p.defaultBaseURL }
    public func setBaseURL(_ v: String, for p: LLMProvider) { defaults.set(v, forKey: "llm.\(p.rawValue).baseURL") }

    public func model(for p: LLMProvider) -> String { defaults.string(forKey: "llm.\(p.rawValue).model") ?? "" }
    public func setModel(_ v: String, for p: LLMProvider) { defaults.set(v, forKey: "llm.\(p.rawValue).model") }

    /// Wasserfall-Ausschnitt als Bild mitsenden (nur sinnvoll bei Modellen mit Bildeingang)
    public var sendImage: Bool {
        get { defaults.object(forKey: "llm.sendImage") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "llm.sendImage") }
    }

    /// Eigenen Standort (Locator) mitsenden; standardmäßig aus
    public var sendLocation: Bool {
        get { defaults.object(forKey: "llm.sendLocation") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "llm.sendLocation") }
    }

    public var maxTokens: Int {
        get { let v = defaults.integer(forKey: "llm.maxTokens"); return v > 0 ? v : 4000 }
        set { defaults.set(max(100, newValue), forKey: "llm.maxTokens") }
    }

    /// Denkmodelle nachdenken lassen (Vorgabe); aus spart Zeit und Token
    public var thinking: Bool {
        get { defaults.object(forKey: "llm.thinking") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "llm.thinking") }
    }

    public func config(apiKey: String) -> LLMConfig {
        let p = provider
        return LLMConfig(baseURL: baseURL(for: p), apiKey: apiKey, model: model(for: p), maxTokens: maxTokens, thinking: thinking)
    }
}
