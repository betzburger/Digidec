// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für die Teilmenge von Network.framework, die der Web-Server nutzt (nur Linux): TCP-Listener und -Verbindungen über POSIX-Sockets.
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

// MARK: - Listener

public final class NWListener: @unchecked Sendable {
    public enum State: Sendable { case setup, waiting(NWError), ready, failed(NWError), cancelled }

    public var stateUpdateHandler: (@Sendable (State) -> Void)?
    public var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    public private(set) var port: NWEndpoint.Port?

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
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

    public func start(queue: DispatchQueue) {
        // Ohne Rechnername: beide Protokolle (IPv6 mit IPv4 im selben Socket), sonst nur die genannte IPv4-Adresse
        if host == nil, let status = open(family: AF_INET6, address: nil) ?? nil { fail(status, queue); return }
        if fd < 0, let status = open(family: AF_INET, address: host ?? "0.0.0.0") ?? nil { fail(status, queue); return }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.acceptPending(queue) }
        s.resume()
        source = s
        stateUpdateHandler?(.ready)
    }

    public func cancel() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        stateUpdateHandler?(.cancelled)
    }

    private func fail(_ error: NWError, _ queue: DispatchQueue) {
        queue.async { [stateUpdateHandler] in stateUpdateHandler?(.failed(error)) }
    }

    /// `.some(nil)` = geöffnet, `.some(Fehler)` = Fehler, `nil` = Familie nicht verfügbar (Rückfall auf IPv4)
    private func open(family: Int32, address: String?) -> NWError?? {
        let s = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        guard s >= 0 else { return .some(NWError(errno: errno)) }
        var one: Int32 = 1
        if reuse { setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let status: Int32
        if family == AF_INET6 {
            var off: Int32 = 0
            setsockopt(s, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = requestedPort.bigEndian
            a.sin6_addr = in6addr_any
            status = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = requestedPort.bigEndian
            inet_pton(AF_INET, address ?? "0.0.0.0", &a.sin_addr)
            status = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard status == 0, listen(s, 16) == 0 else {
            let code = errno
            close(s)
            // IPv6 nicht verfügbar: stiller Rückfall auf IPv4
            if family == AF_INET6, code == EAFNOSUPPORT || code == EADDRNOTAVAIL { return nil }
            return .some(NWError(errno: code))
        }
        setNonBlocking(s)
        fd = s
        // Tatsächlichen Port ermitteln (bei Port 0)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(s, $0, &length) } }
        let raw: UInt16 = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        port = NWEndpoint.Port(rawValue: raw)
        return .some(nil)
    }

    private func acceptPending(_ queue: DispatchQueue) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            setNonBlocking(client)
            var one: Int32 = 1
            setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            newConnectionHandler?(NWConnection(descriptor: client))
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
    private var writeActive = false
    private var cancelled = false
    private var outgoing: [(data: Data, offset: Int, done: @Sendable (NWError?) -> Void)] = []
    private var pendingReceive: (min: Int, max: Int, handler: @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void)?
    private var received = Data()

    init(descriptor: Int32) { fd = descriptor }

    deinit { if !cancelled { close(fd) } }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        r.setEventHandler { [weak self] in self?.readAvailable() }
        r.resume()
        readSource = r
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        w.setEventHandler { [weak self] in self?.flush() }
        writeSource = w
        queue.async { [weak self] in self?.stateUpdateHandler?(.ready) }
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        readSource?.cancel(); readSource = nil
        if writeActive { writeSource?.resume() }
        writeSource?.cancel(); writeSource = nil
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
        let handler = stateUpdateHandler
        queue.async { handler?(.cancelled) }
    }

    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {
        let done: @Sendable (NWError?) -> Void
        if case .contentProcessed(let handler) = completion { done = handler } else { done = { _ in } }
        let work: @Sendable () -> Void = { [self] in
            guard !cancelled, let content, !content.isEmpty else { done(cancelled ? NWError(errno: EPIPE) : nil); return }
            outgoing.append((content, 0, done))
            flush()
        }
        queue.async(execute: work)
    }

    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        queue.async { [self] in
            pendingReceive = (minimumIncompleteLength, maximumLength, completion)
            deliverIfPossible()
        }
    }

    // MARK: Intern (auf der Queue)

    private func flush() {
        while let first = outgoing.first {
            let count = first.data.count - first.offset
            let written = first.data.withUnsafeBytes { send_(fd, $0.baseAddress! + first.offset, count) }
            if written > 0 {
                outgoing[0].offset += written
                if outgoing[0].offset >= first.data.count { outgoing.removeFirst().done(nil) }
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if !writeActive { writeActive = true; writeSource?.resume() }
                return
            }
            let error = NWError(errno: errno)
            let pending = outgoing
            outgoing.removeAll()
            pending.forEach { $0.done(error) }
            fail(error)
            return
        }
        if writeActive { writeActive = false; writeSource?.suspend() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let got = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if got > 0 {
            received.append(contentsOf: chunk[0..<got])
            deliverIfPossible()
        } else if got == 0 {
            readSource?.cancel(); readSource = nil
            if let request = pendingReceive { pendingReceive = nil; request.handler(received.isEmpty ? nil : takeReceived(request.max), nil, true, nil) }
            else { atEnd = true }
        } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            let error = NWError(errno: errno)
            if let request = pendingReceive { pendingReceive = nil; request.handler(nil, nil, true, error) }
            fail(error)
        }
    }

    private var atEnd = false

    private func deliverIfPossible() {
        guard let request = pendingReceive else { return }
        if received.count >= max(1, request.min) {
            pendingReceive = nil
            request.handler(takeReceived(request.max), nil, false, nil)
        } else if atEnd {
            pendingReceive = nil
            request.handler(nil, nil, true, nil)
        }
    }

    private func takeReceived(_ limit: Int) -> Data {
        let n = min(limit, received.count)
        let out = received.prefix(n)
        received.removeFirst(n)
        return Data(out)
    }

    private func fail(_ error: NWError) {
        let handler = stateUpdateHandler
        handler?(.failed(error))
    }
}

private func send_(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
}
