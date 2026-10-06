# Lizenz, Quellen und Drittanbieter-Software

Digidec ist freie Software. Dieses Dokument nennt die Lizenz von Digidec und alles, was von anderen stammt:
Quelltext, Daten, Testaufnahmen und Vorbilder. Es wird auch im Programm angezeigt (Info-Knopf oben rechts).

## 1. Lizenz von Digidec

- Digidec steht unter der **GNU General Public License, Version 3 oder (nach deiner Wahl) jeder späteren Version** (GPL-3.0-or-later). Den vollständigen Text enthält die Datei `LICENSE`; im Programm unter Info → Lizenztext.
- Copyright (C) 2026 Peter Betz und Mitwirkende.
- Es gibt **keine Gewährleistung**, soweit das Gesetz es zulässt (GPL, Abschnitte 15 und 16).
- Quelltext: https://github.com/betzburger/Digidec. Wer eine fertige App von Digidec weitergibt, muss den dazugehörigen Quelltext mitgeben oder anbieten (GPL, Abschnitt 6).
- Warum GPL: Digidec enthält Quelltext aus fldigi und WSJT-X, die unter GPL-3.0 stehen. Das Gesamtwerk muss deshalb unter einer GPL-kompatiblen Lizenz stehen. Alle unten genannten Lizenzen sind mit GPL-3.0-or-later vereinbar.
- Die Dateien unter `Vendor/` behalten ihre ursprünglichen Urheber und Lizenzen (Abschnitt 2). Dateien dort ohne eigenen Kopf sind Anpassungen oder Ableitungen der jeweiligen Quelle und stehen unter deren Lizenz. Die SPDX-Kennzeichnung `GPL-3.0-or-later` steht in Digidecs eigenen Dateien (Swift, Skripte, Werkzeuge).

## 2. Fremder Quelltext im Repository (Vendor/)

### fldigi 4.2.13

- Autoren: David Freese (W1HKJ) und Mitwirkende, darunter Stefan Fendt (DL1SMF) und Tomi Manninen (nach gmfsk) beim RTTY-Empfänger sowie Pawel Jalocha (SP9VRC) bei MT63 und Olivia.
- Quelle: https://sourceforge.net/projects/fldigi/ (Repository `git.code.sf.net/p/fldigi/fldigi`, Version 4.2.13, Commit `e7c3ab3709ad62a7d91829364eb48a05fa325c0d`).
- Lizenz: **GPL-3.0-or-later**. Ausnahmen innerhalb des Pakets:
  - `Vendor/Fldigi/src/common/gfft.h`: **LGPL-3.0-or-later** (Text: `Vendor/Fldigi/LICENSE_LGPL-3.0.txt`).
  - `Vendor/Fldigi/src/misc/locator.cpp`: aus Hamlib (Stephane Fillod und andere), **LGPL-2.0-or-later** (Text: `Vendor/Fldigi/LICENSE_LGPL-2.0.txt`).
  - `Vendor/Fldigi/src/compat/regex.c` und `regex.h`: GNU Regex 0.12 der Free Software Foundation (Copyright 1985–1993 FSF), in der Fassung von fldigi mit dem GPL-3.0-or-later-Kopf.
- Verwendet für: RTTY, SYNOP/SHIP/BUOY-Klartext, NAVTEX, CW, PSK, Olivia, Contestia, MT63, MFSK, DominoEX, Thor, Throb, IFKP, FSQ, Feld-Hell und die Hell-Verwandten, Wetterfax.
- Änderungen und genaue Dateiliste: `Vendor/Fldigi/UPSTREAM.md` und die Dateien `UPSTREAM_*.md` daneben.

### WSJT-X (wsprd)

