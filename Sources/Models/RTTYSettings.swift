import Foundation

/// Parität wie in fldigi (`szParity` in confdialog.fl)
public enum RTTYParity: String, CaseIterable, Codable, Sendable {
    case none, even, odd, zero, one
}

/// RTTY-Übertragungsparameter. Wertebereiche wie in fldigi (PLAN.md, Abschnitt 5.1).
public struct RTTYParameters: Equatable, Codable, Sendable {
    public static let shifts: [Double] = [23, 85, 160, 170, 182, 200, 240, 350, 425, 850]
    public static let bauds: [Double] = [45, 45.45, 50, 56, 75, 100, 110, 150, 200, 300]
    public static let bitCounts: [Int] = [5, 7, 8]
    public static let stopBitChoices: [Double] = [1, 1.5, 2]

    /// Abstand Mark–Space in Hz (frei wählbar, die Liste enthält die fldigi-Vorgaben)
    public var shift: Double
    public var baud: Double
    /// 5 = Baudot/ITA2, 7/8 = ASCII
    public var bits: Int
    public var parity: RTTYParity
    public var stopBits: Double
    /// Mark und Space vertauscht, bezogen auf USB/Regellage (wie fldigi „Rev“).
    /// `true` = Mark auf der tieferen HF (kommerzielles F1B, z. B. DWD). Bei LSB dreht Digidec zusätzlich um.
    public var reverse: Bool
    /// ITA2-Ziffernsatz (europäisch, z. B. `+` `=`); sonst US-TTY wie fldigi-Standard
    public var ita2: Bool
    /// Nach einem Leerzeichen zurück auf Buchstaben. Eigenschaft des Senders: Amateurfunk ja,
    /// DWD nein (sendet FIGS nur einmal je Zeile, SYNOP-Zifferngruppen wären sonst Buchstaben – beobachtet 30.09.2026)
    public var unshiftOnSpace: Bool

    public init(shift: Double, baud: Double, bits: Int = 5, parity: RTTYParity = .none,
                stopBits: Double = 1.5, reverse: Bool = false, ita2: Bool = false, unshiftOnSpace: Bool = true) {
        self.shift = shift
        self.baud = baud
        self.bits = bits
        self.parity = parity
        self.stopBits = stopBits
        self.reverse = reverse
        self.ita2 = ita2
        self.unshiftOnSpace = unshiftOnSpace
    }

    private enum CodingKeys: String, CodingKey { case shift, baud, bits, parity, stopBits, reverse, ita2, unshiftOnSpace }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shift = try c.decode(Double.self, forKey: .shift)
        baud = try c.decode(Double.self, forKey: .baud)
        bits = try c.decode(Int.self, forKey: .bits)
        parity = try c.decode(RTTYParity.self, forKey: .parity)
        stopBits = try c.decode(Double.self, forKey: .stopBits)
        reverse = try c.decode(Bool.self, forKey: .reverse)
        // ab 0.6.0; ältere gespeicherte Werte haben das Feld nicht
        ita2 = try c.decodeIfPresent(Bool.self, forKey: .ita2) ?? false
        unshiftOnSpace = try c.decodeIfPresent(Bool.self, forKey: .unshiftOnSpace) ?? true   // ab 0.7.2
    }

    /// Mark- und Space-Ton im Audio bei gegebener Mittenfrequenz.
    /// Wie fldigi (`rtty::rx_process`): Mark = Mitte + Shift/2, Space = Mitte − Shift/2, bei `reverse` vertauscht.
    public func tones(center: Double) -> (mark: Double, space: Double) {
        let hi = center + shift / 2
        let lo = center - shift / 2
        return reverse ? (lo, hi) : (hi, lo)
    }

    /// Belegte Bandbreite für die Anzeige im Wasserfall (Shift + Baudrate, wie fldigi `set_bandwidth`)
    public var displayBandwidth: Double { shift + baud }

    public var summary: String {
        let b = baud == baud.rounded() ? String(format: "%.0f", baud) : String(format: "%.2f", baud).replacingOccurrences(of: ".", with: ",")
        let s = stopBits == stopBits.rounded() ? String(format: "%.0f", stopBits) : "1,5"
        return "\(b) Bd · \(Int(shift)) Hz · \(bits)/\(s)"
    }
}

