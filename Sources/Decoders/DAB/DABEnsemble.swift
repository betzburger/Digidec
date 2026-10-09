// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Schutz eines Teilkanals
public enum DABProtection: Equatable, Sendable {
    /// Ungleicher Fehlerschutz (Kurzform): Tabellenindex der Norm
    case uep(tableIndex: Int)
    /// Gleicher Fehlerschutz: Profil A oder B, Stufe 1 … 4
    case eep(profileB: Bool, level: Int)
}

/// Ein Teilkanal im Hauptdienstkanal (FIG 0/1)
public struct DABSubchannel: Equatable, Sendable {
    public var id: Int
    /// Startadresse in Kapazitätseinheiten (0 … 863)
    public var startAddress: Int
    /// Länge in Kapazitätseinheiten
    public var length: Int
    public var protection: DABProtection

    /// Nettodatenrate in kbit/s
    public var bitrate: Int {
        switch protection {
        case .uep(let i): return i < DABTables.uepIndex.count ? DABTables.uepIndex[i].bitrate : 0
        case .eep(let b, let level):
            if b {
                switch level { case 1: return length / 27 * 32; case 2: return length / 21 * 32; case 3: return length / 18 * 32; default: return length / 15 * 32 }
            }
            switch level { case 1: return length / 12 * 8; case 2: return length / 8 * 8; case 3: return length / 6 * 8; default: return length / 4 * 8 }
        }
    }

    public var protectionText: String {
        switch protection {
        case .uep(let i): return "UEP \(i < DABTables.uepIndex.count ? DABTables.uepIndex[i].level : 0)"
        case .eep(let b, let level): return "EEP \(level)-\(b ? "B" : "A")"
        }
    }
}

public struct DABComponent: Equatable, Sendable {
    public var subchannelId: Int
    /// Audio-Dienstkomponententyp: 0 = DAB (MPEG-1 Layer II), 63 = DAB+ (HE-AAC)
    public var audioType: Int
    public var primary: Bool
    /// Transportart: 0 Audio, 1 Datenstrom, 3 Paketdaten
    public var transport: Int
}

public struct DABService: Equatable, Identifiable, Sendable {
    public var id: UInt32 { sid }
    public var sid: UInt32
    public var label = ""
    public var shortLabelFlags: UInt16 = 0
    public var components: [DABComponent] = []
    /// Programmtyp (FIG 0/17), 0 = keiner
    public var programType = 0

    public var primaryAudio: DABComponent? { components.first { $0.transport == 0 && $0.primary } ?? components.first { $0.transport == 0 } }
    public var isDABPlus: Bool { primaryAudio?.audioType == 63 }
}

/// Ensemble-Daten aus den FIG: Name, Dienste, Teilkanäle, Uhrzeit
public final class DABEnsemble {
    public private(set) var ensembleId: UInt16 = 0
    public private(set) var label = ""
    public private(set) var subchannels: [Int: DABSubchannel] = [:]
    public private(set) var services: [UInt32: DABService] = [:]
    /// Datum und Uhrzeit des Senders (FIG 0/10), UTC
    public private(set) var time: Date?
    /// Landeskennung
    public private(set) var ecc = 0
    /// Anzahl verarbeiteter FIB (zur Anzeige, ob sich etwas getan hat)
    public private(set) var fibCount = 0
    /// Ändert sich bei jeder Neuerung der Liste (für die Oberfläche)
    public private(set) var revision = 0
    private var seen: [UInt32: Int] = [:]

    public init() {}

    public func reset() {
        ensembleId = 0; label = ""; subchannels = [:]; services = [:]; time = nil; seen = [:]; revision += 1
    }

