// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für das Modul `os` von Apple (nur Linux): `OSAllocatedUnfairLock` auf Basis von pthread_mutex.
import Foundation

public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    /// Eigener Speicher mit fester Adresse: `&eigenschaft` als Zeiger garantiert Swift nicht, ein Mutex darf aber nicht wandern
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private var state: State

    public init(initialState: State) {
        state = initialState
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body(&state)
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}

extension OSAllocatedUnfairLock where State == Void {
    public convenience init() { self.init(initialState: ()) }

    public func lock() { pthread_mutex_lock(mutex) }
    public func unlock() { pthread_mutex_unlock(mutex) }

    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }

    public func withLockUnchecked<R>(_ body: () throws -> R) rethrows -> R {
        try withLock(body)
    }
}
