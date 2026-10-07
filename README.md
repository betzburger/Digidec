# Digidec

**Digidec** ist ein Decoder für Funkbetriebsarten auf dem Mac. Es liest das Empfangsaudio eines Funkgeräts oder SDR-Programms (über den USB-Audio-Codec des Geräts oder eine virtuelle Soundkarte) und macht daraus Text, Bilder, Listen und Karten: von Wetterfunk und Funkfernschreiben über Amateurfunk-Digimodes bis zu Flugzeugen, Schiffen und Radiosonden.

> Status: **Alpha** (aktuell 0.75.0). Es läuft auf dem Mac des Autors; vieles ist an Aufnahmen und Testsignalen geprüft, aber noch nicht im Dauerbetrieb. Fehler sind möglich. Es gibt **keine Gewährleistung** (siehe Lizenz).

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
| **D-STAR** | Digitale Sprache (DV) im Amateurfunk: Kopf mit Rufzeichen, Gegenstation und Repeater, Textnachricht und GPS-Position aus den Langsamdaten, Verlauf der Aussendungen, später Einstieg ohne Kopf; der Ton kommt aus einem Sprachstick mit DVSI AMBE-3000R (in den Einstellungen wählen), ohne Stick bleibt es bei den Steuerdaten. Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Bd); die DPRS-Positionen der gehörten Stationen erscheinen mit Weg auf der Karte |
| **YSF** | Yaesu System Fusion (C4FM, Betriebsart V/D 2): Rufzeichen, Ziel und Repeater aus Kopf und Datenkanal, Verlauf der Aussendungen; der Ton kommt aus dem Sprachstick (derselbe wie bei D-STAR), ohne Stick bleibt es bei den Rufzeichen. Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Symbole/s) |
| **DMR** | Digital Mobile Radio (Repeater mit zwei Zeitschlitzen oder Direktmodus): Gespräche je Zeitschlitz mit Absender, Ziel (Gruppe oder Einzelruf) und Farbcode aus Sprach-Kopf und eingebetteter Information (auch bei spätem Einstieg); auf Wunsch Rufzeichen, Name und Ort aus der DMR-ID-Liste von radioid.net; der Ton eines Zeitschlitzes kommt aus dem Sprachstick (der Chip hat nur einen Kanal). Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Symbole/s); der Talker Alias (Name oder Text, den das Funkgerät mitsendet) wird gelesen |
| **DPMR** | digital Private Mobile Radio (ETSI TS 102 658, Betriebsart 1: Sprache, 4FSK 2400 Bd im 6,25-kHz-Raster, verbreitet im Profifunk und bei PMR446): gerufene und rufende Kennung (sieben Stellen), Kanalcode, Notruf und Scrambler-Hinweis aus den Steuerkanälen, Verlauf der Gespräche mit Wiedergabe; Sprache über den Sprachstick (AMBE+2 wie bei DMR). Eigener Empfänger mit Takt und Pegel aus dem Synchronwort; an einer echten Aufnahme geprüft. Braucht das unbearbeitete FM-Diskriminator-Audio eines Empfängers mit schmalem Filter |
| **TETRA** | Bündelfunk (ETSI EN 300 392-2, π/4-DQPSK 18 000 Bd im 25-kHz-Raster, 380 bis 470 MHz) des **eigenen Netzes**: Digidec liest die I/Q-Daten selbst von HackRF, RTL-SDR, SDRplay oder SDRconnect (2 MS/s), empfängt den eingetragenen Hauptträger und schaltet Verkehrsträger zu, auf die Kanalzuweisungen verweisen. Zeigt Netz (MCC, MNC, Farbcode, Standortbereich, Dienste), Gespräche mit Gruppe, Rufer, Sprecher, Zeitschlitz und Dauer, Teilnehmer und Kurznachrichten (SDS-Text); unverschlüsselte Gespräche werden abgespielt, wenn ein TETRA-Sprachdecoder vorhanden ist (die Schnittstelle liegt bei; der Decoder selbst ist nicht Teil des Repositorys). Verschlüsselte Gespräche bleiben stumm, es wird nichts entschlüsselt. Gruppenfilter und frei vergebbare Namen für Kennungen. An einer echten Aufnahme und an Testsendern (Rauschen, Versatz, Taktfehler, mehrere Träger) geprüft, am Funkgerät noch nicht. **Nur im eigenen Netz und mit Erlaubnis des Betreibers verwenden** |
| **NDB** | Ungerichtete Funkfeuer (Langwelle und unteres Mittelwellenband, 190 bis 535 kHz): liest den getasteten Kennungston (A2A 400 oder 1020 Hz, auch ein Überlagerungston bei unmoduliertem Träger), liest die Morse-Kennung (bestätigt nach zwei gleichen Lesungen) und gleicht sie mit einer Liste der Funkfeuer ab (eingebaute Europaliste von OurAirports, auf Knopfdruck die aktuelle): Name, Land, Entfernung und Richtung vom eigenen Standort. Frequenz vom Funkgerät (rigctld) oder von Hand; Liste der Funkfeuer im Umkreis zum Anklicken (stellt das Funkgerät auf AM), Suchlauf über alle Funkfeuer im Umkreis, Karte mit den gehörten Funkfeuern, Wasserfall mit Tonmarke. An Testsignalen geprüft (Rauschabstand bis etwa −6 dB in 3 kHz), am Funkgerät noch nicht |
| **SENSOREN** | Funksensoren auf 433,92 und 868,3 MHz (Bresser, Fine Offset, Ecowitt, LaCrosse, Oregon Scientific, TFA, Hideki, Nexus, Prologue, Acurite, inFactory, Alecto, Ambient Weather u. a.: Thermometer, Hygrometer, Wetterstationen mit Wind, Regen, UV und Licht, Regenmesser, Poolthermometer): Digidec liest die I/Q-Daten (2 MS/s) selbst von HackRF, RTL-SDR, SDRplay (API oder SDRconnect) oder aus einer Aufnahme und zeigt jeden gehörten Sensor mit Kennung, Kanal, letzten Werten, Verlauf, Pegel und Batteriezustand; Wiederholungen eines Telegramms zählen einmal, dazu ein Protokoll und eine Tagesdatei. Die Verfahren der Pulserkennung und die Telegrammaufbauten folgen rtl_433; an 428 von 440 Aufnahmen aus dessen Prüfdaten geprüft (der Rest: abgeschaltete, kollidierende oder nur US-Sensoren). Braucht einen SDR, keinen Audioeingang |
| **VDL2** | VDL Mode 2 (Datenfunk Flugzeug–Boden auf 136,725 … 136,975 MHz, D8PSK 10 500 Bd): Digidec liest die I/Q-Daten (2 MS/s) selbst von HackRF, RTL-SDR, SDRplay oder aus einer Aufnahme und demoduliert alle gewählten Kanäle zugleich (EUROPA mit sechs Kanälen, ALLE, nur 136,975 MHz oder einzeln); zeigt Flugzeuge mit ICAO-Adresse, Kennzeichen, Flug, Bodenstation und letzter Meldung, alle Rahmen als Protokoll mit ACARS-Texten sowie die Bodenstationen, dazu Kanalpegel und eine Tagesdatei. Vorbild ist dumpvdl2 (Reed-Solomon, Verwürfelung, AVLC); an dessen echter Testaufnahme geprüft. Braucht einen SDR mit Antenne für 136 MHz, keinen Audioeingang |
| **VOR/ILS** | Funknavigation aus AM-Audio (48 kHz) des SDR-Programms: VOR-Peilung (Radial) aus der Phase zwischen dem 30-Hz-Ton in der AM und dem 30-Hz-Ton auf dem 9960-Hz-FM-Hilfsträger, mit Eichung auf ein bekanntes Radial; ILS-Landekurs und -Gleitweg als DDM aus 90 und 150 Hz mit Ablageanzeige; Morse-Kennung (1020 Hz) wird gelesen und bestätigt. Kompass, Verlauf, Messwerte, Tagesdatei. An echten VOR-Aufnahmen geprüft (Richtung, Kennung); die Peilung verlangt eine Eichung, weil Filter im SDR-Programm die Phase verschieben. Für ein VOR muss die AM-Bandbreite mindestens 25 kHz betragen |
| **M17** | Offenes digitales Sprachverfahren der M17-Gemeinschaft (4FSK 4800 Symbole/s, Codec2 3200 und 1600): Gespräche mit Absender, Ziel (Rufzeichen oder Rundruf @ALL), Kanalzugriffsnummer (CAN), Text und Position aus dem Link Setup Frame, bei spätem Einstieg aus den LICH-Anteilen der Strom-Rahmen; Polarität wird erkannt, verschlüsselte Gespräche bleiben stumm. Der Sprachcodec Codec2 ist eingebaut, es braucht keinen Stick; die Sprache kommt direkt aus dem Standard-Ausgang. Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Symbole/s); Positionen aus den Zusatzdaten erscheinen mit Weg auf der Karte |
| **FREEDV** | Digitale Sprache für Kurzwelle von David Rowe VK5DGR (Betriebsarten 700D, 700E, 1600 und 700C): Modem und Sprachcodec Codec2 sind eingebaut, es braucht keinen Stick; die Sprache kommt direkt aus dem Standard-Ausgang, der Textkanal zeigt das Rufzeichen der Gegenstation, dazu Rauschabstand, Frequenzablage und Verlauf. Braucht das Empfangs-Audio des Funkgeräts im USB-Seitenband |
| **AIS** | Schiffsverfolgung auf 161,975 und 162,025 MHz: Schiffsliste, Karte mit Kurs und Weg, beide Kanäle gleichzeitig; ein Klick auf ein Schiff öffnet ein Fenster mit Foto und technischen Daten aus dem Netz; Wetter-, Pegel-, Binnenschiff- und Gebietsmeldungen; NMEA-Log |
| **ADS-B** | Flugzeuge auf 1090 MHz direkt vom SDR (HackRF, RTL-SDR, SDRplay direkt über die SDRplay-API oder über SDRconnect): Liste mit Kennung, Land, Höhe, Geschwindigkeit, Entfernung und Notlagen, Karte mit Weg und Farbe nach Höhe, Reichweitediagramm je Richtung, Meldungsprotokoll; Doppelklick auf ein Flugzeug öffnet ein Fenster mit Foto, Typ, Betreiber und planmäßiger Strecke (Start- und Zielflughafen, Fortschritt) |
| APRS | 1200 Bd AX.25 mit Stationsliste, Nachrichten, Wetter und Karte |
| PACKET | Packet-Radio 1200 Bd: Monitor aller AX.25-Rahmen, Stationen und Digipeater, Verbindungen mit Gesprächsverlauf, Mailbox-Weiterleitung und **Winlink** (Nachrichten werden entpackt und gelesen, Anhänge speicherbar), NET/ROM-Knoten. Nachrichten anderer bitte vertraulich behandeln |
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
- Nur für **ADS-B**: ein SDR mit Antenne für 1090 MHz. Digidec liest die I/Q-Daten selbst (kein Audio). HackRF: `brew install hackrf`, RTL-SDR: `brew install librtlsdr`; die Bibliotheken werden erst zur Laufzeit gesucht, Digidec baut und läuft auch ohne sie. SDRplay (RSP1A, RSP1B, RSPdx, RSPduo): direkt über die SDRplay-API 3.15 (Installer „Hardware API MacOS“ von https://www.sdrplay.com/api/, Digidec lädt sie erst zur Laufzeit; SDRconnect muss beendet sein) oder alternativ über SDRconnect (WebSocket-Server einschalten). Solange das Modul offen ist, gehört das Gerät Digidec; GQRX und andere Programme müssen es freigeben.

## Bauen und starten

```bash
./build_app.sh
```

Das baut Digidec im Release-Modus, legt `Digidec.app` im Projektordner an (ad-hoc signiert) und meldet das URL-Schema `digidec://` beim System an. Danach `Digidec.app` öffnen.

## Funkgerät und Abstimmung

Digidec öffnet **keine seriellen Ports**. Frequenz und Betriebsart liest es über `rigctld` (Hamlib-Textprotokoll, TCP). Die zwei Commander-Programme des Autors (FT-991A und PCR-1500) bieten das an; im Dialog „Funkgerät“ lässt sich auch jeder andere `rigctld` mit Rechner und Port eintragen.
Auch **GQRX** (SDR, z. B. HackRF) lässt sich so einbinden: In GQRX die Remote Control einschalten (Tools → Remote control, Port 7356), in Digidec im Dialog „Funkgerät“ **NEU: GQRX** wählen. Das Audio kommt nicht über diese Verbindung, sondern über das Ausgabegerät von GQRX (z. B. VALHost 2ch oder BlackHole) als Eingang von Digidec. Weil GQRX kein RTTY kennt, stellt Digidec dort USB ein (CW als CW-U, AIS als FM mit 25 kHz).

Ebenso **SDRconnect** (SDRplay): dort den WebSocket-Server einschalten (Port 5454), in Digidec im Dialog „Funkgerät“ **NEU: SDRCONNECT** wählen. Digidec liest Frequenz, Mode, Bandbreite und Zustand und stellt auf Wunsch (QSY AUTO oder die Karte „SDRconnect“ im Hauptfenster) Frequenz, Mode, Bandbreite, Verstärkungsstufe und den Gerätestrom ein. Das Audio kommt wie bei GQRX über eine virtuelle Soundkarte. Es werden nur Eigenschaften gesetzt, nie Aufnahmen gestartet.
Standardmäßig wird **nichts** an das Funkgerät gesendet. Schaltest du **QSY AUTO** ein, stimmt Digidec das Gerät beim Modul- oder Kanalwechsel ab und sendet dabei ausschließlich `F` (Frequenz) und `M` (Betriebsart), niemals PTT oder anderes.

Ein Hauptprogramm kann Digidec auch per URL starten und einstellen, zum Beispiel:

```
digidec://decode?mode=rtty&preset=dwd-lw&source=pcr1500&rigctl=4532&center=1000
digidec://decode?mode=ais&preset=both
```

Parameter und Presets stehen in `PLAN.md`, Abschnitt 3.

## Netzzugriffe

Digidec ruft von sich aus nichts im Netz ab, bis auf die Kartenkacheln von Apple. Auf Knopfdruck laden die Sendepläne Daten von dwd.de und api.v2.sondehub.org. Beim AIS-Schiffsfenster fragt es (abschaltbar mit NETZ-SUCHE) Wikidata, Wikimedia Commons und Wikipedia nach dem angeklickten Schiff; übermittelt werden nur MMSI, IMO-Nummer, Rufzeichen und Name dieses Schiffs. Die DMR-ID-Liste (Rufzeichen, Name und Ort zu den Funkgeräte-Kennungen, rund 17 MB) lädt es nur auf Knopfdruck in den DMR-Einstellungen von radioid.net. Beim ADS-B-Flugzeugfenster fragt es (abschaltbar mit NETZ-SUCHE) adsbdb.com und planespotters.net nach dem angeklickten Flugzeug; übermittelt werden nur ICAO-Adresse und Rufzeichen. Mit dem Schalter AUTO-INFO (standardmäßig aus) geschieht das im Hintergrund für alle gehörten Flugzeuge, höchstens eine Abfrage je Sekunde. Einzelheiten: `THIRD_PARTY.md`, Abschnitt 4.

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
