# Digidec

**Digidec** ist ein Decoder für Funkbetriebsarten auf dem Mac. Es liest das Empfangsaudio eines Funkgeräts oder SDR-Programms (über den USB-Audio-Codec des Geräts oder eine virtuelle Soundkarte) und macht daraus Text, Bilder, Listen und Karten: von Wetterfunk und Funkfernschreiben über Amateurfunk-Digimodes bis zu Flugzeugen, Schiffen und Radiosonden.

> Status: **Alpha** (aktuell 0.83.0). Es läuft auf dem Mac des Autors; vieles ist an Aufnahmen und Testsignalen geprüft, aber noch nicht im Dauerbetrieb. Fehler sind möglich. Es gibt **keine Gewährleistung** (siehe Lizenz).

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
| JS8 | JS8Call-Betriebsarten Normal, Fast, Turbo und Slow (auch zugleich): Bandaktivität mit zusammengesetzten Nachrichten, Heartbeats, Befehle und Freitext (JSC), gehörte Stationen mit Karte, ALL.TXT-Log; nur Empfang |
| DSC, ALE, HFDL | Digitaler Selektivruf (auch UKW-Kanal 70), automatischer Verbindungsaufbau (ALE), Datenlink der Flugzeuge (HFDL) |
| DCF77, EFR | Zeitzeichensender mit Atomuhr und Zeitvergleich, Rundsteuertelegramme (DCF49, DCF39, HGA22) |

**Beide Bereiche**

| Modul | Inhalt |
|---|---|
| **MEHRKANAL** | Mehrere Decoder zugleich auf verschiedenen Frequenzen aus einem Fenster des SDR (HackRF bis 20 MS/s, bis zu 16 Kanäle), auf Kurzwelle wie auf UKW; steht in der Modulleiste als doppelt hoher Knopf vor beiden Rubriken. Je Kanal ein eigener Decoder: UKW/UHF (APRS, PACKET, AIS A und B, ACARS, PAGER, SONDE, VOR/ILS, TÖNE, DMR, D-STAR, YSF, dPMR, NXDN, P25, M17) und Kurzwelle (RTTY mit DWD-Voreinstellungen, DSC, NAVTEX, WEFAX, HFDL, SSTV mit Voreinstellungen in der richtigen Seitenband-Lage); im HF-Wasserfall markiert, Klick trägt die Frequenz ein; ACARS und VDL2 zeigen das Flugzeug aus ADS-B, DSC den Schiffsnamen aus AIS und die AIS-Liste markiert Schiffe mit Seenotruf |

**UKW und darüber (VHF/UHF)**

