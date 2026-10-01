// ----------------------------------------------------------------------------
// fldigi_psk.cpp  --  C-Schnittstelle zum PSK-Empfänger (Digidec)
// ----------------------------------------------------------------------------
#include "fldigi_psk.h"
#include "psk_rx.h"

#define PSK_BLOCK 512   // fldigi ruft rx_process blockweise auf

void psk_rx_reset_statics();   // psk_rx.cpp

struct fldigi_psk {
	psk *rx;
	fldigi_psk_config cfg;
	double block[PSK_BLOCK];
	int fill;
	// psk hält Zustand privat; die C-Hülle ist Freund
	static void status(const psk *r, fldigi_psk_status *out) {
		out->center_hz = r->frequency;
		out->metric = r->metric;
		out->dcd = r->dcd ? 1 : 0;
		out->snr_db = 10.0 * log10(r->snratio > 1.0 ? r->snratio : 1.0);
		out->imd_db = 10.0 * log10(r->imdratio > 1e-6 ? r->imdratio : 1e-6);
		out->phase_quality = r->quality_;
		out->bandwidth_hz = r->samplerate / r->symbollen;
	}
};

static trx_mode modeFor(int m)
{
	switch (m) {
	case FLDIGI_PSK_BPSK63:  return MODE_PSK63;
	case FLDIGI_PSK_BPSK125: return MODE_PSK125;
	case FLDIGI_PSK_BPSK250: return MODE_PSK250;
	case FLDIGI_PSK_QPSK31:  return MODE_QPSK31;
	case FLDIGI_PSK_QPSK63:  return MODE_QPSK63;
	case FLDIGI_PSK_QPSK125: return MODE_QPSK125;
	case FLDIGI_PSK_QPSK250: return MODE_QPSK250;
	default:                 return MODE_PSK31;
	}
}

static void apply(fldigi_psk *p, const fldigi_psk_config *c)
{
	p->cfg = *c;
	p->rx->progStatus_.afconoff = c->afc != 0;
	p->rx->progStatus_.sqlonoff = c->squelch_on != 0;
	p->rx->progStatus_.sldrSquelchValue = c->squelch;
	p->rx->reverse = c->reverse != 0;
}

extern "C" fldigi_psk_config fldigi_psk_default_config(void)
{
	PskProgStatus s;
	fldigi_psk_config c;
	c.mode = FLDIGI_PSK_BPSK31;
	c.afc = s.afconoff;
	c.squelch_on = s.sqlonoff;
	c.squelch = s.sldrSquelchValue;
	c.reverse = 0;
	return c;
}

extern "C" fldigi_psk *fldigi_psk_create(const fldigi_psk_config *cfg, double center_hz, fldigi_psk_char_fn on_char, void *ctx)
{
	fldigi_psk *p = new fldigi_psk;
	psk_rx_reset_statics();
	p->rx = new psk(modeFor(cfg->mode));
	p->fill = 0;
	apply(p, cfg);
	p->rx->on_char = on_char;
	p->rx->on_char_ctx = ctx;
	p->rx->wf->carrier = center_hz;
	p->rx->init();          // wie fldigi beim Moduswechsel: setzt die Frequenz aus dem Wasserfall-Träger
	return p;
}

extern "C" void fldigi_psk_destroy(fldigi_psk *p)
{
	if (!p) return;
	delete p->rx;
	delete p;
}

extern "C" void fldigi_psk_configure(fldigi_psk *p, const fldigi_psk_config *cfg)
{
	apply(p, cfg);
}

extern "C" void fldigi_psk_process(fldigi_psk *p, const float *samples, int count)
{
	for (int i = 0; i < count; i++) {
		p->block[p->fill++] = samples[i];
		if (p->fill == PSK_BLOCK) {
			p->rx->rx_process(p->block, PSK_BLOCK);
			p->fill = 0;
		}
	}
}

/// fldigi: Klick in den Wasserfall setzt die Frequenz des Modems
extern "C" void fldigi_psk_set_center(fldigi_psk *p, double hz)
{
	p->rx->set_freq(hz);
}

extern "C" void fldigi_psk_get_status(const fldigi_psk *p, fldigi_psk_status *out)
{
	fldigi_psk::status(p->rx, out);
}

