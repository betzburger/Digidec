// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Obere MAC-Schicht und Signalisierung von TETRA (ETSI EN 300 392-2 Kapitel 21, EN 300 392-2 Kapitel 14 und 16):
// MAC-Rahmen (RESOURCE, FRAG/END, BROADCAST), Zerlegen in Rufbefehle der Vermittlung (CMCE) und Kurznachrichten (SDS).
// Es werden nur unverschlüsselte Nachrichten ausgewertet: bei einem Verschlüsselungsmodus ungleich 0 bleibt der Inhalt unlesbar.

// MARK: - Bitleser

struct TETRABitReader {
    let bits: [UInt8]
    var pos = 0
    init(_ bits: [UInt8], pos: Int = 0) {
        self.bits = bits
        self.pos = pos
    }
    var remaining: Int { bits.count - pos }
    mutating func read(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            v = (v << 1) | (pos < bits.count ? Int(bits[pos] & 1) : 0)
            pos += 1
        }
        return v
    }
    mutating func flag() -> Bool { read(1) == 1 }
    mutating func skip(_ n: Int) { pos += n }
}

// MARK: - Adressen

public struct TETRAAddress: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case null = 0, ssi = 1, eventLabel = 2, ussi = 3, smi = 4, ssiEvent = 5, ssiUsage = 6, smiEvent = 7
    }
    public var kind: Kind
    public var ssi: Int?
    public var eventLabel: Int?
    public var usageMarker: Int?

    public var description: String {
        switch kind {
        case .null: return "-"
        case .eventLabel: return "E\(eventLabel ?? 0)"
        default:
            var s = String(ssi ?? 0)
            if let e = eventLabel { s += "/E\(e)" }
            if let u = usageMarker { s += "/U\(u)" }
            return s
        }
    }
}

/// Kanalzuweisung (EN 300 392-2, 21.5.2): auf welchem Träger und in welchen Zeitschlitzen läuft das Gespräch
public struct TETRAChannelAllocation: Equatable, Sendable {
    public var type = 0
    public var timeslots: [Int] = []           // 1…4
    public var uplinkDownlink = 0
    public var carrier = 0
    public var band: Int?
    public var offset: Int?
    public var duplex: Int?
    public var reverse: Bool?
}

// MARK: - Netz

public struct TETRANetworkInfo: Equatable, Sendable {
    public var mcc = 0
    public var mnc = 0
    public var colourCode = 0
    public var locationArea = 0
    public var mainCarrier = 0
    public var band = 0
    public var offsetIndex = 0
    public var duplex = 0
    public var reverse = false
    public var serviceDetails = 0
    public var subscriberClass = 0
    public var downlinkHz = 0.0
    public var uplinkHz: Double?
    public var hyperframe: Int?
    public var cckID: Int?

    public var registrationMandatory: Bool { serviceDetails & (1 << 11) != 0 }
    public var voiceService: Bool { serviceDetails & (1 << 5) != 0 }
    public var airEncryption: Bool { serviceDetails & (1 << 1) != 0 }
    public var sndcp: Bool { serviceDetails & (1 << 2) != 0 }
    public var circuitData: Bool { serviceDetails & (1 << 4) != 0 }
    public var migration: Bool { serviceDetails & (1 << 7) != 0 }
}

// MARK: - Rufe

/// Grunddaten eines Gesprächs aus der Rufsignalisierung
public struct TETRACallSignal: Equatable, Sendable {
    public enum Kind: String, Sendable { case setup = "D-SETUP", connect = "D-CONNECT", txGranted = "D-TX GRANTED", txCeased = "D-TX CEASED", release = "D-RELEASE", proceeding = "D-CALL PROCEEDING", disconnect = "D-DISCONNECT", info = "D-INFO", alert = "D-ALERT", status = "D-STATUS" }
    public var kind: Kind
    public var callID: Int
    /// Gerufene Adresse aus dem MAC-Kopf (bei Gruppenrufen die Gruppe)
    public var address: TETRAAddress
    /// Rufender oder sendender Teilnehmer
    public var party: Int?
    public var usageMarker: Int?
    public var allocation: TETRAChannelAllocation?
    /// Gruppenruf (1), Einzelruf (0) usw. nach der Dienstangabe; nil, wenn nicht enthalten
    public var communicationType: Int?
    public var circuitModeType: Int?
    public var encryptedCall = false
    public var simplex = true
    public var priority: Int?
    public var transmissionGrant: Int?
    public var disconnectCause: Int?
    public var status: Int?
}

public struct TETRASDSMessage: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var protocolID: Int?
    public var text: String?
    public var data: [UInt8]
    public var messageType = 0
    public var viaGroup = false
    public var length = 0
}

