# AIS (Automatic Identification System, GMSK 9600 Bd, UKW 161,975 / 162,025 MHz) – Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung nach **ITU-R M.1371-5** (Rahmenaufbau, Nachrichten) und **IEC 61162-1** (NMEA-Sätze `!AIVDM`).
Der Empfänger ist ein eigener Entwurf für **FM-Diskriminator-Audio** (so liefert es ein SDR-Programm hinter dem FM-Demodulator, auch über VALHost).
Referenz zur Gegenprobe (nur gelesen und als Programm gebaut, nicht übernommen): **AIS-catcher** (jvde-github, GPLv3, `Vendor/_upstream/ais/AIS-catcher`,
gebaut im Scratchpad mit cmake). AIS-catcher arbeitet auf I/Q, Digidec auf dem Audio hinter dem Diskriminator; das ist der Unterschied in der Empfindlichkeit (siehe Nachweis).

## Aufbau (`Sources/Decoders/AIS`)

| Datei | Inhalt |
|---|---|
| `AISCore.swift` | Bitfelder (`AISBits`), Bytefolge der Leitung (`AISBitOrder`), CRC-16 (HDLC/X.25), 6-Bit-Panzerung, NMEA-Sätze (auch mehrteilig), HDLC-Rahmenbildung (`AISDeframer`: Flaggen, Bit-Stopfen, Prüfsumme, Korrektur von ein oder zwei Bitfehlern), Sendeseite (`AISFraming`) |
| `AISMessage.swift` | Nachrichten 1–5, 9, 11, 12, 14, 18, 19, 21, 24, 27; Tabellen (Navigationsstatus, Schiffstyp, Seezeichen, Länder nach MID mit Flagge); Plausibilität (Länge je Typ, MMSI); `AISVessel` führt die Meldungen einer MMSI zusammen (Position, Stammdaten, Weg) |
| `AISDemod.swift` | Gauß-Impuls (BT 0,4), Demodulator mit Korrelation auf Training und Startflagge, Taktnachführung, Entscheidung, Wiederholungsstufen; `AISReceiver` mit vier Zweigen (Tiefpass 4,8 / 5,6 / 6,4 / 7,2 kHz) und Zusammenfassen gleicher Rahmen |
| `AISSignalGenerator.swift` | Nachrichten bauen (1, 4, 5, 18, 21, 24) und als Diskriminator-Audio ausgeben (Prüfstand, Tests) |
| `AISModule.swift` | Kanäle, Einstellungen, Decoder-Senke (48 kHz), Diagnose, Kartenaufbereitung, Controller |
| `Sources/Models/ShipInfoService.swift` | Schiffsdaten aus dem Netz (Wikidata, Wikimedia Commons, Wikipedia), Zwischenspeicher, Verweise zu Schiffsdatenbanken |
| `Sources/UI/AISPanels.swift` | Schiffsliste, Abstimmanzeige, Einstellungen, Fenster „Schiffsdaten“ |

## Empfänger

1. **Vorlage:** Jeder Burst beginnt mit 24 Bit Training (0101…, nach NRZI ein Ton von 2400 Hz) und der Startflagge 0x7E. Diese 32 Bit sind bekannt; sie werden als Gauß-geformte Pegelfolge
   (durch denselben Tiefpass wie das Signal) mit dem Eingang korreliert (normiert, Gleichanteil unschädlich). Ein Treffer liefert Lage (parabolisch verfeinert), Polarität, Amplitude und Gleichanteil (Frequenzablage des Senders).
2. **Auslesen:** Bits im Bittakt aus dem gefilterten Signal (kubische Interpolation), NRZI (0 = Wechsel), Entstopfen, Flaggen, CRC-16.
3. **Takt:** Aus den Nulldurchgängen des Rahmens (Ausgleichsgerade über die Bitnummer, mit Ausreißerausschluss) werden Lage und Takt nachgeführt (zweimal); der erste Versuch läuft mit dem Nenntakt.
4. **Wiederholungen** bei falscher Prüfsumme: (a) Korrektur eines Bits (alle Stellen) oder zweier unsicherer Bits; (b) Begrenzer gegen die Klicks des FM-Diskriminators bei schwachem Signal, Tiefpass neu gerechnet;
   (c) verschobene Lage, Schwelle und Takt (nur bei sicherem Burst).
