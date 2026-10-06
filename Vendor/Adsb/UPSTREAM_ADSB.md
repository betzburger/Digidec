# ADS-B (Mode S auf 1090 MHz) – Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung nach den Beschreibungen von Mode S und ADS-B (ICAO Annex 10 Band IV, RTCA DO-260B, „The 1090 MHz Riddle“ von Junzi Sun). Der Ablauf des Demodulators (Präambelprüfung, Pegelprüfung der Lücken, Wiederholung mit Phasenkorrektur) ist der von **dump1090** (Salvatore Sanfilippo, BSD-2-Clause) bekannte; die Phasenkorrektur beschreibt Oliver Jowett im Quelltext von dump1090. Der Quelltext von dump1090 liegt lokal unter `Vendor/_upstream/dump1090` (nicht im Git), gebaut im Scratchpad als Gegenprobe.

## Aufbau (`Sources/Decoders/ADSB`)

| Datei | Inhalt |
|---|---|
| `ModeSDemod.swift` | Betragsbildung (Tabelle, wie bei dump1090 mit 360 skaliert), Präambelsuche, Bits aus den beiden Hälften je µs, Phasenkorrektur, Zähler (Präambeln, Übersteuerung, Rauschen); blockgrößenunabhängig |
| `ModeSMessage.swift` | CRC-24 und Syndrome, Einbitkorrektur (nur DF 17/18), Adressprüfung mit 60 s Zwischenspeicher für DF 0/4/5/16/20/21, DF 11 mit Interrogator-Kennung, Inhalte: Kennung, Kategorie, Höhe (25-Fuß-Codierung), Kennung (Squawk), Position (CPR roh), Geschwindigkeit (Untertypen 1 bis 4), Bodenbewegung, Notlage; `ADSBCPR` (NL, globale und lokale Dekodierung, Luft und Boden) |
| `ADSBTracker.swift` | Flugzeugliste: Paarung gerader und ungerader Rahmen (10 s), danach Einzelrahmen relativ zur letzten Position, Plausibilität (höchstens 1500 kn zwischen Positionen, höchstens 1000 km vom Empfänger), Weg, Reichweite je 10°-Sektor |
| `ADSBTables.swift` | Staat aus der ICAO-Adresse (`Resources/ADSB/icao_ranges.csv`, Landesname deutsch aus dem System), Flugzeugkategorien, Notlagen |
| `ADSBSources.swift` | Quellen: Datei (rohe 8-Bit-I/Q), RTL-SDR (`librtlsdr`), HackRF (`libhackrf`). Die Bibliotheken werden per `dlopen` zur Laufzeit gesucht (`/opt/homebrew/lib`, `/usr/local/lib`), der HackRF liefert vorzeichenbehaftet und wird umgesetzt |
| `SDRconnectSource.swift` | SDRplay (RSP1B, RSPdx, RSPduo …) über die WebSocket-Schnittstelle von SDRconnect (Binärkennung 2 = 16-Bit-I/Q) |
| `ADSBModule.swift` | Einstellungen, Engine (eigener Faden, Rückstau mit Verwerfen), Controller (Quelle starten und stoppen, nur im aktiven Modul), Kartenaufbereitung (Farbe nach Höhe) |
| `ADSBSignalGenerator.swift` | Erzeugt Meldungen und I/Q-Daten für Tests und `make_signal.sh adsb` |
| `Sources/UI/ADSBPanels.swift` | Flugzeugliste, Meldungsprotokoll, Meldungsrate und Reichweitediagramm, Abstimmanzeige, Einstellungen |

## Nachweis

- **Gegenprobe mit dump1090** an dessen Beispielaufnahme `modes1.bin` (713 736 Byte): dump1090 findet 217 Meldungen (111 verschiedene), Digidec findet **alle** davon und dazu weitere gültige (284 Meldungen, 145 verschiedene; die Prüfsumme ist bei jeder erfüllt, 5 mit einem korrigierten Bit), unabhängig von der Blockgröße (2048 Byte bis 100 MB identisch).
- **Testvektoren** aus der Literatur (Rufzeichen KLM1023, Geschwindigkeit 159 kn / 182,88° / −832 ft/min, Höhe 38000 ft, CPR-Paar → 52,2572 / 3,91937, Bodenposition 17 kn / 92,8125°).
- **Rundlauf** Erzeuger → I/Q (mit Rauschen, Phasenversatz, schwachem Signal) → Demodulator → Tracker → Karte; Rauschen allein ergibt keine Meldung.
- **Nicht geprüft:** der Datenstrom von HackRF, RTL-SDR und SDRconnect an echter Hardware beim Schreiben (der HackRF war von GQRX belegt, RTL-SDR und RSPduo nicht angeschlossen). Die Bibliotheken werden gefunden und das Öffnen meldet „belegt“ bzw. „kein Gerät“ richtig.

## Grenzen

- Höhen mit Gillham-Codierung (Q-Bit 0, ältere Transponder) und in Metern bleiben ohne Höhe.
- Nicht ausgewertet: Typ 29 und 31 (Zielstatus, Betriebsstatus), Comm-B außer BDS 2,0 (Rufzeichen), TIS-B/ADS-R-Besonderheiten, MLAT.
- Abstimmen des Funkgeräts (QSY AUTO) entfällt: Der SDR wird direkt auf 1090 MHz gestellt.
