import Foundation

/// Was der Wasserfall vom aktiven Decoder-Modul braucht: Mitte, Töne, Bandbreite und Abstimmen per Klick.
@MainActor
public protocol TuningTarget: ObservableObject {
    /// NF-Mittenfrequenz (von Hand oder durch die AFC)
    var centerHz: Double { get }
    /// Mark- und Space-Ton im NF, wie sie tatsächlich ankommen (nach Seitenband-Korrektur)
    var tones: (mark: Double, space: Double) { get }
    /// Belegte Bandbreite für die Schattierung im Wasserfall
    var markerBandwidth: Double { get }
    /// Mitte von Hand setzen (Klick im Wasserfall)
    func setCenter(_ hz: Double)
}

extension RTTYSettingsStore: TuningTarget {
    public var markerBandwidth: Double { decoderParameters.displayBandwidth }
}
