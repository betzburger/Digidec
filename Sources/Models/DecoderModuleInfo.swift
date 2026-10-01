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
        case .rtty, .navtex: return true
        case .cw, .wefax, .ft8: return false
        }
    }

    /// Preset-IDs, die das Modul über das URL-Schema annimmt. Erstes Element = Standard.
    public var presetIDs: [String] {
        switch self {
        case .rtty: return ["ham", "dwd-kw", "dwd-lw", "custom"]
        case .navtex: return ["518", "490", "4209"]   // = NavtexFrequency.rawValue
        case .cw, .wefax, .ft8: return []
        }
    }
}
