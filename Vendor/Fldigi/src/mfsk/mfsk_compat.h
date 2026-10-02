// ----------------------------------------------------------------------------
// mfsk_compat.h  --  Digidec: Umgebung für MFSK, DominoEX und Thor aus fldigi 4.2.13
//
// Stellt unter den Namen, die mfsk.cxx, dominoex.cxx und thor.cxx erwarten, bereit: die Modem-Basisklasse,
// progdefaults/progStatus-Felder (fldigi-Standardwerte), Wasserfall-Träger, Anzeige- und Statusaufrufe (leer),
// Bildempfang (leer), Modus-Aufzählung. So bleiben die übernommenen Funktionsrümpfe unverändert. GPLv3 wie fldigi.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_MFSK_COMPAT_H
#define DIGIDEC_MFSK_COMPAT_H

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <iomanip>
#include "fldigi_complex.h"
#include "misc_min.h"
#include "filters.h"
#include "fftfilt.h"
#include "viterbi.h"
#include "interleave.h"
#include "mfskvaricode.h"
#include "mbuffer.h"

#define EOT 0x04                  // fldigi ascii.h
#define SOH 0x01
#define OUTBUFSIZE 65536

// fldigi misc.h
inline double clamp(double x, double min, double max)
{
	return (x < min) ? min : ((x > max) ? max : x);
}
inline double blackman(double x)
{
	return (0.42 - 0.50 * cos(2 * M_PI * x) + 0.08 * cos(4 * M_PI * x));
}
unsigned char grayencode(unsigned char data);
unsigned char graydecode(unsigned char data);

// fldigi globals.h: trx_mode und die MODE_*-Werte in Originalreihenfolge
typedef intptr_t trx_mode;
enum {
#include "psk_modes.inc"
};

// fldigi modem.h: Fähigkeiten
enum { CAP_NONE = 0, CAP_AFC = 1 << 0, CAP_AFC_SR = 1 << 1, CAP_REV = 1 << 2, CAP_IMG = 1 << 3, CAP_BW = 1 << 4 };
struct fntchr { char c; int byte[14]; };

namespace Digiscope { enum scope_mode { PHASE = 0, SCOPE = 1, DOMDATA = 2, RTTY = 3, BLANK = 4 }; }
enum status_timeout { STATUS_CLEAR, STATUS_DIM };

/// fldigi-Einstellungen, die die Empfänger lesen (Standardwerte aus fldigi configuration.h)
struct FamProgdefaults {
	bool   StartAtSweetSpot = false;  // fldigi: true; Digidec setzt die Trägerfrequenz selbst
	double PSKsweetspot     = 1500;
	bool   Pskmails2nreport = false;
	int    mfsk_avg         = 32;
	bool   softMFSK         = false;
	bool   softDOMINOEX     = false;
	bool   softTHOR         = false;
	int    SoftStart        = 0;
	// DominoEX
	double DOMINOEX_BW      = 2.0;
	bool   DOMINOEX_FILTER  = true;
	bool   DOMINOEX_FEC     = false;
	bool   rx_lowercase     = false;
	// Feld Hell
	double HELL_BW          = 245.0;
	double HELL_BW_FH = 245.0, HELL_BW_SH = 30.0, HELL_BW_X5 = 1225.0, HELL_BW_X9 = 2205.0;
	double HELL_BW_FSKH245 = 250.0, HELL_BW_FSKH105 = 120.0, HELL_BW_HELL80 = 450.0;
	int    HellRcvWidth     = 2;
	int    HellRcvHeight    = 20;
	bool   HellBlackboard   = false;
	bool   HellMarquee      = false;
	int    HellXmtWidth     = 1;
	bool   HellXmtIdle      = false;
	int    HellPulseFast    = 1;
	int    hellagc          = 2;
	int    feldfontnbr      = 4;
	// FSQ: Mittelungslänge, Geschwindigkeit (Baud), Treffer
	int    fsq_movavg       = 4;
	double fsqbaud          = 4.5;
	int    fsqhits          = 3;
	// IFKP: Geschwindigkeit 0 = 0,5, 1 = 1,0, 2 = 2,0; Frequenzbindung an 1500 Hz aus (fldigi: an)
	int    ifkp_baud        = 1;
	bool   ifkp_freqlock    = false;
	bool   slowcpu          = false;   // fldigi: true (weniger Pfade); Digidec rechnet mit allen Pfaden
	std::string secText     = "";
	// Thor
	double THOR_BW          = 2.0;
	bool   THOR_FILTER      = true;
	int    THOR_PATHS       = 5;
	double ThorCWI          = 0.0;
	bool   THOR_PREAMBLE    = true;
	bool   THOR_SOFTSYMBOLS = true;
	bool   THOR_SOFTBITS    = true;
	std::string THORsecText = "";
	double THOR_RISETIME    = 4.0;
};

