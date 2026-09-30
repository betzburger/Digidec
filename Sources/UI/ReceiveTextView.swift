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
        model.onAppend = { [weak coordinator] s in coordinator?.append(s) }
        model.onClear = { [weak coordinator] in coordinator?.clear() }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    static let color = NSColor(red: 0.00, green: 0.95, blue: 0.45, alpha: 1)   // RadioTheme.vfdGreen

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        func append(_ s: String) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let atEnd = isScrolledToEnd
            storage.append(NSAttributedString(string: s, attributes: [.font: ReceiveTextView.font,
                                                                       .foregroundColor: ReceiveTextView.color]))
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
