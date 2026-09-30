// ----------------------------------------------------------------------------
// rtty_rx.cpp  --  RTTY-Empfänger, herausgelöst aus fldigi 4.2.13 (src/rtty/rtty.cxx)
//
// Original: Copyright (C) 2012 Dave Freese, W1HKJ; Stefan Fendt, DL1SMF; nach gmfsk von Tomi Manninen.
// fldigi ist freie Software unter der GNU General Public License v3 (oder neuer).
//
// Übernommen: rx_init, reset_filters, restart (RX-Teil), mixer, rttyparity, decode_char, is_mark_space,
// is_mark, rx, Metric, rx_process (ohne Synop, Mehrkanal-Viewer, Sync-Scope), baudot_dec, Baudot-Tabellen.
// Nicht übernommen: Senden, FSK-Tastung, Synop, view_rtty (Mehrkanal), searchUp/searchDown.
// ----------------------------------------------------------------------------

#include <cstring>
#include <cstdlib>
#include <cctype>
#include <algorithm>

#include "misc_min.h"
#include "rtty_rx.h"

//=====================================================================
// Baudot support (unverändert aus rtty.cxx)
//=====================================================================

static char letters[32] = {
	'\0',	'E',	'\n',	'A',	' ',	'S',	'I',	'U',
	'\r',	'D',	'R',	'J',	'N',	'F',	'C',	'K',
	'T',	'Z',	'L',	'W',	'H',	'Y',	'P',	'Q',
	'O',	'B',	'G',	' ',	'M',	'X',	'V',	' '
};

/*
 * U.S. version of the figures case.
 */
static char USTTY_figures[32] = {
	'\0',	'3',	'\n',	'-',	' ',	'\a',	'8',	'7',
	'\r',	'$',	'4',	'\'',	',',	'!',	':',	'(',
	'5',	'"',	')',	'2',	'#',	'6',	'0',	'1',
	'9',	'?',	'&',	' ',	'.',	'/',	';',	' '
};

/*
 * ITA-2 version of the figures case
 */
static char ITA2_figures[32] = {
	'\0',	'3',	'\n',	'-',	' ',	'\'',	'8',	'7',
	'\r',	' ',	'4',	'\a',	',',	'!',	':',	'(',
	'5',	'+',	')',	'2',	'#',	'6',	'0',	'1',
	'9',	'?',	'&',	' ',	'.',	'/',	'=',	' '
};

// ABWEICHUNG fldigi (Digidec): Filterlänge je Baudrate aus rtty::FILTLEN[] (gleiche Zuordnung zu rtty::BAUD[]);
// Baudraten außerhalb der Tabelle bekommen die Länge der nächstgrößeren Tabellen-Baudrate.
static int filter_length_for_baud(double baud)
{
	static const double BAUD[]  = {45, 45.45, 50, 56, 75, 100, 110, 150, 200, 300};
	static const int FILTLEN[] = { 512, 512, 512, 512, 512, 512, 512, 256, 128, 64};
	for (int i = 0; i < 10; i++)
		if (baud <= BAUD[i] + 1e-9) return FILTLEN[i];
	return 64;
}

rtty_rx::rtty_rx(const RTTYRxConfig &c, double center_freq, rtty_char_callback cb, void *ctx)
{
	cfg = c;
	char_cb = cb;
	char_ctx = ctx;

	samplerate = RTTY_SampleRate;
	frequency = center_freq;
	bandwidth = 0;
	freqerr = 0;
	metric = 0;
	snr_db = 0;
	sigsearch = 0;

	mark_filt = (fftfilt *)0;
	space_filt = (fftfilt *)0;

	pipe = new double[MAXPIPE];

	pd_buf = new double[PD_LEN];
	pd_window = new double[PD_LEN];
	for (int i = 0; i < PD_LEN; i++) {
		pd_buf[i] = 0;
		// fldigi BlackmanWindow (Standard WFPREFILTER = 1)
		double x = (double)i / PD_LEN;
		pd_window[i] = 0.42 - 0.50 * cos(2.0 * M_PI * x) + 0.08 * cos(4.0 * M_PI * x);
	}
	pd_ptr = 0;

	showxy = 0;
	bitcount = 0;
	dspcnt = 0;

	restart();
	rx_init();
	set_freq(center_freq);
}

