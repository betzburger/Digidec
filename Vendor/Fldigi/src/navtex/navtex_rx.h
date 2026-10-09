// ----------------------------------------------------------------------------
// navtex_rx.h  --  Rahmen für den NAVTEX-Empfänger aus fldigi 4.2.13 (src/navtex/navtex.cxx)
//
// Digidec. Ersetzt die fldigi-Klassen, die navtex_implementation benutzt:
//   - `navtex` (fldigi: modem-Unterklasse)  → Rahmen mit Einstellungen, Rückrufen, Metrik, Mittenfrequenz
//   - `wf` (fldigi: Wasserfall WFdisp)      → NavtexWaterfall: powerDensity / powerDensityMaximum / Reverse / USB
// So bleibt der Decoder-Code in navtex_rx.cpp nahezu unverändert. GPLv3 wie fldigi.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_NAVTEX_RX_H
#define DIGIDEC_NAVTEX_RX_H

#include <string>
#include <vector>

struct NavtexConfig {
	bool   sitor_b_only = false;
	bool   reverse      = false;   // fldigi: wf->Reverse() ^ !wf->USB()
	bool   afc_on       = true;    // progStatus.afconoff
	bool   ita2         = false;   // progdefaults.ITA2
	size_t min_msg      = 0;       // progdefaults.NVTX_MinSizLoggedMsg
};

struct NavtexCallbacks {
	void (*on_char)(void *ctx, int c) = nullptr;
	void (*on_message)(void *ctx, const char *text, char origin, char subject, int number, const char *subject_text) = nullptr;
	void *ctx = nullptr;
};

/// Ersatz für fldigis WFdisp: Leistung je 1-Hz-Pixel aus den letzten Samples (Blackman-Fenster, Goertzel),
/// wie powerDensity()/powerDensityMaximum() in fldigi src/waterfall/waterfall.cxx.
class NavtexWaterfall {
public:
	explicit NavtexWaterfall(int sample_rate);
	~NavtexWaterfall();
	void sig_data(const double *data, int len);
	double powerDensity(double f0, double bw) const;
	double powerDensityMaximum(int bw_nb, const int (*bw)[2]) const;
	bool Reverse() const { return m_reverse; }
	bool USB() const { return true; }       // Seitenband steckt bereits in Reverse (wie RTTY in Digidec)

	bool   m_reverse = false;
	double carrierfreq = 1000;              // fldigi: Trägerfrequenz des Wasserfalls = Modem-Mittenfrequenz
private:
	double pwr(int hz) const;
	int     m_rate;
	int     m_len;
	double *m_buf;
	double *m_window;
	int     m_ptr = 0;
};

class navtex_implementation;

/// Ersatz für fldigis Modem-Klasse `navtex`
class navtex {
public:
	navtex(const NavtexConfig &cfg, double center, const NavtexCallbacks &cb);
	~navtex();

	void configure(const NavtexConfig &cfg);
	void rx_process(const double *buf, int len);
	void set_freq(double freq);
	double get_freq() const { return m_frequency; }

	// von navtex_implementation benutzt (fldigi: modem-Methoden)
	int  get_samplerate() const { return 11025; }
	void display_metric(double m) { m_metric = m; }
	bool get_reverse() const { return false; }  // fldigi modem::reverse; die Umkehr läuft über wf->Reverse()
	void ModulateXmtr(double *, int) {}          // kein Senden

	const NavtexConfig &config() const { return m_cfg; }
	const NavtexCallbacks &callbacks() const { return m_cb; }
	NavtexWaterfall *waterfall() { return &m_wf; }
	/// Testsignal: Text wie fldigis NAVTEX-Sender kodieren (CCIR 476 + FEC)
	std::string encode_fec(const std::string &text) const;

	double m_metric = 0;
	double m_snr = 0;
	int    m_state = 0;
private:
	NavtexConfig     m_cfg;
	NavtexCallbacks  m_cb;
	NavtexWaterfall  m_wf;
	double           m_frequency;
	navtex_implementation *m_impl;
};

/// fldigi NavtexCatalog::FindStation (für die Anzeige des Senders)
bool navtex_find_station(char origin, double frequency_hz, const std::string &locator, const std::string &msg,
                         std::string &out);
bool navtex_load_stations(const std::string &data_dir);
std::string navtex_encode_fec(const std::string &text, bool ita2);

#endif
