// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import CryptoKit

// M17 Digitale Signatur (Spezifikation, Abschnitt „Digital Signatures“): ECDSA über secp256r1. Über die Nutzlasten aller Strom-Rahmen ab Rahmen 0 läuft
// ein 16-Byte-Digest (digest := digest XOR payload; digest := um ein Byte nach links gedreht; bei Verschlüsselung gelten die verschlüsselten Nutzlasten).
// Die vier letzten Rahmen (Rahmennummer 0x7FFC … 0x7FFF) tragen je 16 Byte der 64-Byte-Signatur (r und s, je 32 Byte, höchstes Byte zuerst).
// Der öffentliche Schlüssel (64 Byte, x und y) wird nicht mitgesendet: man trägt ihn je Rufzeichen ein. Die Prüfung gilt nur, wenn alle Rahmen angekommen sind.

/// Die Signatur eines Gesprächs samt Digest, wie der Empfänger sie gesammelt hat
public struct M17SignedStream: Equatable, Sendable {
    /// 16 Byte
    public var digest: [UInt8]
    /// 64 Byte
    public var signature: [UInt8]
    /// Alle Strom-Rahmen ab Nummer 0 lückenlos und alle vier Signaturteile da: nur dann kann die Prüfung gelingen
    public var intact: Bool

    public init(digest: [UInt8], signature: [UInt8], intact: Bool) {
        self.digest = digest
        self.signature = signature
        self.intact = intact
    }
}

public enum M17Signature {
    /// Rahmennummer des ersten Signaturrahmens
    public static let firstSignatureFrame = 0x7FFC

    /// Digest um einen Strom-Rahmen weiterführen
    public static func update(_ digest: inout [UInt8], payload: [UInt8]) {
        precondition(digest.count == 16 && payload.count == 16)
        for i in 0..<16 { digest[i] ^= payload[i] }
        digest = Array(digest[1...]) + [digest[0]]               // um ein Byte nach links drehen
    }

    /// Digest nach allen Nutzlasten (Prüfstände)
    public static func digest(of payloads: [[UInt8]]) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 16)
        for p in payloads { update(&d, payload: p) }
        return d
    }

    /// Ein 16-Byte-Wert als „Digest“ für CryptoKit: das Verfahren signiert die 16 Byte unmittelbar (nicht deren SHA-256)
    private struct RawDigest: Digest {
        static var byteCount: Int { 16 }
        let bytes: [UInt8]
        func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
        func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
        var description: String { bytes.map { String(format: "%02x", $0) }.joined() }
    }

    /// Prüft die Signatur mit dem öffentlichen Schlüssel (64 Byte, x gefolgt von y)
    public static func verify(_ stream: M17SignedStream, publicKey: [UInt8]) -> Bool {
        guard stream.intact, stream.digest.count == 16, stream.signature.count == 64, publicKey.count == 64,
              let key = try? P256.Signing.PublicKey(rawRepresentation: Data(publicKey)),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: Data(stream.signature)) else { return false }
        return key.isValidSignature(signature, for: RawDigest(bytes: stream.digest))
    }

    /// Schlüssel aus Hexziffern (128 Stellen; mit vorangestelltem 04 auch 130); Leerzeichen, Doppelpunkte und „0x“ werden übergangen
    public static func parsePublicKey(_ text: String) -> [UInt8]? {
        var digits = text.lowercased().replacingOccurrences(of: "0x", with: "")
        digits.removeAll { " :-\t\n".contains($0) }
        if digits.count == 130, digits.hasPrefix("04") { digits.removeFirst(2) }
        guard digits.count == 128, digits.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            out.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// Schlüsselliste: je Zeile „RUFZEICHEN SCHLÜSSEL“ (Rufzeichen ohne Unterscheidung von Groß- und Kleinschreibung); Kommentarzeilen beginnen mit #
    public static func parseKeyList(_ text: String) -> [String: [UInt8]] {
        var keys: [String: [UInt8]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            let call = trimmed[..<space].uppercased()
            let rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            if let key = parsePublicKey(rest) { keys[call] = key }
        }
        return keys
    }

    /// Erzeugt Signatur (Prüfstände); `privateKey` 32 Byte
    public static func sign(digest: [UInt8], privateKey: [UInt8]) -> [UInt8]? {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(privateKey)),
              let signature = try? key.signature(for: RawDigest(bytes: digest)) else { return nil }
        return Array(signature.rawRepresentation)
    }

    /// Öffentlicher Schlüssel (64 Byte) zu einem privaten (Prüfstände)
    public static func publicKey(privateKey: [UInt8]) -> [UInt8]? {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(privateKey)) else { return nil }
        return Array(key.publicKey.rawRepresentation)
    }

    /// Ergebnis der Signaturprüfung als Text für Liste und Protokoll
    public static func resultText(_ signed: M17SignedStream, source: String?, keys: [String: [UInt8]]) -> String {
        guard signed.intact else { return "Signatur nicht prüfbar (Rahmen fehlen, Einstieg nach Rahmen 0)" }
        guard let source, let key = keys[source.uppercased()] else { return "signiert, Schlüssel von \(source ?? "?") nicht hinterlegt" }
        return M17Signature.verify(signed, publicKey: key) ? "Signatur GÜLTIG (secp256r1, \(source))" : "Signatur UNGÜLTIG (\(source))"
    }
}
