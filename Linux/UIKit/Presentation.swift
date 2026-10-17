// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Blätter (sheet) und Popover.
import Foundation

private struct SheetRegistryKey: EnvironmentKey { static let defaultValue = 0 }

nonisolated extension View {
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        presentation(isPresented: isPresented, modal: true, placement: .centered, onDismiss: onDismiss, content: content)
    }

    public func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let isPresented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return presentation(isPresented: isPresented, modal: true, placement: .centered, onDismiss: onDismiss) {
            if let value = item.wrappedValue { AnyView(content(value)) } else { AnyView(EmptyView()) }
        }
    }

    public func popover<Content: View>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect, arrowEdge: Edge = .top, @ViewBuilder content: @escaping () -> Content) -> some View {
        presentation(isPresented: isPresented, modal: false, placement: .below, onDismiss: nil, content: content)
    }

    func presentation<Content: View>(isPresented: Binding<Bool>, modal: Bool, placement: OverlayLayer.Placement, onDismiss: (() -> Void)?, @ViewBuilder content: @escaping () -> Content) -> some View {
        modify { r, child in
            let node = IDNode(identity: r.identity, child: child)
            guard let host = r.host else { return node }
            let key = r.identity
            let shown = isPresented.wrappedValue
            let existing = host.presentations[key]
            if shown && existing == nil {
                let layer = OverlayLayer(anchor: .zero, modal: modal, placement: placement, makeView: { EmptyView() }, onDismiss: {})
                layer.makeView = {
                    AnyView(Sheet(modal: modal, content: content)
                        .environment(\.dismiss, DismissAction { isPresented.wrappedValue = false }))
                }
                layer.onDismiss = { isPresented.wrappedValue = false; onDismiss?() }
                layer.anchorProvider = { [weak node] in node?.frame ?? .zero }
                host.presentations[key] = layer.id
                host.overlays.append(layer)
                host.needsResolve = true
            } else if !shown, let id = existing {
                host.presentations[key] = nil
                host.overlays.removeAll { $0.id == id }
                host.needsResolve = true
            }
            if let id = host.presentations[key], let layer = host.overlays.first(where: { $0.id == id }), let anchor = layer.anchorProvider?() { layer.anchor = anchor }
            return node
        }
    }
}

public struct PopoverAttachmentAnchor: Sendable { public static let rect = PopoverAttachmentAnchor() }

/// Rahmen eines Blattes bzw. Popovers: Fläche mit Rand
struct Sheet<Content: View> {
    let modal: Bool
    let content: () -> Content
    var body: some View {
        content()
            .padding(modal ? 0 : 10)
            .background(Color(white: 0.14))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 1, opacity: 0.16), lineWidth: 1))
    }
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension Sheet: View {}