/// Ergebnis der Auswertung eines Steuerblocks
public enum TETRASignal: Sendable {
    case network(TETRANetworkInfo)
    case call(TETRACallSignal)
    case sds(TETRASDSMessage)
    /// Kennung, die im MAC-Kopf einer Nachricht auftauchte (Teilnehmeraktivität)
    case address(Int, String)
    case encrypted(TETRAAddress)
    case note(String)
}

// MARK: - Obere MAC-Schicht

public final class TETRAUpperMAC: @unchecked Sendable {
    public var onSignal: ((TETRASignal, TETRATime) -> Void)?
    private var network = TETRANetworkInfo()
    private var haveCell = false

    private struct Fragment {
        var bits: [UInt8]
        var address: TETRAAddress
        var allocation: TETRAChannelAllocation?
        var encrypted: Bool
        var start: TETRATime
        var parts = 1
    }
    private var fragments: [Int: Fragment] = [:]

    public init() {}

    public func reset() {
        fragments.removeAll()
        haveCell = false
    }

    public func setCell(mcc: Int, mnc: Int, colourCode: Int) {
        network.mcc = mcc
        network.mnc = mnc
        network.colourCode = colourCode
    }

    // MARK: Block

    public func process(_ block: TETRAMacBlock) {
        guard block.crcOK else { return }
        let bits = block.bits
        guard bits.count >= 16 else { return }
        var pos = 0
        var guardCount = 0
        while pos + 16 <= bits.count && guardCount < 8 {
            guardCount += 1
            let type = Int(TETRA.uint(bits, pos, 2))
            switch type {
            case 0:
                guard let end = parseResource(bits, at: pos, block: block) else { return }
                pos = end
            case 1:
                parseFragment(bits, at: pos, block: block)
                return
            case 2:
                parseBroadcast(bits, at: pos, block: block)
                return
            default:
                return
            }
        }
    }

    // MARK: MAC-BROADCAST

    private func parseBroadcast(_ bits: [UInt8], at start: Int, block: TETRAMacBlock) {
        let sub = Int(TETRA.uint(bits, start + 2, 2))
        guard sub == 0, bits.count >= start + 124 else { return }       // SYSINFO
        var r = TETRABitReader(bits, pos: start + 4)
        var n = network
        n.mainCarrier = r.read(12)
        n.band = r.read(4)
        n.offsetIndex = r.read(2)
        n.duplex = r.read(3)
        n.reverse = r.flag()
        r.skip(2 + 3 + 4 + 4 + 4)                              // gemeinsame Zusatzkanäle, Sendeleistung, Empfangspegel, Zugriff, Zeitablauf
        let cckFlag = r.flag()
        let v = r.read(16)
        if cckFlag { n.cckID = v; n.hyperframe = nil } else { n.hyperframe = v; n.cckID = nil }
        // MLE-Systeminformation: Standortbereich 14, Teilnehmerklasse 16, Dienstangaben 12
        var m = TETRABitReader(bits, pos: start + 124 - 42)
        n.locationArea = m.read(14)
        n.subscriberClass = m.read(16)
        n.serviceDetails = m.read(12)
        n.downlinkHz = TETRA.downlinkFrequencyHz(band: n.band, carrier: n.mainCarrier, offsetIndex: n.offsetIndex)
        n.uplinkHz = TETRA.uplinkFrequencyHz(band: n.band, carrier: n.mainCarrier, offsetIndex: n.offsetIndex, duplex: n.duplex, reverse: n.reverse)
        guard n.serviceDetails != 0 else { return }
        network = n
        haveCell = true
        onSignal?(.network(n), block.time)
    }

    // MARK: MAC-RESOURCE

    private func decodeAddress(_ r: inout TETRABitReader) -> TETRAAddress? {
        guard let kind = TETRAAddress.Kind(rawValue: r.read(3)) else { return nil }
        var a = TETRAAddress(kind: kind)
        switch kind {
        case .null: break
        case .ssi, .ussi, .smi: a.ssi = r.read(24)
        case .eventLabel: a.eventLabel = r.read(10)
        case .ssiEvent, .smiEvent: a.ssi = r.read(24); a.eventLabel = r.read(10)
        case .ssiUsage: a.ssi = r.read(24); a.usageMarker = r.read(6)
        }
        return a
    }

