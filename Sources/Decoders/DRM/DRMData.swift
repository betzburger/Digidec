// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// FAC (Fast Access Channel) und SDC (Service Description Channel) von DRM30: Kanalparameter, Dienste, Audioparameter, Datum.

public enum DRMAudioCoding: Int, Sendable {
    case aac = 0, reserved1 = 1, reserved2 = 2, xheaac = 3

    public var title: String {
        switch self {
        case .aac: return "AAC"
        case .xheaac: return "xHE-AAC"
        default: return "unbekannt"
        }
    }
}

public struct DRMAudioParam: Equatable, Sendable {
    public var streamID = 0
    public var coding = DRMAudioCoding.aac
    public var sbr = false
    /// 0 Mono, 1 Parametrisches Stereo, 2 Stereo
    public var mode = 0
    /// Abtastrate des AAC-Kerns in Hz (12000 oder 24000; mit SBR doppelt am Ausgang)
    public var sampleRate = 12_000
    public var textMessage = false
    /// xHE-AAC: Feld „codec specific config“ (xHE-AAC Static Config); MPEG-Surround-Betriebsart des Coder-Felds
    public var codecConfig: [UInt8] = []
    public var surroundMode = 0

    public var modeTitle: String { ["Mono", coding == .xheaac ? "reserviert" : "Stereo (parametrisch)", "Stereo", "?"][min(mode, 3)] }
    /// Ausgabe-Abtastrate (AAC: mit SBR doppelte Rate; xHE-AAC: die Rate des Felds ist schon die Ausgaberate)
    public var outputRate: Int { coding == .xheaac ? sampleRate : (sbr ? sampleRate * 2 : sampleRate) }
    /// Anzahl der AAC-Rahmen je Audio-Überrahmen (400 ms): 5 bei 12 kHz, 10 bei 24 kHz
    public var framesPerSuperframe: Int { sampleRate >= 24_000 ? 10 : 5 }

    /// Bits der Dateneinheit 9 hinter Kurzkennung und Stromnummer
    static func parse(type9 bits: ArraySlice<UInt8>) -> DRMAudioParam? {
        var p = bits.startIndex
        func get(_ n: Int) -> Int { defer { p += n }; return DRMCRC.value(bits[p..<(p + n)]) }
        guard bits.count >= 16 else { return nil }
        var a = DRMAudioParam()
        a.coding = DRMAudioCoding(rawValue: get(2)) ?? .reserved1
        a.sbr = get(1) == 1
        a.mode = get(2)
        let rate = get(3)
        if a.coding == .xheaac {
            a.sampleRate = [9_600, 12_000, 16_000, 19_200, 24_000, 32_000, 38_400, 48_000][rate]
        } else {
            switch rate {
            case 1: a.sampleRate = 12_000
            case 3: a.sampleRate = 24_000
            case 5: a.sampleRate = 48_000
            default: return nil
            }
        }
        a.textMessage = get(1) == 1
        if a.coding == .xheaac, bits.count >= 16 {
            a.sbr = false
            _ = get(1)                                   // enhancement flag
            a.surroundMode = get(3)
            _ = get(3)                                   // rfa 2 Bit und 1 Bit
            let rest = bits.endIndex - p
            a.codecConfig = (0..<(rest / 8)).map { _ in UInt8(get(8)) }
        }
        return a
    }
}

public struct DRMService: Equatable, Sendable {
    public var shortID = 0
    public var id: Int?
    public var label = ""
    public var language = 0
    public var isAudio = true
    public var descriptor = 0                // Programmtyp (Audio) oder Anwendung (Daten)
    public var caUsed = false
    public var audio: DRMAudioParam?

