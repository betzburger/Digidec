// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Zustand der Ansichten: @State, @Binding, @ObservedObject, @StateObject, @Environment, @AppStorage, @FocusState.
// Eine Ansicht ist nur ein Wert und wird bei jeder Auflösung neu gebaut. Ihr Zustand liegt deshalb im `StateStore`,
// geordnet nach der Identität (Pfad im Baum). Die Eigenschaftshüllen sind Verweise auf Behälter, die beim Auflösen an den
// gespeicherten Platz gebunden werden.
import Foundation
import Combine

/// Identität einer Ansicht im Baum (Hash des Pfades)
public struct Identity: Hashable, Sendable {
    var value: Int
    static let root = Identity(value: 0)

    func child<K: Hashable>(_ key: K) -> Identity {
        var h = Hasher()
        h.combine(value)
        h.combine(key)
        return Identity(value: h.finalize())
    }
}

protocol DynamicProperty {
    /// Bindet die Eigenschaft an den gespeicherten Platz `slot` dieser Ansicht und an die aktuelle Umgebung
    @MainActor func attach(_ context: AttachContext, index: Int)
}

struct AttachContext {
    let store: StateStore
    let identity: Identity
    let environment: EnvironmentValues
    let invalidate: () -> Void
}

/// Ein gespeicherter Wert samt Beobachtern
final class StateSlot {
    var value: Any
    var cancellable: AnyCancellable?
    var epoch = 0
    init(_ value: Any) { self.value = value }
}

final class StateStore {
    private var slots: [Identity: [Int: StateSlot]] = [:]
    var epoch = 0
    /// Zeiger- und Verlaufszustand, der über Auflösungen hinweg bestehen muss (Hover, Drücken, Scrollposition …)
    var interaction: [Identity: [String: Any]] = [:]
    var interactionEpoch: [Identity: Int] = [:]

    func slot(_ identity: Identity, _ index: Int, initial: @autoclosure () -> Any) -> StateSlot {
        if let s = slots[identity]?[index] { s.epoch = epoch; return s }
        let s = StateSlot(initial())
        s.epoch = epoch
        slots[identity, default: [:]][index] = s
        return s
    }

    /// Nicht mehr erreichte Plätze entfernen (nach einer Auflösung)
    func sweep() {
        for (id, dict) in slots {
            let live = dict.filter { $0.value.epoch == epoch }
            if live.isEmpty { slots[id] = nil } else if live.count != dict.count { slots[id] = live }
        }
        for id in interactionEpoch.keys where interactionEpoch[id] != epoch { interaction[id] = nil; interactionEpoch[id] = nil }
    }

    func touchInteraction(_ id: Identity) { interactionEpoch[id] = epoch }
}

// MARK: - @State

public final class StateBox<Value> {
    var initial: Value
    var slot: StateSlot?
    var invalidate: (() -> Void)?
    init(_ v: Value) { initial = v }
    var value: Value {
        get { (slot?.value as? Value) ?? initial }
        set {
            if let slot { slot.value = newValue } else { initial = newValue }
            invalidate?()
        }
    }
}

@propertyWrapper
public struct State<Value>: DynamicProperty {
    let box: StateBox<Value>
    public init(wrappedValue: Value) { box = StateBox(wrappedValue) }
    public init(initialValue: Value) { box = StateBox(initialValue) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }

    @MainActor func attach(_ context: AttachContext, index: Int) {
        let slot = context.store.slot(context.identity, index, initial: box.initial)
        box.slot = slot
        box.invalidate = context.invalidate
    }
}

// MARK: - @Binding

@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value> {
    let getter: () -> Value
    let setter: (Value) -> Void
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { getter = get; setter = set }
    public init(projectedValue: Binding<Value>) { getter = projectedValue.getter; setter = projectedValue.setter }
    public static func constant(_ value: Value) -> Binding<Value> { Binding(get: { value }, set: { _ in }) }
    public var wrappedValue: Value {
        get { getter() }
        nonmutating set { setter(newValue) }
    }
    public var projectedValue: Binding<Value> { self }
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding<T>(get: { self.getter()[keyPath: keyPath] }, set: { var v = self.getter(); v[keyPath: keyPath] = $0; self.setter(v) })
    }
    public func transaction() -> Binding<Value> { self }
}

