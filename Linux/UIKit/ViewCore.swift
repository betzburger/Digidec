// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Eine auf Digidec zugeschnittene Teilmenge von SwiftUI für Linux: View, ViewBuilder, Gruppen, Bedingungen, ForEach.
// Die Ansichten werden zu einem Knotenbaum aufgelöst (Node.swift), vermessen, platziert und mit Cairo gezeichnet.
@_exported import Foundation
@_exported import CoreGraphics
@_exported import Combine

public protocol View {
    associatedtype Body: View
    @MainActor @ViewBuilder var body: Body { get }
}

extension Never: View {
    public typealias Body = Never
    @MainActor public var body: Never { fatalError("Never hat keinen Körper") }
}

/// Ansichten, die ohne Körper direkt einen Knoten liefern (Text, Stapel, Formen …)
protocol PrimitiveView: View {
    @MainActor func makeNodes(_ r: Resolver) -> [Node]
}

extension PrimitiveView {
    @MainActor public var body: Never { fatalError("\(type(of: self)) ist eine Grundansicht") }
}

// MARK: - ViewBuilder

@resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> {
        TupleView((repeat each content))
    }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .first(first)) }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .second(second)) }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }
}

public struct EmptyView: PrimitiveView {
    public init() {}
    func makeNodes(_ r: Resolver) -> [Node] { [] }
}

public struct TupleView<T>: PrimitiveView {
    public var value: T
    public init(_ value: T) { self.value = value }

    func makeNodes(_ r: Resolver) -> [Node] {
        var nodes: [Node] = []
        var index = 0
        for child in Mirror(reflecting: value).children {
            if let view = child.value as? any View {
                nodes += r.resolve(view, key: index)
            }
            index += 1
        }
        return nodes
    }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

extension Optional: PrimitiveView where Wrapped: View {
    func makeNodes(_ r: Resolver) -> [Node] {
        guard let wrapped = self else { return [] }
        return r.resolve(wrapped, key: 0)
    }
}

public struct _ConditionalContent<T: View, F: View>: PrimitiveView {
    enum Storage { case first(T), second(F) }
    let storage: Storage

    func makeNodes(_ r: Resolver) -> [Node] {
        switch storage {
        case .first(let v): return r.resolve(v, key: 0)
        case .second(let v): return r.resolve(v, key: 1)
        }
    }
}

public struct Group<Content: View>: PrimitiveView {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNodes(_ r: Resolver) -> [Node] { r.resolve(content, key: 0) }
}

public struct AnyView: PrimitiveView {
    let view: any View
    public init<V: View>(_ view: V) { self.view = view }
    func makeNodes(_ r: Resolver) -> [Node] { r.resolve(view, key: 0) }
}

// MARK: - ForEach

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: PrimitiveView {
    let data: Data
    let idOf: (Data.Element) -> ID
    let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        idOf = { $0[keyPath: id] }
        self.content = content
    }

    func makeNodes(_ r: Resolver) -> [Node] {
        var nodes: [Node] = []
        for element in data { nodes += r.resolve(content(element), key: idOf(element)) }
        return nodes
    }
}

extension ForEach where ID == Data.Element.ID, Data.Element: Identifiable {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        idOf = { $0.id }
        self.content = content
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        idOf = { $0 }
        self.content = content
    }
}
