# Digidec

**Digidec** ist ein Decoder für Funkbetriebsarten auf dem Mac. Es liest das Empfangsaudio eines Funkgeräts oder SDR-Programms (über den USB-Audio-Codec des Geräts oder eine virtuelle Soundkarte) und macht daraus Text, Bilder, Listen und Karten: von Wetterfunk und Funkfernschreiben über Amateurfunk-Digimodes bis zu Flugzeugen, Schiffen und Radiosonden.

> Status: **Alpha** (aktuell 0.57.0). Es läuft auf dem Mac des Autors; vieles ist an Aufnahmen und Testsignalen geprüft, aber noch nicht im Dauerbetrieb. Fehler sind möglich. Es gibt **keine Gewährleistung** (siehe Lizenz).

## Was Digidec kann

Alle Module teilen sich Wasserfall, Eingangswahl, Karte, Log und Bedienung. Es decodiert immer nur das gewählte Modul.

**Kurzwelle und Langwelle (HF)**

| Modul | Inhalt |
|---|---|
| RTTY | Funkfernschreiben, frei einstellbar wie in fldigi; DWD-Presets mit Sendefrequenzen; SYNOP-, SHIP- und BUOY-Meldungen im Klartext; Wetterkarte mit Seewetterbericht, Isobaren, Extremwerten |
| NAVTEX, WEFAX, SSTV, HELL | Seewarnungen, Wetterfax (mit Sendeplan), Slow-Scan-Bilder, Feld-Hell |
| CW, PSK, OLIVIA, MT63, MFSK | Telegrafie, PSK31 bis 8PSK, Olivia und Contestia, MT63; MFSK mit DominoEX, Thor, Throb, IFKP, FSQ (49 Betriebsarten) |
| SKIMMER | liest alle CW- und PSK-Signale im Audio gleichzeitig, mit Rufzeichen, Land und Spots |
| FT8, FT4, WSPR | Bandaktivität, Entfernungen, Karte, ALL.TXT-Log |
| DSC, ALE, HFDL | Digitaler Selektivruf (auch UKW-Kanal 70), automatischer Verbindungsaufbau (ALE), Datenlink der Flugzeuge (HFDL) |
| DCF77, EFR | Zeitzeichensender mit Atomuhr und Zeitvergleich, Rundsteuertelegramme (DCF49, DCF39, HGA22) |

**UKW und darüber (VHF/UHF)**

| Modul | Inhalt |
|---|---|
| **AIS** | Schiffsverfolgung auf 161,975 und 162,025 MHz: Schiffsliste, Karte mit Kurs und Weg, beide Kanäle gleichzeitig; ein Klick auf ein Schiff öffnet ein Fenster mit Foto und technischen Daten aus dem Netz; Wetter-, Pegel-, Binnenschiff- und Gebietsmeldungen; NMEA-Log |
| APRS | 1200 Bd AX.25 mit Stationsliste, Nachrichten, Wetter und Karte |
| ACARS | Flugzeugmeldungen mit Positionen, OOOI-Berichten und Flughäfen |
| PAGER | Funkruf POCSAG und FLEX (z. B. DAPNET) |
| SONDE | Radiosonden Vaisala RS41 mit Flugweg, Landeprognose, Startorten und Sendeplan |
| TÖNE | DTMF, ZVEI, CCIR, EEA, EIA und SELCAL |

Weitere Merkmale: Sendepläne mit automatischer Aufnahme (Wetterfax, RTTY, NAVTEX, Radiosonden), Aufnahme des Eingangs als WAV (REC), Tagesprotokolle unter `~/Documents/Digidec/Logs`, Standort als Maidenhead-Locator für alle Entfernungen, Kartenbild-Export.

## Voraussetzungen

- Mac mit **macOS 14 oder neuer** (entwickelt mit dem macOS-27-SDK).
- **Xcode** (oder die Command Line Tools) mit **Swift 6** zum Bauen.
- Eine Audioquelle mit dem **Empfangsaudio**: der USB-Audio-Codec eines Funkgeräts (IC-PCR1500 und FT-991A werden automatisch erkannt) oder eine virtuelle Soundkarte wie BlackHole oder VALHost, in die ein SDR-Programm das Audio schreibt. Für AIS und Radiosonden braucht es das **Diskriminator-Audio eines FM-Empfängers** (FM, ausreichend breit, ohne De-Emphase, ohne Rauschsperre).
- Beim ersten Start fragt macOS nach dem Zugriff auf das Mikrofon (nötig für den Audioeingang).

## Bauen und starten

```bash
./build_app.sh
```

Das baut Digidec im Release-Modus, legt `Digidec.app` im Projektordner an (ad-hoc signiert) und meldet das URL-Schema `digidec://` beim System an. Danach `Digidec.app` öffnen.