    public static let languages = ["keine Angabe", "Arabisch", "Bengali", "Chinesisch (Mandarin)", "Niederländisch", "Englisch", "Französisch", "Deutsch", "Hindi",
                                   "Japanisch", "Javanisch", "Koreanisch", "Portugiesisch", "Russisch", "Spanisch", "andere Sprache"]
    public static let programmeTypes = ["kein Programmtyp", "Nachrichten", "Aktuelles", "Information", "Sport", "Bildung", "Hörspiel", "Kultur", "Wissenschaft", "Vermischtes",
                                        "Pop", "Rock", "Easy Listening", "Leichte Klassik", "Ernste Klassik", "Andere Musik", "Wetter", "Wirtschaft", "Kinder",
                                        "Gesellschaft", "Religion", "Hörerbeteiligung", "Reise", "Freizeit", "Jazz", "Country", "Nationale Musik", "Oldies", "Folk", "Dokumentation"]

    public var languageTitle: String { Self.languages[min(language, 15)] }
    public var programmeTitle: String { isAudio && descriptor < Self.programmeTypes.count ? Self.programmeTypes[descriptor] : "" }
}

public struct DRMStream: Equatable, Sendable {
    public var lengthA = 0
    public var lengthB = 0
}

/// Kanalparameter aus dem FAC (72 Bit)
public struct DRMFAC: Equatable, Sendable {
    public var frameIdentity = 0               // 0, 1 oder 2: Rahmen im Überrahmen
    public var occupancy = DRMOccupancy.khz10
    public var longInterleaver = true
    /// 0: 64-QAM, 1: hierarchisch gemischt, 2: hierarchisch symmetrisch, 3: 16-QAM
    public var mscMode = 0
    /// 0: 16-QAM, 1: 4-QAM
    public var sdcMode = 0
    public var audioServices = 0
    public var dataServices = 0
    public var service = DRMService()

    static let serviceTable: [[Int]] = [[-1, 1, 2, 3, 15], [4, 5, 6, 7, -1], [8, 9, 10, -1, -1], [12, 13, -1, -1, -1], [0, -1, -1, -1, -1]]

    public var mscScheme: DRMScheme? { mscMode == 0 ? .qam64 : mscMode == 3 ? .qam16 : nil }
    public var sdcScheme: DRMScheme { sdcMode == 0 ? .qam16 : .qam4 }

    /// Prüft die CRC und liest die Felder; nil bei CRC-Fehler
    public static func parse(_ bits: [UInt8]) -> DRMFAC? {
        guard bits.count == 72, DRMCRC.compute(bits[0..<64], degree: 8) == DRMCRC.value(bits[64..<72]) else { return nil }
        var p = 0
        func get(_ n: Int) -> Int { defer { p += n }; return DRMCRC.value(bits[p..<(p + n)]) }
        var f = DRMFAC()
        _ = get(1)                                                   // Basis/Erweiterung
        let id = get(2)
        f.frameIdentity = id == 3 ? 0 : id
        guard let occ = DRMOccupancy(rawValue: get(4)) else { return nil }
        f.occupancy = occ
        f.longInterleaver = get(1) == 0
        f.mscMode = get(2)
        f.sdcMode = get(1)
        let count = get(4)
        for a in 0..<5 { for d in 0..<5 where serviceTable[a][d] == count { f.audioServices = a; f.dataServices = d } }
        _ = get(3); _ = get(2)                                       // Rekonfiguration, rfu
        f.service.id = get(24)
        f.service.shortID = get(2)
        f.service.caUsed = get(1) == 1
        f.service.language = get(4)
        f.service.isAudio = get(1) == 0
        f.service.descriptor = get(5)
        return f
    }

