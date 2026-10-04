import Foundation

/// Suchlauf nach Sonden: stimmt Frequenz für Frequenz ab und prüft, ob dort ein RS41-Rahmen lesbar ist.
/// Reine Ablaufsteuerung ohne Zustand außerhalb (Zeit und Zähler kommen von außen), damit sie sich prüfen lässt.
public struct SondeScanEngine: Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        /// Frequenzen der Startorte in der Umgebung und schon gehörte
        case known
        /// Ganzes Sondenband 400 … 406 MHz im Raster (die bekannten Frequenzen zuerst)
        case band
    }

    public enum Event: Equatable, Sendable {
        /// Auf diese Frequenz (kHz) abstimmen
        case tune(Int)
        /// Hier wurde ein Rahmen gelesen
        case found(Int)
        /// Alle Frequenzen ohne Treffer durchsucht
        case finished
    }

    /// Wartezeit nach dem Abstimmen, bis das Funkgerät umgestellt ist und altes Audio durch ist
    public static let settle: TimeInterval = 0.8
    /// Hörzeit je Frequenz: die Sonde sendet jede Sekunde einen Rahmen von etwa 0,5 s, ein ganzer Rahmen kommt also binnen 1,6 s
    public static let listen: TimeInterval = 1.8

    /// Schrittweite im Band: bei 15-kHz-Filter 10 kHz (Raster der Sonden, Ablage bis ±5 kHz), bei 50 kHz 25 kHz
    public static func step(filterKHz: Int) -> Int { filterKHz >= 50 ? 25 : 10 }

    /// Reihenfolge der Frequenzen (kHz): bekannte zuerst (ohne Doppelte, im Sondenband), dann im Modus `band` das Raster dazwischen
    public static func frequencies(mode: Mode, known: [Int], filterKHz: Int) -> [Int] {
        let range = SondeSettingsStore.frequencyRange
        var out: [Int] = []
        for f in known where range.contains(f) && !out.contains(f) { out.append(f) }
        guard mode == .band else { return out }
        let step = Self.step(filterKHz: filterKHz)
        let first = out
        var f = range.lowerBound
        while f <= range.upperBound {
            // Raster-Frequenzen, die eine bekannte Frequenz schon abdeckt, entfallen
            if !first.contains(where: { abs($0 - f) * 2 < step }) { out.append(f) }
            f += step
        }
        return out
    }

    /// Dauer in Sekunden für `count` Frequenzen (ohne vorzeitigen Treffer)
    public static func duration(count: Int) -> TimeInterval { Double(count) * (settle + listen) }

    private enum Phase: Sendable {
        case settle(until: Date)
        case listen(until: Date, baseline: Int)
        case done
    }

    public let frequencies: [Int]
    public private(set) var index = 0
    private var phase: Phase = .done

    public init(frequencies: [Int]) {
        self.frequencies = frequencies
    }

    public var current: Int? { index < frequencies.count ? frequencies[index] : nil }

    /// Beginnt mit der ersten Frequenz; `.finished`, wenn die Liste leer ist
    public mutating func start(now: Date) -> Event {
        index = 0
        guard let f = current else {
            phase = .done
            return .finished
        }
        phase = .settle(until: now.addingTimeInterval(Self.settle))
        return .tune(f)
    }

    /// Ein Takt. `decoded` ist die laufende Summe der gelesenen Rahmen (ganze und Teile) des Empfängers.
    public mutating func advance(now: Date, decoded: Int) -> Event? {
        switch phase {
        case .done:
            return nil
        case .settle(let until):
            if now >= until { phase = .listen(until: now.addingTimeInterval(Self.listen), baseline: decoded) }
            return nil
        case .listen(let until, let baseline):
            if decoded - baseline >= 1, let f = current {
                phase = .done
                return .found(f)
            }
            guard now >= until else { return nil }
            index += 1
            guard let f = current else {
                phase = .done
                return .finished
            }
            phase = .settle(until: now.addingTimeInterval(Self.settle))
            return .tune(f)
        }
    }
}
