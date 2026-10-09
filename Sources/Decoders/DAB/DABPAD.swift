// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Programmbegleitende Daten (PAD) der DAB+-Audio-Zugriffseinheiten: Dynamic Label (laufender Titel, Sendungsname) nach ETSI EN 300 401 Abschnitt 7.4.5 und TS 102 563.
/// Nicht ausgewertet: DL Plus (Titel-Tags) und MOT (Diashow).
public final class DABPADDecoder {
    /// Ein vollständiger Text (neu oder geändert); leer nach dem Befehl „Text löschen“
    public var onLabel: ((String) -> Void)?
    public private(set) var label = ""

    private struct Indicator { var len: Int; var type: Int }
    private static let lengths = [4, 6, 8, 12, 16, 24, 32, 48]
    private var lastIndicator: Indicator?

    // Datengruppe des Textes
    private var group = [UInt8]()
    private var needed = 4
    // Teilstücke je Nummer
    private var segments: [Int: [UInt8]] = [:]
    private var lastSegment = -1
    private var toggle: Bool?
    private var charset = 0

    public init() {}

    public func reset() {
        lastIndicator = nil; group.removeAll(); needed = 4; segments.removeAll(); lastSegment = -1; toggle = nil; label = ""
    }

    /// Eine Zugriffseinheit (ohne CRC) auf PAD durchsuchen und auswerten
    public func process(accessUnit au: [UInt8]) {
        var xpad = [UInt8](), fpad: [UInt8] = [0, 0]
        if au.count >= 3 && (au[0] >> 5) == 4 {                 // Datenstrom-Element
            var start = 2
            var length = Int(au[1])
            if length == 255 { length += Int(au[2]); start += 1 }
            if length >= 2 && au.count >= start + length {
                xpad = Array(au[start..<(start + length - 2)])
                fpad = Array(au[(start + length - 2)..<(start + length)])
            }
        }
        process(xpad: xpad, fpad: fpad)
    }

    /// `xpad` in der Reihenfolge des Rahmens (die Bytes sind verkehrt herum gespeichert), `fpad` die letzten zwei Bytes
    public func process(xpad raw: [UInt8], fpad: [UInt8]) {
        let xpad = Array(raw.reversed())
        let type = Int(fpad[0] >> 6)
        let indicator = Int(fpad[0] & 0x30) >> 4
        let ciFlag = fpad[1] & 0x02 != 0
        let previous = lastIndicator
        lastIndicator = nil
        var cis = [Indicator]()
        var ciBytes = -1
        if type == 0 {
            if ciFlag {
                if indicator == 1 {                              // kurzes X-PAD: ein Typ, Datenfeld von 3 Byte
                    guard xpad.count >= 1 else { return }
                    let t = Int(xpad[0] & 0x1F)
                    if t != 0 { ciBytes = 1; cis.append(Indicator(len: 3, type: t)) }
                } else if indicator == 2 {                        // X-PAD mit Längenangaben (bis zu vier)
                    ciBytes = 0
                    for i in 0..<4 {
                        guard xpad.count >= i + 1 else { return }
                        let ci = xpad[i]
                        ciBytes += 1
                        if ci & 0x1F == 0 { break }
                        cis.append(Indicator(len: Self.lengths[Int(ci >> 5)], type: Int(ci & 0x1F)))
                    }
                }
            } else if indicator == 1 || indicator == 2, let p = previous {
                ciBytes = 0
                cis.append(p)
            }
        }
        guard !cis.isEmpty else { return }
        var announced = ciBytes
        for c in cis { announced += c.len }
        guard announced <= xpad.count else { return }
        var offset = ciBytes
        var continued: Int?
        for c in cis {
            let field = Array(xpad[offset..<(offset + c.len)])
            switch c.type {
            case 2, 3:
                subfield(start: c.type == 2, field)
                continued = 3
            case 1:
                continued = 1
            default: break
            }
            offset += c.len
        }
        if let t = continued { lastIndicator = Indicator(len: offset, type: t) }
    }

    // MARK: Datengruppe

    private func subfield(start: Bool, _ data: [UInt8]) {
        if start { group.removeAll(); needed = 4 } else if group.isEmpty { return }
        if group.count >= needed && !start { return }
        group.append(contentsOf: data.prefix(max(0, 20 - group.count)))
        guard group.count >= needed else { return }
        decodeGroup()
    }

    private func decodeGroup() {
        let command = group[0] & 0x10 != 0
        var fieldLength = 0
        var remove = false
        if command {
            switch group[0] & 0x0F {
            case 0x01: remove = true
            default: group.removeAll(); needed = 4; return        // DL Plus und andere Befehle werden nicht ausgewertet
            }
        } else {
            fieldLength = Int(group[0] & 0x0F) + 1
        }
        let real = 2 + fieldLength
        needed = real + 2
        guard group.count >= needed else { return }
        let stored = UInt16(group[real]) << 8 | UInt16(group[real + 1])
        let calc = DABCRC.crc16(Array(group[0..<real]))
        defer { group.removeAll(); needed = 4 }
        guard stored == calc else { return }
        if remove {
            segments.removeAll(); lastSegment = -1
            if !label.isEmpty { label = ""; onLabel?("") }
            return
        }
        let prefix0 = group[0], prefix1 = group[1]
        let t = prefix0 & 0x80 != 0
        let first = prefix0 & 0x40 != 0
        let last = prefix0 & 0x20 != 0
        let number = first ? 0 : Int((prefix1 >> 4) & 0x07)
        if let old = toggle, old != t { segments.removeAll(); lastSegment = -1 }
        toggle = t
        if first { charset = Int(prefix1 >> 4) }
        segments[number] = Array(group[2..<real])
        if last { lastSegment = number }
        guard lastSegment >= 0, (0...lastSegment).allSatisfy({ segments[$0] != nil }) else { return }
        var bytes = [UInt8]()
        for i in 0...lastSegment { bytes.append(contentsOf: segments[i]!) }
        let text = DABCharset.decode(bytes, charset: charset).replacingOccurrences(of: "\u{0A}", with: " ").replacingOccurrences(of: "\u{0B}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text != label { label = text; onLabel?(text) }
    }
}
