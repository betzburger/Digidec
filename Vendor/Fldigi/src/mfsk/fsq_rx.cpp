// ----------------------------------------------------------------------------
// fsq_rx.cpp  --  FSQ-Empfänger aus fldigi 4.2.13 (src/fsq/fsq.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2015 Dave Freese, W1HKJ (FSQ: Fast Simple QSO, Con Wassilieff ZL1ACN und Murray Greenman ZL1BPU). GNU GPL v3.
// ABWEICHUNG fldigi (Digidec): Empfangsfunktionen wörtlich übernommen, außer wie unten vermerkt; die Sendefunktionen (send_*) sind nur für
// das Testsignal. Die Auswertung gerichteter Befehle (parse_*: Antworten, Weiterleiten, Sounder, Bildübertragung,
// Heard-Liste), Protokolle und die Sendesteuerung entfallen. Die Zeichen gehen wie im fldigi-Monitor (nicht
// „gerichtet“) in den Empfangstext. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "fsq_rx.h"

#include "fsq_varicode.inc"

#define SQLFILT_SIZE 64

#define NIT std::string::npos
#define txcenterfreq  1500.0

int fsq::symlen = 4096; // nominal symbol length; 3 baud

static const char *FSQBOL = " \n";
static const char *FSQEOL = "\n ";
static const char *FSQEOT = "  \b  ";

void fsq::init_nibbles()
{
	int nibble = 0;
	for (int i = 0; i < 199; i++) {
		nibble = floor(0.5 + (i - 99)/3.0);
		// allow for wrap-around (33 tones for 32 tone differences)
		if (nibble < 0) nibble += 33;
		if (nibble > 32) nibble -= 33;
		// adjust for +1 symbol at the transmitter
		nibble--;
		nibbles[i] = nibble;
	}
}

fsq::fsq(trx_mode md) : fam_modem_base() // ABWEICHUNG fldigi (Digidec): Basisklasse
{
	frequency = 1500; // default Rx/Tx center frequency (ABWEICHUNG fldigi (Digidec): ohne modem::set_freq)

	mode = md;
	samplerate = SR;
	fft = new g_fft<double>(FFTSIZE);
	snfilt = new Cmovavg(SQLFILT_SIZE);

	noisefilt = new Cmovavg(32);
	sigfilt = new Cmovavg(8);

//	baudfilt = new Cmovavg(3);
	movavg_size = progdefaults.fsq_movavg;
	if (movavg_size < 1) movavg_size = progdefaults.fsq_movavg = 1;
	if (movavg_size > MOVAVGLIMIT) movavg_size = progdefaults.fsq_movavg = MOVAVGLIMIT;
	for (int i = 0; i < NUMBINS; i++) binfilt[i] = new Cmovavg(movavg_size);
	spacing = 3;
	txphase = 0;
	basetone = 333;

	picfilter = new C_FIR_filter();
	picfilter->init_lowpass(257, 1, 500.0 / samplerate);
	phase = 0;
	phidiff = 2.0 * M_PI * frequency / samplerate;
	prevz = cmplx(0,0);

	bkptr = 0;
	peak_counter = 0;
	peak = last_peak = 0;
	max = 0;
	curr_nibble = prev_nibble = 0;
	s2n = 0;
	ch_sqlch_open = false;
	metric = 0;
	memset(rx_stream, 0, sizeof(rx_stream));
	rx_text.clear();

	for (int i = 0; i < BLOCK_SIZE; i++)
		a_blackman[i] = blackman(1.0 * i / BLOCK_SIZE);

	fsq_tx_image = false;

	init_nibbles();

	// ABWEICHUNG fldigi (Digidec): Alterung, Anzeige und Protokolle entfallen
	restart();
}

fsq::~fsq()
{
	delete fft;
	delete snfilt;
	delete sigfilt;
	delete noisefilt;
	for (int i = 0; i < NUMBINS; i++)
		delete binfilt[i];
	delete picfilter;   // ABWEICHUNG fldigi (Digidec): Fenster, Sounder, Alterung und Protokolle entfallen
};

void  fsq::tx_init()
{
	tone = prevtone = 0;
	txphase = 0;
	send_bot = true;
	videoText();
}

void  fsq::rx_init()
{
	set_freq(frequency);
	bandwidth = 33 * spacing * samplerate / FSQ_SYMLEN;
	bkptr = 0;
	peak_counter = 0;
	peak = last_peak = 0;
	max = 0;
	curr_nibble = prev_nibble = 0;
	s2n = 0;
	ch_sqlch_open = false;
	metric = 0;
	memset(rx_stream, 0, sizeof(rx_stream));

	rx_text.clear();
	for (int i = 0; i < NUMBINS; i++) {
		tones[i] = 0.0;
		binfilt[i]->reset();
	}

	pixel = 0;
	amplitude = 0;
	phase = 0;
	prevz = cmplx(0,0);
	image_counter = 0;
	RXspp = 10; // 10 samples per pixel
	state = TEXT;
}

