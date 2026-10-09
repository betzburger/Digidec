# MT63, Olivia und Contestia – Herkunft und Abweichungen

Empfänger für **MT63** (500/1000/2000 Hz, kurze und lange Verschachtelung) sowie **Olivia** und **Contestia** (4 … 64 Töne, 125 … 2000 Hz) aus fldigi 4.2.13. Lizenz GPLv3 wie fldigi.

Die Bibliotheken von **Pawel Jalocha SP9VRC** werden wortgleich kopiert (`port_mt63_olivia.py`), die Empfangslogik der fldigi-Modems steht in zwei von Hand geschriebenen Rahmen. (Anders als bei PSK und CW werden die fldigi-Klassen nicht herausgezogen, weil sie nur eine dünne Hülle um die Bibliothek sind.)

| Datei | Herkunft |
|---|---|
| `src/mt63/dsp.cpp`, `dsp.h`, `mt63base.cpp`, `mt63base.h` | fldigi `mt63/dsp.cxx`, `include/dsp.h`, `mt63/mt63base.cxx`, `include/mt63base.h` – unverändert |
| `mt63data/*.dat` | fldigi `mt63/*.dat` (Symbolform, Verschachtelungsmuster) – unverändert; nur außerhalb von `src/`, damit SwiftPM sie nicht als Quellen sucht |
| `src/olivia/jalocha/*.h` | fldigi `include/jalocha/*.h` (MFSK-Sender/-Empfänger, nur Header) – unverändert |
| `src/mt63/mt63_rx.cpp`, `include/fldigi_mt63.h` | Rahmen nach `mt63.cxx` (`rx_init`, `rx_process`, `rx_flush`, `restart`, `set_freq`); C-Schnittstelle |
| `src/olivia/olivia_rx.cpp`, `include/fldigi_olivia.h` | Rahmen nach `olivia.cxx` und `contestia.cxx` (`restart`, `rx_process`, `unescape`, `rx_flush`); C-Schnittstelle |

## Abweichungen (`ABWEICHUNG fldigi (Digidec)` im Code)

1. **Einstellungen** kommen aus `fldigi_olivia_config` / `fldigi_mt63_config` statt aus `progdefaults` (Standardwerte wie fldigi: Olivia/Contestia 8 Töne, 500 Hz, Sync-Rand 8, Integration 4, 8-Bit an, Squelch an mit Pegel 5; MT63 1000 Hz kurz, kurze Integration, 8-Bit an). Die Anzeige (Wasserfall-S/N, Statuszeilen, Signalbrowser) entfällt.
2. **Blöcke von 1024 Samples:** fldigi gibt dem Modem Blöcke von `fragmentsize = 1024`; die MT63-Bibliothek verträgt keine großen Blöcke (ihre Verzögerungsleitung ist auf einen Block ausgelegt). Die Rahmen teilen deshalb größere Eingaben.
3. **Mehrere Exemplare** gleichzeitig sind möglich (kein file-static-Zustand, anders als bei CW und PSK).
4. **Contestia:** wie in fldigi `contestia.cxx`: Sync-Schwelle in `rx_process()` mindestens 3, erste Trägerfrequenz `Bandbreite/2` statt Olivias `fc_offset`.
5. **Testsignale** (nur für Tests, Digidec sendet nie): Sendeseite nach `olivia::tx_process()` / `mt63::tx_process()` ohne Starttöne. **MT63:** Der Vorspann (32 bzw. 64 Nullzeichen) wird gesendet; fldigi füllt damit nur die Verschachtelung, ohne Ausgabe.
6. **`MT63tx::Preset()` zweimal:** Die Funktion liest `FFT.Size` schon vor `FFT.Preset()`; beim ersten Aufruf ist die Maske unbestimmt und `dspPhaseCorr[]` falsch. fldigi ruft `Tx->Preset()` ohnehin zweimal auf (`restart()` und `tx_init()`), der Testsignal-Generator tut es auch. Der Empfänger ist nicht betroffen (er berechnet seine Maske nach `FFT.Preset()`). Das zu finden hat Zeit gekostet: ohne den zweiten Aufruf decodiert der Empfänger das eigene Testsignal nicht.

## Prüfen

Logiktests: Olivia (6 Betriebsarten, REV, Mitte, −10 dB S/N, falsche Tonzahl, Umstellen der Mitte), Contestia (4 Betriebsarten, −8 dB), MT63 (alle 6 Betriebsarten, 6 dB S/N), Squelch bei Rauschen, Pipeline 48 kHz → 8 kHz. Das Testsignal folgt der Sendeseite von fldigi, ist aber **nicht** mit dem Original-fldigi gegengeprüft und nicht an echtem Funkverkehr. `decode_file.sh <wav> --olivia olivia-8-500 --center 1500` und `--mt63 1000s` decodieren Aufnahmen offline.
