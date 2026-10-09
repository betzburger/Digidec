// ----------------------------------------------------------------------------
// rtty_rx.h  --  RTTY-Empfänger, herausgelöst aus fldigi 4.2.13 (src/include/rtty.h, src/rtty/rtty.cxx)
//
// Original: Copyright (C) 2012 Dave Freese, W1HKJ; Stefan Fendt, DL1SMF; nach gmfsk von Tomi Manninen.
// fldigi ist freie Software unter der GNU General Public License v3 (oder neuer).
//
// Digidec: nur der Empfangsteil. Algorithmik unverändert; fldigi-Globale (progdefaults, progStatus,
// Wasserfall, Digiscope, Synop, FLTK) sind durch RTTYRxConfig und Rückruffunktionen ersetzt.
// Jede Abweichung ist mit "ABWEICHUNG fldigi (Digidec)" markiert, Übersicht in UPSTREAM.md.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_RTTY_RX_H
#define DIGIDEC_RTTY_RX_H

#include "fldigi_complex.h" // ABWEICHUNG fldigi (Digidec): umbenannt, kollidiert sonst mit <complex.h> des Systems
#include "fftfilt.h"

#define	RTTY_SampleRate	8000

#define MAXPIPE			1024
#define MAXBITS			(2 * RTTY_SampleRate / 23 + 1)

#define	LETTERS	0x100
#define	FIGURES	0x200

// ABWEICHUNG fldigi (Digidec): ersetzt progdefaults / progStatus
struct RTTYRxConfig {
	double shift        = 170;     // Hz (rtty_shift bzw. rtty_custom_shift)
	double baud         = 45.45;   // rtty_baud
	int    bits         = 5;       // 5, 7, 8
	int    parity       = 0;       // 0 none, 1 even, 2 odd, 3 zero, 4 one
	double stop_bits    = 1.5;     // 1, 1.5, 2
	bool   reverse      = false;   // Mark/Space vertauscht (fldigi: wf->Reverse() ^ !wf->USB())
	int    afc_speed    = 1;       // 0 slow, 1 normal, 2 fast (rtty_afcspeed)
	bool   afc_on       = true;    // progStatus.afconoff
	bool   squelch_on   = false;   // progStatus.sqlonoff
	double squelch      = 0;       // progStatus.sldrSquelchValue, 0 … 100 (gegen metric)
	int    cwi          = 0;       // 0 Mark-Space, 1 nur Mark, 2 nur Space (rtty_cwi)
	bool   uos_rx       = true;    // Unshift on Space (UOSrx)
	bool   ita2         = false;   // ITA2- statt US-TTY-Ziffernsatz (ITA2)
	bool   true_scope   = true;    // XY-Scope aus Mark/Space-Filtern (true_scope)
	double filter_k     = 1.4;     // Formfaktor rtty_filter (fldigi 4.2.13: fest 1.4)
	double low_cutoff   = 0;       // LowFreqCutoff (Grenze für AFC/set_freq)
	double high_cutoff  = 3000;    // HighFreqCutoff
	bool   rx_lowercase = false;   // rx_lowercase
};

// ABWEICHUNG fldigi (Digidec): ersetzt put_rx_char und set_freq/put_freq
typedef void (*rtty_char_callback)(void *ctx, int c);

class rtty_rx {
public:
enum RTTY_RX_STATE {
	RTTY_RX_STATE_IDLE = 0,
	RTTY_RX_STATE_START,
	RTTY_RX_STATE_DATA,
	RTTY_RX_STATE_PARITY,
	RTTY_RX_STATE_STOP,
	RTTY_RX_STATE_STOP2
};
enum RTTY_PARITY {
	RTTY_PARITY_NONE = 0,
	RTTY_PARITY_EVEN,
	RTTY_PARITY_ODD,
	RTTY_PARITY_ZERO,
	RTTY_PARITY_ONE
};

	rtty_rx(const RTTYRxConfig &cfg, double center_freq, rtty_char_callback cb, void *ctx);
	~rtty_rx();

	void configure(const RTTYRxConfig &cfg);   // wie fldigi restart() nach Einstellungsänderung
	void set_freq(double freq);                // modem::set_freq
	double get_freq() const { return frequency; }
	void rx_init();
	void restart();
	void reset_filters();
	int rx_process(const double *buf, int len);

	// Anzeige
	double get_metric() const { return metric; }
	double get_snr_db() const { return snr_db; }
	double get_freqerr() const { return freqerr; }
	double get_mark_mag() const { return mark_mag; }
	double get_space_mag() const { return space_mag; }
	int    get_scope(double *xy, int max_points) const;   // QI-Puffer (set_zdata) als x,y-Paare, älteste zuerst

private:
	RTTYRxConfig cfg;
	rtty_char_callback char_cb;
	void *char_ctx;

	// aus class modem
	double samplerate;
	double frequency;
	double bandwidth;
	double freqerr;
	double metric;
	bool   reverse;
	int    sigsearch;

	double shift;
	int symbollen;
	int nbits;
	int stoplen;

	double		rtty_shift;
	double		rtty_BW;
	double		rtty_baud;
	int 		rtty_bits;
	RTTY_PARITY	rtty_parity;

	double		mark_noise;
	double		space_noise;
	bool		nubit;
	bool		bit;

	bool		bit_buf[MAXBITS];

	double mark_phase;
	double space_phase;
	fftfilt *mark_filt;
	fftfilt *space_filt;
	int filter_length;

	double *pipe;
	int pipeptr;

	cmplx mark_history[MAXPIPE];
	cmplx space_history[MAXPIPE];

	RTTY_RX_STATE rxstate;

	int counter;
	int bitcntr;
	int rxdata;

	double xy_phase;

	cmplx QI[MAXPIPE];
	int inp_ptr;

	cmplx xy;

	bool   clear_zdata;
	double sigpwr;
	double noisepwr;
	double snr_db;

	double mark_mag;
	double space_mag;
	double mark_env;
	double space_env;
	double	noise_floor;

	unsigned char lastchar;

	int rxmode;
	int shift_state;

	// ABWEICHUNG fldigi (Digidec): in fldigi globale bzw. funktionslokale static-Variablen
	int dspcnt;
	int showxy;
	int bitcount;

	// ABWEICHUNG fldigi (Digidec): Ersatz für wf->powerDensity() (Leistung je 1-Hz-Bin des Wasserfalls)
	enum { PD_LEN = 8192 };
	double *pd_buf;
	double *pd_window;
	int pd_ptr;
	double powerDensity(double f0, double bw) const;

	inline cmplx mixer(double &phase, double f, cmplx in);

	int rttyparity(unsigned int c, int nbits) const;
	int decode_char();
	bool rx(bool bit);
	char baudot_dec(unsigned char data);
	void Metric();

	bool is_mark_space(int &);
	bool is_mark();
	void put_rx_char(int c);
};

#endif
