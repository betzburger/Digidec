// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Gesten, Hover, Hilfetexte und die Lebenszyklus-Modifikatoren (onAppear, onChange, task, onReceive).
import Foundation
import Combine

public struct DragGesture {
    var minimumDistance: CGFloat
    var changed: ((DragValue) -> Void)?
    var ended: ((DragValue) -> Void)?
    public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) { self.minimumDistance = minimumDistance }
    public func onChanged(_ action: @escaping (DragValue) -> Void) -> DragGesture { var g = self; g.changed = action; return g }
    public func onEnded(_ action: @escaping (DragValue) -> Void) -> DragGesture { var g = self; g.ended = action; return g }
}

public struct TapGestureValue { public var location: CGPoint }

nonisolated extension View {
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            let enabled = r.env.isEnabled
            n.handlers = Handlers(tap: { if enabled { action() } })
            return n
        }
    }

    public func gesture(_ g: DragGesture) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            n.handlers = Handlers(drag: DragHandler(minimumDistance: g.minimumDistance,
                                                    changed: { [unowned n] v in g.changed?(DragValue(location: CGPoint(x: v.location.x - n.frame.minX, y: v.location.y - n.frame.minY),
                                                                                                    startLocation: CGPoint(x: v.startLocation.x - n.frame.minX, y: v.startLocation.y - n.frame.minY))) },
                                                    ended: { [unowned n] v in g.ended?(DragValue(location: CGPoint(x: v.location.x - n.frame.minX, y: v.location.y - n.frame.minY),
                                                                                               startLocation: CGPoint(x: v.startLocation.x - n.frame.minX, y: v.startLocation.y - n.frame.minY))) }))
            return n
        }
    }

    public func highPriorityGesture(_ g: DragGesture) -> some View { gesture(g) }

    public func onHover(perform action: @escaping (Bool) -> Void) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            n.handlers = Handlers(hover: action)
            return n
        }
    }

    public func help(_ text: LocalizedStringKey) -> some View { help(text.resolved) }

    @_disfavoredOverload public func help<S: StringProtocol>(_ text: S) -> some View {
        let string = String(text)
        return modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            n.handlers = Handlers(help: string)
            return n
        }
    }

    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        modify { r, child in
            r.host?.registerShortcut(key: key.character, command: modifiers.contains(.command), enabled: r.env.isEnabled, action: { [weak child] in child?.handlers?.tap?() })
            return child
        }
    }

    public func tag<V: Hashable>(_ tag: V) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            n.explicitID = AnyHashable(tag)
            return n
        }
    }

    // MARK: Lebenszyklus

    public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        modify { r, child in
            if r.store.interaction[r.identity]?["appeared"] == nil {
                r.store.interaction[r.identity, default: [:]]["appeared"] = true
                action?()
            }
            r.store.touchInteraction(r.identity)
            return child
        }
    }

    public func onDisappear(perform action: (() -> Void)? = nil) -> some View { self }

    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        modify { r, child in
            let slot = r.store.slot(r.identity, 90, initial: value)
            if let old = slot.value as? V {
                if old != value { slot.value = value; DispatchQueue.main.async { action(old, value) } }
            } else { slot.value = value }
            return child
        }
    }

    public func onChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        onChange(of: value) { _, new in action(new) }
    }

    public func task(priority: TaskPriority = .userInitiated, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modify { r, child in
            if r.store.interaction[r.identity]?["task"] == nil {
                r.store.interaction[r.identity, default: [:]]["task"] = true
                Task { @MainActor in await action() }
            }
            r.store.touchInteraction(r.identity)
            return child
        }
    }

    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View where P.Failure == Never {
        modify { r, child in
            let slot = r.store.slot(r.identity, 91, initial: 0)
            if slot.cancellable == nil { slot.cancellable = publisher.sink { v in DispatchQueue.main.async { action(v) } } }
            return child
        }
    }

    public func onSubmit(_ action: @escaping () -> Void) -> some View {
        transformEnvironment { $0.submitAction = action }
    }
}

public struct KeyEquivalent: Sendable {
    let character: Character
    public init(_ c: Character) { character = c }
    public static let `return` = KeyEquivalent("\r"), escape = KeyEquivalent("\u{1b}"), space = KeyEquivalent(" "), delete = KeyEquivalent("\u{7f}")
    public static let upArrow = KeyEquivalent("\u{f700}"), downArrow = KeyEquivalent("\u{f701}")
}
extension KeyEquivalent: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(extendedGraphemeClusterLiteral value: Character) { character = value }
}

public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = EventModifiers(rawValue: 1), shift = EventModifiers(rawValue: 2), option = EventModifiers(rawValue: 4), control = EventModifiers(rawValue: 8)
}

private struct SubmitKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: (() -> Void)? = nil }
extension EnvironmentValues { var submitAction: (() -> Void)? { get { self[SubmitKey.self] } set { self[SubmitKey.self] = newValue } } }