| Modul | Inhalt |
|---|---|
| **RDS** | Radio Data System im UKW-Rundfunk (87,5 bis 108,0 MHz, 57-kHz-Unterträger): Programmkennung (PI mit Land aus ECC), Sendername (PS), Radiotext (RT mit Verlauf und RT+: Titel und Interpret), Programmtyp (PTY und PTY-Name), Verkehrsfunk (TP/TA), Musik/Sprache, Decoder-Kennungen, Senderuhr (CT), Sprache, Alternativfrequenzen (AF) mit Direktabstimmung, Zusatzdienste (TMC, RT+) eine Kurzdiagnose des Empfangs und eine eigene Schnellauswahl („★ MERKEN“ legt den Sender mit seinem Programmnamen ab). Der Demodulator arbeitet mit dem Multiplexsignal bei 480 kS/s: pegelnormierte Costas-Schleife, Taktnachführung, Blocksynchronisation mit Bitschlupf-Erkennung und Reparatur von Ein- und Zweibitfehlern; Werte aus reparierten Blöcken zählen erst nach Bestätigung |
| **D-STAR** | Digitale Sprache (DV) im Amateurfunk: Kopf mit Rufzeichen, Gegenstation und Repeater, Textnachricht und GPS-Position aus den Langsamdaten, Verlauf der Aussendungen, später Einstieg ohne Kopf; der Ton kommt aus einem Sprachstick mit DVSI AMBE-3000R (in den Einstellungen wählen), ohne Stick bleibt es bei den Steuerdaten. Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Bd); die DPRS-Positionen der gehörten Stationen erscheinen mit Weg auf der Karte |
| **YSF** | Yaesu System Fusion (C4FM, Betriebsart V/D 2): Rufzeichen, Ziel und Repeater aus Kopf und Datenkanal, Verlauf der Aussendungen; der Ton kommt aus dem Sprachstick (derselbe wie bei D-STAR), ohne Stick bleibt es bei den Rufzeichen. Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Symbole/s) |
| **DMR** | Digital Mobile Radio (Repeater mit zwei Zeitschlitzen oder Direktmodus): Gespräche je Zeitschlitz mit Absender, Ziel (Gruppe oder Einzelruf) und Farbcode aus Sprach-Kopf und eingebetteter Information (auch bei spätem Einstieg); auf Wunsch Rufzeichen, Name und Ort aus der DMR-ID-Liste von radioid.net; der Ton eines Zeitschlitzes kommt aus dem Sprachstick (der Chip hat nur einen Kanal). Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Symbole/s); der Talker Alias (Name oder Text, den das Funkgerät mitsendet) wird gelesen |
| **P25** | APCO-25 Phase 1 (C4FM 4800 Bd, 12,5 kHz, verbreitet bei Behörden und im Amateurfunk): Netzkennung (NAC), Gruppe oder Ziel, Quelle, Hersteller, Verschlüsselungsalgorithmus und Schlüsselnummer, Notruf aus Kopf, LDU1 und LDU2 mit voller Fehlerkorrektur (BCH, Golay, Hamming, Reed-Solomon), Verlauf der Gespräche mit Wiedergabe der IMBE-Sprache (soweit ein Sprachdecoder da ist; verschlüsselte Gespräche bleiben stumm). Steuerkanäle werden erkannt, nicht gelesen. An echten Aufnahmen geprüft. Braucht das unbearbeitete FM-Diskriminator-Audio |
| **NXDN** | Kenwood NEXEDGE und Icom IDAS (Sprache; NXDN Forum TS 1-A): 4FSK mit 2400 Bd (NXDN48, 6,25 kHz) und 4800 Bd (NXDN96, 12,5 kHz), beide zugleich gesucht. Quelle, Ziel, Ruftyp (Gruppe, Einzelruf …), Funkzugangsnummer (RAN), Übertragungsart und Chiffre aus Rufkopf und SACCH, Verlauf der Gespräche mit Wiedergabe; Sprache über den Sprachstick (AMBE+2 wie bei DMR). Eigener Empfänger; an zwei echten Aufnahmen geprüft. Braucht das unbearbeitete FM-Diskriminator-Audio |
| **DPMR** | digital Private Mobile Radio (ETSI TS 102 658, Betriebsart 1: Sprache, 4FSK 2400 Bd im 6,25-kHz-Raster, verbreitet im Profifunk und bei PMR446): gerufene und rufende Kennung (sieben Stellen), Kanalcode, Notruf und Scrambler-Hinweis aus den Steuerkanälen, Verlauf der Gespräche mit Wiedergabe; Sprache über den Sprachstick (AMBE+2 wie bei DMR). Eigener Empfänger mit Takt und Pegel aus dem Synchronwort; an einer echten Aufnahme geprüft. Braucht das unbearbeitete FM-Diskriminator-Audio eines Empfängers mit schmalem Filter |
| **TETRA** | Bündelfunk (ETSI EN 300 392-2, π/4-DQPSK 18 000 Bd im 25-kHz-Raster, 380 bis 470 MHz) des **eigenen Netzes**: Digidec liest die I/Q-Daten selbst von HackRF, RTL-SDR, SDRplay oder SDRconnect (2 MS/s), empfängt den eingetragenen Hauptträger und schaltet Verkehrsträger zu, auf die Kanalzuweisungen verweisen. Zeigt Netz (MCC, MNC, Farbcode, Standortbereich, Dienste), Gespräche mit Gruppe, Rufer, Sprecher, Zeitschlitz und Dauer, Teilnehmer und Kurznachrichten (SDS-Text); unverschlüsselte Gespräche werden abgespielt, wenn ein TETRA-Sprachdecoder vorhanden ist (die Schnittstelle liegt bei; der Decoder selbst ist nicht Teil des Repositorys). Verschlüsselte Gespräche bleiben stumm, es wird nichts entschlüsselt. Gruppenfilter und frei vergebbare Namen für Kennungen. An einer echten Aufnahme und an Testsendern (Rauschen, Versatz, Taktfehler, mehrere Träger) geprüft, am Funkgerät noch nicht. **Nur im eigenen Netz und mit Erlaubnis des Betreibers verwenden** |
| **NDB** | Ungerichtete Funkfeuer (Langwelle und unteres Mittelwellenband, 190 bis 535 kHz): liest den getasteten Kennungston (A2A 400 oder 1020 Hz, auch ein Überlagerungston bei unmoduliertem Träger), liest die Morse-Kennung (bestätigt nach zwei gleichen Lesungen) und gleicht sie mit einer Liste der Funkfeuer ab (eingebaute Europaliste von OurAirports, auf Knopfdruck die aktuelle): Name, Land, Entfernung und Richtung vom eigenen Standort. Frequenz vom Funkgerät (rigctld) oder von Hand; Liste der Funkfeuer im Umkreis zum Anklicken (stellt das Funkgerät auf AM), Suchlauf über alle Funkfeuer im Umkreis, Karte mit den gehörten Funkfeuern, Wasserfall mit Tonmarke. An Testsignalen geprüft (Rauschabstand bis etwa −6 dB in 3 kHz), am Funkgerät noch nicht |
| **SENSOREN** | Funksensoren auf 433,92 und 868,3 MHz (Bresser, Fine Offset, Ecowitt, LaCrosse, Oregon Scientific, TFA, Hideki, Nexus, Prologue, Acurite, inFactory, Alecto, Ambient Weather u. a.: Thermometer, Hygrometer, Wetterstationen mit Wind, Regen, UV und Licht, Regenmesser, Poolthermometer): Digidec liest die I/Q-Daten (2 MS/s) selbst von HackRF, RTL-SDR, SDRplay (API oder SDRconnect) oder aus einer Aufnahme und zeigt jeden gehörten Sensor mit Kennung, Kanal, letzten Werten, Verlauf, Pegel und Batteriezustand; Wiederholungen eines Telegramms zählen einmal, dazu ein Protokoll und eine Tagesdatei. Die Verfahren der Pulserkennung und die Telegrammaufbauten folgen rtl_433; an 428 von 440 Aufnahmen aus dessen Prüfdaten geprüft (der Rest: abgeschaltete, kollidierende oder nur US-Sensoren). Braucht einen SDR, keinen Audioeingang. Der Reiter **UNBEKANNT** zeigt Aussendungen, die kein Decoder kennt, mit Pulsbreiten, vermuteter Modulation, Bits, Wiederholungen und Abstand (regelmäßige Sender sind Kandidaten für einen neuen Decoder) |
| **DAB** | Digitalradio (DAB und DAB+, Band III 174 bis 240 MHz): Digidec liest die I/Q-Daten (2,048 MS/s) selbst von HackRF, RTL-SDR oder SDRplay, empfängt das Ensemble (Name, Dienste, Programmtyp, Datenrate), spielt den gewählten DAB+-Dienst über den Standard-Ausgang und zeigt den laufenden Titel (Dynamic Label); SUCHLAUF über alle Blöcke. Der AAC-Decoder FAAD2 ist eingebunden. Klassisches DAB (MP2) wird noch nicht gespielt |
| **VDL2** | VDL Mode 2 (Datenfunk Flugzeug–Boden auf 136,725 … 136,975 MHz, D8PSK 10 500 Bd): Digidec liest die I/Q-Daten (2 MS/s) selbst von HackRF, RTL-SDR, SDRplay oder aus einer Aufnahme und demoduliert alle gewählten Kanäle zugleich (EUROPA mit sechs Kanälen, ALLE, nur 136,975 MHz oder einzeln); zeigt Flugzeuge mit ICAO-Adresse, Kennzeichen, Flug, Bodenstation und letzter Meldung, alle Rahmen als Protokoll mit ACARS-Texten sowie die Bodenstationen, dazu Kanalpegel und eine Tagesdatei. Vorbild ist dumpvdl2 (Reed-Solomon, Verwürfelung, AVLC); an dessen echter Testaufnahme geprüft. Braucht einen SDR mit Antenne für 136 MHz, keinen Audioeingang |
| **VOR/ILS** | Funknavigation aus AM-Audio (48 kHz) des SDR-Programms: VOR-Peilung (Radial) aus der Phase zwischen dem 30-Hz-Ton in der AM und dem 30-Hz-Ton auf dem 9960-Hz-FM-Hilfsträger, mit Eichung auf ein bekanntes Radial; ILS-Landekurs und -Gleitweg als DDM aus 90 und 150 Hz mit Ablageanzeige; Morse-Kennung (1020 Hz) wird gelesen und bestätigt. Kompass, Verlauf, Messwerte, Tagesdatei. An echten VOR-Aufnahmen geprüft (Richtung, Kennung); die Peilung verlangt eine Eichung, weil Filter im SDR-Programm die Phase verschieben. Für ein VOR muss die AM-Bandbreite mindestens 25 kHz betragen |
| **M17** | Offenes digitales Sprachverfahren der M17-Gemeinschaft (4FSK 4800 Symbole/s, Codec2 3200 und 1600): Gespräche mit Absender, Ziel (Rufzeichen oder Rundruf @ALL), Kanalzugriffsnummer (CAN), Text und Position aus dem Link Setup Frame, bei spätem Einstieg aus den LICH-Anteilen der Strom-Rahmen; Polarität wird erkannt, verschlüsselte Gespräche bleiben stumm. Der Sprachcodec Codec2 ist eingebaut, es braucht keinen Stick; die Sprache kommt direkt aus dem Standard-Ausgang. Braucht das Diskriminator-Audio eines FM-Empfängers (4800 Symbole/s); Positionen aus den Zusatzdaten erscheinen mit Weg auf der Karte. Dazu Paketmodus (SMS, APRS, IPv4 … mit CRC-Prüfung), BERT-Test (Bitfehlerrate) und Prüfung der digitalen Signatur mit hinterlegtem öffentlichem Schlüssel |
| **FREEDV** | Digitale Sprache für Kurzwelle von David Rowe VK5DGR (Betriebsarten 700D, 700E, 1600 und 700C): Modem und Sprachcodec Codec2 sind eingebaut, es braucht keinen Stick; die Sprache kommt direkt aus dem Standard-Ausgang, der Textkanal zeigt das Rufzeichen der Gegenstation, dazu Rauschabstand, Frequenzablage und Verlauf. Braucht das Empfangs-Audio des Funkgeräts im USB-Seitenband |
| **DRM** | Digital Radio Mondiale (DRM30, ETSI ES 201 980) auf Lang-, Mittel- und Kurzwelle: OFDM-Empfänger für die Robustheitsmodi A bis D und alle Kanalbreiten von 4,5 bis 20 kHz, 16- und 64-QAM. Zeigt Modus, Belegung, Dienstname, Sprache, Programmtyp, Datum und Zeit, Signalqualität und Frequenzablage; der Ton (AAC mit SBR, Mono und Stereo) wird mit FAAD2 decodiert, dazu die Textnachricht. Braucht das Empfangs-Audio mit etwa 10 kHz Breite im USB-Seitenband (Kanalmitte bei 6 kHz). Nicht enthalten: xHE-AAC, CELP, HVXC, DRM+ und Datendienste |
| **AIS** | Schiffsverfolgung auf 161,975 und 162,025 MHz: Schiffsliste, Karte mit Kurs und Weg (Schiffe als Umriss nach Typ und Länge, um den Kurs gedreht: Fracht, Tanker, Fahrgast, Schlepper, Segler, Fischer, Schnellboot, Behörden, Marine, Seenotrettung, Sportboot), beide Kanäle gleichzeitig; ein Klick auf ein Schiff öffnet ein Fenster mit Foto und technischen Daten aus dem Netz; Wetter-, Pegel-, Binnenschiff- und Gebietsmeldungen; NMEA-Log |
| **ADS-B** | Flugzeuge auf 1090 MHz (auf der Karte mit Umrissen nach Klasse: Verkehrs-, Großraum-, Geschäftsreise-, Kleinflugzeug, Hubschrauber, Segelflugzeug, Drohne, Ballon, Hochleistungsflugzeug, Bodenfahrzeug, um den Kurs gedreht) direkt vom SDR (HackRF, RTL-SDR, SDRplay direkt über die SDRplay-API oder über SDRconnect): Liste mit Kennung, Land, Höhe, Geschwindigkeit, Entfernung und Notlagen, Karte mit Weg und Farbe nach Höhe, Reichweitediagramm je Richtung, Meldungsprotokoll; Doppelklick auf ein Flugzeug öffnet ein Fenster mit Foto, Typ, Betreiber und planmäßiger Strecke (Start- und Zielflughafen, Fortschritt) |
| APRS | 1200 Bd AX.25 mit Stationsliste, Nachrichten, Wetter und Karte |
| PACKET | Packet-Radio 1200 Bd (AFSK) und **9600 Bd (G3RUH)**, umschaltbar: Monitor aller AX.25-Rahmen, Stationen und Digipeater, Verbindungen mit Gesprächsverlauf, Mailbox-Weiterleitung und **Winlink** (Nachrichten werden entpackt und gelesen, Anhänge speicherbar), NET/ROM-Knoten. Nachrichten anderer bitte vertraulich behandeln |
| ACARS | Flugzeugmeldungen mit Positionen, OOOI-Berichten und Flughäfen |
| PAGER | Funkruf POCSAG und FLEX (z. B. DAPNET) |
| SONDE | Radiosonden Vaisala RS41, Graw DFM (06, 09, 17), Meteomodem M10 und Meteosis M20, Typ automatisch erkannt; Flugweg, Landeprognose, Startorte und Sendeplan (Sendeplan nur für RS41) |
| TÖNE | DTMF, ZVEI, CCIR, EEA, EIA und SELCAL |

