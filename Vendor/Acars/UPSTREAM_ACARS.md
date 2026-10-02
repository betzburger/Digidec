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
| `ACARSModule.swift` | Kanäle (131,550 / 131,725 / 131,525 / 130,025 / 136,900 MHz AM), Label-Bezeichnungen, OOOI-Berichte, Flughafenkatalog, Einstellungen, Controller, Karte |

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
