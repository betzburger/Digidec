// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
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
    private let recovery = SynopHeaderRecovery()

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

    /// Ein decodiertes RTTY-Zeichen weitergeben (wie fldigi `rtty::rx()` bei aktiver Synop-Decodierung).
    /// Fehlt einer SYNOP-Meldung die Kopfzeile (Empfang mitten im Block), ergänzt `SynopHeaderRecovery` sie.
    public func feed(_ ch: Character) {
        recovery.process(ch, now: Date(), pass: { [self] c in feedRaw(c) },
                         note: { [self] n in sink.emit(TextSegment(n, decoded: true)) })
    }

    private func feedRaw(_ ch: Character) {
        for scalar in ch.unicodeScalars where scalar.value < 256 {
            fldigi_synop_feed(CChar(bitPattern: UInt8(scalar.value)))
        }
    }

    /// Angefangene Meldung ausgeben (beim Abschalten)
    public func flush() {
        recovery.release(pass: { [self] c in feedRaw(c) })
        fldigi_synop_flush()
    }

    // MARK: - Stationslisten

    /// Stationslisten laden (einmal je Programmlauf, dauert einige Zehntelsekunden)
    @discardableResult
    public static func loadStations(from directory: URL? = stationDirectory) -> Bool {
        guard let dir = directory else { return false }
        return fldigi_synop_load_stations(dir.path + "/") == 1
    }

    /// `Contents/Resources/Stations` im App-Bundle, sonst `Resources/Stations` im Projektordner (Tests, Werkzeuge)
    public static var stationDirectory: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Stations"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("nsd_bbsss.txt").path) {
            return res
        }
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Stations")
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


// MARK: - SYNOP ohne Kopfzeile

/// Der SYNOP-Decoder von fldigi springt nur bei einer Kopfzeile `AAXX`, `BBXX` oder `OOXX` an. Wer mitten in eine
/// Sendung hineinhört (die DWD-Blöcke dauern Minuten), sieht nur Fünfergruppen und bekommt keinen Klartext. Hier wird eine
/// Meldung erkannt, die mit einer bekannten WMO-Stationsnummer und einer plausiblen zweiten Gruppe (`iR iX h VV`) beginnt,
/// und die Kopfzeile ergänzt: `AAXX TTGGi` mit Tag und der letzten Hauptstunde (UTC) von jetzt, Windeinheit Knoten
/// (`i = 4`, DWD-Standard). Zeit und Einheit sind damit angenommen; das meldet ein Hinweis im Klartext.
final class SynopHeaderRecovery {
    private enum State { case idle, bulletin }
    private var state = State.idle
    private var bulletinWord = ""
    /// Wörter, die mit einer Ziffer beginnen, werden zurückgehalten, bis klar ist, ob eine Meldung beginnt
    private var word = ""
    private var wordChars: [Character] = []
    /// Fertige Wörter samt Zeichen (mit den folgenden Trennzeichen)
    private var pieces: [(text: String, chars: [Character])] = []
    private var holding = false

    /// Zeichen hereingeben; `pass` bekommt die (ggf. verzögerten) Zeichen für den fldigi-Decoder, `note` einen Klartext-Hinweis
    func process(_ ch: Character, now: Date, pass: (Character) -> Void, note: (String) -> Void) {
        let separator = ch == " " || ch == "\r" || ch == "\n" || ch == "\r\n" || ch == "=" || ch == "\t"   // „\r\n“ ist in Swift ein Zeichen
        if state == .bulletin {
            pass(ch)
            if separator {
                if bulletinWord == "NNNN" { state = .idle }
                bulletinWord = ""
            } else {
                bulletinWord.append(ch)
            }
            return
        }
        // idle
        if separator {
            if holding {
                if !word.isEmpty {
                    pieces.append((word, wordChars))
                    word = ""
                    wordChars = []
                }
                if pieces.isEmpty { pass(ch); return }
                pieces[pieces.count - 1].chars.append(ch)       // Trennzeichen hängt am letzten Wort
                evaluate(now: now, pass: pass, note: note)
                return
            }
            if word == "AAXX" || word == "BBXX" || word == "OOXX" { state = .bulletin; bulletinWord = "" }
            word = ""
            pass(ch)
            return
        }
        if holding {
            word.append(ch)
            wordChars.append(ch)
            // nur Fünfergruppen aus Ziffern und „/“ gehören zu einer Meldung
            if word.count > 5 || !(ch.isNumber || ch == "/") { release(pass: pass) }
            return
        }
        word.append(ch)
        if word.count == 1, ch.isNumber {
            holding = true
            wordChars = [ch]
            pieces = []
            return
        }
        pass(ch)
    }

