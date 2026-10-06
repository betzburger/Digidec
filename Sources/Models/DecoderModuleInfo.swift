// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Decoder-Module, die Digidec kennt. Die Reihenfolge der Fälle ist die Entstehungsreihenfolge;
/// die Modul-Leiste ordnet nach `Band` und darin nach Namen A–Z (`Band.modules`).
/// `isAvailable` wird pro Modul auf `true` gesetzt, sobald es implementiert ist (PLAN.md, Abschnitt 10).
public enum DecoderModuleInfo: String, CaseIterable, Identifiable, Sendable {
    case rtty
    case navtex
    case cw
    case psk
    case skimmer
    case olivia
    case mt63
    case mfsk
    case hell
    case dsc
    case ale
    case aprs
    case packet
    case adsb
    case acars
    case ais
    case dstar
    case ysf
    case dmr
    case m17
    case sensors
    case vdl2
    case freedv
    case hfdl
    case sonde
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
        case .skimmer: return "SKIMMER"
        case .olivia: return "OLIVIA"
        case .mt63:   return "MT63"
        case .mfsk:   return "MFSK"
        case .hell:   return "HELL"
        case .dsc:    return "DSC"
        case .ale:    return "ALE"
        case .aprs:   return "APRS"
        case .packet: return "PACKET"
        case .adsb:   return "ADS-B"
        case .acars:  return "ACARS"
        case .ais:    return "AIS"
        case .dstar:  return "D-STAR"
        case .ysf:    return "YSF"
        case .dmr:    return "DMR"
        case .m17:    return "M17"
        case .sensors: return "SENSOREN"
        case .vdl2:   return "VDL2"
        case .freedv: return "FREEDV"
        case .hfdl:   return "HFDL"
        case .sonde:  return "SONDE"
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

