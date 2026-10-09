// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Mitgelieferte Dokumente (Lizenz, Quellen) und ein kleiner Markdown-Leser für die Anzeige im Programm

/// Dokumente, die im Info-Fenster erscheinen. Im App-Bundle liegen sie unter `Contents/Resources`
/// (`build_app.sh` kopiert sie dorthin); beim Start aus dem Quellbaum (`swift run`, Tests) werden sie im Projektordner gesucht.
public enum LicenseDocument: String, CaseIterable, Sendable {
    case license = "LICENSE"
    case thirdParty = "THIRD_PARTY.md"

    /// Mögliche Orte, in dieser Reihenfolge
    public func candidates(bundleResources: URL?, projectRoot: URL?) -> [URL] {
        var urls: [URL] = []
        if let bundleResources { urls.append(bundleResources.appendingPathComponent(rawValue)) }
        if let projectRoot { urls.append(projectRoot.appendingPathComponent(rawValue)) }
        return urls
    }

    /// Text des Dokuments; nil, wenn es nirgends liegt
    public func load(bundleResources: URL? = Bundle.main.resourceURL, projectRoot: URL? = LicenseDocument.defaultProjectRoot) -> String? {
        for url in candidates(bundleResources: bundleResources, projectRoot: projectRoot) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        }
        return nil
    }

    /// Projektordner beim Start aus dem Quellbaum (`swift run`, Tests): ab dem Programmordner und dem aktuellen Verzeichnis nach oben
    /// suchen, bis eine `Package.swift` neben der Lizenzdatei liegt. Kein Pfad wird ins Programm eingebaut.
    public static var defaultProjectRoot: URL? {
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL { starts.append(exe.deletingLastPathComponent()) }
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        for start in starts {
            var dir = start
            for _ in 0..<8 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path),
                   FileManager.default.fileExists(atPath: dir.appendingPathComponent(LicenseDocument.license.rawValue).path) {
                    return dir
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }
}

/// Block eines einfachen Markdown-Texts
public enum MarkdownBlock: Equatable, Sendable {
    /// Überschrift der Ebene 1 … 3
    case heading(level: Int, text: String)
    case paragraph(String)
    /// Listenpunkt mit Einrückungsebene (0 = oberste)
    case bullet(level: Int, text: String)
}

/// Liest das, was `THIRD_PARTY.md` braucht: Überschriften (`#` bis `###`), Listen (`-`, eingerückt = tiefer), Absätze.
/// Das Innere der Zeilen (fett, `Code`, Links) bleibt Markdown und wird von der Anzeige gesetzt. Keine Tabellen, keine Codeblöcke.
public enum MarkdownLite {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if let heading = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if let item = bulletText(line) {
                flush()
                blocks.append(.bullet(level: item.level, text: item.text))
            } else if case .bullet(let level, let previous)? = blocks.last, paragraph.isEmpty, line.first == " " {
                // Fortsetzungszeile eines Listenpunkts (eingerückt, ohne eigenes „-“)
                blocks[blocks.count - 1] = .bullet(level: level, text: previous + " " + trimmed)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...3).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ line: String) -> (level: Int, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard rest.hasPrefix("- ") else { return nil }
        return (indent / 2, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
