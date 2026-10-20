// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Button, ButtonStyle, Toggle, Slider, Stepper, ProgressView, Link.
import Foundation
import CGtkCairo

// MARK: - ButtonStyle

public struct ButtonStyleConfiguration {
    public struct Label {
        let view: any View
        @MainActor func makeNodes(_ r: Resolver) -> [Node] { r.resolve(view, key: 0) }
    }
    public let label: Label
    public let isPressed: Bool
}

@MainActor
public protocol ButtonStyle {
    associatedtype Body: View
    typealias Configuration = ButtonStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

struct AnyButtonStyle {
    let make: @MainActor (ButtonStyleConfiguration) -> any View
    nonisolated init<S: ButtonStyle>(_ style: S) { make = { style.makeBody(configuration: $0) } }
}

private struct ButtonStyleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: AnyButtonStyle? = nil }
extension EnvironmentValues {
    var buttonStyle: AnyButtonStyle? { get { self[ButtonStyleKey.self] } set { self[ButtonStyleKey.self] = newValue } }
}

public struct PlainButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.6 : 1) }
}

public struct BorderlessButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.6 : 1) }
}

/// Standard-Tastenstil: abgerundete Fläche mit leichtem Verlauf
public struct DefaultButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(white: configuration.isPressed ? 0.2 : 0.34), Color(white: configuration.isPressed ? 0.16 : 0.26)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0, opacity: 0.6), lineWidth: 1))
    }
}

extension ButtonStyle where Self == PlainButtonStyle { nonisolated public static var plain: PlainButtonStyle { PlainButtonStyle() } }
extension ButtonStyle where Self == BorderlessButtonStyle { nonisolated public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() } }
extension ButtonStyle where Self == DefaultButtonStyle {
    nonisolated public static var bordered: DefaultButtonStyle { DefaultButtonStyle() }
    nonisolated public static var borderedProminent: DefaultButtonStyle { DefaultButtonStyle() }
    nonisolated public static var automatic: DefaultButtonStyle { DefaultButtonStyle() }
}

nonisolated extension View {
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        transformEnvironment { $0.buttonStyle = AnyButtonStyle(style) }
    }
}

// MARK: - Button

public struct Button<Label: View> {
    let action: () -> Void
    let label: Label

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) { self.action = action; self.label = label() }
    public init(_ title: LocalizedStringKey, action: @escaping () -> Void) where Label == Text { self.action = action; label = Text(title) }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) where Label == Text { self.action = action; label = Text(title) }
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) { self.action = action; self.label = label() }
    public init(_ title: LocalizedStringKey, role: ButtonRole?, action: @escaping () -> Void) where Label == Text { self.action = action; label = Text(title) }

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let identity = r.identity, store = r.store, host = r.host, action = self.action, label = self.label
        let enabled = r.env.isEnabled
        let buttonStyle = r.env.buttonStyle
        return r.refreshable { [unowned r] in
            let pressed = store.interaction[identity]?["pressed"] as? Bool ?? false
            store.touchInteraction(identity)
            let style: AnyButtonStyle
            if let s = buttonStyle { style = s } else { style = AnyButtonStyle(DefaultButtonStyle()) }
            let body = style.make(ButtonStyleConfiguration(label: .init(view: label), isPressed: pressed && enabled))
            let node = ButtonNode(identity: identity, child: r.content(AnyView(body)))
            node.enabled = enabled
            node.handlers = Handlers(tap: { if node.enabled { action() } }, press: { down in
                store.interaction[identity, default: [:]]["pressed"] = down
                host?.invalidate(identity)
            })
            return [node]
        }
    }
}

public enum ButtonRole: Sendable { case destructive, cancel }

@MainActor
final class ButtonNode: WrapperNode {
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        if !enabled, let child { g.drawOpacityGroup(alpha: 0.45, bounds: child.subtreeBounds().intersection(clip)) { inner in child.draw(&inner, clip: clip) } }
        else { child?.draw(&g, clip: clip) }
    }
}

// MARK: - Toggle

public protocol ToggleStyle_ {}
public struct ToggleStyleKind: Sendable, Equatable {
    let id: Int
    public static let checkbox = ToggleStyleKind(id: 0), `switch` = ToggleStyleKind(id: 1), button = ToggleStyleKind(id: 2), automatic = ToggleStyleKind(id: 3)
}

private struct ToggleStyleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = ToggleStyleKind.checkbox }
extension EnvironmentValues { var toggleStyleKind: ToggleStyleKind { get { self[ToggleStyleKey.self] } set { self[ToggleStyleKey.self] = newValue } } }

nonisolated extension View {
    public func toggleStyle(_ style: ToggleStyleKind) -> some View { transformEnvironment { $0.toggleStyleKind = style } }
}

