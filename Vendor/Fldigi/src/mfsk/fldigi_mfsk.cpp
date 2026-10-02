// ----------------------------------------------------------------------------
// fldigi_mfsk.cpp  --  C-Schnittstelle zu MFSK, DominoEX und Thor (Digidec)
// ----------------------------------------------------------------------------
#include "fldigi_mfsk.h"
#include "mfsk_rx.h"
#include "dominoex_rx.h"
#include "thor_rx.h"

struct fldigi_mfsk {
	fam_modem_base *rx = nullptr;
	fldigi_mfsk_config cfg;
	std::vector<double> block;
	void (*on_char)(void *, int) = nullptr;
	void *ctx = nullptr;

	// Die Klassen halten Zustand geschützt; die C-Hülle ist Freund
	static trx_mode modeFor(int m) {
		switch (m) {
		case FLDIGI_MFSK4:    return MODE_MFSK4;
		case FLDIGI_MFSK8:    return MODE_MFSK8;
		case FLDIGI_MFSK11:   return MODE_MFSK11;
		case FLDIGI_MFSK22:   return MODE_MFSK22;
		case FLDIGI_MFSK31:   return MODE_MFSK31;
		case FLDIGI_MFSK32:   return MODE_MFSK32;
		case FLDIGI_MFSK64:   return MODE_MFSK64;
		case FLDIGI_MFSK128:  return MODE_MFSK128;
		case FLDIGI_MFSK64L:  return MODE_MFSK64L;
		case FLDIGI_MFSK128L: return MODE_MFSK128L;
		case FLDIGI_DOMINOEXMICRO: return MODE_DOMINOEXMICRO;
		case FLDIGI_DOMINOEX4:  return MODE_DOMINOEX4;
		case FLDIGI_DOMINOEX5:  return MODE_DOMINOEX5;
		case FLDIGI_DOMINOEX8:  return MODE_DOMINOEX8;
		case FLDIGI_DOMINOEX11: return MODE_DOMINOEX11;
		case FLDIGI_DOMINOEX16: return MODE_DOMINOEX16;
		case FLDIGI_DOMINOEX22: return MODE_DOMINOEX22;
		case FLDIGI_DOMINOEX44: return MODE_DOMINOEX44;
		case FLDIGI_DOMINOEX88: return MODE_DOMINOEX88;
		case FLDIGI_THORMICRO: return MODE_THORMICRO;
		case FLDIGI_THOR4:     return MODE_THOR4;
		case FLDIGI_THOR5:     return MODE_THOR5;
		case FLDIGI_THOR8:     return MODE_THOR8;
		case FLDIGI_THOR11:    return MODE_THOR11;
		case FLDIGI_THOR22:    return MODE_THOR22;
		case FLDIGI_THOR25:    return MODE_THOR25;
		case FLDIGI_THOR32:    return MODE_THOR32;
		case FLDIGI_THOR44:    return MODE_THOR44;
		case FLDIGI_THOR56:    return MODE_THOR56;
		case FLDIGI_THOR100:   return MODE_THOR100;
		case FLDIGI_THOR25X4:  return MODE_THOR25x4;
		case FLDIGI_THOR50X1:  return MODE_THOR50x1;
		case FLDIGI_THOR50X2:  return MODE_THOR50x2;
		case FLDIGI_THOR16:    return MODE_THOR16;
		default:               return MODE_MFSK16;
		}
	}

	static bool isDomino(int m) { return m >= FLDIGI_DOMINOEXMICRO && m <= FLDIGI_DOMINOEX88; }
	static bool isThor(int m)   { return m >= FLDIGI_THORMICRO && m <= FLDIGI_THOR50X2; }

	static fam_modem_base *make(int m) {
		if (isDomino(m)) return new dominoex(modeFor(m));
		if (isThor(m))   return new thor(modeFor(m));
		return new mfsk(modeFor(m));
	}

	static void init(fam_modem_base *r, int m) {
		if (isDomino(m)) static_cast<dominoex *>(r)->init();
		else if (isThor(m)) static_cast<thor *>(r)->init();
		else static_cast<mfsk *>(r)->init();
	}

	static int tones(const fam_modem_base *r, int m) {
		if (isDomino(m)) return NUMTONES;
		if (isThor(m)) return THORNUMTONES;
		return static_cast<const mfsk *>(r)->numtones;
	}

	void build(int m, double center) {
		rx = make(m);
		rx->on_char = on_char;
		rx->on_sec_char = nullptr;
		rx->on_char_ctx = ctx;
		init(rx, m);
		rx->set_freq(center);
	}

	void apply(const fldigi_mfsk_config *c) {
		cfg = *c;
		rx->progStatus_.afconoff = c->afc != 0;
		rx->progStatus_.sqlonoff = c->squelch_on != 0;
		rx->progStatus_.sldrSquelchValue = c->squelch;
		rx->reverse = c->reverse != 0;
		rx->progdefaults_.DOMINOEX_FEC = c->fec != 0;
	}

