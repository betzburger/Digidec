// ----------------------------------------------------------------------------
// mt63_rx.cpp  --  MT63-Empfänger für Digidec
//
// Die Empfangslogik folgt Zeile für Zeile fldigi 4.2.13 (src/mt63/mt63.cxx: rx_init(), rx_process(), rx_flush(),
// restart()); die Bibliothek MT63rx/MT63tx (dsp.cpp, mt63base.cpp) stammt unverändert von Pawel Jalocha SP9VRC. GNU GPL v3.
// ABWEICHUNG fldigi (Digidec): Einstellungen kommen aus fldigi_mt63_config statt progdefaults; die Anzeige entfällt.
// Die Sendeseite (nur Testsignal) folgt mt63::tx_process().
// ----------------------------------------------------------------------------
#include <cmath>
#include <cstring>
#include <vector>
#include "fldigi_mt63.h"
#include "dsp.h"
#include "mt63base.h"

struct fldigi_mt63 {
	fldigi_mt63_config cfg;
	MT63rx *Rx;
	dspLevelMonitor *InpLevel;
	double_buff *InpBuff;
	double_buff *emptyBuff;
	double frequency;
	double snr = 0;
	double f_offset = 0;
	int escape = 0;
	bool flushbuffer = false;
	fldigi_mt63_char_fn on_char;
	void *ctx;

	void rx_init() {                              // mt63::rx_init()
		Rx->Preset(frequency, cfg.bandwidth_hz, cfg.long_interleave ? 1 : 0, cfg.long_integration ? 32 : 16);
		InpLevel->Preset(64.0, 0.75);
		escape = 0;
	}

	void emit(unsigned int c) {                   // Zeichenausgabe wie in rx_process() und rx_flush()
		if (!cfg.eight_bit) { if (on_char) on_char(ctx, (int)c); return; }
		if ((c < 8) && (escape == 0)) return;
		if (c == 127) { escape = 1; return; }
		if (escape) { c += 128; escape = 0; }
		if (on_char) on_char(ctx, (int)c);
	}
};

extern "C" fldigi_mt63_config fldigi_mt63_default_config(void)
{
	fldigi_mt63_config c;
	c.bandwidth_hz = 1000;
	c.long_interleave = 0;
	c.long_integration = 0;
	c.eight_bit = 1;
	c.squelch_on = 1;
	c.squelch = 5.0;
	return c;
}

extern "C" fldigi_mt63 *fldigi_mt63_create(const fldigi_mt63_config *cfg, double center_hz, fldigi_mt63_char_fn on_char, void *ctx)
{
	fldigi_mt63 *m = new fldigi_mt63;
	m->cfg = *cfg;
	m->frequency = center_hz;
	m->on_char = on_char;
	m->ctx = ctx;
	m->Rx = new MT63rx;
	m->InpLevel = new dspLevelMonitor;
	m->InpBuff = new double_buff;
	m->emptyBuff = new double_buff;
	m->rx_init();                         // fldigi: restart() + rx_init() beim Moduswechsel
	return m;
}

extern "C" void fldigi_mt63_destroy(fldigi_mt63 *m)
{
	if (!m) return;
	delete m->Rx;
	delete m->InpLevel;
	delete m->InpBuff;
	delete m->emptyBuff;
	delete m;
}

extern "C" void fldigi_mt63_configure(fldigi_mt63 *m, const fldigi_mt63_config *cfg)
{
	bool restart = cfg->bandwidth_hz != m->cfg.bandwidth_hz || cfg->long_interleave != m->cfg.long_interleave
		|| cfg->long_integration != m->cfg.long_integration;
	m->cfg = *cfg;
	if (restart) m->rx_init();
}

static void process_block(fldigi_mt63 *m, const float *samples, int len)
{
	if (m->InpBuff->EnsureSpace(len) == -1) return;
	for (int i = 0; i < len; i++) m->InpBuff->Data[i] = samples[i];
	m->InpBuff->Len = len;
	m->InpLevel->Process(m->InpBuff);
	m->Rx->Process(m->InpBuff);

	double snr = m->Rx->FEC_SNR();
	if (m->cfg.squelch_on && snr < m->cfg.squelch) {      // fldigi: Ausgabe verwerfen, Anzeige leer
		m->snr = 0;
		return;
	}
	for (int i = 0; i < m->Rx->Output.Len; i++) m->emit((unsigned int)m->Rx->Output.Data[i]);
	m->f_offset = m->Rx->TotalFreqOffset();
	if (snr > 99.9) snr = 99.9;
	m->snr = snr;
	m->flushbuffer = true;
}