- Autoren: Joe Taylor (K1JT), Steven Franke (K9AN) und weitere Mitwirkende von WSJT-X.
- Quelle: https://sourceforge.net/projects/wsjt/ (Repository `git.code.sf.net/p/wsjt/wsjtx`, Commit `b4f9a431bcf6449df8f37b56de79d48b665b044c`, Verzeichnis `lib/wsprd`).
- Lizenz: **GPL-3.0** (Text: `Vendor/Wspr/LICENSE_wsjtx_GPLv3.txt`).
- `Vendor/Wspr/src/nhash.c` (Hashfunktion von Bob Jenkins) ist laut seinem Kopf **gemeinfrei** („public domain“).
- Verwendet für: WSPR. Änderungen: `Vendor/Wspr/UPSTREAM_WSPR.md`.

### ft8mon

- Autor: Robert T. Morris (AB1HL). Quelle: https://github.com/rtmrtmrtmrtm/ft8mon (Commit `1b36a13`).
- Lizenz: **MIT** (Text: `Vendor/FT8/LICENSE_ft8mon.txt`; das Jahr steht dort so wie im Original).
- Verwendet für: FT8 (Decoder). Änderungen: `Vendor/FT8/UPSTREAM_FT8.md`.

### ft8_lib

- Autor: Kārlis Goba (YL3JG). Quelle: https://github.com/kgoba/ft8_lib (Commit `9fec6ca`).
- Lizenz: **MIT** (Text: `Vendor/FT8/LICENSE_ft8_lib.txt`).
- Verwendet für: FT4-Demodulator und -Decoder, Testsignale (Encoder). Darin enthalten: **KISS FFT** von Mark Borgerding, Copyright 2003–2010, **BSD-3-Clause** (Text: `Vendor/FT8/LICENSE_kissfft.txt`).

### pocketfft (C++-Zweig)

- Autoren: Max-Planck-Society, Martin Reinecke. Quelle: https://github.com/mreineck/pocketfft.
- Lizenz: **BSD-3-Clause** (Text: `Vendor/FT8/LICENSE_pocketfft.md` und `Vendor/Wspr/LICENSE_pocketfft.md`).
- Verwendet für: FFT in FT8, FT4 und WSPR (statt FFTW).

## 3. Eigene Umsetzungen nach Vorbildern

In diesen Fällen steht **kein Fremdcode** im Digidec-Quelltext. Die Programme wurden gelesen und dienten als Vorbild oder als Referenz, mit der die eigene Umsetzung verglichen wurde. Die Herkunftsdateien liegen unter `Vendor/<Modul>/UPSTREAM_*.md`.

