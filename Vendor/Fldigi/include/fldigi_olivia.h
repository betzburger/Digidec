// ----------------------------------------------------------------------------
// fldigi_olivia.h  --  C-Schnittstelle zu Olivia und Contestia (fldigi 4.2.13, Pawel Jalocha SP9VRC) für Swift
//
// Digidec. Empfangslogik nach fldigi olivia.cxx / contestia.cxx, Bibliothek: src/olivia/jalocha (GPLv3).
// Alle Aufrufe vom selben Thread. Mehrere Exemplare gleichzeitig sind möglich.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_OLIVIA_H
#define FLDIGI_OLIVIA_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLDIGI_OLIVIA_SAMPLE_RATE 8000

typedef struct {
    int    contestia;      ///< 0 Olivia, 1 Contestia
    int    tones_exp;      ///< Töne = 2 · 2^n: 1 → 4 … 5 → 64 (fldigi „Tones“; Standard 2 = 8)
    int    bandwidth_exp;  ///< Bandbreite = 125 · 2^n Hz: 0 → 125 … 4 → 2000 (Standard 2 = 500)
    int    sync_margin;    ///< Suchbereich des Synchronisierers (8)
    int    sync_integ;     ///< Integrationsdauer des Synchronisierers (4)
    int    eight_bit;      ///< 8-Bit-Zeichen (127 als Fluchtzeichen, an)
    int    squelch_on;
    double squelch;        ///< 0 … 100; Schwelle S/N = squelch/5 + 3
    int    reverse;
} fldigi_olivia_config;

typedef struct {
    double center_hz;
    double metric;         ///< 0 … 100 (fldigi: 5 · (S/N − 3))
    double snr;            ///< S/N des Synchronisierers (linear, fldigi Rx->SignalToNoiseRatio)
    double freq_offset_hz; ///< gemessene Abweichung von der Mitte
    double bandwidth_hz;
    int    tones;
} fldigi_olivia_status;

typedef void (*fldigi_olivia_char_fn)(void *ctx, int c);
typedef struct fldigi_olivia fldigi_olivia;

fldigi_olivia_config fldigi_olivia_default_config(void);
fldigi_olivia *fldigi_olivia_create(const fldigi_olivia_config *cfg, double center_hz, fldigi_olivia_char_fn on_char, void *ctx);
void fldigi_olivia_destroy(fldigi_olivia *o);
/// Parameter geändert (Töne, Bandbreite, …): entspricht fldigis restart()
void fldigi_olivia_configure(fldigi_olivia *o, const fldigi_olivia_config *cfg);
void fldigi_olivia_process(fldigi_olivia *o, const float *samples, int count);
void fldigi_olivia_set_center(fldigi_olivia *o, double hz);
void fldigi_olivia_get_status(const fldigi_olivia *o, fldigi_olivia_status *out);
/// Am Ende einer Aufnahme: restliche Zeichen ausgeben (fldigi rx_flush)
void fldigi_olivia_flush(fldigi_olivia *o);

/// Testsignal (nur für Tests, Digidec sendet nie): Text als Olivia/Contestia-Aussendung (ohne Starttöne), Träger-Mitte `center_hz`,
/// 8000 Hz. Liefert die Zahl der Samples, < 0 wenn `max_samples` nicht reicht.
int fldigi_olivia_synthesize(const fldigi_olivia_config *cfg, const char *text, double center_hz, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
