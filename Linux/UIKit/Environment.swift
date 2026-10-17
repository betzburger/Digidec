// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { (storage[ObjectIdentifier(key)] as? K.Value) ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

// MARK: - Eingebaute Werte

private struct FontKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = Font.body }
private struct ForegroundKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: Color? = nil }
private struct EnabledKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = true }
private struct LineLimitKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: Int? = nil }
private struct MinScaleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: CGFloat = 1 }
private struct ColorSchemeKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = ColorScheme.dark }
private struct LocaleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = Locale.current }
private struct TrackingKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: CGFloat = 0 }
private struct MultilineAlignmentKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = TextAlignment.leading }
private struct ControlSizeKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = ControlSize.regular }
private struct OpenWindowKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = OpenWindowAction { _ in } }
private struct DismissKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = DismissAction { } }
private struct TintKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: Color? = nil }
private struct HostKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: UIHost? = nil }
private struct LabelsHiddenKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = false }

public enum ColorScheme: Sendable { case light, dark }
public enum ControlSize: Sendable { case mini, small, regular, large }
public enum TextAlignment: Sendable { case leading, center, trailing }

public struct OpenWindowAction: @unchecked Sendable {
    let open: (String) -> Void
    public func callAsFunction(id: String) { open(id) }
}

public struct DismissAction: @unchecked Sendable {
    let action: () -> Void
    public func callAsFunction() { action() }
}

extension EnvironmentValues {
    public var font: Font { get { self[FontKey.self] } set { self[FontKey.self] = newValue } }
    var foregroundColor: Color? { get { self[ForegroundKey.self] } set { self[ForegroundKey.self] = newValue } }
    public var isEnabled: Bool { get { self[EnabledKey.self] } set { self[EnabledKey.self] = newValue } }
    public var lineLimit: Int? { get { self[LineLimitKey.self] } set { self[LineLimitKey.self] = newValue } }
    var minimumScaleFactor: CGFloat { get { self[MinScaleKey.self] } set { self[MinScaleKey.self] = newValue } }
    public var colorScheme: ColorScheme { get { self[ColorSchemeKey.self] } set { self[ColorSchemeKey.self] = newValue } }
    public var locale: Locale { get { self[LocaleKey.self] } set { self[LocaleKey.self] = newValue } }
    var tracking: CGFloat { get { self[TrackingKey.self] } set { self[TrackingKey.self] = newValue } }
    var multilineTextAlignment: TextAlignment { get { self[MultilineAlignmentKey.self] } set { self[MultilineAlignmentKey.self] = newValue } }
    public var controlSize: ControlSize { get { self[ControlSizeKey.self] } set { self[ControlSizeKey.self] = newValue } }
    public var openWindow: OpenWindowAction { get { self[OpenWindowKey.self] } set { self[OpenWindowKey.self] = newValue } }
    public var dismiss: DismissAction { get { self[DismissKey.self] } set { self[DismissKey.self] = newValue } }
    var tintColor: Color? { get { self[TintKey.self] } set { self[TintKey.self] = newValue } }
    var host: UIHost? { get { self[HostKey.self] } set { self[HostKey.self] = newValue } }
    var labelsHidden: Bool { get { self[LabelsHiddenKey.self] } set { self[LabelsHiddenKey.self] = newValue } }
}

// MARK: - @Environment

@propertyWrapper
public struct Environment<Value>: DynamicProperty {
    let keyPath: KeyPath<EnvironmentValues, Value>
    let box = StateBox<EnvironmentValues?>(nil)

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }

    public var wrappedValue: Value { (box.initial ?? EnvironmentValues())[keyPath: keyPath] }

    @MainActor func attach(_ context: AttachContext, index: Int) { box.initial = context.environment }
}

// MARK: - Umgebungsmodifikatoren

struct EnvironmentModifier<Content: View> {
    let content: Content
    let change: (inout EnvironmentValues) -> Void
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let saved = r.env
        change(&r.env)
        defer { r.env = saved }
        return r.resolve(content, key: 0)
    }
}

nonisolated extension View {
    func transformEnvironment(_ change: @escaping (inout EnvironmentValues) -> Void) -> some View {
        EnvironmentModifier(content: self, change: change)
    }

    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        transformEnvironment { $0[keyPath: keyPath] = value }
    }

    public func font(_ font: Font?) -> some View {
        transformEnvironment { if let font { $0.font = font } }
    }

    public func foregroundColor(_ color: Color?) -> some View {
        transformEnvironment { $0.foregroundColor = color }
    }

    public func foregroundStyle(_ color: Color) -> some View {
        transformEnvironment { $0.foregroundColor = color }
    }

    public func lineLimit(_ limit: Int?) -> some View {
        transformEnvironment { $0.lineLimit = limit }
    }

    public func minimumScaleFactor(_ factor: CGFloat) -> some View {
        transformEnvironment { $0.minimumScaleFactor = factor }
    }

    public func tracking(_ value: CGFloat) -> some View {
        transformEnvironment { $0.tracking = value }
    }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        transformEnvironment { $0.multilineTextAlignment = alignment }
    }

    public func disabled(_ disabled: Bool) -> some View {
        transformEnvironment { if disabled { $0.isEnabled = false } }
    }

    public func preferredColorScheme(_ scheme: ColorScheme?) -> some View { self }
    public func colorScheme(_ scheme: ColorScheme) -> some View { self }
    public func controlSize(_ size: ControlSize) -> some View { transformEnvironment { $0.controlSize = size } }
    public func tint(_ color: Color?) -> some View { transformEnvironment { $0.tintColor = color } }
    public func labelsHidden() -> some View { transformEnvironment { $0.labelsHidden = true } }
    public func textSelection(_ selectable: TextSelectability) -> some View { self }
    public func truncationMode(_ mode: Text.TruncationMode) -> some View { self }
    public func textCase(_ textCase: Text.Case?) -> some View { transformEnvironment { $0.textCase = textCase } }
}

public struct TextSelectability: Sendable { public static let enabled = TextSelectability(); public static let disabled = TextSelectability() }

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension EnvironmentModifier: PrimitiveView {}