public struct RTTYPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let parameters: RTTYParameters
    public let note: String

    /// Presets aus PLAN.md, Abschnitt 5.2. Die DWD-Polarität (`reverse`) ist beim ersten Empfang zu prüfen.
    public static let all: [RTTYPreset] = [
        RTTYPreset(id: "ham", name: "Amateur",
                   parameters: RTTYParameters(shift: 170, baud: 45.45),
                   note: "Amateurfunk-Standard, Baudot mit US-TTY-Ziffern (fldigi-Standard)"),
        // DWD: Mark auf der tieferen HF (bestätigt 30.09.2026 an DDK2, PLAN.md 5.2) -> reverse bezogen auf USB;
        // europäischer ITA2-Ziffernsatz (noch zu bestätigen); kein Unshift on Space (SYNOP-Gruppen, beobachtet 30.09.2026)
        RTTYPreset(id: "dwd-kw", name: "DWD KW",
                   parameters: RTTYParameters(shift: 450, baud: 50, reverse: true, ita2: true, unshiftOnSpace: false),
                   note: "DWD Pinneberg 4583 / 7646 / 10100,8 / 11039 / 14467,3 kHz"),
        RTTYPreset(id: "dwd-lw", name: "DWD LW",
                   parameters: RTTYParameters(shift: 85, baud: 50, reverse: true, ita2: true, unshiftOnSpace: false),
                   note: "DWD DDH47 147,3 kHz"),
        RTTYPreset(id: "custom", name: "Eigene",
                   parameters: RTTYParameters(shift: 170, baud: 45.45),
                   note: "Frei einstellbar")
    ]

    public static func preset(id: String) -> RTTYPreset? {
        all.first { $0.id == id }
    }
}

/// Empfangsoptionen (fldigi: Modem/TTY/Rx). Gelten für alle Presets.
public struct RTTYDecodeOptions: Equatable, Codable, Sendable {
    public enum AFC: Int, CaseIterable, Codable, Sendable {
        case off = -1, slow = 0, normal = 1, fast = 2
        public var label: String {
            switch self {
            case .off: return "Aus"
            case .slow: return "Langsam"
            case .normal: return "Normal"
            case .fast: return "Schnell"
            }
        }
    }
    /// fldigi rtty_cwi
    public enum Tones: Int, CaseIterable, Codable, Sendable {
        case both = 0, markOnly = 1, spaceOnly = 2
        public var label: String {
            switch self {
            case .both: return "Mark-Space"
            case .markOnly: return "Nur Mark"
            case .spaceOnly: return "Nur Space"
            }
        }
    }

    public var afc: AFC = .normal
    public var squelchOn = false
    /// 0 … 100 gegen die fldigi-Metrik; bei DWD LW (85 Hz) höchstens ≈ 20
    public var squelch: Double = 15
    public var tones: Tones = .both
    /// Filter-Formfaktor; fldigi 4.2.13 rechnet fest mit 1,4
    public var filterK: Double = 1.4
    /// XY-Scope aus den Mark/Space-Filtern (sonst Pseudo-Scope aus den Beträgen)
    public var trueScope = true

    public init() {}

    public static let filterKRange: ClosedRange<Double> = 1.0...2.0
}

/// Seitenband für die Kehrlage-Korrektur (fldigi: `reverse = Rev xor LSB`)
public enum SidebandMode: String, CaseIterable, Codable, Sendable {
    /// aus dem Mode des Funkgeräts (rigctld); unbekannt = USB
    case auto
    case usb
    case lsb

    public var label: String {
        switch self {
        case .auto: return "AUTO"
        case .usb: return "USB"
        case .lsb: return "LSB"
        }
    }
}

/// Begleitdatei einer Aufnahme (`…wav` + `…json`): alles, was zum identischen Nachdecodieren nötig ist
public struct RecordingInfo: Codable, Equatable, Sendable {
    public var presetID: String
    /// Preset-Parameter (Reverse bezogen auf USB)
    public var parameters: RTTYParameters
    /// Parameter, wie sie der Decoder bekam (Reverse nach Seitenband-Korrektur)
    public var decoderParameters: RTTYParameters
    public var options: RTTYDecodeOptions
    /// NF-Mitte beim Start der Aufnahme
    public var centerHz: Double
    public var lsb: Bool
    public var frequencyHz: Int?
    public var mode: String?
    public var startedAt: Date
}