// ABWEICHUNG fldigi (Digidec): fldigi liefert dem Modem Blöcke von fragmentsize = 1024 Samples; die Bibliothek verträgt
// keine großen Blöcke (ihre Verzögerungsleitung ist auf einen Block ausgelegt), deshalb wird hier geteilt.
extern "C" void fldigi_mt63_process(fldigi_mt63 *m, const float *samples, int len)
{
	while (len > 0) {
		int n = len < 1024 ? len : 1024;
		process_block(m, samples, n);
		samples += n;
		len -= n;
	}
}

extern "C" void fldigi_mt63_set_center(fldigi_mt63 *m, double hz)
{
	m->frequency = hz;                // mt63::set_freq()
	m->rx_init();
}

extern "C" void fldigi_mt63_get_status(const fldigi_mt63 *m, fldigi_mt63_status *out)
{
	out->center_hz = m->frequency;
	out->snr = m->snr;
	out->freq_offset_hz = m->f_offset;
	out->locked = m->Rx->SYNC_LockStatus();
	out->confidence = m->Rx->SYNC_Confidence();
	out->bandwidth_hz = m->cfg.bandwidth_hz;
}

extern "C" void fldigi_mt63_flush(fldigi_mt63 *m)       // mt63::rx_flush()
{
	int len = 512;
	if (!m->flushbuffer) return;
	if (m->emptyBuff->EnsureSpace(len) == -1) { m->flushbuffer = false; return; }
	for (int j = 0; j < len; j++) m->emptyBuff->Data[j] = 0.0;
	m->emptyBuff->Len = len;
	m->InpLevel->Process(m->emptyBuff);
	m->Rx->Process(m->emptyBuff);
	int dlen = m->Rx->Output.Len;
	int guard = 0;
	while (m->Rx->SYNC_LockStatus() && guard++ < 100000) {
		for (int i = 0; i < dlen; i++) m->emit((unsigned int)m->Rx->Output.Data[i]);
		for (int j = 0; j < len; j++) m->emptyBuff->Data[j] = 0.0;
		m->emptyBuff->Len = len;
		m->InpLevel->Process(m->emptyBuff);
		m->Rx->Process(m->emptyBuff);
		dlen = m->Rx->Output.Len;
	}
	m->flushbuffer = false;
}

// ----------------------------------------------------------------------------
// Testsignal: Sendeseite nach mt63::tx_init() / tx_process() (ohne Starttöne)
// ----------------------------------------------------------------------------
extern "C" int fldigi_mt63_synthesize(const fldigi_mt63_config *cfg, const char *text, double center_hz, float *out, int max_samples)
{
	MT63tx Tx;
	// fldigi ruft Tx->Preset() zweimal auf (restart() und tx_init()). MT63tx::Preset() liest FFT.Size schon vor
	// FFT.Preset(): beim ersten Aufruf ist die Maske unbestimmt und dspPhaseCorr[] falsch, erst der zweite stimmt.
	Tx.Preset(center_hz, cfg->bandwidth_hz, cfg->long_interleave ? 1 : 0);
	Tx.Preset(center_hz, cfg->bandwidth_hz, cfg->long_interleave ? 1 : 0);
	std::vector<float> samples;
	double maxval = 0.0;
	auto emitBlock = [&](bool normalizeFirst) {
		int len = Tx.Comb.Output.Len;
		if (normalizeFirst) for (int i = 0; i < len; i++) if (fabs(Tx.Comb.Output.Data[i]) > maxval) maxval = fabs(Tx.Comb.Output.Data[i]);
		for (int i = 0; i < len; i++) samples.push_back((float)(Tx.Comb.Output.Data[i] / (maxval > 0 ? maxval : 1.0)));
	};
	// ABWEICHUNG fldigi (Digidec): fldigi füllt den Verschachteler hier ohne Ausgabe (nach den Starttönen); für den Test wird der Vorspann gesendet
	for (int i = 0; i < Tx.DataInterleave; i++) { Tx.SendChar(0); emitBlock(true); }
	for (const char *t = text; *t; t++) {
		int c = (unsigned char)*t;
		if (c > 127 && !cfg->eight_bit) c = '.';
		if (c > 127) {
			Tx.SendChar(127);
			emitBlock(true);
			c &= 127;
		}
		Tx.SendChar(c);
		emitBlock(true);
	}
	int flush = Tx.DataInterleave;
	while (--flush) { Tx.SendChar(0); emitBlock(true); }                // Nachspann
	Tx.SendJam();
	emitBlock(true);
	if ((int)samples.size() > max_samples) return -1;
	memcpy(out, samples.data(), samples.size() * sizeof(float));
	return (int)samples.size();
}
