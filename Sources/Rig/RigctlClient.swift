// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Stand des Funkgeräts laut rigctld des Commanders
public struct RigState: Equatable, Sendable {
    public var connected = false
    /// Rechner und Port des rigctld, zu dem die Verbindung gehört
    public var host: String?
    public var port: UInt16?
    public var frequencyHz: Int?
    /// Hamlib-Mode, z. B. "USB", "LSB", "PKTUSB", "RTTY", "AM"
    public var mode: String?
    public var passbandHz: Int?

    public init() {}

    /// Hamlib-Modes mit Kehrlage im NF (höhere Audiofrequenz = tiefere HF). fldigi: `reverse = REV xor !USB`.
    /// (GQRX: LSB und CWL; WFM, AM und die übrigen sind Regellage.)
    public static let invertingModes: Set<String> = ["LSB", "PKTLSB", "ECSSLSB", "RTTY", "CWR", "CWL"]

    /// `true` = Kehrlage (LSB), `false` = Regellage, `nil` = unbekannt
    public var isLSB: Bool? {
        guard let mode else { return nil }
        return Self.invertingModes.contains(mode.uppercased())
    }

    /// „4.584,700 kHz“
    public var frequencyText: String? {
        guard let f = frequencyHz else { return nil }
        let khz = Double(f) / 1000
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "de_DE")
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 3
        fmt.maximumFractionDigits = 3
        return (fmt.string(from: NSNumber(value: khz)) ?? String(format: "%.3f", khz)) + " kHz"
    }
}

/// Ergebnis eines Abstimmversuchs
public enum RigTuneResult: Equatable, Sendable {
    case ok
    case notConnected
    case rejected(String)
}

/// Ergebnis eines Verbindungstests (Knopf TESTEN im Dialog „Funkgerät“)
public enum RigProbeResult: Equatable, Sendable {
    case ok(RigState)
    case unreachable
    case noAnswer

    public var message: String {
        switch self {
        case .ok(let s):
            var t = "Verbunden"
            if let f = s.frequencyText { t += " · \(f)" }
            if let m = s.mode { t += " · \(m)" }
            if s.frequencyHz == nil { t += " · rigctld antwortet, aber das Funkgerät meldet keine Frequenz" }
            return t
        case .unreachable: return "Keine Verbindung – läuft rigctld auf diesem Rechner und Port?"
        case .noAnswer: return "Verbunden, aber keine Antwort auf „f“ und „m“ – ist das ein rigctld?"
        }
    }
}