	static void synthesize(int m, const char *text, double center, std::vector<float> &buf) {
		if (isDomino(m)) {
			dominoex d(modeFor(m));
			d.tx_sink = &buf;
			d.init();
			d.set_freq(center);
			d.tx_init();
			d.sendidle();
			d.sendchar('\r', 0);
			if (d.mode != MODE_DOMINOEXMICRO) { d.sendchar(2, 0); d.sendchar('\r', 0); }
			for (const char *p = text; *p; p++) d.sendchar((unsigned char)*p, 0);
			d.sendchar('\r', 0);
			if (d.mode != MODE_DOMINOEXMICRO) { d.sendchar(4, 0); d.sendchar('\r', 0); }
			d.flushtx();
		} else if (isThor(m)) {
			thor t(modeFor(m));
			t.tx_sink = &buf;
			t.init();
			t.set_freq(center);
			t.tx_init();
			t.Clearbits();
			for (int j = 0; j < 16; j++) t.sendsymbol(0);
			t.sendidle();
			t.sendchar('\r', 0);
			if (t.mode != MODE_THORMICRO) { t.sendchar(2, 0); t.sendchar('\r', 0); }
			for (const char *p = text; *p; p++) t.sendchar((unsigned char)*p, 0);
			t.sendchar('\r', 0);
			if (t.mode != MODE_THORMICRO) { t.sendchar(4, 0); t.sendchar('\r', 0); }
			t.flushtx();
		} else {
			mfsk x(modeFor(m));
			x.tx_sink = &buf;
			x.init();
			x.set_freq(center);
			x.tx_init();
			x.clearbits();
			if (x.mode != MODE_MFSK64L && x.mode != MODE_MFSK128L)
				for (int i = 0; i < x.preamble / 3; i++) x.sendbit(0);
			x.sendchar('\r'); x.sendchar(2); x.sendchar('\r');
			for (const char *p = text; *p; p++) x.sendchar((unsigned char)*p);
			x.sendchar('\r'); x.sendchar(4); x.sendchar('\r');
			x.flushtx(x.preamble);
		}
	}
};

extern "C" double fldigi_mfsk_sample_rate(int mode)
{
	switch (mode) {
	case FLDIGI_MFSK11: case FLDIGI_MFSK22:
	case FLDIGI_DOMINOEX5: case FLDIGI_DOMINOEX11: case FLDIGI_DOMINOEX22: case FLDIGI_DOMINOEX44: case FLDIGI_DOMINOEX88:
	case FLDIGI_THOR5: case FLDIGI_THOR11: case FLDIGI_THOR22: case FLDIGI_THOR44:
		return 11025.0;
	case FLDIGI_THOR56:
		return 16000.0;
	default:
		return 8000.0;
	}
}

extern "C" fldigi_mfsk_config fldigi_mfsk_default_config(void)
{
	FamProgStatus s;
	fldigi_mfsk_config c;
	c.mode = FLDIGI_MFSK16;
	c.afc = s.afconoff;
	c.fec = 0;
	c.squelch_on = s.sqlonoff;
	c.squelch = s.sldrSquelchValue;
	c.reverse = 0;
	return c;
}

extern "C" fldigi_mfsk *fldigi_mfsk_create(const fldigi_mfsk_config *cfg, double center_hz, fldigi_mfsk_char_fn on_char, void *ctx)
{
	fldigi_mfsk *p = new fldigi_mfsk;
	p->on_char = on_char;
	p->ctx = ctx;
	p->build(cfg->mode, center_hz);
	p->apply(cfg);
	return p;
}

extern "C" void fldigi_mfsk_destroy(fldigi_mfsk *p)
{
	if (!p) return;
	delete p->rx;
	delete p;
}

extern "C" void fldigi_mfsk_configure(fldigi_mfsk *p, const fldigi_mfsk_config *cfg)
{
	if (cfg->mode != p->cfg.mode) {
		double f = p->rx->frequency;
		delete p->rx;
		p->build(cfg->mode, f);
	}
	p->apply(cfg);
}

extern "C" void fldigi_mfsk_process(fldigi_mfsk *p, const float *samples, int count)
{
	const int N = 1024;
	p->block.resize(N);
	int i = 0;
	while (i < count) {
		int n = count - i < N ? count - i : N;
		for (int k = 0; k < n; k++) p->block[k] = samples[i + k];
		p->rx->rx_process(p->block.data(), n);
		i += n;
	}
}

extern "C" void fldigi_mfsk_set_center(fldigi_mfsk *p, double hz)
{
	p->rx->set_freq(hz);
}

extern "C" void fldigi_mfsk_get_status(const fldigi_mfsk *p, fldigi_mfsk_status *out)
{
	out->center_hz = p->rx->frequency;
	out->metric = p->rx->metric;
	out->bandwidth_hz = p->rx->bandwidth;
	out->sample_rate = p->rx->samplerate;
	out->tones = fldigi_mfsk::tones(p->rx, p->cfg.mode);
}

extern "C" int fldigi_mfsk_synthesize(int mode, const char *text, double center_hz, float *out, int max_samples)
{
	std::vector<float> buf;
	fldigi_mfsk::synthesize(mode, text, center_hz, buf);
	if ((int)buf.size() > max_samples) return -1;
	for (size_t i = 0; i < buf.size(); i++) out[i] = buf[i];
	return (int)buf.size();
}
