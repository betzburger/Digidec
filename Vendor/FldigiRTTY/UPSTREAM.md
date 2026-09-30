# FldigiRTTY – Herkunft und Abweichungen

RTTY-**Empfänger** aus fldigi, herausgelöst als GUI-freies C++-Modul mit C-Schnittstelle für Digidec.

## Quelle

| | |
|---|---|
| Projekt | fldigi (W1HKJ u. a.) |
| Repository | `https://git.code.sf.net/p/fldigi/fldigi` (SourceForge; der GitHub-Spiegel ist veraltet) |
| Stand | **v4.2.13**, Commit `e7c3ab3709ad62a7d91829364eb48a05fa325c0d` (29.07.2026) |
| Lizenz | GNU GPL v3 oder neuer; `gfft.h` GNU LGPL v3 |
| Nutzung | rein privat (PLAN.md). Bei Weitergabe müsste Digidec unter GPLv3 stehen. |

Die Originalquellen liegen zum Nachschlagen in `Vendor/_upstream/fldigi-4.2.13/` (nicht im Git, siehe PLAN.md 4.1).

## Dateien

| Digidec | fldigi 4.2.13 | Änderung |
|---|---|---|
| `src/gfft.h` | `src/include/gfft.h` | unverändert |
| `src/complex.h` | `src/include/complex.h` | unverändert |
| `src/fftfilt.h` | `src/include/fftfilt.h` | + Überladung `rtty_filter(f, k)` |
| `src/fftfilt.cpp` | `src/filters/fftfilt.cxx` | `config.h` entfernt, `misc.h` → `misc_min.h`, Faktor K als Parameter |
| `src/misc_min.h` | Auszug aus `misc.h`, `modem.h`, `util.h` | nur `sinc`, `decayavg`, `TWOPI`, `SIGSEARCH`, `CLAMP` |
| `src/rtty_rx.h/.cpp` | `src/include/rtty.h`, `src/rtty/rtty.cxx` | nur Empfangsteil, siehe unten |
| `src/fldigi_rtty.cpp`, `include/fldigi_rtty.h` | – | neu: C-Schnittstelle für Swift |

## Abweichungen im Empfänger (im Code mit `ABWEICHUNG fldigi (Digidec)` markiert)

Maschinell geprüft (normalisierter Zeilenvergleich, 30.09.2026): `decode_char`, `is_mark_space`, `is_mark`, `mixer`
sind identisch; in `rx`, `Metric`, `baudot_dec` und der Schleife von `rx_process` unterscheiden sich nur die
folgenden Punkte.

1. **Einstellungen:** `progdefaults.*` / `progStatus.*` → `RTTYRxConfig` (Shift, Baud, Bits, Parität, Stoppbits,
   Reverse, AFC an/Tempo, Squelch an/Wert, CWI, Unshift-on-Space, ITA2, true_scope, Filter-K, Frequenzgrenzen, Kleinbuchstaben).
2. **Ausgabe:** `put_rx_char` → Rückruffunktion; `set_freq`/`put_freq` → Mittenfrequenz im Objekt (abfragbar).
3. **Signalmaß:** `wf->powerDensity()` (Leistung je 1-Hz-Pixel des fldigi-Wasserfalls: 8192er-FFT, Blackman,
   Pixel i = Bin round(i·8192/8000)) ist durch Goertzel-Filter auf genau diesen Bins über die letzten 8192 Samples
   ersetzt. Die Skalierung kürzt sich in `Metric()` heraus.
4. **Reverse:** fldigi berechnet `reverse = wf->Reverse() ^ !wf->USB()`; hier liefert die App den fertigen Wert.
5. **Entfallen:** Senden, FSK-Tastung, Synop-Decodierung, Mehrkanal-Viewer (`view_rtty`), Sync-Scope,
   `searchUp/Down`, Statuszeilen, Digiscope-Aufrufe (`set_zdata` → `get_scope()` liefert den QI-Puffer).
6. **static-Variablen:** `dspcnt` (global), `showxy`, `bitcount` (funktionslokal static) → Objektvariablen.
7. **Filterlänge:** fldigi nimmt `FILTLEN[]` per Tabellenindex der Baudrate; hier dieselbe Zuordnung über den Baudwert
   (Werte zwischen Tabellenstufen → nächstgrößere Stufe).
8. **Blockgröße:** Die C-Schnittstelle ruft `rx_process` wie fldigi in 512er-Blöcken auf (`SCBLOCKSIZE`).

## Befunde beim Herauslösen

- **Filter-Formfaktor:** Der Dialogwert „Filter Shape Factor“ (`progdefaults.rtty_filter`, Standard 1,25) wird in
  fldigi 4.2.13 **nirgends gelesen**; `fftfilt::rtty_filter` rechnet fest mit K = 1,4. Digidec übernimmt 1,4 als Standard.
- **Ziffernsatz:** fldigi verwendet standardmäßig den **US-TTY**-Ziffernsatz (`ITA2 = false`). ITA2 unterscheidet sich
  bei 5 Codes (u. a. `+` statt `"`, `=` statt `;`) – für europäische Aussendungen (DWD) ist ITA2 zu prüfen.
- **S/N-Anzeige:** fldigi misst das „Rauschen“ in einem Fenster (Baud/8 breit) genau zwischen Mark und Space und rechnet
  es auf 3 kHz hoch. Bei starken Signalen liegen dort Seitenbänder der Tastung; der Wert ist dann niedrig oder negativ.
  Ist dort fast keine Leistung, setzt fldigi `np = sp * 100`.
- **Squelch bei schmaler Shift:** Bei 85 Hz Shift (DWD LW) liegt das Messfenster im Signal; die Metrik erreicht
  bei sauberem Signal nur ≈ 30 (bei 170/450 Hz: 100). Squelch dort höchstens ≈ 20.
