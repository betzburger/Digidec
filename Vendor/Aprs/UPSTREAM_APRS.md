# APRS / Packet-Radio (AFSK 1200 Bd) – Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung, Gegenprobe mit **Dire Wolf** (wb2osz, GPL-2.0-oder-später,
`Vendor/_upstream/direwolf`, lokal, nicht im Git) als Referenzdecoder `atest`.

## Aufbau (`Sources/Decoders/APRS`)

| Datei | Inhalt |
|---|---|
| `AFSKModem.swift` | `HDLCReceiver` (Flags, Entstopfen, Abbruch), `AFSKDemodulator`, `AFSKReceiver`, `AFSKModulator` (Testsignal) |
| `APRSPacket.swift` | `AX25Frame`, `HDLC` (CRC-16/X.25), `APRSParser` (Position, Mic-E, Objekt, Gegenstand, Nachricht, Wetter, Telemetrie, NMEA, Status), Symbole, Wetter |
| `APRSModule.swift` | Kanäle, Einstellungen, Decoder-Senke (12 kHz), Controller mit Stationsliste, Protokoll, Nachrichten, Karte |

### Demodulator

1. Bandpass 1014 … 2386 Hz (Mark − 0,155·Baud … Space + 0,155·Baud), Hamming-gefenstert, 8 Symbole lang.
2. Zwei Mischer (Mark, Space), je I und Q, Wurzel-Kosinus-Tiefpass (Roll-off 0,2, 2,8 Symbole) als angepasstes Filter.
3. Hüllkurven, je Ton auf 0…1 normiert (schnelle Spitzen-, langsame Tal-Nachführung, 0,25 s).
4. **Sieben Entscheider** mit Space-Gewicht von −9 … +9 dB gegen Mark. Je Entscheider eine Taktrückgewinnung
   (DPLL, 32-Bit-Zähler, auf Nulldurchgängen mit Trägheit 0,5 suchend / 0,74 eingerastet), NRZI, HDLC.
5. FCS-Prüfung. Bei Fehler **Ein-Bit-Reparatur**, aber nur wenn der AX.25-Kopf plausibel ist (Rufzeichen A–Z, 0–9, UI-Control).
   Reparierte Rahmen kommen ins Protokoll (~), nie in die Stationsliste oder auf die Karte.
6. `AFSKReceiver` lässt **zwei Demodulatoren parallel** laufen (ohne und mit Vorverzerrung 0,7), damit flaches
   Diskriminator-Audio und de-emphasiertes Lautsprecher-Audio ohne Umschalten gelesen werden. Doppelte Rahmen
   (gleiche Bytes, Ende innerhalb 40 ms) zählen einmal.

Abtastrate 12 000 Hz (10 Abtastwerte je Bit). Rechenzeit etwa 300× Echtzeit.

### Parser

Nach APRS101 (Positionen unkomprimiert und komprimiert mit Kurs, Geschwindigkeit, Höhe, Reichweite; Mehrdeutigkeit;
DAO; Mic-E nach Kapitel 10 samt Gerätekennung; Objekte, Gegenstände; Nachrichten mit Quittung; Wetter mit und ohne Ort;
Telemetrie; NMEA RMC/GGA). Die Mic-E-Tabellen (Längen- und Breitenzeichen, Nachrichtenbits) entsprechen `decode_aprs.c`
von Dire Wolf; der Test kodiert Mic-E unabhängig nach der Spezifikation und liest es zurück.

## Nachweis

Aufnahmen: **WA8LMF TNC Test CD v2.0** (`Vendor/_upstream/wa8lmf`, FLAC → WAV), Spur 1 (40 min Verkehr auf 144,390 MHz
Los Angeles, flach), Spur 2 (de-emphasiert), Spur 3/4 (100 Mic-E-Bursts, Übungsfahrt), dazu gr-APRS (synthetisch, zufällige Nutzdaten).
Alle Zahlen über die Produktionskette 44,1/48 kHz → 12 kHz (Polyphasen-Resampler), `decode_file.sh <wav> --aprs`:

| Aufnahme | Dire Wolf 1.7 | Dire Wolf `-F 1` | Digidec |
|---|---|---|---|
| Spur 1, Verkehr, flach | 1005 | 1018 | **1006** |
| Spur 2, de-emphasiert | 982 | 999 | **996** |
| Spur 3, 100 Mic-E (flach) | 100 | 100 | **100** |
| Spur 4, Übungsfahrt | 101 | 106 | **105** |

Stationen: 119, davon 754 Pakete mit Ort (Mic-E, unkomprimiert, komprimiert, Objekte). Die Mic-E-Orte liegen im Raum Los Angeles,
die Fahrt der Spur 4 ergibt einen glatten Weg.
