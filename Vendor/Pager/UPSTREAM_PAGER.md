# Funkruf (POCSAG, FLEX) und Tonfolgen (DTMF, ZVEI, CCIR, EEA, EIA) – Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung nach den Protokollbeschreibungen. Als Gegenprobe dient **multimon-ng**
(EliasOenal, GPL-2.0-oder-später, `Vendor/_upstream/multimon-ng`, lokal, nicht im Git; gebaut in den Scratchpad). Seine Testaufnahmen
(`test/samples`: POCSAG 512/1200/2400 und eine echte FLEX-Aufnahme P2000) dienen als echte Gegenproben; die Nachrichtenbits stimmen überein.

## Aufbau (`Sources/Decoders/Pager`)

| Datei | Inhalt |
|---|---|
| `POCSAGCore.swift` | `PagerBCH` (BCH(31,21) + Parität, Korrektur bis 2 Bit), POCSAG-Codewörter, Stapel, Meldungsaufbau, `PagerBitSlicer`, `POCSAGReceiver` (512/1200/2400 parallel), Testsignal |
| `FLEXCore.swift` | `FLEXReceiver`: Symbole (2 und 4 Pegel), Synchronisation, FIW, Phasen A–D, Entschachteln, Alphanumerik, Ziffern, Tonrufe, Gruppenrufe; Testsignal 1600 Bd |
| `ToneCore.swift` | Normtabellen, Goertzel, `ToneDecoder` (DTMF, 8 Selektivrufnormen), Testsignale |
| `PagerModule.swift`, `TonesModule.swift` | Einstellungen, 24-kHz- bzw. 8-kHz-Senke, Controller, Logs |

### POCSAG
- Eingang ist das NRZ-Basisband des FM-Diskriminators (kein Tonpaar). Je Baudrate ein Bit-Entscheider: Tiefpass bei 0,7·Baud, DPLL auf den Nulldurchgängen.
- Der Entscheider arbeitet mit Hysterese; bei wechselstromgekoppeltem Audio sinkt der Pegel nach langen gleichen Bitfolgen gegen Null:
  dann entscheiden die Sprünge (Kantenerkennung) statt des Pegels. Damit lesen auch 30-Hz- und 150-Hz-Kopplung fehlerfrei.
- Synchronwort `0x7CD215D8` in beiden Polaritäten (bis zwei Bitfehler), Stapel mit 16 Codewörtern, Synchronwort am nächsten Stapel Pflicht.
- Schutz gegen Zufallstreffer: Stapelprüfung (mindestens 10 von 16 gültige Wörter), Adresswörter mit zwei Korrekturen werden nicht angenommen,
  konstante Wörter (0, 0xFFFFFFFF) zählen nicht, zu viele unlesbare oder korrigierte Wörter verwerfen die Meldung, reine Rufe müssen fehlerfrei sein,
  und neben einer gerade gelesenen guten Meldung einer Baudrate werden zweifelhafte Meldungen anderer Baudraten 3 s lang unterdrückt.
- Anzeige: Funktion 0 → Ziffern (`084 2.6]195-3U7[`), sonst Klartext (7 Bit, niederwertiges Bit zuerst); beide Lesarten im Tooltip.

### FLEX
- Nach den Angaben der Protokollbeschreibung und der Struktur von multimon-ng: Marker `0xA6C6AAAA` mit Außencode (Baudrate und Pegelzahl), FIW mit
  Prüfsumme, 25 ms Sync 2, 1,76 s Daten, 88 Wörter je Phase (11 Blöcke × 8, bitweise verschachtelt). Codewörter kommen mit dem zuerst gesendeten Bit
  niederwertig; für die BCH-Prüfung werden sie umgedreht und mit demselben Code wie bei POCSAG korrigiert.
- Gruppenrufe (Adresse 2 029 568 … 583) werden den vorher gemeldeten Mitgliedern zugeordnet.

### Tonfolgen
- Goertzel-Filter je Normton, Fenster 20 … 40 ms, Schritt 5 ms; ein Ton zählt bei ausreichendem Anteil an der Gesamtleistung und deutlichem Abstand zum
  nächsten Ton. Folge zu Ende nach mehreren Tondauern Stille (DTMF: 0,8 s). Frequenztabellen: ZVEI 1/2/3, DZVEI, PZVEI, CCIR, EEA, EIA, DTMF.

## Nachweis

- **POCSAG** (echte Aufnahmen aus multimon-ng): 512, 1200 und 2400 Baud, Rufnummer, Funktion und Klartext wie dort.
- **FLEX** (echte P2000-Aufnahme, 51 s): alle 44 Meldungen, Gruppenrufe mit denselben Mitgliedern wie multimon-ng; mit Rauschen (7 dB), invertiert,
  Gleichstromversatz, Tiefpass und 30-Hz-Kopplung unverändert vollständig.
- **Synthetisch** (27 Dateien je Baudrate: sauber, invertiert, 30/150 Hz Kopplung, Rauschen, Takt ±1 %): fast überall alle 4 Meldungen; multimon-ng
  liefert dort auf demselben Material oft weniger oder dazu falsche Rufe.
