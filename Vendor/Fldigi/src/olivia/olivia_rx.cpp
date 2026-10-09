// ----------------------------------------------------------------------------
// olivia_rx.cpp  --  Olivia/Contestia-Empfänger für Digidec
//
// Die Empfangslogik folgt Zeile für Zeile fldigi 4.2.13 (src/olivia/olivia.cxx, src/contestia/contestia.cxx:
// restart(), rx_process(), unescape(), rx_flush()); die Bibliothek MFSK_Receiver stammt unverändert von
// Pawel Jalocha SP9VRC (jalocha/pj_mfsk.h). GNU GPL v3.
// ABWEICHUNG fldigi (Digidec): Einstellungen kommen aus fldigi_olivia_config statt progdefaults; die Anzeige
// (Wasserfall-S/N, Statuszeilen) entfällt. Die Sendeseite (nur Testsignal) folgt olivia::tx_process().
// ----------------------------------------------------------------------------
#include <cmath>
#include <cstring>
#include <vector>
#include "fldigi_olivia.h"
#include "jalocha/pj_mfsk.h"

static double clampd(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }

struct fldigi_olivia {
	fldigi_olivia_config cfg;
	MFSK_Receiver<double> *Rx;
	double frequency;
	double lastfreq = 0;
	double bandwidth = 500;
	double metric = 0;
	int escape = 0;
	fldigi_olivia_char_fn on_char;
	void *ctx;

	int unescape(int c) {                     // olivia::unescape / contestia::unescape
		if (cfg.eight_bit == 0) return c;
		if (escape) { escape = 0; return c + 128; }
		if (c == 127) { escape = 1; return -1; }
		return c;
	}

	double syncThreshold() const {            // restart(): Olivia und Contestia gleich (0 … 90)
		return cfg.squelch_on ? clampd(cfg.squelch / 5.0 + 3.0, 0, 90.0) : 0.0;
	}

	void setCarrier() {                       // restart() / rx_process(): erste Trägerfrequenz
		if (cfg.contestia) {
			Rx->FirstCarrierMultiplier = (frequency + (cfg.reverse ? 1 : -1) * (double)(Rx->Bandwidth / 2)) / 500;
		} else {
			int fc_offset = Rx->Bandwidth * (1.0 - 0.5 / Rx->Tones) / 2.0;
			Rx->FirstCarrierMultiplier = (frequency + (cfg.reverse ? 1 : -1) * fc_offset) / 500.0;
		}
		Rx->Reverse = cfg.reverse ? 1 : 0;
	}

	void restart() {
		bandwidth = 125 * (1 << cfg.bandwidth_exp);
		Rx->Tones = 2 * (1 << cfg.tones_exp);
		Rx->Bandwidth = (size_t)bandwidth;
		Rx->SyncMargin = cfg.sync_margin;
		Rx->SyncIntegLen = cfg.sync_integ;
		Rx->SyncThreshold = syncThreshold();
		Rx->SampleRate = 8000;
		Rx->InputSampleRate = 8000;
		if (cfg.contestia) Rx->bContestia = true;
		setCarrier();
		Rx->Preset();
		metric = 0;
	}

	void drain() {
		unsigned char ch = 0;
		while (Rx->GetChar(ch) > 0) {
			int c = unescape(ch);
			if (c != -1 && c > 7 && on_char) on_char(ctx, c);
		}
	}
};

extern "C" fldigi_olivia_config fldigi_olivia_default_config(void)
{
	fldigi_olivia_config c;
	c.contestia = 0;
	c.tones_exp = 2;
	c.bandwidth_exp = 2;
	c.sync_margin = 8;
	c.sync_integ = 4;
	c.eight_bit = 1;
	c.squelch_on = 1;
	c.squelch = 5.0;
	c.reverse = 0;
	return c;
}

extern "C" fldigi_olivia *fldigi_olivia_create(const fldigi_olivia_config *cfg, double center_hz, fldigi_olivia_char_fn on_char, void *ctx)
{
	fldigi_olivia *o = new fldigi_olivia;
	o->cfg = *cfg;
	o->frequency = center_hz;
	o->on_char = on_char;
	o->ctx = ctx;
	o->Rx = new MFSK_Receiver<double>;
	o->restart();
	return o;
}

extern "C" void fldigi_olivia_destroy(fldigi_olivia *o)
{
	if (!o) return;
	delete o->Rx;
	delete o;
}

extern "C" void fldigi_olivia_configure(fldigi_olivia *o, const fldigi_olivia_config *cfg)
{
	bool restart = cfg->contestia != o->cfg.contestia || cfg->tones_exp != o->cfg.tones_exp || cfg->bandwidth_exp != o->cfg.bandwidth_exp
		|| cfg->sync_margin != o->cfg.sync_margin || cfg->sync_integ != o->cfg.sync_integ || cfg->reverse != o->cfg.reverse;
	o->cfg = *cfg;
	if (restart) { o->lastfreq = 0; o->restart(); }
}

