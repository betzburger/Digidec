// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für die Teilmenge von Network.framework, die der Web-Server nutzt (nur Linux): TCP-Listener und -Verbindungen über POSIX-Sockets.
//
// Regeln für die Dispatch-Quellen (libdispatch beendet sonst das Programm): Eine Quelle wird nie inaktiv oder angehalten freigegeben,
// und der Socket wird erst geschlossen, wenn alle Quellen auf ihm abgebrochen sind (im Abbruch-Handler).
import Foundation
import Glibc

public struct NWError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    init(errno code: Int32) { self.code = code; message = String(cString: strerror(code)) }
    public var errorDescription: String? { message }
}

public enum NWEndpoint: Sendable {
    public struct Port: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init(integerLiteral value: UInt16) { rawValue = value }
        public static let any = Port(integerLiteral: 0)
    }
    public struct Host: ExpressibleByStringLiteral, Sendable {
        public let name: String
        public init(stringLiteral value: String) { name = value }
        public init(_ name: String) { self.name = name }
    }
    case hostPort(host: Host, port: Port)
}

public final class NWParameters: @unchecked Sendable {
    public static var tcp: NWParameters { NWParameters() }
    public var allowLocalEndpointReuse = false
    public var requiredLocalEndpoint: NWEndpoint?
}

// MARK: - Hilfen

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

/// Schließt den Socket, sobald alle `count` Quellen abgebrochen sind (Abbruch-Handler laufen auf derselben seriellen Queue)
private final class SocketCloser: @unchecked Sendable {
    private let fd: Int32
    private var remaining: Int
    init(fd: Int32, sources: Int) { self.fd = fd; remaining = sources }
    func sourceCancelled() {
        remaining -= 1
        if remaining == 0 { close(fd) }
    }
}

// MARK: - Listener

public final class NWListener: @unchecked Sendable {
    public enum State: Sendable { case setup, waiting(NWError), ready, failed(NWError), cancelled }

    public var stateUpdateHandler: (@Sendable (State) -> Void)?
    public var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    public private(set) var port: NWEndpoint.Port?

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var queue: DispatchQueue?
    private let requestedPort: UInt16
    private let host: String?
    private let reuse: Bool

    public init(using parameters: NWParameters, on port: NWEndpoint.Port) throws {
        requestedPort = port.rawValue
        reuse = parameters.allowLocalEndpointReuse
        host = nil
    }

    public init(using parameters: NWParameters) throws {
        reuse = parameters.allowLocalEndpointReuse
        if case .hostPort(let host, let port)? = parameters.requiredLocalEndpoint {
            self.host = host.name; requestedPort = port.rawValue
        } else { host = nil; requestedPort = 0 }
    }

    deinit {
        // Ohne `cancel()` freigegeben: Quelle abbrechen, sie schließt den Socket selbst
        source?.cancel()
        if source == nil, fd >= 0 { close(fd) }
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        let opened: Result<Int32, NWError>
        if let host {
            opened = Self.bind(host: host, port: requestedPort, reuse: reuse)
        } else {
            // Ohne Rechnername: beide Protokolle in einem IPv6-Socket; ohne IPv6 nur IPv4
            switch Self.bind(host: "::", port: requestedPort, reuse: reuse, dualStack: true) {
            case .success(let s): opened = .success(s)
            case .failure(let e) where e.code == EAFNOSUPPORT || e.code == EADDRNOTAVAIL:
                opened = Self.bind(host: "0.0.0.0", port: requestedPort, reuse: reuse)
            case .failure(let e): opened = .failure(e)
            }
        }
        switch opened {
        case .failure(let error):
            queue.async { [stateUpdateHandler] in stateUpdateHandler?(.failed(error)) }
        case .success(let s):
            fd = s
            port = NWEndpoint.Port(rawValue: Self.localPort(s))
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptPending() }
            let closer = SocketCloser(fd: s, sources: 1)
            src.setCancelHandler { closer.sourceCancelled() }
            src.resume()
            source = src
            queue.async { [stateUpdateHandler] in stateUpdateHandler?(.ready) }
        }
    }

    public func cancel() {
        guard let src = source else { return }
        source = nil
        fd = -1
        src.cancel()
        let handler = stateUpdateHandler
        (queue ?? .main).async { handler?(.cancelled) }
    }

    /// Bindet einen lauschenden Socket an Adresse und Port (Rechnername, IPv4- oder IPv6-Adresse)
    private static func bind(host: String, port: UInt16, reuse: Bool, dualStack: Bool = false) -> Result<Int32, NWError> {
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else { return .failure(NWError(errno: rc == EAI_SYSTEM ? errno : EADDRNOTAVAIL)) }
        defer { freeaddrinfo(list) }
        var lastError = NWError(errno: EADDRNOTAVAIL)
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let s = socket(info.pointee.ai_family, info.pointee.ai_socktype | Int32(SOCK_CLOEXEC.rawValue), info.pointee.ai_protocol)
            guard s >= 0 else { lastError = NWError(errno: errno); continue }
            var one: Int32 = 1, off: Int32 = 0
            if reuse { setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
            if info.pointee.ai_family == AF_INET6 {
                var v6only = dualStack ? off : one
                setsockopt(s, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            }
            if Glibc.bind(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0, listen(s, 32) == 0 {
                setNonBlocking(s)
                return .success(s)
            }
            lastError = NWError(errno: errno)
            close(s)
        }
        return .failure(lastError)
    }

    private static func localPort(_ s: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(s, $0, &length) } }
        // sin_port und sin6_port liegen an derselben Stelle
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
    }

    private func acceptPending() {
        while fd >= 0 {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            setNonBlocking(client)
            var one: Int32 = 1
            setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let connection = NWConnection(descriptor: client)
            if let handler = newConnectionHandler { handler(connection) } else { connection.cancel() }
        }
    }
}

