import Foundation

/// Abstimmziel für das Funkgerät: **Dial**-Frequenz (nicht Sendefrequenz) und Mode.
/// Die Dial-Frequenz berücksichtigt die NF-Mitte des Decoders (Sender = Dial + NF-Mitte in USB).
public struct RigTuneTarget: Equatable, Sendable {
    public let dialHz: Int64
    /// Hamlib-Mode: "USB", "LSB", "FM" …
    public let mode: String
    /// Bandbreite in Hz; `nil`/0 = Standard des Geräts
    public let passbandHz: Int?
    /// Kurzbeschreibung für die Anzeige, z. B. „14,080 MHz USB“
    public var label: String {
        let mhz = Double(dialHz) / 1_000_000
        let text: String
        if mhz >= 1 {
            text = String(format: "%.3f MHz", mhz)
        } else {
            text = String(format: "%.3f kHz", Double(dialHz) / 1000)
        }
        return text.replacingOccurrences(of: ".", with: ",") + " " + mode
    }

    public init(dialHz: Int64, mode: String, passbandHz: Int? = nil) {
        self.dialHz = dialHz
        self.mode = mode
        self.passbandHz = passbandHz
    }

    // MARK: - Ziele je Modul (nil = Modul hat keine feste Frequenz)

    public static func ft8(band: FT8Band) -> RigTuneTarget { RigTuneTarget(dialHz: Int64(band.dialHz), mode: "USB") }

    public static func ft4(band: FT4Band) -> RigTuneTarget { RigTuneTarget(dialHz: Int64(band.dialHz), mode: "USB") }

    /// DSC-Kanal: Rufträger bei `centerHz` im NF (USB), UKW Kanal 70 in FM; frei = nichts
    public static func dsc(channel: DSCChannel, centerHz: Double) -> RigTuneTarget? {
        channel.dial(center: centerHz).map { RigTuneTarget(dialHz: $0, mode: channel.isVHF ? "FM" : "USB") }
    }

    /// PSK31-Anruffrequenz des Bandes (nil = „frei“)
    public static func psk(band: PSKBand) -> RigTuneTarget? {
        band.dialHz.map { RigTuneTarget(dialHz: Int64($0), mode: "USB") }
    }

    /// Skimmer: Dial des gewählten Bandes in USB (CW: Anfang des CW-Bereichs, PSK: PSK31-Anruffrequenz; frei = nichts)
    public static func skimmer(mode: SkimMode, cwBand: SkimBand, pskBand: PSKBand) -> RigTuneTarget? {
        let dial = mode == .cw ? cwBand.dialHz : pskBand.dialHz
        return dial.map { RigTuneTarget(dialHz: Int64($0), mode: "USB") }
    }

    /// APRS-Kanal: FM auf der Region-Frequenz (frei = nichts)
    public static func aprs(channel: APRSChannel) -> RigTuneTarget? {
        channel.frequencyHz.map { RigTuneTarget(dialHz: Int64($0.rounded()), mode: "FM") }
    }

    /// ACARS-Kanal: AM auf der Kanalfrequenz (frei = nichts)
    public static func acars(channel: ACARSChannel) -> RigTuneTarget? {
        channel.frequencyHz.map { RigTuneTarget(dialHz: Int64($0.rounded()), mode: "AM") }
    }

    /// Funkruf-Kanal: FM auf der Kanalfrequenz (frei = nichts)
    public static func pager(channel: PagerChannel) -> RigTuneTarget? {
        channel.frequencyHz.map { RigTuneTarget(dialHz: Int64($0.rounded()), mode: "FM") }
    }

    public static func wspr(band: WSPRBand) -> RigTuneTarget { RigTuneTarget(dialHz: Int64(band.dialHz), mode: "USB") }

    public static func sstv(channel: SSTVChannel) -> RigTuneTarget? {
        guard let f = channel.frequencyHz else { return nil }
        let mode = ["USB", "LSB", "FM"].contains(channel.modulation) ? channel.modulation : nil
        return mode.map { RigTuneTarget(dialHz: Int64(f.rounded()), mode: $0) }
    }

    /// Sendefrequenz der Station minus NF-Mitte (Empfang in USB)
    public static func efr(station: EFRStation, centerHz: Double) -> RigTuneTarget? {
        station == .custom ? nil : RigTuneTarget(dialHz: station.frequencyHz - Int64(centerHz.rounded()), mode: "USB")
    }

    /// DCF77 sendet auf 77,5 kHz
    public static func dcf77(centerHz: Double) -> RigTuneTarget {
        RigTuneTarget(dialHz: 77_500 - Int64(centerHz.rounded()), mode: "USB")
    }

    public static func wefax(station: WefaxStation, centerHz: Double) -> RigTuneTarget? {
        station.usbDial(center: centerHz).map { RigTuneTarget(dialHz: Int64($0.rounded()), mode: "USB") }
    }

    /// RTTY auf einer Sendefrequenz (Träger in der Mitte von Mark und Space): Dial = Frequenz − NF-Mitte, USB
    public static func rtty(frequencyHz: Double, centerHz: Double) -> RigTuneTarget {
        RigTuneTarget(dialHz: Int64(frequencyHz.rounded()) - Int64(centerHz.rounded()), mode: "USB")
    }

    public static func navtex(frequency: NavtexFrequency, centerHz: Double) -> RigTuneTarget {
        RigTuneTarget(dialHz: Int64(frequency.usbDial(center: centerHz).rounded()), mode: "USB")
    }
}

/// Die einzigen Stellbefehle, die Digidec je an ein Funkgerät schickt: `F` (Frequenz) und `M` (Mode).
/// Alles andere (insbesondere PTT `T`, Leistung, Lautstärke) wird nie gesendet. Reine Funktionen, damit testbar.
public enum RigCommand {
    /// Hamlib-Modes, die Digidec setzen darf
    public static let allowedModes: Set<String> = ["USB", "LSB", "FM", "AM", "CW", "CWR", "RTTY", "RTTYR", "PKTUSB", "PKTLSB"]

    /// `F <Hz>` – nur sinnvolle Frequenzen (10 kHz … 10 GHz)
    public static func frequency(_ hz: Int64) -> String? {
        (10_000...10_000_000_000).contains(hz) ? "F \(hz)\n" : nil
    }

    /// `M <Mode> <Bandbreite>` – Bandbreite 0 = Standard des Geräts
    public static func mode(_ mode: String, passbandHz: Int?) -> String? {
        let m = mode.uppercased()
        guard allowedModes.contains(m) else { return nil }
        let pb = max(0, min(passbandHz ?? 0, 50_000))
        return "M \(m) \(pb)\n"
    }
}
