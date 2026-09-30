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
    /// Mark und Space vertauscht (zusätzlich zur Seitenband-Korrektur)
    public var reverse: Bool

    public init(shift: Double, baud: Double, bits: Int = 5, parity: RTTYParity = .none,
                stopBits: Double = 1.5, reverse: Bool = false) {
        self.shift = shift
        self.baud = baud
        self.bits = bits
        self.parity = parity
        self.stopBits = stopBits
        self.reverse = reverse
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
                   note: "Amateurfunk-Standard, ITA2"),
        RTTYPreset(id: "dwd-kw", name: "DWD KW",
                   parameters: RTTYParameters(shift: 450, baud: 50),
                   note: "DWD Pinneberg 4583 / 7646 / 10100,8 / 11039 / 14467,3 kHz"),
        RTTYPreset(id: "dwd-lw", name: "DWD LW",
                   parameters: RTTYParameters(shift: 85, baud: 50),
                   note: "DWD DDH47 147,3 kHz"),
        RTTYPreset(id: "custom", name: "Eigene",
                   parameters: RTTYParameters(shift: 170, baud: 45.45),
                   note: "Frei einstellbar")
    ]

    public static func preset(id: String) -> RTTYPreset? {
        all.first { $0.id == id }
    }
}
