# Radiosonden (Vaisala RS41): Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung. Der Rahmenaufbau (Kopf, Verwürfelung, Reed-Solomon, Blöcke, Kalibrierung, Formeln für
Temperatur, Feuchte und Druck) folgt den Angaben aus **rs41mod** von zilog80 (`radiosonde_auto_rx/demod/mod/rs41mod.c`, GPL-3.0, lokal unter
`Vendor/_upstream/sonde/rs41`, nicht im Git; gebaut als Gegenprobe). Die Demodulation (Takt, Entzerrer) ist eigene Arbeit.

## Aufbau (`Sources/Decoders/Sonde`)

| Datei | Inhalt |
|---|---|
| `RS41Core.swift` | `RS41ReedSolomon` (RS(255,231) über GF(2⁸), Polynom 0x11D, 24 Prüfbytes, Berlekamp-Massey), `RS41Telemetry`, `RS41Calibration` (51 Kalibrierblöcke → T, rF, p, Frequenz, Typ), `RS41FrameParser` (Blöcke mit CRC-16, ECEF → Breite/Länge/Höhe, Geschwindigkeit, GPS-Zeit → UTC) |
| `RS41Demod.swift` | `RS41Demodulator` (Bits aus FM-Diskriminator-Audio), `RS41Receiver` (Rahmenprüfung, Teilauswertung, Zähler) |
| `RS41Signal.swift` | Testsignale: Rahmen, Kalibriertabelle, FSK-Audio, simulierter Flug (nur Prüfungen und Werkzeuge) |
| `SondeModule.swift` | `SondeFlight` (Flug, Phase, Weg), `SondeLanding` (Landeprognose), Einstellungen, `SondeDecoder` (48-kHz-Senke), Diagnose, Kartenaufbau, `SondeController` |
| `Sources/UI/SondePanels.swift` | Liste, Einzelheiten mit Höhenverlauf, Abstimmanzeige, Einstellungen |

## Signal und Rahmen

- 400,15 … 405,9 MHz (Raster 10 kHz), FSK 4800 Bd, ±2,4 kHz Hub; als FM-Diskriminator-Audio ist das ein Bitstrom (NRZ). Vorbereitungsfolge aus wechselnden Bits,
  dann der Kopf `10 B6 CA 11 22 96 12 F8`, Bits mit dem niederwertigen Bit zuerst. Ein Rahmen je Sekunde: 320 Bytes (518 mit Zusatzdaten).
- Alles ab Byte 0 ist mit einer 64-Byte-Folge verwürfelt (XOR). Prüfbytes: zwei verschränkte Reed-Solomon-Wörter (gerade und ungerade Bytes ab 56), je 132 Nutzbytes + 24 Prüfbytes (Bytes 8 … 55); korrigiert bis 12 Bytes je Wort.
- Danach Blöcke `Typ, Länge, Daten, CRC-16 (CCITT, little endian)`: `0x79` Status (Rahmennummer, Seriennummer, Batterie, ein 16-Byte-Stück der Kalibrierdaten), `0x7A` Messzähler (12 × 24 Bit),
  `0x7C` GPS-Woche und -Zeit, `0x7D` GPS-Rohdaten, `0x7B` Position ECEF (cm) und Geschwindigkeit (cm/s), `0x76` Füllung, `0x82` (neuere Firmware RS41-SGM: Position und UTC).
- Die Kalibrierdaten (51 × 16 Byte) laufen über 51 Rahmen vorbei; Temperatur nach den Blöcken 3 … 6 (ab dem 7. Rahmen), Feuchte nach Block 7, Druck (nur RS41-SGP) nach 0x21, 0x25 … 0x2A.
- GPS-Zeit minus 18 Schaltsekunden = UTC.

## Demodulator

1. Gleichanteil abziehen (langsamer Mittelwert), Mittelwert über eine Bitdauer (angepasstes Filter).
2. Kopfsuche: Korrelation mit den 64 Kopfbits in beiden Polaritäten. Das Verhältnis ist 1, solange alle Vorzeichen stimmen (breites Plateau); die Mitte des Plateaus ist die beste Abtastlage.
   Die Vorbereitungsfolge ähnelt dem Kopf (Verhältnis bis 0,9): ein 100-Bit-Fenster sammelt die Treffer, die besten drei werden der Reihe nach versucht; mehrere Aufnahmen laufen zugleich, ein falscher Treffer verdeckt den echten Kopf nicht.
3. Takt: (A) Nulldurchgänge der Eingangsspannung, Stück für Stück über 96, 256, 640, 1600, 2560 Bits mit Ausgleichsgerade (Verschiebung und Bitdauer, Ausreißer fallen heraus), Lage nach der größten Augenöffnung;
   (B) bei Rauschen ein Raster über Bitdauer (±600 ppm) und Lage (±5 Abtastwerte) nach der größten Augenöffnung; die Bitdauer der Sonde wird für den nächsten Rahmen gemerkt.
