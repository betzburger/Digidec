import Foundation

/// Decoder-Module, die Digidec kennt. Reihenfolge = Reihenfolge in der Modul-Leiste.
/// `isAvailable` wird pro Modul auf `true` gesetzt, sobald es implementiert ist (PLAN.md, Abschnitt 10).
public enum DecoderModuleInfo: String, CaseIterable, Identifiable, Sendable {
    case rtty
    case navtex
    case cw
    case psk
    case olivia
    case mt63
    case dsc
    case ale
    case aprs
    case pager
    case tones
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
        case .olivia: return "OLIVIA"
        case .mt63:   return "MT63"
        case .dsc:    return "DSC"
        case .ale:    return "ALE"
        case .aprs:   return "APRS"
        case .pager:  return "PAGER"
        case .tones:  return "TÖNE"
        case .wefax:  return "WEFAX"
        case .ft8:    return "FT8"
        case .ft4:    return "FT4"
        case .wspr:   return "WSPR"
        case .dcf77:  return "DCF77"
        case .efr:    return "EFR"
        case .sstv:   return "SSTV"
        }
    }

    /// Hat das Modul eine Kartenanzeige? (Ohne Ortsdaten nicht: Bilder, Funkruf, Tonfolgen, ALE)
    public var hasMap: Bool {
        switch self {
        case .sstv, .ale, .pager, .tones: return false
        default: return true
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .rtty, .navtex, .cw, .psk, .olivia, .mt63, .dsc, .ale, .aprs, .pager, .tones, .wefax, .ft8, .ft4, .wspr, .dcf77, .efr, .sstv: return true
        }
    }

    /// Preset-IDs, die das Modul über das URL-Schema annimmt. Erstes Element = Standard.
    public var presetIDs: [String] {
        switch self {
        case .rtty: return ["ham", "dwd-kw", "dwd-lw", "custom"]
        case .navtex: return ["518", "490", "4209"]   // = NavtexFrequency.rawValue
        case .cw: return ["ham"]
        case .psk: return ["bpsk31", "bpsk63", "bpsk125", "bpsk250", "qpsk31", "qpsk63", "qpsk125", "qpsk250"]   // = PSKMode.rawValue
        case .olivia: return ["olivia-8-500", "olivia-4-250", "olivia-8-250", "olivia-16-500", "olivia-32-1000", "olivia-64-2000", "olivia-4-125", "olivia-4-500", "olivia-4-1000", "olivia-4-2000", "olivia-8-125", "olivia-8-1000", "olivia-8-2000", "olivia-16-1000", "olivia-16-2000", "olivia-32-2000", "olivia-64-500", "olivia-64-1000",
                         "contestia-8-500", "contestia-4-250", "contestia-4-500", "contestia-8-250", "contestia-16-500", "contestia-16-1000", "contestia-32-1000", "contestia-64-1000"]   // = FldigiOliviaCore.Options.presetID
        case .ale: return ["ale"]
        case .aprs: return ["eu", "na", "iss", "au", "jp", "free"]   // = APRSChannel.rawValue
        case .pager: return ["dapnet", "free"]   // = PagerChannel.rawValue
        case .tones: return ["all"]
        case .dsc: return ["8414", "2187", "4207", "6312", "12577", "16804"]   // = DSCChannel.rawValue (ohne „frei“)
        case .mt63: return ["1000s", "1000l", "500s", "500l", "2000s", "2000l"]   // = FldigiMT63Core.Options.presetID
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
