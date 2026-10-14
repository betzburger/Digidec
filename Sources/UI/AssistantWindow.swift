// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Fenster „KI-Assistent“

/// Fragen zu Signalen im Wasserfall und zu decodierten Texten an einen KI-Server. Der Kontext einer Frage steht vor dem Senden sichtbar im Fenster.
struct AssistantWindow: View {
    @ObservedObject var model: AssistantModel
    @State private var showSettings = false
    @State private var showModels = false

    private var configured: Bool { !model.baseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            RadioTheme.bgPanel.ignoresSafeArea()
            VStack(spacing: 8) {
                header
                if showSettings { settings }
                transcript
                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.ledYellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let ctx = model.pending { pendingCard(ctx) }
                inputBar
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 560)
        .preferredColorScheme(.dark)
        .onAppear { if model.baseURL.isEmpty { showSettings = true } }
        .onDisappear { model.commitKey() }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(RadioTheme.vfdCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("KI-ASSISTENT")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                    .tracking(1.2)
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .lineLimit(1)
            }
            Text(model.provider.isCloud ? "CLOUD" : "LOKAL")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(model.provider.isCloud ? RadioTheme.vfdAmber : RadioTheme.vfdGreen)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RadioTheme.bgDeep)
                .cornerRadius(3)
                .help(model.provider.isCloud ? "Der Server steht im Internet: Messwerte, Texte und Bilder gehen an einen Dritten" : "Der Server läuft im eigenen Netz")
            Spacer()
            ButtonGrid {
                Button { showSettings.toggle(); if showSettings { model.loadKey() } } label: {
                    HStack(spacing: 4) { Image(systemName: "gearshape").font(.system(size: 9, weight: .bold)); Text("EINSTELLUNGEN") }
                }
                .buttonStyle(ModeButtonStyle(isSelected: showSettings, compact: true))
                Button { model.clear() } label: {
                    HStack(spacing: 4) { Image(systemName: "trash").font(.system(size: 9, weight: .bold)); Text("LEEREN") }
                }
                .buttonStyle(ModeButtonStyle(isSelected: false, compact: true))
                .disabled(model.turns.isEmpty && model.pending == nil)
                .help("Gespräch und vorbereitete Frage verwerfen")
            }
        }
    }

    private var summary: String {
        let m = model.modelName.isEmpty ? "Modell des Servers" : model.modelName
        return "\(model.provider.title) · \(m)"
    }

    // MARK: Einstellungen

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            ButtonGrid(columns: .fill(3)) {
                ForEach(LLMProvider.allCases) { p in
                    Button(p.title) { model.commitKey(); model.provider = p; model.loadKey() }
                        .buttonStyle(ModeButtonStyle(isSelected: model.provider == p, compact: true))
                }
            }
            field("ADRESSE", help: "OpenAI-kompatible Adresse, z. B. http://127.0.0.1:8080/v1 (llama-server) oder https://openrouter.ai/api/v1") {
                TextField("http://127.0.0.1:8080/v1", text: $model.baseURL)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            field("MODELL", help: model.provider == .llamaServer ? "Leer lassen: llama-server nimmt das geladene Modell" : "Modellname, bei OpenRouter z. B. anbieter/modell") {
                HStack(spacing: 6) {
                    TextField(model.provider == .llamaServer ? "(das geladene Modell)" : "anbieter/modell", text: $model.modelName)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                    Button {
                        model.fetchModels()
                        showModels = true
                    } label: { Text(model.modelsLoading ? "…" : "LISTE") }
                        .buttonStyle(ModeButtonStyle(isSelected: false, compact: true))
                        .frame(width: 60)
                        .help("Modelle des Servers laden und eines wählen (prüft zugleich die Verbindung)")
                        .popover(isPresented: $showModels, arrowEdge: .bottom) { ModelPicker(model: model, isPresented: $showModels) }
                }
            }
            field("API-SCHLÜSSEL", help: "Liegt im Schlüsselbund. llama-server braucht einen, wenn er mit --api-key oder --api-key-file gestartet wurde") {
                SecureField(model.provider.isCloud ? "sk-or-…" : "(nur wenn der Server --api-key nutzt)", text: $model.keyDraft)
                    .textFieldStyle(.plain)
                    .onSubmit { model.commitKey() }
            }
            field("ANTWORTLÄNGE", help: "Obergrenze der Antwort in Token. Denkmodelle brauchen viel, weil das Nachdenken mitzählt (z. B. 4000 bis 8000)") {
                TextField("4000", value: $model.maxTokens, format: .number.grouping(.never))
                    .textFieldStyle(.plain)
            }
            Toggle(isOn: $model.thinking) {
                Text("Denkmodelle nachdenken lassen (aus = schneller, nur llama-server)").font(.system(size: 10, design: .monospaced))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $model.sendImageDefault) {
                Text("Wasserfall-Ausschnitt als Bild mitsenden (Modell mit Bildeingang nötig)").font(.system(size: 10, design: .monospaced))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $model.sendLocation) {
                Text("Eigenen Standort (Locator) mitsenden").font(.system(size: 10, design: .monospaced))
            }
            .toggleStyle(.checkbox)
            if model.provider.isCloud {
                Text("OpenRouter ist ein Dienst im Internet: Messwerte, markierte Texte und – wenn eingeschaltet – Bilder und Standort gehen an OpenRouter und den Anbieter des Modells. Vor jedem Senden zeigt dieses Fenster genau, was gesendet wird.")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }
            if let r = model.testResult {
                Text(r).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textMuted).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RadioTheme.bgCard)
        .cornerRadius(6)
    }

    private func field<Content: View>(_ title: LocalizedStringKey, help: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 96, alignment: .leading)
            content()
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RadioTheme.bgDeep)
                .cornerRadius(4)
        }
        .help(help)
    }

    // MARK: Gespräch

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.turns.isEmpty { emptyHint }
                    ForEach(model.turns) { turn in
                        if !(turn.role == .assistant && turn.text.isEmpty && !turn.isStreaming) { bubble(turn).id(turn.id) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(2)
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
            .onChange(of: model.turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("So fragst du:")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
            Text("• Rechtsklick in den HF-Wasserfall auf ein Signal: „KI fragen: Signal …“\n• Text im Empfangsfenster markieren, Rechtsklick: „KI fragen …“\n• oder hier direkt eine Frage stellen")
            Text("Digidec misst das Signal selbst (Mitte, Bandbreite, Linien, Tastung, Drift) und schickt die Werte als Text mit. Das Modell kombiniert sie mit seinem Wissen; seine Antwort ist eine Vermutung, keine Messung.")
                .foregroundColor(RadioTheme.textDim)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(RadioTheme.textMuted)
        .padding(10)
    }

    @ViewBuilder
    private func bubble(_ t: AssistantModel.Turn) -> some View {
        if t.role == .user {
            VStack(alignment: .leading, spacing: 4) {
                Text("DU").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdAmber).tracking(1)
                Text(t.text).font(.system(size: 12, design: .monospaced)).foregroundColor(RadioTheme.textBright).textSelection(.enabled)
                if let title = t.title {
                    DisclosureGroup {
                        Text(t.sent).font(.system(size: 9.5, design: .monospaced)).foregroundColor(RadioTheme.textMuted).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let d = t.imageData, let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 180).cornerRadius(3)
                        }
                    } label: {
                        Text("Gesendet: \(title)" + (t.hadImage ? " + Bild" : ""))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RadioTheme.bgCard)
            .cornerRadius(6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("KI").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan).tracking(1)
                    if t.isStreaming { ProgressView().controlSize(.mini) }
                    if t.isStreaming && t.text.isEmpty {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let s = Int(ctx.date.timeIntervalSince(t.startedAt))
                            Text(model.isThinking ? "denkt … \(s) s" : "wartet auf den Server … \(s) s" + (s >= 30 ? " (Router-Server laden beim ersten Aufruf das Modell; hängt es, im Server-Protokoll nachsehen)" : ""))
                                .font(.system(size: 9, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                        }
                    }
                }
                if !t.thought.isEmpty {
                    DisclosureGroup {
                        Text(t.thought).font(.system(size: 9.5, design: .monospaced)).foregroundColor(RadioTheme.textDim).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Gedankengang (\(t.thought.count) Zeichen)").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                    }
                }
                Text(Self.markdown(t.text))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(t.failed ? RadioTheme.textDim : RadioTheme.vfdGreen)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func markdown(_ s: String) -> AttributedString { AssistantMarkdown.render(s) }

    // MARK: Vorbereitete Frage

    private func pendingCard(_ ctx: AssistantContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WIRD MITGESENDET")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdAmber).tracking(1)
                Text(ctx.title).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textBright).lineLimit(1)
                Spacer()
                Button { model.discardPending() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ModeButtonStyle(isSelected: false, compact: true)).frame(width: 30)
                    .help("Kontext nicht mitsenden")
            }
            ScrollView {
                Text(ctx.text)
                    .font(.system(size: 9.5, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            if let data = ctx.image, let img = NSImage(data: data) {
                HStack(alignment: .top, spacing: 8) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 90).cornerRadius(3).opacity(model.includeImage ? 1 : 0.35)
                    Toggle(isOn: $model.includeImage) {
                        Text("Bild mitsenden").font(.system(size: 10, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .help("Nur Modelle mit Bildeingang können das Bild lesen; sonst aus lassen")
                }
            }
        }
        .padding(9)
        .background(RadioTheme.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RadioTheme.vfdAmber.opacity(0.5), lineWidth: 1))
        .cornerRadius(6)
    }

    // MARK: Eingabe

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $model.input)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(minHeight: 54, maxHeight: 110)
                .background(RadioTheme.bgDeep)
                .cornerRadius(5)
            if model.isBusy {
                Button { model.cancel() } label: { Text("STOPP") }
                    .buttonStyle(ModeButtonStyle(isSelected: true))
                    .frame(width: 90)
            } else {
                Button { model.commitKey(); model.send() } label: { Text("SENDEN") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .frame(width: 90)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !configured)
                    .help("Frage senden (⌘↩)")
            }
        }
    }
}

/// Liste der Modelle eines Servers mit Suche
private struct ModelPicker: View {
    @ObservedObject var model: AssistantModel
    @Binding var isPresented: Bool
    @State private var filter = ""

    private var list: [LLMModelInfo] {
        let f = filter.lowercased()
        return f.isEmpty ? model.models : model.models.filter { $0.id.lowercased().contains(f) || $0.name.lowercased().contains(f) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Suchen", text: $filter).textFieldStyle(.roundedBorder)
            if let r = model.testResult { Text(r).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
            List(list.prefix(300)) { m in
                Button {
                    model.modelName = m.id
                    isPresented = false
                } label: {
                    HStack {
                        Text(m.id).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        if m.vision == true { Text("BILD").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan) }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 420, height: 300)
        }
        .padding(10)
    }
}
