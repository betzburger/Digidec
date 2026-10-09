# FldigiSynop – Herkunft und Abweichungen

SYNOP/SHIP/BUOY-Decoder aus fldigi (FM 12 SYNOP, FM 13 SHIP, FM 18 BUOY u. a.), herausgelöst ohne GUI, mit C-Schnittstelle.
Erkennt Wettermeldungen im RTTY-Text und gibt sie als Klartext aus („Temperature=20.2 °C“ …).

## Quelle

| | |
|---|---|
| Projekt / Stand | fldigi **v4.2.13**, Commit `e7c3ab3709ad62a7d91829364eb48a05fa325c0d` (wie `Vendor/Fldigi`) |
| Lizenz | GNU GPL v3 oder neuer; GNU-Regex (`src/compat/regex.*`) GPL; Hamlib-Locator (`locator.cpp`) LGPL |
| Stationslisten | `Resources/Synop/` = fldigi `data/` (nsd_bbsss.txt WMO-Stationen, station_table.txt NDBC-Bojen, ToR-Stats-SHIP.csv Schiffe, wmo_list.txt JCOMM). **Alter Stand** (Dateien aus fldigi, teils > 10 Jahre); neuere Bojen fehlen (z. B. 62170, 62198), Positionen stehen aber in den Meldungen selbst. |

## Dateien

| Digidec | fldigi 4.2.13 | Änderung |
|---|---|---|
| `src/synop.cpp` | `src/synop-src/synop.cxx` | 3 Stellen, siehe unten |
| `src/synop.h`, `re.h`, `strutil.h`, `coordinate.h`, `locator.h`, `field_def.h`, `record_loader.h` | `src/include/…` | unverändert |
| `src/re.cpp`, `src/strutil.cpp` | `src/misc/re.cxx`, `strutil.cxx` | + `#include "digidec_compat.h"` |
| `src/coordinate.cpp` | `src/misc/coordinate.cxx` | unverändert |
| `src/locator.cpp` | `src/misc/locator.cxx` (nicht `locator.c`!) | + `#include "digidec_compat.h"` |
| `src/record_loader.cpp` | `src/misc/record_loader.cxx` | nur Ladeteil (ohne FLTK-Dialog, Download, Verwaltungsliste); Dateien aus `SetDataDir` |
| `src/compat/regex.c/.h` | `src/compat/regex.*` | + `#undef DEBUG` (SwiftPM setzt DEBUG) |
| `src/compat_stubs.cpp` | – | Null-KML-Server, leerer ADIF-QsoHelper, `KmlServer::Tm2Time` (1:1 aus `src/kml/kmlserver.cxx`) |
| `compat/*.h` | – | Ersatz für config.h, gettext.h (Texte englisch), debug.h (Protokoll aus), configuration.h, fl_digi.h (`MODE_RTTY`), FL/fl_ask.H, kmlserver.h (Kopie) |
| `src/fldigi_synop.cpp`, `include/fldigi_synop.h` | – | C-Schnittstelle; Einspeisung wie fldigi `rtty::rx()` |

**GNU-Regex:** fldigi verwendet auf macOS die mitgelieferte GNU-Regex (`m4/macosx.m4`), nicht die des Systems.
Digidec tut das auch, damit die rund 100 SYNOP-Muster exakt gleich greifen.

## Abweichungen in `synop.cpp` (markiert mit `ABWEICHUNG fldigi (Digidec)`)

1. `SynopDB::Init(data_dir)`: setzt das Verzeichnis der Stationslisten. fldigi ignoriert den Parameter und sucht in seinem Datenordner.
2. **Fehler in fldigi behoben:** `AddOtherTok()` → `CtxtDerived::Mtch()` liest beim ersten Aufruf `m_bstStartToken[m_currSection]`
   mit `m_currSection = -1`, also außerhalb des Arrays. Das ist undefiniertes Verhalten und führt hier zum Absturz.
   Jetzt wird ohne gesetzten Abschnitt nicht nach Priorität gefiltert.
3. **Fehler in fldigi behoben:** `DayHourMin2Tm()` rechnet die UTC-Felder mit `mktime()` um, das sie als Ortszeit deutet. In MESZ wurde so aus 18 UTC „17:00“.
   Jetzt `timegm()`.

## Verhalten (wie fldigi)

- „Interleaved“: Der Rohtext läuft unverändert durch. Nach jeder erkannten Meldung folgt ein Klartextblock (fldigi fett, Digidec amber).
- `;` wird als `=` (Meldungsende) behandelt, weil der US-TTY-Ziffernsatz `=` als `;` liefert.
- Ausgabe **englisch**. fldigi hat keine Übersetzung der 731 SYNOP-Texte.
