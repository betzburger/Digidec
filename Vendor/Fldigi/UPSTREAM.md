# Vendor/Fldigi – Empfangsteile aus fldigi 4.2.13

Ein gemeinsames SwiftPM-Target `Fldigi` (seit 01.10.2026), weil die Modems gemeinsame Teile nutzen (FFT-Filter, Koordinaten, Tabellen-Lader).
Zwei getrennte Targets hätten doppelte Symbole ergeben.

| Ordner | Inhalt | Details |
|---|---|---|
| `include/` | C-Schnittstellen für Swift (`fldigi_rtty.h`, `fldigi_synop.h`) | |
| `src/common/` | `fftfilt`, `gfft.h`, `fldigi_complex.h` (= fldigi `complex.h`, umbenannt wegen Konflikt mit `<complex.h>` des Systems), `misc_min.h` | UPSTREAM_RTTY.md |
| `src/rtty/` | RTTY-Empfänger | UPSTREAM_RTTY.md |
| `src/synop/` | SYNOP/SHIP/BUOY-Decoder | UPSTREAM_SYNOP.md |
| `src/misc/` | re, strutil, coordinate, locator, record_loader (Ladeteil), field_def, Ersatzteile (KML/ADIF) | UPSTREAM_SYNOP.md |
| `src/compat/` | GNU-Regex (wie fldigi auf macOS) | UPSTREAM_SYNOP.md |
| `compat/` | Ersatz-Header für fldigi/FLTK/gettext | UPSTREAM_SYNOP.md |

Außerhalb von SwiftPM (Logiktests, `decode_file.sh`) übersetzt `Tools/build_fldigi.sh` dasselbe und legt die Modul-Map `Fldigi` an.