    /// Dienste, die zuverlässig gehört wurden, nach Namen sortiert
    public var serviceList: [DABService] {
        services.values.filter { !$0.components.isEmpty && !$0.label.isEmpty }.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    public func subchannel(of service: DABService) -> DABSubchannel? {
        service.primaryAudio.flatMap { subchannels[$0.subchannelId] }
    }

    // MARK: FIB

    /// Ein FIB (30 Nutzbytes) auswerten
    public func process(fib: [UInt8]) {
        fibCount += 1
        var pos = 0
        while pos < 30 {
            let header = fib[pos]
            if header == 0xFF { break }
            let type = Int(header >> 5)
            let length = Int(header & 0x1F)
            guard length > 0, pos + 1 + length <= 30 else { break }
            let data = Array(fib[(pos + 1)..<(pos + 1 + length)])
            switch type {
            case 0: figType0(data)
            case 1: figType1(data)
            default: break
            }
            pos += 1 + length
        }
    }

    private func bits(_ d: [UInt8], _ offset: Int, _ count: Int) -> Int {
        var v = 0
        for i in 0..<count {
            let b = offset + i
            guard b / 8 < d.count else { return v << (count - i) }
            v = (v << 1) | Int((d[b / 8] >> UInt8(7 - b % 8)) & 1)
        }
        return v
    }

    private func figType0(_ d: [UInt8]) {
        guard !d.isEmpty else { return }
        let pd = Int(d[0] >> 5) & 1
        let ext = Int(d[0] & 0x1F)
        let body = Array(d.dropFirst())
        switch ext {
        case 0: fig0_0(body)
        case 1: fig0_1(body)
        case 2: fig0_2(body, pd: pd)
        case 9: if body.count >= 3 { ecc = Int(body[2]) }
        case 10: fig0_10(body)
        case 17: fig0_17(body)
        default: break
        }
    }

    private func fig0_0(_ d: [UInt8]) {
        guard d.count >= 4 else { return }
        let id = UInt16(d[0]) << 8 | UInt16(d[1])
        if id != ensembleId { ensembleId = id; revision += 1 }
    }

    /// Teilkanalorganisation
    private func fig0_1(_ d: [UInt8]) {
        var off = 0
        while off + 3 <= d.count {
            let id = bits(d, off * 8, 6)
            let start = bits(d, off * 8 + 6, 10)
            let long = bits(d, off * 8 + 16, 1)
            var sub: DABSubchannel
            if long == 0 {
                let ix = bits(d, off * 8 + 18, 6)
                guard ix < DABTables.uepIndex.count else { return }
                sub = DABSubchannel(id: id, startAddress: start, length: DABTables.uepIndex[ix].cu, protection: .uep(tableIndex: ix))
                off += 3
            } else {
                guard off + 4 <= d.count else { return }
                let option = bits(d, off * 8 + 17, 3)
                let level = bits(d, off * 8 + 20, 2) + 1
                let size = bits(d, off * 8 + 22, 10)
                guard option <= 1 else { off += 4; continue }
                sub = DABSubchannel(id: id, startAddress: start, length: size, protection: .eep(profileB: option == 1, level: level))
                off += 4
            }
            if subchannels[id] != sub { subchannels[id] = sub; revision += 1 }
        }
    }

    /// Dienstorganisation
    private func fig0_2(_ d: [UInt8], pd: Int) {
        var off = 0
        while true {
            let idBytes = pd == 1 ? 4 : 2
            guard off + idBytes + 1 <= d.count else { return }
            let sid = pd == 1 ? UInt32(bits(d, off * 8, 32)) : UInt32(bits(d, off * 8, 16))
            off += idBytes
            let count = Int(d[off] & 0x0F)
            off += 1
            guard off + count * 2 <= d.count else { return }
            var comps = [DABComponent]()
            for _ in 0..<count {
                let tmid = bits(d, off * 8, 2)
                switch tmid {
                case 0, 1:
                    comps.append(DABComponent(subchannelId: bits(d, off * 8 + 8, 6), audioType: tmid == 0 ? bits(d, off * 8 + 2, 6) : -1,
                                              primary: bits(d, off * 8 + 14, 1) == 1, transport: tmid))
                default:
                    comps.append(DABComponent(subchannelId: -1, audioType: -1, primary: bits(d, off * 8 + 14, 1) == 1, transport: tmid))
                }
                off += 2
            }
            // erst nach mehrfachem Empfang aufnehmen (verhindert Phantomdienste durch Bitfehler)
            seen[sid, default: 0] += 1
            if seen[sid]! >= 2 {
                var s = services[sid] ?? DABService(sid: sid)
                if s.components != comps { s.components = comps; services[sid] = s; revision += 1 } else if services[sid] == nil { services[sid] = s; revision += 1 }
            }
        }
    }

    private func fig0_10(_ d: [UInt8]) {
        guard d.count >= 4 else { return }
        let mjd = bits(d, 1, 17)
        let utcFlag = bits(d, 18, 1)
        guard utcFlag == 1, d.count >= 5 else {
            return
        }
        let hours = bits(d, 20, 5), minutes = bits(d, 25, 6)
        // Modifiziertes Julianisches Datum: 40587 = 1970-01-01
        let seconds = Double(mjd - 40587) * 86_400 + Double(hours * 3600 + minutes * 60)
        time = Date(timeIntervalSince1970: seconds)
    }

    /// Programmtyp (FIG 0/17): je Eintrag Kennung (2 Byte), Flags (L: Sprache folgt, CC: Zusatzbyte), optional Sprache, Programmtyp (5 Bit)
    private func fig0_17(_ d: [UInt8]) {
        var off = 0
        while off + 4 <= d.count {
            let sid = UInt32(d[off]) << 8 | UInt32(d[off + 1])
            let flags = d[off + 2]
            let language = flags & 0x20 != 0
            let cc = flags & 0x10 != 0
            var p = off + 3
            if language { p += 1 }
            guard p < d.count else { return }
            let pty = Int(d[p] & 0x1F)
            if var s = services[sid], s.programType != pty { s.programType = pty; services[sid] = s; revision += 1 }
            off = p + 1 + (cc ? 1 : 0)
        }
    }

    /// Bezeichnungen (FIG 1)
    private func figType1(_ d: [UInt8]) {
        guard d.count >= 19 else { return }
        let charset = Int(d[0] >> 4)
        let oe = Int(d[0] >> 3) & 1
        let ext = Int(d[0] & 0x07)
        guard oe == 0 else { return }
        let id = Int(d[1]) << 8 | Int(d[2])
        let raw = Array(d[3..<19])
        let flags = d.count >= 21 ? UInt16(d[19]) << 8 | UInt16(d[20]) : 0
        let text = DABCharset.decode(raw, charset: charset).trimmingCharacters(in: .whitespaces)
        switch ext {
        case 0:
            if label != text { label = text; revision += 1 }
        case 1:
            let sid = UInt32(id)
            var s = services[sid] ?? DABService(sid: sid)
            if s.label != text { s.label = text; s.shortLabelFlags = flags; services[sid] = s; revision += 1 }
        default: break
        }
    }
}
