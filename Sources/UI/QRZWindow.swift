// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import WebKit
import AppKit

// MARK: - Abfrage

/// Zeigt die QRZ.com-Seite eines Rufzeichens in einem eigenen Fenster. Die Seite wird erst geladen, wenn ein Knopf gedrückt wird.
/// Die Browsersitzung bleibt erhalten: wer sich bei QRZ.com anmeldet (für die vollen Angaben) oder das Einwilligungsbanner beantwortet, muss das nur einmal tun.
@MainActor
final class QRZLookup: NSObject, ObservableObject {
    static let shared = QRZLookup()

    @Published private(set) var current: String?
    @Published private(set) var history: [String] = []
    @Published var input = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: String?
    let web: WKWebView

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // QRZ.com (Cloudflare) behandelt Browser ohne Safari-Kennung als Roboter
        config.applicationNameForUserAgent = "Version/17.5 Safari/605.1.15"
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }

    /// Rufzeichen (auch mit Zusätzen oder SSID) nachschlagen; false, wenn es kein Rufzeichen ist
    @discardableResult
    func show(_ raw: String) -> Bool {
        guard let call = QRZ.baseCall(raw), let url = QRZ.url(for: call) else { return false }
        current = call
        input = call
        history.removeAll { $0 == call }
        history.insert(call, at: 0)
        if history.count > 12 { history.removeLast(history.count - 12) }
        failure = nil
        web.load(URLRequest(url: url))
        return true
    }

    func goBack() { web.goBack() }
    func goForward() { web.goForward() }
    func reload() { web.reload() }
    func openInBrowser() {
        if let url = web.url ?? current.flatMap({ QRZ.url(for: $0) }) { NSWorkspace.shared.open(url) }
    }

    fileprivate func refreshState() {
        loading = web.isLoading
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
    }

    /// Nur Seiten von qrz.com bleiben im Fenster, alles andere öffnet im Standardbrowser
    fileprivate static func isQRZ(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "qrz.com" || host.hasSuffix(".qrz.com")
    }
}

extension QRZLookup: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = !isMainFrame || url?.scheme == "about" || Self.isQRZ(url)
        if !allowed, let url, navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refreshState() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = nil; refreshState() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        refreshState()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        refreshState()
    }

    /// Links mit target=_blank: Seiten von QRZ.com im selben Fenster, andere im Standardbrowser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.isQRZ(url) { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }
}

// MARK: - Fenster

private struct QRZWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Fenster „QRZ.com“: Eingabefeld, die zuletzt abgefragten Rufzeichen und die Seite von QRZ.com
struct QRZWindow: View {
    @ObservedObject var lookup: QRZLookup

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(RadioTheme.borderSubtle).frame(height: 1)
            ZStack {
                QRZWebView(web: lookup.web)
                if lookup.current == nil { hint }
                if let failure = lookup.failure, lookup.current != nil {
                    VStack {
                        Text("Die Seite lässt sich nicht laden: \(failure)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(RadioTheme.ledRed)
                            .padding(8)
                            .background(RadioTheme.bgPanel.opacity(0.92))
                            .cornerRadius(5)
                        Spacer()
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(RadioTheme.bgPanel)
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("QRZ.COM")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                TextField("Rufzeichen", text: $lookup.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .frame(width: 150)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(5)
                    .onSubmit { lookup.show(lookup.input) }
                    .help("Rufzeichen eintippen und mit Return nachschlagen (Zusätze wie /P und -9 werden entfernt)")
                Button("SUCHEN") { lookup.show(lookup.input) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(QRZ.baseCall(lookup.input) == nil)
                Divider().frame(height: 18)
                Button("◀") { lookup.goBack() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(!lookup.canGoBack)
                    .help("Zurück")
                Button("▶") { lookup.goForward() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(!lookup.canGoForward)
                    .help("Vor")
                Button(lookup.loading ? "LÄDT …" : "NEU LADEN") { lookup.reload() }
                    .buttonStyle(ModeButtonStyle(isSelected: lookup.loading))
                    .disabled(lookup.current == nil)
                Button("IM BROWSER") { lookup.openInBrowser() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(lookup.current == nil)
                    .help("Die Seite im Standardbrowser öffnen")
                Spacer()
            }
            if !lookup.history.isEmpty {
                HStack(spacing: 6) {
                    Text("ZULETZT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    ForEach(lookup.history, id: \.self) { call in
                        Button(call) { lookup.show(call) }
                            .buttonStyle(ModeButtonStyle(isSelected: call == lookup.current))
                            .scaleEffect(0.85)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Text("QRZ.com")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text("Rufzeichen oben eintippen oder in einer Liste auf QRZ drücken.\nDie Seite wird erst dann von qrz.com geladen; für die vollen Angaben meldest du dich dort an (die Anmeldung bleibt erhalten).")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadioTheme.bgPanel)
    }
}

// MARK: - Knopf

/// Kleiner Knopf „QRZ“ neben einem Rufzeichen oder einer Meldung. Steht ein Rufzeichen darin, schlägt der Knopf es nach; sind es mehrere
/// (FT8: „DL1ABC DK2XYZ −12“), wählt ein Menü. Ohne Rufzeichen im Text erscheint nichts.
struct QRZButton: View {
    /// Rufzeichen oder Text, in dem Rufzeichen vorkommen
    let text: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let calls = QRZ.callsigns(in: text)
        if calls.count == 1, let call = calls.first {
            Button { open(call) } label: { label }
                .buttonStyle(.plain)
                .help("\(call) bei QRZ.com nachschlagen")
        } else if calls.count > 1 {
            Menu {
                ForEach(calls, id: \.self) { call in
                    Button("\(call) bei QRZ.com nachschlagen") { open(call) }
                }
            } label: { label }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rufzeichen bei QRZ.com nachschlagen: " + calls.joined(separator: ", "))
        }
    }

    private var label: some View {
        Text("QRZ")
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundColor(RadioTheme.vfdCyan)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(RadioTheme.vfdCyan.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func open(_ call: String) {
        if QRZLookup.shared.show(call) { openWindow(id: "qrz") }
    }
}

/// Menüeintrag „Rufzeichen bei QRZ.com nachschlagen …“ (⇧⌘K): öffnet das Fenster mit dem Eingabefeld
struct QRZCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Rufzeichen bei QRZ.com nachschlagen …") { openWindow(id: "qrz") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
