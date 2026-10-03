# ACARS (ARINC 618, 2400 Bd MSK auf 1200/2400 Hz, AM) – Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung. Die Demodulation folgt dem bekannten Verfahren von **acarsdec**
(Thierry Leconte, GPL-2/LGPL-2, `Vendor/_upstream/acarsdec`, lokal, nicht im Git; gebaut in den Scratchpad mit libsndfile): MSK wie versetzte
QPSK mit Halbsinus-Impulsen; VCO bei 1800 Hz, Mischer, angepasstes Filter (halber Cosinus über zwei Bitzeiten, zwölffach überabgetastet),
Bittakt und Trägerfrequenz über eine PLL. Der Rahmenaufbau folgt ARINC 618 (SYN SYN SOH, Modus, 7 Zeichen Kennzeichen, Quittung, 2 Zeichen Label,
Block-ID, STX/ETX, bei Abwärtsmeldungen Meldungsnummer und Flugnummer, Text, ETX/ETB, zwei Prüfbytes, DEL; ungerade Parität je Zeichen).

## Aufbau (`Sources/Decoders/ACARS`)

| Datei | Inhalt |
|---|---|
| `ACARSCore.swift` | `ACARSDemodulator`, Rahmenerkennung, `ACARSParser` (Parität, CRC-16/KERMIT, Bitfehlerkorrektur), `ACARSReceiver`, Testsignal |
| `ACARSPosition.swift` | `ACARSPositionParser`: Positionsberichte aus dem Meldungstext (siehe unten) |
| `ACARSModule.swift` | Kanäle (131,550 / 131,725 / 131,525 / 130,025 / 136,900 MHz AM), Label-Bezeichnungen, OOOI-Berichte, Flughafenkatalog, Einstellungen, Flugzeuge mit Weg, Controller, Karte |

Fehlerkorrektur: Hat der Block Paritätsfehler (höchstens drei), werden je Zeichen alle Einzelbit-Möglichkeiten durchprobiert, bis die Prüfsumme stimmt;
sonst alle Doppelbitfehler innerhalb eines Zeichens. Unreparierte Blöcke fallen weg.

OOOI: Die Labels Q1, Q2, QA, QB, QC, QD tragen Start- und Zielflughafen (ICAO) sowie Zeiten (Gate ab, Start, Landung, Gate an, ETA). Aus ihnen entsteht
die Karte: Flughäfen als Punkte, Großkreislinie von Start zu Ziel, Beschriftung mit der Flugnummer.

## Daten

`Resources/Airports/airports.txt`: **OurAirports** (https://ourairports.com/data/, gemeinfrei), Stand 02.10.2026; Flughäfen mit vierbuchstabiger
ICAO-Kennung, groß/mittel oder klein mit Linienverkehr (5594 Einträge). Im App-Bundle unter `Contents/Resources/Airports`.

## Nachweis

Echte Aufnahme `test.wav` aus acarsdec (4 Kanäle, 12,5 kHz, 4,3 s): alle 7 Meldungen, Kennzeichen, Flugnummern, Labels, Block-IDs, Texte und Pegel
stimmen mit acarsdec überein (u. a. F-GTAE AF7728 Label H1 mit Text, PH-BXR KL1681). Mit Rauschen (15 … 4 dB) liefert Digidec dieselbe Zahl wie acarsdec
(7, 6, 5, 5 gegen 7, 6, 6, 5 bei 7 dB). Beide scheitern bei ±2 % Frequenzabweichung (Resampling) gleichermaßen: die Aufnahme muss auf den NF-Takt passen.

## Positionen und Wege (ab 0.43.0)

Die Funkstrecke nennt keinen Ort. Viele Bordrechner schicken aber Positionsberichte im Text; welche Form sie haben, bestimmt die Fluggesellschaft (Label und Aufbau).
`ACARSPositionParser` liest die verbreiteten Formen nach den Regeln der Referenz **acars-decoder-typescript** (airframes.io, MIT-Lizenz;
`Vendor/_upstream/acars-decoder-typescript`, lokal, nicht im Git): ARINC 702 in H1 (`POSN43312W123174,…`, `/PS…`, `/TS…`, `*POS…`, M-Serie, `(POS-…)`),
Label 10 (POS, LDR, `/N…/W…/`), 12, 15, 16 (N-Space, POSA1, AUTPOS, TOD, Honeywell), 1L, 20, 21, 22, 24, 2P (FM3, POS), 44, 4J, 58, 80, 83, HX, 4T. Aus den Testmeldungen der Referenz
(mit echten Aussendungen) sind 65 Fälle (und 14 ohne Position) in die Logiktests übernommen. Die Koordinatenschreibweisen unterscheiden sich je Label:
Grad und Minuten mit Zehntel (`N43312` = 43° 31,2′), Dezimalgrad in Hundertstel, Tausendstel oder Zehntausendstel, Grad-Minuten-Sekunden.

Abweichungen von der Referenz:

- Label 80 `N3539.2W07937.2` und Label 16 TOD `N3835.95 W07858.88` (Punkt in der Zahl): die Referenz teilt durch 100 (Dezimalgrad, im Quelltext selbst als „FIXME?“ markiert),
  Digidec liest Grad und Dezimalminuten (35° 39,2′), wie in ICAO üblich und wie `RA FMT LOCATION N4009.6` oder Label 83 in der Referenz selbst.
- Label 20 `POSN38160W077075`: wie die Referenz Dezimalgrad (38,160°), obwohl derselbe Aufbau in H1 Grad und Minuten ist; ob das stimmt, ist ungeklärt (Unterschied höchstens etwa 15 km).
- Nicht übernommen: Ereignismeldungen (OFF/ON/IN mit Ort am Flughafen), Flugplan- und Wetterformate ohne Flugzeugposition.

Prüfungen im Controller: Eine Position, die kein Flugzeug erreichen kann (mehr als 40 km + 1500 km/h × Zeit seit der letzten), wird verworfen; zweimal an derselben neuen Stelle (±50 km)
gilt sie, und der Weg beginnt dort neu. Wegpunkte, die weniger als 300 m auseinander liegen, werden nicht doppelt gespeichert (höchstens 300 je Flugzeug, 6 Stunden auf der Karte).
