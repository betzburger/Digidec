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

## Prüfung des POCSAG-Empfangs unter Funkbedingungen (0.44.0)

Anlass: Auf dem Funkgerät kam nichts an; war der Empfänger schuld? Die Antwort liefert `Tools/PagerBench` (`pager_bench.sh [--baud 512|1200|2400] [--mm <multimon-ng>] [--only <Muster>] [--session <wav>]`).
Das Werkzeug erzeugt Aussendungen mit drei Meldungen (zwei Klartext, eine Ziffernfolge) und schickt sie durch eine Nachbildung des Funkwegs
(`Sources/Decoders/Pager/PagerChannelModel.swift`): FM-Modulator mit 4,5 kHz Hub → Rauschen und Zwischenfrequenzfilter (12 kHz) → Diskriminator →
NF-Kette des Empfängers (Entzerrung 75 µs oder 530 µs, Kopplungs-Hochpass, Sprachband 300–3000 Hz, Rauschsperre, Knackser) → Abtastratenwandler wie in Digidec → Empfänger.
Gezählt wird, wie viele gesendete Meldungen mit richtiger Rufnummer **und** richtigem Text ankamen (20 Aussendungen = 60 Meldungen je Zeile; Zufallsfolge fest).

| Bedingung (1200 Bd) | Digidec | multimon-ng |
|---|---|---|
| sauber, 20 dB, 14 dB, 10 dB Rauschabstand (in 12 kHz) | 100 % | 98–100 % |
| 8 dB / 7 dB / 6 dB / 5 dB | 100 / 95 / 70 / 45 % | 85 / 60 / 20 / 5 % |
| Ablage der Abstimmung +1,5 kHz / −2 kHz | 100 % | 100 / 95 % |
| Entzerrung 300 Hz (6 dB je Oktave, wie Amateur-FM) | 100 % | 98 % |
| NF wechselstromgekoppelt: 30 / 150 / 300 Hz | 100 % | 98 / 23 / **0** % |
| Entzerrung 300 Hz + Kopplung 300 Hz | 100 % | 37 % |
| Sprachband 300–3000 Hz, 20 / 12 / 10 dB | 98 / 90 / 87 % | **0** % |
| Rauschsperre zu (20 s Stille davor) | 100 % | 100 % |
| Drift 1,5 kHz in der Aussendung | 100 % | 100 % |
| Knackser 8/s, Sprachband, 14 dB | 72 % | 0 % |

Bei 512 Bd (100 % bis 5 dB, 98 % im Sprachband bei 12 dB) und 2400 Bd (100 % bis 8 dB; im Sprachband nur mit Entzerrung, dort 98 %) ähnlich. Ergebnis:

- Der Empfänger liest Funkruf auch aus Audio, das schlecht aufbereitet ist (Lautsprecher-NF: Entzerrung, Hochpass, Sprachband), wo multimon-ng nichts mehr liest.
  Seine Grenze ist die Physik: unter etwa 7 dB Rauschabstand im Zwischenfrequenzfilter (Diskriminator-Knackser) und bei 2400 Bd im Sprachband.
- Fehler im Empfänger wurden dabei nicht gefunden. Ein Funkgerät, bei dem „nichts“ ankommt, hat sein Problem davor: Rauschsperre zu, falscher Kanal (L/R) oder Eingang,
  Betriebsart (FM schmal oder AM statt FM), Frequenz, zu schwaches Signal, oder zur Zeit sendet niemand. Dafür gibt es seit 0.44.0 die **Diagnose** im Panel: Pegel am Eingang und Zähler
  (Vorspann, Synchronwörter, Stapel gut/schlecht, gültige Codewörter), daraus „KEIN AUDIO“, „WARTEN AUF FUNKRUF“, „VORSPANN OHNE SYNCHRONWORT“, „SYNCHRON, ABER FEHLERHAFT“, „VIELE FEHLER“ oder „EMPFANG GUT“ mit Hinweis.
- Die Logiktests enthalten elf dieser Funkbedingungen (alle drei Baudraten) und die Beurteilung der Diagnose; `REC` im Funkruf-Panel nimmt den Eingang als WAV auf
  (`~/Documents/Digidec/Recordings/PAGER_…wav`), damit sich ein misslungener Empfang später mit `decode_file.sh <wav> --pager` untersuchen lässt.

**Polarität:** POCSAG sendet die 1 auf der tieferen Frequenz. Ein Diskriminator liefert dafür negatives Audio; der Empfänger liest es „invers“ und dreht selbst
(Anzeige „Sync … (invers)“). Umgekehrtes Audio liest er direkt.

**Anzeige:** Knopf `ÄÖÜ` (Standard an) setzt `{ | } ~` in ä ö ü ß um (7-Bit-Zeichensatz DIN 66003 wie bei AlphaPoc, DAPNET-Meldungen mit Umlauten); `[ \ ]` als Ä Ö Ü nur im Wortzusammenhang.
Skyper-Meldungen (Zeichen um eins verschoben) werden nicht umgesetzt.