## Funkgerät und Abstimmung

Digidec öffnet **keine seriellen Ports**. Frequenz und Betriebsart liest es über `rigctld` (Hamlib-Textprotokoll, TCP). Die zwei Commander-Programme des Autors (FT-991A und PCR-1500) bieten das an; im Dialog „Funkgerät“ lässt sich auch jeder andere `rigctld` mit Rechner und Port eintragen.
Auch **GQRX** (SDR, z. B. HackRF) lässt sich so einbinden: In GQRX die Remote Control einschalten (Tools → Remote control, Port 7356), in Digidec im Dialog „Funkgerät“ **NEU: GQRX** wählen. Das Audio kommt nicht über diese Verbindung, sondern über das Ausgabegerät von GQRX (z. B. VALHost 2ch oder BlackHole) als Eingang von Digidec. Weil GQRX kein RTTY kennt, stellt Digidec dort USB ein (CW als CW-U, AIS als FM mit 25 kHz).
Standardmäßig wird **nichts** an das Funkgerät gesendet. Schaltest du **QSY AUTO** ein, stimmt Digidec das Gerät beim Modul- oder Kanalwechsel ab und sendet dabei ausschließlich `F` (Frequenz) und `M` (Betriebsart), niemals PTT oder anderes.

Ein Hauptprogramm kann Digidec auch per URL starten und einstellen, zum Beispiel:

```
digidec://decode?mode=rtty&preset=dwd-lw&source=pcr1500&rigctl=4532&center=1000
digidec://decode?mode=ais&preset=both
```

Parameter und Presets stehen in `PLAN.md`, Abschnitt 3.

## Netzzugriffe

Digidec ruft von sich aus nichts im Netz ab, bis auf die Kartenkacheln von Apple. Auf Knopfdruck laden die Sendepläne Daten von dwd.de und api.v2.sondehub.org. Beim AIS-Schiffsfenster fragt es (abschaltbar mit NETZ-SUCHE) Wikidata, Wikimedia Commons und Wikipedia nach dem angeklickten Schiff; übermittelt werden nur MMSI, IMO-Nummer, Rufzeichen und Name dieses Schiffs. Einzelheiten: `THIRD_PARTY.md`, Abschnitt 4.

## Tests und Werkzeuge

```bash
Tools/LogicTests/run_logic_tests.sh      # rund 2500 Prüfungen der Rechenlogik, Exit-Code 0 = bestanden
```

Die Logiktests laufen ohne Audio und ohne Oberfläche (etwa 5 Minuten). Prüfungen, die echte Aufnahmen brauchen, werden übersprungen, wenn `TestData/` fehlt (die Aufnahmen gehören nicht ins Repository).
Weitere Werkzeuge unter `Tools/`: `DecodeFile` (Aufnahme offline decodieren), `AISBench`, `HFDLBench`, `PagerBench`, `SkimBench`, `MakeSignal` (Testsignale), `UIPreview`.

## Aufbau

```
Sources/App        Programmstart, Zustand, Version
Sources/Audio      Eingang (CoreAudio), Pipeline, Abtastratenwandler, Aufnahme
Sources/Decoders   ein Ordner je Betriebsart (RTTY, AIS, APRS, FT8 …)
Sources/Models     gemeinsame Modelle: Karte, Standort, DXCC, Sendepläne, Wetter
Sources/Rig        rigctld-Anbindung und Abstimmziele
Sources/UI         SwiftUI-Oberfläche (Wasserfall, Karte, Panels)
Vendor/            übernommener Quelltext (fldigi, WSJT-X, ft8mon, ft8_lib) und Herkunftsdateien
Resources/         Daten im Programm (Flughäfen, Stationslisten, Sendepläne)
Tools/             Prüfstände und Hilfsprogramme
PLAN.md            Projektplan, Meilensteine und Stand (Übergabedokument)
```

Wer weiterarbeiten will, beginnt mit `PLAN.md`: dort stehen Ziel, Entscheidungen, Projektregeln und der Stand je Version. Die Herkunft jedes Moduls steht in `Vendor/<Modul>/UPSTREAM_*.md`.

## Lizenz und Quellen

Digidec steht unter der **GNU General Public License, Version 3 oder später** (GPL-3.0-or-later), siehe `LICENSE`. Es enthält Quelltext aus **fldigi** und **WSJT-X** (beide GPL-3.0) sowie weiteren Projekten; die Quellen mit ihren Lizenzen, die Vorbilder der eigenen Umsetzungen und die verwendeten Daten nennt **`THIRD_PARTY.md`**.
Copyright (C) 2026 Peter Betz und Mitwirkende.