Weitere Merkmale: **Rufzeichen bei QRZ.com nachschlagen** (Knopf QRZ in den Listen von FT8, FT4, JS8, WSPR, Skimmer, APRS, Packet, D-STAR, DMR, YSF und M17, oder ⇧⌘K für das Eingabefeld; die Seite erscheint in einem eigenen Fenster), Sendepläne mit automatischer Aufnahme (Wetterfax, RTTY, NAVTEX, Radiosonden), Aufnahme des Eingangs als WAV (REC), Tagesprotokolle unter `~/Documents/Digidec/Logs`, Standort als Maidenhead-Locator für alle Entfernungen, Kartenbild-Export.

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

## Ausbreitungslineal

Am rechten Fensterrand zeigt ein senkrechtes Lineal von 0 bis 30 MHz die Kurzwellen-Ausbreitung an deinem Standort und zu dieser Uhrzeit: **rot** schlecht, **weiß** mittel, **grün** gut. Grundlage sind die berechneten Bandbedingungen von HamQSL (N0NBH, stündlich aktualisiert, Abruf höchstens alle 45 Minuten) für die Bandgruppen 80–40, 30–20, 17–15 und 12–10 m, getrennt für Tag und Nacht. Aus Standort (Locator), Datum und Uhrzeit rechnet Digidec den Sonnenstand und blendet in der Dämmerung zwischen Tag und Nacht über; zwischen den Bandgruppen wird in der Frequenz interpoliert, unterhalb von 3,5 MHz und im Sommer (Rauschen) geschätzt. Das ist eine grobe Orientierung, keine Streckenvorhersage. Cyan umrandet ist das Fenster des SDR, ein amberfarbener Pfeil markiert die eingestellte Frequenz; Maus darüber zeigt Quelle und Stand, ein Klick ruft neu ab.

