// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

/// Empfangstext als NSTextView: hängt neuen Text an, ohne den ganzen Inhalt neu aufzubauen,
/// scrollt mit, solange man am Ende steht, und lässt Markieren und Kopieren zu.
struct ReceiveTextView: NSViewRepresentable {
    let model: ReceiveTextModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = Self.font
        tv.textColor = Self.color
        tv.string = model.text

        let coordinator = context.coordinator
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.scrollView = scroll
        model.onAppend = { [weak coordinator] s, decoded in coordinator?.append(s, decoded: decoded) }
        model.onClear = { [weak coordinator] in coordinator?.clear() }
        model.onReveal = { [weak coordinator] id in coordinator?.reveal(station: id) ?? false }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    static var color: NSColor { NSColor(ThemeModel.shared.palette.vfdGreen) }
    /// SYNOP-Klartext: etwas kleiner, in Amber
    static let decodedFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static var decodedColor: NSColor { NSColor(ThemeModel.shared.palette.vfdAmber) }
    /// Kennzeichnet Klartext (SYNOP): nur damit lassen sich die Farben beim Wechsel des Themes neu setzen
    static let decodedKey = NSAttributedString.Key("digidecDecoded")

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        override init() {
            super.init()
            // schwach gehalten: nach dem Abbau der Ansicht tut der Beobachter nichts mehr
            NotificationCenter.default.addObserver(forName: ThemeModel.notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recolor() }
            }
        }

        /// Farben des vorhandenen Textes dem neuen Theme anpassen
        private func recolor() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            tv.textColor = ReceiveTextView.color
            storage.beginEditing()
            storage.enumerateAttribute(ReceiveTextView.decodedKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                let color = (value as? Bool) == true ? ReceiveTextView.decodedColor : ReceiveTextView.color
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
        }

        func append(_ s: String, decoded: Bool) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let atEnd = isScrolledToEnd
            let attrs: [NSAttributedString.Key: Any] = decoded
                ? [.font: ReceiveTextView.decodedFont, .foregroundColor: ReceiveTextView.decodedColor, ReceiveTextView.decodedKey: true]
                : [.font: ReceiveTextView.font, .foregroundColor: ReceiveTextView.color]
            // Klartext auf eigenen Zeilen
            let text = decoded && !(storage.string.hasSuffix("\n") || storage.length == 0) ? "\n" + s : s
            storage.append(NSAttributedString(string: text, attributes: attrs))
            if atEnd { tv.scrollToEndOfDocument(nil) }
        }

        func clear() {
            textView?.string = ""
        }

        /// Kontextmenü: markierten Text (oder ohne Markierung den letzten Teil) dem KI-Assistenten vorlegen
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let hasSelection = view.selectedRange().length > 0
            let item = NSMenuItem(title: String(localized: hasSelection ? "KI fragen: markierter Text …" : "KI fragen: letzter Text …"), action: #selector(askAssistant(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func askAssistant(_ sender: Any?) {
            guard let tv = textView else { return }
            let all = tv.string as NSString
            var range = tv.selectedRange()
            if range.length == 0 {
                let len = min(all.length, 1500)
                range = NSRange(location: all.length - len, length: len)
            }
            let before = all.substring(with: NSRange(location: max(0, range.location - 1500), length: range.location - max(0, range.location - 1500)))
            let afterStart = range.location + range.length
            let after = all.substring(with: NSRange(location: afterStart, length: min(1500, all.length - afterStart)))
            DigidecState.shared.assistant.askAboutText(selection: all.substring(with: range), before: before, after: after)
        }

        /// Die Rohmeldung der Station im angezeigten Text markieren und ins Bild holen
        func reveal(station id: String) -> Bool {
            guard let tv = textView, let range = SynopRawLocator.find(id: id, in: tv.string) else { return false }
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
            tv.showFindIndicator(for: range)
            return true
        }

        private var isScrolledToEnd: Bool {
            guard let scroll = scrollView, let doc = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            return visible.maxY >= doc.bounds.maxY - 24
        }
    }
}
