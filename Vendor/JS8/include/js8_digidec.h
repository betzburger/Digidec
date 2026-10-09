// ----------------------------------------------------------------------------
// js8_digidec.h  --  C-Schnittstelle zum JS8-Decoder aus JS8Call (GPLv3) für Swift
//
// Digidec. Ein Aufruf decodiert ein Fenster Audio einer Betriebsart (Normal, Fast, Turbo, Slow, Ultra) mit bis zu drei
// Durchgängen und Subtraktion. Geliefert werden die rohen Rahmen (12 Zeichen + 3 Bit Rahmenart); das Auspacken zu Text
// (Varicode, JSC) macht Swift. Der Rückruf kommt im Thread des Aufrufers. Pro Betriebsart läuft immer nur ein Aufruf.
// ----------------------------------------------------------------------------
#ifndef JS8_DIGIDEC_H
#define JS8_DIGIDEC_H

#ifdef __cplusplus
extern "C" {
#endif

/// Betriebsarten (Werte wie in JS8Call, Bitmaske)
enum {
    JS8DD_NORMAL = 0,   ///< 15 s, 6,25 Baud, 50 Hz
    JS8DD_FAST   = 1,   ///< 10 s, 10 Baud, 80 Hz
    JS8DD_TURBO  = 2,   ///< 6 s, 20 Baud, 160 Hz
    JS8DD_SLOW   = 4,   ///< 30 s, 3,125 Baud, 25 Hz
    JS8DD_ULTRA  = 8    ///< 4 s, 31,25 Baud, 250 Hz (in JS8Call ausgeschaltet)
};

typedef struct {
    char  data[13];     ///< 12 Zeichen aus „0-9A-Za-z-+“, NUL-terminiert
    int   frame_type;   ///< 3 Bit: 0 weiter, 1 erster, 2 letzter, 4 Daten (Bits der Übertragungsart)
    int   snr;          ///< dB in 2500 Hz (JS8Call-Konvention)
    float dt;           ///< Zeitversatz in s gegen den nominellen Beginn (Verzögerung der Betriebsart abgezogen)
    float freq_hz;      ///< NF-Frequenz des untersten Tons
    float quality;      ///< 0…1 (1 − Bitfehler/60)
    int   submode;      ///< JS8DD_*
} js8dd_decode;

typedef void (*js8dd_decode_fn)(void *ctx, const js8dd_decode *d);

/// samples: 12 000 Hz, Skala wie 16-Bit-Zahlen (±32768); das Fenster beginnt bei Zyklusbeginn (0 s).
/// Betriebsart `submode`; Suchbereich nfa…nfb in Hz, bevorzugt um nfqso. Liefert die Zahl der verschiedenen Decodes, < 0 bei Fehler.
int js8dd_decode_window(const float *samples, int count, int submode, int nfa, int nfb, int nfqso,
                        js8dd_decode_fn on_decode, void *ctx);

/// Länge des Zyklus in Sekunden, Symbolabtastwerte, Verzögerung des Beginns in ms; 0 bei unbekannter Betriebsart.
int js8dd_period_seconds(int submode);
int js8dd_symbol_samples(int submode);
int js8dd_start_delay_ms(int submode);

/// Rahmen in 79 Töne (0…7) umsetzen (nur für Tests und die Gegenprobe; Digidec sendet nie).
/// data: genau 12 Zeichen. Liefert 0, bei ungültigem Zeichen oder falscher Länge −1.
int js8dd_encode(int frame_type, int submode, const char *data, int *tones79);

/// Testsignal: Rahmen als reelles 8-FSK bei 12 kHz, unterster Ton bei f0, Amplitude `amp` in Einheiten der Ausgabe (Swift nimmt 1 = Vollaussteuerung),
/// beginnend mit der Startverzögerung der Betriebsart. Liefert die Zahl der Samples, < 0 bei Fehler.
int js8dd_synthesize(int frame_type, int submode, const char *data, double f0, double amp, float *out, int max_samples);

#ifdef __cplusplus
}
#endif

#endif
