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
            try Data(key.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
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
