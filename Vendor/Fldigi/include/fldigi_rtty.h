// ----------------------------------------------------------------------------
// fldigi_rtty.h  --  C-Schnittstelle zum RTTY-Empfänger aus fldigi 4.2.13 (für Swift)
//
// Digidec. Der Empfänger selbst (src/rtty_rx.*, src/fftfilt.*, src/gfft.h) stammt aus fldigi,
// GNU General Public License v3 bzw. LGPL v3 (gfft.h), siehe UPSTREAM.md.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_RTTY_H
#define FLDIGI_RTTY_H

#ifdef __cplusplus
extern "C" {
#endif

/// Abtastrate, die der Empfänger erwartet (fldigi RTTY_SampleRate)
#define FLDIGI_RTTY_SAMPLE_RATE 8000

typedef struct {
    double shift;          ///< Hz
    double baud;
    int    bits;           ///< 5 (Baudot/ITA2), 7, 8
    int    parity;         ///< 0 none, 1 even, 2 odd, 3 zero, 4 one
    double stop_bits;      ///< 1, 1.5, 2
    int    reverse;        ///< Mark/Space vertauscht (einschließlich Seitenband-Korrektur)
    int    afc_on;
    int    afc_speed;      ///< 0 slow, 1 normal, 2 fast
    int    squelch_on;
    double squelch;        ///< 0 … 100, verglichen mit `metric`
    int    cwi;            ///< 0 Mark-Space, 1 nur Mark, 2 nur Space
    int    uos_rx;         ///< Unshift on Space
    int    ita2;           ///< 1 = ITA2-Ziffernsatz, 0 = US-TTY
    int    true_scope;     ///< XY-Scope aus Mark/Space-Filtern
    double filter_k;       ///< Filter-Formfaktor (fldigi 4.2.13: 1.4)
    double low_cutoff;     ///< untere Grenze für die Mittenfrequenz (Hz)
    double high_cutoff;    ///< obere Grenze für die Mittenfrequenz (Hz)
} fldigi_rtty_config;

typedef struct {
    double center_hz;      ///< aktuelle Mittenfrequenz (ändert sich durch AFC)
    double metric;         ///< 0 … 100, Grundlage für Squelch (fldigi `metric`)
    double snr_db;         ///< Signal-Rausch-Abstand wie in fldigis Statuszeile
    double freq_error;     ///< geglätteter Frequenzfehler (Hz)
    double mark_mag;
    double space_mag;
} fldigi_rtty_status;

typedef void (*fldigi_rtty_char_fn)(void *ctx, int c);

typedef struct fldigi_rtty fldigi_rtty;

/// Standardwerte wie fldigi (170 Hz, 45,45 Bd, 5/1,5, AFC normal, UOS an, US-TTY, K = 1.4)
fldigi_rtty_config fldigi_rtty_default_config(void);

fldigi_rtty *fldigi_rtty_create(const fldigi_rtty_config *cfg, double center_hz,
                                fldigi_rtty_char_fn on_char, void *ctx);
void fldigi_rtty_destroy(fldigi_rtty *r);

/// Neue Einstellungen übernehmen (wie fldigi `restart()`); Mittenfrequenz bleibt.
void fldigi_rtty_configure(fldigi_rtty *r, const fldigi_rtty_config *cfg);

/// Samples mit 8000 Hz. Intern in 512er-Blöcke zerlegt wie fldigi (SCBLOCKSIZE).
/// `on_char` wird aus diesem Aufruf heraus aufgerufen.
void fldigi_rtty_process(fldigi_rtty *r, const float *samples, int count);

void fldigi_rtty_set_center(fldigi_rtty *r, double hz);
void fldigi_rtty_get_status(const fldigi_rtty *r, fldigi_rtty_status *out);

/// XY-Scope-Punkte (x, y abwechselnd), älteste zuerst; liefert die Anzahl Punkte (≤ max_points, ≤ 1024).
int fldigi_rtty_get_scope(const fldigi_rtty *r, double *xy, int max_points);

#ifdef __cplusplus
}
#endif

#endif
