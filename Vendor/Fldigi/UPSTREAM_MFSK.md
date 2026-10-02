# MFSK, DominoEX, Thor, Throb, IFKP, FSQ und Hell – Herkunft und Abweichungen

Empfänger für **Throb** (1, 2, 4, X1, X2, X4), **IFKP** (0,5 / 1,0 / 2,0) und **FSQ** (1,5 / 2 / 3 / 4,5 / 6 Baud) sowie **MFSK** (4, 8, 11, 16, 22, 31, 32, 64, 128, 64L, 128L), **DominoEX** (Micro, 4, 5, 8, 11, 16, 22, 44, 88) und **Thor** (Micro, 4, 5, 8, 11, 16, 22, 25, 32, 44, 56, 100, 25x4, 50x1, 50x2) aus fldigi 4.2.13. Lizenz GPLv3 wie fldigi.
Erzeugt von `port_mfsk.py`: die Funktionen werden wörtlich herausgezogen (Klammerzählung); das Skript bricht ab, wenn das Original nicht mehr wie erwartet aussieht.

| Datei | Herkunft |
|---|---|
| `src/mfsk/mfsk_rx.cpp`, `mfsk_rx.h` | `mfsk/mfsk.cxx`, `include/mfsk.h`: Konstruktor (alle Betriebsarten), `rx_init`, Bildkopf-Erkennung, `recvchar`, `recvbit`, `decodesymbol`, `softdecode`, `harddecode`, `synchronize`, `afc`, `eval_s2n`, `rx_process`; Sendefunktionen nur für das Testsignal; Gray-Code aus `misc/misc.cxx` |
| `src/mfsk/dominoex_rx.cpp`, `dominoex_rx.h`, `dominovar.*` | `dominoex/dominoex.cxx`, `include/dominoex.h`, `dominoex/dominovar.cxx` (Varicode, unverändert) |
| `src/mfsk/thor_rx.cpp`, `thor_rx.h`, `thorvaricode.*` | `thor/thor.cxx`, `include/thor.h`, `thor/thorvaricode.cxx` (unverändert) |
| `src/mfsk/throb_rx.cpp`, `throb_rx.h` | `throb/throb.cxx`, `include/throb.h` (Tonpaar-Tabellen, Empfang, Sendefunktionen für das Testsignal) |
| `src/mfsk/ifkp_rx.cpp`, `ifkp_rx.h`, `ifkp_varicode.inc` | `ifkp/ifkp.cxx`, `include/ifkp.h`, `ifkp/ifkp_varicode.cxx` (unverändert) |
| `src/mfsk/fsq_rx.cpp`, `fsq_rx.h`, `fsq_varicode.inc`, `crc8.h` | `fsq/fsq.cxx`, `include/fsq.h`, `fsq/fsq_varicode.cxx` (unverändert), `include/crc8.h` |
| `src/mfsk/feld_rx.cpp`, `feld_rx.h`, `feldhell_12.inc`, `include/fldigi_hell.h`, `src/mfsk/fldigi_hell.cpp` | `feld/feld.cxx`, `include/feld.h`, `feld/FeldHell-12.cxx` (Schrift, unverändert); eigene C-Schnittstelle (Feld Hell liefert Rasterspalten statt Zeichen) |
| `src/mfsk/mfsk_compat.h` | Ersatz für Modem-Basisklasse, `progdefaults`, `progStatus`, Wasserfall, Anzeigen, Bildempfang |
| `src/mfsk/fldigi_mfsk.cpp`, `include/fldigi_mfsk.h` | C-Schnittstelle für Swift; Testsignal-Generator |
| (gemeinsam mit PSK) | `src/psk/viterbi.*`, `interleave.*`, `mfskvaricode.*`; `src/common/filters.*`, `fftfilt.*` |

## Abweichungen (`ABWEICHUNG fldigi (Digidec)` im Code)

