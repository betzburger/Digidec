// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: der kleine Teil von AppKit, den die Oberfläche außerhalb der Ansichten benutzt (Dateimanager, Zwischenablage, Dateidialoge, Farben).
import Foundation
#if !canImport(AppKit)
import SwiftUI
import UniformTypeIdentifiers

final class NSWorkspace: @unchecked Sendable {
    static let shared = NSWorkspace()
    @discardableResult func open(_ url: URL) -> Bool { PlatformOpener.open(url); return true }
    /// Zeigt die Dateien im Dateimanager (der Ordner der ersten Datei wird geöffnet)
    func activateFileViewerSelecting(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory), isDirectory.boolValue { PlatformOpener.open(first) }
        else { PlatformOpener.open(first.deletingLastPathComponent()) }
    }
}

final class NSPasteboard: @unchecked Sendable {
    struct PasteboardType: Equatable { var rawValue: String; static let string = PasteboardType(rawValue: "string") }
    static let general = NSPasteboard()
    private var text: String?
    func clearContents() -> Int { text = nil; return 0 }
    @discardableResult func setString(_ string: String, forType type: PasteboardType) -> Bool { text = string; clipboardHook(string); return true }
    func string(forType type: PasteboardType) -> String? { text }
}

final class NSColor: @unchecked Sendable {
    let color: Color
    init(red: Double, green: Double, blue: Double, alpha: Double) { color = Color(red: red, green: green, blue: blue, opacity: alpha) }
    init(_ color: Color) { self.color = color }
    static var black: NSColor { NSColor(.black) }
    static var white: NSColor { NSColor(.white) }
    func withAlphaComponent(_ a: Double) -> NSColor { NSColor(color.opacity(a)) }
}

extension Color { init(nsColor: NSColor) { self = nsColor.color } }

class NSSavePanel: @unchecked Sendable {
    enum ModalResponse { case OK, cancel }
    var title = "", message = "", prompt = ""
    var nameFieldStringValue = ""
    var directoryURL: URL?
    var canCreateDirectories = true
    var allowedContentTypes: [UTType] = []
    var url: URL?
    func runModal() -> ModalResponse {
        guard let path = fileDialogHook(title.isEmpty ? message : title, true, false, nameFieldStringValue.isEmpty ? nil : nameFieldStringValue) else { return .cancel }
        url = URL(fileURLWithPath: path)
        return .OK
    }
}

final class NSOpenPanel: NSSavePanel {
    var canChooseFiles = true, canChooseDirectories = false, allowsMultipleSelection = false
    var urls: [URL] { url.map { [$0] } ?? [] }
    override func runModal() -> ModalResponse {
        guard let path = fileDialogHook(title.isEmpty ? message : title, false, canChooseDirectories && !canChooseFiles, nil) else { return .cancel }
        url = URL(fileURLWithPath: path)
        return .OK
    }
}

final class NSCursor: @unchecked Sendable {
    static let resizeUpDown = NSCursor(), arrow = NSCursor(), pointingHand = NSCursor()
    func set() {}
    func push() {}
    static func pop() {}
}
#endif

#if !canImport(AppKit)
extension CGImage {
    /// Größe in Punkten (wie `NSImage.size`)
    var size: CGSize { CGSize(width: width, height: height) }
}

// Markdown: Foundation unter Linux liest es nicht. `AttributedString(markdown:)` liefert hier den Text ohne Auszeichnung.
extension AttributedString {
    struct MarkdownParsingOptions {
        enum InterpretedSyntax { case inlineOnly, inlineOnlyPreservingWhitespace, full }
        var interpretedSyntax: InterpretedSyntax = .full
        init(allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full, failurePolicy: Int = 0, languageCode: String? = nil) { self.interpretedSyntax = interpretedSyntax }
    }

    init(markdown: String, options: MarkdownParsingOptions = MarkdownParsingOptions()) throws {
        var text = markdown
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1", options: .regularExpression)
        self.init(text)
    }
}
#endif

#if !canImport(AppKit)
/// Rollrad und Pinch-Ereignisse für die Stellen, die sie mit einem lokalen Beobachter abfangen (HF-Wasserfall)
final class NSEvent: @unchecked Sendable {
    struct EventTypeMask: OptionSet { let rawValue: Int; static let scrollWheel = EventTypeMask(rawValue: 1), magnify = EventTypeMask(rawValue: 2) }
    enum EventType { case scrollWheel, magnify }
    struct ModifierFlags: OptionSet { let rawValue: Int; static let option = ModifierFlags(rawValue: 1 << 19), shift = ModifierFlags(rawValue: 1 << 17), command = ModifierFlags(rawValue: 1 << 20), control = ModifierFlags(rawValue: 1 << 18) }

    let type: EventType
    let scrollingDeltaY: CGFloat
    let deltaY: CGFloat
    let magnification: CGFloat = 0
    let modifierFlags: ModifierFlags

    init(type: EventType, dy: CGFloat, state: Int) {
        self.type = type; scrollingDeltaY = dy; deltaY = dy
        // GDK: Shift 1, Control 4, Alt 8, Super 64
        var flags: ModifierFlags = []
        if state & 1 != 0 { flags.insert(.shift) }
        if state & 4 != 0 { flags.insert(.control) }
        if state & 8 != 0 { flags.insert(.option) }
        modifierFlags = flags
    }

    private nonisolated(unsafe) static var monitors: [Int: (NSEvent) -> NSEvent?] = [:]
    private nonisolated(unsafe) static var next = 1

    static func addLocalMonitorForEvents(matching mask: EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        let id = next; next += 1
        monitors[id] = handler
        if rawScrollHook == nil {
            rawScrollHook = { dx, dy, state in
                let event = NSEvent(type: .scrollWheel, dy: -dy / 40, state: state)
                var consumed = false
                for handler in NSEvent.monitors.values where handler(event) == nil { consumed = true }
                return consumed
            }
        }
        return id
    }

    static func removeMonitor(_ monitor: Any) { if let id = monitor as? Int { monitors[id] = nil } }
}
#endif
