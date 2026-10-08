// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Kanalvoreinstellungen des Mehrkanalbetriebs: welche Decoder als Kanal laufen können und mit welcher Frequenz, Betriebsart und Breite.
// Reine Daten, damit sie sich prüfen lassen (Logiktests).

/// Voreinstellung für einen neuen Kanal
public struct ChannelPreset: Identifiable, Equatable, Sendable {
    public var id: String { module.rawValue + "/" + title }
    public let module: DecoderModuleInfo
    public let title: String
    public let frequencyHz: Double
    public let mode: SDRMode
    public let bandwidthHz: Double
    /// Voreinstellung des Decoders (Kennung wie in `SDRBankSlot.preset`)
    public var option: String? = nil
}

public enum ChannelCatalog {
    /// Module, die als Kanal laufen können (Audio aus dem SDR, eigener Decoder)
    public static let modules: [DecoderModuleInfo] = [.aprs, .packet, .ais, .acars, .pager, .sonde, .dsc, .vor, .tones, .dmr, .dstar, .ysf, .dpmr, .m17,
                                                       .rtty, .navtex, .wefax, .hfdl, .sstv]

    /// Kurzwellen-Decoder (Seitenband-Audio): Dial = Sendefrequenz minus NF-Mitte des Decoders
    public static let hfModules: Set<DecoderModuleInfo> = [.rtty, .navtex, .wefax, .hfdl, .sstv]

    /// NF-Mitte, auf die der Decoder eines Kanals eingestellt wird (die Vorgaben der Module)
    public static func audioCenter(for module: DecoderModuleInfo) -> Double {
        switch module {
        case .rtty, .navtex: return 1000
        case .dsc: return 1700
        case .wefax: return 1900
        case .hfdl: return 1440
        default: return 0
        }
    }

    /// Betriebsart und Breite eines Kanals für ein Modul
    public static func defaults(for module: DecoderModuleInfo) -> (mode: SDRMode, bandwidthHz: Double) {
        switch module {
        case .acars, .vor: return (.am, 10_000)
        case .ais: return (.nfm, 25_000)
        case .sonde: return (.nfm, 25_000)
        case .dmr, .dstar, .ysf, .dpmr, .m17: return (.nfm, 12_500)
        case .rtty, .navtex, .wefax, .hfdl, .sstv: return (.usb, 3_000)
        default: return (.nfm, 15_000)
        }
    }

    /// Bekannte Frequenzen je Modul (für die Auswahl beim Anlegen)
    public static func presets(for module: DecoderModuleInfo) -> [ChannelPreset] {
        let d = defaults(for: module)
        func p(_ title: String, _ hz: Double?) -> ChannelPreset? {
            hz.map { ChannelPreset(module: module, title: title, frequencyHz: $0, mode: d.mode, bandwidthHz: d.bandwidthHz) }
        }
        switch module {
        case .aprs: return APRSChannel.allCases.compactMap { p("APRS \($0.label) MHz", $0.frequencyHz) }
        case .packet: return PacketChannel.allCases.compactMap { p("Packet \($0.label) MHz", $0.frequencyHz) }
        case .ais: return [p("AIS A 161,975 MHz", AISChannel.frequencyA), p("AIS B 162,025 MHz", AISChannel.frequencyB)].compactMap { $0 }
        case .acars: return ACARSChannel.allCases.compactMap { p("ACARS \($0.label) MHz", $0.frequencyHz) }
        case .pager: return PagerChannel.allCases.compactMap { p("\($0.name) \($0.label) MHz", $0.frequencyHz) }
        case .dsc:
            // Kurzwelle in USB, der Rufträger liegt 1,7 kHz über dem Dial; UKW-Kanal 70 in FM
            return DSCChannel.allCases.compactMap { ch in
                guard let dial = ch.dial(center: audioCenter(for: .dsc)) else { return nil }
                let title = ch.isVHF ? "DSC Kanal 70, 156,525 MHz" : "DSC \(ch.label) kHz"
                return ChannelPreset(module: .dsc, title: title, frequencyHz: Double(dial), mode: ch.isVHF ? .nfm : .usb, bandwidthHz: ch.isVHF ? 15_000 : 3_000, option: ch.rawValue)
            }
        case .rtty:
            let c = audioCenter(for: .rtty)
            let dwd: [(Double, String)] = [(4_583_000, "DDK2"), (7_646_000, "DDH7"), (10_100_800, "DDK9"), (11_039_000, "DDH9"), (14_467_300, "DDH8")]
            var list = dwd.map { ChannelPreset(module: .rtty, title: "DWD \(ChannelCatalog.khz($0.0)) kHz \($0.1)", frequencyHz: $0.0 - c, mode: .usb, bandwidthHz: 3_000, option: "dwd-kw") }
            list.append(ChannelPreset(module: .rtty, title: "DWD 147,3 kHz DDH47", frequencyHz: 147_300 - c, mode: .usb, bandwidthHz: 3_000, option: "dwd-lw"))
            return list
        case .navtex:
            return NavtexFrequency.allCases.map { ChannelPreset(module: .navtex, title: "NAVTEX \($0.label)", frequencyHz: $0.usbDial(center: audioCenter(for: .navtex)), mode: .usb, bandwidthHz: 3_000, option: $0.rawValue) }
        case .wefax:
            return WefaxStation.allCases.compactMap { st in
                st.usbDial(center: audioCenter(for: .wefax)).map { ChannelPreset(module: .wefax, title: "Wetterfax \(st.label) kHz (\(st.note))", frequencyHz: $0, mode: .usb, bandwidthHz: 3_000, option: st.rawValue) }
            }
        case .hfdl:
            return HFDLStations.channels.map { ch in
                let names = ch.stations.prefix(2).map(\.name).joined(separator: ", ")
                return ChannelPreset(module: .hfdl, title: "HFDL \(ChannelCatalog.khz(ch.kHz * 1000)) kHz \(names)", frequencyHz: ch.kHz * 1000, mode: .usb, bandwidthHz: 3_000, option: HFDLChannels.presetID(ch.kHz))
            }
        case .sstv:
            return SSTVChannel.allCases.compactMap { ch in
                guard let f = ch.frequencyHz else { return nil }
                let mode: SDRMode = ch.modulation == "LSB" ? .lsb : ch.modulation == "FM" ? .nfm : .usb
                return ChannelPreset(module: .sstv, title: "SSTV \(ch.name)", frequencyHz: f, mode: mode, bandwidthHz: mode == .nfm ? 15_000 : 3_000, option: ch.rawValue)
            }
        case .sonde: return [p("Sonde 403,000 MHz", 403_000_000), p("Sonde 404,500 MHz", 404_500_000), p("Sonde 405,100 MHz", 405_100_000)].compactMap { $0 }
        default: return []
        }
    }

    /// Anzeigename eines Kanals: Voreinstellung, sonst Modul und Frequenz
    public static func title(module: DecoderModuleInfo, frequencyHz: Double) -> String {
        if let preset = presets(for: module).first(where: { abs($0.frequencyHz - frequencyHz) < 1 }) { return preset.title }
        return module.displayName + " " + String(format: "%.4f MHz", frequencyHz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    /// 4583 oder 10100,8 (kHz, so viele Nachkommastellen wie nötig)
    static func khz(_ hz: Double) -> String {
        let k = hz / 1000
        return (k.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", k) : String(format: "%g", (k * 10).rounded() / 10)).replacingOccurrences(of: ".", with: ",")
    }
}