extern "C" int fldigi_psk_get_scope(const fldigi_psk *p, double *phase, double *amplitude, int max_values)
{
	const std::vector<psk_modem_base::ScopePoint> &s = p->rx->scope;
	int n = (int)s.size() < max_values ? (int)s.size() : max_values;
	int off = (int)s.size() - n;
	for (int i = 0; i < n; i++) { phase[i] = s[off + i].phase; amplitude[i] = s[off + i].amp; }
	return n;
}

// ----------------------------------------------------------------------------
// Testsignal: Sendeseite von fldigi psk.cxx (tx_carriers, tx_bit, tx_char, tx_flush, Vorspann) für einen Träger.
// Nur für Tests. Die Symbolabbildung (sym_vec_pos, Hüllkurve tx_shape) ist wörtlich aus fldigi.
// ----------------------------------------------------------------------------
static cmplx sym_vec_pos[16] = {
	cmplx (-1.0, 0.0),				// 180 degrees
	cmplx (-0.9238, -0.3826),		// 202.5 degrees
	cmplx (-0.7071, -0.7071),		// 225 degrees
	cmplx (-0.3826, -0.9238),		// 247.5 degrees
	cmplx (0.0, -1.0),				// 270 degrees
	cmplx (0.3826, -0.9238),		// 292.5 degrees
	cmplx (0.7071, -0.7071),		// 315 degrees
	cmplx (0.9238, -0.3826),		// 337.5 degrees
	cmplx (1.0, 0.0),				// 0 degrees
	cmplx (0.9238, 0.3826),			// 22.5 degrees
	cmplx (0.7071, 0.7071),			// 45 degrees
	cmplx (0.3826, 0.9238),			// 67.5 degrees
	cmplx (0.0, 1.0),				// 90 degrees
	cmplx (-0.3826, 0.9238),		// 112.5 degrees
	cmplx (-0.7071, 0.7071),		// 135 degrees
	cmplx (-0.9238, 0.3826) 		// 157.5 degrees
};

struct PskSynth {
	bool qpsk;
	int symbollen, dcdbits;
	double delta, phaseacc = 0;
	cmplx prev = cmplx(1.0, 0.0);
	std::vector<double> shape, out;
	encoder *enc = nullptr;

	PskSynth(int mode, double center) {
		qpsk = mode >= FLDIGI_PSK_QPSK31;
		int speed = mode % 4;                       // 31, 63, 125, 250
		symbollen = 256 >> speed;
		dcdbits = 32 << speed;
		delta = TWOPI * center / 8000.0;
		for (int i = 0; i < symbollen; i++) shape.push_back(0.5 * cos(i * M_PI / symbollen) + 0.5);   // tx_shape
		if (qpsk) enc = new encoder(5, 0x17, 0x19);   // K, POLY1, POLY2
	}
	~PskSynth() { delete enc; }

	void tx_symbol(int sym) {                       // tx_carriers()
		if (qpsk) sym = (4 - sym) & 3;              // reverse = false
		sym *= 4;                                   // BPSK und QPSK
		cmplx symbol = prev * sym_vec_pos[sym & 15];
		for (int i = 0; i < symbollen; i++) {
			double a = shape[i], b = 1.0 - a;
			double ival = a * prev.real() + b * symbol.real();
			double qval = a * prev.imag() + b * symbol.imag();
			out.push_back(ival * cos(phaseacc) + qval * sin(phaseacc));
			phaseacc += delta;
			if (phaseacc > TWOPI) phaseacc -= TWOPI;
		}
		prev = symbol;
	}
	void tx_bit(int bit) {
		if (qpsk) tx_symbol(enc->encode(bit) & 3);
		else tx_symbol(bit << 1);
	}
	void tx_char(unsigned char c) {
		const char *code = psk_varicode_encode(c);
		while (*code) { tx_bit(*code - '0'); code++; }
		tx_bit(0);
		tx_bit(0);
	}
	void flush() {
		if (qpsk) { for (int i = 0; i < dcdbits; i++) tx_bit(0); }
		else { for (int i = 0; i < dcdbits; i++) tx_symbol(2); }
	}
};

extern "C" int fldigi_psk_synthesize(int mode, const char *text, double center_hz, float *out, int max_samples)
{
	PskSynth s(mode, center_hz);
	for (int i = 0; i < s.dcdbits; i++) s.tx_symbol(0);     // Vorspann: Phasenumkehr
	for (const char *t = text; *t; t++) s.tx_char((unsigned char)*t);
	s.flush();
	if ((int)s.out.size() > max_samples) return -1;
	for (size_t i = 0; i < s.out.size(); i++) out[i] = (float)s.out[i];
	return (int)s.out.size();
}
