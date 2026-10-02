// ----------------------------------------------------------------------------
// ifkp_rx.cpp  --  IFKP-Empfänger aus fldigi 4.2.13 (src/ifkp/ifkp.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2015 Dave Freese, W1HKJ (IFKP: Incremental Frequency Keying Plus, Murray Greenman ZL1BPU). GNU GPL v3.
// ABWEICHUNG fldigi (Digidec): Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen, außer wie unten
// vermerkt. Bild- und Avatar-Senden und -Anzeige, Heard- und Audit-Protokolle, Rufzeichenliste und die Sendesteuerung
// (tx_process) entfallen. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "ifkp_rx.h"

#define IFKP_SR 16000

#include "ifkp_varicode.inc"

static char sz[21];

int ifkp::IMAGEspp = IMAGESPP;
std::string ifkp::imageheader;
std::string ifkp::avatarheader;

int no_signal = 0;

void ifkp::init_nibbles()
{
	int nibble = 0;
	for (int i = 0; i < 199; i++) {
		nibble = floor(0.5 + (i - 99.0)/IFKP_SPACING);
		// allow for wrap-around (33 tones for 32 tone differences)
		if (nibble < 0) nibble += 33;
		if (nibble > 32) nibble -= 33;
		// adjust for +1 symbol at the transmitter
		nibble--;
		nibbles[i] = nibble;
	}
}

ifkp::ifkp(trx_mode md) : fam_modem_base() // ABWEICHUNG fldigi (Digidec): Basisklasse
{
	samplerate = IFKP_SR;
	symlen = IFKP_SYMLEN;

	cap |= CAP_IMG;

	if (progdefaults.StartAtSweetSpot) {
		frequency = progdefaults.PSKsweetspot;
	} else
		frequency = wf->Carrier();
	// ABWEICHUNG fldigi (Digidec): Frequenzanzeige entfällt

	mode = md;
	fft = new g_fft<double>(IFKP_FFTSIZE);
	snfilt = new Cmovavg(32);
	movavg_size = 4;
	for (int i = 0; i < IFKP_NUMBINS; i++) binfilt[i] = new Cmovavg(movavg_size);
	txphase = 0;
	basetone = 197;

	float lo = frequency - 0.75 * bandwidth;
	float hi = frequency + 0.75 * bandwidth;

	rxfilter = new C_FIR_filter();
	rxfilter->init_bandpass(129, 1, lo/samplerate, hi/samplerate);

	picfilter = new C_FIR_filter();
	picfilter->init_lowpass(129, 1, 2.0 * bandwidth / samplerate);

	phase = 0;
	phidiff = 2.0 * M_PI * frequency / samplerate;

	IMAGEspp = IMAGESPP;
	pixfilter = new Cmovavg(IMAGEspp / 2);
	ampfilter = new Cmovavg(IMAGEspp);
	syncfilter = new Cmovavg(IMAGEspp / 2);

	bkptr = 0;
	peak_counter = 0;
	peak = last_peak = 0;
	max = 0;
	curr_nibble = prev_nibble = 0;
	s2n = 0;

	memset(rx_stream, 0, sizeof(rx_stream));
	rx_text.clear();

	for (int i = 0; i < IFKP_BLOCK_SIZE; i++)
		a_blackman[i] = blackman(1.0 * i / IFKP_BLOCK_SIZE);

	state = TEXT;

	init_nibbles();

	TX_IMAGE = TX_AVATAR = false;

	restart();

	// ABWEICHUNG fldigi (Digidec): Protokolle und Bildmenü entfallen

}

ifkp::~ifkp()
{
	delete fft;
	delete snfilt;
	delete rxfilter;
	delete picfilter;
	for (int i = 0; i < IFKP_NUMBINS; i++)
		delete binfilt[i];
	// ABWEICHUNG fldigi (Digidec): Bildfenster, Protokolle und Bildmenü entfallen

}

void  ifkp::tx_init()
{
	tone = prevtone = 0;
	txphase = 0;
	send_bot = true;
	videoText();
}

