# JS8 – Herkunft und Abweichungen

## Quellen

| Teil | Herkunft | Lizenz |
|---|---|---|
| Decoder und Encoder (`src/js8_core.cc`) | **JS8Call** `JS8.cpp` (C++-Fassung des Fortran-Decoders von Allan Bazinet W6BAZ), github.com/js8call/js8call, Commit `a7ff1be0b389d287fdc56e2ea0d06962aa68127d` (05.12.2025) | GPLv3 (`LICENSE_GPLv3.txt`) |
| Wörterbuch (`src/jsc_words.c`) | **JS8Call** `jsc_map.cpp` (JSC, Jordan Sherer KN4CRD), 262 144 Wörter | GPLv3 |
| Entpacken der Rahmen (`Sources/Decoders/JS8/JS8Varicode.swift`) | **JS8Call** `varicode.cpp`, `jsc.cpp`, `decodedtext.cpp`, in Swift nachgebaut (nur Empfang) | GPLv3 |
| FFT (`compat/pocketfft_hdronly.h`) | **pocketfft** (C++-Zweig), github.com/mreineck/pocketfft | BSD-3 (`LICENSE_pocketfft.md`) |

Die Originale liegen unter `Vendor/_upstream/js8call` (nicht im Git; neu holen mit `git clone https://github.com/js8call/js8call` und die Dateien `JS8.cpp`, `JS8.hpp`, `varicode.cpp`, `varicode.h`, `jsc.cpp`, `jsc.h`, `jsc_map.cpp`, `commons.h`, `COPYING` sowie `media/tests` dorthin kopieren).
`python3 Vendor/JS8/port_js8.py` erzeugt `src/js8_core.cc` aus `JS8.cpp` und bricht ab, wenn das Original nicht mehr wie erwartet aussieht. `python3 Vendor/JS8/port_jsc.py` erzeugt `src/jsc_words.c`.

## Aufbau

- `js8_core.cc` = `JS8.cpp` ohne Worker/Decoder (Qt-Threads) + `inc/js8_api.inc` (C-Schnittstelle `include/js8_digidec.h`: Decodieren eines Fensters je Betriebsart, Kodieren, Testsignal).
- `compat/js8_compat.h` ersetzt `JS8.hpp` und `commons.h` und enthält die FFTW-Aufrufe (`fftwf_*`) auf pocketfft.
- `jsc_lookup.c`: Wort zu Index des Wörterbuchs (Offsettisch beim ersten Aufruf).
- Rechnung: Sync-Suche über alle Töne, Grundlinie (Polynom), Downsampling auf 32 (oder 20, 12) Abtastwerte je Symbol, Costas-Synchronisation in Zeit und Frequenz, Soft-Symbole, Belief-Propagation (174, 87), bis zu drei Durchgänge mit Subtraktion decodierter Signale. Betriebsarten Normal (A), Fast (B), Turbo (C), Slow (E); Ultra (I) ist im Quelltext vorhanden, in JS8Call aber abgeschaltet und in Digidec nicht erreichbar.

## Abweichungen

1. **Qt entfällt:** `Worker`, `Decoder` und die Ereignisse laufen nicht mehr über Qt-Threads und Signale. Ein Aufruf `js8dd_decode_window` rechnet ein Fenster im Aufrufer-Thread; je Betriebsart läuft ein Aufruf zur Zeit (Mutex), die Decoder (bis 10 MB Zwischenspeicher) liegen auf dem Heap und werden beim ersten Gebrauch angelegt.
2. **Boost entfällt:** `boost::augmented_crc<12, 0xc06>` ist eine eigene bitweise Division (`augmentedCRC12`); `ccmath::round` eine eigene `constexpr`-Rundung; **Boost.MultiIndex** (Kandidatenliste von `syncjs8`) ist ein `std::vector` mit derselben Auswahl: Normierung auf das 40-%-Perzentil, dann wiederholt der stärkste Kandidat, dazu fallen alle Einträge im Abstand `AZ` weg. NaN wird nie gewählt.
3. **Eigen entfällt:** Die Ausgleichskurve der Grundlinie (5. Grad, 6 Tschebyscheff-Knoten, also ein quadratisches System) löst eine Gauß-Elimination mit Spaltenwahl; die x-Werte sind auf [0, 1) normiert, das Ergebnis ist mathematisch dasselbe wie `colPivHouseholderQr()`.
4. **FFTW → pocketfft:** `fftwf_plan_dft_1d`, `fftwf_plan_dft_r2c_1d`, `fftwf_execute`, `fftwf_destroy_plan` in `compat/js8_compat.h`, gleiche Konventionen (unnormiert, Vorzeichen). Die Pläne merken ihre Puffer wie bei FFTW; der „In-place“-r2c sichert den Eingang vorher.
5. **Audio aus dem Speicher:** Das Fenster beginnt beim Zyklusbeginn (Index 0), kein Ringpuffer mit `kpos`/`ksz`. Was fehlt, ist Stille. Eingang `float`, Pegel wie 16-Bit-Zahlen (Swift multipliziert mit 32768), denn die S/N-Werte hängen vom absoluten Pegel ab.
6. **Wörterbuch:** statt der Tabelle `Tuple[262144]` mit Zeiger, Länge und Index nur die Zeichenfolge je Index (1,9 MB statt 6,3 MB Quelltext); gesucht wird nur Index → Wort (Empfang). Latin-1, wie im Original.
7. **Nachrichtenschicht in Swift:** `JS8Varicode.unpack` folgt `DecodedText` (Reihenfolge: schnelle Daten, Daten, Heartbeat, Compound, Directed). Befehle mit mehreren Schreibweisen geben die erste in der Sortierung von `QMap::key()` wieder (` SNR?` vor `?`, ` QUERY MSGS` vor ` QUERY MSGS?`). Kein Codieren bis auf `JS8Pack.swift` für Tests und Gegenprobe.
8. **Testsignal** `js8dd_synthesize` (nur für Tests): phasenstetiges 8-FSK wie `Modulator.cpp`.

## Prüfen

- Logiktests Gruppe `js8` (`Tools/LogicTests/run_logic_tests.sh --only js8`): Betriebsarten, Bänder, Entpacken echter Rahmen, Packen und Entpacken aller Rahmenarten, Nachrichten aus Rahmen, Decodieren synthetischer Signale in allen Betriebsarten (sauber, im Rauschen, zwei Stationen, Versatz), die Aufnahmen aus `media/tests` und ein Zyklus über die Pipeline mit simulierter Uhr.
- **Gegenprobe mit dem Original:** `JS8.cpp` unverändert (mit FFTW, Boost, Eigen aus Homebrew, ohne Qt-Teil) auf allen Aufnahmen in `media/tests` liefert dieselben Rahmen mit demselben S/N, DT und derselben Frequenz wie `js8_core.cc` (A_1_4: 5, A_2_1: 0, A_2_3: 2, A_2_5: 5, A_2_6: 4, A_2_9: 8, A_3_3: 2, E_1_1: 1, E_2_1: 1). Die Zahl im Dateinamen der Aufnahmen stammt vom alten Fortran-Decoder („Tiefe 1 bis 3“); der C++-Decoder dieser Fassung findet teils weniger oder mehr.
- Schwellen (Rauschen, S/N in 2500 Hz nominal): Normal etwa −17 dB, Fast −15, Turbo −13, Slow −22. JS8Call meldet dabei etwa 8 dB tiefer (Bezug auf die Symbolbandbreite), Normal also „−24 … −26 dB“ an der Schwelle.
