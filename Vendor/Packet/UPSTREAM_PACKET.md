# Packet-Radio (AX.25, Mailbox, Winlink, NET/ROM) – Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung nach **AX.25 v2.2** (Rahmen, Steuerfeld, Befehl/Antwort), der Beschreibung des **NET/ROM**-Protokolls (Knotenlisten und Netzwerkkopf)
und dem **B2F-Protokoll** von Winlink (Vorschläge `FC`/`FS`/`F>`, Datenblöcke SOH/STX/EOT, Nachrichtenformat). Die 1200-Bd-Demodulation (Bell 202) ist die des Moduls APRS (`Sources/Decoders/APRS/AFSKModem.swift`).

Referenz (nur gelesen, als Quelle für Testdaten benutzt, nichts übernommen): **Pat / wl2k-go** (Martin Hebnes Pedersen, LA5NTA, MIT, https://github.com/la5nta/wl2k-go),
lokal unter `Vendor/_upstream/wl2k-go` (nicht im Git). Aus dessen `lzhuf/testdata` stammen die Prüfdateien für den Entpacker (`gettysburg.txt`, `e.txt`, `LPE5NXDVLVSQ.b2f` samt `.lzh`), nur lokal unter `TestData/Winlink`.

LZHUF (LZSS mit adaptivem Huffman-Code) stammt aus dem Programm LZHUF von Haruyasu Yoshizaki (1988) und Haruhiko Okumura; Winlink und FBB benutzen es für Nachrichten.
`LZHUF.swift` ist eine eigene Umsetzung des Entpackers nach dem Algorithmus (die Huffman-Tabellen zum Decodieren werden aus den Positionscodes berechnet).

## Aufbau (`Sources/Decoders/Packet`)

| Datei | Inhalt |
|---|---|
| `PacketFrame.swift` | Steuerfeld (Rahmenarten I, RR, RNR, REJ, SREJ, SABM, SABME, DISC, UA, DM, UI, FRMR, XID, TEST; N(S), N(R), P/F), Befehl/Antwort aus den C-Bits, gehörter Sender und Digipeater, Monitorzeile, PID-Namen, NET/ROM (Knotenliste, Netzwerkkopf), IP-Kurzdeutung |
| `LZHUF.swift` | Entpacker für Winlink-Nachrichten (CRC-16, Länge, Bitstrom); dazu ein Kodierer, der nur Einzelzeichen schreibt (für Testsignale) |
| `PacketMail.swift` | Kennung `[WL2K-5.0-B2FWIHJM$]`, Vorschläge und Antworten (Winlink `FC`, Mailbox `FB`), Prüfsumme `F>`, Datenblöcke, Nachrichtenformat (Kopfzeilen, Text, Anhänge, RFC-2047-Wörter), Verfolgung beider Richtungen einer Verbindung |
| `PacketAnalyzer.swift` | Stationsliste (wie MHEARD), Digipeater, Verbindungen (Aufbau, Daten mit Folgenummern, Wiederholungen, Lücken, Abbau) mit Gesprächsverlauf, NET/ROM-Knoten, Nachrichten |
| `PacketModule.swift` | Kanäle (2 m: 144,8125 bis 144,9875 MHz, 70 cm: 433,625 bis 433,775 MHz, Raster 25 kHz), Einstellungen, Controller |
| `Sources/UI/PacketPanels.swift` | Monitor, Stationen, Digipeater, Verbindungen, Nachrichten, Knoten; Abstimmanzeige; Einstellungen |

## Was gelesen wird und was nicht

- **Gelesen:** alle AX.25-Rahmen mit gültiger Prüfsumme. Ungesicherte Rahmen (UI) und Verbindungsrahmen. Verbindungen werden aus **beiden** Richtungen zusammengesetzt, soweit zu hören. Fehlt ein Rahmen, steht im Verlauf eine Lücke.
- **Winlink-Nachrichten** (Vorschlag `FC`, B2F) werden entpackt und angezeigt, wenn **kein** Rahmen in den Daten fehlte (die Kompression lässt sich ab einer Lücke nicht fortsetzen). Mit Prüfsumme (EOT-Byte und CRC-16 der Nachricht).
- **Mailbox-Weiterleitung (FBB, `FB`/`FA`):** Vorschläge und der mitgeschriebene Text erscheinen; ihre binäre Kompression (B/B1) wird nicht entpackt.
- **Nicht gelesen:** 9600 Bd (G3RUH), erweiterte Sitzungen (SABME, Modulo 128, zweites Steuerbyte), INP3 und FlexNet-Besonderheiten, verschlüsselte oder gesicherte Inhalte.
- Reparierte Rahmen (ein gekipptes Bit) erscheinen nur im Monitor (`~`), nie in Stationen oder Verbindungen.

## Nachweis

- `Tools/LogicTests` (Abschnitt „Packet-Radio“): Steuerfeld, Monitorzeilen, Verbindungsablauf mit Wiederholung und Lücke, Digipeater, NET/ROM, LZHUF-Rundlauf und **bitgleiche Entpackung der echten Dateien**,
  die echte Winlink-Nachricht (Kopfzeilen, Text in ISO-8859-1, JPEG-Anhang mit 31028 Byte), eine vollständige synthetische Winlink-Sitzung (Kennungen, Vorschlag, `FS`, Datenblöcke in 128-Byte-Rahmen, Nachricht mit Anhang),
  Mailbox-Vorschläge, der Weg über das Audiosignal (Modulator → Empfänger → Controller).