void  ifkp::rx_init()
{
	bkptr = 0;
	peak_counter = 0;
	peak = last_peak = 0;
	max = 0;
	curr_nibble = prev_nibble = 0;
	s2n = 0;

	memset(rx_stream, 0, sizeof(rx_stream));

	prevz = cmplx(0,0);
	image_counter = 0;
	state = TEXT;

	rx_text.clear();
	for (int i = 0; i < IFKP_NUMBINS; i++) {
		tones[i] = 0.0;
		binfilt[i]->reset();
	}
	pixel = 0;
	pic_str = "     ";
}

void ifkp::rx_reset()
{
	prevz = cmplx(0,0);
	image_counter = 0;
	pixel = 0;
	pic_str = "     ";
	snfilt->reset();
	state = TEXT;
}

void ifkp::set_freq(double f)
{
	if (progdefaults.ifkp_freqlock)
		frequency = 1500;
	else
		frequency = f;

	if (frequency < 100 + 0.5 * bandwidth) frequency = 100 + 0.5 * bandwidth;
	if (frequency > 3900 - 0.5 * bandwidth) frequency = 3900 - 0.5 * bandwidth;

	tx_frequency = frequency;

	// ABWEICHUNG fldigi (Digidec): Frequenzanzeige entfällt

	set_bandwidth(33 * IFKP_SPACING * samplerate / symlen);

	basetone = ceil((frequency - bandwidth / 2.0) * symlen / samplerate);

	float lo = frequency - 0.75 * bandwidth;
	float hi = frequency + 0.75 * bandwidth;

	rxfilter->init_bandpass(129, 1, lo/samplerate, hi/samplerate);
	picfilter->init_lowpass(129, 1, 2.0 * bandwidth / samplerate);

	phase = 0;
	phidiff = 2.0 * M_PI * frequency / samplerate;

	// ABWEICHUNG fldigi (Digidec): Protokollausgabe entfällt
}

void ifkp::restart()
{
	set_freq(wf->Carrier());

	peak_hits = 4;

	movavg_size = progdefaults.ifkp_baud == 2 ? 3 : 4;

	for (int i = 0; i < IFKP_NUMBINS; i++) binfilt[i]->setLength(movavg_size);


}

bool ifkp::valid_char(int ch)
{
	if ( ! (ch ==  10 || ch == 163 || ch == 176 ||
		ch == 177 || ch == 215 || ch == 247 ||
		(ch > 31 && ch < 128)))
		return false;
	return true;
}

void ifkp::parse_pic(int ch)
{
	b_ava = false;
	image_mode = 0;

	pic_str.erase(0,1);
	pic_str += ch;

	if (pic_str.find("pic%") == 0) {
		switch (pic_str[4]) {
			case 'A':	picW = 59; picH = 74; b_ava = true; break;
			case 'T':	picW = 59; picH = 74; break;
			case 't':	picW = 59; picH = 74; image_mode = 1; break;
			case 'S':	picW = 160; picH = 120; break;
			case 's':	picW = 160; picH = 120; image_mode = 1; break;
			case 'L':	picW = 320; picH = 240; break;
			case 'l':	picW = 320; picH = 240; image_mode = 1; break;
			case 'V':	picW = 640; picH = 480; break;
			case 'v':	picW = 640; picH = 480; image_mode = 1; break;
			case 'F':	picW = 640; picH = 480; image_mode = 1; break;
			case 'P':	picW = 240; picH = 300; break;
			case 'p':	picW = 240; picH = 300; image_mode = 1; break;
			case 'M':	picW = 120; picH = 150; break;
			case 'm':	picW = 120; picH = 150; image_mode = 1; break;
			default: 
				syncfilter->reset();
				pixfilter->reset();
				ampfilter->reset();
				return;
		}
	} else
		return;

	if (!b_ava)
		;   // ABWEICHUNG fldigi (Digidec): Bildanzeige entfällt
	else
		;   // ABWEICHUNG fldigi (Digidec): Avatar-Anzeige entfällt

	image_counter = -symlen / 2;
	col = row = rgb = 0;
	syncfilter->reset();
	pixfilter->reset();
//	ampfilter->reset();
	state = IMAGE_START;
}