// MARK: - @ObservedObject / @StateObject

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject>: DynamicProperty {
    var object: ObjectType
    public init(wrappedValue: ObjectType) { object = wrappedValue }
    public var wrappedValue: ObjectType { get { object } set { object = newValue } }
    @dynamicMemberLookup
    public struct Wrapper {
        let object: ObjectType
        public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, T>) -> Binding<T> {
            Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
        }
    }
    public var projectedValue: Wrapper { Wrapper(object: object) }

    @MainActor func attach(_ context: AttachContext, index: Int) {
        let slot = context.store.slot(context.identity, index, initial: ObjectIdentifier(object))
        // Neu abonnieren, wenn sich das Objekt geändert hat
        if slot.cancellable == nil || (slot.value as? ObjectIdentifier) != ObjectIdentifier(object) {
            slot.value = ObjectIdentifier(object)
            let invalidate = context.invalidate
            slot.cancellable = object.objectWillChange.sink { _ in invalidate() }
        }
    }
}

@propertyWrapper
public struct StateObject<ObjectType: ObservableObject>: DynamicProperty {
    let make: () -> ObjectType
    let holder = StateBox<ObjectType?>(nil)
    public init(wrappedValue: @autoclosure @escaping () -> ObjectType) { make = wrappedValue }
    public var wrappedValue: ObjectType {
        if let o = holder.value { return o }
        let o = make()
        holder.initial = o
        return o
    }
    public var projectedValue: ObservedObject<ObjectType>.Wrapper { ObservedObject<ObjectType>.Wrapper(object: wrappedValue) }

    @MainActor func attach(_ context: AttachContext, index: Int) {
        let slot = context.store.slot(context.identity, index, initial: Optional<ObjectType>.none as Any)
        holder.slot = slot
        if (slot.value as? ObjectType) == nil {
            let o = make()
            slot.value = o
            if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_STATE"] != nil { FileHandle.standardError.write(Data("StateObject new \(ObjectType.self) id \(context.identity.value) idx \(index) epoch \(context.store.epoch)\n".utf8)) }
        }
        if slot.cancellable == nil, let o = slot.value as? ObjectType {
            let invalidate = context.invalidate
            slot.cancellable = o.objectWillChange.sink { _ in invalidate() }
        }
    }
}

extension StateBox where Value == Optional<AnyObject> {}

// MARK: - @FocusState

@propertyWrapper
public struct FocusState<Value: Hashable>: DynamicProperty {
    let box: StateBox<Value>
    public init() where Value == Bool { box = StateBox(false) }
    public init() where Value == Optional<AnyHashable> { box = StateBox(nil) }
    public init<T: Hashable>() where Value == Optional<T> { box = StateBox(nil) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
    @MainActor func attach(_ context: AttachContext, index: Int) {
        box.slot = context.store.slot(context.identity, index, initial: box.initial)
        box.invalidate = context.invalidate
    }
}

// MARK: - @AppStorage

@propertyWrapper
public struct AppStorage<Value>: DynamicProperty {
    let key: String
    let defaultValue: Value
    let read: (UserDefaults, String, Value) -> Value
    let write: (UserDefaults, String, Value) -> Void
    let invalidateBox = StateBox<Int>(0)

    init(key: String, defaultValue: Value, read: @escaping (UserDefaults, String, Value) -> Value, write: @escaping (UserDefaults, String, Value) -> Void) {
        self.key = key; self.defaultValue = defaultValue; self.read = read; self.write = write
    }

    public var wrappedValue: Value {
        get { read(.standard, key, defaultValue) }
        nonmutating set { write(.standard, key, newValue); invalidateBox.value &+= 1 }
    }
    public var projectedValue: Binding<Value> {
        let s = self
        return Binding(get: { s.wrappedValue }, set: { s.wrappedValue = $0 })
    }
    @MainActor func attach(_ context: AttachContext, index: Int) {
        invalidateBox.slot = context.store.slot(context.identity, index, initial: 0)
        invalidateBox.invalidate = context.invalidate
    }

    public init(wrappedValue: Value, _ key: String) where Value == Bool {
        self.init(key: key, defaultValue: wrappedValue, read: { $0.object(forKey: $1) == nil ? $2 : $0.bool(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }
    public init(wrappedValue: Value, _ key: String) where Value == Int {
        self.init(key: key, defaultValue: wrappedValue, read: { $0.object(forKey: $1) == nil ? $2 : $0.integer(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }
    public init(wrappedValue: Value, _ key: String) where Value == Double {
        self.init(key: key, defaultValue: wrappedValue, read: { $0.object(forKey: $1) == nil ? $2 : $0.double(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }
    public init(wrappedValue: Value, _ key: String) where Value == String {
        self.init(key: key, defaultValue: wrappedValue, read: { $0.string(forKey: $1) ?? $2 }, write: { $0.set($2, forKey: $1) })
    }
}

