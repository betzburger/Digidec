// ----------------------------------------------------------------------------
// wefax_rx.h  --  Digidec: Rahmen für den WEFAX-Empfänger aus fldigi 4.2.13 (src/wefax/wefax.cxx)
//
// Ersetzt, was fldigis fax_implementation von außen braucht:
//   - Modem-Klasse `wefax`            → Klasse `wefax` hier (Einstellungen, Status, Rückruf „Bild fertig“)
//   - Wasserfall `wf` (WFdisp)         → WefaxWaterfall: powerDensity / powerDensityMaximum / rfcarrier
//   - Bildfenster `wefax_pic`/`wefax_map` (FLTK) → WefaxImage: Bildpuffer, Zentrierung, Rauschentfernung
//   - progdefaults / progStatus        → wefax::cfg / wefax::status (fldigi-Standardwerte)
// Alle Eingriffe sind mit „ABWEICHUNG fldigi (Digidec)“ markiert. GPLv3 wie fldigi.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_WEFAX_RX_H
#define DIGIDEC_WEFAX_RX_H

#include <string>
#include <vector>
#include <complex>
#include "fldigi_complex.h"
#include "gfft.h"

typedef int trx_mode;
enum { MODE_WEFAX_576 = 0, MODE_WEFAX_288 = 1 };

/// fldigi wefax-pic.h
struct LPM_VALUES {
	int          m_value ;
	const char * m_label ;
};
extern struct LPM_VALUES all_lpm_values[];

/// fldigi-Einstellungen, die WEFAX liest (Standardwerte aus fldigi configuration.h)
struct WefaxProgdefaults {
	int    WEFAX_Center           = 1900;  // NF-Mitte
	int    WEFAX_Shift            = 800;   // Hub (DWD laut fldigi: 850)
	int    wefax_lpm_576          = 1;     // Index in all_lpm_values: 0=240 1=120 2=90 3=60
	int    wefax_lpm_288          = 3;
	int    wefax_filter           = 0;     // 0 schmal, 1 mittel, 2 breit
	int    wefax_correlation_rows = 15;
	double wefax_correlation      = 0.05;
	int    WEFAX_MaxRows          = 4000;
	int    wefax_align_rows       = 10;
	int    wefax_align_stop       = 500;
	int    wefax_auto_after       = 30;
	bool   wefax_autocenter       = true;
	int    WEFAX_NoiseMargin      = 1;
	int    WEFAX_NoiseThreshold   = 5;
};

struct WefaxProgStatus {
	bool afconoff = true;
};

/// Ersatz für fldigis WFdisp: Leistung je 1-Hz-Pixel wie WFdisp::processFftBuffer
/// (8192-Punkt-FFT, Blackman-Fenster, pwr = norm), berechnet bei Bedarf aus den letzten Samples.
class WefaxWaterfall {
public:
	explicit WefaxWaterfall(int sample_rate);
	~WefaxWaterfall();
	void sig_data(const double *data, int len);
	double powerDensity(double f0, double bw) const;
	double powerDensityMaximum(int bw_nb, const int (*bw)[2]) const;
	long long rfcarrier() const { return m_rfcarrier; }

	double    carrierfreq = 1900;   // fldigi: Trägerfrequenz des Wasserfalls = Modem-Mitte
	long long m_rfcarrier = 0;      // Empfangsfrequenz laut Funkgerät (für AFC-Rücksetzen und Dateinamen)
private:
	void update() const;
	int m_rate;
	std::vector<double> m_circ;
	std::vector<double> m_window;
	int m_ptr = 0;
	mutable bool m_dirty = true;
	mutable std::vector<double> m_pwr;          // 0 … IMAGE_WIDTH Hz
	mutable std::vector<std::complex<double> > m_fftbuf;
	g_fft<double> *m_fft;
};

/// Ersatz für fldigis Empfangsbild (wefax_map + Empfangsteil von wefax-pic.cxx), ohne FLTK
class WefaxImage {
public:
	static const int depth = 3;                    // fldigi: 3 Byte je Pixel (Kanal 1 dient der Rauschentfernung als Puffer)
	static const int curr_pix_h_default = 1300;
	static const int noise_height_margin = 5;

