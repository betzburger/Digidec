// ----------------------------------------------------------------------------
// fldigi_synop.cpp  --  C-Schnittstelle zum SYNOP-Decoder (Digidec)
// ----------------------------------------------------------------------------
#include <string>
#include "fldigi_synop.h"
#include "synop.h"

namespace {
fldigi_synop_print_fn g_print = nullptr;
void *g_ctx = nullptr;
bool g_interleaved = true;

/// Entspricht fldigis rtty_callback (rtty.cxx), ohne Logbuch- und KML-Ausgabe
struct DigidecSynopCallback : public synop_callback {
	bool interleaved(void) const override { return g_interleaved; }
	void print( const char * str, size_t nb, bool bold ) const override {
		if (g_print && nb > 0) g_print(g_ctx, str, (int)nb, bold ? 1 : 0);
	}
	bool log_adif(void) const override { return false; }
	bool log_kml(void) const override { return false; }
};

bool g_setup = false;
void ensure_setup()
{
	if (!g_setup) {
		synop::setup<DigidecSynopCallback>();
		synop::instance()->init();
		g_setup = true;
	}
}
}

extern "C" int fldigi_synop_load_stations(const char *data_dir)
{
	return SynopDB::Init(data_dir ? data_dir : "") ? 1 : 0;
}

extern "C" void fldigi_synop_set_output(fldigi_synop_print_fn fn, void *ctx, int interleaved)
{
	g_print = fn;
	g_ctx = ctx;
	g_interleaved = interleaved != 0;
	ensure_setup();
}

// Wie fldigi rtty::rx() bei aktivierter Synop-Decodierung:
//   if (c != 0 && c != '\r') synop->add(c); else { if (synop->enabled()) synop->flush(false); put_rx_char(c); }
extern "C" void fldigi_synop_feed(char c)
{
	ensure_setup();
	synop *s = synop::instance();
	if (c != 0 && c != '\r') {
		s->add(c);
	} else {
		if (s->enabled()) s->flush(false);
		if (c != 0 && g_print) g_print(g_ctx, &c, 1, 0);
	}
}

extern "C" void fldigi_synop_flush(void)
{
	ensure_setup();
	synop *s = synop::instance();
	if (s->enabled()) s->flush(true);
}

extern "C" const char *fldigi_synop_station_name(int wmo_indicator)
{
	static std::string name;
	name = SynopDB::IndicatorToName(wmo_indicator);
	return name.c_str();
}
