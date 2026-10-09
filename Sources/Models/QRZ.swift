// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// QRZ.com-Abfrage: Rufzeichen im Text erkennen, auf das Grundrufzeichen zurückführen und die Adresse der Seite bilden.
/// Digidec ruft nichts von selbst ab; erst der Knopf lädt die Seite von qrz.com (übermittelt wird nur das Rufzeichen in der Adresse).
public enum QRZ {
    public static let host = "www.qrz.com"

    /// Form eines Amateurfunk-Rufzeichens ohne Zusätze: Präfix aus 1 bis 3 Zeichen (mindestens ein Buchstabe), die letzte Ziffer, danach 1 bis 4 Buchstaben
    /// (DL1ABC, W1AW, 9A1A, VK2TPM, 3DA0XY, K1A). Wörter, „RR73“, „FT8“ und Zahlen passen nicht.
    public static func isCallsign(_ s: String) -> Bool {
        let c = Array(s.uppercased())
        guard (3...8).contains(c.count), c.allSatisfy({ ($0.isASCII && $0.isLetter) || $0.isASCII && $0.isNumber }), c[0] != "0",
              let d = c.lastIndex(where: \.isNumber) else { return false }
        // Ein Maidenhead-Locator mit sechs Zeichen („JN49WS“) hat dieselbe Form, ist aber kein Rufzeichen
        if c.count == 6, c[0...1].allSatisfy({ "ABCDEFGHIJKLMNOPQR".contains($0) }), c[2...3].allSatisfy(\.isNumber), c[4...5].allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWX".contains($0) }) { return false }
        let prefix = c[..<d], suffix = c[(d + 1)...]
        return (1...3).contains(prefix.count) && prefix.contains(where: \.isLetter) && (1...4).contains(suffix.count) && suffix.allSatisfy(\.isLetter)
    }

    /// Grundrufzeichen für die Abfrage: ohne Klammern, ohne SSID („DL1ABC-9“, APRS), ohne Zusätze (`/P`, `/M`, `/QRP`, `/7`) und bei einem Gastland-Präfix
    /// (`EA8/DL1ABC`) das Heimatrufzeichen. nil, wenn nichts Rufzeichenähnliches darin steht.
    public static func baseCall(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        // SSID hinter dem Strich („-9“, „-15“)
        if let dash = s.lastIndex(of: "-"), s[s.index(after: dash)...].allSatisfy(\.isNumber), (1...2).contains(s.distance(from: dash, to: s.endIndex) - 1) {
            s = String(s[..<dash])
        }
        let parts = s.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let calls = parts.filter(isCallsign)
        // bei zwei Treffern („EA8/DL1ABC“ gibt EA8 nicht her; „DL1ABC/W1“ ebenso) das längere nehmen
        return calls.max { $0.count < $1.count }
    }

    /// Adresse der Seite zum Rufzeichen
    public static func url(for call: String) -> URL? {
        guard let base = baseCall(call) else { return nil }
        return URL(string: "https://\(host)/db/\(base)")
    }

    /// Rufzeichen in einem Text (Meldung, Zeile), in der Reihenfolge des Auftretens, ohne Doppelte (nach dem Grundrufzeichen)
    public static func callsigns(in text: String, limit: Int = 4) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for token in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "<" || $0 == ">") }) {
            guard let call = baseCall(String(token)), seen.insert(call).inserted else { continue }
            out.append(call)
            if out.count >= limit { break }
        }
        return out
    }
}