    /// FAC aus Parametern (für Sender und Prüfungen)
    public func encoded() -> [UInt8] {
        var b: [UInt8] = []
        b += DRMCRC.bits(0, 1)
        b += DRMCRC.bits(frameIdentity == 0 ? 3 : frameIdentity, 2)
        b += DRMCRC.bits(occupancy.rawValue, 4)
        b += DRMCRC.bits(longInterleaver ? 0 : 1, 1)
        b += DRMCRC.bits(mscMode, 2)
        b += DRMCRC.bits(sdcMode, 1)
        b += DRMCRC.bits(Self.serviceTable[audioServices][dataServices], 4)
        b += DRMCRC.bits(0, 5)
        b += DRMCRC.bits(service.id ?? 0, 24)
        b += DRMCRC.bits(service.shortID, 2)
        b += DRMCRC.bits(service.caUsed ? 1 : 0, 1)
        b += DRMCRC.bits(service.language, 4)
        b += DRMCRC.bits(service.isAudio ? 0 : 1, 1)
        b += DRMCRC.bits(service.descriptor, 5)
        b += DRMCRC.bits(0, 7)
        b += DRMCRC.bits(DRMCRC.compute(b[0..<64], degree: 8), 8)
        return b
    }
}

/// Inhalt des SDC (ein Überrahmen)
public struct DRMSDC: Equatable, Sendable {
    public var protectionA = 0
    public var protectionB = 0
    public var streams: [DRMStream] = []
    public var labels: [Int: String] = [:]
    public var audio: [Int: DRMAudioParam] = [:]
    public var languages: [Int: (language: String, country: String)] = [:]
    /// Datum (MJD) und Uhrzeit (UTC) der Aussendung
    public var modifiedJulianDay: Int?
    public var minutesOfDay: Int?

    public static func == (a: DRMSDC, b: DRMSDC) -> Bool {
        a.protectionA == b.protectionA && a.protectionB == b.protectionB && a.streams == b.streams && a.labels == b.labels && a.audio == b.audio
            && a.modifiedJulianDay == b.modifiedJulianDay && a.minutesOfDay == b.minutesOfDay
    }

    /// Bits des SDC-Blocks (Länge nach dem Decodieren) lesen; nil bei CRC-Fehler
    public static func parse(_ bits: [UInt8]) -> DRMSDC? {
        let dataBytes = (bits.count - 20) / 8
        let useful = 20 + dataBytes * 8
        guard dataBytes > 0, useful <= bits.count else { return nil }
        let crcCovered = [UInt8](repeating: 0, count: 4) + bits[0..<4] + bits[4..<(useful - 16)]
        guard DRMCRC.compute(crcCovered[...], degree: 16) == DRMCRC.value(bits[(useful - 16)..<useful]) else { return nil }
        var s = DRMSDC()
        var p = 4                                                    // AFS-Index
        let end = useful - 16
        func get(_ n: Int) -> Int { defer { p += n }; return DRMCRC.value(bits[p..<(p + n)]) }
        while p + 12 <= end {
            let length = get(7)
            if length == 0 { break }
            _ = get(1)
            let type = get(4)
            let bodyBits = length * 8 + 4
            guard p + bodyBits <= end else { break }
            let bodyStart = p
            switch type {
            case 0:
                s.protectionA = get(2); s.protectionB = get(2)
                for _ in 0..<(length / 3) where p + 24 <= bodyStart + bodyBits {
                    var st = DRMStream()
                    st.lengthA = get(12); st.lengthB = get(12)
                    s.streams.append(st)
                }
            case 1:
                let shortID = get(2); _ = get(2)
                let chars = (0..<length).map { _ in UInt8(get(8)) }
                s.labels[shortID] = Self.decodeLabel(chars)
            case 8:
                if length >= 3 {
                    s.modifiedJulianDay = get(17)
                    let h = get(5), m = get(6)
                    s.minutesOfDay = h * 60 + m
                }
            case 9:
                let shortID = get(2)
                let streamID = get(2)
                if var a = DRMAudioParam.parse(type9: bits[p..<(bodyStart + bodyBits)]) {
                    a.streamID = streamID
                    s.audio[shortID] = a
                }
            default: break
            }
            p = bodyStart + bodyBits
        }
        return s
    }