    private func decodeAllocation(_ r: inout TETRABitReader) -> TETRAChannelAllocation {
        var c = TETRAChannelAllocation()
        c.type = r.read(2)
        let ts = r.read(4)
        c.timeslots = (0..<4).filter { (ts >> (3 - $0)) & 1 == 1 }.map { $0 + 1 }
        c.uplinkDownlink = r.read(2)
        r.skip(2)                                            // Erlaubnis für Gemeinschaftskanal, Zellwechsel
        c.carrier = r.read(12)
        if r.flag() {
            c.band = r.read(4)
            c.offset = r.read(2)
            c.duplex = r.read(3)
            c.reverse = r.flag()
        }
        let monitoring = r.read(2)
        if monitoring == 0 { r.skip(2) }
        if c.uplinkDownlink == 0 {
            // Erweiterte Zuweisung (nicht für π/4-DQPSK gebräuchlich): Felder überspringen
            r.skip(2 + 3 + 3 + 3 + 3 + 3 + 4 + 5)
            let napping = r.read(2)
            if napping == 1 { r.skip(11) }
            r.skip(4)
            if r.flag() { r.skip(16) }
            if r.flag() { r.skip(16) }
            r.skip(1)
        }
        return c
    }

    /// Länge der PDU in Bits laut Längenangabe; nil = unbrauchbar, -1 = Fortsetzung folgt, -2 = zweiter Halbschlitz geraubt
    private func lengthBits(_ indication: Int) -> Int? {
        if indication == 0 || indication == 0x3B || indication == 0x3C || indication == 0x3D { return nil }
        if indication <= 0x3A { return indication * 8 }
        if indication == 0x3E { return -2 }
        if indication == 0x3F { return -1 }
        return nil
    }

    private func stripFill(_ bits: ArraySlice<UInt8>) -> [UInt8] {
        var end = bits.endIndex
        while end > bits.startIndex && bits[end - 1] == 0 { end -= 1 }
        if end > bits.startIndex { end -= 1 }                // das abschließende 1-Bit
        return Array(bits[bits.startIndex..<end])
    }

    private func parseResource(_ bits: [UInt8], at start: Int, block: TETRAMacBlock) -> Int? {
        var r = TETRABitReader(bits, pos: start + 2)
        let fill = r.flag()
        r.skip(1)                                            // Lage der Zuteilung
        let encryption = r.read(2)
        r.skip(1)                                            // Zufallszugriff
        let indication = r.read(6)
        guard let address = decodeAddress(&r) else { return nil }
        if address.kind == .null { return nil }              // Leer-PDU: Rest des Blocks ist Füllung
        if let s = address.ssi { onSignal?(.address(s, "MAC"), block.time) }
        if r.flag() { r.skip(4) }                            // Leistungssteuerung
        if r.flag() { r.skip(8) }                            // Zeitschlitzvergabe
        var allocation: TETRAChannelAllocation?
        if r.flag() { allocation = decodeAllocation(&r) }
        guard r.pos <= bits.count, let length = lengthBits(indication) else { return nil }
        var end: Int
        switch length {
        case -1: end = bits.count                            // beginnt eine Folge von Fragmenten
        case -2: end = bits.count
        default: end = min(bits.count, start + length)
        }
        guard end >= r.pos else { return nil }
        var payload = Array(bits[r.pos..<end])
        if fill && !payload.isEmpty { payload = stripFill(payload[...]) }
        if encryption != 0 {
            onSignal?(.encrypted(address), block.time)
            if length == -1 { fragments[block.time.tn] = nil }
            return end
        }
        if length == -1 {
            fragments[block.time.tn] = Fragment(bits: payload, address: address, allocation: allocation, encrypted: false, start: block.time)
            return end
        }
        handleSDU(payload, address: address, allocation: allocation, time: block.time)
        return end
    }

    // MARK: MAC-FRAG / MAC-END

    private func parseFragment(_ bits: [UInt8], at start: Int, block: TETRAMacBlock) {
        let isEnd = bits[start + 2] == 1
        let tn = block.time.tn
        guard var frag = fragments[tn] else { return }
        // Abgelaufene Fragmente verwerfen (mehr als vier Mehrfachrahmen)
        if abs(block.time.mn - frag.start.mn) > 4 && abs(block.time.mn - frag.start.mn) < 56 { fragments[tn] = nil; return }
        let fill = bits[start + 3] == 1
        if !isEnd {
            var payload = Array(bits[(start + 4)...])
            if fill { payload = stripFill(payload[...]) }
            frag.bits += payload
            frag.parts += 1
            fragments[tn] = frag
            return
        }
        var r = TETRABitReader(bits, pos: start + 4)
        r.skip(1)                                            // Lage der Zuteilung
        let indication = r.read(6)
        if r.flag() { r.skip(8) }                            // Zeitschlitzvergabe
        var allocation = frag.allocation
        if r.flag() { allocation = decodeAllocation(&r) }
        guard let length = lengthBits(indication), length > 0 else { fragments[tn] = nil; return }
        let end = min(bits.count, start + length)
        guard end >= r.pos else { fragments[tn] = nil; return }
        var payload = Array(bits[r.pos..<end])
        if fill && !payload.isEmpty { payload = stripFill(payload[...]) }
        frag.bits += payload
        fragments[tn] = nil
        handleSDU(frag.bits, address: frag.address, allocation: allocation, time: block.time)
    }

