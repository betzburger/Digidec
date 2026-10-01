// ----------------------------------------------------------------------------
// fldigi_psk.h  --  C-Schnittstelle zum PSK-Empfänger (BPSK/QPSK) aus fldigi 4.2.13 (für Swift)
//
// Digidec. Empfänger: src/psk/psk_rx.cpp (erzeugt von port_psk.py aus fldigi psk.cxx), GPLv3.
// Wegen fldigis file-static-Variablen nur EIN PSK-Decoder gleichzeitig. Alle Aufrufe vom selben Thread.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_PSK_H
#define FLDIGI_PSK_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLDIGI_PSK_SAMPLE_RATE 8000

enum {
    FLDIGI_PSK_BPSK31 = 0, FLDIGI_PSK_BPSK63, FLDIGI_PSK_BPSK125, FLDIGI_PSK_BPSK250,
    FLDIGI_PSK_QPSK31, FLDIGI_PSK_QPSK63, FLDIGI_PSK_QPSK125, FLDIGI_PSK_QPSK250
};

typedef struct {
    int    mode;          ///< FLDIGI_PSK_*
    int    afc;           ///< Frequenznachführung (progStatus.afconoff, an)
    int    squelch_on;    ///< Squelch (sqlonoff, an): ohne Squelch ist der Decoder immer „DCD“
    double squelch;       ///< 0 … 100 gegen `metric` (sldrSquelchValue, 5)
    int    reverse;       ///< QPSK: Seitenband umkehren (reverse)
} fldigi_psk_config;

typedef struct {
    double center_hz;     ///< Mittenfrequenz nach AFC
    double metric;        ///< 0 … 100 Signalqualität (fldigi „metric“)
    int    dcd;           ///< Träger erkannt, Zeichen werden ausgegeben
    double snr_db;        ///< 10 · log10(S/N-Verhältnis) aus den Goertzel-Filtern
    double imd_db;        ///< Intermodulation
    int    phase_quality; ///< 0 … 100 (Abweichung der Phase vom Idealwert)
    double bandwidth_hz;  ///< Symbolrate (31,25 / 62,5 / 125 / 250 Hz)
} fldigi_psk_status;

typedef void (*fldigi_psk_char_fn)(void *ctx, int c);

typedef struct fldigi_psk fldigi_psk;

fldigi_psk_config fldigi_psk_default_config(void);
fldigi_psk *fldigi_psk_create(const fldigi_psk_config *cfg, double center_hz, fldigi_psk_char_fn on_char, void *ctx);
void fldigi_psk_destroy(fldigi_psk *p);
void fldigi_psk_configure(fldigi_psk *p, const fldigi_psk_config *cfg);
void fldigi_psk_process(fldigi_psk *p, const float *samples, int count);
void fldigi_psk_set_center(fldigi_psk *p, double hz);
void fldigi_psk_get_status(const fldigi_psk *p, fldigi_psk_status *out);
/// Letzte Symbole des Phasenvektors (Digiscope): Phase (rad) und Betrag je Symbol; liefert die Anzahl (höchstens max_values)
int fldigi_psk_get_scope(const fldigi_psk *p, double *phase, double *amplitude, int max_values);

/// Testsignal (nur für Tests, Digidec sendet nie): Text als PSK-Aussendung wie fldigi (Vorspann aus Phasenumkehr,
/// Varicode, Nachspann), Träger bei `center_hz`, Amplitude 1, 8000 Hz. Liefert die Zahl der Samples, < 0 wenn `max_samples` nicht reicht.
int fldigi_psk_synthesize(int mode, const char *text, double center_hz, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