4. (C) **Entzerrer** für verzerrte Funkketten: entscheidungsrückgekoppelter Entzerrer (±1,5 Bit Abtastwerte, 14 Rückkopplungsbits, Festwert), per Kleinste-Quadrate erst an den bekannten Bits (64 der Vorbereitungsfolge und der Kopf),
   dann zweimal nachgelernt an den eigenen Entscheidungen. Nur wenn (A) und (B) nichts lesen.
5. Prüfung: Reed-Solomon beider Wörter und Typbyte (0x0F/0xF0); sonst Teilauswertung der Blöcke mit gültiger CRC. Zähler: Rahmen, Teile, verloren (guter Kopf ohne Rahmen binnen 1,3 s), korrigierte Bytes.
   Rechenaufwand: 120 s Audio in 0,5 s.

## Karte, Flug, Landeprognose

- `SondeFlight` sammelt je Seriennummer die Wegpunkte (bis 20 000), die höchste Höhe, die Starthöhe. Phase: AM BODEN (nah an der Starthöhe, langsam), AUFSTIEG (> 1 m/s), ABSTIEG (geplatzt: mehr als 400 m unter dem Höchststand und Sinken > 1 m/s),
  GELANDET (Sinkflug, Signal 90 s weg, unter 2,5 km über dem Start).
- Landeprognose (grob): Sinkgeschwindigkeit wächst mit der Höhe wie 1/√Luftdichte (Skalenhöhe 8,4 km), waagerechte Geschwindigkeit bleibt wie zuletzt; die Winde der tieferen Schichten sind unbekannt.
- Elevation vom Standort mit Erdkrümmung (Brechung 4/3), Standorthöhe = Starthöhe der Sonde (grob).

## Nachweis

- **Echte Aufnahme** (RS41-SG N3920808, Adelaide, 10.02.2019, 120 s, am Boden; IQ aus dem Beispielsatz von radiosonde_auto_rx, https://rfhead.net/sondes/sonde_samples.tar.gz, hier mit `iq2fm` in FM-Audio umgesetzt, lokal):
  alle 119 Rahmen gelesen (rs41mod: 118); Position, Höhe, Geschwindigkeit, Kurs, Steigen für alle 118 Rahmen mit Position **identisch**, Temperatur (70 Vergleiche) und Feuchte identisch.
  Die Aufnahme „brokenrs41.wav“ (rfhead.net, RS41-SGM, 35 s, ohne GPS-Fix): 30 Rahmen mit Seriennummer R0230556 und Batterie, wie rs41mod.
- **Nachgebildeter Funkweg** (`Tools/SondeBench/sweep.py`, 60 s der echten Aufnahme, 59 Rahmen): Digidec liest alle 59 bei C/N 8 dB (in 15 kHz ZF; rs41mod 56), bei 50-kHz-Filter und C/N 10 dB (rs41mod 0), De-Emphase 75, 150 µs (rs41mod 0), Kopplungs-Hochpass 300 und 500 Hz (rs41mod 13 und 0),
  Sprachband 300 … 3000 Hz, Frequenzablage ±5 kHz, Bitrate ±300 ppm (rs41mod 0) und alle diese Verzerrungen zugleich (De-Emphase 75 µs + 300 Hz + 3 kHz + C/N 8 dB). Grenzen: C/N 6 dB 38 von 59, De-Emphase 300 µs 53, Sprachband bei C/N 6 dB 29.
- **Logiktests:** Reed-Solomon (0 … 12 Fehler), echter Rahmen (Blöcke, Position, Zeit), synthetischer Flug über die ganze Kette (60 Rahmen, Position auf 1e-5°, Temperatur), 15 Funkbedingungen, Rauschen ergibt nichts, Teilauswertung, Pipeline mit 48 und 96 kHz,
  Flug (Phasen, Landeprognose), Karte, Diagnose; die echte Aufnahme, wenn lokal vorhanden.

## Grenzen

- Nur RS41 (SG, SGP, SGM). M10/M20 (9600 Bd), DFM, iMet, Meisei, MRZ und andere folgen nicht von selbst; sie haben eigene Rahmen. Rahmen mit 518 Bytes (Zusatzdaten) sind nur synthetisch geprüft.
- Das Audio des PCR-1500 wurde nicht mit einer Sonde gemessen; der Entzerrer deckt De-Emphase, Hochpass und Sprachband ab, aber echte Aufnahmen am Gerät fehlen. Die REC-Taste im Modul nimmt den Eingang für `decode_file.sh --sonde` auf.
- Der FT-991A empfängt 400 … 406 MHz nicht (nur 420 … 470 MHz); der PCR-1500 ja.
- Kein Suchlauf: die Frequenz wird eingestellt (oder per QSY AUTO an das Gerät gegeben). Keine Übertragung zu SondeHub o. ä.
- Temperatur und Druck sind gegen rs41mod, nicht gegen eine Messung geprüft; die Feuchte ist die empirische Formel von rs41mod (bei kalten Temperaturen träge). Druck (SGP) ist nicht mit echten Daten belegt.
