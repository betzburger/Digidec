// ----------------------------------------------------------------------------
// fldigi_mfsk.h  --  C-Schnittstelle zu MFSK, DominoEX und Thor (fldigi 4.2.13, Dave Freese W1HKJ) für Swift
//
// Digidec. Empfänger: src/mfsk/{mfsk,dominoex,thor}_rx.cpp (erzeugt von port_mfsk.py aus fldigi mfsk.cxx, dominoex.cxx,
// thor.cxx), GPLv3. Alle Aufrufe vom selben Thread. Mehrere MFSK-Exemplare gleichzeitig sind möglich; DominoEX und Thor
// haben (wie in fldigi) etwas gemeinsamen Zustand: nur je ein Decoder gleichzeitig.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_MFSK_H
#define FLDIGI_MFSK_H

#ifdef __cplusplus
extern "C" {
#endif

enum {
    FLDIGI_MFSK4 = 0, FLDIGI_MFSK8, FLDIGI_MFSK11, FLDIGI_MFSK16, FLDIGI_MFSK22,
    FLDIGI_MFSK31, FLDIGI_MFSK32, FLDIGI_MFSK64, FLDIGI_MFSK128, FLDIGI_MFSK64L, FLDIGI_MFSK128L,
    FLDIGI_MFSK_MODE_COUNT,
    FLDIGI_DOMINOEXMICRO = 16, FLDIGI_DOMINOEX4, FLDIGI_DOMINOEX5, FLDIGI_DOMINOEX8, FLDIGI_DOMINOEX11,
    FLDIGI_DOMINOEX16, FLDIGI_DOMINOEX22, FLDIGI_DOMINOEX44, FLDIGI_DOMINOEX88,
    FLDIGI_THORMICRO = 32, FLDIGI_THOR4, FLDIGI_THOR5, FLDIGI_THOR8, FLDIGI_THOR11, FLDIGI_THOR16, FLDIGI_THOR22,
    FLDIGI_THOR25, FLDIGI_THOR32, FLDIGI_THOR44, FLDIGI_THOR56, FLDIGI_THOR100, FLDIGI_THOR25X4, FLDIGI_THOR50X1,
    FLDIGI_THOR50X2
};

typedef struct {
    int    mode;          ///< FLDIGI_MFSK*, FLDIGI_DOMINOEX*, FLDIGI_THOR*
    int    afc;           ///< Frequenznachführung (progStatus.afconoff, an; nur MFSK)
    int    fec;           ///< DominoEX: MultiPsk-FEC (progdefaults.DOMINOEX_FEC, aus)
    int    squelch_on;    ///< Squelch (sqlonoff, an)
    double squelch;       ///< 0 … 100 gegen `metric` (sldrSquelchValue, 5)
    int    reverse;       ///< Seitenband umkehren
} fldigi_mfsk_config;

typedef struct {
    double center_hz;     ///< Mittenfrequenz nach AFC (Mitte des Tonfeldes)
    double metric;        ///< 0 … 100 Signalqualität des Viterbi-Decoders
    double bandwidth_hz;  ///< Breite des Tonfeldes
    double sample_rate;   ///< 8000 oder 11025 Hz: so muss das Audio kommen
    int    tones;
} fldigi_mfsk_status;

typedef void (*fldigi_mfsk_char_fn)(void *ctx, int c);
typedef struct fldigi_mfsk fldigi_mfsk;

/// Abtastrate, mit der die Betriebsart arbeitet (8000; 11025 bei MFSK11/22, DominoEX 5/11/22/44/88, Thor 5/11/22/44; Thor56: 16000)
double fldigi_mfsk_sample_rate(int mode);
fldigi_mfsk_config fldigi_mfsk_default_config(void);
fldigi_mfsk *fldigi_mfsk_create(const fldigi_mfsk_config *cfg, double center_hz, fldigi_mfsk_char_fn on_char, void *ctx);
void fldigi_mfsk_destroy(fldigi_mfsk *m);
void fldigi_mfsk_configure(fldigi_mfsk *m, const fldigi_mfsk_config *cfg);
void fldigi_mfsk_process(fldigi_mfsk *m, const float *samples, int count);
void fldigi_mfsk_set_center(fldigi_mfsk *m, double hz);
void fldigi_mfsk_get_status(const fldigi_mfsk *m, fldigi_mfsk_status *out);

/// Testsignal (nur für Tests, Digidec sendet nie): Text als Aussendung wie fldigi (Vorspann, STX, Text, EOT, Nachspann),
/// Mitte `center_hz`, Abtastrate der Betriebsart. Liefert die Zahl der Samples, < 0 wenn `max_samples` nicht reicht.
int fldigi_mfsk_synthesize(int mode, const char *text, double center_hz, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
