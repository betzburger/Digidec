// ----------------------------------------------------------------------------
// fldigi_hell.h  --  C-Schnittstelle zu Feld Hell und Verwandten (fldigi 4.2.13, Dave Freese W1HKJ) für Swift
//
// Digidec. Empfänger: src/mfsk/feld_rx.cpp (erzeugt von port_mfsk.py aus fldigi feld.cxx), GPLv3.
// Feld Hell liefert keine Zeichen, sondern Rasterspalten: jede Spalte besteht aus 2 · Spaltenlänge Werten (0 = schwarz …
// 255 = weiß; vorherige und aktuelle Spalte, damit man den Zeilenanfang erkennt). Alle Aufrufe vom selben Thread.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_HELL_H
#define FLDIGI_HELL_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLDIGI_HELL_SAMPLE_RATE 8000

enum {
    FLDIGI_HELL_FELD = 0, FLDIGI_HELL_SLOW, FLDIGI_HELL_X5, FLDIGI_HELL_X9,
    FLDIGI_HELL_FSKH245, FLDIGI_HELL_FSKH105, FLDIGI_HELL_80,
    FLDIGI_HELL_MODE_COUNT
};

typedef struct {
    int    mode;          ///< FLDIGI_HELL_*
    int    squelch_on;    ///< Squelch (sqlonoff, an)
    double squelch;       ///< 0 … 100 gegen `metric` (sldrSquelchValue, 5)
    int    reverse;       ///< nur FSK-Hell: Töne vertauschen
    int    blackboard;    ///< Umkehrdarstellung (weiße Schrift)
    int    column_height; ///< Spaltenlänge in Pixeln (HellRcvHeight, 20; höchstens 42)
    int    column_repeat; ///< jede Spalte so oft ausgeben (HellRcvWidth, 2)
    int    agc;           ///< 1 langsam, 2 mittel, 3 schnell (hellagc, 2)
    double filter_hz;     ///< Filterbreite; ≤ 0 = Vorgabe der Betriebsart
} fldigi_hell_config;

typedef struct {
    double center_hz;
    double metric;        ///< 0 … 100
    double bandwidth_hz;
    double filter_hz;
    int    column_height;
} fldigi_hell_status;

typedef void (*fldigi_hell_column_fn)(void *ctx, const int *data, int length);
typedef struct fldigi_hell fldigi_hell;

fldigi_hell_config fldigi_hell_default_config(void);
fldigi_hell *fldigi_hell_create(const fldigi_hell_config *cfg, double center_hz, fldigi_hell_column_fn on_column, void *ctx);
void fldigi_hell_destroy(fldigi_hell *h);
void fldigi_hell_configure(fldigi_hell *h, const fldigi_hell_config *cfg);
void fldigi_hell_process(fldigi_hell *h, const float *samples, int count);
void fldigi_hell_set_center(fldigi_hell *h, double hz);
void fldigi_hell_get_status(const fldigi_hell *h, fldigi_hell_status *out);

/// Testsignal (nur für Tests, Digidec sendet nie): Text als Hell-Aussendung wie fldigi (Punkte, Text, Punkte), Mitte `center_hz`,
/// 8000 Hz. Liefert die Zahl der Samples, < 0 wenn `max_samples` nicht reicht.
int fldigi_hell_synthesize(int mode, const char *text, double center_hz, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
