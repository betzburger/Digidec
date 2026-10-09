// ----------------------------------------------------------------------------
// fldigi_mt63.h  --  C-Schnittstelle zum MT63-Empfänger (fldigi 4.2.13, Pawel Jalocha SP9VRC) für Swift
//
// Digidec. Empfangslogik nach fldigi mt63.cxx, Bibliothek: src/mt63/dsp.cpp, mt63base.cpp (GPLv3).
// Alle Aufrufe vom selben Thread. Mehrere Exemplare gleichzeitig sind möglich.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_MT63_H
#define FLDIGI_MT63_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLDIGI_MT63_SAMPLE_RATE 8000

typedef struct {
    int    bandwidth_hz;     ///< 500, 1000 oder 2000
    int    long_interleave;  ///< 0 kurz (32), 1 lang (64)
    int    long_integration; ///< lange Empfangsintegration (fldigi mt63_rx_integration, aus)
    int    eight_bit;        ///< 8-Bit-Zeichen (an)
    int    squelch_on;
    double squelch;          ///< gegen das S/N am FEC (fldigi sldrSquelchValue, 5)
} fldigi_mt63_config;

typedef struct {
    double center_hz;
    double snr;              ///< S/N am FEC (linear, höchstens 99,9)
    double freq_offset_hz;
    int    locked;           ///< Synchronisierer eingerastet
    double confidence;       ///< 0 … 1
    double bandwidth_hz;
} fldigi_mt63_status;

typedef void (*fldigi_mt63_char_fn)(void *ctx, int c);
typedef struct fldigi_mt63 fldigi_mt63;

fldigi_mt63_config fldigi_mt63_default_config(void);
fldigi_mt63 *fldigi_mt63_create(const fldigi_mt63_config *cfg, double center_hz, fldigi_mt63_char_fn on_char, void *ctx);
void fldigi_mt63_destroy(fldigi_mt63 *m);
void fldigi_mt63_configure(fldigi_mt63 *m, const fldigi_mt63_config *cfg);
void fldigi_mt63_process(fldigi_mt63 *m, const float *samples, int count);
void fldigi_mt63_set_center(fldigi_mt63 *m, double hz);
void fldigi_mt63_get_status(const fldigi_mt63 *m, fldigi_mt63_status *out);
/// Am Ende einer Aufnahme: restliche Zeichen ausgeben (fldigi rx_flush)
void fldigi_mt63_flush(fldigi_mt63 *m);

/// Testsignal (nur für Tests, Digidec sendet nie): Text als MT63-Aussendung, Mitte `center_hz`, 8000 Hz.
int fldigi_mt63_synthesize(const fldigi_mt63_config *cfg, const char *text, double center_hz, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
