// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
#if canImport(Security)
import Security
#endif

#if !canImport(Security)
/// API-Schlüssel der KI-Server im Geheimnisdienst (libsecret über `secret-tool`), nie in den Einstellungen oder im Protokoll.
/// Ohne `secret-tool` oder ohne laufenden Dienst: Datei mit Rechten 0600 unter ~/.config/digidec.
enum LLMKeychain {
    private static let service = "com.peterbetz.digidec.llm"

    static func key(for provider: LLMProvider) -> String {
        if let result = secretTool(["lookup", "service", service, "account", provider.rawValue]), result.status == 0 {
            return String(decoding: result.output, as: UTF8.self)
        }
        return (try? String(contentsOf: fileURL(provider), encoding: .utf8)) ?? ""
    }

    @discardableResult
    static func setKey(_ key: String, for provider: LLMProvider) -> Bool {
        if key.isEmpty {
            let removed = secretTool(["clear", "service", service, "account", provider.rawValue])?.status == 0
            let file = (try? FileManager.default.removeItem(at: fileURL(provider))) != nil
            return removed || file
        }
        if secretTool(["store", "--label=Digidec \(provider.rawValue)", "service", service, "account", provider.rawValue], input: Data(key.utf8))?.status == 0 {
            try? FileManager.default.removeItem(at: fileURL(provider))
            return true
        }
        let url = fileURL(provider)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return writePrivate(Data(key.utf8), to: url)
        } catch { return false }
    }

    /// Schreibt die Datei so, dass sie zu keinem Zeitpunkt für andere lesbar ist: neue Datei mit 0600 anlegen, dann umbenennen
    private static func writePrivate(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    private static func fileURL(_ provider: LLMProvider) -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("digidec").appendingPathComponent("llm-\(provider.rawValue).key")
    }

    private static func secretTool(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["secret-tool"] + arguments
        let out = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = inp
        do { try process.run() } catch { return nil }
        // Ohne laufenden Geheimnisdienst wartet `secret-tool` auf die D-Bus-Aktivierung (bis 25 s): nach 5 s aufgeben, dann gilt die Datei
        let watchdog = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }
        if let input { inp.fileHandleForWriting.write(input) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
#else
/// API-Schlüssel der KI-Server im Schlüsselbund (je Server ein Eintrag), nie in den Einstellungen oder im Protokoll
enum LLMKeychain {
    private static let service = "com.peterbetz.digidec.llm"

    static func key(for provider: LLMProvider) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func setKey(_ key: String, for provider: LLMProvider) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
        if key.isEmpty { return SecItemDelete(base as CFDictionary) == errSecSuccess }
        let data = Data(key.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
#endif
