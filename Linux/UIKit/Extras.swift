// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Weitere Teile von SwiftUI, die die Oberfläche braucht: AsyncImage, DisclosureGroup, List, Tastenkürzel, task(id:), NSImage-Brücke.
import Foundation
import CGtkCairo
import ImageIO
import UniformTypeIdentifiers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Text aus AttributedString

extension Text {
    public init(_ attributed: AttributedString) { self.init(verbatim: String(attributed.characters)) }
}

// MARK: - KeyboardShortcut

public struct KeyboardShortcut: Sendable {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) { self.key = key; self.modifiers = modifiers }
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])
}

nonisolated extension View {
    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View { keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers) }
    public func scrollContentBackground(_ v: Visibility) -> some View { self }
    public func autocorrectionDisabled(_ disabled: Bool = true) -> some View { self }
    public func disableAutocorrection(_ disabled: Bool?) -> some View { self }
    public func textContentType(_ type: Int?) -> some View { self }
    public func focused(_ condition: Binding<Bool>) -> some View { self }
    public func focused<V: Hashable>(_ binding: Binding<V?>, equals value: V) -> some View { self }
    public func submitLabel(_ label: Int) -> some View { self }
    public func labelStyle(_ style: LabelStyleKind) -> some View { transformEnvironment { $0.labelStyleKind = style } }
    public func monospacedDigit() -> some View { transformEnvironment { $0.font = $0.font.monospacedDigit() } }
    public func bold(_ on: Bool = true) -> some View { transformEnvironment { if on { $0.font = $0.font.bold() } } }
    public func italic() -> some View { transformEnvironment { $0.font = $0.font.italic() } }
    public func fontWeight(_ weight: Font.Weight?) -> some View { transformEnvironment { if let weight { $0.font = $0.font.weight(weight) } } }
    public func border<S: ShapeStyle>(_ style: S, width: CGFloat = 1) -> some View { overlay(Rectangle().strokeBorder(style, lineWidth: width)) }
    public func task<ID: Equatable>(id: ID, priority: TaskPriority = .userInitiated, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modify { r, child in
            let slot = r.store.slot(r.identity, 92, initial: Optional<Any>.none as Any)
            let changed: Bool
            if let old = slot.value as? ID { changed = old != id } else { changed = true }
            if changed {
                slot.value = id
                Task { @MainActor in await action() }
            }
            return child
        }
    }
}

public enum Visibility: Sendable { case automatic, visible, hidden }

public struct LabelStyleKind: Sendable, Equatable {
    let id: Int
    public static let iconOnly = LabelStyleKind(id: 0), titleOnly = LabelStyleKind(id: 1), titleAndIcon = LabelStyleKind(id: 2), automatic = LabelStyleKind(id: 2)
}
private struct LabelStyleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = LabelStyleKind.titleAndIcon }
extension EnvironmentValues { var labelStyleKind: LabelStyleKind { get { self[LabelStyleKey.self] } set { self[LabelStyleKey.self] = newValue } } }

// MARK: - NSImage-Brücke

public typealias NSSize = CGSize
public typealias NSRect = CGRect
public typealias NSPoint = CGPoint

public final class NSImage: @unchecked Sendable {
    public let cgImage: CGImage
    public var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    public init(cgImage: CGImage, size: CGSize) { self.cgImage = cgImage }
    public init?(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cgImage = image
    }
}

extension Image {
    public init(nsImage: NSImage) { self.init(decorative: nsImage.cgImage, scale: 1) }
}

// MARK: - AsyncImage

public enum AsyncImagePhase {
    case empty
    case success(Image)
    case failure(Error)
    public var image: Image? { if case .success(let i) = self { return i }; return nil }
}

@MainActor
final class AsyncImageLoader: ObservableObject {
    static var cache: [URL: CGImage] = [:]
    @Published var phase = AsyncImagePhase.empty
    private var started = false

    func load(_ url: URL) {
        if let image = Self.cache[url] { phase = .success(Image(decorative: image, scale: 1)); return }
        guard !started else { return }
        started = true
        Task { @MainActor in
            do {
                var request = URLRequest(url: url)
                request.setValue("Digidec", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                if let img = NSImage(data: data) { Self.cache[url] = img.cgImage; phase = .success(Image(decorative: img.cgImage, scale: 1)) }
                else { phase = .failure(URLError(.cannotDecodeContentData)) }
            } catch { phase = .failure(error) }
        }
    }
}

public struct AsyncImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content
    @StateObject private var loader = AsyncImageLoader()
    public init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) { self.url = url; self.content = content }
    public var body: some View {
        if let url { loader.load(url) }
        return content(loader.phase)
    }
}

// MARK: - DisclosureGroup und List

public struct DisclosureGroup<Label: View, Content: View>: View {
    let label: Label, content: Content
    @State private var expanded = false
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label() }
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Label == Text { self.content = content(); label = Text(title) }
    public init(@ViewBuilder content: () -> Content) where Label == Text { self.content = content(); label = Text("Einzelheiten") }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 4) { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)); label }
            }.buttonStyle(.plain)
            if expanded { content.padding(.leading, 14) }
        }
    }
}

public struct List<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public init<Data: RandomAccessCollection, Row: View>(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> Row) where Data.Element: Identifiable, Content == ForEach<Data, Data.Element.ID, Row> {
        content = ForEach(data, content: rowContent)
    }
    public var body: some View { ScrollView { VStack(alignment: .leading, spacing: 0) { content } } }
}

// MARK: - Maske, kontinuierliches Hovern

public enum HoverPhase { case active(CGPoint), ended }

nonisolated extension View {
    public func onContinuousHover(coordinateSpace: CoordinateSpace = .local, perform action: @escaping (HoverPhase) -> Void) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            weak var node: IDNode? = n
            n.handlers = Handlers(hover: { inside in if !inside { action(.ended) } }, motion: { p in
                guard let node else { return }
                action(.active(CGPoint(x: p.x - node.frame.minX, y: p.y - node.frame.minY)))
            })
            return n
        }
    }

    /// Der Inhalt wird nur dort gezeigt, wo die Maske (eine gefüllte Form) liegt
    public func mask<M: View>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> M) -> some View {
        let m = mask()
        return modify { r, child in MaskNode(identity: r.identity, content: child, mask: r.content(m, key: 1), alignment: alignment) }
    }
}

@MainActor
final class MaskNode: Node {
    let content: Node, mask: Node
    let alignment: Alignment
    init(identity: Identity, content: Node, mask: Node, alignment: Alignment) {
        self.content = content; self.mask = mask; self.alignment = alignment
        super.init(identity: identity)
        children = [content, mask]
    }
    override func computeSize(_ p: Proposal) -> CGSize { content.size(for: p) }
    override func placeChildren() {
        content.place(origin: frame.origin, size: content.size(for: .fixed(frame.size)))
        let s = mask.size(for: .fixed(frame.size))
        mask.place(origin: CGPoint(x: frame.minX + alignment.horizontal.offset(in: frame.width - s.width), y: frame.minY + alignment.vertical.offset(in: frame.height - s.height)), size: s)
    }
    private func shapeNode(_ n: Node) -> ShapeNode? {
        if let s = n as? ShapeNode { return s }
        for c in n.children { if let s = shapeNode(c) { return s } }
        return nil
    }
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        cairo_save(g.cr)
        if let shape = shapeNode(mask) { g.clip(to: shape.shape.path(in: shape.frame)) } else { g.clip(to: Path(mask.frame)) }
        content.draw(&g, clip: clip)
        cairo_restore(g.cr)
    }
}