// ABWEICHUNG fldigi (Digidec): process_symbol ohne Protokolle und Rufzeichenliste (Zeichen gehen an put_rx_char)
void ifkp::process_symbol(int sym)
{
	int nibble = 0;
	int curr_ch = -1	;

	symbol = sym;

	nibble = symbol - prev_symbol;
	if (nibble < -99 || nibble > 99) {
		prev_symbol = symbol;
		return;
	}
	nibble = nibbles[nibble + 99];

	if (nibble >= 0) { // process nibble
		curr_nibble = nibble;

// single-nibble characters
		if ((prev_nibble < 29) & (curr_nibble < 29)) {
			curr_ch = ifkp_varidecode[prev_nibble];

// double-nibble characters
		} else if ( (prev_nibble < 29) &&
					 (curr_nibble > 28) &&
					 (curr_nibble < 32)) {
			curr_ch = ifkp_varidecode[prev_nibble * 32 + curr_nibble];
		}
		if (curr_ch > 0) {
			if (ch_sqlch_open || metric >= progStatus.sldrSquelchValue) {
				put_rx_char(curr_ch);
				parse_pic(curr_ch);
			}
		}
		prev_nibble = curr_nibble;
	}

	prev_symbol = symbol;
}

void ifkp::process_tones()
{
	max = 0;
	peak = 0;

	max = 0;
	peak = IFKP_NUMBINS / 2;

	int firstbin = frequency * IFKP_SYMLEN / samplerate - IFKP_NUMBINS / 2;
	double sigval = 0;
	double min = 3.0e8;

	for (int i = 0; i < IFKP_NUMBINS; ++i) {
		val = norm(fft_data[i + firstbin]);
// search for minimum and maximum signalx
		tones[i] = binfilt[i]->run(val);
		if (tones[i] > max) {
			max = tones[i];
			peak = i;
		}
		if (tones[i] < min) {
			min = tones[i];
		}
	}

	if (peak == prev_peak) {
		peak_counter++;
	} else {
		peak_counter = 0;
	}

	if ((peak_counter >= peak_hits) &&
		(peak != last_peak)) {
		sigval = (tones[peak-1] + tones[peak] + tones[peak+1]);
		if (min == 0) min = max / 1000;
		if (min > 0 && max > 0) {
			s2n = 20 * log10( snfilt->run(sigval/min));
			s2n -= 64;
			s2n *= 40;
			s2n /= 75;
			s2n -= 20;
		} else
			s2n = -25;

//scale to -25 to +45 db range
// -25 -> 0 linear
// 0 - > 45 compressed by 2

		if (s2n <= 0) metric = 2 * (25 + s2n);
		if (s2n > 0) metric = 50 * ( 1 + s2n / 45);
			metric = clamp(metric, 0, 100);

		display_metric(metric);

		if (metric >= progStatus.sldrSquelchValue ||
			progStatus.sqlonoff == false) { //) {
			process_symbol(peak);
		}
		peak_counter = 0;
		last_peak = peak;
		no_signal = 0;
	} else if (++no_signal > 128) { // reset the filter and zero the s/n display
		snfilt->reset();
		display_metric(0);
	}

	prev_peak = peak;
}

