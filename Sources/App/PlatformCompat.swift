// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
#if canImport(AppKit)
#if canImport(AppKit)
import AppKit
#endif
#endif

#if !canImport(Darwin)
// Linux: `ProcessInfo.beginActivity` (App Nap / Ruhezustand verhindern) gibt es nicht. Die Aufrufe bleiben gleich und tun nichts;
// ein Ruhezustandsverhinderer (systemd-inhibit) kann später hier eingehängt werden.
extension ProcessInfo {
    struct ActivityOptions: OptionSet, Sendable {
        let rawValue: UInt64
        static let idleSystemSleepDisabled = ActivityOptions(rawValue: 1 << 20)
        static let userInitiated = ActivityOptions(rawValue: 0x00FF_FFFF | (1 << 20))
        static let background = ActivityOptions(rawValue: 0xFF)
    }

    func beginActivity(options: ActivityOptions, reason: String) -> NSObjectProtocol { NSObject() }
    func endActivity(_ activity: NSObjectProtocol) {}
}
#endif

/// Ordner oder Datei mit dem Dateimanager des Systems öffnen (Finder bzw. `xdg-open`)
enum PlatformOpener {
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        #endif
    }
}