public struct Toggle<Label: View> {
    let isOn: Binding<Bool>
    let label: Label
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) { self.isOn = isOn; self.label = label() }
    public init(_ title: LocalizedStringKey, isOn: Binding<Bool>) where Label == Text { self.isOn = isOn; label = Text(title) }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) where Label == Text { self.isOn = isOn; label = Text(title) }

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let kind = r.env.toggleStyleKind
        let on = isOn.wrappedValue
        let binding = isOn
        let box = ToggleMark(on: on, kind: kind, color: r.env.tintColor ?? Color.accentColor, enabled: r.env.isEnabled)
        let content = r.env.labelsHidden ? AnyView(box) : AnyView(HStack(spacing: 6) { box; label })
        let node = ButtonNode(identity: r.identity, child: r.content(content))
        node.enabled = r.env.isEnabled
        node.handlers = Handlers(tap: { if node.enabled { binding.wrappedValue.toggle() } })
        return [node]
    }
}

struct ToggleMark {
    let on: Bool, kind: ToggleStyleKind, color: Color, enabled: Bool
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [ToggleMarkNode(identity: r.identity, on: on, kind: kind, color: color)] }
}

@MainActor
final class ToggleMarkNode: Node {
    let on: Bool, kind: ToggleStyleKind, color: Color
    init(identity: Identity, on: Bool, kind: ToggleStyleKind, color: Color) { self.on = on; self.kind = kind; self.color = color; super.init(identity: identity) }
    override func computeSize(_ p: Proposal) -> CGSize { kind == .switch ? CGSize(width: 34, height: 20) : CGSize(width: 16, height: 16) }
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        if kind == .switch {
            let track = Path(roundedRect: frame, cornerRadius: frame.height / 2)
            g.fill(track, with: .color(on ? color : Color(white: 1, opacity: 0.18)))
            g.stroke(track, with: .color(Color(white: 0, opacity: 0.5)), lineWidth: 1)
            let r = frame.height / 2 - 2
            let cx = on ? frame.maxX - 2 - r : frame.minX + 2 + r
            g.fill(Path(ellipseIn: CGRect(x: cx - r, y: frame.midY - r, width: 2 * r, height: 2 * r)), with: .color(.white))
        } else {
            let box = Path(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 4)
            g.fill(box, with: .color(on ? color : Color(white: 1, opacity: 0.1)))
            g.stroke(box, with: .color(Color(white: 1, opacity: on ? 0 : 0.3)), lineWidth: 1)
            if on {
                var tick = Path(); tick.move(to: CGPoint(x: frame.minX + 4, y: frame.midY)); tick.addLine(to: CGPoint(x: frame.minX + 7, y: frame.midY + 3)); tick.addLine(to: CGPoint(x: frame.maxX - 4, y: frame.midY - 3))
                g.stroke(tick, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Slider

public struct Slider<Label: View> {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let onEditingChanged: (Bool) -> Void

    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where Label == EmptyView {
        self.value = value; self.range = range; step = nil; self.onEditingChanged = onEditingChanged
    }
    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where Label == EmptyView {
        self.value = value; self.range = range; self.step = step; self.onEditingChanged = onEditingChanged
    }
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in range: ClosedRange<V>, step: V.Stride? = nil) where Label == EmptyView, V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = step.map { Double($0) }
        onEditingChanged = { _ in }
    }

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = SliderNode(identity: r.identity, value: value.wrappedValue, range: range, step: step, enabled: r.env.isEnabled, tint: r.env.tintColor ?? Color(red: 0.2, green: 0.7, blue: 0.95))
        node.enabled = r.env.isEnabled
        let binding = value, edit = onEditingChanged
        node.set = { binding.wrappedValue = $0 }
        node.handlers = Handlers(drag: DragHandler(minimumDistance: 0, changed: { [unowned node] v in node.apply(x: v.location.x) }, ended: { _ in edit(false) }))
        return [node]
    }
}

@MainActor
final class SliderNode: Node {
    let value: Double, range: ClosedRange<Double>, step: Double?, tint: Color
    var set: ((Double) -> Void)?
    init(identity: Identity, value: Double, range: ClosedRange<Double>, step: Double?, enabled: Bool, tint: Color) {
        self.value = value; self.range = range; self.step = step; self.tint = tint
        super.init(identity: identity)
    }
    override func computeSize(_ p: Proposal) -> CGSize { CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 120, height: 20) }
    func apply(x: CGFloat) {
        guard enabled else { return }
        let t = min(1, max(0, Double((x - frame.minX - 8) / max(1, frame.width - 16))))
        var v = range.lowerBound + t * (range.upperBound - range.lowerBound)
        if let step, step > 0 { v = (v / step).rounded() * step; v = min(range.upperBound, max(range.lowerBound, v)) }
        set?(v)
    }
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let t = CGFloat((value - range.lowerBound) / max(1e-9, range.upperBound - range.lowerBound))
        let trackY = frame.midY
        let x0 = frame.minX + 8, x1 = frame.maxX - 8
        let trough = Path(roundedRect: CGRect(x: x0 - 2, y: trackY - 2, width: x1 - x0 + 4, height: 4), cornerRadius: 2)
        g.fill(trough, with: .color(Color(white: 0, opacity: 0.45)))
        g.stroke(trough, with: .color(Color(white: 1, opacity: 0.12)), lineWidth: 1)
        let kx = x0 + (x1 - x0) * t
        g.fill(Path(roundedRect: CGRect(x: x0 - 2, y: trackY - 2, width: kx - x0 + 2, height: 4), cornerRadius: 2), with: .color(tint.opacity(0.85)))
        let knob = Path(ellipseIn: CGRect(x: kx - 7, y: trackY - 7, width: 14, height: 14))
        g.fill(knob, with: .linearGradient(Gradient(colors: [Color(white: 0.85), Color(white: 0.6)]), startPoint: CGPoint(x: kx, y: trackY - 7), endPoint: CGPoint(x: kx, y: trackY + 7)))
        g.stroke(knob, with: .color(Color(white: 0, opacity: 0.6)), lineWidth: 1)
        if !enabled { g.fill(Path(frame), with: .color(Color(white: 0, opacity: 0.0))) }
    }
}