    // MARK: LLC und MLE

    private func handleSDU(_ bits: [UInt8], address: TETRAAddress, allocation: TETRAChannelAllocation?, time: TETRATime) {
        guard bits.count >= 8 else { return }
        var r = TETRABitReader(bits)
        let llcType = r.read(4)
        var end = bits.count
        switch llcType {
        case 0, 4: r.skip(2)                                 // BL-ADATA: N(R), N(S)
        case 1, 5: r.skip(1)                                 // BL-DATA: N(S)
        case 2, 6: break                                     // BL-UDATA
        case 3, 7: r.skip(1)                                 // BL-ACK: N(R)
        default: return                                      // Fortgeschrittene Verbindung: nicht ausgewertet
        }
        if llcType >= 4 { end -= 32 }                        // Prüfsumme
        guard end - r.pos >= 8 else { return }
        let sdu = Array(bits[r.pos..<end])
        parseMLE(sdu, address: address, allocation: allocation, time: time)
    }

    private func parseMLE(_ bits: [UInt8], address: TETRAAddress, allocation: TETRAChannelAllocation?, time: TETRATime) {
        var r = TETRABitReader(bits)
        let discriminator = r.read(3)
        switch discriminator {
        case 2: parseCMCE(&r, address: address, allocation: allocation, time: time)
        default: break
        }
    }

    private func callingParty(_ r: inout TETRABitReader) -> Int? {
        switch r.read(2) {
        case 0: return r.read(8)
        case 1: return r.read(24)
        case 2:
            let ssi = r.read(24)
            r.skip(24)
            return ssi
        default: return nil
        }
    }

    private func parseCMCE(_ r: inout TETRABitReader, address: TETRAAddress, allocation: TETRAChannelAllocation?, time: TETRATime) {
        let type = r.read(5)
        func emit(_ s: TETRACallSignal) { onSignal?(.call(s), time) }
        switch type {
        case 0x07:                                           // D-SETUP
            let callID = r.read(14)
            r.skip(4)                                        // Zeitablauf
            r.skip(1)                                        // Anhängemethode
            let simplex = r.read(1) == 0
            let basic = r.read(8)
            let grant = r.read(2)
            r.skip(1)
            let priority = r.read(4)
            var party: Int?
            if r.flag() {                                    // optionale Elemente
                if r.flag() { r.skip(6) }                    // Hinweis
                if r.flag() { r.skip(24) }                   // vorläufige Adresse
                if r.flag() { party = callingParty(&r) }
            }
            var s = TETRACallSignal(kind: .setup, callID: callID, address: address, party: party, usageMarker: address.usageMarker, allocation: allocation)
            s.circuitModeType = (basic >> 5) & 7
            s.encryptedCall = (basic >> 4) & 1 == 1
            s.communicationType = (basic >> 2) & 3
            s.simplex = simplex
            s.priority = priority
            s.transmissionGrant = grant
            emit(s)
        case 0x02:                                           // D-CONNECT
            let callID = r.read(14)
            r.skip(4 + 1)
            let simplex = r.read(1) == 0
            let grant = r.read(2)
            var s = TETRACallSignal(kind: .connect, callID: callID, address: address, party: nil, usageMarker: address.usageMarker, allocation: allocation)
            s.simplex = simplex
            s.transmissionGrant = grant
            emit(s)
        case 0x0B:                                           // D-TX GRANTED
            let callID = r.read(14)
            let grant = r.read(2)
            r.skip(1)
            let encryptionControl = r.read(1) == 1
            r.skip(1)
            var party: Int?
            if r.flag() {
                if r.flag() { r.skip(6) }
                if r.flag() { party = callingParty(&r) }
            }
            var s = TETRACallSignal(kind: .txGranted, callID: callID, address: address, party: party, usageMarker: address.usageMarker, allocation: allocation)
            s.transmissionGrant = grant
            s.encryptedCall = encryptionControl
            emit(s)
        case 0x09:                                           // D-TX CEASED
            let callID = r.read(14)
            emit(TETRACallSignal(kind: .txCeased, callID: callID, address: address, party: nil, usageMarker: address.usageMarker, allocation: allocation))
        case 0x06:                                           // D-RELEASE
            let callID = r.read(14)
            let cause = r.read(5)
            var s = TETRACallSignal(kind: .release, callID: callID, address: address, party: nil, usageMarker: address.usageMarker, allocation: allocation)
            s.disconnectCause = cause
            emit(s)
        case 0x01:                                           // D-CALL PROCEEDING
            let callID = r.read(14)
            emit(TETRACallSignal(kind: .proceeding, callID: callID, address: address, party: nil, usageMarker: address.usageMarker, allocation: allocation))
        case 0x04:                                           // D-DISCONNECT
            let callID = r.read(14)
            let cause = r.read(5)
            var s = TETRACallSignal(kind: .disconnect, callID: callID, address: address, party: nil, usageMarker: address.usageMarker, allocation: allocation)
            s.disconnectCause = cause
            emit(s)
        case 0x08:                                           // D-STATUS
            let party = callingParty(&r)
            let status = r.read(16)
            var s = TETRACallSignal(kind: .status, callID: 0, address: address, party: party, usageMarker: nil, allocation: nil)
            s.status = status
            emit(s)
        case 0x0F:                                           // D-SDS DATA
            parseSDS(&r, address: address, time: time)
        default:
            break
        }
    }