// MARK: - Verbindung

public final class NWConnection: @unchecked Sendable {
    public enum State: Sendable { case setup, preparing, waiting(NWError), ready, failed(NWError), cancelled }

    public struct ContentContext: Sendable {
        public static let defaultMessage = ContentContext()
        public static let finalMessage = ContentContext()
        public init() {}
    }

    public enum SendCompletion: Sendable {
        case contentProcessed(@Sendable (NWError?) -> Void)
        case idempotent
    }

    public var stateUpdateHandler: (@Sendable (State) -> Void)?

    private let fd: Int32
    private var queue = DispatchQueue.main
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Die Schreibquelle läuft (nur solange Daten auf einen beschreibbaren Socket warten); sonst ist sie angehalten
    private var writeActive = false
    private var started = false
    private var cancelled = false
    private var failed = false
    private var outgoing: [(data: Data, offset: Int, done: @Sendable (NWError?) -> Void)] = []
    private var pendingReceive: (min: Int, max: Int, handler: @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void)?
    private var received = Data()
    private var atEnd = false
    private var readError: NWError?

    init(descriptor: Int32) { fd = descriptor }

    deinit {
        if started { tearDownSources() } else { close(fd) }
    }

    public func start(queue: DispatchQueue) {
        guard !started, !cancelled else { return }
        started = true
        self.queue = queue
        let closer = SocketCloser(fd: fd, sources: 2)
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        r.setEventHandler { [weak self] in self?.readAvailable() }
        r.setCancelHandler { closer.sourceCancelled() }
        r.resume()
        readSource = r
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        w.setEventHandler { [weak self] in self?.flush() }
        w.setCancelHandler { closer.sourceCancelled() }
        // Aktivieren und sofort anhalten: so ist die Quelle nie inaktiv, und `flush` setzt sie nur bei Bedarf in Gang
        w.resume()
        w.suspend()
        writeSource = w
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.stateUpdateHandler?(.ready)
        }
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        let pending = outgoing
        outgoing.removeAll()
        if let request = pendingReceive { pendingReceive = nil; request.handler(nil, nil, true, nil) }
        if started {
            shutdown(fd, Int32(SHUT_RDWR))
            tearDownSources()
        } else {
            close(fd)
        }
        let handler = stateUpdateHandler
        let error = NWError(errno: ECANCELED)
        queue.async {
            pending.forEach { $0.done(error) }
            handler?(.cancelled)
        }
    }

    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {
        let done: @Sendable (NWError?) -> Void
        if case .contentProcessed(let handler) = completion { done = handler } else { done = { _ in } }
        queue.async { [self] in
            if cancelled || failed { done(NWError(errno: EPIPE)); return }
            guard let content, !content.isEmpty else { done(nil); return }
            outgoing.append((content, 0, done))
            if outgoing.count == 1 { flush() }
        }
    }

    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        queue.async { [self] in
            if cancelled { completion(nil, nil, true, nil); return }
            pendingReceive = (minimumIncompleteLength, maximumLength, completion)
            deliverIfPossible()
        }
    }

    // MARK: Intern (auf der Queue)

    /// Bricht beide Quellen ab; die Schreibquelle muss dafür laufen (eine angehaltene Quelle darf nicht freigegeben werden)
    private func tearDownSources() {
        readSource?.cancel()
        readSource = nil
        if let w = writeSource {
            if !writeActive { w.resume() }
            writeActive = true
            w.cancel()
        }
        writeSource = nil
    }

    private func flush() {
        guard !cancelled else { return }
        while let first = outgoing.first {
            let count = first.data.count - first.offset
            let written = first.data.withUnsafeBytes { send_(fd, $0.baseAddress! + first.offset, count) }
            if written > 0 {
                outgoing[0].offset += written
                if outgoing[0].offset >= first.data.count { outgoing.removeFirst().done(nil) }
                continue
            }
            let code = errno
            if written < 0, code == EINTR { continue }
            if written < 0, code == EAGAIN || code == EWOULDBLOCK {
                if !writeActive { writeActive = true; writeSource?.resume() }
                return
            }
            let error = NWError(errno: code)
            let pending = outgoing
            outgoing.removeAll()
            pending.forEach { $0.done(error) }
            fail(error)
            return
        }
        if writeActive { writeActive = false; writeSource?.suspend() }
    }

    private func readAvailable() {
        guard !cancelled else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let got = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if got > 0 {
            received.append(contentsOf: chunk[0..<got])
            deliverIfPossible()
            return
        }
        let code = errno
        if got < 0, code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return }
        // Ende oder Fehler: die Lesequelle meldet sich sonst endlos weiter
        readSource?.cancel()
        readSource = nil
        if got == 0 { atEnd = true } else { readError = NWError(errno: code) }
        deliverIfPossible()
        if let readError { fail(readError) }
    }

    private func deliverIfPossible() {
        guard let request = pendingReceive else { return }
        if received.count >= max(1, request.min) {
            pendingReceive = nil
            let data = takeReceived(request.max)
            request.handler(data, nil, (atEnd || readError != nil) && received.isEmpty, nil)
        } else if atEnd || readError != nil {
            pendingReceive = nil
            request.handler(received.isEmpty ? nil : takeReceived(request.max), nil, true, readError)
        }
    }

    private func takeReceived(_ limit: Int) -> Data {
        let n = min(limit, received.count)
        let out = Data(received.prefix(n))
        received.removeFirst(n)
        return out
    }

    private func fail(_ error: NWError) {
        guard !failed, !cancelled else { return }
        failed = true
        stateUpdateHandler?(.failed(error))
    }
}

private func send_(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
}
