// ----------------------------------------------------------------------------
// ft8_digidec.h  --  C-Schnittstelle zum FT8-Decoder ft8mon (Robert Morris AB1HL, MIT) für Swift
//
// Digidec. Ein Aufruf decodiert einen 15-s-Zyklus (mehrere Durchgänge mit Subtraktion, OSD, Hinweise auf CQ).
// Der Rückruf kommt aus Arbeits-Threads des Decoders (nacheinander, nie gleichzeitig).
// ----------------------------------------------------------------------------
#ifndef FT8_DIGIDEC_H
#define FT8_DIGIDEC_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char   text[48];      ///< Klartext wie WSJT-X, z. B. „CQ DL1ABC JN49“
    double snr_db;        ///< S/N in 2500 Hz (WSJT-X-Konvention)
    double dt;            ///< Zeitversatz gegen 0,5 s nach Zyklusbeginn
    double freq_hz;       ///< NF-Frequenz des untersten Tons
    int    correct_bits;  ///< Bits, die das LDPC/OSD korrigieren musste (hoch = unsicher)
    int    pass;          ///< Durchgang (nach Subtraktion stärkerer Signale > 0)
} ft8dd_decode;

typedef void (*ft8dd_decode_fn)(void *ctx, const ft8dd_decode *d);

/// samples: Zyklus ab Zyklusbeginn (0 s), beliebige Abtastrate (12 000 Hz empfohlen).
/// Rechenzeit höchstens `budget_s` Sekunden, `threads` Arbeits-Threads. Liefert die Zahl der Decodes.
int ft8dd_decode_cycle(const float *samples, int count, int rate, double min_hz, double max_hz,
                       double budget_s, int threads, ft8dd_decode_fn on_decode, void *ctx);

/// Testsignal (nur für Tests, Digidec sendet nie): FT8-Aussendung des Klartexts, unterster Ton bei f0,
/// Amplitude 1, 79 Symbole (12,64 s). Liefert die Zahl der Samples, < 0 bei Fehler (Text nicht kodierbar, Puffer zu klein).
int ft8dd_synthesize(const char *text, double f0, int rate, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