rtty_rx::~rtty_rx()
{
	if (mark_filt) delete mark_filt;
	if (space_filt) delete space_filt;
	if (pipe) delete [] pipe;
	delete [] pd_buf;
	delete [] pd_window;
}

void rtty_rx::configure(const RTTYRxConfig &c)
{
	cfg = c;
	restart();
	rx_init();
	set_freq(frequency);
}

// modem::set_freq
void rtty_rx::set_freq(double freq)
{
	frequency = CLAMP(
		freq,
		cfg.low_cutoff + bandwidth / 2,
		cfg.high_cutoff - bandwidth / 2);
}

void rtty_rx::rx_init()
{
	rxstate = RTTY_RX_STATE_IDLE;
	rxmode = LETTERS;

	for (int i = 0; i < MAXBITS; i++ ) bit_buf[i] = 0.0;

	mark_phase = 0;
	space_phase = 0;
	xy_phase = 0.0;

	mark_mag = 0;
	space_mag = 0;
	mark_env = 0;
	space_env = 0;

	inp_ptr = 0;

	lastchar = 0;
	// ABWEICHUNG fldigi (Digidec): Synop-Initialisierung entfällt
}

void rtty_rx::reset_filters()
{
	delete mark_filt;
	mark_filt = new fftfilt(rtty_baud/samplerate, filter_length);
	mark_filt->rtty_filter(rtty_baud/samplerate, cfg.filter_k);
	delete space_filt;
	space_filt = new fftfilt(rtty_baud/samplerate, filter_length);
	space_filt->rtty_filter(rtty_baud/samplerate, cfg.filter_k);
}

void rtty_rx::restart()
{
	double stl;

	rtty_shift = shift = cfg.shift;
	rtty_baud = cfg.baud;
	filter_length = filter_length_for_baud(rtty_baud);

	nbits = rtty_bits = cfg.bits;
	if (rtty_bits == 5)
		rtty_parity = RTTY_PARITY_NONE;
	else
		switch (cfg.parity) {
			case 0 : rtty_parity = RTTY_PARITY_NONE; break;
			case 1 : rtty_parity = RTTY_PARITY_EVEN; break;
			case 2 : rtty_parity = RTTY_PARITY_ODD; break;
			case 3 : rtty_parity = RTTY_PARITY_ZERO; break;
			case 4 : rtty_parity = RTTY_PARITY_ONE; break;
			default : rtty_parity = RTTY_PARITY_NONE; break;
		}

	shift_state = LETTERS;
	rxmode = LETTERS;
	symbollen = (int) (samplerate / rtty_baud + 0.5);

	bandwidth = shift;   // set_bandwidth(shift)

	rtty_BW = rtty_baud * 2;

	reset_filters();

	mark_noise = space_noise = 0;
	bit = nubit = true;

// stop length = 1, 1.5 or 2 bits
	stl = cfg.stop_bits;
	stoplen = (int) (stl * samplerate / rtty_baud + 0.5);
	freqerr = 0.0;
	pipeptr = 0;

	for (int i = 0; i < MAXBITS; i++ ) bit_buf[i] = 0.0;

	metric = 0.0;

	for (int i = 0; i < MAXPIPE; i++)
		QI[i] = cmplx(0.0, 0.0);
	sigpwr = 0.0;
	noisepwr = 0.0;
	sigsearch = 0;
	dspcnt = 2*(nbits + 2);

	clear_zdata = true;

	mark_phase = 0;
	space_phase = 0;
	xy_phase = 0.0;

	mark_mag = 0;
	space_mag = 0;
	mark_env = 0;
	space_env = 0;

	inp_ptr = 0;

	for (int i = 0; i < MAXPIPE; i++) mark_history[i] = space_history[i] = cmplx(0,0);

	// ABWEICHUNG fldigi (Digidec): static-Initialwerte aus rx_process
	showxy = symbollen;
	bitcount = 5 * nbits * symbollen;

	// ABWEICHUNG fldigi (Digidec): Seitenband-/Reverse-Logik liefert die App als fertiges cfg.reverse
	reverse = cfg.reverse;
}

