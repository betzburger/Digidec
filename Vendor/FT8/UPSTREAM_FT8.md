# FT8 – Herkunft und Abweichungen

## Quellen

| Teil | Herkunft | Lizenz |
|---|---|---|
| Decoder (`src/ft8.cc`, `osd.cc`, `libldpc.cc`, `unpack.cc`, `fft.cc`, `util.cc`, Header) | **ft8mon** von Robert Morris AB1HL, github.com/rtmrtmrtmrtm/ft8mon, Commit `1b36a13` (19.11.2021) | MIT (`LICENSE_ft8mon.txt`) |
| FFT | **pocketfft** (C++-Zweig), github.com/mreineck/pocketfft | BSD-3 (`LICENSE_pocketfft.md`) |
| Encoder für Testsignale (`src/ft8lib/`) | **ft8_lib** von Kārlis Goba YL3JG, github.com/kgoba/ft8_lib, Commit `9fec6ca` (24.08.2025) | MIT (`LICENSE_ft8_lib.txt`) |

Die Originale liegen unter `Vendor/_upstream/` (nicht im Git). `python3 Vendor/FT8/port_ft8mon.py` kopiert alles wortgleich.

## Warum ft8mon und nicht ft8_lib

Gemessen an 353 WSJT-X-Decodes aus den 27 Testaufnahmen von ft8_lib (`test/wav`):

| Decoder | gefunden |
|---|---|
| ft8_lib, Standard (`demo/decode_ft8.c`) | 73,4 % |
| ft8_lib, bestmögliche Parameter (Score 3, 600 Kandidaten, Zeit-OSR 4) | 75,9 % |
| ft8mon (FFTW, 5 s Rechenzeit) | 90,9 % |
| **ft8mon in Digidec** (pocketfft, 3 s) | **90,7 %** |

ft8mon arbeitet in mehreren Durchgängen mit Subtraktion decodierter Signale, mit OSD-Decodierung und mit Hinweisen auf CQ-Rufe. ft8_lib ist für Mikrocontroller gebaut und hat nichts davon.

## Abweichungen

1. **FFTW → pocketfft:** `compat/fftw3.h` stellt die benutzten FFTW-Aufrufe bereit (Pläne r2c, c2r, c2c, `fftw_execute_dft*`, `fftw_malloc`) und folgt FFTWs Konventionen (unnormiert, Vorzeichen). `fft.cc` bleibt unverändert. Die Trefferquote ist gleich (90,7 % gegen 90,9 %, Unterschied im Rechenzeit-Rauschen).
2. **libsndfile:** `readwav`/`writewav` in `util.cc` sind ausgeklammert (`DIGIDEC_WITH_SNDFILE`). Der Decoder ruft sie nicht auf.
3. **`libldpc.c` → `libldpc.cc`:** ft8mon übersetzt die Datei mit `c++`. SwiftPM würde sie als C übersetzen, und die Namen passten dann nicht zusammen.
4. **Rahmen `src/ft8_digidec.cc`:** Ablauf wie `ft8mon.cc` (`-file`/`-card`). Der Zyklus wird auf 15 s gebracht, Hinweise auf CQ, doppelte Meldungen werden nicht gemeldet und nicht noch einmal subtrahiert (`hcb`). Ein Zyklus läuft zur Zeit, weil ft8mons Parameter global sind.
5. **FT2 (0.97.0):** `monitor_config_t` hat zwei neue Felder (`symbol_period`, `slot_time`; 0 = Standard des Protokolls), `monitor_init` nimmt sie, wenn gesetzt. FT2 (inoffiziell) ist FT4 bei halber Symboldauer (0,024 s) und halbem Zyklus (3,75 s); Codierung, Sync-Folgen und Rahmen sind dieselben, `decode.c` bleibt unverändert (die 156 Blöcke je Zyklus bleiben gleich). `ft4_digidec.c` rechnet die SNR-Schätzung auf die halbe Symboldauer um (+3,01 dB gegenüber FT4). Rahmen `ft2dd_decode_cycle`, Testsignal `ft2dd_synthesize` (`ft8lib_synth.c`).
6. **Optimierung:** Das Target wird immer mit `-O3` übersetzt. Der Decoder ist zeitbegrenzt, im Debug-Build würde er sonst weniger Durchgänge schaffen.

## Unsichere Decodes

Alle bestätigten Decodes der Referenzaufnahmen haben ≥ 140 von 174 übereinstimmenden Bits (`correct_bits`). Darunter liegen fast nur Fehldecodierungen aus dem OSD-Zweig, etwa `TE9VBM 0T9FRX BE26` oder `i3=5 n3=3`.
Digidec markiert diese wie WSJT-X mit „?“. Dasselbe gilt für Meldungen mit unplausiblen Rufzeichen (ITU-Präfixregel). Meldungen `i3=…` werden verworfen.

## Prüfen

- `Tools/FT8Reference/run_reference.sh [Rechenzeit]`: Trefferquote gegen WSJT-X (braucht `Vendor/_upstream/ft8_lib`).
- `Tools/DecodeFile/decode_file.sh <wav> --ft8 [--budget 3] [--wsjtx ref.txt]`: eigene Aufnahmen; sie müssen am Zyklusbeginn starten.
