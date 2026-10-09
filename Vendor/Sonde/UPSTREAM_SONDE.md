# Radiosonden (Vaisala RS41, Graw DFM, Meteomodem M10, Meteosis M20): Herkunft und Aufbau

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

- RS41 (SG, SGP, SGM), seit 0.88.0 auch DFM, M10 und M20 (siehe unten). iMet, Meisei, MRZ, LMS6 und andere haben eigene Rahmen und folgen nicht von selbst. Rahmen mit 518 Bytes (Zusatzdaten) sind nur synthetisch geprüft.
- Das Audio des PCR-1500 wurde nicht mit einer Sonde gemessen; der Entzerrer deckt De-Emphase, Hochpass und Sprachband ab, aber echte Aufnahmen am Gerät fehlen. Die REC-Taste im Modul nimmt den Eingang für `decode_file.sh --sonde` auf.
- Der FT-991A empfängt 400 … 406 MHz nicht (nur 420 … 470 MHz); der PCR-1500 ja.
- Kein Suchlauf: die Frequenz wird eingestellt (oder per QSY AUTO an das Gerät gegeben). Keine Übertragung zu SondeHub o. ä.
- Temperatur und Druck sind gegen rs41mod, nicht gegen eine Messung geprüft; die Feuchte ist die empirische Formel von rs41mod (bei kalten Temperaturen träge). Druck (SGP) ist nicht mit echten Daten belegt.

## DFM, M10 und M20 (0.88.0)

Rahmenaufbau und Formeln folgen **dfm09mod** und **m10m20mod** von zilog80 (`radiosonde_auto_rx/demod/mod`, GPL-3.0; lokal unter `Vendor/_upstream/sonde_rs1729`, nicht im Git).
Die Demodulation ist eigene Arbeit und für alle drei Arten dieselbe.

| Datei | Inhalt |
|---|---|
| `SondeSymbolDemod.swift` | `SymbolBurstDemodulator`: Kopfsuche per Korrelation (beide Polaritäten), Taktnachführung (Gardner-Fehlerdetektor, Schleife zweiter Ordnung), liefert die weichen Symbole hinter dem Kopf |
| `DFMCore.swift` | `DFMHamming` (Hamming 8,4, Verschachtelung), `DFMDecoder` (Kanalblöcke: Seriennummer, Typ, Messwerte; Datenpakete 0 bis 8; Temperatur), `DFMReceiver` |
| `M10Core.swift` | `M10Frame` (Differenz- und Manchestercodierung, Prüfsumme), `M10Parser` (GPS, Seriennummer, Temperatur, Feuchte, Druck, Batterie), `M10Receiver` |
| `SondeTelemetry.swift` | `SondeTelemetry` und `SondeStats` (früher `RS41Telemetry`/`RS41Stats`), Protokoll `SondeReceiving` |
| `SondeReceiverBank.swift` | RS41, DFM, M10 und M20 laufen zugleich auf demselben Audio; die Zähler zählen nur Empfänger, die Rahmen lesen |
| `SondeSignal.swift` | Testsignale: Rahmen aus vorgegebenen Werten, Manchester-FSK als Audio (nur Prüfungen und Werkzeuge) |

### Signale

- **DFM**: 2500 Symbole/s, Manchester (1250 Bit/s), GFSK. Kopf 0x45CF (32 Rohsymbole), danach 264 Bit: Kanalblock (7 Hamming-Wörter, 28 Nutzbits), zwei Datenblöcke (je 13 Wörter, 52 Nutzbits: 48 Bit Daten und die Paketnummer). Die Rahmen folgen ohne Lücke aufeinander (4,46 je Sekunde), eine Sekunde trägt die Pakete 0 bis 8 (Zähler, GPS-Zeit, Breite, Länge, Höhe, Datum). Keine Rahmenprüfsumme: nur der Hamming-Code (ein Bitfehler je Wort) und Plausibilitätsprüfungen. Die Seriennummer steht in zwei Kanalblöcken, die Typkennung in den Blöcken davor; ein Zyklus dauert 40 Rahmen (etwa 9 s), bis dahin gibt Digidec nichts aus.
- **M10 und M20**: 9600 Symbole/s (M10 etwa 9615), Manchester, zusätzlich differenziell codiert (Bit = nicht (m ⊕ m_vorher)), ein Rahmen je Sekunde: Länge, Typ (`64 9F` M10, `45 20` M20), Daten, 16-Bit-Prüfsumme. M10 hat Trimble-GPS (Ort in 2³²/360-Schritten) oder Gtop-GPS (`64 AF`), M20 eigene Skalen (1e-6°). Vor dem Kopf liegt ein langer periodischer Vorlauf. Ohne GPS-Lösung sendet die M10 Platzhalter (90° N, 0° E, 150 m); Digidec zeigt dann keine Position.
- Zeit: DFM sendet UTC; M10 sendet GPS-Zeit und den Unterschied zu UTC, M20 nur GPS-Zeit (Digidec rechnet 18 Schaltsekunden ab, wie bei der RS41).