	const WefaxProgdefaults *cfg = nullptr;
	int width = 0, height = 0, bufsize = 0;
	std::vector<unsigned char> vidbuf;
	int background = 255;

	// wefax-pic.cxx (file-static dort)
	int    center_val_prev = 0;
	int    curr_pix_height = curr_pix_h_default;
	int    rx_last_filtered_row = 0;
	bool   noise_removal = false;
	double rx_slant_ratio = 0.0;
	bool   reception_paused = false;
	double center_value = 0.0;          // fldigi: Regler wefax_rx_center
	int    prev_row = 0, last_row = 0;  // fldigi: static in update_rx_pic_bw

	// für die Anzeige
	int      rows = 0;                  // höchste beschriebene Zeile
	unsigned revision = 0;              // ändert sich bei jedem neuen Pixel / Verschieben / Löschen

	void (*on_saved)(void *ctx, const char *name, const char *comments,
	                 const unsigned char *gray, int width, int height) = nullptr;
	void *ctx = nullptr;

	// wefax_map
	void resize(int w, int h);
	void resize_height(int new_height, bool clear_img);
	void shift_horizontal_center(int horizontal_shift);
	void pixel(unsigned char data, int pos);
	bool restore(int row, int margin);
	void remove_noise(int row, int half_len, int noise_margin);

	// wefax-pic.cxx
	double slant_factor_default() const { return 100.0 / ( rx_slant_ratio + 100.0 ); }
	int  update_rx_pic_col(unsigned char data, int pix_pos);
	void update_rx_pic_bw(unsigned char data, int pix_pos);
	int  estimate_rx_image_center(int row_end, int numrows);
	void rx_center_changed();
	void abort_rx_viewer();
	void resize_rx_viewer(int wid_img);
	void save_image(const std::string &fil_name, const std::string &extra_comments);

	/// Graustufen (Kanal 0) der Zeilen 0 … rows
	void copy_gray(std::vector<unsigned char> &out, int &w, int &h) const;
};

/// Ersatz für fldigis Namensraum wefax_pic (statische Funktionen des Bildfensters).
/// Es gibt wie in fldigi nur ein Empfangsbild; `current` zeigt auf das des gerade rechnenden Decoders.
struct wefax_pic {
	static WefaxImage *current;
	static void update_rx_pic_bw(unsigned char data, int pix_pos) { current->update_rx_pic_bw(data, pix_pos); }
	static void skip_rx_apt() {}
	static void skip_rx_phasing(bool) {}
	static void abort_rx_viewer() { current->abort_rx_viewer(); }
	static void resize_rx_viewer(int w) { current->resize_rx_viewer(w); }
	static void save_image(const std::string &n, const std::string &c) { current->save_image(n, c); }
	static void send_image(const std::string &) {}
};

class fax_implementation;

/// Ersatz für fldigis Modem-Klasse `wefax` (nur Empfang)
class wefax {
public:
	wefax(trx_mode mode, const WefaxProgdefaults &defaults, const WefaxProgStatus &st);
	~wefax();

	WefaxProgdefaults cfg;
	WefaxProgStatus   status;
	WefaxWaterfall    m_wf;
	WefaxImage        image;
	fax_implementation *m_impl = nullptr;

	trx_mode mode;
	int    samplerate = 11025;
	double frequency  = 1900;
	double bandwidth  = 800;
	double metric     = 0;
	double snr_db     = 0;
	std::string status1, status2;

	WefaxWaterfall *waterfall() { return &m_wf; }
	void set_freq(double freq);
	void display_metric(double m) { metric = m; }
	void qso_rec_init() {}
	void put_Status1_(const char *s);
	void put_Status2_(const char *s) { status2 = s; }

	int  rx_process(const double *buf, int len);
	void skip_apt();
	void skip_phasing(bool auto_center);
	void end_reception();
	void set_rx_manual_mode(bool manual_flag);
	bool manual_mode() const;
	void save_now();

	int    rx_state() const;   // fax_state (RXAPTSTART …)
	double lpm() const;
	int    fax_width() const;
};

#endif
