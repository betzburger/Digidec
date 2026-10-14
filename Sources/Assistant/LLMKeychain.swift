// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Security

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
