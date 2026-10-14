// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Kandidaten aus Digidecs eigenen Tabellen: was zu Tonabstand, Tastung, Bandbreite und Frequenz eines gemessenen Signals passt.
// Das ist Heuristik und kein Beweis; sie geht als Anhaltspunkt an das Sprachmodell (kleine Modelle erfinden sonst gern Werte).
// Reine Logik (prüfbar).

public enum SignalHints {
    /// Kandidaten als Textzeilen (leer, wenn nichts passt)
    public static func candidates(_ m: SignalMeasurement, tuning: AssistantTuning? = nil) -> [String] {
        var out: [String] = []
        func f(_ v: Double, _ d: Int = 0) -> String { String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",") }
        func near(_ v: Double, _ ref: Double, _ tol: Double) -> Bool { abs(v - ref) <= tol }
        let rf = m.centerHz
        guard m.snrDB >= 8 else { return ["Das Signal liegt kaum über dem Rauschen (\(f(Double(m.snrDB), 1)) dB): für eine sichere Zuordnung zu schwach"] }
        let steady = m.duty == nil
        // Breite für schmale Signale: −20 dB (die +6-dB-Breite eines starken Trägers wird von seinen Flanken bestimmt)
        let w = m.bw20Hz
        let single = m.lines.count <= 1 && m.tones.isEmpty

        // Zwei Tonlagen: Frequenzumtastung nach dem Tonabstand. Liegen zwei bekannte Shifts innerhalb der Auflösung, kommen beide als Kandidat.
        if m.tones.count == 2 {
            let shift = abs(m.tones[1] - m.tones[0])
            let tol = max(m.binHz * 1.5, shift * 0.05)
            var found = false
            if near(shift, 85, tol) {
                found = true
                out.append("Zwei Töne im Abstand von etwa \(f(shift)) Hz: 85 Hz Shift nutzt der DWD auf Langwelle (DDH47, 147,3 kHz, 50 Bd) für Wetter-RTTY. Digidec-Modul: RTTY (Voreinstellung DWD LW)")
            }
            if near(shift, 170, tol) {
                found = true
                out.append("Zwei Töne im Abstand von etwa \(f(shift)) Hz: 170 Hz Shift ist der Standard bei RTTY (Amateur 45,45 Bd, Presse und Behörden 50 Bd) und bei NAVTEX/SITOR-B (100 Bd, 518, 490 und 4209,5 kHz). Digidec-Module: RTTY, NAVTEX")
            }
            if near(shift, 200, tol) {
                found = true
                out.append("Zwei Töne im Abstand von etwa \(f(shift)) Hz: 200 Hz Shift ist bei Kurzwellen-Packet (300 Bd) üblich. Digidec-Modul: PACKET")
            }
            if near(shift, 400, tol) || near(shift, 425, tol) {
                found = true
                out.append("Zwei Töne im Abstand von etwa \(f(shift)) Hz: 400 bis 425 Hz Shift ist bei kommerziellem Fernschreiben (Telex, Schifffahrt) üblich. Digidec-Modul: RTTY")
            }
            if near(shift, 450, tol) {
                found = true
                out.append("Zwei Töne im Abstand von etwa \(f(shift)) Hz: 450 Hz Shift nutzt der DWD auf Kurzwelle (4583, 7646, 10100,8, 11039, 14467,3 kHz, 50 Bd). Digidec-Modul: RTTY (Voreinstellung DWD KW)")
            }
            if near(shift, 850, tol) {
                found = true
                out.append("Zwei Töne im Abstand von etwa \(f(shift)) Hz: 850 Hz Shift ist bei breitem RTTY (Presse, Militär, kommerziell) üblich. Digidec-Modul: RTTY")
            }
            if !found {
                out.append("Zwei feste Tonlagen im Abstand von \(f(shift)) Hz: Frequenzumtastung (FSK) mit ungewöhnlichem Shift. Digidec-Module zum Probieren: RTTY (Shift einstellbar), PACKET")
            }
        }

        // Getastetes schmales Signal: Morse, Funkfeuer, Kennung
        if let duty = m.duty, m.onSegments >= 3, w < 500, single, duty < 0.95 {
            var s = "Schmales getastetes Signal (\(f(duty * 100)) % an, \(m.onSegments) Einschaltungen): Morsezeichen (CW)"
            if rf >= 190_000 && rf <= 535_000 { s += "; im Bereich 190 bis 535 kHz sind das meist Funkfeuer (NDB) mit Kennung. Digidec-Modul: NDB" }
            else if rf >= 108_000_000 && rf <= 118_000_000 { s += "; im Bereich 108 bis 118 MHz ist es wahrscheinlich die Kennung eines VOR oder ILS (Flugnavigation). Digidec-Modul: VOR/ILS" }
            else { s += ". Digidec-Module: CW, SKIMMER (liest mehrere Signale zugleich)" }
            if let on = m.medianOnSeconds, on > 0 { s += ". Typische Tastdauer \(f(on, 2)) s" }
            out.append(s)
        }

