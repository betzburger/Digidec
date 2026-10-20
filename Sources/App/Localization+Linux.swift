// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

#if !canImport(Darwin)
// Linux: Foundation kennt `String(localized:)` nicht. Der Schlüssel ist wie unter macOS der deutsche Ausgangstext;
// übersetzt wird aus `<Sprache>.lproj/Localizable.strings` neben der Programmdatei (Bundle.main.resourceURL) bzw. im Quellbaum.
extension String {
    struct LocalizationValue: ExpressibleByStringLiteral, Sendable {
        let key: String
        init(stringLiteral value: String) { key = value }
    }

    init(localized value: LocalizationValue) {
        self = LinuxStrings.translate(value.key)
    }
}

enum LinuxStrings {
    private static let table: [String: String] = load()

    static func translate(_ key: String) -> String { table[key] ?? key }

    /// Sprachcode: `DIGIDEC_LANG`, sonst die Wahl im Menü (`AppLanguage` = de/en, „system“ = Umgebung), sonst die Umgebung
    /// („de_DE.UTF-8“ → „de“); ohne Angabe die Ausgangssprache Deutsch
    static var language: String {
        let env = ProcessInfo.processInfo.environment
        if let forced = env["DIGIDEC_LANG"], !forced.isEmpty { return String(forced.prefix { $0.isLetter }) }
        if let chosen = UserDefaults.standard.string(forKey: "AppLanguage"), chosen == "de" || chosen == "en" { return chosen }
        return environmentLanguage
    }

    /// Sprache der Sitzung (Gebietsschema-Variablen); ohne Angabe Deutsch
    static var environmentLanguage: String {
        let env = ProcessInfo.processInfo.environment
        for name in ["LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"] {
            if let value = env[name], !value.isEmpty, value != "C", value != "POSIX" {
                return String(value.prefix { $0.isLetter })
            }
        }
        return "de"
    }

    private static func load() -> [String: String] {
        var roots: [URL] = []
        if let res = Bundle.main.resourceURL { roots.append(res) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { roots.append(exe) }
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        for root in roots {
            let url = root.appendingPathComponent("\(language).lproj/Localizable.strings")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return parse(text)
        }
        return [:]
    }

    /// `"Schlüssel" = "Wert";` je Eintrag (altes Plist-Format, mit Fluchtfolgen \" \\ \n \t)
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var chars = Substring(text)
        func skipSpace() {
            while let c = chars.first {
                if c.isWhitespace { chars.removeFirst() }
                else if chars.hasPrefix("/*") { if let r = chars.range(of: "*/") { chars = chars[r.upperBound...] } else { chars = "" } }
                else if chars.hasPrefix("//") { if let r = chars.firstIndex(of: "\n") { chars = chars[r...] } else { chars = "" } }
                else { break }
            }
        }
        func quoted() -> String? {
            guard chars.first == "\"" else { return nil }
            chars.removeFirst()
            var out = ""
            while let c = chars.first {
                chars.removeFirst()
                if c == "\"" { return out }
                if c == "\\", let e = chars.first {
                    chars.removeFirst()
                    switch e { case "n": out.append("\n"); case "t": out.append("\t"); case "r": out.append("\r"); default: out.append(e) }
                } else { out.append(c) }
            }
            return nil
        }
        while true {
            skipSpace()
            guard let key = quoted() else { break }
            skipSpace()
            guard chars.first == "=" else { break }
            chars.removeFirst(); skipSpace()
            guard let value = quoted() else { break }
            skipSpace()
            if chars.first == ";" { chars.removeFirst() }
            result[key] = value
        }
        return result
    }
}
#endif
