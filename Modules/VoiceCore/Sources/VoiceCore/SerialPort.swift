// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Darwin

/// Serielle Schnittstelle (POSIX) mit Zeitgrenzen. Ein Zugriff zugleich (der Aufrufer sperrt).
final class SerialPort: @unchecked Sendable {
    private let fd: Int32

    init(path: String, baud: Int) throws {
        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw VoiceError.io("\(path): \(String(cString: strerror(errno)))") }
        // Nur ein Prozess zugleich (verhindert, dass zwei Programme dieselben Pakete lesen)
        if ioctl(descriptor, TIOCEXCL) != 0 {
            close(descriptor)
            throw VoiceError.io("\(path): belegt")
        }
        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL)
        settings.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CRTSCTS)
        settings.c_cc.16 = 0   // VMIN
        settings.c_cc.17 = 0   // VTIME
        cfsetspeed(&settings, speed_t(baud))
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            close(descriptor)
            throw VoiceError.io("\(path): Einstellung fehlgeschlagen")
        }
        tcflush(descriptor, TCIOFLUSH)
        fd = descriptor
    }

    deinit { close(fd) }

    func flushInput() { tcflush(fd, TCIFLUSH) }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(1.0)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 { offset += written; continue }
            if written < 0, errno != EAGAIN, errno != EINTR { throw VoiceError.io(String(cString: strerror(errno))) }
            guard Date() < deadline else { throw VoiceError.timeout }
            var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&item, 1, 50)
        }
    }

    /// Liest genau `count` Bytes oder wirft `timeout`.
    func read(count: Int, timeout: TimeInterval) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < count {
            let got = result.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if got > 0 { offset += got; continue }
            if got < 0, errno != EAGAIN, errno != EINTR { throw VoiceError.io(String(cString: strerror(errno))) }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw VoiceError.timeout }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&item, 1, Int32(max(1, min(remaining * 1000, 100))))
        }
        return result
    }
}
