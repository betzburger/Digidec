// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Auftrag eines Hauptprogramms an Digidec, übergeben per URL-Schema (PLAN.md, Abschnitt 3.1):
/// `digidec://open?source=pcr1500&rigctl=4532&device=<UID>`
/// oder gezielt: `digidec://decode?mode=rtty&preset=dwd-lw&source=pcr1500&rigctl=4532&device=<UID>&center=1000`
public struct DecodeRequest: Equatable, Sendable {
    public static let scheme = "digidec"
    public static let actionDecode = "decode"
    public static let actionOpen = "open"
    public static let centerRange: ClosedRange<Double> = 100...4000
    public static let portRange: ClosedRange<Int> = 1025...65535

    public var module: DecoderModuleInfo?
    public var presetID: String?
    /// Aufrufendes Programm, nur für die Anzeige (z. B. "pcr1500", "ft991a").
    public var source: String?
    /// rigctld-Port des aufrufenden Programms (PCR-1500: 4532, FT-991A: 4533).
    public var rigctlPort: Int?
    /// CoreAudio-UID des Geräts, auf das der Commander ausgibt. `nil` = Standardgerät (VALHost 2ch).
    public var deviceUID: String?
    /// Audio-Mittenfrequenz in Hz.
    public var centerHz: Double?

    public init(module: DecoderModuleInfo? = nil, presetID: String? = nil, source: String? = nil,
                rigctlPort: Int? = nil, deviceUID: String? = nil, centerHz: Double? = nil) {
        self.module = module
        self.presetID = presetID
        self.source = source
        self.rigctlPort = rigctlPort
        self.deviceUID = deviceUID
        self.centerHz = centerHz
    }

    /// Anzeigename der Quelle für die Kopfzeile.
    public var sourceDisplayName: String? {
        guard let source else { return nil }
        switch source.lowercased() {
        case "pcr1500": return "PCR-1500 Commander"
        case "ft991a":  return "FT-991A Commander"
        default:        return source
        }
    }
}

public enum DecodeRequestError: Error, Equatable, CustomStringConvertible {
    case wrongScheme(String?)
    case unknownAction(String?)
    case missingMode
    case unknownMode(String)
    case moduleNotAvailable(DecoderModuleInfo)
    case unknownPreset(String, DecoderModuleInfo)
    case invalidPort(String)
    case invalidCenter(String)

    public var description: String {
        switch self {
        case .wrongScheme(let s):          return "Unbekanntes URL-Schema: \(s ?? "–")"
        case .unknownAction(let a):        return "Unbekannte Aktion: \(a ?? "–")"
        case .missingMode:                 return "Parameter „mode“ fehlt"
        case .unknownMode(let m):          return "Unbekannte Betriebsart: \(m)"
        case .moduleNotAvailable(let m):   return "\(m.displayName) ist noch nicht verfügbar"
        case .unknownPreset(let p, let m): return "Unbekanntes Preset „\(p)“ für \(m.displayName)"
        case .invalidPort(let p):          return "Ungültiger rigctld-Port: \(p)"
        case .invalidCenter(let c):        return "Ungültige Mittenfrequenz: \(c) Hz"
        }
    }
}

public enum DecodeRequestParser {
    public static func parse(_ url: URL) -> Result<DecodeRequest, DecodeRequestError> {
        guard url.scheme?.lowercased() == DecodeRequest.scheme else {
            return .failure(.wrongScheme(url.scheme))
        }
        guard let host = url.host?.lowercased(),
              host == DecodeRequest.actionDecode || host == DecodeRequest.actionOpen else {
            return .failure(.unknownAction(url.host))
        }

        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                params[item.name.lowercased()] = value
            }
        }

        let module: DecoderModuleInfo?
        let presetID: String?

        if let modeString = params["mode"] {
            guard let m = DecoderModuleInfo(rawValue: modeString.lowercased()) else {
                return .failure(.unknownMode(modeString))
            }
            guard m.isAvailable else { return .failure(.moduleNotAvailable(m)) }
            module = m
            if let p = params["preset"]?.lowercased() {
                guard m.presetIDs.contains(p) else { return .failure(.unknownPreset(p, m)) }
                presetID = p
            } else {
                presetID = m.presetIDs.first ?? ""
            }
        } else if host == DecodeRequest.actionDecode {
            return .failure(.missingMode)
        } else {
            module = nil
            presetID = nil
        }

        var port: Int?
        if let p = params["rigctl"] {
            guard let value = Int(p), DecodeRequest.portRange.contains(value) else {
                return .failure(.invalidPort(p))
            }
            port = value
        }

        var center: Double?
        if let c = params["center"] {
            guard let value = Double(c.replacingOccurrences(of: ",", with: ".")),
                  DecodeRequest.centerRange.contains(value) else {
                return .failure(.invalidCenter(c))
            }
            center = value
        }

        return .success(DecodeRequest(module: module, presetID: presetID, source: params["source"],
                                      rigctlPort: port, deviceUID: params["device"], centerHz: center))
    }
}
