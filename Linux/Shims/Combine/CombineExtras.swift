// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Was OpenCombine (Stand 0.14) gegenüber Apples Combine nicht kennt und Digidec braucht: CombineLatest (2 und 4 Ströme) und MergeMany.
@_exported import OpenCombine
import Foundation

extension Publishers {
    /// Merkt sich je Strom den letzten Wert und meldet jedes Paar, sobald beide einen haben (Nachfrage wird wie bei `sink` als unbegrenzt behandelt).
    public struct CombineLatest<A: Publisher, B: Publisher>: Publisher where A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B

        public init(_ a: A, _ b: B) {
            self.a = a
            self.b = b
        }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            subscriber.receive(subscription: CombineLatestSubscription(a, b, subscriber))
        }
    }

    /// Alle Ströme zu einem verschmelzen (gleicher Werttyp)
    public struct MergeMany<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstreams: [Upstream]

        public init(_ upstreams: [Upstream]) { self.upstreams = upstreams }
        public init(_ upstreams: Upstream...) { self.upstreams = upstreams }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            Publishers.Sequence<[Upstream], Failure>(sequence: upstreams)
                .flatMap { $0 }
                .receive(subscriber: subscriber)
        }
    }
}

extension Publisher {
    public func combineLatest<P: Publisher>(_ other: P) -> Publishers.CombineLatest<Self, P> where P.Failure == Failure {
        Publishers.CombineLatest(self, other)
    }

    public func combineLatest<B: Publisher, C: Publisher, D: Publisher>(_ b: B, _ c: C, _ d: D)
        -> AnyPublisher<(Output, B.Output, C.Output, D.Output), Failure> where B.Failure == Failure, C.Failure == Failure, D.Failure == Failure {
        Publishers.CombineLatest(Publishers.CombineLatest(self, b), Publishers.CombineLatest(c, d))
            .map { ($0.0.0, $0.0.1, $0.1.0, $0.1.1) }
            .eraseToAnyPublisher()
    }
}

private final class CombineLatestSubscription<A: Publisher, B: Publisher, S: Subscriber>: Subscription, @unchecked Sendable
    where A.Failure == B.Failure, S.Input == (A.Output, B.Output), S.Failure == A.Failure {
    let combineIdentifier = CombineIdentifier()

    private let lock = NSRecursiveLock()
    private var subscriber: S?
    private let a: A
    private let b: B
    private var cancellables: [AnyCancellable] = []
    private var started = false
    private var latestA: A.Output?
    private var latestB: B.Output?
    private var finishedA = false
    private var finishedB = false

    init(_ a: A, _ b: B, _ subscriber: S) {
        self.a = a
        self.b = b
        self.subscriber = subscriber
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        guard !started, subscriber != nil else { lock.unlock(); return }
        started = true
        lock.unlock()
        let ca = a.sink(receiveCompletion: { [weak self] in self?.complete($0, first: true) },
                        receiveValue: { [weak self] value in self?.update { $0.latestA = value } })
        let cb = b.sink(receiveCompletion: { [weak self] in self?.complete($0, first: false) },
                        receiveValue: { [weak self] value in self?.update { $0.latestB = value } })
        lock.lock()
        cancellables = [ca, cb]
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        subscriber = nil
        let items = cancellables
        cancellables = []
        lock.unlock()
        items.forEach { $0.cancel() }
    }

    private func update(_ change: (CombineLatestSubscription) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(self)
        if let x = latestA, let y = latestB { _ = subscriber?.receive((x, y)) }
    }

    private func complete(_ completion: Subscribers.Completion<A.Failure>, first: Bool) {
        lock.lock()
        defer { lock.unlock() }
        switch completion {
        case .failure: subscriber?.receive(completion: completion)
        case .finished:
            if first { finishedA = true } else { finishedB = true }
            if finishedA && finishedB { subscriber?.receive(completion: .finished) }
        }
    }
}