extern "C" void fldigi_olivia_process(fldigi_olivia *o, const float *samples, int count)
{
	// fldigi liefert dem Modem Blöcke von fragmentsize = 1024 Samples (ABWEICHUNG fldigi (Digidec): hier geteilt)
	while (count > 1024) {
		fldigi_olivia_process(o, samples, 1024);
		samples += 1024;
		count -= 1024;
	}
	static thread_local std::vector<double> buf;
	buf.assign(samples, samples + count);
	MFSK_Receiver<double> *Rx = o->Rx;

	// rx_process(): Frequenz oder Seitenband geändert → Synchronisierer neu einstellen
	if ((o->lastfreq != o->frequency || Rx->Reverse) && !o->cfg.reverse) {
		o->setCarrier();
		Rx->Reverse = 0;
		o->lastfreq = o->frequency;
		Rx->Preset();
	} else if ((o->lastfreq != o->frequency || !Rx->Reverse) && o->cfg.reverse) {
		o->setCarrier();
		Rx->Reverse = 1;
		o->lastfreq = o->frequency;
		Rx->Preset();
	}

	// Contestia hebt die Schwelle in rx_process() auf mindestens 3 an
	if (o->cfg.contestia)
		Rx->SyncThreshold = o->cfg.squelch_on ? clampd(o->cfg.squelch / 5.0 + 3.0, 3.0, 90.0) : 3.0;
	else
		Rx->SyncThreshold = o->syncThreshold();

	Rx->Process(buf.data(), buf.size());
	o->metric = clampd(5.0 * (Rx->SignalToNoiseRatio() - 3.0), 0, 100);
	o->drain();
}

extern "C" void fldigi_olivia_set_center(fldigi_olivia *o, double hz)
{
	o->frequency = hz;
}

extern "C" void fldigi_olivia_get_status(const fldigi_olivia *o, fldigi_olivia_status *out)
{
	out->center_hz = o->frequency;
	out->metric = o->metric;
	out->snr = o->Rx->SignalToNoiseRatio();
	out->freq_offset_hz = o->Rx->FrequencyOffset();
	out->bandwidth_hz = o->bandwidth;
	out->tones = (int)o->Rx->Tones;
}

extern "C" void fldigi_olivia_flush(fldigi_olivia *o)
{
	o->Rx->Flush();                   // olivia::rx_flush()
	o->drain();
}

// ----------------------------------------------------------------------------
// Testsignal: Sendeseite nach olivia::tx_init() / tx_process() (ohne Starttöne)
// ----------------------------------------------------------------------------
extern "C" int fldigi_olivia_synthesize(const fldigi_olivia_config *cfg, const char *text, double center_hz, float *out, int max_samples)
{
	MFSK_Transmitter<double> Tx;
	double bandwidth = 125 * (1 << cfg->bandwidth_exp);
	Tx.Tones = 2 * (1 << cfg->tones_exp);
	Tx.Bandwidth = (size_t)bandwidth;
	Tx.SampleRate = 8000;
	Tx.OutputSampleRate = 8000;
	if (cfg->contestia) {
		Tx.bContestia = true;
		Tx.FirstCarrierMultiplier = (center_hz + (cfg->reverse ? 1 : -1) * (double)(Tx.Bandwidth / 2)) / 500;
	} else {
		double fc_offset = Tx.Bandwidth * (1.0 - 0.5 / Tx.Tones) / 2.0;
		Tx.FirstCarrierMultiplier = (center_hz + (cfg->reverse ? 1 : -1) * fc_offset) / 500.0;
	}
	Tx.Reverse = cfg->reverse ? 1 : 0;
	if (Tx.Preset() < 0) return -2;
	std::vector<double> buf(Tx.MaxOutputLen);
	Tx.Start();
	Tx.PutChar(0);                    // der Sender braucht mindestens ein Zeichen
	std::vector<float> samples;
	const char *t = text;
	bool stop = false;
	int guard = 0;
	while (guard++ < 1000000) {
		if (stop || Tx.GetReadReady() < Tx.BitsPerSymbol) {
			if (!stop) {
				if (*t) {
					int c = (unsigned char)*t++;
					if (c > 127 && cfg->eight_bit) { Tx.PutChar(127); Tx.PutChar(c & 127); }
					else Tx.PutChar(c > 127 ? '.' : c);
				} else stop = true;
			}
			if (stop) Tx.Stop();
		}
		int len = Tx.Output(buf.data());
		for (int i = 0; i < len; i++) samples.push_back((float)buf[i]);
		if (!Tx.Running()) break;
	}
	if ((int)samples.size() > max_samples) return -1;
	memcpy(out, samples.data(), samples.size() * sizeof(float));
	return (int)samples.size();
}