void ifkp::recvpic(double smpl)
{
	phidiff = 2.0 * M_PI * frequency / samplerate;
	phase -= phidiff;
	if (phase < 0) phase += 2.0 * M_PI;

	cmplx z = smpl * cmplx( cos(phase), sin(phase ) );
	picfilter->run( z, currz);
	pixel = (samplerate / TWOPI) * pixfilter->run(arg(conj(prevz) * currz));
	sync = (samplerate / TWOPI) * syncfilter->run(arg(conj(prevz) * currz));

	prevz = currz;

	image_counter++;

	if (image_counter < 0) return;

	if (state == IMAGE_START) {
		if (sync < -0.59 * bandwidth) {
			state = IMAGE_SYNC;
				}
		return;
	}
	if (state == IMAGE_SYNC) {
		if (sync > -0.51 * bandwidth) {
			state = IMAGE;
		}
		return;
	}

	if ((image_counter % IMAGEspp) == 0) {
		byte = pixel * 256.0 / bandwidth + 128;
		byte = (int)CLAMP( byte, 0.0, 255.0);

		if (image_mode == 1) { // bw transmission
			pixelnbr = 3 * (col + row * picW);
			if (b_ava) {
				(void)(byte, pixelnbr);
				(void)(byte, pixelnbr + 1);
				(void)(byte, pixelnbr + 2);
			} else {
				(void)(byte, pixelnbr);
				(void)(byte, pixelnbr + 1);
				(void)(byte, pixelnbr + 2);
			}
			if (++ col == picW) {
				col = 0;
				row++;
				if (row >= picH) {
					rx_reset();
					
				}
			}
		} else { // color transmission
			pixelnbr = rgb + 3 * (col + row * picW);
			if (b_ava)
				(void)(byte, pixelnbr);
			else
				(void)(byte, pixelnbr);
			if (++col == picW) {
				col = 0;
				if (++rgb == 3) {
					rgb = 0;
					++row;
				}
			}
			if (row >= picH) {
				rx_reset();
				
			}
		}
	}
}

int ifkp::rx_process(const double *buf, int len)
{
	double val;
	cmplx zin, z;

	if (bkptr < 0) bkptr = 0;
	if (bkptr >= IFKP_SHIFT_SIZE) bkptr = 0;

	while (len) {
		if (state == TEXT) {
			rxfilter->Irun(*buf, val);
			rx_stream[IFKP_BLOCK_SIZE + bkptr] = val;
			bkptr++;

			if (bkptr == IFKP_SHIFT_SIZE) {
				bkptr = 0;
				memmove(rx_stream,								// to
						&rx_stream[IFKP_SHIFT_SIZE],			// from
						IFKP_BLOCK_SIZE*sizeof(*rx_stream));	// # bytes

				for (int n = 0; n < 2*IFKP_FFTSIZE; n++)
					fft_data[n] = cmplx(0,0);

				for (int i = 0; i < IFKP_BLOCK_SIZE; i++) {
					double d = rx_stream[i] * a_blackman[i];
					fft_data[i] = cmplx(d,d);
				}
				fft->ComplexFFT(fft_data);
				process_tones();
			}
		} else
			recvpic(*buf);

		len--;
		buf++;
	}
	return 0;
}

void ifkp::transmit(double *buf, int len)
{
//	if (xmtfilt && progdefaults.ifkp_xmtfilter)
//		for (int i = 0; i < len; i++) xmtfilt->Irun(buf[i], buf[i]);
	ModulateXmtr(buf, len);
}

void ifkp::send_tone(int tone)
{
	double phaseincr;
	double frequency;

	frequency = (basetone + tone * IFKP_SPACING) * samplerate / symlen;
	phaseincr = 2.0 * M_PI * frequency / samplerate;
	prevtone = tone;

	int send_symlen = symlen * (
			progdefaults.ifkp_baud == 2 ? 0.5 :
			progdefaults.ifkp_baud == 0 ? 2.0 : 1.0);

	for (int i = 0; i < send_symlen; i++) {
		outbuf[i] = cos(txphase);
		txphase -= phaseincr;
		if (txphase < 0) txphase += TWOPI;
	}
	transmit(outbuf, send_symlen);
}

void ifkp::send_symbol(int sym)
{
	tone = (prevtone + sym + IFKP_OFFSET) % 33;
	send_tone(tone);
}

void ifkp::send_idle()
{
	send_symbol(0);
}

void ifkp::send_char(int ch)
{
	if (ch <= 0) return send_idle();

	int sym1 = ifkp_varicode[ch][0];
	int sym2 = ifkp_varicode[ch][1];

	send_symbol(sym1);
	if (sym2 > 28)
		send_symbol(sym2);
	put_echo_char(ch);
}

// ABWEICHUNG fldigi (Digidec): init() ohne Protokolle; Trägerfrequenz setzt Digidec
void ifkp::init()
{
	peak_hits = 4;
	movavg_size = 3;
	for (int i = 0; i < IFKP_NUMBINS; i++) binfilt[i]->setLength(movavg_size);
	rx_init();
}