cmplx rtty_rx::mixer(double &phase, double f, cmplx in)
{
	cmplx z = cmplx( cos(phase), sin(phase)) * in;

	phase -= TWOPI * f / samplerate;
	if (phase < -TWOPI) phase += TWOPI;

	return z;
}

static int rparity(int c)
{
	int w = c;
	int p = 0;
	while (w) {
		p += (w & 1);
		w >>= 1;
	}
	return p & 1;
}

// ABWEICHUNG fldigi (Digidec): Parität aus cfg statt progdefaults.rtty_parity (Logik unverändert)
int rtty_rx::rttyparity(unsigned int c, int nbits) const
{
	c &= (1 << nbits) - 1;

	switch (cfg.parity) {
	default:
	case RTTY_PARITY_NONE:
		return 0;

	case RTTY_PARITY_ODD:
		return rparity(c);

	case RTTY_PARITY_EVEN:
		return !rparity(c);

	case RTTY_PARITY_ZERO:
		return 0;

	case RTTY_PARITY_ONE:
		return 1;
	}
}

int rtty_rx::decode_char()
{
	unsigned int parbit, par, data;

	parbit = (rxdata >> nbits) & 1;
	par = rttyparity(rxdata, nbits);

	if (rtty_parity != RTTY_PARITY_NONE && parbit != par)
		return 0;

	data = rxdata & ((1 << nbits) - 1);

	if (nbits == 5)
		return baudot_dec(data);

	return data;
}

bool rtty_rx::is_mark_space( int &correction)
{
	correction = 0;
// test for rough bit position
	if (bit_buf[0] && !bit_buf[symbollen-1]) {
// test for mark/space straddle point
		for (int i = 0; i < symbollen; i++)
			correction += bit_buf[i];
		if (abs(symbollen/2 - correction) < 6) // too small & bad signals are not decoded
			return true;
	}
	return false;
}

bool rtty_rx::is_mark()
{
	return bit_buf[symbollen / 2];
}

void rtty_rx::put_rx_char(int c)
{
	if (char_cb) char_cb(char_ctx, c);
}

bool rtty_rx::rx(bool bit) // original modified for probability test
{
	bool flag = false;
	unsigned char c = 0;
	int correction;

	for (int i = 1; i < symbollen; i++) bit_buf[i-1] = bit_buf[i];
	bit_buf[symbollen - 1] = bit;

	switch (rxstate) {
	case RTTY_RX_STATE_IDLE:
		if ( is_mark_space(correction)) {
			rxstate = RTTY_RX_STATE_START;
			counter = correction;
		}
		break;
	case RTTY_RX_STATE_START:
		if (--counter == 0) {
			if (!is_mark()) {
				rxstate = RTTY_RX_STATE_DATA;
				counter = symbollen;
				bitcntr = 0;
				rxdata = 0;
			} else {
				rxstate = RTTY_RX_STATE_IDLE;
			}
		}
		break;
	case RTTY_RX_STATE_DATA:
		if (--counter == 0) {
			rxdata |= is_mark() << bitcntr++;
			counter = symbollen;
		}
		if (bitcntr == nbits + (rtty_parity != RTTY_PARITY_NONE ? 1 : 0))
			rxstate = RTTY_RX_STATE_STOP;
		break;
	case RTTY_RX_STATE_STOP:
		if (--counter == 0) {
			if (is_mark()) {
				if ((metric >= cfg.squelch && cfg.squelch_on) || !cfg.squelch_on) {
					c = decode_char();
					// ABWEICHUNG fldigi (Digidec): Synop-Zweig entfällt (SynopAdif/Kml-Decoding aus)
					if ( c != 0 ) {
// supress <CR><CR> and <LF><LF> sequences
// these were observed during the RTTY contest 2/9/2013
						if (c == '\r' && lastchar == '\r');
						else if (c == '\n' && lastchar == '\n');
						else
							put_rx_char(cfg.rx_lowercase ? tolower(c) : c);
						lastchar = c;
					}
					flag = true;
				}
			}
			rxstate = RTTY_RX_STATE_IDLE;
		}
		break;
	default : break;
	}

	return flag;
}