5. **Schutz vor Zufallstreffern** (16 Bit Prüfsumme lassen bei Rauschen gelegentlich einen Rahmen durch): Länge muss zum Nachrichtentyp passen, MMSI muss gültig sein (bei nicht unveränderten Rahmen:
   bekannte MID und volle Bytelänge), korrigierte Rahmen unbekannter MMSI werden erst bei einer zweiten Sichtung angenommen, korrigierte Rahmen entfallen, wenn derselbe Burst unverändert gelesen wurde.
6. **Bitreihenfolge:** Auf der Leitung geht in jedem Byte das niederwertige Bit zuerst, die Felder der Nachricht sind MSB-zuerst; `AISDeframer` liefert Nutzbits in Nachrichtenordnung (wie `!AIVDM`).
   Das stand nicht in der Referenz, sondern ergab sich an der echten Aufnahme (zuerst Typ 8, 10, 43 statt 1, 5).

## Schiffsdaten aus dem Netz

Frei zugänglich ohne Schlüssel: **Wikidata** (Schiff über IMO-Nummer P458, sonst MMSI P587, Rufzeichen P2317, zuletzt über den Namen, nur eindeutig und ohne widersprechende Kennung),
**Wikimedia Commons** (Foto der Wikidata-Seite P18, sonst Kategorie „IMO n“, sonst Volltextsuche nach der IMO-Nummer; Lizenz und Urheber werden angezeigt), **Wikipedia** (Kurztext).
Die großen Schiffsdatenbanken (MarineTraffic, VesselFinder, Equasis …) haben keine freie Schnittstelle: das Fenster verweist per Knopf auf sie (Browser), es holt dort nichts ab.
Wikidata kennt vor allem große Handelsschiffe, Fähren, Kreuzfahrt- und Museumsschiffe; für kleine Boote bleibt es bei den AIS-Daten.
Zwischenspeicher: `~/Library/Caches/com.peterbetz.digidec/ShipInfo` (30 Tage, leere Antworten 1 Tag). Übermittelt werden MMSI, IMO-Nummer, Rufzeichen und Name des angeklickten Schiffs.

## Nachweis

- **gpsd-Sammlung** (`sample.aivdm` mit Erwartungswerten `sample.aivdm.chk`, BSD, Kurt Schwehr u. a.): Typen 1, 2, 3, 4, 5, 9, 11, 12, 14, 18, 19, 21, 24, 27 stimmen in allen geprüften Feldern.
- **Echte Aufnahme** (sigidwiki „AIS“, I/Q 48 kHz, 43 s, Limfjord bei Aalborg, Kanal B): mit dem FM-Diskriminator von Digidec dieselben **12 Rahmen** (13 Sätze) bitgleich wie AIS-catcher.
- **Funkstrecke nachgebildet** (`Tools/AISBench/ais_rf_sim.py`: GMSK, Frequenzablage ±0,8 kHz, Takt ±40 ppm, Rauschen in 25 kHz, ZF-Filter ±12,5 kHz, Diskriminator, Audio-Tiefpass 12 kHz; je 900 Meldungen):

  | C/N in 25 kHz | 8 dB | 10 dB | 12 dB | 14 dB | 20 dB |
  |---|---|---|---|---|---|
  | Digidec (Audio) | 56 % | 93 % | 98 % | 99 % | 100 % |
  | AIS-catcher (I/Q) | 99 % | 99 % | 99,6 % | 99,8 % | 100 % |

  Bei starken Signalen gleichwertig; unter etwa 10 dB bricht der FM-Diskriminator ein (Schwelleneffekt), der I/Q-Empfänger nicht. Ein Empfänger mit bekannter Taktlage (Genie, Tiefpass 5,6 kHz)
  liest bei 8 dB nur 49 % fehlerfrei; Digidec liegt mit Vierfach-Zweig und Bitkorrektur darüber. Mehr gäbe nur ein anderer Empfangsweg (I/Q statt Audio).
- **Reines Rauschen:** 400 s bei C/N 5 dB und 15 dB ohne einen Zufallsrahmen. Rechenzeit etwa 60× Echtzeit (eine Rechenkern-Auslastung unter 2 %).
