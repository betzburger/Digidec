import Foundation
import Darwin

/// Stand des Funkgeräts laut rigctld des Commanders
public struct RigState: Equatable, Sendable {
    public var connected = false
    public var port: UInt16?
    public var frequencyHz: Int?
    /// Hamlib-Mode, z. B. "USB", "LSB", "PKTUSB", "RTTY", "AM"
    public var mode: String?
    public var passbandHz: Int?

    public init() {}

    /// Hamlib-Modes mit Kehrlage im NF (höhere Audiofrequenz = tiefere HF). fldigi: `reverse = REV xor !USB`.
    public static let invertingModes: Set<String> = ["LSB", "PKTLSB", "ECSSLSB", "RTTY", "CWR"]

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

/// Liest Frequenz und Mode vom Hamlib-rigctld der Commander (PCR-1500: 4532, FT-991A: 4533).
/// Standardmäßig **nur lesend** (`f`, `m`). Auf ausdrücklichen Wunsch des Nutzers (Schalter in der Kopfzeile) kann
/// `tune` die Frequenz und den Mode setzen – ausschließlich mit `F` und `M` (siehe `RigCommand`), nie PTT.
public final class RigctlClient: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.rigctl", qos: .utility)
    private let onUpdate: @Sendable (RigState) -> Void
    // Nur auf `queue`
    private var port: UInt16?
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var state = RigState()
    private var nextConnectAttempt = Date.distantPast

    public init(onUpdate: @escaping @Sendable (RigState) -> Void) {
        self.onUpdate = onUpdate
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Mit rigctld auf `port` (localhost) verbinden; `nil` trennt.
    public func setPort(_ newPort: UInt16?) {
        queue.async { [self] in
            guard newPort != port else { return }
            closeSocket()
            port = newPort
            state = RigState()
            state.port = newPort
            nextConnectAttempt = .distantPast
            publish()
            if newPort == nil {
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

    /// Stellt Frequenz und Mode des Funkgeräts über den rigctld des Commanders ein (`F`, danach `M`). Der Commander stellt
    /// sich dabei selbst um, seine Anzeige folgt. Die Rückmeldung kommt auf einer Hintergrund-Queue.
    public func tune(frequencyHz: Int64, mode: String?, passbandHz: Int?, completion: @escaping @Sendable (RigTuneResult) -> Void) {
        queue.async { [self] in
            guard let port else { completion(.notConnected); return }
            if fd < 0 {
                fd = Self.connectLocalhost(port: port)
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
                guard let mCommand = RigCommand.mode(mode, passbandHz: passbandHz) else {
                    completion(.rejected("Mode \(mode) nicht erlaubt")); return
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
        guard let port else { return }
        if fd < 0 {
            guard Date() >= nextConnectAttempt else { return }
            nextConnectAttempt = Date().addingTimeInterval(3)
            fd = Self.connectLocalhost(port: port)
            if fd < 0 {
                if state.connected || state.frequencyHz != nil {
                    state = RigState()
                    state.port = port
                    publish()
                }
                return
            }
        }
        guard let lines = exchange("f\nm\n", expectedLines: 3) else {
            closeSocket()
            state = RigState()
            state.port = port
            publish()
            return
        }
        var new = Self.parse(lines)
        new.port = port
        if new != state {
            state = new
            publish()
        }
    }

    private func publish() {
        let s = state
        onUpdate(s)
    }

    private func closeSocket() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Befehle senden und Antwortzeilen lesen (Zeitlimit 1 s). `nil` bei Verbindungsfehler.
    private func exchange(_ command: String, expectedLines: Int) -> [String]? {
        let bytes = Array(command.utf8)
        let sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
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
            let n = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
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

    private static func connectLocalhost(port: UInt16) -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 {
            Darwin.close(s)
            return -1
        }
        return s
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
            if !mode.hasPrefix("RPRT"), !mode.isEmpty, mode.allSatisfy({ $0.isLetter }) {
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
