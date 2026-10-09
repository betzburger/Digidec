// ----------------------------------------------------------------------------
// cw_compat.h  --  Digidec: Umgebung für den CW-Empfänger aus fldigi 4.2.13 (src/cw/cw.cxx)
//
// Stellt unter den Namen, die cw.cxx erwartet, bereit: die Modem-Basisklasse, progdefaults/progStatus-
// Felder (fldigi-Standardwerte), Wasserfall-Träger, Digiscope- und Statusaufrufe (leer bzw. gespeichert).
// So bleiben die übernommenen Funktionsrümpfe unverändert. GPLv3 wie fldigi.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_CW_COMPAT_H
#define DIGIDEC_CW_COMPAT_H

#include <cmath>
#include <cstring>
#include <string>
#include <vector>
#include "fldigi_complex.h"
#include "misc_min.h"
#include "morse.h"

#define OUTBUFSIZE 65536          // fldigi modem.h
#define CW_DEBUG 0
#define REQ(...) ((void)0)        // GUI-Aktualisierungen entfallen

// fldigi misc.h
inline double clamp(double x, double min, double max)
{
	return (x < min) ? min : ((x > max) ? max : x);
}

/// fldigi-Einstellungen, die der CW-Empfänger liest (Standardwerte aus fldigi configuration.h)
struct CwProgdefaults {
	int    CWspeed          = 18;     // WPM (Startwert der Geschwindigkeitsnachführung)
	int    CWbandwidth      = 150;    // Hz (FIR-Bandpass)
	int    CWfarnsworth     = 18;
	double CWupper          = 0.6;    // wird vom Decoder laufend überschrieben (Hysterese)
	double CWlower          = 0.4;
	bool   CWmfilt          = false;  // Matched Filter: Bandbreite = 2 × WPM
	bool   StartAtSweetSpot = false;
	double CWsweetspot      = 1500;
	int    CW_fillen        = 2;      // 0:128 1:256 2:512 3:1024 FIR-Taps
	double CWrisetime       = 4.0;
	int    QSKshape         = 0;
	double CWdash2dot       = 3.0;
	bool   CWtrack          = true;   // Geschwindigkeit nachführen
	int    CWrange          = 10;     // ± WPM um CWspeed
	int    CWlowerlimit     = 5;
	int    CWupperlimit     = 50;
	int    cwrx_attack      = 1;      // 0 langsam, 1 mittel, 2 schnell
	int    cwrx_decay       = 1;
	char   CW_noise         = '*';    // Zeichen für nicht erkannte Codes ('*', '_', ' ' oder keins)
	bool   CWuseSOMdecoding = false;  // SOM-Mustererkennung statt Tabelle
	bool   CW_use_paren     = false;
	std::string CW_prosigns = "=~<>%+&{}";
	bool   pretone          = false;
};

/// fldigi progStatus-Felder
struct CwProgStatus {
	double carrier          = 0;
	bool   sqlonoff         = false;
	double sldrSquelchValue = 0;
	bool   show_channels    = false;
};

/// Ersatz für fldigis Wasserfall: nur Trägerfrequenz und Seitenband
struct CwWaterfall {
	double carrier = 1000;
	bool   rev     = false;
	double Carrier() const { return carrier; }
	bool   Reverse() const { return rev; }
	bool   USB() const { return true; }
};

/// Ersatz für view_cw (Mehrkanal-Ansicht) und den Signal-Browser-Dialog
struct CwViewStub {
	void restart() {}
	int  rx_process(const double *, int) { return 0; }
};
struct CwDialogStub {
	bool visible() const { return false; }
};

namespace Digiscope { enum scope_mode { SCOPE = 0 }; }
namespace FTextBase { enum { RECV = 0, CTRL = 1 }; }

enum { MODE_CW = 0, CAP_BW = 1 };

/// Ersatz für fldigis Modem-Basisklasse (nur was cw.cxx im Empfang benutzt)
class cw_modem_base {
public:
	virtual ~cw_modem_base() {}
	double frequency  = 1000;
	double bandwidth  = 150;
	double samplerate = 8000;
	double metric     = 0;
	int    fragmentsize = 0;
	int    mode = MODE_CW;
	int    cap  = 0;
	bool   freqlock = false;
	bool   reverse  = false;
	bool   stopflag = false;
	bool   cwTrack  = true;
	int    symbols = 0, acc_symbols = 0, ovhd_symbols = 0;
	double outbuf[OUTBUFSIZE];      // fldigi modem::outbuf; init() löscht ihn mit memset über die volle Länge
	cMorse  morse_;                  // fldigi: modem::morse (new cMorse in modem.cxx)
	cMorse *morse = &morse_;

	CwProgdefaults progdefaults_;   // über das Makro unten als `progdefaults` erreichbar
	CwProgStatus   progStatus_;
	CwWaterfall    wf_;
	CwWaterfall   *wf = &wf_;
	CwDialogStub   dlg_;
	CwDialogStub  *dlgViewer = &dlg_;
	bool bHighSpeed = false;
	bool bHistory   = false;

	// Ausgaben für Digidec
	void (*on_char)(void *ctx, const char *text, int is_prosign) = nullptr;
	void *on_char_ctx = nullptr;
	double rx_wpm = 0;
	std::vector<double> scope;      // letzte Hüllkurve (Digiscope)
	double scope_level = 0;

	void set_freq(double f) { frequency = f; }
	void display_metric(double m) { metric = m; }
	void put_rx_char(int c, int style) {
		char s[2] = { (char)c, 0 };
		if (on_char) on_char(on_char_ctx, s, style == FTextBase::CTRL);
	}
	void put_cwRcvWPM(double w) { rx_wpm = w; }
	void set_scope_mode(int) {}
	void set_scope_xaxis_1(double y) { scope_level = y; }
	template <class T> void set_scope(T &data, int len, bool) {
		scope.assign(len, 0.0);
		for (int i = 0; i < len; i++) scope[i] = data[i];
	}
	template <class... A> void put_MODEstatus(A...) {}
};

#define progdefaults progdefaults_
#define progStatus   progStatus_

// Senden/Tastung entfällt
inline void start_cwio_thread() {}
inline void stop_cwio_thread() {}
static const bool use_nanoIO = false;
inline void set_nanoCW() {}
inline void set_nanoWPM(int) {}
inline void set_nano_dash2dot(double) {}

#endif
