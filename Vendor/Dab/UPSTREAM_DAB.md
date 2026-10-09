# DAB und DAB+ (Modul DAB)

Eigene Umsetzung in Swift (`Sources/Decoders/DAB/`), Übertragungsmodus I (Band III, 174 bis 240 MHz, 2,048 MS/s, 1536 Träger zu 1 kHz).

## Quellen

- **Norm:** ETSI EN 300 401 (DAB, Eureka 147), ETSI TS 102 563 (DAB+), ETSI TS 101 756 (Zeichensatz, Programmtypen).
- **Gegenproben (nur gelesen, lokal unter `Vendor/_upstream`, nicht im Git):** welle.io (GPL-2.0-or-later) für den Ablauf des Empfängers und die Tabellen, dablin (GPL-3.0) für die PAD-Auswertung. **welle-cli** wurde gebaut und lieferte für dieselben Aufnahmen die Vergleichsdaten.
- **FAAD2** (GPL-2.0-or-later) decodiert die AAC-Zugriffseinheiten (`Vendor/Faad2`).

## Aufbau

| Datei | Inhalt |
|---|---|
| `DABTables` | Punktierung, UEP-Tabellen, Phasentabelle, Frequenz-Verschachtelung, Energieverwischung, Zeitverschachtelung (Zahlen aus welle.io per Skript übernommen) |
| `DABOFDM` | Nullsymbol-Suche, Zeitsynchronisation über das Phasenbezugssymbol (Korrelation im Frequenzbereich, ±12 kHz Grobverschiebung beim Einrasten), Feinfrequenz aus dem Schutzintervall, DQPSK-Demodulation zu weichen Bits |
| `DABViterbi` | Faltungsdecoder K=7, Rate 1/4 (Polynome 133, 171, 145, 133 oktal), CRC-16 und Feuercode |
| `DABFIC` | Entpunktieren (PI_16, PI_15, PI_X), Viterbi, Entwirbeln, FIB mit CRC |
| `DABEnsemble` | FIG 0/0, 0/1, 0/2, 0/9, 0/10, 0/17, FIG 1/0 und 1/1: Ensemble, Dienste, Teilkanäle, Namen, Programmtyp, Uhrzeit |
| `DABMSC` | CIF aus 18 Symbolen, Zeitentschachtelung über 16 CIF, Entpunktieren (EEP A/B, UEP), Reed-Solomon (120,110), Überrahmen mit Feuercode, Zugriffseinheiten mit CRC |
| `DABAudioDecoder` | FAAD2: AAC-LC, HE-AAC (SBR), HE-AAC v2 (PS) mit 960er-Rahmen |
| `DABPAD` | Programmbegleitende Daten: Dynamic Label (laufender Titel) |
| `DABModule` | Engine auf eigenem Faden, Wiedergabe (AVAudioEngine), Controller, Suchlauf über alle Blöcke |
| `DABSignalGenerator` | Codierer der Gegenseite für Prüfungen (Faltungscode, Reed-Solomon, FIB, Überrahmen) |

## Nachweis

- **Echte Aufnahmen** (HackRF, Raum Würzburg, je 12 s): Block 11D „Bayern“ (10 Dienste), 10A „Unterfranken“ (12), 5C „DR Deutschland“ (14), 5D „Antenne DE“ (16): in allen vier **1488 von 1488 FIB mit gültiger CRC**; Rechenzeit etwa 20-fach schneller als Echtzeit.
- **Ton:** „Bayern 2“ (HE-AAC Stereo, 96 kbit/s) aus 267 Zugriffseinheiten ohne CRC-Fehler; die Wellenform ist **bitgleich mit der von welle-cli** (normierte Korrelation 1,0).
- Dynamic Label auf GONG WÜRZBURG: „SIDO - Issa“ gelesen.
- **Prüfstand:** `Tools/DABBench/dab_bench.sh fic|msc|selftest`; Eigenprüfungen: Faltungscode mit 2,6 % Bitfehlern, Reed-Solomon (5 Fehler korrigiert, 6 erkannt), Überrahmen mit Fehlern und Fremdrahmen, FIG, Zeichensatz, PAD, alle EEP-Profile; dazu die Aufnahme als Logiktest, wenn sie lokal liegt.
- **Live:** HackRF, Block 10A und 11D in der App, Suchlauf über alle 38 Blöcke findet genau diese vier Ensembles.

## Grenzen

- Nur **DAB+** (HE-AAC). Klassisches DAB (MPEG Layer II) wird erkannt, aber nicht gespielt.
- Im ungleichen Fehlerschutz (UEP, nur alte DAB-Dienste) passt die Entpunktierung bei 21 der 64 Tabellenzeilen nicht auf die Länge des Teilkanals (Abweichung 4 oder 8 Bits; bei Index 23 ein Tippfehler der Quelle): diese Kombinationen werden abgelehnt. EEP (DAB+) ist vollständig geprüft.
- Nicht ausgewertet: Diashow (MOT), DL Plus, Paketdaten, TII, andere Übertragungsmodi (II bis IV).
- Weiche Bits ohne Gewichtung nach der Trägerstärke (wie welle.io); bei schwachem Signal wäre das verbesserbar.