void fsq::set_freq(double f)
{
	frequency = f;
	// ABWEICHUNG fldigi (Digidec): modem::set_freq entfällt
	basetone = ceil(1.0*(frequency - bandwidth / 2) * FSQ_SYMLEN / samplerate);
	tx_basetone = ceil((frequency - bandwidth / 2) * FSQ_SYMLEN / samplerate );
	int incr = basetone % spacing;
	basetone -= incr;
	tx_basetone -= incr;
}

void fsq::adjust_for_speed()
{
	speed = progdefaults.fsqbaud;

	if( speed == 1.5 ) {
	        symlen = 8192;
	} else if (speed == 2.0) {
		symlen = 6144;
	} else if (speed == 3.0) {
		symlen = 4096;
	} else if (speed == 4.5) {
		symlen = 3072;
	} else { // speed == 6
		symlen = 2048;
	}
}

void fsq::restart()
{
	set_freq(frequency);

	peak_hits = progdefaults.fsqhits;
	adjust_for_speed();

	movavg_size = progdefaults.fsq_movavg;
	if (movavg_size < 1) movavg_size = progdefaults.fsq_movavg = 1;
	if (movavg_size > MOVAVGLIMIT) movavg_size = progdefaults.fsq_movavg = MOVAVGLIMIT;

	for (int i = 0; i < NUMBINS; i++) binfilt[i]->setLength(movavg_size);


}

bool fsq::valid_char(int ch)
{
	if ( ch ==  10 || ch == 163 || ch == 176 ||
		ch == 177 || ch == 215 || ch == 247 ||
		(ch > 31 && ch < 128))
		return true;
	return false;
}

bool fsq::fsq_squelch_open()
{
	return (ch_sqlch_open || 
			metric >= progStatus.sldrSquelchValue  ||
			state == IMAGE);
}

void fsq::lf_check(int ch)
{
	static char lfpair[3] = "01";
	static char bstrng[4] = "012";

	lfpair[0] = lfpair[1];
	lfpair[1] = 0xFF & ch;

	bstrng[0] = bstrng[1];
	bstrng[1] = bstrng[2];
	bstrng[2] = 0xFF & ch;

	b_bot = b_eol = b_eot = false;
	if (bstrng[0] == FSQEOT[0]    // find SP SP BS SP
		&& bstrng[1] == FSQEOT[1]
		&& bstrng[2] == FSQEOT[2]
		) {
		b_eot = true;
	} else if (lfpair[0] == FSQBOL[0] && lfpair[1] == FSQBOL[1]) {
		b_bot = true;
	} else if (lfpair[0] == FSQEOL[0] && lfpair[1] == FSQEOL[1]) {
		b_eol = true;
	}
}

// ABWEICHUNG fldigi (Digidec): process_symbol ohne Protokolle, Monitor-Anzeige und parse_rx_text; die Zeichen gehen wie im fldigi-Monitor
// (nicht „gerichtet“) in den Empfangstext
static void fsq_emit(fam_modem_base *m, int ch)
{
	if (ch == 10 || ch == 163 || ch == 176 || ch == 177 || ch == 215 || ch == 247 || (ch > 31 && ch < 128))
		m->put_rx_char(ch);
}

void fsq::process_symbol(int sym)
{
	int nibble = 0;
	int curr_ch = -1;

	symbol = sym;

	nibble = symbol - prev_symbol;
	if (nibble < -99 || nibble > 99) {
		prev_symbol = symbol;
		return;
	}
	nibble = nibbles[nibble + 99];

// -1 is our idle symbol, indicating we already have our symbol
	if (nibble >= 0) { // process nibble
		curr_nibble = nibble;

// single-nibble characters
		if ((prev_nibble < 29) & (curr_nibble < 29)) {
			curr_ch = wsq_varidecode[prev_nibble];

// double-nibble characters
		} else if ( (prev_nibble < 29) &&
					 (curr_nibble > 28) &&
					 (curr_nibble < 32)) {
			curr_ch = wsq_varidecode[prev_nibble * 32 + curr_nibble];
		}
		if (curr_ch > 0) {
			lf_check(curr_ch);

			if (b_bot) {
				ch_sqlch_open = true;
				rx_text.clear();
			}

			if (fsq_squelch_open()) {
				if (b_bot) fsq_emit(this, 10);
				if (b_eol) {
					noisefilt->reset();
					noisefilt->run(1);
					sigfilt->reset();
					sigfilt->run(1);
				}
				if (b_eot) {
					noisefilt->reset();
					noisefilt->run(1);
					sigfilt->reset();
					sigfilt->run(1);
				}
				if (!b_bot && !b_eot) fsq_emit(this, curr_ch);
			}

			if (fsq_squelch_open() && (b_eot || b_eol)) {
				ch_sqlch_open = false;
				metric = 0;
			}
		}
		prev_nibble = curr_nibble;
	}

	prev_symbol = symbol;
}

