// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Serielle Schnittstelle (POSIX) mit Zeitgrenzen. Ein Zugriff zugleich (der Aufrufer sperrt).
final class SerialPort: @unchecked Sendable {
    private let fd: Int32

    init(path: String, baud: Int) throws {
        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw VoiceError.io("\(path): \(String(cString: strerror(errno)))") }
        // Nur ein Prozess zugleich (verhindert, dass zwei Programme dieselben Pakete lesen)
        if ioctl(descriptor, UInt(TIOCEXCL)) != 0 {
            close(descriptor)
            throw VoiceError.io("\(path): belegt")
        }
        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CS8) | tcflag_t(CREAD) | tcflag_t(CLOCAL)
        settings.c_cflag &= ~(tcflag_t(CSTOPB) | tcflag_t(PARENB) | tcflag_t(CRTSCTS))
        #if canImport(Darwin)
        settings.c_cc.16 = 0   // VMIN
        settings.c_cc.17 = 0   // VTIME
        cfsetspeed(&settings, speed_t(baud))
        #else
        settings.c_cc.6 = 0    // VMIN
        settings.c_cc.5 = 0    // VTIME
        guard let speed = Self.linuxSpeed(baud) else {
            close(descriptor)
            throw VoiceError.io("\(path): Baudrate \(baud) nicht unterstützt")
        }
        cfsetspeed(&settings, speed)
        #endif
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            close(descriptor)
            throw VoiceError.io("\(path): Einstellung fehlgeschlagen")
        }
        tcflush(descriptor, TCIOFLUSH)
        fd = descriptor
    }

    deinit { close(fd) }

    #if !canImport(Darwin)
    /// Unter Linux sind die Geschwindigkeiten Konstanten (B…), nicht die Baudrate selbst
    private static func linuxSpeed(_ baud: Int) -> speed_t? {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        case 460800: return speed_t(B460800)
        case 921600: return speed_t(B921600)
        default: return nil
        }
    }
    #endif

    func flushInput() { tcflush(fd, TCIFLUSH) }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(1.0)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { sysWrite(fd, $0.baseAddress! + offset, bytes.count - offset) }
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
            let got = result.withUnsafeMutableBytes { sysRead(fd, $0.baseAddress! + offset, count - offset) }
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

// Auf Dateiebene, damit die Namen nicht von den gleichnamigen Methoden der Klasse verdeckt werden
private func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
private func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
