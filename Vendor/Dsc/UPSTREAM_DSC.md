# DSC (Digitaler Selektivruf) – Herkunft

Kein Fremdcode im Projekt: `Sources/Decoders/DSC/DSCCore.swift` ist eine eigene Umsetzung von **ITU-R M.493-9** (MF/HF: F1B/J2B, 170 Hz Hub, 100 Bd, NF-Mitte 1700 Hz).

| Quelle | Verwendung | Lizenz |
|---|---|---|
| ITU-R M.493-9 (`http://hflink.com/selcall/ITU-R%20M.493-9%20specification.pdf`) | Töne (höher = B/0, tiefer = Y/1), 10-Bit-Code (7 Informationsbits LSB zuerst, 3 Prüfbits = Zahl der B-Elemente, MSB zuerst), Zeitdiversität (DX, Wiederholung RX vier Zeichen später), Punktmuster 200/20 Bit, Phasing (DX 125; RX 111 … 104), Formatspezifizierer, ECC (gerade Längsparität), Adress-/Positions-/Gebietsfelder | – |
| **TAOSW.DSC_Decoder** (Tao Energy SRL, github.com/alemassimo/TAOSW.DSC_Decoder, Commit `9bad1a8`, .NET) | Gegenprobe der Symbolanordnung (Felder je Rufart, welche Symbole die Frequenz tragen, welche EOS/ECC) an dessen Komponententests mit **echten aufgezeichneten Rufen** auf 8414,5 kHz (Symbolfolgen sind als Testvektoren in `Tools/LogicTests/main.swift` übernommen) und an seiner Aufnahme `TAOSW.DSC_Decoder/testFiles/test.wav` (SDRuno, 88,2 kHz, 65 s, fünf Testrufe der Küstenfunkstelle 002371000 an verschiedene Schiffe) | MIT (Code nicht kopiert) |

Die Referenz liegt unter `Vendor/_upstream/dsc_taosw` (nicht im Git; neu holen mit `git clone --depth 1 https://github.com/alemassimo/TAOSW.DSC_Decoder.git Vendor/_upstream/dsc_taosw`).

## Aufbau

- **Demodulator** (`DSCDemodulator`): zwei gleitende Integrale über genau ein Bit (80 Abtastwerte bei 8 kHz) auf den Tönen Mitte ± 85 Hz; Bit = Y, wenn der tiefere Ton stärker ist. Die Taktlage ist unbekannt: **acht Bitströme** mit je 10 Abtastwerten Versatz laufen parallel.
- **Rahmen** (`DSCFramer`, einer je Taktlage): sucht im Bitstrom die Phasing-Folge (16 Zeichen, mindestens 6 richtige, davon je 2 DX und RX), liest dann zeichenweise, führt DX und RX zusammen (bei Fehlern in DX gilt die Wiederholung), erkennt das erste EOS (117 / 122 / 127) und wartet, bis auch die Wiederholungen der letzten Zeichen da sind. ECC = XOR der Symbole vom zweiten Formatspezifizierer bis zum ersten EOS; bei Widerspruch zwischen DX und RX werden die Wiederholungen probiert, bis der ECC stimmt.
- **Sammler** (`DSCCallCollector`): Rufe aus mehreren Taktlagen innerhalb 3,5 s gelten als dieselbe Aussendung, es bleibt der beste (ECC stimmt, wenige unlesbare Symbole); stark beschädigte Rufe (ECC falsch und > 6 unlesbare Symbole) entfallen.
- **Nachführung** (`DSCAutoTuner`): Goertzel über 4096 Abtastwerte im 5-Hz-Raster (300 … 3500 Hz), sucht das Tonpaar im Abstand 170 Hz (Spitze beider Töne mit parabolischer Interpolation), wirkt erst nach zwei ähnlichen Messungen und nur über dem Rauschboden.
- **Nachricht** (`DSCMessage.parse`): Notruf (112), Alle Schiffe (116), Gruppe (114), Einzelruf (120), Gebiet (102), halbautomatisch (123: nur Adressen); Kategorie, MMSI, Art des Notfalls, Position, Zeit, Telekommandos, Frequenzen/Kanäle (MF/HF 100-Hz-Raster), EOS.

## Grenzen

- Nur MF/HF mit 100 Bd. UKW-DSC (Kanal 70, 1200 Bd AFSK) ist nicht umgesetzt (braucht FM-Diskriminator-Audio und andere Töne).
- Notruf-Quittungen und -Weiterleitungen: Nutzdaten (MMSI, Art, Position, Zeit) werden nicht zerlegt, der Ruf wird als Alle-Schiffe-/Einzelruf mit Telekommando „NOTRUF-QUITTUNG“ gezeigt.
- Telekommando-Tabelle und Frequenzfelder: 100-Hz-Raster (Ziffer 0/1/2), Arbeitskanal (3), 10-Hz-Raster (4) nur als Zahl; UKW-Kanäle (90 …) als Zahl.
- Küstenfunkstellen-Namen und Länder (MID) sind nicht hinterlegt.
