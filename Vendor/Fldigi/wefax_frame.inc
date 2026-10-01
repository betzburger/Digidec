// ============================================================================
// ABWEICHUNG fldigi (Digidec): Rahmen statt fldigis Modem-Klasse `wefax`, Wasserfall und Bildfenster
// ============================================================================

/// fldigi wefax-pic.cxx
LPM_VALUES all_lpm_values[4] = {
	{ 240, "240" },
	{ 120, "120" },
	{  90,  "90" },
	{  60,  "60" }
};

WefaxImage *wefax_pic::current = nullptr;

// ----------------------------------------------------------------------------
// Wasserfall: wie WFdisp::processFftBuffer (8192-Punkt-FFT, Blackman, vscale 2/N, pwr = norm).
// fldigi rechnet den Wasserfall nach Umsetzung auf 8000 Hz; hier direkt bei der Modem-Abtastrate,
// das 1-Hz-Pixel i liegt im Bin round(i · N / Abtastrate).
// ----------------------------------------------------------------------------

static const int WF_FFTLEN_DD = 8192;

WefaxWaterfall::WefaxWaterfall(int sample_rate)
: m_rate(sample_rate)
, m_circ(WF_FFTLEN_DD, 0.0)
, m_window(WF_FFTLEN_DD)
, m_pwr(IMAGE_WIDTH + 1, 0.0)
, m_fftbuf(WF_FFTLEN_DD)
{
	for (int i = 0; i < WF_FFTLEN_DD; i++) {
		// fldigi BlackmanWindow (Standard wfPreFilter = Blackman)
		double x = (double)i / WF_FFTLEN_DD;
		m_window[i] = 0.42 - 0.50 * cos(2.0 * M_PI * x) + 0.08 * cos(4.0 * M_PI * x);
	}
	m_fft = new g_fft<double>(WF_FFTLEN_DD);
}

WefaxWaterfall::~WefaxWaterfall()
{
	delete m_fft;
}

void WefaxWaterfall::sig_data(const double *data, int len)
{
	for (int i = 0; i < len; i++) {
		m_circ[m_ptr] = data[i];
		if (++m_ptr == WF_FFTLEN_DD) m_ptr = 0;
	}
	m_dirty = true;
}

void WefaxWaterfall::update() const
{
	if (!m_dirty) return;
	m_dirty = false;
	double vscale = 2.0 / WF_FFTLEN_DD;
	for (int i = 0; i < WF_FFTLEN_DD; i++) m_fftbuf[i] = 0;
	double *pbuf = reinterpret_cast<double *>(m_fftbuf.data());
	int idx = m_ptr;   // älteste Probe zuerst
	for (int i = 0; i < WF_FFTLEN_DD; i++) {
		pbuf[i] = m_window[i] * m_circ[idx] * vscale;
		if (++idx == WF_FFTLEN_DD) idx = 0;
	}
	m_fft->RealFFT(m_fftbuf.data());
	double scale = (double)WF_FFTLEN_DD / m_rate;
	m_pwr[0] = 0;
	for (int i = 1; i <= IMAGE_WIDTH; i++) {
		int n = (int)round(scale * i);
		m_pwr[i] = (n < WF_FFTLEN_DD / 2) ? std::norm(m_fftbuf[n]) : 0.0;
	}
}

/// Wie WFdisp::powerDensity
double WefaxWaterfall::powerDensity(double f0, double bw) const
{
	update();
	double pwrdensity = 0.0;
	int flower = (int)((f0 - bw/2)),
		fupper = (int)((f0 + bw/2));
	if (flower < 0 || fupper > IMAGE_WIDTH)
		return 0.0;
	for (int i = flower; i <= fupper; i++)
		pwrdensity += m_pwr[i];
	return pwrdensity/(bw+1);
}

/// Wie WFdisp::powerDensityMaximum
double WefaxWaterfall::powerDensityMaximum(int bw_nb, const int (*bw)[2]) const
{
	update();
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
		if (f_highest > IMAGE_WIDTH) f_highest = IMAGE_WIDTH;
		max_pwr = 0;
		pnbw[i] = 0;
		for (int n = f_lowest; n < f_highest; n++) {
			if (m_pwr[n] > max_pwr) {
				max_pwr = m_pwr[n];
				fmax[i] = n;
			}
			pnbw[i] += m_pwr[n];
		}
		if (pnbw[i] == 0) return carrierfreq;
	}
	int fmid = 0;
	double total_pwr = 0;
	for (int i = 0; i < bw_nb; i++) total_pwr += pnbw[i];

	for (int i = 0; i < bw_nb; i++) fmid += fmax[i] * pnbw[i] / total_pwr;

	return fmid;
}

