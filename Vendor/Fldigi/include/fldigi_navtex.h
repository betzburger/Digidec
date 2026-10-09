// ----------------------------------------------------------------------------
// fldigi_navtex.h  --  C-Schnittstelle zum NAVTEX/SITOR-B-Empfänger aus fldigi 4.2.13 (für Swift)
//
// Digidec. Der Empfänger (src/navtex/navtex_rx.cpp) stammt aus fldigi (F4ECW, AB1KW, nach JNX von Paul Lutus),
// GNU GPL v3, siehe UPSTREAM_NAVTEX.md. Alle Aufrufe je Instanz vom selben Thread.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_NAVTEX_H
#define FLDIGI_NAVTEX_H

#ifdef __cplusplus
extern "C" {
#endif

/// Abtastrate, die der Empfänger erwartet (fldigi navtex: modem::samplerate = 11025)
#define FLDIGI_NAVTEX_SAMPLE_RATE 11025

typedef struct {
    int    sitor_b_only;   ///< 1 = reines SITOR-B (ohne ZCZC/NNNN-Nachrichten), 0 = NAVTEX
    int    reverse;        ///< Mark/Space vertauscht (fldigi: wf->Reverse() ^ !wf->USB())
    int    afc_on;         ///< progStatus.afconoff
    int    ita2;           ///< ITA2- statt US-TTY-Ziffernsatz (progdefaults.ITA2)
    int    min_message_length; ///< progdefaults.NVTX_MinSizLoggedMsg (Standard 0)
} fldigi_navtex_config;

typedef struct {
    double center_hz;      ///< Mittenfrequenz (AFC kann sie verschieben)
    double metric;         ///< 0 … 100 wie fldigi (Squelch-Maß)
    double snr_db;         ///< „s/n“ wie in fldigis Statuszeile
    int    state;          ///< 0 SYNC_SETUP, 1 SYNC, 2 READ_DATA
} fldigi_navtex_status;

/// Laufender Text (wie put_rx_char)
typedef void (*fldigi_navtex_char_fn)(void *ctx, int c);
/// Vollständige Nachricht (wie put_received_message): Text mit eventuellen Markierungen „[Lost header]:“ usw.,
/// Kopf-Kennungen aus „ZCZC B1B2B3B4“ (origin = Station, subject = Art, number) – '?'/0, wenn ohne Kopf.
typedef void (*fldigi_navtex_message_fn)(void *ctx, const char *text, char origin, char subject, int number,
                                         const char *subject_text);

typedef struct fldigi_navtex fldigi_navtex;

fldigi_navtex_config fldigi_navtex_default_config(void);

fldigi_navtex *fldigi_navtex_create(const fldigi_navtex_config *cfg, double center_hz,
                                    fldigi_navtex_char_fn on_char, fldigi_navtex_message_fn on_message, void *ctx);
void fldigi_navtex_destroy(fldigi_navtex *n);
void fldigi_navtex_configure(fldigi_navtex *n, const fldigi_navtex_config *cfg);

/// Samples mit 11025 Hz, intern in 512er-Blöcken wie fldigi (SCBLOCKSIZE)
void fldigi_navtex_process(fldigi_navtex *n, const float *samples, int count);
void fldigi_navtex_set_center(fldigi_navtex *n, double hz);
void fldigi_navtex_get_status(const fldigi_navtex *n, fldigi_navtex_status *out);

/// Stationsliste NAVTEX_Stations.csv laden (Verzeichnis mit abschließendem „/“); 1 bei Erfolg
int fldigi_navtex_load_stations(const char *data_dir);

/// Station zu einer Kennung suchen wie fldigi NavtexCatalog::FindStation (Kennbuchstabe, Frequenz,
/// eigener Locator, Nachrichtentext für den Namensvergleich). Ergebnis in `out` als
/// „Name;Rufzeichen;Land;Breite;Länge“ (Grad, Süd/West negativ); 0 = nicht gefunden.
int fldigi_navtex_find_station(char origin, double frequency_hz, const char *locator, const char *message,
                               char *out, int out_size);

/// Testsignal wie fldigis NAVTEX-Sender: Text → 7-Bit-CCIR-476-Codes mit FEC-Verschachtelung
/// (rep/alpha). Liefert die Anzahl Codes in `codes` (höchstens `max_codes`).
int fldigi_navtex_encode(const char *text, int ita2, unsigned char *codes, int max_codes);

#ifdef __cplusplus
}
#endif

#endif
