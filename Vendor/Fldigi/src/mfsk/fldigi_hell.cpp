// ----------------------------------------------------------------------------
// fldigi_hell.cpp  --  C-Schnittstelle zum Feld-Hell-Empfänger (Digidec)
// ----------------------------------------------------------------------------
#include "fldigi_hell.h"
#include "feld_rx.h"

struct fldigi_hell {
	feld *rx = nullptr;
	fldigi_hell_config cfg;
	std::vector<double> block;
	fldigi_hell_column_fn on_column = nullptr;
	void *ctx = nullptr;
	int repeat = 2;

	// Rückruf der Basisklasse: HellRcvWidth-fach ausgeben (fldigi wiederholt die Spalte im Aufrufer; hier im Rückruf)
	static void relay(void *p, const int *data, int len) {
		fldigi_hell *h = (fldigi_hell *)p;
		if (h->on_column) h->on_column(h->ctx, data, len);
	}

	static trx_mode modeFor(int m) {
		switch (m) {
		case FLDIGI_HELL_SLOW:    return MODE_SLOWHELL;
		case FLDIGI_HELL_X5:      return MODE_HELLX5;
		case FLDIGI_HELL_X9:      return MODE_HELLX9;
		case FLDIGI_HELL_FSKH245: return MODE_FSKH245;
		case FLDIGI_HELL_FSKH105: return MODE_FSKH105;
		case FLDIGI_HELL_80:      return MODE_HELL80;
		default:                  return MODE_FELDHELL;
		}
	}

	void build(int m, double center) {
		rx = new feld(modeFor(m));
		rx->on_column = &fldigi_hell::relay;
		rx->on_char_ctx = this;
		rx->wf_.carrier = center;
		rx->init();
		rx->set_freq(center);
	}

	void apply(const fldigi_hell_config *c) {
		cfg = *c;
		rx->progStatus_.sqlonoff = c->squelch_on != 0;
		rx->progStatus_.sldrSquelchValue = c->squelch;
		rx->reverse = c->reverse != 0;
		rx->progdefaults_.HellBlackboard = c->blackboard != 0;
		int h = c->column_height < 4 ? 4 : c->column_height > MAX_RX_COLUMN_LEN ? MAX_RX_COLUMN_LEN : c->column_height;
		rx->progdefaults_.HellRcvHeight = h;
		rx->progdefaults_.HellRcvWidth = c->column_repeat < 1 ? 1 : c->column_repeat > 4 ? 4 : c->column_repeat;
		rx->progdefaults_.hellagc = c->agc < 1 ? 1 : c->agc > 3 ? 3 : c->agc;
		rx->restart();   // Spaltenlänge, Pixelrate, Filterbreite der Betriebsart
		if (c->filter_hz > 0) {
			rx->progdefaults_.HELL_BW = c->filter_hz;      // rx_process stellt das Filter um
		} else {
			rx->progdefaults_.HELL_BW = rx->filter_bandwidth;
		}
	}

	static double filterOf(const feld *r) { return r->filter_bandwidth; }
	static int colLen(const feld *r) { return r->RxColumnLen; }

	static void synthesize(int m, const char *text, double center, std::vector<float> &buf) {
		feld t(modeFor(m));
		t.tx_sink = &buf;
		t.wf_.carrier = center;
		t.init();
		t.set_freq(center);
		t.tx_init();
		for (int i = 0; i < 3; i++) t.tx_char('.');
		for (const char *p = text; *p; p++) {
			char ch = *p;
			if (ch == '\r' || ch == '\n') ch = ' ';
			t.tx_char(ch);
		}
		for (int i = 0; i < 3; i++) t.tx_char('.');
		t.tx_char(' ');
	}
};

extern "C" fldigi_hell_config fldigi_hell_default_config(void)
{
	fldigi_hell_config c;
	c.mode = FLDIGI_HELL_FELD;
	c.squelch_on = 1;
	c.squelch = 5;
	c.reverse = 0;
	c.blackboard = 0;
	c.column_height = 20;
	c.column_repeat = 2;
	c.agc = 2;
	c.filter_hz = 0;
	return c;
}

extern "C" fldigi_hell *fldigi_hell_create(const fldigi_hell_config *cfg, double center_hz, fldigi_hell_column_fn on_column, void *ctx)
{
	fldigi_hell *p = new fldigi_hell;
	p->on_column = on_column;
	p->ctx = ctx;
	p->build(cfg->mode, center_hz);
	p->apply(cfg);
	return p;
}

extern "C" void fldigi_hell_destroy(fldigi_hell *p)
{
	if (!p) return;
	delete p->rx;
	delete p;
}

extern "C" void fldigi_hell_configure(fldigi_hell *p, const fldigi_hell_config *cfg)
{
	if (cfg->mode != p->cfg.mode) {
		double f = p->rx->frequency;
		delete p->rx;
		p->build(cfg->mode, f);
	}
	p->apply(cfg);
}

extern "C" void fldigi_hell_process(fldigi_hell *p, const float *samples, int count)
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

extern "C" void fldigi_hell_set_center(fldigi_hell *p, double hz)
{
	p->rx->wf_.carrier = hz;
	p->rx->set_freq(hz);
}

extern "C" void fldigi_hell_get_status(const fldigi_hell *p, fldigi_hell_status *out)
{
	out->center_hz = p->rx->frequency;
	out->metric = p->rx->metric;
	out->bandwidth_hz = p->rx->bandwidth;
	out->filter_hz = fldigi_hell::filterOf(p->rx);
	out->column_height = fldigi_hell::colLen(p->rx);
}

extern "C" int fldigi_hell_synthesize(int mode, const char *text, double center_hz, float *out, int max_samples)
{
	std::vector<float> buf;
	fldigi_hell::synthesize(mode, text, center_hz, buf);
	if ((int)buf.size() > max_samples) return -1;
	for (size_t i = 0; i < buf.size(); i++) out[i] = buf[i];
	return (int)buf.size();
}