## Eingebauter SDR-Empfänger

Mit einem **HackRF**, **RTL-SDR** oder **SDRplay** (RSP1A, RSP1B, RSPdx, RSPduo) braucht Digidec kein zweites Programm: Im Kasten „Eingang“ **SDR** wählen. Digidec liest die I/Q-Daten selbst (2,4 MS/s), demoduliert **WFM (Stereo, 230 kHz Kanalbreite), FM, AM, USB, LSB und CW** und gibt das Audio an das gewählte Modul, als käme es von einer virtuellen Soundkarte. Der HF-Wasserfall zeigt 2,4 MHz auf einmal (beim HackRF wählbar bis 20 MS/s, im Feld „FENSTER“); ein Klick (oder das Mausrad) stimmt ab, Frequenz und Breite lassen sich auch eintippen. Mit **MITHÖREN** hörst du das Audio über den Lautsprecher. Der Empfänger meldet sich als Funkgerät an: Module mit fester Frequenz (AIS, APRS, PACKET, PAGER, ACARS, SONDE, FT8 und die übrigen) stellen ihn selbst ein, solange **FOLGT MODUL** an ist. Module mit eigenem I/Q-Eingang (ADS-B, SENSOREN, VDL2, TETRA) bekommen das Gerät; der Empfänger gibt es ab und nimmt es danach wieder. Bibliotheken wie bei ADS-B: HackRF `brew install hackrf`, RTL-SDR `brew install librtlsdr`, SDRplay-API von sdrplay.com/api. GQRX muss das Gerät freigeben.

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

