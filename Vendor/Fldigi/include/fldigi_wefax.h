// ----------------------------------------------------------------------------
// fldigi_wefax.h  --  C-Schnittstelle zum WEFAX-Empfänger aus fldigi 4.2.13 (für Swift)
//
// Digidec. Empfänger: src/wefax/wefax_rx.cpp (erzeugt von port_wefax.py aus fldigi wefax.cxx), GPLv3.
// Alle Aufrufe eines Decoders vom selben Thread. fldigis Hub (fm_deviation) ist dateiweit: ein Decoder gleichzeitig.
// ----------------------------------------------------------------------------
#ifndef FLDIGI_WEFAX_H
#define FLDIGI_WEFAX_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLDIGI_WEFAX_SAMPLE_RATE 11025

typedef struct {
    int    ioc;              ///< 576 (Standard) oder 288
    int    lpm;              ///< Zeilen je Minute: 240, 120 (Standard), 90, 60
    int    shift_hz;         ///< Hub (fldigi 800; DWD 850)
    int    center_hz;        ///< NF-Mitte (fldigi 1900)
    int    filter;           ///< 0 schmal, 1 mittel, 2 breit
    int    afc;
    int    auto_center;      ///< Bild automatisch horizontal ausrichten
    int    noise_removal;
    int    max_rows;         ///< fldigi 4000
    double correlation;      ///< Schwelle Zeilenkorrelation (0,05)
    int    correlation_rows; ///< (15)
    double slant;            ///< Schräglauf-Korrektur in % (0)
} fldigi_wefax_config;

/// Zustände wie fldigi fax_state
enum { FLDIGI_WEFAX_APT_START = 0, FLDIGI_WEFAX_APT_STOP = 1, FLDIGI_WEFAX_PHASING = 2, FLDIGI_WEFAX_IMAGE = 3,
       FLDIGI_WEFAX_IDLE = 10 };

typedef struct {
    double   center_hz;
    double   metric;       ///< Zeilenkorrelation × 100
    double   snr_db;       ///< Bildträger zu Rauschen (fldigi „s/n“)
    int      state;
    double   lpm;
    int      width;        ///< Pixel je Zeile (IOC · π)
    int      rows;         ///< empfangene Zeilen des aktuellen Bilds
    int      manual;
    unsigned revision;     ///< ändert sich, sobald sich das Bild ändert
} fldigi_wefax_status;

/// Bild fertig (fldigi save_automatic / Knopf Speichern): Name wie fldigi, Kommentare, Graustufen Zeile für Zeile
typedef void (*fldigi_wefax_saved_fn)(void *ctx, const char *name, const char *comments,
                                      const unsigned char *gray, int width, int height);

typedef struct fldigi_wefax fldigi_wefax;

fldigi_wefax_config fldigi_wefax_default_config(void);
/// IOC und Hub gelten ab dem Anlegen; bei Änderung neu anlegen
fldigi_wefax *fldigi_wefax_create(const fldigi_wefax_config *cfg, fldigi_wefax_saved_fn on_saved, void *ctx);
void fldigi_wefax_destroy(fldigi_wefax *w);
/// Änderbar im Betrieb: LPM, Mitte, Filter, AFC, Auto-Zentrierung, Rauschentfernung, Grenzen, Schräglauf
void fldigi_wefax_configure(fldigi_wefax *w, const fldigi_wefax_config *cfg);
void fldigi_wefax_process(fldigi_wefax *w, const float *samples, int count);
void fldigi_wefax_set_rf(fldigi_wefax *w, long long rf_hz);
void fldigi_wefax_get_status(const fldigi_wefax *w, fldigi_wefax_status *out);
/// Graustufen des aktuellen Bilds (Breite × Zeilen); liefert die Zeilenzahl
int  fldigi_wefax_copy_image(const fldigi_wefax *w, unsigned char *gray, int max_bytes);

// Knöpfe wie in fldigis Empfangsfenster
void fldigi_wefax_skip_apt(fldigi_wefax *w);
void fldigi_wefax_skip_phasing(fldigi_wefax *w);
void fldigi_wefax_abort(fldigi_wefax *w);
void fldigi_wefax_set_manual(fldigi_wefax *w, int manual);   ///< „Non-Stop“: ohne APT/Phasing durchgehend
void fldigi_wefax_save(fldigi_wefax *w);

#ifdef __cplusplus
}
#endif

#endif