    /// Alle zurückgehaltenen Zeichen unverändert weitergeben (kein SYNOP-Beginn)
    func release(pass: (Character) -> Void) {
        var chars: [Character] = []
        for p in pieces { chars += p.chars }
        chars += wordChars
        pieces = []
        word = ""
        wordChars = []
        holding = false
        for c in chars { pass(c) }
    }

    /// Prüft die zurückgehaltenen Wörter: Stationsnummer, `iR iX h VV`, `N dd ff`, dann eine Gruppe `1sTTT` (oder `00fff`).
    /// Passt der Anfang nicht, wird das erste Wort freigegeben und ab dem nächsten neu geprüft (Empfang beginnt mitten in einer Meldung).
    private func evaluate(now: Date, pass: (Character) -> Void, note: (String) -> Void) {
        while !pieces.isEmpty {
            let t = pieces.map(\.text)
            if !Self.isStation(t[0]) || (t.count > 1 && !Self.isSecondGroup(t[1])) || (t.count > 2 && !Self.isFiveSymbols(t[2]))
                || (t.count > 3 && !Self.isFourthGroup(t[3])) {
                let first = pieces.removeFirst()
                for c in first.chars { pass(c) }
                continue
            }
            if t.count >= 4 {
                recover(now: now, pass: pass, note: note)
            }
            return
        }
        holding = false
        word = ""
        wordChars = []
    }

    private func recover(now: Date, pass: (Character) -> Void, note: (String) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.day, .hour], from: now)
        let hour = ((c.hour ?? 0) / 3) * 3
        let header = String(format: "AAXX %02d%02d4 ", c.day ?? 1, hour)
        note("\tNote=Header missing: time and wind unit assumed (UTC \(String(format: "%02d", hour)):00, knots)\n")
        for ch in header { pass(ch) }
        state = .bulletin
        bulletinWord = ""
        var chars: [Character] = []
        for p in pieces { chars += p.chars }
        pieces = []
        holding = false
        word = ""
        wordChars = []
        for ch in chars { pass(ch) }
    }

    /// Fünf Ziffern, die als WMO-Stationsnummer in der Liste stehen
    static func isStation(_ w: String) -> Bool {
        guard w.count == 5, let n = Int(w), w.allSatisfy(\.isNumber) else { return false }
        return SynopCatalog.lookup(wmo: n) != nil
    }

    /// Zweite Gruppe einer Landmeldung: `iR` 0 … 4, `iX` 1 … 7 (oder /), `h`, `VV` zwei Stellen
    static func isSecondGroup(_ w: String) -> Bool {
        let c = Array(w)
        guard c.count == 5, "01234".contains(c[0]), "1234567/".contains(c[1]) else { return false }
        return c[2...].allSatisfy { $0.isNumber || $0 == "/" }
    }

    /// Fünf Zeichen aus Ziffern und „/“ (`N dd ff`)
    static func isFiveSymbols(_ w: String) -> Bool {
        w.count == 5 && w.allSatisfy { $0.isNumber || $0 == "/" }
    }

    /// Vierte Gruppe: Temperatur `1sTTT` oder Windzusatz `00fff`
    static func isFourthGroup(_ w: String) -> Bool {
        isFiveSymbols(w) && (w.hasPrefix("1") || w.hasPrefix("00"))
    }
}