// MARK: - Stepper

public struct Stepper<Label: View> {
    let label: Label
    let onIncrement: () -> Void, onDecrement: () -> Void
    public init(@ViewBuilder label: () -> Label, onIncrement: @escaping () -> Void, onDecrement: @escaping () -> Void) {
        self.label = label(); self.onIncrement = onIncrement; self.onDecrement = onDecrement
    }
    public init<V: Strideable>(value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label) {
        self.label = label()
        onIncrement = { value.wrappedValue = min(range.upperBound, value.wrappedValue.advanced(by: step)) }
        onDecrement = { value.wrappedValue = max(range.lowerBound, value.wrappedValue.advanced(by: -step)) }
    }
    public init<V: Strideable>(_ title: LocalizedStringKey, value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) where Label == Text {
        self.init(value: value, in: range, step: step) { Text(title) }
    }
    public var body: some View {
        HStack(spacing: 6) {
            label
            HStack(spacing: 1) {
                Button(action: onDecrement) { Image(systemName: "minus").frame(width: 18, height: 16) }
                Button(action: onIncrement) { Image(systemName: "plus").frame(width: 18, height: 16) }
            }
        }
    }
}

// MARK: - ProgressView

public struct ProgressView {
    let fraction: Double?
    public init() { fraction = nil }
    public init(value: Double?, total: Double = 1) { fraction = value.map { $0 / max(total, 1e-9) } }
    public init(_ title: LocalizedStringKey) { fraction = nil }
    public init<V: BinaryFloatingPoint>(value: V, total: V = 1) { fraction = Double(value) / max(Double(total), 1e-9) }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [ProgressNode(identity: r.identity, fraction: fraction, tint: r.env.tintColor ?? Color.accentColor)] }
}

public struct ProgressViewStyleKind: Sendable { public static let linear = ProgressViewStyleKind(), circular = ProgressViewStyleKind(), automatic = ProgressViewStyleKind() }
nonisolated extension View { public func progressViewStyle(_ style: ProgressViewStyleKind) -> some View { self } }

@MainActor
final class ProgressNode: Node {
    let fraction: Double?, tint: Color
    init(identity: Identity, fraction: Double?, tint: Color) { self.fraction = fraction; self.tint = tint; super.init(identity: identity) }
    override func computeSize(_ p: Proposal) -> CGSize {
        fraction == nil ? CGSize(width: 16, height: 16) : CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 100, height: 6)
    }
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        guard let fraction else {
            // Unbestimmt: drehender Bogen
            let phase = Date().timeIntervalSinceReferenceDate * 5
            var p = Path()
            p.addArc(center: CGPoint(x: frame.midX, y: frame.midY), radius: min(frame.width, frame.height) / 2 - 1.5, startAngle: Angle(radians: phase), endAngle: Angle(radians: phase + 4.2), clockwise: true)
            g.stroke(p, with: .color(Color(white: 1, opacity: 0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            return
        }
        let track = Path(roundedRect: frame, cornerRadius: frame.height / 2)
        g.fill(track, with: .color(Color(white: 1, opacity: 0.15)))
        let f = CGFloat(min(1, max(0, fraction)))
        g.fill(Path(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: max(frame.height, frame.width * f), height: frame.height), cornerRadius: frame.height / 2), with: .color(tint))
    }
}

// MARK: - Link

public struct Link<Label: View> {
    let url: URL
    let label: Label
    public init(destination: URL, @ViewBuilder label: () -> Label) { url = destination; self.label = label() }
    public init(_ title: LocalizedStringKey, destination: URL) where Label == Text { url = destination; label = Text(title) }
    public var body: some View {
        Button(action: { openURLHook(url) }) { label.foregroundColor(Color(red: 0.4, green: 0.7, blue: 1)) }.buttonStyle(.plain)
    }
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension ButtonStyleConfiguration.Label: PrimitiveView {}
extension Button: PrimitiveView {}
extension Toggle: PrimitiveView {}
extension ToggleMark: PrimitiveView {}
extension Slider: PrimitiveView {}
extension Stepper: View {}
extension ProgressView: PrimitiveView {}
extension Link: View {}
extension PlainButtonStyle: ButtonStyle {}
extension BorderlessButtonStyle: ButtonStyle {}
extension DefaultButtonStyle: ButtonStyle {}
