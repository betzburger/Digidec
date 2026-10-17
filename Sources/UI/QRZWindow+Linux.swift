// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: QRZ.com-Abfrage im Standardbrowser statt in einem eingebetteten WebKit-Fenster
// (QRZ.com verlangt einen echten Browser mit Anmeldung und Einwilligung).
#if !canImport(WebKit)
import SwiftUI

@MainActor
final class QRZLookup: ObservableObject {
    static let shared = QRZLookup()

    /// Rufzeichen (auch mit Zusätzen oder SSID) nachschlagen; false, wenn es kein Rufzeichen ist
    @discardableResult
    func show(_ raw: String) -> Bool {
        guard let call = QRZ.baseCall(raw), let url = QRZ.url(for: call) else { return false }
        PlatformOpener.open(url)
        return true
    }
}

struct QRZButton: View {
    let text: String

    var body: some View {
        let calls = QRZ.callsigns(in: text)
        if calls.count == 1, let call = calls.first {
            Button { QRZLookup.shared.show(call) } label: { label }
                .buttonStyle(.plain)
                .help("\(call) bei QRZ.com nachschlagen")
        } else if calls.count > 1 {
            Menu {
                ForEach(calls, id: \.self) { call in
                    Button("\(call) bei QRZ.com nachschlagen") { QRZLookup.shared.show(call) }
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
}
#endif
