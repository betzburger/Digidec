// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Nachgebauter OpenAI-kompatibler Server für die Logiktests (hört auf 127.0.0.1): beantwortet POST /v1/chat/completions als Ereignisstrom
// oder mit einem Fehler und GET /v1/models; protokolliert Pfad, Kopfzeilen und Körper der letzten Anfrage. Nicht Teil der App.
import Foundation
import Darwin

final class FakeLLMServer: @unchecked Sendable {
    enum Behavior { case stream([String]), status(Int, String) }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var behavior: Behavior
    private var _lastPath = ""
    private var _lastHeaders: [String: String] = [:]
    private var _lastBody = Data()

    var lastPath: String { lock.withLock { _lastPath } }
    var lastBody: Data { lock.withLock { _lastBody } }
    func header(_ name: String) -> String? { lock.withLock { _lastHeaders[name.lowercased()] } }

    init?(_ behavior: Behavior) {
        self.behavior = behavior
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0, listen(s, 4) == 0 else { close(s); return nil }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = s
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(listenFD, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { [self] in serve(c) }
            }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { return }
            data.append(contentsOf: buf[0..<n])
            headEnd = data.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(decoding: data[..<headEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let request = lines.removeFirst()
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        var body = Data(data[headEnd!.upperBound...])
        let want = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < want {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: buf[0..<n])
        }
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let current: Behavior = lock.withLock { _lastPath = path; _lastHeaders = headers; _lastBody = body; return behavior }
        func send(_ s: String) { _ = s.withCString { Darwin.send(c, $0, strlen($0), 0) } }
        if path.hasSuffix("/models") {
            let json = #"{"data":[{"id":"gpt-fake","name":"Fake","architecture":{"input_modalities":["text","image"]}},{"id":"nur-text","architecture":{"input_modalities":["text"]}}]}"#
            send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)")
            return
        }
        switch current {
        case .status(let code, let json):
            send("HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)")
        case .stream(let events):
            send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
            for e in events { send(e + "\n\n"); usleep(2000) }
        }
    }

    deinit {
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }
}
