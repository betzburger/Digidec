// ----------------------------------------------------------------------------
// wspr_digidec.h  --  C-Schnittstelle zum WSPR-Decoder wsprd (WSJT-X, K1JT/K9AN, GPLv3) für Swift
//
// Digidec. Ein Aufruf decodiert eine 2-Minuten-Aufnahme (WSPR-2, 162 Symbole, 4-FSK 1,4648 Baud).
// Die Rückrufe kommen nacheinander aus dem aufrufenden Thread. Aufrufe sind gegeneinander gesperrt.
// ----------------------------------------------------------------------------
#ifndef WSPR_DIGIDEC_H
#define WSPR_DIGIDEC_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char   message[24];   ///< wie wsprd: „DL1ABC JO30 37“ (Typ 1), „PJ4/K1ABC 37“ (Typ 2), „<DL1ABC> JO30 37“ (Typ 3)
    float  snr_db;        ///< S/N in 2500 Hz (wsprd-Konvention)
    float  dt;            ///< Zeitversatz in s gegen 1 s nach Zyklusbeginn
    double freq_hz;       ///< NF-Frequenz der Mitte des 4-FSK-Signals (1500 + Versatz)
    float  drift;         ///< Drift in Hz/Minute
    float  sync;          ///< Sync-Güte 0 … 1
    int    pass;          ///< Durchgang (1…3, nach Subtraktion stärkerer Signale > 1)
    int    cycles;        ///< Rechenschritte des Fano-Decoders
} wsprdd_decode;

typedef void (*wsprdd_decode_fn)(void *ctx, const wsprdd_decode *d);

/// samples: Aufnahme ab Zyklusbeginn (gerade UTC-Minute), 12 000 Hz, mindestens ≈ 110 s (114 s werden benutzt).
/// wide: ± 150 Hz statt ± 110 Hz um 1500 Hz. deep: mehr Kandidaten (langsamer). Liefert die Zahl der Decodes, < 0 bei Fehler.
int wsprdd_decode_slot(const float *samples, int count, int wide, int deep, wsprdd_decode_fn on_decode, void *ctx);

/// Hashtabelle für Typ-3-Meldungen (Rufzeichen mit Zusatz, die nur als Hash gesendet werden): lesen / schreiben
/// (Textdatei im Format von wsprd, `hashtable.txt`). Liefert 0 bei Erfolg.
int wsprdd_hash_load(const char *path);
int wsprdd_hash_save(const char *path);

/// Testsignal (nur für Tests, Digidec sendet nie): Meldung „CALL GRID DBM“ als 4-FSK, Mitte des Signals bei f0
/// (Hz, nominal 1500), Beginn `start_s` Sekunden nach Zyklusbeginn (nominal 1,0), Amplitude 1.
/// `out` wird mit 120 s · 12 000 Hz Nullen vorbelegt und überschrieben; max_samples muss 1 440 000 fassen.
/// Liefert die Zahl der Samples (1 440 000), < 0 bei Fehler (Meldung nicht kodierbar).
int wsprdd_synthesize(const char *message, double f0, double start_s, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