// ----------------------------------------------------------------------------
// Empfangsbild: wefax_map (wefax_map.cxx/.h) und Empfangsteil von wefax-pic.cxx ohne FLTK
// ----------------------------------------------------------------------------

/// wefax_map::resize
void WefaxImage::resize(int w, int h)
{
	width = w;
	height = h;
	bufsize = depth * w * h;
	vidbuf.assign(bufsize, (unsigned char)background);
	++revision;
}

/// wefax_map::resize_height
void WefaxImage::resize_height(int new_height, bool clear_img)
{
	int new_bufsize = width * new_height * depth;
	if( clear_img )
	{
		vidbuf.assign(new_bufsize, (unsigned char)background);
	}
	else
	{
		vidbuf.resize(new_bufsize, (unsigned char)background);
	}
	bufsize = new_bufsize ;
	height = new_height;
	++revision;
}

/// wefax_map::shift_horizontal_center
void WefaxImage::shift_horizontal_center(int horizontal_shift)
{
	/// This is a number of pixels.
	horizontal_shift *= depth ;
	if( horizontal_shift < -bufsize ) {
		horizontal_shift = -bufsize ;
	}
	unsigned char *buf = vidbuf.data();

	if( horizontal_shift > 0 ) {
		if (horizontal_shift > bufsize) horizontal_shift = bufsize;   // Digidec: Schutz vor Überlauf
		memmove( buf + horizontal_shift, buf, bufsize - horizontal_shift );
		memset( buf, background, horizontal_shift );
	} else {
		memmove( buf, buf - horizontal_shift, bufsize + horizontal_shift );
		memset( buf + bufsize + horizontal_shift, background, -horizontal_shift );
	}
	++revision;
}

/// wefax_map::pixel(data, pos)
void WefaxImage::pixel(unsigned char data, int pos)
{
	if (pos < 0 || pos >= bufsize) {
		return ;
	}
	vidbuf[pos] = data;
	++revision;
}

/// wefax_map::restore
bool WefaxImage::restore( int row, int margin )
{
	if( ( row <= noise_height_margin ) || ( row >= height ) ) return true;

	unsigned char * line_ante = vidbuf.data() + (row - noise_height_margin) * width * depth;
	for( int col = margin ; col < width - margin; ++col )
	{
		int offset = col * depth ;
		line_ante[ offset ] = line_ante[ offset + 2 ] = line_ante[ offset + 1 ];
	}
	return false ;
}

/// wefax_map::remove_noise
void WefaxImage::remove_noise( int row, int half_len, int noise_margin )
{
	if( restore( row, half_len ) ) return ;

	const unsigned char * line_prev = vidbuf.data() + (row - noise_height_margin + 1) * width * depth;
	      unsigned char * line_curr = vidbuf.data() + (row - noise_height_margin + 2) * width * depth;
	const unsigned char * line_next = vidbuf.data() + (row - noise_height_margin + 3) * width * depth;

	const int nb_neighbours = ( 2 * ( 2 * half_len + 1 ) );
	std::vector<int> medians(nb_neighbours);

	/// Takes into account the first component only.
	for( int col = half_len ; col < width - half_len; ++col )
	{
		int curr_pix = line_curr[ col * depth ];

		int pix_min = 255, pix_max = 0;
		for( int subcol = col - half_len, tmp, nghb_i = 0 ; subcol <= col + half_len ; ++subcol )
		{
			int offset = subcol * depth ;
			tmp = line_prev[ offset ];
			if( tmp < pix_min ) pix_min = tmp ;
			else if( tmp > pix_max ) pix_max = tmp ;
			medians[nghb_i++] = tmp;

			tmp = line_next[ offset ];
			if( tmp < pix_min ) pix_min = tmp ;
			else if( tmp > pix_max ) pix_max = tmp ;
			medians[nghb_i++] = tmp;
		}

		// Maybe the pixel is between min and max.
		int thres_min = pix_min - noise_margin;
		if(thres_min < 0) thres_min = 0;
		int thres_max = pix_max + noise_margin;
		if(thres_max > 255 ) thres_max = 255;

		if( ( curr_pix >= thres_min ) && ( curr_pix <= thres_max ) ) continue ;

		std::sort( medians.begin(), medians.end() );
		int new_pix = medians[ nb_neighbours / 2 ];

		line_curr[ col * depth + 1 ] = new_pix;
	}
}

