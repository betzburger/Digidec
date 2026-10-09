// ----------------------------------------------------------------------------
// fldigi_cw.h  --  C-Schnittstelle zum CW-Empfänger aus fldigi 4.2.13 (für Swift)
//
// Digidec. Empfänger: src/cw/cw_rx.cpp (erzeugt von port_cw.py aus fldigi cw.cxx), GPLv3.
// Wegen fldigis file-static-Variablen nur EIN CW-Decoder gleichzeitig. Alle Aufrufe vom selben Thread.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_CW_H
#define FLDIGI_CW_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLDIGI_CW_SAMPLE_RATE 8000

typedef struct {
    int    speed_wpm;      ///< Startgeschwindigkeit / Mitte des Nachführbereichs (CWspeed, 18)
    int    bandwidth_hz;   ///< FIR-Bandpass (CWbandwidth, 150)
    int    matched_filter; ///< Bandbreite = 2 × WpM (CWmfilt, aus)
    int    filter_length;  ///< 0:128 1:256 2:512 3:1024 Taps (CW_fillen, 2)
    int    track;          ///< Geschwindigkeit nachführen (CWtrack, an)
    int    range_wpm;      ///< Nachführbereich ± WpM (CWrange, 10)
    int    lower_wpm;      ///< untere Grenze (CWlowerlimit, 5)
    int    upper_wpm;      ///< obere Grenze (CWupperlimit, 50)
    int    attack;         ///< 0 langsam, 1 mittel, 2 schnell (cwrx_attack)
    int    decay;          ///< (cwrx_decay)
    int    som_decoding;   ///< SOM-Mustererkennung (CWuseSOMdecoding, aus)
    int    squelch_on;
    double squelch;        ///< 0 … 100 gegen `metric`
    char   noise_char;     ///< Ersatz für nicht erkannte Zeichen ('*')
} fldigi_cw_config;

typedef struct {
    double center_hz;
    double metric;         ///< 0 … 100 (fldigi: 2,5 × S/N in dB, geglättet)
    double rx_wpm;         ///< erkannte Geschwindigkeit
    double level;          ///< normierter Signalpegel (Schwellenmitte)
} fldigi_cw_status;

/// Zeichen oder Prosign („<BT>“, is_prosign = 1)
typedef void (*fldigi_cw_char_fn)(void *ctx, const char *text, int is_prosign);

typedef struct fldigi_cw fldigi_cw;

fldigi_cw_config fldigi_cw_default_config(void);
fldigi_cw *fldigi_cw_create(const fldigi_cw_config *cfg, double center_hz, fldigi_cw_char_fn on_char, void *ctx);
void fldigi_cw_destroy(fldigi_cw *c);
void fldigi_cw_configure(fldigi_cw *c, const fldigi_cw_config *cfg);
void fldigi_cw_process(fldigi_cw *c, const float *samples, int count);
void fldigi_cw_set_center(fldigi_cw *c, double hz);
void fldigi_cw_get_status(const fldigi_cw *c, fldigi_cw_status *out);
/// Hüllkurve der letzten Zeichen (Digiscope), 0 … 1; liefert die Anzahl Werte
int fldigi_cw_get_scope(const fldigi_cw *c, double *values, int max_values);

#ifdef __cplusplus
}
#endif

#endif
