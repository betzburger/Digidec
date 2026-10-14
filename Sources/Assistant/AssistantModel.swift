// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI
import Combine

/// Gespräch mit dem KI-Assistenten: hält den Verlauf, bereitet Fragen mit Kontext vor (Signal, Text), schickt sie an den Server und zeigt die Antwort Stück für Stück.
/// Nichts geht ohne Druck auf SENDEN hinaus; der Kontext steht vorher sichtbar im Fenster.
@MainActor
public final class AssistantModel: ObservableObject {
    public struct Turn: Identifiable, Equatable {
        public let id = UUID()
        public var role: LLMRole
        /// Angezeigter Text (bei Fragen: die Frage des Nutzers)
        public var text: String
        /// Was tatsächlich gesendet wurde (Kontext und Frage), für den Verlauf und zur Ansicht
        public var sent: String = ""
        public var title: String?
        public var hadImage = false
        public var imageData: Data?
        /// Gedankengang eines Denkmodells (nicht die Antwort)
        public var thought = ""
        public var isStreaming = false
        public var failed = false
        /// Beginn der Anfrage (für die Wartezeit-Anzeige)
        public var startedAt = Date()
    }

    @Published public private(set) var turns: [Turn] = []
    /// Vorbereiteter Kontext, noch nicht gesendet
    @Published public var pending: AssistantContext?
    @Published public var includeImage = false
    @Published public var input = ""
    @Published public private(set) var isBusy = false
    @Published public private(set) var isThinking = false
    @Published public var notice: String?
    /// Zählt hoch, wenn das Fenster nach vorn soll (das Hauptfenster öffnet es)
    @Published public private(set) var showRequest = 0

    // Einstellungen (gespiegelt, damit die Oberfläche sie binden kann)
    @Published public var provider: LLMProvider { didSet { guard provider != oldValue else { return }; store.provider = provider; loadServerFields() } }
    @Published public var baseURL: String { didSet { store.setBaseURL(baseURL, for: provider) } }
    @Published public var modelName: String { didSet { store.setModel(modelName, for: provider) } }
    @Published public var sendImageDefault: Bool { didSet { store.sendImage = sendImageDefault } }
    @Published public var sendLocation: Bool { didSet { store.sendLocation = sendLocation } }
    /// Obergrenze der Antwort in Token; bei Denkmodellen zählt das Nachdenken mit
    @Published public var maxTokens: Int { didSet { store.maxTokens = maxTokens } }
    @Published public var thinking: Bool { didSet { store.thinking = thinking } }
    @Published public var keyDraft = ""
    @Published public private(set) var models: [LLMModelInfo] = []
    @Published public private(set) var modelsLoading = false
    @Published public private(set) var testResult: String?

    private let store = LLMSettingsStore()
    /// Nur für Prüfläufe: ersetzt die gespeicherte Verbindung
    var overrideConfig: LLMConfig?
    private var keyLoaded = false
    private var task: Task<Void, Never>?
    /// Zustand des Empfängers für den Kontext; setzt `DigidecState`
    var tuningProvider: (() -> AssistantTuning)?
    var moduleNames: [String] = DecoderModuleInfo.allCases.map(\.displayName)

    public init() {
        let p = store.provider
        provider = p
        baseURL = store.baseURL(for: p)
        modelName = store.model(for: p)
        sendImageDefault = store.sendImage
        sendLocation = store.sendLocation
        maxTokens = store.maxTokens
        thinking = store.thinking
    }

    private func loadServerFields() {
        baseURL = store.baseURL(for: provider)
        modelName = store.model(for: provider)
        keyLoaded = false
        keyDraft = ""
        models = []
        testResult = nil
        loadKey()
    }

    /// Schlüssel aus dem Schlüsselbund in das Feld holen (erst wenn die Einstellungen offen sind, damit der Start nichts abfragt)
    public func loadKey() {
        guard !keyLoaded else { return }
        keyLoaded = true
        keyDraft = LLMKeychain.key(for: provider)
    }

    public func commitKey() {
        guard keyLoaded else { return }
        LLMKeychain.setKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
    }