    /// Frequenzbereich, dem die Modul-Leiste ein Modul zuordnet (je Modul genau einer, nach dem Haupteinsatz)
    public enum Band: String, CaseIterable, Identifiable, Sendable {
        case hf
        case vhfUhf

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .hf:     return "HF"
            case .vhfUhf: return "VHF/UHF"
            }
        }

        public var detail: String {
            switch self {
            case .hf:     return "Lang-, Mittel- und Kurzwelle"
            case .vhfUhf: return "UKW und darüber"
            }
        }

        /// Module dieses Bereichs, nach Namen A–Z (Umlaute wie ihr Grundbuchstabe)
        public var modules: [DecoderModuleInfo] {
            DecoderModuleInfo.allCases
                .filter { $0.band == self }
                .sorted { $0.displayName.compare($1.displayName, options: [.diacriticInsensitive, .caseInsensitive]) == .orderedAscending }
        }
    }

    public var band: Band {
        switch self {
        case .acars, .adsb, .ais, .aprs, .dstar, .dmr, .m17, .packet, .pager, .sensors, .sonde, .tones, .vdl2, .ysf: return .vhfUhf
        case .rtty, .navtex, .cw, .psk, .skimmer, .olivia, .mt63, .mfsk, .hell, .dsc, .ale, .freedv, .hfdl, .wefax, .ft8, .ft4, .wspr, .dcf77, .efr, .sstv: return .hf
        }
    }

    /// Hat das Modul eine Kartenanzeige? (Ohne Ortsdaten nicht: Bilder, Funkruf, Tonfolgen, ALE)
    public var hasMap: Bool {
        switch self {
        case .sstv, .ale, .pager, .tones, .hell, .packet, .dstar, .ysf, .dmr, .m17, .sensors, .vdl2, .freedv: return false
        default: return true
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .rtty, .navtex, .cw, .psk, .skimmer, .olivia, .mt63, .mfsk, .hell, .dsc, .ale, .aprs, .packet, .adsb, .acars, .ais, .dstar, .ysf, .dmr, .m17, .sensors, .vdl2, .freedv, .hfdl, .sonde, .pager, .tones, .wefax, .ft8, .ft4, .wspr, .dcf77, .efr, .sstv: return true
        }
    }

    /// Preset-IDs, die das Modul über das URL-Schema annimmt. Erstes Element = Standard.
    public var presetIDs: [String] {
        switch self {
        case .rtty: return ["ham", "dwd-kw", "dwd-lw", "custom"]
        case .navtex: return ["518", "490", "4209"]   // = NavtexFrequency.rawValue
        case .cw: return ["ham"]
        case .psk: return ["bpsk31", "bpsk63", "bpsk125", "bpsk250", "qpsk31", "qpsk63", "qpsk125", "qpsk250", "psk125r", "psk250r", "psk500r", "psk1000r",
                          "8psk125", "8psk125fl", "8psk125f", "8psk250", "8psk250fl", "8psk250f", "8psk500", "8psk500f", "8psk1000", "8psk1000f", "8psk1200f"]   // = PSKMode.rawValue
        case .skimmer: return ["cw", "psk31", "psk63"]   // = SkimMode.rawValue
        case .olivia: return ["olivia-8-500", "olivia-4-250", "olivia-8-250", "olivia-16-500", "olivia-32-1000", "olivia-64-2000", "olivia-4-125", "olivia-4-500", "olivia-4-1000", "olivia-4-2000", "olivia-8-125", "olivia-8-1000", "olivia-8-2000", "olivia-16-1000", "olivia-16-2000", "olivia-32-2000", "olivia-64-500", "olivia-64-1000",
                         "contestia-8-500", "contestia-4-250", "contestia-4-500", "contestia-8-250", "contestia-16-500", "contestia-16-1000", "contestia-32-1000", "contestia-64-1000"]   // = FldigiOliviaCore.Options.presetID
        case .ale: return ["ale"]
        case .aprs: return ["eu", "na", "iss", "au", "jp", "free"]   // = APRSChannel.rawValue
        case .packet: return PacketChannel.allCases.map(\.rawValue)   // = PacketChannel.rawValue
        case .adsb: return ["hackrf", "rtlsdr", "sdrplay", "sdrconnect"]   // = ADSBSourceKind.rawValue (ohne Datei)
        case .acars: return ["f131550", "f131725", "f131525", "f130025", "f136900", "free"]   // = ACARSChannel.rawValue
        case .dstar: return ["dstar"]
        case .ysf: return ["ysf"]
        case .dmr: return ["dmr"]
        case .m17: return ["m17"]
        case .vdl2: return ["europa", "csc", "alle"]   // Kanalwahl: EUROPA (6 Kanäle), nur 136,975 MHz, alle Kanäle
        case .sensors: return SensorBand.allCases.map { $0.rawValue }   // = SensorBand.rawValue („433.92“, „868.3“), Standard 433,92 MHz
        case .freedv: return FreeDVMode.allCases.map { $0.title.lowercased() }   // = FreeDVMode.title (kleingeschrieben), Standard 700D
        case .ais: return ["a", "b", "both"]   // = AISChannel.rawValue (ohne „frei“)
        case .hfdl: return HFDLChannels.allPresetIDs   // = HFDLChannels.presetID(kHz), Standard 8942 kHz
        case .sonde: return ["rs41"]
        case .pager: return ["dapnet", "free"]   // = PagerChannel.rawValue
        case .tones: return ["all"]
        case .dsc: return ["8414", "2187", "4207", "6312", "12577", "16804", "70"]   // = DSCChannel.rawValue (ohne „frei“)
        case .mt63: return ["1000s", "1000l", "500s", "500l", "2000s", "2000l"]   // = FldigiMT63Core.Options.presetID
        case .hell: return ["feld", "slow", "x5", "x9", "fskh245", "fskh105", "hell80"]   // = HellMode.rawValue
        case .mfsk: return ["mfsk16", "mfsk32", "mfsk8", "mfsk4", "mfsk11", "mfsk22", "mfsk31", "mfsk64", "mfsk128", "mfsk64l", "mfsk128l",
                           "dominoex11", "dominoex16", "dominoex22", "dominoex8", "dominoex5", "dominoex4", "dominoexmicro", "dominoex44", "dominoex88",
                           "thor16", "thor8", "thor11", "thor22", "thor32", "thor25", "thor44", "thor56", "thor100", "thor5", "thor4", "thormicro", "thor25x4", "thor50x1", "thor50x2",
                           "throb1", "throb2", "throb4", "throbx1", "throbx2", "throbx4", "ifkp10", "ifkp05", "ifkp20", "fsq45", "fsq3", "fsq6", "fsq2", "fsq15"]   // = MFSKMode.rawValue
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