// ABWEICHUNG fldigi (Digidec): Ersatz für WFdisp::powerDensity(). fldigi summiert die Leistung der
// 1-Hz-Pixel seines Wasserfalls (8192er-FFT, Blackman, Pixel i = Bin round(i·8192/8000)) von
// f0 − bw/2 bis f0 + bw/2 und teilt durch bw + 1. Hier dieselben Bins per Goertzel aus den letzten
// 8192 Samples. Die absolute Skalierung kürzt sich in Metric() heraus (nur Verhältnisse).
double rtty_rx::powerDensity(double f0, double bw) const
{
	int flower = (int)((f0 - bw/2)),
		fupper = (int)((f0 + bw/2));
	if (flower < 0 || fupper > 4000)
		return 0.0;
	const double scale = (double)PD_LEN / samplerate;
	double pwrdensity = 0.0;
	for (int i = flower; i <= fupper; i++) {
		int n = (int)round(scale * i);
		double w = TWOPI * n / PD_LEN;
		double coeff = 2.0 * cos(w);
		double s1 = 0, s2 = 0;
		int idx = pd_ptr;                  // ältestes Sample
		for (int k = 0; k < PD_LEN; k++) {
			double s0 = pd_buf[idx] * pd_window[k] + coeff * s1 - s2;
			s2 = s1;
			s1 = s0;
			if (++idx == PD_LEN) idx = 0;
		}
		double re = s1 - s2 * cos(w);
		double im = s2 * sin(w);
		double v = 2.0 / PD_LEN;           // vscale wie im fldigi-Wasserfall
		pwrdensity += (re * re + im * im) * v * v;
	}
	return pwrdensity/(bw+1);
}

void rtty_rx::Metric()
{
	double delta = rtty_baud/8.0;
	double np = powerDensity(frequency, delta) * 3000 / delta + 1e-8;
	double sp =
		powerDensity(frequency - shift/2, delta) +
		powerDensity(frequency + shift/2, delta) + 1e-8;
	double snr = 0;

	if (np < 1e-6) np = sp * 100;

	sigpwr = decayavg( sigpwr, sp, sp > sigpwr ? 2 : 8);
	noisepwr = decayavg( noisepwr, np, 16 );

	snr = 10*log10(sigpwr / noisepwr);

	snr_db = snr;   // ABWEICHUNG fldigi (Digidec): statt put_Status2("s/n …")
	metric = CLAMP((3000 / delta) * (sigpwr/noisepwr), 0.0, 100.0);
}