    private func currentConfig() -> LLMConfig {
        if let overrideConfig { return overrideConfig }
        let key = keyLoaded ? keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) : LLMKeychain.key(for: provider)
        return store.config(apiKey: key)
    }

    public var hasImageSupportHint: Bool { models.first { $0.id == modelName }?.vision ?? false }

    // MARK: Fragen vorbereiten

    /// Frage mit Kontext vorbereiten und das Fenster zeigen; gesendet wird erst auf Knopfdruck
    public func stage(_ context: AssistantContext) {
        pending = context
        includeImage = context.image != nil && sendImageDefault
        if input.isEmpty { input = context.suggestedQuestion }
        showRequest += 1
    }

    /// Markierten Text samt Umgebung vorlegen
    public func askAboutText(selection: String, before: String, after: String) {
        let t = tuning() ?? AssistantTuning(moduleName: "?")
        stage(AssistantContextBuilder.text(selection: selection, before: before, after: after, tuning: t))
    }

    public func stageGeneral() {
        guard let t = tuning() else { return }
        pending = AssistantContextBuilder.general(tuning: t)
        includeImage = false
        showRequest += 1
    }

    public func tuning() -> AssistantTuning? {
        guard var t = tuningProvider?() else { return nil }
        if !sendLocation { t.locator = nil }
        return t
    }

    public func discardPending() {
        pending = nil
        includeImage = false
    }

    // MARK: Senden

    public func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !question.isEmpty else { return }
        notice = nil
        let cfg = currentConfig()
        if cfg.model.trimmingCharacters(in: .whitespaces).isEmpty && provider == .openRouter {
            notice = "Bei OpenRouter muss ein Modell eingetragen sein (Einstellungen)."
            return
        }
        if provider.isCloud && cfg.apiKey.isEmpty {
            notice = "Für OpenRouter fehlt der API-Schlüssel (Einstellungen)."
            return
        }
        let ctx = pending
        let image = (includeImage ? ctx?.image : nil)
        var sent = question
        if let ctx { sent = ctx.text + "\n\nFrage des Nutzers:\n" + question }

        // Verlauf: Systemanweisung, frühere Fragen und Antworten (ohne Bilder), die neue Frage
        var messages = [LLMMessage(.system, AssistantPrompt.system(moduleNames: moduleNames, language: Locale.preferredLanguages.first ?? "de"))]
        for t in turns.suffix(12) where !t.failed && !t.text.isEmpty {
            messages.append(LLMMessage(t.role, t.role == .user ? (t.sent.isEmpty ? t.text : t.sent) : t.text))
        }
        messages.append(LLMMessage(.user, sent, images: image.map { [$0] } ?? []))

        var userTurn = Turn(role: .user, text: question, sent: sent, title: ctx?.title)
        userTurn.hadImage = image != nil
        userTurn.imageData = image
        turns.append(userTurn)
        turns.append(Turn(role: .assistant, text: "", isStreaming: true))
        let index = turns.count - 1
        input = ""
        pending = nil
        includeImage = false
        isBusy = true
        isThinking = false

        task = Task { [weak self] in
            var failed = false
            var truncated = false
            do {
                for try await event in LLMClient().stream(config: cfg, messages: messages) {
                    guard let self else { return }
                    switch event {
                    case .text(let t): self.isThinking = false; self.turns[index].text += t
                    case .reasoning(let r): self.isThinking = true; self.turns[index].thought += r
                    case .finish(let reason): truncated = (reason == "length")
                    case .error(let m): self.notice = m; failed = true
                    case .done: break
                    }
                }
            } catch {
                self?.notice = error.localizedDescription
                failed = true
            }
            guard let self else { return }
            self.finish(index: index, failed: failed, truncated: truncated)
        }
    }

    private func finish(index: Int, failed: Bool, truncated: Bool) {
        if turns.indices.contains(index) {
            turns[index].isStreaming = false
            if turns[index].text.isEmpty {
                // Leere Antwort: Fehlertext stehen lassen, den leeren Beitrag entfernen
                turns[index].failed = true
                if truncated { notice = "Die Grenze für die Antwortlänge war erreicht, bevor das Modell zu antworten begann (Denkmodelle zählen das Nachdenken mit). Antwortlänge in den Einstellungen erhöhen." }
                else if !failed { notice = "Der Server hat nichts geantwortet." }
            } else if failed {
                turns[index].failed = true
            } else if truncated {
                notice = "Die Antwort wurde an der Längengrenze abgeschnitten. Antwortlänge in den Einstellungen erhöhen."
            }
        }
        isBusy = false
        isThinking = false
        task = nil
    }

    public func cancel() {
        task?.cancel()
        if let i = turns.indices.last, turns[i].isStreaming { turns[i].isStreaming = false }
        isBusy = false
        isThinking = false
    }

    public func clear() {
        cancel()
        turns = []
        pending = nil
        notice = nil
    }

    // MARK: Verbindung

    public func fetchModels() {
        commitKey()
        modelsLoading = true
        testResult = nil
        let cfg = currentConfig()
        Task { [weak self] in
            do {
                let list = try await LLMClient(timeout: 20).models(config: cfg)
                self?.models = list.sorted { $0.id < $1.id }
                self?.testResult = list.isEmpty ? "Verbindung steht, der Server nennt aber keine Modelle." : "Verbindung steht: \(list.count) Modelle."
                if let self, self.modelName.isEmpty, self.provider == .llamaServer, let first = list.first { self.modelName = first.id }
            } catch {
                self?.testResult = error.localizedDescription
            }
            self?.modelsLoading = false
        }
    }
}
