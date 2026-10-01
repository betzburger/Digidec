import Foundation

/// Decoder-Module, die Digidec kennt. Reihenfolge = Reihenfolge in der Modul-Leiste.
/// `isAvailable` wird pro Modul auf `true` gesetzt, sobald es implementiert ist (PLAN.md, Abschnitt 10).
public enum DecoderModuleInfo: String, CaseIterable, Identifiable, Sendable {
    case rtty
    case navtex
    case cw
    case psk
    case wefax
    case ft8
    case ft4
    case wspr
    case dcf77
    case efr
    case sstv

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rtty:   return "RTTY"
        case .navtex: return "NAVTEX"
        case .cw:     return "CW"
        case .psk:    return "PSK"
        case .wefax:  return "WEFAX"
        case .ft8:    return "FT8"
        case .ft4:    return "FT4"
        case .wspr:   return "WSPR"
        case .dcf77:  return "DCF77"
        case .efr:    return "EFR"
        case .sstv:   return "SSTV"
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .rtty, .navtex, .cw, .psk, .wefax, .ft8, .ft4, .wspr, .dcf77, .efr, .sstv: return true
        }
    }

    /// Preset-IDs, die das Modul über das URL-Schema annimmt. Erstes Element = Standard.
    public var presetIDs: [String] {
        switch self {
        case .rtty: return ["ham", "dwd-kw", "dwd-lw", "custom"]
        case .navtex: return ["518", "490", "4209"]   // = NavtexFrequency.rawValue
        case .cw: return ["ham"]
        case .psk: return ["bpsk31", "bpsk63", "bpsk125", "bpsk250", "qpsk31", "qpsk63", "qpsk125", "qpsk250"]   // = PSKMode.rawValue
        case .wefax: return ["dwd-7880", "dwd-3855", "dwd-13882", "custom"]   // = WefaxStation.rawValue
        case .ft8: return ["20m", "40m", "80m", "160m", "60m", "30m", "17m", "15m", "12m", "10m", "6m"]   // = FT8Band.rawValue
        case .ft4: return ["20m", "40m", "80m", "30m", "17m", "15m", "12m", "10m", "6m", "2m", "70cm"]   // = FT4Band.rawValue
        case .wspr: return ["20m", "40m", "80m", "30m", "17m", "15m", "12m", "10m", "160m", "60m", "630m", "2200m", "6m", "4m", "2m", "70cm"]   // = WSPRBand.rawValue
        case .dcf77: return ["mainflingen"]
        case .efr: return ["dcf49", "dcf39", "hga22", "custom"]
        case .sstv: return ["20m", "40m", "80m", "10m", "iss", "2m", "custom"]
        }
    }
}