- **ACARS**: Verfahren nach acarsdec (Thierry Leconte, GPL). Positionsberichte nach den Regeln und Testfällen von acars-decoder-typescript (airframes.io, MIT; Testfälle sind in den Logiktests übernommen).
- **ALE**: nach der MIT-lizenzierten Referenz openALE (DL3HC, aufbauend auf PC-ALE 2.0 von Alex Pennington). Lizenztext: `Vendor/Ale/LICENSE_openALE.txt`.
- **APRS/AX.25**: Gegenprobe mit Dire Wolf (WB2OSZ, GPL); Mic-E-Tabellen nach dessen `decode_aprs.c`. Prüfmaterial: WA8LMF TNC Test CD (nur lokal, nicht im Repository).
- **DSC**: nach ITU-R M.493-9. Symbolfolgen echter Rufe als Testvektoren aus TAOSW.DSC_Decoder (Tao Energy SRL, MIT). Lizenztext: `Vendor/Dsc/LICENSE_TAOSW.DSC_Decoder.txt`.
- **Funkruf (POCSAG, FLEX) und Tonfolgen**: Gegenprobe mit multimon-ng (Elias Oenal, GPL).
- **Skimmer**: eigener Entwurf; der Aufbau von KZ4AP Skimmer (GPL-3.0) wurde zum Vergleich gelesen. Die Varicode-Tabelle ist die allgemein bekannte von G3PLX und wurde gegen fldigi geprüft.
- **Radiosonden (RS41)**: Rahmenaufbau, Reed-Solomon und Kalibrierformeln nach rs41mod (zilog80, radiosonde_auto_rx, GPL-3.0).
- **HFDL**: Rahmenaufbau, Protokolltypen und die Systemtabelle der Bodenstationen nach dumphfdl 1.7.0 (Tomasz Lemiech, GPL-3.0); die Signalverarbeitung ist eigene Arbeit.
- **AIS**: eigener Empfänger und eigene Auswertung nach ITU-R M.1371-5 und IEC 61162-1; die Layouts der binären Nachrichten (Wetter, Binnenschiff, Gebietsmeldungen u. a.) nach der AIVDM/AIS-Beschreibung des gpsd-Projekts (BSD-2-Clause, https://gpsd.io). Gegenprobe mit AIS-catcher (jvde-github, GPL-3.0; nur als Programm benutzt, kein Quelltext übernommen) und mit der Sammlung `sample.aivdm` des gpsd-Projekts (BSD) sowie der I/Q-Aufnahme „AIS“ von Signal Identification Wiki; beides nur lokal, nicht im Repository. Herkunft und Nachweis: `Vendor/Ais/UPSTREAM_AIS.md`. Die Zuordnung der MMSI-Kennzahl (MID) zu Ländern folgt der öffentlichen Liste der ITU.
- **Packet-Radio (Winlink, Mailbox, NET/ROM)**: eigene Umsetzung nach AX.25 v2.2, dem B2F-Protokoll von Winlink und der Beschreibung von NET/ROM. Der Entpacker LZHUF folgt dem Algorithmus von Haruyasu Yoshizaki (1988) und Haruhiko Okumura (LZSS mit adaptivem Huffman-Code); die Swift-Umsetzung ist eigene Arbeit. Gegenprobe und Prüfdateien (`gettysburg.txt`, `e.txt` und eine echte Winlink-Nachricht, jeweils mit `.lzh`) aus dem Repository **Pat / wl2k-go** (Martin Hebnes Pedersen, LA5NTA, MIT, https://github.com/la5nta/wl2k-go); nur gelesen und lokal unter `TestData/Winlink` benutzt, kein Quelltext übernommen, die Dateien nicht im Repository. Herkunft und Nachweis: `Vendor/Packet/UPSTREAM_PACKET.md`.
- **SSTV, DCF77, EFR (DCF49/DCF39/HGA22)**: nach den veröffentlichten Beschreibungen der Verfahren.

Normen und Beschreibungen, nach denen gearbeitet wurde (nicht Teil des Pakets): ITU-R M.493, ITU-R M.1371-5 und IEC 61162-1 (AIS), IMO SN/Circ.236 und SN.1/Circ.289 (binäre AIS-Nachrichten), Inland-AIS-Standard (DAC 200), MIL-STD-188-141, ARINC 618 und 635, APRS Protocol Reference (APRS101), DIN 19244 / IEC 60870-5, WMO FM 12/13/18 (SYNOP, SHIP, BUOY), IMO NAVTEX-Handbuch.

## 4. Daten im Programm (Resources/)

- **Flughäfen** (`Resources/Airports/airports.txt`): OurAirports (https://ourairports.com/data/), gemeinfrei, Stand 02.10.2026.
- **Radiosonden-Startorte** (`Resources/Sonde/sondehub_sites.json`): SondeHub (https://sondehub.org, Abruf `https://api.v2.sondehub.org/sites`), Einträge von den Nutzern gepflegt, **CC BY-SA 2.0**. Namensnennung: „SondeHub und seine Mitwirkenden“. Für diese Datei gilt Share-Alike; sie ist vom Programmcode getrennt, und Änderungen an ihr müssen unter derselben Lizenz weitergegeben werden.
- **Länder und Präfixe** (`Resources/cty.dat`): Country Files von Jim Reisert (AD1C), https://www.country-files.com/, auf Grundlage der ARRL-DXCC-Liste. Die Datei wird vom Autor zur freien Nutzung bereitgestellt; eine förmliche Lizenz ist nicht bekannt. Die ARRL-Bezeichnungen sind Marken der ARRL.
- **Stationslisten** (`Resources/Stations/`: `nsd_bbsss.txt`, `station_table.txt`, `ToR-Stats-SHIP.csv`, `wmo_list.txt`, `NAVTEX_Stations.csv`): aus dem Datenordner von fldigi 4.2.13 (dort unter GPL-3.0-or-later). Die ursprünglichen Quellen sind WMO-Stationsverzeichnisse, die Stationsliste der Bojen des NDBC (NOAA) und Schiffs- und NAVTEX-Listen; der Stand ist teils über zehn Jahre alt. Genaue Herkunft: `Vendor/Fldigi/UPSTREAM_SYNOP.md`.
- **Sendepläne** (`Resources/Rtty/`, `Resources/Wefax/`): Textauszüge der Sendepläne des Deutschen Wetterdienstes (Stand 09/2023). **Quelle: Deutscher Wetterdienst**, https://www.dwd.de/. Die Aktualisierung im Programm lädt die Seiten und PDFs des DWD nur auf Knopfdruck.
- **Karten**: Die Kartendarstellung nutzt Apple Karten (MapKit) mit den Nutzungsbedingungen von Apple; Kartenbilder, die du mit BILD speicherst, enthalten Kartendaten von Apple.

Außer den Kartenkacheln von Apple und der Verbindung zu deinem rigctld ruft Digidec nichts von sich aus im Netz ab. Plandaten werden nur geladen, wenn du den Knopf **Aktualisieren** im Sendeplan drückst, und nur von dwd.de und api.v2.sondehub.org.

**Schiffsdaten (AIS):** Öffnest du in der AIS-Karte oder -Liste die Schiffsdaten eines Schiffs, fragt Digidec (solange der Schalter NETZ-SUCHE an ist, sonst erst auf Knopfdruck) bei **Wikidata** (`query.wikidata.org`, `www.wikidata.org`; Daten **CC0**), **Wikimedia Commons** (`commons.wikimedia.org`, `upload.wikimedia.org`; Fotos mit eigener Lizenz, die im Fenster mit Urheber angezeigt wird) und **Wikipedia** (`de.wikipedia.org`, `en.wikipedia.org`; Texte **CC BY-SA**) nach diesem Schiff. Übermittelt werden nur MMSI, IMO-Nummer, Rufzeichen und Name dieses Schiffs. Antworten werden unter `~/Library/Caches/com.peterbetz.digidec/ShipInfo` zwischengespeichert. Für Seezeichen und Küstenstationen wird nichts abgefragt. Die Knöpfe zu MarineTraffic, VesselFinder, ShipSpotting und BalticShipping öffnen nur die Seite im Browser.

## 5. Testaufnahmen

Aufnahmen und Beispielberichte, mit denen Digidec bei der Entwicklung geprüft wird, gehören **nicht** zum Repository und nicht zum Programm; sie liegen nur lokal beim Entwickler (Ordner `TestData/`, in `.gitignore`). Die Logiktests überspringen die Prüfungen, die sie brauchen, wenn sie fehlen. Im Quelltext der Tests stehen nur Zahlen- und Symbolfolgen aus den Testfällen von TAOSW.DSC_Decoder (MIT) und acars-decoder-typescript (MIT, siehe Abschnitt 3).

## 6. Systembestandteile und externe Programme

- Apple-Frameworks (SwiftUI, MapKit, AVFoundation, CoreAudio, Accelerate und weitere) gehören zum Betriebssystem und werden nicht mitgeliefert.
- **Hamlib** wird nicht eingebunden. Digidec spricht nur das Textprotokoll von `rigctld` (Hamlib, GPL/LGPL) über TCP, wenn du ein Funkgerät über einen rigctld einstellst. Gesendet werden nur `f`, `m` und auf Wunsch `F`, `M`.
- Die Namen fldigi, WSJT-X, Hamlib, Dire Wolf, multimon-ng, SondeHub, OurAirports und weitere sind Namen oder Marken ihrer Inhaber; sie werden hier nur zur Herkunftsangabe genannt.