### Beim Bau gefunden

1. **Plateau der Kopfkorrelation.** Bei sauberem Signal ist die normierte Korrelation auf einem breiten Plateau genau 1; die erste oder letzte Stelle des Plateaus liegt 0,4 bis 0,9 Symbole neben der besten Lage (alle Daten ein Bit falsch gelesen, 10 % Fehler). Die Lage bestimmt jetzt die unnormierte Korrelation (am größten, wenn die Fenster mittig auf den Symbolen liegen), die normierte nur die Schwelle.
2. **Periodischer Vorlauf (M10/M20).** Der Vorlauf ähnelt dem Anfang des Kopfes und korreliert mit 0,75 an vielen Stellen; der Empfänger startete im Vorlauf und las Unsinn. Ein Treffer gilt erst, wenn 24 Symbole lang kein besserer folgt; ein deutlich besserer (+0,02) ersetzt ihn. Zusätzlich: die ersten 16 Bit hinter dem Kopf (Länge und Typ) müssen plausibel sein, das Signal muss so stark sein wie der Eingangspegel.
3. **Taktschleife.** Die Referenz tastet mit fester Symbolrate ab und scheitert bei M10/M20 mit nur 5 Abtastwerten je Symbol (48 kHz); eine Schleife mit Kp 0,4 und Ki 0,04 (Messung an den echten Aufnahmen, 0,1/0,005 bis 0,6/0,1 durchprobiert) und 2 % Toleranz der Symbolrate liest fast alle Rahmen.
4. **Erster Bit des M10/M20-Rahmens**: die Differenzdecodierung beginnt mit dem letzten Paar des Kopfes (m = 1).

### Nachweis

- **Echte Aufnahmen** (Beispielsatz von radiosonde_auto_rx, `samples/*_96k_float.bin`, 120 s, I/Q 96 kHz, mit `iq2fm2.py` in FM-Audio umgesetzt, 48 kHz, ZF 15 bzw. 30 kHz; lokal unter `TestData/Sonde`):
  - **DFM-09** (DFM-637797, Adelaide, 10.02.2019): 534 von 535 Rahmen vollständig, 0 Bitkorrekturen nötig; Position, Höhe, Geschwindigkeit, Temperatur und Batterie wie dfm09mod; 88 s Telemetrie (dfm09mod 96, aber ohne Seriennummer nötig).
  - **M20** (M20-911-2-00269, 23.07.2022): 120 Rahmen mit gültiger Prüfsumme (m10m20mod bei 48 kHz 108, bei 96 kHz 120); Position, Zeit, T, rF und Druck wie m10m20mod.
  - **M10** (M10-803-2-10732, 07.04.2019, am Boden ohne GPS-Fix): 125 Rahmen (m10m20mod bei 48 kHz 17, bei 96 kHz 91); Seriennummer, T 23,6 °C, rF 50 % wie m10m20mod.
  - Beide Referenzprogramme brauchen für M10/M20 den Schalter `--dc` (Gleichanteil), sonst lesen sie nichts.
- ZF-Bandbreite (dieselben Aufnahmen, ZF 15/25/50 kHz): DFM 534 Rahmen bei allen; M10 113/122/125; M20 115/119/119: M10 und M20 vertragen den 15-kHz-Filter, verlieren dabei aber 5 bis 10 % der Rahmen; empfohlen 50 kHz.
- Synthetisch (Logiktests): alle drei bei Gleichanteil, umgekehrter Polarität, Bitrate ±0,5 %, Rauschen; bei 6 dB Signal-Rausch-Abstand im ganzen Audioband 15 bis 17 von 20 Rahmen (M10/M20), DFM unverändert vollständig.

### Grenzen

- DFM-06, DFM-17 und PS-15 (Kanalblock-Auswertung und Typerkennung) sind nur nach dem Referenzcode übernommen, **nicht an einer echten Aufnahme geprüft** (nur DFM-09 liegt vor).
- M10: Doppelrahmen (`64 49`, alle 10 s, Signalpegel der Satelliten) werden gezählt, aber nicht ausgewertet; M10plus (`64 AF`, Gtop) und M2K2 (`8F`) nach dem Referenzcode, nicht an einer Aufnahme geprüft. M20: der Prüfblock für Firmware unter 7 wird nicht genutzt (ein Rahmen mit falscher Gesamtprüfsumme wird verworfen).
- Der Sendeplan (SondeHub) und die Startorte auf der Karte kennen weiter nur RS41; die WMO-Kennungen von DFM, M10 und M20 in der SondeHub-Liste sind nicht sicher zugeordnet.
- Live-Empfang einer DFM, M10 oder M20 am Funkgerät oder SDR ist nicht geprüft; das Audio läuft mit 48 kHz (die Referenz empfiehlt mehr).
