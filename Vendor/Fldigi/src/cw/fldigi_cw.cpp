// ----------------------------------------------------------------------------
// fldigi_cw.cpp  --  C-Schnittstelle zum CW-Empfänger (Digidec)
// ----------------------------------------------------------------------------
#include "fldigi_cw.h"
#include "cw_rx.h"

#define CW_BLOCK 512   // fldigi ruft rx_process blockweise auf

void cw_rx_reset_statics();   // cw_rx.cpp

struct fldigi_cw {
	cw *rx;
	double block[CW_BLOCK];
	int fill;
	static void sync(cw *rx) { rx->sync_parameters(); }
};

static void apply(cw *rx, const fldigi_cw_config *c)
{
	CwProgdefaults &p = rx->progdefaults_;
	p.CWspeed = c->speed_wpm;
	p.CWbandwidth = c->bandwidth_hz;
	p.CWmfilt = c->matched_filter != 0;
	p.CW_fillen = c->filter_length;
	p.CWtrack = c->track != 0;
	p.CWrange = c->range_wpm;
	p.CWlowerlimit = c->lower_wpm;
	p.CWupperlimit = c->upper_wpm;
	p.cwrx_attack = c->attack;
	p.cwrx_decay = c->decay;
	p.CWuseSOMdecoding = c->som_decoding != 0;
	p.CW_noise = c->noise_char;
	rx->progStatus_.sqlonoff = c->squelch_on != 0;
	rx->progStatus_.sldrSquelchValue = c->squelch;
}

extern "C" fldigi_cw_config fldigi_cw_default_config(void)
{
	CwProgdefaults d;
	fldigi_cw_config c;
	c.speed_wpm = d.CWspeed;
	c.bandwidth_hz = d.CWbandwidth;
	c.matched_filter = d.CWmfilt;
	c.filter_length = d.CW_fillen;
	c.track = d.CWtrack;
	c.range_wpm = d.CWrange;
	c.lower_wpm = d.CWlowerlimit;
	c.upper_wpm = d.CWupperlimit;
	c.attack = d.cwrx_attack;
	c.decay = d.cwrx_decay;
	c.som_decoding = d.CWuseSOMdecoding;
	c.squelch_on = 0;
	c.squelch = 0;
	c.noise_char = d.CW_noise;
	return c;
}

extern "C" fldigi_cw *fldigi_cw_create(const fldigi_cw_config *cfg, double center_hz, fldigi_cw_char_fn on_char, void *ctx)
{
	fldigi_cw *c = new fldigi_cw;
	cw_rx_reset_statics();  // wie beim ersten Anlegen in fldigi
	c->rx = new cw();
	c->fill = 0;
	apply(c->rx, cfg);
	c->rx->on_char = on_char;
	c->rx->on_char_ctx = ctx;
	c->rx->wf->carrier = center_hz;
	fldigi_cw::sync(c->rx);   // fldigi liest die Einstellungen schon im Konstruktor; hier erst nach apply()
	c->rx->init();          // wie fldigi beim Moduswechsel: Filter, Morsetabelle, Empfangszustand
	return c;
}

extern "C" void fldigi_cw_destroy(fldigi_cw *c)
{
	if (!c) return;
	delete c->rx;
	delete c;
}

/// Neue Einstellungen: reset_rx_filter() erkennt geänderte Bandbreite/Filterlänge/Matched Filter selbst
extern "C" void fldigi_cw_configure(fldigi_cw *c, const fldigi_cw_config *cfg)
{
	apply(c->rx, cfg);
	fldigi_cw::sync(c->rx);
}

extern "C" void fldigi_cw_process(fldigi_cw *c, const float *samples, int count)
{
	for (int i = 0; i < count; i++) {
		c->block[c->fill++] = samples[i];
		if (c->fill == CW_BLOCK) {
			c->rx->rx_process(c->block, CW_BLOCK);
			c->fill = 0;
		}
	}
}

/// fldigi: Klick in den Wasserfall setzt wf->Carrier(); reset_rx_filter() übernimmt ihn beim nächsten Block
extern "C" void fldigi_cw_set_center(fldigi_cw *c, double hz)
{
	c->rx->wf->carrier = hz;
}

extern "C" void fldigi_cw_get_status(const fldigi_cw *c, fldigi_cw_status *out)
{
	out->center_hz = c->rx->frequency;
	out->metric = c->rx->metric;
	out->rx_wpm = c->rx->rx_wpm;
	out->level = c->rx->scope_level;
}

extern "C" int fldigi_cw_get_scope(const fldigi_cw *c, double *values, int max_values)
{
	const std::vector<double> &s = c->rx->scope;
	int n = (int)s.size() < max_values ? (int)s.size() : max_values;
	for (int i = 0; i < n; i++) values[i] = s[i];
	return n;
}
