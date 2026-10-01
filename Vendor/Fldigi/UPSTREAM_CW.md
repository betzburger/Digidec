# CW – Herkunft und Abweichungen

CW-Empfänger aus fldigi **4.2.13** (`src/cw/cw.cxx`, Dave Freese W1HKJ u. a.; `src/cw/morse.cxx`; `src/filters/filters.cxx`), GPLv3.

## Erzeugung

`python3 Vendor/Fldigi/port_cw.py` erzeugt aus `Vendor/_upstream/fldigi-4.2.13/src`:

| Ziel | Quelle | Eingriff |
|---|---|---|
| `src/cw/cw_rx.h` | `include/cw.h` | Basisklasse `cw_modem_base` statt `modem`, `view_cw` durch Platzhalter ersetzt, `friend struct fldigi_cw` |
| `src/cw/cw_rx.cpp` | `cw/cw.cxx` | nur die Empfangsfunktionen, wörtlich (Ausschnitt per Klammerzählung) |
| `src/cw/morse.cpp`, `morse.h` | `cw/morse.cxx`, `include/morse.h` | `configuration.h` → `morse_defaults.h` |
| `src/cw/mbuffer.h` | `include/mbuffer.h` | unverändert (von Hand kopiert) |
| `src/common/filters.cpp`, `filters.h` | `filters/filters.cxx`, `include/filters.h` | `complex.h` → `fldigi_complex.h` |

Von Hand geschrieben: `cw_compat.h` (Umgebung), `morse_defaults.h/.cpp`, `fldigi_cw.cpp` und `include/fldigi_cw.h` (C-Schnittstelle).
Das Skript bricht ab, wenn eine Funktion oder Ersetzungsstelle nicht genau einmal vorkommt.

Übernommene Funktionen: `som_table`, `normalize`, `find_winner`, `rx_init`, `init`, Konstruktor, `reset_rx_filter`,
`sync_transmit_parameters`, `sync_parameters`, `update_tracking`, `update_Status`, `update_syncscope`, `clear_syncscope`,
`mixer`, `decode_stream`, `rx_FFTprocess`, `rx_process`, `usec_diff`, `handle_event`.

## Abweichungen

1. **Basisklasse:** `cw_compat.h` stellt `cw_modem_base` bereit, mit den Feldern und Methoden, die der Empfang aus `modem` braucht.
   `progdefaults` und `progStatus` sind Objektfelder (per Makro unter dem fldigi-Namen) mit fldigis Standardwerten.
   `wf` liefert nur Trägerfrequenz und Seitenband. `REQ(...)` (GUI-Aktualisierung) entfällt.
2. **Ausgabe:** `put_rx_char` ruft einen C-Rückruf. CTRL-Zeichen (Prosigns, beginnen mit `<`) werden markiert.
   `put_cwRcvWPM`, `display_metric`, `set_scope` und `set_scope_xaxis_1` speichern Werte für die Anzeige (WpM, Metrik, Hüllkurve, Schwelle).
3. **Senden und Tastung entfallen:** Winkeyer, nanoIO, GPIO, CAT-Keying, cwio-Thread und QSK. `create_edges()` ist leer, und der Destruktor gibt nur die Filter frei.
4. **Mehrkanal-Ansicht (`view_cw`, Signal Browser) entfällt.**
5. **file-static-Variablen** (`first_time`, `cw_freq`, `FIR_FILTER_LEN`, `filnbr`, `cwprocessing`) bleiben wie in fldigi. Deshalb gibt es nur **einen** CW-Decoder gleichzeitig.
   `cw_rx_reset_statics()` setzt `first_time` beim Anlegen zurück. fldigi legt den Empfänger nur einmal je Programmlauf an. Ohne Rücksetzen würde `reset_rx_filter()` bei einem zweiten Exemplar auf derselben Frequenz das Filter nicht setzen, und es bliebe auf 1000 Hz.
6. **Einstellungen:** fldigi liest sie schon im Konstruktor. Die C-Hülle setzt sie danach und ruft vor `init()` einmal `sync_parameters()` auf, und ebenso bei jeder Änderung.
7. **Blockgröße:** Die C-Hülle ruft `rx_process` wie fldigi in 512er-Blöcken bei 8000 Hz auf.
8. **Morsetabelle:** Die Optionen (Umlaute, Sonderzeichen, Prosign-Zeichen) stehen fest auf fldigis Standardwerten (`morse_defaults.h`): Ä, Å, Ç, È, É, Ö, Ñ, Ü sind an, die Prosigns werden als Name angezeigt (`<BT>`).

## Befunde

- **Einschwingen:** Die Pegelnachführung startet mit `agc_peak = 0` und `noise_floor = 1`. Nach völliger Stille wird das erste Element oft falsch gelesen. Das ist fldigi-Verhalten und in Digidec unverändert.
- **Geschwindigkeit:** Die Nachführung arbeitet nur im Bereich Start ±`CWrange` (10 WpM). Außerhalb davon zerfällt der Text.
- **Grenze (synthetisch, S/N in 3 kHz, 18 WpM, 150 Hz):** fehlerfrei bis +3 dB, bei 0 dB einzelne Fehler. Mit Matched Filter (36 Hz) bei −3 dB fehlerfrei.