1. **Nur Empfang:** Senden (`tx_process`, `transmit`, Bild- und Avatar-Senden) entfällt. Die Sendefunktionen (`sendsymbol`, `sendchar` …) bleiben, weil sie das Testsignal erzeugen (nach `tx_process()`: Vorspann, STX, Text, EOT, Nachspann).
2. **Bilder:** Bilder (MFSK-„Pic:“, Thor-„pic%“, Avatare) werden aus dem Signal genommen, damit der Text-Decoder nicht Unsinn ausgibt, aber nicht angezeigt. Die Pixel gehen an Rückrufe (`on_pixel`, `on_picture`), die Digidec nicht belegt.
3. **Einstellungen** kommen aus `FamProgdefaults`/`FamProgStatus` statt aus `progdefaults`: Standardwerte wie fldigi (Squelch an, Pegel 5, AFC an, MFSK-AFC-Zeitkonstante 32, Filterbreite DominoEX und Thor 2,0, Thor: Soft-Symbole und Soft-Bits an, Preamble-Erkennung an, CWI-Schwelle 0). **Ausnahme:** `slowcpu` ist aus (fldigi: an): fünf statt drei Pfade bei DominoEX und Thor; Digidec rechnet mit allen Pfaden.
3a. **Trägerfrequenz** setzt Digidec (`init()` ohne `modem::init()` und Wasserfallträger); DominoEX und Thor haben keine AFC (wie in fldigi).
4. **Je Instanz statt function-static:** der CWI-Zähler von MFSK `softdecode` ist Element der Klasse. **Thor** (Soft-Decoder, Preamble-Erkennung) und **DominoEX** (Sekundärtext-Zeiger) behalten fldigis function-static-Variablen: nur ein Decoder gleichzeitig; ein Moduswechsel setzt sie nicht zurück.
5. **Abtastraten:** MFSK11/22, DominoEX 5/11/22/44/88 und Thor 5/11/22/44 laufen mit 11025 Hz, Thor 56 mit 16000 Hz, alle anderen mit 8000 Hz (wie fldigi). Digidec hängt dafür drei Senken an die Pipeline und lässt die passende arbeiten.
6. **NUL-Zeichen:** Thor gibt Leerzeichen-Füllung (NUL) aus; die Swift-Hülle verwirft Zeichen 0.
8. **Throb:** Die Metrik ist das S/N-Verhältnis (fldigi-Schwelle 5); der Squelch-Regler 0 … 100 wird auf 0 … 20 abgebildet (Voreinstellung 30 → 6), die Pegelanzeige ebenso.
9. **IFKP:** Bildempfang, Avatar, Heard- und Audit-Protokoll, Rufzeichenliste und die Bindung an 1500 Hz (`ifkp_freqlock`, in fldigi an) entfallen; Zeichen gehen unverändert in den Text. Die Geschwindigkeit 0,5 / 1,0 / 2,0 bestimmt wie in fldigi die Mittelungslänge des Empfängers (2,0: 3, sonst 4); der Empfänger arbeitet mit 16 kHz.
10. **FSQ:** Die Auswertung gerichteter Befehle (Antworten, Weiterleiten, Sounder, Bildübertragung, Heard-Liste, CRC-Prüfung des Rufzeichens) entfällt. Die Zeichen gehen wie im fldigi-Monitor (nicht „gerichtet“) in den Text, ein Rahmen beginnt mit Zeilenvorschub und endet am Rahmenende; der Squelch öffnet am Rahmenanfang (` \n`) und schließt am Ende. Empfänger mit 12 kHz.
11. **Hell (Feld Hell, Slow Hell, X5, X9, FSK Hell 245/105, Hell 80):** Empfänger wörtlich (`rx_init`, `restart`, `rx`, `FSKH_rx`, `rx_process`); die Rasterspalten (je 2 · Spaltenlänge Werte, vorherige und aktuelle Spalte) gehen an einen Rückruf statt in das Raster-Widget (`put_rx_data`); `HellRcvWidth` wiederholt jede Spalte im Empfänger wie in fldigi. Digidec baut daraus ein Bild (`HellRasterModel`, 720 Spalten je Zeile, 2 · Spaltenlänge Pixel hoch, Zeilenumbruch). Die Schrift der Sendefunktionen ist nur „hell 12“ (fldigi-Standard); das Testsignal sendet über `tx_char`, ohne Mithören über den Empfänger. Die Zeichen werden **nicht** erkannt (Hell ist ein Bildverfahren).
7. **Sekundärtext** (DominoEX, Thor: Text während der Sendepausen) wird nicht ausgegeben (`put_sec_char` leer).

## Prüfen

- Logiktests: alle Betriebsarten außer MFSK4, DominoEX Micro, Thor Micro, IFKP 0,5 und FSQ 1,5 (sehr langsam) im Rundlauf, Mitte (1000, 2200 Hz), AFC (8 Hz Versatz), Umstellen von Mitte und Betriebsart, Rauschen (MFSK16 0 dB, MFSK32 6 dB, DominoEX 11 3 dB, Thor 16 0 dB), Squelch, IFKP 2,0 und FSQ 6 mit 6 dB S/N, Throb 4 mit 6 dB, Pipeline 48 kHz → 8000/11025/12000/16000 Hz. Hell: Rundlauf aller Betriebsarten (Spalten, Tinte verdoppelt sich mit dem Text), Spaltenlänge, Wiederholung, Mitte, Rauschen, Tafeldarstellung, Squelch, Raster-Bild.
- Das Testsignal folgt der Sendeseite von fldigi (dieselben Funktionen), ist aber **nicht** mit dem Original-fldigi gegengeprüft und **nicht** an echtem Funkverkehr. Gleiche Fehler auf Sende- und Empfangsseite würden sich aufheben.
- `Tools/DecodeFile/decode_file.sh <aufnahme.wav> --mfsk mfsk16 --center 1500` decodiert Aufnahmen offline.
