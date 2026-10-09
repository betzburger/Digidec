
// ============================================================================
// ABWEICHUNG fldigi (Digidec): Rahmen statt fldigis Modem-Klasse `navtex` und Wasserfall
// ============================================================================

NavtexWaterfall::NavtexWaterfall(int sample_rate)
: m_rate(sample_rate)
, m_len(8192)
{
	m_buf = new double[m_len];
	m_window = new double[m_len];
	for (int i = 0; i < m_len; i++) {
		m_buf[i] = 0;
		// fldigi BlackmanWindow (Standard WFPREFILTER = 1)
		double x = (double)i / m_len;
		m_window[i] = 0.42 - 0.50 * cos(2.0 * M_PI * x) + 0.08 * cos(4.0 * M_PI * x);
	}
}

NavtexWaterfall::~NavtexWaterfall()
{
	delete [] m_buf;
	delete [] m_window;
}

void NavtexWaterfall::sig_data(const double *data, int len)
{
	for (int i = 0; i < len; i++) {
		m_buf[m_ptr] = data[i];
		if (++m_ptr == m_len) m_ptr = 0;
	}
}

/// Leistung des 1-Hz-Pixels `hz` wie fldigis pwr[] (Bin round(hz · N / Abtastrate) einer N-Punkt-FFT
/// mit Blackman-Fenster), hier per Goertzel nur für die benötigten Frequenzen.
double NavtexWaterfall::pwr(int hz) const
{
	int n = (int)round((double)hz * m_len / m_rate);
	double w = TWOPI * n / m_len;
	double coeff = 2.0 * cos(w);
	double s1 = 0, s2 = 0;
	int idx = m_ptr;
	for (int k = 0; k < m_len; k++) {
		double s0 = m_buf[idx] * m_window[k] + coeff * s1 - s2;
		s2 = s1;
		s1 = s0;
		if (++idx == m_len) idx = 0;
	}
	double re = s1 - s2 * cos(w);
	double im = s2 * sin(w);
	double v = 2.0 / m_len;
	return (re * re + im * im) * v * v;
}

/// Wie WFdisp::powerDensity (fldigi src/waterfall/waterfall.cxx)
double NavtexWaterfall::powerDensity(double f0, double bw) const
{
	double pwrdensity = 0.0;
	int flower = (int)((f0 - bw/2)),
		fupper = (int)((f0 + bw/2));
	if (flower < 0 || fupper > m_rate / 2)
		return 0.0;
	for (int i = flower; i <= fupper; i++)
		pwrdensity += pwr(i);
	return pwrdensity/(bw+1);
}

/// Wie WFdisp::powerDensityMaximum (fldigi src/waterfall/waterfall.cxx)
double NavtexWaterfall::powerDensityMaximum(int bw_nb, const int (*bw)[2]) const
{
	if (bw_nb < 1) return carrierfreq;

	std::vector<int> fmax(bw_nb);
	std::vector<double> pnbw(bw_nb);
	int f_lowest = carrierfreq;
	int f_highest = carrierfreq;
	double max_pwr = 0;
	for (int i = 0; i < bw_nb; i++) {
		fmax[i] = carrierfreq;
		pnbw[i] = 0;
	}

	for (int i = 0; i < bw_nb; i++) {
		f_lowest = carrierfreq + bw[i][0];
		if (f_lowest <= 0) f_lowest = 0;
		f_highest = carrierfreq + bw[i][1];
		if (f_highest > m_rate / 2) f_highest = m_rate / 2;
		max_pwr = 0;
		pnbw[i] = 0;
		for (int n = f_lowest; n < f_highest; n++) {
			double p = pwr(n);
			if (p > max_pwr) {
				max_pwr = p;
				fmax[i] = n;
			}
			pnbw[i] += p;
		}
		if (pnbw[i] == 0) return carrierfreq;
	}
	int fmid = 0;
	double total_pwr = 0;
	for (int i = 0; i < bw_nb; i++) total_pwr += pnbw[i];

	for (int i = 0; i < bw_nb; i++) fmid += fmax[i] * pnbw[i] / total_pwr;

	return fmid;
}

navtex::navtex(const NavtexConfig &cfg, double center, const NavtexCallbacks &cb)
: m_cfg(cfg)
, m_cb(cb)
, m_wf(11025)
, m_frequency(center)
{
	m_wf.m_reverse = cfg.reverse;
	m_impl = new navtex_implementation( get_samplerate(), cfg.sitor_b_only, this );
	set_freq(center);
}

navtex::~navtex()
{
	delete m_impl;
}

void navtex::configure(const NavtexConfig &cfg)
{
	bool rebuild = cfg.ita2 != m_cfg.ita2 || cfg.sitor_b_only != m_cfg.sitor_b_only;
	m_cfg = cfg;
	m_wf.m_reverse = cfg.reverse;
	if (rebuild) {
		delete m_impl;
		m_impl = new navtex_implementation( get_samplerate(), cfg.sitor_b_only, this );
		m_impl->set_carrier(m_frequency);
	}
}

void navtex::rx_process(const double *buf, int len)
{
	m_impl->process_data(buf, len);
}

/// fldigi navtex::set_freq: modem::set_freq (Begrenzung auf das Band) + set_carrier
void navtex::set_freq(double freq)
{
	const double bandwidth = 2 * deviation_f;
	if (freq < bandwidth / 2) freq = bandwidth / 2;
	if (freq > 4000 - bandwidth / 2) freq = 4000 - bandwidth / 2;
	m_frequency = freq;
	m_impl->set_carrier(freq);
}

bool navtex_load_stations(const std::string &data_dir)
{
	RecordLoaderInterface::SetDataDir(data_dir);
	return NavtexCatalog::InstCatalog().LoadAndRegister() > 0;
}

bool navtex_find_station(char origin, double frequency_hz, const std::string &locator, const std::string &msg,
                         std::string &out)
{
	try {
		const NavtexRecord *rec = NavtexCatalog::InstCatalog().FindStation(
			(long long)frequency_hz, origin, locator, msg);
		if (!rec) return false;
		std::stringstream strm;
		strm << rec->name() << ';' << rec->callsign() << ';' << rec->country() << ';'
		     << rec->coordinates().latitude().angle() << ';' << rec->coordinates().longitude().angle();
		out = strm.str();
		return true;
	} catch (const std::exception &) {
		return false;     // z. B. ungültiger Locator
	}
}

/// Testsignal: dieselbe Kodierung wie fldigis NAVTEX-Sender (encode + create_fec)
std::string navtex_encode_fec(const std::string &text, bool ita2)
{
	NavtexConfig cfg;
	cfg.ita2 = ita2;
	NavtexCallbacks cb;
	navtex tmp(cfg, 1000, cb);
	return tmp.encode_fec(text);
}

std::string navtex::encode_fec(const std::string &text) const
{
	return m_impl->create_fec( m_impl->encode( text ) );
}
