// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: Empfangstext in der Textfläche des Frontends (RichTextView) statt in einem NSTextView.
#if !canImport(AppKit)
import SwiftUI

@MainActor
final class ReceiveTextHolder {
    let buffer = RichTextBuffer()
    private var theme = ""
    private weak var installedModel: ReceiveTextModel?

    static var normalColor: Color { Color(ThemeModel.shared.palette.vfdGreen) }
    static var decodedColor: Color { Color(ThemeModel.shared.palette.vfdAmber) }

    func install(_ model: ReceiveTextModel) {
        let themeKey = ThemeModel.shared.theme.rawValue
        if installedModel !== model {
            installedModel = model
            buffer.clear()
            buffer.append(model.text, color: Self.normalColor, size: 13, weight: .medium)
            theme = themeKey
            model.onAppend = { [weak self] s, decoded in self?.append(s, decoded: decoded) }
            model.onClear = { [weak self] in self?.buffer.clear() }
            model.onReveal = { [weak self] id in self?.reveal(station: id, model: model) ?? false }
        }
        if themeKey != theme {
            theme = themeKey
            buffer.recolor { $0.tag ? Self.decodedColor : Self.normalColor }
        }
    }

    private func append(_ s: String, decoded: Bool) {
        if decoded {
            let text = (buffer.text.isEmpty || buffer.text.hasSuffix("\n")) ? s : "\n" + s
            buffer.append(text, color: Self.decodedColor, size: 11.5, weight: .regular, tag: true)
        } else {
            buffer.append(s, color: Self.normalColor, size: 13, weight: .medium)
        }
    }

    private func reveal(station id: String, model: ReceiveTextModel) -> Bool {
        let text = buffer.text
        guard let ns = SynopRawLocator.find(id: id, in: text), let range = Range(ns, in: text) else { return false }
        let lower = text.utf8.distance(from: text.startIndex, to: range.lowerBound), upper = text.utf8.distance(from: text.startIndex, to: range.upperBound)
        buffer.reveal(range: lower..<upper)
        return true
    }

    /// Kontextmenü: markierten Text (oder ohne Markierung den letzten Teil) dem KI-Assistenten vorlegen
    func menu() -> [(title: String, action: () -> Void)] {
        let hasSelection = buffer.selectedText != nil
        return [(String(localized: hasSelection ? "KI fragen: markierter Text …" : "KI fragen: letzter Text …"), { [weak self] in self?.askAssistant() })]
    }

    private func askAssistant() {
        let all = buffer.text
        let chars = Array(all)
        var lower: Int, upper: Int
        if let selected = buffer.selectedText, let r = all.range(of: selected) {
            lower = all.distance(from: all.startIndex, to: r.lowerBound); upper = lower + selected.count
        } else {
            upper = chars.count; lower = max(0, upper - 1500)
        }
        let before = String(chars[max(0, lower - 1500)..<lower])
        let after = String(chars[upper..<min(chars.count, upper + 1500)])
        DigidecState.shared.assistant.askAboutText(selection: String(chars[lower..<upper]), before: before, after: after)
    }
}

struct ReceiveTextView: View {
    let model: ReceiveTextModel
    @State private var holder = ReceiveTextHolder()

    var body: some View {
        holder.install(model)
        return RichTextView(buffer: holder.buffer, inset: 8, onMenu: { _ in holder.menu() })
    }
}
#endif