void fsq::process_tones()
{
	max = 0;
	peak = NUMBINS / 2;

// examine FFT bin contents over bandwidth +/- ~ 50 Hz
	int firstbin = frequency * FSQ_SYMLEN / samplerate - NUMBINS / 2;

	double sigval = 0;

	double min = 3.0e8;
    int minbin = NUMBINS / 2;

	for (int i = 0; i < NUMBINS; ++i) {
		val = norm(fft_data[i + firstbin]);
// looking for maximum signal
		tones[i] = binfilt[i]->run(val);
		if (tones[i] > max) {
			max = tones[i];
			peak = i;
		}
// looking for minimum signal in a 3 bin sequence
        if (tones[i] < min) {
            min = tones[i];
            minbin = i;
        }
	}

	sigval = tones[(peak-1) < 0 ? (NUMBINS - 1) : (peak - 1)] + 
             tones[peak] + 
             tones[(peak+1) == NUMBINS ? 0 : (peak + 1)];

	min = tones[(minbin-1) < 0 ? (NUMBINS - 1) : (minbin - 1)] + 
          tones[minbin] + 
          tones[(minbin+1) == NUMBINS ? 0 : (minbin + 1)];

	if (min == 0) min = 1e-10;

	s2n = 10 * log10( snfilt->run(sigval/min)) - 34.0 + movavg_size / 4;

	if (s2n <= 0) metric = 2 * (25 + s2n);
	if (s2n > 0) metric = 50 * ( 1 + s2n / 45);
	metric = clamp(metric, 0, 100);

	display_metric(metric);

	if (metric < progStatus.sldrSquelchValue && ch_sqlch_open)
		ch_sqlch_open = false;

// requires consecutive hits
	if (peak == prev_peak) {
		peak_counter++;
	} else {
		peak_counter = 0;
	}

	if ((peak_counter >= peak_hits) &&
		(peak != last_peak) &&
		(fsq_squelch_open() || !progStatus.sqlonoff)) {
		process_symbol(peak);
		peak_counter = 0;
		last_peak = peak;
	}

	prev_peak = peak;
}

int fsq::rx_process(const double *buf, int len)
{
	if (peak_hits != progdefaults.fsqhits) restart();
	if (movavg_size != progdefaults.fsq_movavg) restart();
	if (speed != progdefaults.fsqbaud) restart();

	if (bkptr < 0) bkptr = 0;
	if (bkptr >= SHIFT_SIZE) bkptr = 0;

	if (len > 512) {
		LOG_ERROR("fsq rx stream overrun %d", len);
	}

	while (len) {
		if (false) {   // ABWEICHUNG fldigi (Digidec): Bildempfang entfällt
			len--;
			buf++;
		} else {
			rx_stream[BLOCK_SIZE + bkptr] = *buf;
			len--;
			buf++;
			bkptr++;

			if (bkptr == SHIFT_SIZE) {
				bkptr = 0;
				memmove(rx_stream,							// to
						&rx_stream[SHIFT_SIZE],				// from
						BLOCK_SIZE*sizeof(*rx_stream));	// # bytes
                // fft_data gets overwritten each time with a fixed number of
                // elements. Do we need to zero it out?
				//memset(fft_data, 0, sizeof(fft_data));
				for (int i = 0; i < BLOCK_SIZE; i++) {
					double d = rx_stream[i] * a_blackman[i];
					fft_data[i] = cmplx(d, d);
				}
				fft->ComplexFFT(fft_data);
				process_tones();
			}
		}
	}
	return 0;
}

void fsq::send_tone(int tone)
{
	double phaseincr;
	double freq;

	if (speed != progdefaults.fsqbaud) restart();

	freq = (tx_basetone + tone * spacing) * samplerate / FSQ_SYMLEN;
	phaseincr = 2.0 * M_PI * freq / samplerate;
	prevtone = tone;

	int send_symlen = symlen;
	if (fsq_tx_image) send_symlen = 4096; // must use 3 baud symlen for image xfrs

	for (int i = 0; i < send_symlen; i++) {
		outbuf[i] = cos(txphase);
		txphase -= phaseincr;
		if (txphase < 0) txphase += TWOPI;
	}
	ModulateXmtr(outbuf, send_symlen);
}

void fsq::send_symbol(int sym)
{

	tone = (prevtone + sym + 1) % 33;
	send_tone(tone);
}

void fsq::send_idle()
{
	send_symbol(28);
	send_symbol(30);
}

void fsq::send_char(int ch)
{
	if (!ch) return send_idle();

	int sym1 = fsq_varicode[ch][0];
	int sym2 = fsq_varicode[ch][1];

	send_symbol(sym1);
	if (sym2 > 28)
		send_symbol(sym2);

}

void fsq::send_string(std::string s)
{
	for (size_t n = 0; n < s.length(); n++)
		send_char(s[n]);
}

// ABWEICHUNG fldigi (Digidec): init() ohne modem::init() und Sounder; Trägerfrequenz setzt Digidec
void fsq::init()
{
	rx_init();
}

