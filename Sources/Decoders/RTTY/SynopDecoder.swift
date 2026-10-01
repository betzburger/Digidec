import Foundation
import Fldigi

/// Ein Stück Empfangstext: Rohtext aus RTTY oder Klartext einer erkannten SYNOP/SHIP/BUOY-Meldung
public struct TextSegment: Equatable, Sendable {
    public var text: String
    public var decoded: Bool

    public init(_ text: String, decoded: Bool = false) {
        self.text = text
        self.decoded = decoded
    }
}

/// Hülle um den SYNOP-Decoder aus fldigi 4.2.13 (`Vendor/Fldigi`).
/// Der fldigi-Decoder ist ein Singleton – deshalb gibt es auch hier nur eine aktive Ausgabe.
/// Alle Aufrufe vom selben Thread (in der App: Verarbeitungs-Queue der Pipeline).
public final class SynopDecoder {
    private let sink: Sink

    /// `onOutput` bekommt Rohtext (`decoded == false`) und Klartextblöcke (`decoded == true`) in Empfangsreihenfolge.
    public init(onOutput: @escaping (TextSegment) -> Void) {
        sink = Sink(onOutput)
        fldigi_synop_set_output({ ctx, text, length, decoded in
            guard let ctx, let text, length > 0 else { return }
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), count: Int(length))
            // synop.cpp ist UTF-8 (z. B. „°C“ = C2 B0); RTTY-Zeichen sind ASCII
            let s = String(decoding: bytes, as: UTF8.self)
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().emit(TextSegment(s, decoded: decoded != 0))
        }, Unmanaged.passUnretained(sink).toOpaque(), 1)
    }

    /// Ein decodiertes RTTY-Zeichen weitergeben (wie fldigi `rtty::rx()` bei aktiver Synop-Decodierung)
    public func feed(_ ch: Character) {
        for scalar in ch.unicodeScalars where scalar.value < 256 {
            fldigi_synop_feed(CChar(bitPattern: UInt8(scalar.value)))
        }
    }

    /// Angefangene Meldung ausgeben (beim Abschalten)
    public func flush() {
        fldigi_synop_flush()
    }

    // MARK: - Stationslisten

    /// Stationslisten laden (einmal je Programmlauf, dauert einige Zehntelsekunden)
    @discardableResult
    public static func loadStations(from directory: URL? = stationDirectory) -> Bool {
        guard let dir = directory else { return false }
        return fldigi_synop_load_stations(dir.path + "/") == 1
    }

    /// `Contents/Resources/Synop` im App-Bundle, sonst `Resources/Synop` im Projektordner (Tests, Werkzeuge)
    public static var stationDirectory: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Synop"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("nsd_bbsss.txt").path) {
            return res
        }
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Synop")
        return FileManager.default.fileExists(atPath: project.appendingPathComponent("nsd_bbsss.txt").path) ? project : nil
    }

    public static func stationName(wmo: Int) -> String {
        String(cString: fldigi_synop_station_name(Int32(wmo)))
    }

    private final class Sink {
        let emit: (TextSegment) -> Void
        init(_ f: @escaping (TextSegment) -> Void) { emit = f }
    }
}
