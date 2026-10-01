// ----------------------------------------------------------------------------
// fldigi_rtty.cpp  --  C-Schnittstelle zu rtty_rx (Digidec)
// ----------------------------------------------------------------------------
#include "fldigi_rtty.h"
#include "rtty_rx.h"

#define SCBLOCKSIZE 512   // fldigi src/include/sound.h: Blockgröße, in der rx_process aufgerufen wird

struct fldigi_rtty {
	rtty_rx *rx;
	double block[SCBLOCKSIZE];
	int fill;
};

static RTTYRxConfig to_rx(const fldigi_rtty_config *c)
{
	RTTYRxConfig r;
	r.shift = c->shift;
	r.baud = c->baud;
	r.bits = c->bits;
	r.parity = c->parity;
	r.stop_bits = c->stop_bits;
	r.reverse = c->reverse != 0;
	r.afc_on = c->afc_on != 0;
	r.afc_speed = c->afc_speed;
	r.squelch_on = c->squelch_on != 0;
	r.squelch = c->squelch;
	r.cwi = c->cwi;
	r.uos_rx = c->uos_rx != 0;
	r.ita2 = c->ita2 != 0;
	r.true_scope = c->true_scope != 0;
	r.filter_k = c->filter_k;
	r.low_cutoff = c->low_cutoff;
	r.high_cutoff = c->high_cutoff;
	return r;
}

extern "C" fldigi_rtty_config fldigi_rtty_default_config(void)
{
	RTTYRxConfig d;
	fldigi_rtty_config c;
	c.shift = d.shift;
	c.baud = d.baud;
	c.bits = d.bits;
	c.parity = d.parity;
	c.stop_bits = d.stop_bits;
	c.reverse = d.reverse;
	c.afc_on = d.afc_on;
	c.afc_speed = d.afc_speed;
	c.squelch_on = d.squelch_on;
	c.squelch = d.squelch;
	c.cwi = d.cwi;
	c.uos_rx = d.uos_rx;
	c.ita2 = d.ita2;
	c.true_scope = d.true_scope;
	c.filter_k = d.filter_k;
	c.low_cutoff = d.low_cutoff;
	c.high_cutoff = d.high_cutoff;
	return c;
}

extern "C" fldigi_rtty *fldigi_rtty_create(const fldigi_rtty_config *cfg, double center_hz,
                                           fldigi_rtty_char_fn on_char, void *ctx)
{
	fldigi_rtty *r = new fldigi_rtty;
	r->rx = new rtty_rx(to_rx(cfg), center_hz, on_char, ctx);
	r->fill = 0;
	return r;
}

extern "C" void fldigi_rtty_destroy(fldigi_rtty *r)
{
	if (!r) return;
	delete r->rx;
	delete r;
}

extern "C" void fldigi_rtty_configure(fldigi_rtty *r, const fldigi_rtty_config *cfg)
{
	r->rx->configure(to_rx(cfg));
	r->fill = 0;
}

extern "C" void fldigi_rtty_process(fldigi_rtty *r, const float *samples, int count)
{
	for (int i = 0; i < count; i++) {
		r->block[r->fill++] = samples[i];
		if (r->fill == SCBLOCKSIZE) {
			r->rx->rx_process(r->block, SCBLOCKSIZE);
			r->fill = 0;
		}
	}
}

extern "C" void fldigi_rtty_set_center(fldigi_rtty *r, double hz)
{
	r->rx->set_freq(hz);
}

extern "C" void fldigi_rtty_get_status(const fldigi_rtty *r, fldigi_rtty_status *out)
{
	out->center_hz = r->rx->get_freq();
	out->metric = r->rx->get_metric();
	out->snr_db = r->rx->get_snr_db();
	out->freq_error = r->rx->get_freqerr();
	out->mark_mag = r->rx->get_mark_mag();
	out->space_mag = r->rx->get_space_mag();
}

extern "C" int fldigi_rtty_get_scope(const fldigi_rtty *r, double *xy, int max_points)
{
	return r->rx->get_scope(xy, max_points);
}
