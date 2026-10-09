// ----------------------------------------------------------------------------
// ft8_digidec.cc  --  C-Schnittstelle zu ft8mon (Digidec). Ablauf wie ft8mon.cc (-file / -card).
// ----------------------------------------------------------------------------
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "ft8_digidec.h"
#include "ft8.h"
#include "unpack.h"

extern int nthreads;   // ft8.cc

namespace {
std::mutex g_cycle_mu;                 // ein Zyklus zur Zeit (ft8mon-Parameter sind global)
std::mutex g_cb_mu;
std::map<std::string, bool> g_seen;    // ft8mon.cc: cycle_already
ft8dd_decode_fn g_fn = nullptr;
void *g_ctx = nullptr;
int g_count = 0;

/// wie hcb() in ft8mon.cc: doppelte Meldungen nicht noch einmal melden und nicht noch einmal subtrahieren
int hcb(int *a91, double hz0, double hz1, double off, const char *comment, double snr, int pass, int correct_bits)
{
	std::string msg = unpack(a91);
	std::lock_guard<std::mutex> g(g_cb_mu);
	if (g_seen.count(msg) > 0) return 1;   // schon gesehen → nicht subtrahieren
	g_seen[msg] = true;
	g_count += 1;
	ft8dd_decode d;
	memset(&d, 0, sizeof(d));
	strncpy(d.text, msg.c_str(), sizeof(d.text) - 1);
	d.snr_db = snr;
	d.dt = off - 0.5;
	d.freq_hz = hz0;
	d.correct_bits = correct_bits;
	d.pass = pass;
	if (g_fn) g_fn(g_ctx, &d);
	return 2;   // neu → subtrahieren
}
}

extern "C" int ft8dd_decode_cycle(const float *samples, int count, int rate, double min_hz, double max_hz,
                                  double budget_s, int threads, ft8dd_decode_fn on_decode, void *ctx)
{
	std::lock_guard<std::mutex> cycle(g_cycle_mu);
	{
		std::lock_guard<std::mutex> g(g_cb_mu);
		g_seen.clear();
		g_fn = on_decode;
		g_ctx = ctx;
		g_count = 0;
	}
	nthreads = threads > 0 ? threads : 1;
	std::vector<double> s(count);
	for (int i = 0; i < count; i++) s[i] = samples[i];
	// ft8mon.cc: auf genau 15 s bringen (Plan-Cache), Hinweise auf CQ
	if ((int)s.size() < 15 * rate) s.resize(15 * rate, 0.0);
	int hints[2] = { 2, 0 };
	entry(s.data(), (int)s.size(), (int)(0.5 * rate), rate, min_hz, max_hz,
	      hints, hints, budget_s, budget_s, hcb, 0, (struct cdecode *)0);
	std::lock_guard<std::mutex> g(g_cb_mu);
	g_fn = nullptr;
	return g_count;
}