/// Liest Frequenz und Mode von einem Hamlib-rigctld (die Commander: PCR-1500 Port 4532, FT-991A Port 4533; jedes andere Gerät
/// über seinen eigenen rigctld, Rechner und Port frei wählbar).
/// Standardmäßig **nur lesend** (`f`, `m`). Auf ausdrücklichen Wunsch des Nutzers (Schalter in der Kopfzeile) kann
/// `tune` die Frequenz und den Mode setzen – ausschließlich mit `F` und `M` (siehe `RigCommand`), nie PTT.
public final class RigctlClient: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.rigctl", qos: .utility)
    private let onUpdate: @Sendable (RigState) -> Void
    // Nur auf `queue`
    private var endpoint: RigEndpoint?
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var state = RigState()
    private var nextConnectAttempt = Date.distantPast

    public init(onUpdate: @escaping @Sendable (RigState) -> Void) {
        self.onUpdate = onUpdate
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Mit dem rigctld auf diesem Rechner (127.0.0.1) und `port` verbinden; `nil` trennt.
    public func setPort(_ newPort: UInt16?) {
        setEndpoint(newPort.map { RigEndpoint.loopback(port: $0) })
    }

    /// Mit einem rigctld auf beliebigem Rechner verbinden; `nil` trennt.
    public func setEndpoint(_ newEndpoint: RigEndpoint?) {
        queue.async { [self] in
            guard newEndpoint != endpoint else { return }
            closeSocket()
            endpoint = newEndpoint
            state = RigState()
            state.host = newEndpoint?.host
            state.port = newEndpoint?.port
            nextConnectAttempt = .distantPast
            publish()
            if newEndpoint == nil {
                timer?.cancel()
                timer = nil
            } else if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(100))
                t.setEventHandler { [weak self] in self?.poll() }
                timer = t
                t.resume()
            }
        }
    }

    /// Einmaliger Test ohne laufende Verbindung: verbinden, `f` und `m` fragen, wieder trennen. Rückmeldung auf einer Hintergrund-Queue.
    public static func probe(_ endpoint: RigEndpoint, completion: @escaping @Sendable (RigProbeResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = openConnection(to: endpoint)
            guard fd >= 0 else { completion(.unreachable); return }
            defer { close(fd) }
            guard let lines = exchange(fd: fd, command: "f\nm\n", expectedLines: 3) else { completion(.noAnswer); return }
            var state = parse(lines)
            state.host = endpoint.host
            state.port = endpoint.port
            completion(.ok(state))
        }
    }

    /// Stellt Frequenz und Mode des Funkgeräts über den rigctld des Commanders ein (`F`, danach `M`). Der Commander stellt
    /// sich dabei selbst um, seine Anzeige folgt. Die Rückmeldung kommt auf einer Hintergrund-Queue.
    public func tune(frequencyHz: Int64, mode: String?, passbandHz: Int?, dialect: RigDialect = .hamlib,
                     completion: @escaping @Sendable (RigTuneResult) -> Void) {
        queue.async { [self] in
            guard let endpoint else { completion(.notConnected); return }
            if fd < 0 {
                fd = Self.openConnection(to: endpoint)
                if fd < 0 { completion(.notConnected); return }
            }
            guard let fCommand = RigCommand.frequency(frequencyHz) else {
                completion(.rejected("Frequenz außerhalb des Bereichs")); return
            }
            guard let reply = exchange(fCommand, expectedLines: 1) else {
                closeSocket(); completion(.notConnected); return
            }
            guard reply.first == "RPRT 0" else {
                completion(.rejected(reply.first ?? "keine Antwort")); return
            }
            if let mode {
                guard let mCommand = RigCommand.mode(mode, passbandHz: passbandHz, dialect: dialect) else {
                    completion(.rejected("Mode \(mode) nicht erlaubt oder bei \(dialect.title) unbekannt")); return
                }
                guard let modeReply = exchange(mCommand, expectedLines: 1) else {
                    closeSocket(); completion(.notConnected); return
                }
                guard modeReply.first == "RPRT 0" else {
                    completion(.rejected(modeReply.first ?? "keine Antwort")); return
                }
            }
            completion(.ok)
            poll()   // neue Frequenz sofort anzeigen
        }
    }

    // MARK: - Nur auf `queue`

    private func poll() {
        guard let endpoint else { return }
        if fd < 0 {
            guard Date() >= nextConnectAttempt else { return }
            nextConnectAttempt = Date().addingTimeInterval(3)
            fd = Self.openConnection(to: endpoint)
            if fd < 0 {
                if state.connected || state.frequencyHz != nil {
                    state = freshState(endpoint)
                    publish()
                }
                return
            }
        }
        guard let lines = exchange("f\nm\n", expectedLines: 3) else {
            closeSocket()
            state = freshState(endpoint)
            publish()
            return
        }
        var new = Self.parse(lines)
        new.host = endpoint.host
        new.port = endpoint.port
        if new != state {
            state = new
            publish()
        }
    }

    private func freshState(_ endpoint: RigEndpoint) -> RigState {
        var s = RigState()
        s.host = endpoint.host
        s.port = endpoint.port
        return s
    }

    private func publish() {
        let s = state
        onUpdate(s)
    }

    private func closeSocket() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Befehle senden und Antwortzeilen lesen (Zeitlimit 1 s). `nil` bei Verbindungsfehler.
    private func exchange(_ command: String, expectedLines: Int) -> [String]? {
        Self.exchange(fd: fd, command: command, expectedLines: expectedLines)
    }

    private static func exchange(fd: Int32, command: String, expectedLines: Int) -> [String]? {
        let bytes = Array(command.utf8)
        let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, sendFlags) }
        guard sent == bytes.count else { return nil }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let lines = String(decoding: buffer, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let complete = lines.dropLast()           // letzte Zeile evtl. unvollständig
            if complete.count >= expectedLines || complete.contains(where: { $0.hasPrefix("RPRT") }) {
                return complete.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                return nil                             // Gegenseite hat geschlossen
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                return nil
            }
        }
        return nil
    }

    /// Beim Senden auf eine geschlossene Verbindung kein Signal auslösen (macOS: Socket-Option, Linux: Flag je Aufruf)
    private static var sendFlags: Int32 {
        #if os(Linux)
        return Int32(MSG_NOSIGNAL)
        #else
        return 0
        #endif
    }

    /// Verbindungsaufbau mit Zeitlimit (1,5 s je Adresse), damit ein nicht erreichbarer Rechner die Abfrage nicht aufhält.
    /// Rechnernamen werden aufgelöst (IPv4 und IPv6). Rückgabe: Dateikennung oder -1.
    static func openConnection(to endpoint: RigEndpoint, timeout: TimeInterval = 1.5) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let host = endpoint.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard getaddrinfo(host, String(endpoint.port), &hints, &result) == 0, let first = result else { return -1 }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let s = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if s >= 0 {
                #if !os(Linux)
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connectWithTimeout(s, info.pointee.ai_addr, info.pointee.ai_addrlen, timeout: timeout) { return s }
                close(s)
            }
            cursor = info.pointee.ai_next
        }
        return -1
    }

    // Die Namen `connect` und `poll` sind in der Klasse anders belegt: die Systemaufrufe ausdrücklich ansprechen
    private static func systemConnect(_ s: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(s, address, length)
        #else
        return Glibc.connect(s, address, length)
        #endif
    }

    private static func systemPoll(_ pfd: inout pollfd, _ milliseconds: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.poll(&pfd, 1, milliseconds)
        #else
        return Glibc.poll(&pfd, 1, milliseconds)
        #endif
    }

    /// `connect` im nicht blockierenden Modus mit `poll`; danach wieder blockierend
    private static func connectWithTimeout(_ s: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t, timeout: TimeInterval) -> Bool {
        guard let address else { return false }
        let flags = fcntl(s, F_GETFL)
        guard flags >= 0, fcntl(s, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
        var ok = systemConnect(s, address, length) == 0
        if !ok, errno == EINPROGRESS {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            if systemPoll(&pfd, Int32(timeout * 1000)) > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                ok = getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0
            }
        }
        _ = fcntl(s, F_SETFL, flags)
        return ok
    }

    /// Antwort auf `f` + `m` im einfachen rigctld-Protokoll: „4584700“, „LSB“, „2800“.
    /// Fehlerzeilen („RPRT -11“) machen den jeweiligen Wert unbekannt.
    public static func parse(_ lines: [String]) -> RigState {
        var s = RigState()
        s.connected = true
        var rest = lines[...]
        if let first = rest.first {
            rest = rest.dropFirst()
            if !first.hasPrefix("RPRT"), let f = Double(first) {
                s.frequencyHz = Int(f.rounded())
            }
        }
        if let mode = rest.first {
            rest = rest.dropFirst()
            // GQRX meldet auch WFM_ST und WFM_ST_OIRT
            if !mode.hasPrefix("RPRT"), !mode.isEmpty, mode.allSatisfy({ $0.isLetter || $0 == "_" }) {
                s.mode = mode.uppercased()
                if let pb = rest.first, let v = Int(pb) {
                    s.passbandHz = v
                }
            }
        }
        return s
    }

    /// rigctld-Port eines Commanders; berücksichtigt einen dort geänderten Port.
    public static func defaultPort(for radio: RadioSource) -> UInt16 {
        let (domain, key, fallback): (String, String, UInt16) = switch radio {
        case .pcr1500: ("com.peterbetz.pcr1500commander", "rigctldPort", 4532)
        case .ft991a:  ("com.peterbetz.ft991acommander", "ft991aRigctldPort", 4533)
        }
        let saved = UserDefaults(suiteName: domain)?.integer(forKey: key) ?? 0
        return (1025...65535).contains(saved) ? UInt16(saved) : fallback
    }
}
