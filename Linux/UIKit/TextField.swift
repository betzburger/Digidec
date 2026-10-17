// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Texteingabe: Die Felder sind echte GTK-Eingabefelder (Eingabemethoden, Zwischenablage, Auswahl), die über die Zeichenfläche gelegt werden.
import Foundation
import CGtkCairo

public struct TextFieldStyleKind: Sendable, Equatable {
    let id: Int
    public static let roundedBorder = TextFieldStyleKind(id: 0), plain = TextFieldStyleKind(id: 1), automatic = TextFieldStyleKind(id: 2)
}
private struct TextFieldStyleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = TextFieldStyleKind.roundedBorder }
extension EnvironmentValues { var textFieldStyleKind: TextFieldStyleKind { get { self[TextFieldStyleKey.self] } set { self[TextFieldStyleKey.self] = newValue } } }
extension View { public func textFieldStyle(_ style: TextFieldStyleKind) -> some View { transformEnvironment { $0.textFieldStyleKind = style } } }

struct NativeFieldSpec {
    var text: Binding<String>
    var placeholder: String
    var secure = false
    var multiline = false
    var font: Font
    var style: TextFieldStyleKind
    var enabled = true
    var submit: (() -> Void)?
    var frame: CGRect = .zero
    var alignment: TextAlignment = .leading
}

public struct TextField: PrimitiveView {
    let placeholder: String
    let text: Binding<String>
    var secure = false

    public init(_ title: LocalizedStringKey, text: Binding<String>) { placeholder = title.resolved; self.text = text }
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) { placeholder = String(title); self.text = text }
    public init(_ title: LocalizedStringKey, text: Binding<String>, axis: Axis) { placeholder = title.resolved; self.text = text }

    public init<V: LosslessStringConvertible>(_ title: LocalizedStringKey, value: Binding<V>, format: NumberFormatStyle) {
        placeholder = title.resolved
        text = Binding(get: { String(value.wrappedValue) }, set: { if let v = V($0.trimmingCharacters(in: .whitespaces)) { value.wrappedValue = v } })
    }

    func makeNodes(_ r: Resolver) -> [Node] {
        let node = TextFieldNode(identity: r.identity, host: r.host)
        node.spec = NativeFieldSpec(text: text, placeholder: placeholder, secure: secure, font: r.env.font, style: r.env.textFieldStyleKind, enabled: r.env.isEnabled,
                                    submit: r.env.submitAction, alignment: r.env.multilineTextAlignment)
        return [node]
    }
}

public struct SecureField: PrimitiveView {
    let placeholder: String
    let text: Binding<String>
    public init(_ title: LocalizedStringKey, text: Binding<String>) { placeholder = title.resolved; self.text = text }
    func makeNodes(_ r: Resolver) -> [Node] { TextField(verbatimTitle: placeholder, text: text, secure: true).makeNodes(r) }
}

extension TextField {
    init(verbatimTitle: String, text: Binding<String>, secure: Bool) { placeholder = verbatimTitle; self.text = text; self.secure = secure }
}

public struct TextEditor: PrimitiveView {
    let text: Binding<String>
    public init(text: Binding<String>) { self.text = text }
    func makeNodes(_ r: Resolver) -> [Node] {
        let node = TextFieldNode(identity: r.identity, host: r.host)
        node.spec = NativeFieldSpec(text: text, placeholder: "", multiline: true, font: r.env.font, style: .roundedBorder, enabled: r.env.isEnabled, submit: nil)
        node.multiline = true
        return [node]
    }
}

/// Zahlenformat für `TextField(value:format:)`: Die Darstellung übernimmt der Wert selbst, die Angabe wird nur angenommen
public struct NumberFormatStyle {
    public static var number: NumberFormatStyle { NumberFormatStyle() }
    public func grouping(_ g: Grouping) -> NumberFormatStyle { self }
    public func precision(_ p: Precision) -> NumberFormatStyle { self }
    public enum Grouping { case never, automatic }
    public struct Precision { public static func fractionLength(_ n: Int) -> Precision { Precision() }; public static func fractionLength(_ r: ClosedRange<Int>) -> Precision { Precision() } }
}

@MainActor
final class TextFieldNode: Node {
    var spec: NativeFieldSpec!
    weak var host: UIHost?
    var multiline = false

    init(identity: Identity, host: UIHost?) { self.host = host; super.init(identity: identity) }

    override func computeSize(_ p: Proposal) -> CGSize {
        let w = p.width.flatMap { $0.isFinite ? $0 : nil } ?? 160
        if multiline { return CGSize(width: w, height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? 120) }
        let h = max(22, TextEngine.lineHeight(spec.font.size) + 8)
        return CGSize(width: w, height: h)
    }

    override func place(origin: CGPoint, size: CGSize) {
        frame = CGRect(origin: origin, size: size)
        spec.frame = frame
        spec.enabled = spec.enabled && enabled
        host?.fieldSpecs[identity] = spec
    }
}
