// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Einfache Darstellung der Modellantwort: Überschriften werden fett, Aufzählungszeichen zu Punkten, Trennlinien zu einer Linie, Tabellenzeilen bleiben Text;
/// Fett, Kursiv und Code innerhalb der Zeile übernimmt das Markdown von Foundation.
public enum AssistantMarkdown {
    public static func render(_ text: String) -> AttributedString {
        var out = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            var line = raw
            var heading = false
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), Set(trimmed).count == 1 {
                line = String(repeating: "─", count: 24)
            } else if let r = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line = String(trimmed[r.upperBound...])
                heading = true
            } else if let r = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                let indent = line[r].prefix { $0 == " " }
                line = indent + "• " + line[r.upperBound...]
            }
            var part = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
            if heading { part.inlinePresentationIntent = .stronglyEmphasized }
            out.append(part)
            if i < lines.count - 1 { out.append(AttributedString("\n")) }
        }
        return out
    }
}
