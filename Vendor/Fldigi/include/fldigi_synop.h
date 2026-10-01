// ----------------------------------------------------------------------------
// fldigi_synop.h  --  C-Schnittstelle zum SYNOP/SHIP/BUOY-Decoder aus fldigi 4.2.13 (für Swift)
//
// Digidec. Der Decoder (src/synop.cpp u. a.) stammt aus fldigi, GNU GPL v3; GNU-Regex (src/compat) GPL.
// Es gibt nur eine Instanz (fldigi: synop::instance()); alle Aufrufe vom selben Thread.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_SYNOP_H
#define FLDIGI_SYNOP_H

#ifdef __cplusplus
extern "C" {
#endif

/// Ausgabe: Rohtext (`decoded` = 0) und Klartext der erkannten Meldungen (`decoded` = 1)
typedef void (*fldigi_synop_print_fn)(void *ctx, const char *text, int length, int decoded);

/// Stationslisten laden (nsd_bbsss.txt, station_table.txt, ToR-Stats-SHIP.csv, wmo_list.txt aus `data_dir`).
/// Liefert 1 bei Erfolg. Ohne Listen decodiert der Decoder trotzdem, nur ohne Stationsnamen.
int fldigi_synop_load_stations(const char *data_dir);

/// Ausgabeziel setzen. `interleaved` = 1: Rohtext läuft sofort durch, Klartext folgt je Meldung (fldigi-Standard).
void fldigi_synop_set_output(fldigi_synop_print_fn fn, void *ctx, int interleaved);

/// Ein decodiertes RTTY-Zeichen übergeben – genau wie fldigi rtty::rx() es tut (CR und NUL beenden den Block).
void fldigi_synop_feed(char c);

/// Angefangene Meldung ausgeben und Zustand leeren (z. B. beim Ausschalten)
void fldigi_synop_flush(void);

/// Name einer WMO-Station („Wuerzburg“) – für Tests; leer, wenn unbekannt
const char *fldigi_synop_station_name(int wmo_indicator);

#ifdef __cplusplus
}
#endif

#endif
