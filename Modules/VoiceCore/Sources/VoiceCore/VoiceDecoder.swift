// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Gemeinsame Schnittstelle für digitale Sprache (D-Star, DMR, YSF, …).
// Die Demodulatoren und Rahmendecoder liefern Sprachrahmen; ein `VoiceDecoder` macht daraus Ton.
// Wer einen Sprachdecoder bereitstellt, trägt ihn in `VoiceRegistry.shared` ein. Ohne eingetragenen Decoder
// zeigt Digidec nur die Steuerdaten (Rufzeichen, Kennungen, Gruppen) und bleibt stumm.

/// Übertragungsverfahren, dessen Sprachrahmen ein Decoder verarbeiten soll.
public enum VoiceProfile: String, Sendable, CaseIterable {
    /// D-Star: 3600 bit/s Kanalbits (2400 Sprache + 1200 Fehlerschutz).
    case dstar
    /// DMR, ebenso YSF (V/D-Modus 2) und NXDN: 3600 bit/s Kanalbits (2450 Sprache + 1150 Fehlerschutz).
    case dmr
}

/// Ein Sprachrahmen von 20 ms: 72 Kanalbits, MSB zuerst, in der Bitordnung des Decoders.
public struct VoiceFrame: Sendable, Equatable {
    public static let byteCount = 9
    public static let samplesPerFrame = 160
    public static let sampleRate = 8000

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }
}

public enum VoiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case deviceNotFound
    case io(String)
    case timeout
    case protocolError(String)
    case unsupported(VoiceProfile)

    public var description: String {
        switch self {
        case .deviceNotFound: return "Gerät nicht gefunden"
        case .io(let text): return "Ein-/Ausgabefehler: \(text)"
        case .timeout: return "Zeitüberschreitung"
        case .protocolError(let text): return "Protokollfehler: \(text)"
        case .unsupported(let profile): return "Verfahren \(profile.rawValue) wird nicht unterstützt"
        }
    }
}

/// Wandelt Sprachrahmen in Ton (160 Abtastwerte, 8 kHz, 16 Bit, mono je Rahmen).
public protocol VoiceDecoder: Sendable {
    var name: String { get }
    /// `true` bei einem Gerät mit eigenem Sprachbaustein (hat Vorrang vor reiner Software).
    var isHardware: Bool { get }
    func supports(_ profile: VoiceProfile) -> Bool
    func decode(_ frame: VoiceFrame, profile: VoiceProfile) throws -> [Int16]
}

/// Sammelstelle der verfügbaren Sprachdecoder.
public final class VoiceRegistry: @unchecked Sendable {
    public static let shared = VoiceRegistry()

    private let lock = NSLock()
    private var entries: [any VoiceDecoder] = []

    public init() {}

    public var decoders: [any VoiceDecoder] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func register(_ decoder: any VoiceDecoder) {
        lock.lock(); defer { lock.unlock() }
        entries.append(decoder)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    public func removeAll(where shouldRemove: (any VoiceDecoder) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(where: shouldRemove)
    }

    /// Bester Decoder für das Verfahren: Geräte vor Software, sonst in der Reihenfolge der Eintragung.
    public func preferred(for profile: VoiceProfile) -> (any VoiceDecoder)? {
        let candidates = decoders.filter { $0.supports(profile) }
        return candidates.first(where: { $0.isHardware }) ?? candidates.first
    }
}