        // Dauerträger
        if steady, single, w < 150, m.tones.isEmpty {
            if rf > 70_000 && rf < 80_000 { out.append("Schmaler Dauerträger im Bereich 77,5 kHz: DCF77 (Zeitzeichensender Mainflingen, Amplitudentastung jede Sekunde). Digidec-Modul: DCF77") }
            else if rf > 125_000 && rf < 133_000 { out.append("Schmaler Dauerträger im Bereich 129,1 kHz: Rundsteuersender (EFR, Telegramme). Digidec-Modul: EFR") }
            else { out.append("Schmaler stetiger Träger ohne erkennbare Tastung (\(f(w)) Hz breit bei −20 dB): Bake, Zeitzeichen, Träger einer Aussendung ohne Modulation, Störer oder Oberwelle")}
        }

        // Schmales stetiges Digimode-Signal mit mehreren Linien oder Sprüngen
        if steady, m.tones.isEmpty, w >= 20, w <= 120, m.lines.count >= 2 {
            out.append("Schmales Dauersignal mit mehreren Linien (\(f(w)) Hz breit bei −20 dB): kann ein MFSK-Verfahren sein (Olivia, Contestia, DominoEX, THOR, FT8 mit 50 Hz, JS8, WSPR mit 6 Hz). Digidec-Module: MFSK, FT8, JS8, WSPR, OLIVIA")
        } else if steady, single, w >= 20, w <= 120, m.tones.isEmpty {
            out.append("Schmales stetiges Signal mit einer Linie (\(f(w)) Hz breit bei −20 dB): passt zu PSK31 (etwa 31 Hz) oder PSK63. Digidec-Modul: PSK")
        }

        // Tonlage wandert breit, Dauersignal
        if steady, m.peakJitterHz > 150, m.occupiedHz > 500, m.occupiedHz < 1600 {
            out.append("Stetiges Signal, dessen Spitze über etwa \(f(m.occupiedHz)) Hz wandert: frequenzmoduliertes Bildsignal. Wetterfax (1500 bis 2300 Hz, auf Kurzwelle USB) oder SSTV (1200 bis 2300 Hz). Digidec-Module: WEFAX, SSTV")
        }

        // Breite stetige Signale
        if steady, m.occupiedHz >= 1200, m.occupiedHz <= 3400, m.flatnessDB < 3.5, m.tones.isEmpty {
            out.append("Stetiges flaches Signal von etwa \(f(m.occupiedHz)) Hz Breite: Datensignal mit mehreren Trägern oder PSK-Modem. Dazu passen HFDL (Flugzeug-Datenlink, etwa 1,5 bis 2 kHz, Frequenzen um 3 bis 22 MHz), ALE (2,4 kHz, 8-FSK) und militärische Modems. Digidec-Modul: HFDL, ALE")
        } else if steady, m.occupiedHz >= 8_000, m.occupiedHz <= 12_000 {
            out.append(m.lines.count >= 1 && m.peakDB - m.floorDB > 20 && m.flatnessDB > 4
                       ? "Etwa \(f(m.occupiedHz / 1000, 1)) kHz breites Signal mit Träger und Seitenbändern: AM-Rundfunk (Raster 9 oder 10 kHz). Digidec bietet dafür kein Modul, der SDR-Empfänger kann es in AM anhören"
                       : "Etwa \(f(m.occupiedHz / 1000, 1)) kHz breites flaches Signal: digitaler Rundfunk (DRM) oder ein Datensignal. Digidec-Modul: DRM")
        }

        // Bekannte Frequenzen aus den Kanalvoreinstellungen
        var matches: [String] = []
        for module in ChannelCatalog.modules {
            let center = ChannelCatalog.audioCenter(for: module)
            for p in ChannelCatalog.presets(for: module) {
                let carrier = p.frequencyHz + (ChannelCatalog.hfModules.contains(module) ? center : 0)
                if abs(carrier - rf) <= max(1500, w) { matches.append("\(p.title) (Modul \(module.displayName))") }
            }
        }
        if !matches.isEmpty { out.append("Die Frequenz liegt bei bekannten Aussendungen: " + matches.prefix(4).joined(separator: "; ")) }
        return out
    }
}
