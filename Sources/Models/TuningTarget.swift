import Foundation

/// Wie der Wasserfall das Signal des Moduls markiert
public enum WaterfallMarkerStyle: Equatable, Sendable {
    /// Mark- und Space-Ton mit Mitte und Bandbreite (Standard)
    case tones
    /// Nur das belegte NF-Band (z. B. Funkruf im Basisband), mit Text in der Kopfzeile
    case band(String)
    /// Keine Markierung (Tonfolgen: überall im Spektrum)
    case none(String)
}

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
    var markerStyle: WaterfallMarkerStyle { get }
}

extension TuningTarget {
    public var markerStyle: WaterfallMarkerStyle { .tones }
}

extension RTTYSettingsStore: TuningTarget {
    public var markerBandwidth: Double { decoderParameters.displayBandwidth }
}
