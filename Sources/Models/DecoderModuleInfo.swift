import Foundation

/// Decoder-Module, die Digidec kennt. Reihenfolge = Reihenfolge in der Modul-Leiste.
/// `isAvailable` wird pro Modul auf `true` gesetzt, sobald es implementiert ist (PLAN.md, Abschnitt 10).
public enum DecoderModuleInfo: String, CaseIterable, Identifiable, Sendable {
    case rtty
    case navtex
    case cw
    case wefax
    case ft8

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rtty:   return "RTTY"
        case .navtex: return "NAVTEX"
        case .cw:     return "CW"
        case .wefax:  return "WEFAX"
        case .ft8:    return "FT8"
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .rtty, .navtex, .cw, .wefax, .ft8: return true
        }
    }

    /// Preset-IDs, die das Modul über das URL-Schema annimmt. Erstes Element = Standard.
    public var presetIDs: [String] {
        switch self {
        case .rtty: return ["ham", "dwd-kw", "dwd-lw", "custom"]
        case .navtex: return ["518", "490", "4209"]   // = NavtexFrequency.rawValue
        case .cw: return ["ham"]
        case .wefax: return ["dwd-7880", "dwd-3855", "dwd-13882", "custom"]   // = WefaxStation.rawValue
        case .ft8: return ["20m", "40m", "80m", "160m", "60m", "30m", "17m", "15m", "12m", "10m", "6m"]   // = FT8Band.rawValue
        }
    }
}
