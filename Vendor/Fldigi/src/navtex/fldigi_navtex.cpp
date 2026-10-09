// ----------------------------------------------------------------------------
// fldigi_navtex.cpp  --  C-Schnittstelle zum NAVTEX-Empfänger (Digidec)
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include "fldigi_navtex.h"
#include "navtex_rx.h"

#define SCBLOCKSIZE 512   // fldigi src/include/sound.h: Blockgröße, in der rx_process aufgerufen wird

struct fldigi_navtex {
	navtex *nv;
	double block[SCBLOCKSIZE];
	int fill;
};

static NavtexConfig to_cfg(const fldigi_navtex_config *c)
{
	NavtexConfig r;
	r.sitor_b_only = c->sitor_b_only != 0;
	r.reverse = c->reverse != 0;
	r.afc_on = c->afc_on != 0;
	r.ita2 = c->ita2 != 0;
	r.min_msg = c->min_message_length > 0 ? (size_t)c->min_message_length : 0;
	return r;
}

extern "C" fldigi_navtex_config fldigi_navtex_default_config(void)
{
	NavtexConfig d;
	fldigi_navtex_config c;
	c.sitor_b_only = d.sitor_b_only;
	c.reverse = d.reverse;
	c.afc_on = d.afc_on;
	c.ita2 = d.ita2;
	c.min_message_length = (int)d.min_msg;
	return c;
}

extern "C" fldigi_navtex *fldigi_navtex_create(const fldigi_navtex_config *cfg, double center_hz,
                                               fldigi_navtex_char_fn on_char, fldigi_navtex_message_fn on_message, void *ctx)
{
	NavtexCallbacks cb;
	cb.on_char = on_char;
	cb.on_message = on_message;
	cb.ctx = ctx;
	fldigi_navtex *n = new fldigi_navtex;
	n->nv = new navtex(to_cfg(cfg), center_hz, cb);
	n->fill = 0;
	return n;
}

extern "C" void fldigi_navtex_destroy(fldigi_navtex *n)
{
	if (!n) return;
	delete n->nv;
	delete n;
}

extern "C" void fldigi_navtex_configure(fldigi_navtex *n, const fldigi_navtex_config *cfg)
{
	n->nv->configure(to_cfg(cfg));
}

extern "C" void fldigi_navtex_process(fldigi_navtex *n, const float *samples, int count)
{
	for (int i = 0; i < count; i++) {
		n->block[n->fill++] = samples[i];
		if (n->fill == SCBLOCKSIZE) {
			n->nv->rx_process(n->block, SCBLOCKSIZE);
			n->fill = 0;
		}
	}
}

extern "C" void fldigi_navtex_set_center(fldigi_navtex *n, double hz)
{
	n->nv->set_freq(hz);
}

extern "C" void fldigi_navtex_get_status(const fldigi_navtex *n, fldigi_navtex_status *out)
{
	out->center_hz = n->nv->get_freq();
	out->metric = n->nv->m_metric;
	out->snr_db = n->nv->m_snr;
	out->state = n->nv->m_state;
}

extern "C" int fldigi_navtex_load_stations(const char *data_dir)
{
	return navtex_load_stations(data_dir ? data_dir : "") ? 1 : 0;
}

extern "C" int fldigi_navtex_find_station(char origin, double frequency_hz, const char *locator, const char *message,
                                          char *out, int out_size)
{
	std::string res;
	if (!navtex_find_station(origin, frequency_hz, locator ? locator : "", message ? message : "", res)) return 0;
	if (out && out_size > 0) {
		strncpy(out, res.c_str(), out_size - 1);
		out[out_size - 1] = '\0';
	}
	return 1;
}

extern "C" int fldigi_navtex_encode(const char *text, int ita2, unsigned char *codes, int max_codes)
{
	std::string enc = navtex_encode_fec(text ? text : "", ita2 != 0);
	int n = (int)enc.size() < max_codes ? (int)enc.size() : max_codes;
	for (int i = 0; i < n; i++) codes[i] = (unsigned char)enc[i];
	return n;
}
