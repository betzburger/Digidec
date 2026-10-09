// ----------------------------------------------------------------------------
// fldigi_wefax.cpp  --  C-Schnittstelle zum WEFAX-Empfänger (Digidec)
// ----------------------------------------------------------------------------
#include <vector>
#include <cstring>
#include "fldigi_wefax.h"
#include "wefax_rx.h"

#define WEFAX_BLOCK 512   // fldigi: rx_process nimmt höchstens 512 Samples

struct fldigi_wefax {
	wefax *rx;
	double block[WEFAX_BLOCK];
	int fill;
};

static int lpm_index(int lpm)
{
	for (int i = 0; i < 4; i++) if (all_lpm_values[i].m_value == lpm) return i;
	return 1;   // 120
}

static void apply(WefaxProgdefaults &p, WefaxProgStatus &st, const fldigi_wefax_config *c)
{
	p.WEFAX_Center = c->center_hz;
	p.WEFAX_Shift = c->shift_hz;
	p.wefax_lpm_576 = lpm_index(c->lpm);
	p.wefax_lpm_288 = lpm_index(c->lpm);
	p.wefax_filter = c->filter;
	p.wefax_correlation_rows = c->correlation_rows;
	p.wefax_correlation = c->correlation;
	p.WEFAX_MaxRows = c->max_rows;
	p.wefax_autocenter = c->auto_center != 0;
	st.afconoff = c->afc != 0;
}

extern "C" fldigi_wefax_config fldigi_wefax_default_config(void)
{
	WefaxProgdefaults d;
	WefaxProgStatus s;
	fldigi_wefax_config c;
	c.ioc = 576;
	c.lpm = all_lpm_values[d.wefax_lpm_576].m_value;
	c.shift_hz = d.WEFAX_Shift;
	c.center_hz = d.WEFAX_Center;
	c.filter = d.wefax_filter;
	c.afc = s.afconoff;
	c.auto_center = d.wefax_autocenter;
	c.noise_removal = 0;
	c.max_rows = d.WEFAX_MaxRows;
	c.correlation = d.wefax_correlation;
	c.correlation_rows = d.wefax_correlation_rows;
	c.slant = 0;
	return c;
}

extern "C" fldigi_wefax *fldigi_wefax_create(const fldigi_wefax_config *cfg, fldigi_wefax_saved_fn on_saved, void *ctx)
{
	WefaxProgdefaults p;
	WefaxProgStatus st;
	apply(p, st, cfg);
	fldigi_wefax *w = new fldigi_wefax;
	w->fill = 0;
	w->rx = new wefax(cfg->ioc == 288 ? MODE_WEFAX_288 : MODE_WEFAX_576, p, st);
	w->rx->image.on_saved = on_saved;
	w->rx->image.ctx = ctx;
	w->rx->image.noise_removal = cfg->noise_removal != 0;
	w->rx->image.rx_slant_ratio = cfg->slant;
	return w;
}

extern "C" void fldigi_wefax_destroy(fldigi_wefax *w)
{
	if (!w) return;
	delete w->rx;
	delete w;
}

extern "C" void fldigi_wefax_configure(fldigi_wefax *w, const fldigi_wefax_config *cfg)
{
	int old_center = w->rx->cfg.WEFAX_Center;
	apply(w->rx->cfg, w->rx->status, cfg);
	w->rx->image.noise_removal = cfg->noise_removal != 0;
	w->rx->image.rx_slant_ratio = cfg->slant;
	// fldigi: Klick in den Wasserfall setzt die Mitte (WEFAX_Center wird von der AFC als Bezug genutzt)
	if (cfg->center_hz != old_center) w->rx->set_freq(cfg->center_hz);
}

extern "C" void fldigi_wefax_process(fldigi_wefax *w, const float *samples, int count)
{
	for (int i = 0; i < count; i++) {
		w->block[w->fill++] = samples[i];
		if (w->fill == WEFAX_BLOCK) {
			w->rx->rx_process(w->block, WEFAX_BLOCK);
			w->fill = 0;
		}
	}
}

extern "C" void fldigi_wefax_set_rf(fldigi_wefax *w, long long rf_hz)
{
	w->rx->m_wf.m_rfcarrier = rf_hz;
}

extern "C" void fldigi_wefax_get_status(const fldigi_wefax *w, fldigi_wefax_status *out)
{
	out->center_hz = w->rx->frequency;
	out->metric = w->rx->metric;
	out->snr_db = w->rx->snr_db;
	out->state = w->rx->rx_state();
	out->lpm = w->rx->lpm();
	out->width = w->rx->image.width;
	out->rows = w->rx->image.rows;
	out->manual = w->rx->manual_mode();
	out->revision = w->rx->image.revision;
}

extern "C" int fldigi_wefax_copy_image(const fldigi_wefax *w, unsigned char *gray, int max_bytes)
{
	std::vector<unsigned char> buf;
	int wd = 0, h = 0;
	w->rx->image.copy_gray(buf, wd, h);
	if (wd <= 0) return 0;
	int rows = std::min(h, max_bytes / wd);
	memcpy(gray, buf.data(), (size_t)rows * wd);
	return rows;
}

extern "C" void fldigi_wefax_skip_apt(fldigi_wefax *w) { w->rx->skip_apt(); }
extern "C" void fldigi_wefax_skip_phasing(fldigi_wefax *w) { w->rx->skip_phasing(true); }
extern "C" void fldigi_wefax_abort(fldigi_wefax *w) { w->rx->end_reception(); }

/// wie wefax_cb_pic_rx_manual: an → APT und Phasing überspringen; aus → wieder APT-gesteuert
extern "C" void fldigi_wefax_set_manual(fldigi_wefax *w, int manual)
{
	w->rx->set_rx_manual_mode(manual != 0);
	if (manual) {
		if (w->rx->rx_state() == 0) w->rx->skip_apt();
		if (w->rx->rx_state() == 2) w->rx->skip_phasing(true);
	}
}

extern "C" void fldigi_wefax_save(fldigi_wefax *w) { w->rx->save_now(); }