Digidec ruft von sich aus nichts im Netz ab, bis auf die Kartenkacheln von Apple. Auf Knopfdruck QRZ lädt es die Seite des Rufzeichens von qrz.com (in der Adresse steht nur das Rufzeichen; QRZ.com fragt selbst nach der Einwilligung für Cookies, die Anmeldung dort bleibt im Fenster erhalten). Auf Knopfdruck laden die Sendepläne Daten von dwd.de und api.v2.sondehub.org. Beim AIS-Schiffsfenster fragt es (abschaltbar mit NETZ-SUCHE) Wikidata, Wikimedia Commons und Wikipedia nach dem angeklickten Schiff; übermittelt werden nur MMSI, IMO-Nummer, Rufzeichen und Name dieses Schiffs. Die DMR-ID-Liste (Rufzeichen, Name und Ort zu den Funkgeräte-Kennungen, rund 17 MB) lädt es nur auf Knopfdruck in den DMR-Einstellungen von radioid.net. Beim ADS-B-Flugzeugfenster fragt es (abschaltbar mit NETZ-SUCHE) adsbdb.com und planespotters.net nach dem angeklickten Flugzeug; übermittelt werden nur ICAO-Adresse und Rufzeichen. Mit dem Schalter AUTO-INFO (standardmäßig aus) geschieht das im Hintergrund für alle gehörten Flugzeuge, höchstens eine Abfrage je Sekunde. Einzelheiten: `THIRD_PARTY.md`, Abschnitt 4.

## Tests und Werkzeuge

```bash
Tools/LogicTests/run_logic_tests.sh      # über 3300 Prüfungen der Rechenlogik, Exit-Code 0 = bestanden
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