int rtty_rx::rx_process(const double *buf, int len)
{
	const double *buffer = buf;
	int length = len;

	cmplx z, zmark, zspace, *zp_mark, *zp_space;

	int n_out = 0;

	// ABWEICHUNG fldigi (Digidec): Verlauf für powerDensity() nachführen (fldigi: Wasserfall-circbuff)
	for (int i = 0; i < len; i++) {
		pd_buf[pd_ptr] = buf[i];
		if (++pd_ptr == PD_LEN) pd_ptr = 0;
	}

	// ABWEICHUNG fldigi (Digidec): reverse kommt fertig aus cfg (fldigi: wf->Reverse() ^ !wf->USB())
	reverse = cfg.reverse;

	Metric();

	while (length-- > 0) {

// Create analytic signal from sound card input samples

	z = cmplx(*buffer, *buffer);
	buffer++;

// Mix it with the audio carrier frequency to create two baseband signals
// mark and space are separated and processed independently
// lowpass Windowed Sinc - Overlap-Add convolution filters.
// The two fftfilt's are the same size and processed in sync
// therefore the mark and space filters will concurrently have the
// same size outputs available for further processing

		zmark = mixer(mark_phase, frequency + shift/2.0, z);
		mark_filt->run(zmark, &zp_mark);

		zspace = mixer(space_phase, frequency - shift/2.0, z);
		n_out = space_filt->run(zspace, &zp_space);

		for (int i = 0; i < n_out; i++) {

			mark_mag = abs(zp_mark[i]);
			mark_env = decayavg (mark_env, mark_mag,
						(mark_mag > mark_env) ? symbollen / 4 : symbollen * 16);
			mark_noise = decayavg (mark_noise, mark_mag,
						(mark_mag < mark_noise) ? symbollen / 4 : symbollen * 48);
			space_mag = abs(zp_space[i]);
			space_env = decayavg (space_env, space_mag,
						(space_mag > space_env) ? symbollen / 4 : symbollen * 16);
			space_noise = decayavg (space_noise, space_mag,
						(space_mag < space_noise) ? symbollen / 4 : symbollen * 48);

			noise_floor = std::min(space_noise, mark_noise);

// clipped if clipped decoder selected
			double mclipped = 0, sclipped = 0;
			mclipped = mark_mag > mark_env ? mark_env : mark_mag;
			sclipped = space_mag > space_env ? space_env : space_mag;
			if (mclipped < noise_floor) mclipped = noise_floor;
			if (sclipped < noise_floor) sclipped = noise_floor;

			switch (cfg.cwi) {
				case 1 : // mark only decode
					space_env = sclipped = noise_floor;
					break;
				case 2: // space only decode
					mark_env = mclipped = noise_floor;
				default : ;
			}

			double v3;

// Optimal ATC
			v3  = (mclipped - noise_floor) * (mark_env - noise_floor) -
					(sclipped - noise_floor) * (space_env - noise_floor) - 0.25 * (
					(mark_env - noise_floor) * (mark_env - noise_floor) -
					(space_env - noise_floor) * (space_env - noise_floor));

				bit = v3 > 0;

// XY scope signal generation

			if (cfg.true_scope) {
//----------------------------------------------------------------------
// "true" scope implementation------------------------------------------
//----------------------------------------------------------------------

// get the baseband-signal and...
				xy = cmplx(
						zp_mark[i].real() * cos(xy_phase) + zp_mark[i].imag() * sin(xy_phase),
						zp_space[i].real() * cos(xy_phase) + zp_space[i].imag() * sin(xy_phase) );

// if mark-tone has a higher magnitude than the space-tone,
// further reduce the scope's space-amplitude and vice versa
// this makes the scope looking a little bit nicer, too...
// aka: less noisy...
				if( abs(zp_mark[i]) > abs(zp_space[i]) ) {
					xy = cmplx( xy.real(),
								xy.imag() * abs(zp_space[i])/abs(zp_mark[i]) );
				} else {
					xy = cmplx( xy.real() / ( abs(zp_space[i])/abs(zp_mark[i]) ),
								xy.imag() );
				}

// now normalize the scope
				double const norm = 1.3*(abs(zp_mark [i]) + abs(zp_space[i]));
				xy /= norm;

			} else {
//----------------------------------------------------------------------
// "ortho" scope implementation-----------------------------------------
//----------------------------------------------------------------------
// get magnitude of the baseband-signal
				if (bit)
					xy = cmplx( mark_mag * cos(xy_phase), space_noise * sin(xy_phase) / 2.0);
				else
					xy = cmplx( mark_noise * cos(xy_phase) / 2.0, space_mag * sin(xy_phase));
// now normalize the scope
				double const norm = (mark_env + space_env);
				xy /= norm;
			}

// Rotate the scope x-y iaw frequency error.  Old scopes were not capable
// of this, but it should be very handy, so... who cares of realism anyways?
			double const rotate = 8 * TWOPI * freqerr / rtty_shift;
			xy = xy * cmplx(cos(rotate), sin(rotate));

			QI[inp_ptr] = xy;

// shift it to 128Hz(!) and not to it's original position.
// this makes it more pretty and does not remove it's other
// qualities. Reason is that this is a fraction of the used
// block-size.
			xy_phase += (TWOPI * (128.0 / samplerate));
// end XY signal generation

			mark_history[inp_ptr] = zp_mark[i];
			space_history[inp_ptr] = zp_space[i];

			inp_ptr = (inp_ptr + 1) % MAXPIPE;

			if (dspcnt && (--dspcnt % (nbits + 2) == 0)) {
				pipe[pipeptr] = bit - 0.5; //testbit - 0.5;
				pipeptr = (pipeptr + 1) % symbollen;
			}

// detect TTY signal transitions
// rx(...) returns true if valid TTY bit stream detected
// either character or idle signal
			if ( rx( reverse ? !bit : bit ) ) {
				dspcnt = symbollen * (nbits + 2);
				// ABWEICHUNG fldigi (Digidec): Update_syncscope() entfällt
				clear_zdata = true;
				bitcount = 5 * nbits * symbollen;
				if (sigsearch) sigsearch--;
					int mp0 = inp_ptr - 2;
				int mp1 = mp0 + 1;
				if (mp0 < 0) mp0 += MAXPIPE;
				if (mp1 < 0) mp1 += MAXPIPE;
				double ferr = (TWOPI * samplerate / rtty_baud) *
						(!reverse ?
							arg(conj(mark_history[mp1]) * mark_history[mp0]) :
							arg(conj(space_history[mp1]) * space_history[mp0]));
				if (fabs(ferr) > rtty_baud / 2) ferr = 0;
				freqerr = decayavg ( freqerr, ferr / 8,
					cfg.afc_speed == 0 ? 8 :
					cfg.afc_speed == 1 ? 4 : 1 );
				if (cfg.afc_on &&
					(metric > cfg.squelch || !cfg.squelch_on))
					set_freq(frequency - freqerr);
			} else
				if (bitcount) --bitcount;
		}
		// ABWEICHUNG fldigi (Digidec): Scope-Pflege ohne GUI; get_scope() liefert QI direkt
		if (!bitcount) {
			if (clear_zdata) {
				clear_zdata = false;
				for (int i = 0; i < MAXPIPE; i++)
					QI[i] = cmplx(0.0, 0.0);
			}
		}
		if (!--showxy) {
			showxy = symbollen;
		}
	}
	return 0;
}

int rtty_rx::get_scope(double *xyout, int max_points) const
{
	int n = max_points < MAXPIPE ? max_points : MAXPIPE;
	int start = (inp_ptr - n + MAXPIPE) % MAXPIPE;
	for (int k = 0; k < n; k++) {
		const cmplx &p = QI[(start + k) % MAXPIPE];
		xyout[2 * k] = p.real();
		xyout[2 * k + 1] = p.imag();
	}
	return n;
}

char rtty_rx::baudot_dec(unsigned char data)
{
	int out = 0;
	const char *figures;

	if (cfg.ita2)
		figures = ITA2_figures;
	else
		figures = USTTY_figures;

	switch (data) {
	case 0x1F:		/* letters */
		rxmode = LETTERS;
		break;
	case 0x1B:		/* figures */
		rxmode = FIGURES;
		break;
	case 0x04:		/* unshift-on-space */
		if (cfg.uos_rx)
			rxmode = LETTERS;
		return ' ';
		break;
	default:
		if (rxmode == LETTERS)
			out = letters[data];
		else
			out = figures[data];
		break;
	}

	return out;
}