/// wefax_pic::update_rx_pic_col (ohne Scrollen)
int WefaxImage::update_rx_pic_col(unsigned char data, int pix_pos )
{
	/// Each time the received image becomes too high, we increase its height.
	static const int curr_pix_incr_height = 100 ;

	int row_number = 1 + ( pix_pos / ( width * depth ) );

	/// Maybe we must increase the image height.
	if( curr_pix_height <= row_number )
	{
		curr_pix_height = row_number + curr_pix_incr_height ;
		resize_height( curr_pix_height, false );
	}
	pixel(data, pix_pos);
	if (row_number > rows) rows = row_number;
	return row_number ;
}

/// wefax_pic::update_rx_pic_bw
void WefaxImage::update_rx_pic_bw(unsigned char data, int pix_pos )
{
	/// No pixel is added nor printed until this flag is reset to false.
	if( reception_paused  ) {
		return ;
	};
	/// The image must be horizontally shifted.
	pix_pos += center_val_prev * depth ;
	if( pix_pos < 0 ) {
		pix_pos = 0 ;
	}

	/// Maybe there is a slant.
	pix_pos = ( double )pix_pos * slant_factor_default() + 0.5 ;

	/// Must be a multiple of the number of bytes per pixel.
	pix_pos = ( pix_pos / depth ) * depth ;

	int row_number = 0;
	for (int n = 0; n < depth; n++)
		row_number = update_rx_pic_col(data, pix_pos + n);

	if (prev_row != row_number) {
		prev_row = row_number;
	}

	if( noise_removal ) {
		if( ( row_number > noise_height_margin - 2 ) && ( row_number != rx_last_filtered_row ) ) {
			remove_noise(
				row_number,
				cfg->WEFAX_NoiseMargin,
				cfg->WEFAX_NoiseThreshold );
			rx_last_filtered_row = row_number ;
		}
	}

/// Recenter every X-th row

	if ((row_number != last_row) &&
		(row_number < cfg->wefax_align_stop) &&
		(row_number > cfg->wefax_auto_after) &&
		(row_number % cfg->wefax_align_rows == 0)) {
			last_row = row_number;
		int new_center = estimate_rx_image_center( row_number, cfg->wefax_align_rows );
		if (cfg->wefax_autocenter) {
			if ( abs(new_center) > 3) { // 2 x depth of image
				center_value = center_value - new_center;
				rx_center_changed();
			}
		}
	}
}

/// estimate_rx_image_center (wefax-pic.cxx)
int WefaxImage::estimate_rx_image_center( int row_end , int numrows )
{
if (row_end < numrows) return 0;
	/// This works as well with color images.
	int img_wid = width * depth;
	unsigned const char * img_start = vidbuf.data();

	/// The width of the image band on which we compute the minima
	/// of the absolute value of the video signal.
	/// Equal to the WEFAX start phasing width.
	#define AVG_WID 180

	const unsigned char *pch = img_start;

	std::vector<int> avgs(img_wid, 0);
	std::vector<int> img_avg(img_wid, 0);

// averages over numrows
	for (int col = 0; col < img_wid; col++) {
		int avgval = 0;
		for (int row = row_end - numrows; row < row_end; ++row) {
			avgval += (int)(pch[row * img_wid + col]);
		}
		avgs[col] = avgval / numrows;
	}

	int min_idx = -1;
	int min_val = 255;

	for (int col = 0; col < img_wid; col++) {
		for (int n = 0; n < AVG_WID; n++)
			img_avg[col] += avgs[(col + n) % img_wid];
		img_avg[col] /= AVG_WID;
		if (img_avg[col] < min_val) {
			min_val = img_avg[col];
			min_idx = col;
		}
	}

	if (min_idx > img_wid / 2) min_idx -= img_wid;
	min_idx += AVG_WID / 2;
	min_idx /= depth;

	if (min_val > 40) return 0;

	return min_idx;
	#undef AVG_WID
}

/// wefax_cb_pic_rx_center
void WefaxImage::rx_center_changed()
{
	int center_new_val = center_value;
	int center_delta = center_new_val - center_val_prev ;
	center_val_prev = center_new_val ;

	shift_horizontal_center( center_delta );
}

/// wefax_pic::abort_rx_viewer
void WefaxImage::abort_rx_viewer(void)
{
	/// Maybe the image is too high, we make it shorter.
	resize_height( curr_pix_h_default, true );

	curr_pix_height = curr_pix_h_default ;
	rx_last_filtered_row = 0;
	center_val_prev = 0 ;
	center_value = 0.0;
	rows = 0;
	prev_row = last_row = 0;   // Digidec: fldigis static-Werte gelten je Bild
}

