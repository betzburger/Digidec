// ----------------------------------------------------------------------------
// psk_compat.h  --  Digidec: Umgebung für den PSK-Empfänger aus fldigi 4.2.13 (src/psk/psk.cxx)
//
// Stellt unter den Namen, die psk.cxx erwartet, bereit: die Modem-Basisklasse, progdefaults/progStatus-Felder
// (fldigi-Standardwerte), Wasserfall-Träger, Digiscope- und Statusaufrufe (leer bzw. gespeichert), Modus-Aufzählung.
// So bleiben die übernommenen Funktionsrümpfe unverändert. GPLv3 wie fldigi.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_PSK_COMPAT_H
#define DIGIDEC_PSK_COMPAT_H

#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <iomanip>
#include "fldigi_complex.h"
#include "misc_min.h"
#include "filters.h"
#include "viterbi.h"
#include "interleave.h"
#include "pskcoeff.h"
#include "pskvaricode.h"
#include "mfskvaricode.h"

#define EOT 0x04                  // fldigi ascii.h
#define IMAGE_WIDTH 3000          // fldigi-config.h (nur Signalsuche des Mailservers)
#define PipeLen (64)              // psk.h

// fldigi misc.h
inline double clamp(double x, double min, double max)
{
	return (x < min) ? min : ((x > max) ? max : x);
}

// fldigi globals.h: trx_mode und die MODE_*-Werte in Originalreihenfolge
typedef intptr_t trx_mode;
enum {
#include "psk_modes.inc"
};

// fldigi modem.h: Fähigkeiten
enum { CAP_NONE = 0, CAP_AFC = 1 << 0, CAP_AFC_SR = 1 << 1, CAP_REV = 1 << 2 };

namespace Digiscope { enum scope_mode { PHASE = 0, SCOPE = 1 }; }
enum status_timeout { STATUS_CLEAR, STATUS_DIM };

/// fldigi-Einstellungen, die der PSK-Empfänger liest (Standardwerte aus fldigi configuration.h)
struct PskProgdefaults {
	bool   StartAtSweetSpot = false;  // fldigi: true; Digidec setzt die Trägerfrequenz selbst
	double PSKsweetspot     = 1500;
	int    SearchRange      = 50;
	bool   pskpilot         = false;
	double ACQsn            = 9.0;
	bool   Pskmails2nreport = false;
	bool   StatusDim        = true;
	double StatusTimeout    = 15.0;
	bool   PSKmailSweetSpot = false;
	int    ServerOffset     = 50;
	int    ServerCarrier    = 1500;
	int    ServerAFCrange   = 25;
	double ServerACQsn      = 9.0;
	bool   report_when_visible = false;
	double pilot_power      = -20;   // Sendeseite (Testsignal)
	bool   softPSK          = false;
};

/// fldigi progStatus-Felder
struct PskProgStatus {
	bool   psk8DCDShortFlag = false;
	double carrier          = 0;
	bool   afconoff         = true;
	bool   sqlonoff         = true;
	double sldrSquelchValue = 5.0;
	bool   show_channels    = false;
};

/// Ersatz für fldigis Wasserfall: nur Trägerfrequenz
struct PskWaterfall {
	double carrier = 1000;
	double Carrier() const { return carrier; }
	double powerDensity(double, double) const { return 0; }
};

/// Ersatz für die Mehrkanal-Ansicht (viewpsk), den Signal-Browser-Dialog und die Signalsuche (pskeval)
struct pskeval {
	void setbw(double) {}
	double sigpeak(int &, int, int) { return 0; }
	void sigdensity() {}
};
struct viewpsk {
	viewpsk(pskeval *, trx_mode) {}
	void restart(trx_mode) {}
	int rx_process(const double *, int) { return 0; }
	void clear() {}
	void clearch(int) {}
	int get_freq(int) { return 0; }
};
struct PskDialogStub {
	bool visible() const { return false; }
};

/// Ersatz für fldigis Modem-Basisklasse (nur was psk.cxx im Empfang benutzt)
class psk_modem_base {
public:
	virtual ~psk_modem_base() {}
	double frequency  = 1000;
	double bandwidth  = 0;
	double samplerate = 8000;
	double metric     = 0;
	int    fragmentsize = 0;
	trx_mode mode = MODE_PSK31;
	int    cap  = 0;
	bool   freqlock = false;
	bool   reverse  = false;
	bool   stopflag = false;
	int    sigsearch = 0;
	int    symbols = 0, acc_symbols = 0, ovhd_symbols = 0, char_symbols = 0;
	double s2n_metric = 0, s2n_sum = 0, s2n_sum2 = 0, s2n_ncount = 0;
	bool   mailserver = false, mailclient = false;
	bool   bHistory = false;

	PskProgdefaults progdefaults_;
	PskProgStatus   progStatus_;
	PskWaterfall    wf_;
	PskWaterfall   *wf = &wf_;
	PskDialogStub   dlg_;
	PskDialogStub  *dlgViewer = &dlg_;

	// Sendeseite (nur Testsignal): Samples gehen in diesen Puffer
	double outbuf[65536];
	std::vector<float> *tx_sink = nullptr;
	double get_txfreq_woffset() const { return frequency; }
	void ModulateXmtr(double *buf, int len) {
		if (tx_sink) for (int i = 0; i < len; i++) tx_sink->push_back((float)buf[i]);
	}

	// Ausgaben für Digidec
	void (*on_char)(void *ctx, int c) = nullptr;
	void *on_char_ctx = nullptr;
	int quality_ = 0;
	// Phasenvektor (Digiscope PHASE): letzte Symbole (Phase, Betrag, DCD)
	struct ScopePoint { double phase, amp; bool dcd; };
	std::vector<ScopePoint> scope;

	void set_freq(double f) { frequency = f; }
	void set_freqlock(bool) {}
	void display_metric(double m) { metric = m; }
	void put_rx_char(int c) { if (on_char) on_char(on_char_ctx, c); }
	void update_quality(int q) { quality_ = q; }
	int  get_quality() const { return quality_; }
	void set_phase(double p, double a, bool d) {
		scope.push_back({p, a, d});
		if (scope.size() > 256) scope.erase(scope.begin(), scope.begin() + (scope.size() - 256));
	}
	void set_scope_mode(int) {}
	void videoText() {}
	template <class... A> void put_MODEstatus(A...) {}
	template <class... A> void put_Status1(A...) {}
	template <class... A> void put_Status2(A...) {}
	template <class... A> void put_status(A...) {}
};

#define progdefaults progdefaults_
#define progStatus   progStatus_

#endif