    /// Dienstname: UTF-8 (Label-Entität)
    static func decodeLabel(_ chars: [UInt8]) -> String {
        String(decoding: chars.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

public enum DRMDate {
    /// Modifiziertes Julianisches Datum → (Jahr, Monat, Tag)
    public static func fromMJD(_ mjd: Int) -> (year: Int, month: Int, day: Int) {
        let j = mjd + 2_400_001 + 68_569
        let c = 4 * j / 146_097
        var l = j - (146_097 * c + 3) / 4
        let i = 4000 * (l + 1) / 1_461_001
        l = l - 1461 * i / 4 + 31
        let k = 80 * l / 2447
        let day = l - 2447 * k / 80
        l = k / 11
        return (100 * (c - 49) + i + l, k + 2 - 12 * l, day)
    }
}

/// Textnachricht (Radiotext) von DRM: je Audio-Überrahmen vier Bytes am Ende des Stroms; Segmente beginnen mit vier Bytes 0xFF, dann Kopf (2 Byte),
/// Körper (bis 16 Byte) und CRC-16. Bis zu acht Segmente, ein Umschaltbit trennt Nachrichten.
public struct DRMTextMessage: Sendable {
    private var buffer: [UInt8] = []
    private var segments: [Int: [UInt8]] = [:]
    private var lastSegment: Int?
    private var toggle: Int?
    public private(set) var text = ""

    public init() {}

    /// Vier Bytes eines Überrahmens aufnehmen; Rückgabe: true, wenn sich der Text geändert hat
    public mutating func feed(_ piece: [UInt8]) -> Bool {
        guard piece.count == 4 else { return false }
        if piece == [0xFF, 0xFF, 0xFF, 0xFF] {
            defer { buffer.removeAll() }
            return finish()
        }
        if buffer.count < 2 + 16 + 2 { buffer += piece }
        return false
    }

    private mutating func finish() -> Bool {
        guard buffer.count >= 4 else { return false }
        let bits = buffer.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } }
        let t = Int(bits[0]), first = bits[1] == 1, last = bits[2] == 1, command = bits[3] == 1
        let field1 = DRMCRC.value(bits[4..<8]), field2 = DRMCRC.value(bits[8..<12])
        if command {
            let length = 0
            guard buffer.count >= 2 + length + 2, DRMCRC.compute(bits[0..<(16 + length * 8)], degree: 16) == DRMCRC.value(bits[(16 + length * 8)..<(32 + length * 8)]) else { return false }
            if field1 == 1 { segments.removeAll(); lastSegment = nil; let changed = !text.isEmpty; text = ""; return changed }
            return false
        }
        let length = field1 + 1
        guard buffer.count >= 2 + length + 2 else { return false }
        let covered = 16 + length * 8
        guard DRMCRC.compute(bits[0..<covered], degree: 16) == DRMCRC.value(bits[covered..<(covered + 16)]) else { return false }
        if toggle != t { segments.removeAll(); lastSegment = nil; toggle = t }
        let number = first ? 0 : (field2 & 7)
        let body = Array(buffer[2..<(2 + length)])
        if let old = segments[number], old != body { segments.removeAll(); lastSegment = nil }
        segments[number] = body
        if last { lastSegment = number }
        guard let end = lastSegment, (0...end).allSatisfy({ segments[$0] != nil }) else { return false }
        let joined = (0...end).flatMap { segments[$0]! }
        let new = Self.decode(joined)
        let changed = new != text
        text = new
        return changed
    }

    static func decode(_ bytes: [UInt8]) -> String {
        // Steuerzeichen: 0x0A Zeilenumbruch, 0x0B Ende der Überschrift, 0x1F weicher Trennstrich
        var out = [UInt8]()
        for b in bytes {
            switch b {
            case 0x0A, 0x0B: out.append(0x20)
            case 0x1F: break
            default: if b >= 0x20 { out.append(b) }
            }
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
