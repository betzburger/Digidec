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
        coordinator.textView = tv
        coordinator.scrollView = scroll
        model.onAppend = { [weak coordinator] s, decoded in coordinator?.append(s, decoded: decoded) }
        model.onClear = { [weak coordinator] in coordinator?.clear() }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    static let color = NSColor(red: 0.00, green: 0.95, blue: 0.45, alpha: 1)   // RadioTheme.vfdGreen
    /// SYNOP-Klartext: etwas kleiner, in Amber
    static let decodedFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let decodedColor = NSColor(red: 1.00, green: 0.72, blue: 0.10, alpha: 1)   // RadioTheme.vfdAmber

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        func append(_ s: String, decoded: Bool) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let atEnd = isScrolledToEnd
            let attrs: [NSAttributedString.Key: Any] = decoded
                ? [.font: ReceiveTextView.decodedFont, .foregroundColor: ReceiveTextView.decodedColor]
                : [.font: ReceiveTextView.font, .foregroundColor: ReceiveTextView.color]
            // Klartext auf eigenen Zeilen
            let text = decoded && !(storage.string.hasSuffix("\n") || storage.length == 0) ? "\n" + s : s
            storage.append(NSAttributedString(string: text, attributes: attrs))
            if atEnd { tv.scrollToEndOfDocument(nil) }
        }

        func clear() {
            textView?.string = ""
        }

        private var isScrolledToEnd: Bool {
            guard let scroll = scrollView, let doc = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            return visible.maxY >= doc.bounds.maxY - 24
        }
    }
}