/// wefax_pic::resize_rx_viewer
void WefaxImage::resize_rx_viewer(int wid_img)
{
	abort_rx_viewer();
	resize(wid_img, curr_pix_h_default);
}

/// wefax_pic::save_image: Digidec schreibt das PNG selbst (Rückruf mit Graustufen und fldigis Kommentaren)
void WefaxImage::save_image(const std::string & fil_name, const std::string & extra_comments )
{
	std::stringstream local_comments;
	local_comments << extra_comments ;
	local_comments << "Slant:" << rx_slant_ratio << "\n" ;
	local_comments << "Auto-Center:" << ( cfg->wefax_autocenter ? "On" : "Off" ) << "\n" ;
	if (!on_saved) return;
	std::vector<unsigned char> gray;
	int w = 0, h = 0;
	copy_gray(gray, w, h);
	on_saved(ctx, fil_name.c_str(), local_comments.str().c_str(), gray.data(), w, h);
}

void WefaxImage::copy_gray(std::vector<unsigned char> &out, int &w, int &h) const
{
	w = width;
	h = std::min(rows, height);
	out.resize((size_t)w * h);
	for (int i = 0; i < w * h; i++) out[i] = vidbuf[(size_t)i * depth];
}

// ----------------------------------------------------------------------------
// Modem-Klasse wefax (wefax.cxx), nur Empfang
// ----------------------------------------------------------------------------

/// wefax::wefax
wefax::wefax(trx_mode wefax_mode, const WefaxProgdefaults &defaults, const WefaxProgStatus &st)
: cfg(defaults)
, status(st)
, m_wf(11025)
, mode(wefax_mode)
{
	image.cfg = &cfg;
	wefax_pic::current = &image;

	samplerate = 11025;

	m_impl = new fax_implementation(wefax_mode, this);

	m_impl->set_mode(wefax_mode);

	int tmpShift = cfg.WEFAX_Shift ;
	if (
	          (cfg.WEFAX_Shift < 100)
	       || (cfg.WEFAX_Shift > 1000)) {
		static const int standard_shift = 800;
		tmpShift = standard_shift ;
	}
	fm_deviation = tmpShift / 2 ;

	bandwidth = fm_deviation * 2 ;

	set_rx_manual_mode(false);

	// init() → rx_init()
	m_impl->init_rx(samplerate) ;
	wefax_pic::resize_rx_viewer(m_impl->fax_width());
}

wefax::~wefax()
{
	wefax_pic::current = &image;
	end_reception();
	delete m_impl ;
	m_impl = 0 ;
	if (wefax_pic::current == &image) wefax_pic::current = nullptr;
}

/// wefax::set_freq (modem::set_freq ohne Bandgrenzen + Trigonometrie-Tabellen)
void wefax::set_freq(double freq)
{
	frequency = freq;
	m_wf.carrierfreq = freq;
	m_impl->set_carrier(freq);
}

/// put_Status1: „s/n NN dB“ – Digidec merkt sich den Wert zusätzlich als Zahl
void wefax::put_Status1_(const char *s)
{
	status1 = s;
	double v = 0;
	if (sscanf(s, "s/n %lf", &v) == 1) snr_db = v;
}

/// wefax::rx_process; fldigis Schätzung verlorener Samples über die Uhrzeit entfällt
/// (Digidec verliert keine Samples, und bei Dateien wäre die Uhrzeit bedeutungslos)
int wefax::rx_process(const double *buf, int len)
{
	if (len == 0 || len > 512)
		return 0 ;
	wefax_pic::current = &image;
	m_wf.sig_data(buf, len);            // fldigi füttert den Wasserfall getrennt
	m_impl->rx_new_samples(buf, len);
	return 0;
}

void wefax::skip_apt(void)
{
	wefax_pic::current = &image;
	m_impl->skip_apt_rx();
}

void wefax::skip_phasing(bool auto_center)
{
	wefax_pic::current = &image;
	m_impl->skip_phasing_rx(auto_center);
}

void wefax::end_reception(void)
{
	wefax_pic::current = &image;
	m_impl->end_rx();
}

void wefax::set_rx_manual_mode(bool manual_flag)
{
	m_impl->manual_mode_set(manual_flag);
}

bool wefax::manual_mode() const { return m_impl->manual_mode_get(); }

void wefax::save_now()
{
	wefax_pic::current = &image;
	m_impl->save_now();
}

int    wefax::rx_state() const  { return m_impl->rx_state_num(); }
double wefax::lpm() const       { return m_impl->lpm_img(); }
int    wefax::fax_width() const { return m_impl->fax_width(); }
