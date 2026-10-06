// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Nachgebauter rigctld für die Logiktests (macOS und Linux): hört auf 127.0.0.1, merkt sich Frequenz und Mode,
// antwortet auf f, m, F, M und protokolliert alle Befehle. Nicht Teil der App.
// `.gqrx` verhält sich wie GQRX Remote Control (am echten GQRX am 06.10.2026 gemessen): kennt nur AM, AMS, LSB, USB, CWL, CWU, FM, WFM, WFM_ST;
// alles andere (RTTY, PKTUSB …) beantwortet es mit „RPRT 1“, Bandbreite 0 ergibt die Voreinstellung des Modes.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class FakeRigctld: @unchecked Sendable {
    enum Behavior { case normal, silent, gqrx }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var received: [String] = []
    private var frequency = 14_074_000
    private var mode: String
    private var passband: Int
    private let behavior: Behavior

    static let gqrxModes: [String: Int] = ["AM": 5000, "AMS": 5000, "LSB": 2700, "USB": 2700, "CWL": 500, "CWU": 500,
                                           "FM": 10_000, "WFM": 160_000, "WFM_ST": 160_000]
    private var connections = 0

    var commands: [String] { lock.withLock { received } }
    var connectionCount: Int { lock.withLock { connections } }
    var currentFrequency: Int { lock.withLock { frequency } }
    var currentMode: String { lock.withLock { mode } }

    init?(behavior: Behavior = .normal) {
        self.behavior = behavior
        mode = behavior == .gqrx ? "FM" : "USB"
        passband = behavior == .gqrx ? 10_000 : 2400
        #if os(Linux)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
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
        Thread.detachNewThread { [self] in self.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            lock.withLock { connections += 1 }
            Thread.detachNewThread { [self] in self.serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        var buf = [UInt8](repeating: 0, count: 256)
        var pending = ""
        while true {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            pending += String(decoding: buf[0..<n], as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                let cmd = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                lock.withLock { received.append(cmd) }
                if behavior == .silent { continue }
                let reply = answer(cmd)
                _ = reply.withCString { send(c, $0, strlen($0), 0) }
            }
        }
        close(c)
    }

    private func answer(_ cmd: String) -> String {
        lock.withLock {
            let parts = cmd.split(separator: " ").map(String.init)
            switch parts.first {
            case "f": return "\(frequency)\n"
            case "m": return "\(mode)\n\(passband)\n"
            case "F":
                guard parts.count == 2, let hz = Int(parts[1]) else { return "RPRT -1\n" }
                frequency = hz
                return "RPRT 0\n"
            case "M":
                guard parts.count == 3, let pb = Int(parts[2]) else { return "RPRT -1\n" }
                if behavior == .gqrx {
                    guard let standard = Self.gqrxModes[parts[1]] else { return "RPRT 1\n" }
                    mode = parts[1]
                    passband = pb == 0 ? standard : pb
                    return "RPRT 0\n"
                }
                mode = parts[1]
                passband = pb == 0 ? 2400 : pb
                return "RPRT 0\n"
            default: return "RPRT -4\n"
            }
        }
    }

    deinit {
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }
}
