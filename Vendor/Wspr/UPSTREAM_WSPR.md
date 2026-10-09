# WSPR – Herkunft und Abweichungen

## Quellen

| Teil | Herkunft | Lizenz |
|---|---|---|
| Decoder (`src/wspr_rx.c` aus `wsprd.c`, `fano.c`, `jelinek.c`, `nhash.c`, `tab.c`, `wsprd_utils.c`, `wsprsim_utils.c`, `inc/metric_tables.inc`) | **wsprd** aus **WSJT-X** (Joe Taylor K1JT, Steven Franke K9AN u. a.), `lib/wsprd`, SourceForge `git.code.sf.net/p/wsjt/wsjtx`, Commit `b4f9a431bcf6449df8f37b56de79d48b665b044c` (04.02.2025) | GPLv3 (`LICENSE_wsjtx_GPLv3.txt`) |
| FFT | **pocketfft** (C++-Zweig), github.com/mreineck/pocketfft | BSD-3 (`LICENSE_pocketfft.md`) |

Die Originale liegen unter `Vendor/_upstream/wsjtx` (nicht im Git; neu holen mit
`git clone --depth 1 https://git.code.sf.net/p/wsjt/wsjtx Vendor/_upstream/wsjtx`).
`python3 Vendor/Wspr/port_wspr.py` kopiert alles und bricht ab, wenn das Original nicht mehr wie erwartet aussieht.
Wie bei fldigi: Lizenz GPLv3; für die rein private Nutzung ohne Folgen, bei einer Weitergabe müsste Digidec GPLv3 werden.

## Aufbau

- `wspr_rx.c` wird von `port_wspr.py` aus `wsprd.c` erzeugt: alle Funktionen vor `main()` wortgleich (Synchronisation, Soft-Symbole, Signalsubtraktion, Phasenschätzung), `main()` selbst fällt weg.
- `inc/wspr_decode.inc` ist der Ersatz für `main()` und die C-Schnittstelle `include/wspr_digidec.h`. Der Rumpf folgt `main()` Zeile für Zeile, jede Abweichung ist mit „ABWEICHUNG wsprd (Digidec)“ gekennzeichnet.
- `wspr_fftw.h` / `wspr_fft.cc`: die wenigen FFTW-3-Aufrufe (`fftwf_*`) auf pocketfft.

## Abweichungen

1. **FFTW → pocketfft** (`wspr_fftw.h`, `wspr_fft.cc`): gleiche Konventionen (unnormiert, Vorzeichen). Auf dem WSJT-X-Beispiel `150426_0918.wav` liefert der Kern dieselben 8 Meldungen mit gleichem S/N und DT wie das Original-wsprd mit FFTW.
2. **Audio aus dem Speicher:** `readwavfile()` liest eine Datei; `wspr_downsample()` rechnet dasselbe (12 kHz → 375 Hz komplex, 46 080 Punkte) auf Daten im Speicher. Fehlendes Ende der Aufnahme = Stille.
3. **Ergebnisse per Rückruf** statt `ALL_WSPR.TXT`, `wspr_spots.txt` und Konsole. Keine Zeitdatei, kein FFTW-Wisdom. Die NF-Frequenz (1500 + Versatz) ersetzt die Funkfrequenz; Dial-Fehler-Korrektur (`-e`) entfällt.
4. **Voreinstellungen von wsprd** statt Kommandozeile: Fano-Decoder, 3 Durchgänge mit Subtraktion, Hashtabelle. Schalter `wide` entspricht `-w` (± 150 Hz), `deep` entspricht `-d`. Der Stack-Decoder (`-J`), 15-Minuten-Modus (`-m`), Schnellmodus, `.c2`-Dateien und die Voreinstellungen `-B -s -z -C` sind nicht erreichbar.
5. **Hashtabelle im Speicher**, zwischen Aufrufen erhalten; `wsprdd_hash_load/save` lesen und schreiben das Dateiformat von `hashtable.txt`. Typ-3-Meldungen (`<PJ4/K1ABC> FN42UD 37`) lösen sich erst auf, wenn das Rufzeichen vorher als Typ 1 oder 2 empfangen wurde.
6. **`ps[512][nffts]` auf dem Heap** (735 kB; auf dem Stack würden Arbeitsthreads mit 512 kB überlaufen).
7. **Keine OSD-Stufe:** `osdwspr_` (Fortran, `-o`) ist in wsprd optional und standardmäßig aus; SwiftPM baut kein Fortran.
8. **Ein Aufruf zur Zeit** (Mutex): wsprd hat globale Pläne und Zwischenspeicher.
9. **Testsignal** `wsprdd_synthesize` (nur für Tests, Digidec sendet nie): Kanalsymbole aus `get_wspr_channel_symbols`, 4-FSK reell bei 12 kHz (wie `add_signal_vector` in `wsprsim.c`).
10. **Swift-Nachbearbeitung** (`WSPRCore.removeResiduals`, nicht im C-Kern): Ein sehr starkes Signal hinterlässt nach der Subtraktion einen Rest, den wsprd als dieselbe Meldung mit viel kleinerem S/N wenige Hz daneben noch einmal findet (wsprd prüft nur ± 4 Hz); das stärkere bleibt.

## Prüfen

- Logiktests: sauberes Signal, Frequenz-/Zeitversatz, ± 110 / ± 150 Hz, drei Stationen mit Subtraktion, Weißrauschen bis −24 dB, Typ 2 und Typ 3, Hashtabelle, echte WSJT-X-Aufnahme, Zyklus über die Pipeline.
- Referenz: Original-wsprd mit FFTW bauen (`brew install fftw gfortran`; Quellen aus `Vendor/_upstream/wsjtx/lib/wsprd` und `lib/indexx.f90`) und mit `wsprd -a . -f <MHz> <datei>.wav` vergleichen. Der Dateiname muss `JJMMTT_HHMM.wav` heißen.