    // MARK: SDS

    private func parseSDS(_ r: inout TETRABitReader, address: TETRAAddress, time: TETRATime) {
        guard let from = callingParty(&r) else { return }
        let sdti = r.read(2)
        var data: [UInt8] = []
        var protocolID: Int?
        var messageType = 0
        var length = 0
        func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(r.read(8)) } }
        switch sdti {
        case 0: data = bytes(2); length = 16
        case 1: data = bytes(4); length = 32
        case 2: data = bytes(8); length = 64
        default:
            length = r.read(11)
            guard length >= 8, r.remaining >= length else { return }
            protocolID = r.read(8)
            var remaining = length - 8
            if let p = protocolID, p & 0x80 != 0 {
                // SDS-TL: Nachrichtentyp und Kopf
                messageType = r.read(4)
                remaining -= 4
                if messageType == 0 {                         // SDS-TRANSFER
                    r.skip(2 + 1 + 1 + 8)
                    remaining -= 12
                    // Speicher- und Weiterleitungsangaben fehlen bei Gruppenverkehr meist; nicht auswerten
                }
            }
            guard remaining > 0, r.remaining >= remaining else { break }
            let tail = (0..<remaining).map { _ in UInt8(r.read(1)) }
            // Bits bytegerecht zusammenfassen
            data = stride(from: 0, to: tail.count - tail.count % 8, by: 8).map { i in
                var v: UInt8 = 0
                for k in 0..<8 { v = (v << 1) | tail[i + k] }
                return v
            }
        }
        var message = TETRASDSMessage(from: from, to: address.ssi ?? 0, protocolID: protocolID, text: nil, data: data, messageType: messageType, viaGroup: false, length: length)
        if let p = protocolID, [0x02, 0x09, 0x82, 0x89].contains(p), messageType == 0 || p < 0x80, data.count >= 1 {
            message.text = TETRAUpperMAC.decodeText(data)
        }
        onSignal?(.sds(message), time)
    }

    /// Text einer Kurznachricht: 1 Bit reserviert, 7 Bit Codierung, dann die Zeichen (7 Bit GSM, 8 Bit Latin-1/CP437 oder UCS-2)
    static func decodeText(_ data: [UInt8]) -> String? {
        guard data.count >= 2 else { return nil }
        let scheme = Int(data[0] & 0x7F)
        let body = Array(data.dropFirst())
        switch scheme {
        case 0:
            // 7-Bit-Alphabet, in Oktetten gepackt (LSB zuerst)
            var out = [UInt8]()
            var carry: UInt16 = 0
            var nbits = 0
            for b in body {
                carry |= UInt16(b) << UInt16(nbits)
                nbits += 8
                while nbits >= 7 {
                    out.append(UInt8(carry & 0x7F))
                    carry >>= 7
                    nbits -= 7
                }
            }
            return String(out.map { Character(UnicodeScalar($0 < 0x20 ? 0x2E : $0)) })
        case 0x1A:
            var chars = [UInt16]()
            var i = 0
            while i + 1 < body.count { chars.append(UInt16(body[i]) << 8 | UInt16(body[i + 1])); i += 2 }
            return String(utf16CodeUnits: chars, count: chars.count)
        default:
            return String(body.map { $0 >= 0x20 && $0 != 0x7F ? Character(UnicodeScalar($0)) : "·" })
        }
    }
}