/// fldigi progStatus-Felder
struct FamProgStatus {
	bool   thordebug        = false;
	double carrier          = 0;
	bool   afconoff         = true;
	bool   sqlonoff         = true;
	double sldrSquelchValue = 5.0;
};

/// Ersatz für fldigis Wasserfall: nur Trägerfrequenz
struct FamWaterfall {
	double carrier = 1000;
	double Carrier() const { return carrier; }
	void redraw_marker() {}
};

// Bildempfang (MFSK): Ersatz für fldigis Bildfenster. Die Pixel gehen an den Rückruf des Modems.
struct FamPicStub { void save_png(const char *) {} };
static FamPicStub famPicStub;
static FamPicStub *picRx = &famPicStub;
static const char *PicsDir = "";

/// Ersatz für fldigis Modem-Basisklasse (nur was die Empfänger benutzen)
class fam_modem_base {
public:
	virtual ~fam_modem_base() {}
	double frequency  = 1000;
	double bandwidth  = 0;
	double samplerate = 8000;
	double metric     = 0;
	int    symlen     = 0;
	double syncpos    = 0.5;
	double tx_frequency = 1000;
	int    fragmentsize = 0;
	trx_mode mode = MODE_MFSK16;
	int    cap  = 0;
	bool   freqlock = false;
	bool   reverse  = false;
	bool   stopflag = false;
	int    sigsearch = 0;
	double freqerr = 0;
	bool   s2n_valid = false;
	double s2n_metric = 0, s2n_sum = 0, s2n_sum2 = 0, s2n_ncount = 0;
	bool   mailserver = false, mailclient = false;
	bool   sig_start = false, sig_stop = false;
	bool   fsq_tx_image = false;
	int    quality_ = 0;
	double outbuf[OUTBUFSIZE];

	FamProgdefaults progdefaults_;
	FamProgStatus   progStatus_;
	FamWaterfall    wf_;
	FamWaterfall   *wf = &wf_;

	// Ausgaben für Digidec
	void (*on_char)(void *ctx, int c) = nullptr;
	void (*on_sec_char)(void *ctx, int c) = nullptr;
	void *on_char_ctx = nullptr;
	void (*on_pixel)(void *ctx, int value, int pos) = nullptr;
	void (*on_picture)(void *ctx, int w, int h, int color) = nullptr;
	// Sendeseite (nur Testsignal): Samples gehen in diesen Puffer
	std::vector<float> *tx_sink = nullptr;

	virtual int rx_process(const double *, int) { return 0; }
	void update_quality(int q) { quality_ = q; }
	int  get_quality() const { return quality_; }
	void set_bandwidth(double b) { bandwidth = b; }
	virtual void set_freq(double f) { frequency = f; }
	void set_freqlock(bool) {}
	void display_metric(double m) { metric = m; }
	void put_rx_char(int c) { if (on_char) on_char(on_char_ctx, c); }
	void put_sec_char(int c) { if (on_sec_char && c) on_sec_char(on_char_ctx, c); }
	void put_echo_char(int) {}
	// Feld Hell: eine Rasterspalte (2 · Spaltenlänge Werte 0 … 255) an den Rückruf
	void (*on_column)(void *ctx, const int *data, int len) = nullptr;
	void put_rx_data(int *data, int len) { if (on_column) on_column(on_char_ctx, data, len); }
	void set_scope_mode(int) {}
	void set_scope(double *, int, bool = false) {}
	void set_video(double *, int, bool = true) {}
	void videoText() {}
	double get_txfreq_woffset() const { return frequency; }
	void ModulateXmtr(double *buf, int len) {
		if (tx_sink) for (int i = 0; i < len; i++) tx_sink->push_back((float)buf[i]);
	}
	template <class... A> void put_MODEstatus(A...) {}
	template <class... A> void put_Status1(A...) {}
	template <class... A> void put_Status2(A...) {}
	template <class... A> void put_status(A...) {}
	void s2nreport() {}
};

// Thor: Bild- und Avatar-Anzeige, Statusabfrage, Protokoll (alles leer)
enum { STATE_RX = 1 };
static const int trx_state = STATE_RX;
inline void thor_clear_avatar() {}
inline void thor_showRxViewer(int) {}
inline void thor_update_avatar(int, int) {}
inline void thor_updateRxPic(int, int) {}
inline void thor_enableshift() {}
#define LOG_INFO(...)  ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_ERROR(...) ((void)0)

#define progdefaults progdefaults_
#define progStatus   progStatus_
#define REQ(f, ...)  f(__VA_ARGS__)

#endif
