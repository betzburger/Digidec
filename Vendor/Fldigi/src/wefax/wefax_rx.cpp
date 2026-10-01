// ----------------------------------------------------------------------------
// wefax_rx.cpp  --  WEFAX-Empfänger aus fldigi 4.2.13 (src/wefax/wefax.cxx), erzeugt von port_wefax.py
//
// Copyright (C) Dave Freese W1HKJ, Remi Chateauneu F4ECW u. a. (siehe Original); Kern aus Hamfax/ACfax. GNU GPL v3.
// ABWEICHUNG fldigi (Digidec): Empfangsteil wörtlich; Senden, XML-RPC-Warteschlangen und ADIF-Log entfallen.
// fldigis Globale sind an den Rahmen gebunden (wefax_rx.h, wefax_frame.inc):
//   progdefaults/progStatus → Einstellungen des Decoders, wf → WefaxWaterfall, wefax_pic → WefaxImage.
// ----------------------------------------------------------------------------
#include <unistd.h>
#include <cstdlib>
#include <cstdio>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <cstring>
#include <cassert>
#include <valarray>
#include <cmath>
#include <cstddef>
#include <queue>
#include <map>
#include <algorithm>
#include <ctime>

#include "wefax_rx.h"
#include "filters.h"
#include "misc_min.h"
#include "strutil.h"

#define _(s) (s)
#define LOG_DEBUG(...)   ((void)0)
#define LOG_VERBOSE(...) ((void)0)
#define LOG_INFO(...)    ((void)0)
#define LOG_WARN(...)    ((void)0)
#define LOG_ERROR(...)   ((void)0)
#define IMAGE_WIDTH 4000                           // fldigi: Breite des Wasserfalls in Hz
#define REQ(...) wefax_req(__VA_ARGS__)            // fldigi: Aufruf im GUI-Thread; hier direkt
template <class F, class... A> static inline void wefax_req(F f, A... a) { f(a...); }

// fldigis Globale → Rahmen des Decoders (nur innerhalb von fax_implementation benutzt)
#define progdefaults     (m_ptr_wefax->cfg)
#define progStatus       (m_ptr_wefax->status)
#define wf               (m_ptr_wefax->waterfall())
#define put_Status1(s)   m_ptr_wefax->put_Status1_(s)
#define put_Status2(s)   m_ptr_wefax->put_Status2_(s)

#define PUT_STATUS(A)                          \
{                                                \
	std::stringstream strm_status ;              \
	strm_status << A ;                           \
	LOG_DEBUG("%s", strm_status.str().c_str()); \
}
//	put_status(strm_status.str().c_str());

// ---------------------------------------------------------------------
// Core of the code taken from Hamfax.
// ---------------------------------------------------------------------

/// No reasonable FIR filter should have more coefficients than that.
#define MAX_FILT_SIZE 256

struct fir_coeffs
{
	const char * _name ;
	int          _size ;
	const double _coefs[MAX_FILT_SIZE];
};

// Narrow, middle and wide fir low pass filter from ACfax
static const fir_coeffs input_filters[] = {
{ _("Narrow"), 65,
{
  0.000495,  0.000684,  0.000885,  0.00109,   0.00128,  
  0.00141,   0.00142,   0.00124,   0.000793,  2.94e-05,  
 -0.00108,  -0.00251,  -0.0042,   -0.00602,  -0.00778,  
 -0.00925,  -0.0101,   -0.0102,   -0.00909,  -0.00664,  
 -0.00267,   0.00289,   0.01,      0.0185,    0.0281,  
  0.0383,    0.0488,    0.059,     0.0682,    0.0761,  
  0.0821,    0.0858,    0.0871,    0.0858,    0.0821,  
  0.0761,    0.0682,    0.059,     0.0488,    0.0383,  
  0.0281,    0.0185,    0.01,      0.00289,  -0.00267,  
 -0.00664,  -0.00909,  -0.0102,   -0.0101,   -0.00925,  
 -0.00778,  -0.00602,  -0.0042,   -0.00251,  -0.00108,  
  2.94e-05,  0.000793,  0.00124,   0.00142,   0.00141,  
  0.00128,   0.00109,   0.000885,  0.000684,  0.000495
} },
{ _("Medium"), 65,
{
 -0.000795, -0.000779, -0.000698, -0.000517, -0.000195,  
  0.000303,  0.000982,  0.0018,    0.00267,   0.00343,  
  0.00389,   0.00383,   0.00306,   0.00144,  -0.00102,  
 -0.0042,   -0.0078,   -0.0114,   -0.0143,   -0.0159,  
 -0.0156,   -0.0127,   -0.00695,   0.00188,   0.0136,  
  0.0277,    0.0434,    0.0596,    0.0752,    0.0889,  
  0.0997,    0.106,     0.109,     0.106,     0.0997,  
  0.0889,    0.0752,    0.0596,    0.0434,    0.0277,  
  0.0136,    0.00188,  -0.00695,  -0.0127,   -0.0156,  
 -0.0159,   -0.0143,   -0.0114,   -0.0078,   -0.0042,  
 -0.00102,   0.00144,   0.00306,   0.00383,   0.00389,  
  0.00343,   0.00267,   0.0018,    0.000982,  0.000303,  
 -0.000195, -0.000517, -0.000698, -0.000779, -0.000795
} },
{ _("Wide"),   65,
{
  0.000716,  0.000844,  0.000845,  0.000668,  0.000259,  
 -0.000402, -0.00126,  -0.00216,  -0.00284,  -0.003,  
 -0.00234,  -0.00073,   0.00175,   0.0047,    0.00747,  
  0.00922,   0.00911,   0.00655,   0.00143,  -0.00575,  
 -0.0138,   -0.0209,   -0.025,    -0.0241,   -0.0167,  
 -0.00203,   0.0193,    0.0457,    0.0743,    0.102,  
  0.125,     0.14,      0.145,     0.14,      0.125,  
  0.102,     0.0743,    0.0457,    0.0193,   -0.00203,  
 -0.0167,   -0.0241,   -0.025,    -0.0209,   -0.0138,  
 -0.00575,   0.00143,   0.00655,   0.00911,   0.00922,  
  0.00747,   0.0047,    0.00175,  -0.00073,  -0.00234,  
 -0.003,    -0.00284,  -0.00216,  -0.00126,  -0.000402,  
  0.000259,  0.000668,  0.000845,  0.000844,  0.000716
} }
};

static const size_t nb_filters = sizeof(input_filters)/sizeof(input_filters[0]); ;

/// This contains all possible reception filters.
class fir_filter_pair_set : public std::vector< C_FIR_filter > {
	/// This, because C_FIR_filter cannot be copied.
	fir_filter_pair_set(const fir_filter_pair_set &);
	fir_filter_pair_set & operator = (const fir_filter_pair_set &);

public:
	static const char ** filters_list(void) {
		/// There will be a small memory leak when leaving. No problem at all.
		static const char ** stt_filters = NULL ;
		if (stt_filters == NULL) {
			stt_filters = new const char * [nb_filters + 1];
			for(size_t ix_filt = 0 ; ix_filt < nb_filters ; ++ix_filt) {
				stt_filters[ix_filt] = input_filters[ix_filt]._name ;
			}
			stt_filters[nb_filters] = NULL ;
		}
		return stt_filters ;
	}

	fir_filter_pair_set() {
		/// Beware that C_FIR_filter cannot be copied with its content.
		resize(nb_filters);
		for(size_t ix_filt = 0 ; ix_filt < nb_filters ; ++ix_filt) {
			// Same filter for real and imaginary.
			const fir_coeffs * ptr_filt = input_filters + ix_filt ;
			// init() should take const double pointers.
			operator[](ix_filt).init(ptr_filt->_size, 1,
					const_cast< double * >(ptr_filt->_coefs),
					const_cast< double * >(ptr_filt->_coefs));
		}
	}
}; // fir_filter_pair_set

/// Speed-up of trigonometric calculations.
template <class T> class lookup_table {
	T    * m_table;
	size_t m_table_size;
	size_t m_next;
	size_t m_increment;

	/// No default constructor because it would invalidate the buffer pointer.
	lookup_table();
	lookup_table(const lookup_table &);
	lookup_table & operator = (const lookup_table &);
public:
	lookup_table(const size_t N)
	: m_table_size(N), m_next(0), m_increment(0) {
		assert(N != 0);
		/// If no more memory, an exception will be thrown.
		m_table = new T[m_table_size];
	}

	~lookup_table(void) {
		delete[] m_table;
	}

	T& operator[](size_t i) {
		return m_table[i];
	}

	void set_increment(size_t i) {
		m_increment = i;
	}

	T next_value(void) {
		m_next+=m_increment;
		if (m_next>=m_table_size) {
			m_next%=m_table_size;
		}
		return m_table[m_next];
	}

	size_t size(void) const {
		return m_table_size;
	}

	void reset(void) {
		m_next = 0;
	}
}; // lookup_table

typedef enum {
	RXAPTSTART,
	RXAPTSTOP,
	RXPHASING,
	RXIMAGE,
	TXAPTSTART,
	TXPHASING,
	ENDPHASING,
	TXIMAGE,
	TXAPTSTOP,
	TXBLACK,
	IDLE } fax_state;

static const char * state_to_str(fax_state a_state)
{
	switch(a_state) {
		case RXAPTSTART : return _("APT reception start");
		case RXAPTSTOP  : return _("APT reception stop");
		case RXPHASING  : return _("Phasing reception");
		case RXIMAGE    : return _("Receiving");
		case TXAPTSTART : return _("APT transmission start");
		case TXAPTSTOP  : return _("APT stop");
		case TXPHASING  : return _("Phasing transmission");
		case ENDPHASING : return _("End phasing");
		case TXIMAGE    : return _("Sending image");
		case TXBLACK    : return _("Sending black");
		case IDLE       : return _("Idle");
	}
	return "UNKNOWN";
};

/// TODO: This should be hidden to this class.
static const int bytes_per_pixel = 3;

#define IOC_576 576
#define IOC_288 288

/// Index of correlation to image width.
static int ioc_to_width(int ioc)
{
	return ioc * M_PI ;
};

/// Used by bandwidth. Standard shift is 800 Hz, so deviation is 400 Hz.
/// Deutsche Wetterdienst (DWD) shift is 850 Hz.
static int fm_deviation = -1 ;

#define GARBAGE_STR "garbage"

class fax_implementation {
	wefax * m_ptr_wefax ;  // Points to the modem of which this is the implementation.
	fax_state m_rx_state ; // RXPHASING, RXIMAGE etc...
	bool  rx_state_changed;
	int m_sample_rate;     // Set at startup: 8000, 11025 etc...
	int m_current_value;   // Latest received pixel value.
	bool m_apt_high;
	int m_apt_trans;       // APT low-high transitions
	int m_apt_count;       // samples counted for m_apt_trans
	int m_apt_start_freq;  // Standard APT frequency. Set at startup.
	int m_apt_stop_freq;   // Standard APT frequency.
	bool m_phase_high;     // When state=RXPHASING
	int m_curr_phase_len;  // Counts the len of the image band used for phasing
	int m_curr_phase_high; // Counts the len of the white part of the phasing image band.
	int m_curr_phase_low;  // Counts the len of the black part of the phasing image band.
	int m_phase_lines;
	int m_num_phase_lines;
	int m_phasing_calls_nb;// Number of calls to decode_phasing for the current image.
	double m_lpm_img;      // Lines per minute.
	double m_lpm_sum_rx;   // Sum of the latest LPM values, when RXPHASING.
	int m_default_lpm;     // 120 for WEFAX_576, 60 for WEFAX_288.
	int m_img_width;       // Calculated with IOC=576 or 288.
	int m_img_sample;      // Current received samples number when in RXIMAGE.
	int m_last_col;        // Current col based on samples number, decides to set a pixel when changes.
	int m_pixel_val;       // Accumulates received samples, then averaged to set a pixel.
	int m_pix_samples_nb;  // Number of samples read for the next pixel, and current column. About 4 if 11025 Hz.
	bool m_img_color;      // Whether this is a color image or not.
	fax_state m_tx_state;  // Modem state when transmitting.
	int m_tx_phasing_lin;  // Nb of phasing lines sent when transmitting an image.
	int m_start_duration;  // Number of seconds for sending ATP start.
	int m_stop_duration;   // Number of seconds for sending APT stop.
	int m_img_tx_cols;     // Number of columns when transmitting.
	int m_img_tx_rows;     // Number of rows when transmitting.
	int m_carrier;         // Normalised fax carrier frequency. Should be identical to modem::get_freq().
	int m_fax_pix_num;     // Index of current pixel in received image.
	const unsigned char * m_xmt_pic_buf ; // Bytes to send. Number of pixels by three.
	bool m_manual_mode ;   // Tells whether everything is read, or apt+phasing detection.

	/// The number of samples sent for one line. The LPM is given by the GUI. Typically 5512.
	double m_smpl_per_lin ;// Recalculated each time m_lpm_img is updated.

	double deviation_ratio;

	// At the moment, never found an example where it should be negated.
	static const bool m_phase_inverted = false;

	/// This is always the same filter for all objects.
	fir_filter_pair_set m_rx_filters ; // ABWEICHUNG fldigi (Digidec): je Objekt statt static (Filterzustand)

	/// These are used for transmission.
	lookup_table<double> m_dbl_sine;
	lookup_table<double> m_dbl_cosine;
	lookup_table<double> m_dbl_arc_sine;

	/// Stores a result based on the previous received sample.
	double m_i_fir_old;
	double m_q_fir_old;
	cmplx currz;
	cmplx prevz;

	void decode(const int* buf, int nb_samples);

	/// Used for transmission.
	lookup_table<short> m_short_sine;

	/// This evaluates the average and standard deviation of the current image,
	// using the histogram.
	class statistics {
		static const size_t m_sz = 256 ;
		int m_hist[m_sz];
		mutable double m_avg ;
		mutable double m_dev ;

	public:
		void add_bw(int pix_val) {
			pix_val = pix_val < 0 ? 0 : pix_val > 255 ? 255 : pix_val ;
			m_hist[ pix_val ]++;
		}
		void calc() const {
			m_avg = 0.0;
			int sum = 0 ;
			int sum_vals = 0 ;
			for(size_t i = 0; i < m_sz; ++ i) {
				int weight = m_hist[i];
				sum_vals +=  i * weight ;
				sum += weight ;
			}
			if (sum == 0) {
				m_avg = 0.0 ;
				m_dev = 0.0 ;
				return ;
			}
			m_avg = sum_vals / sum ;

			double sum_dlt_pwr2 = 0.0 ;
			for(size_t i = 0; i < m_sz; ++ i) {
				int weight = m_hist[i];
				double val = i - m_avg ;
				sum_dlt_pwr2 += val * val * weight ;
			}
			m_dev = sqrt(sum_dlt_pwr2 / sum);
		}
		double average() const { return m_avg; }
		double stddev() const { return m_dev; };
		void reset() {
			std::fill(m_hist, m_hist + m_sz, 0);
		}
	};

	statistics m_statistics ;

	fax_implementation();

	/// Needed when starting image reception, after phasing.
	void reset_counters(void) {
		m_last_col       = 0 ;
		m_fax_pix_num    = 0 ;
		m_img_sample     = 0;
		m_pix_samples_nb = 0;
	}

	// These counters used for phasing.
	void reset_phasing_counters() {
		m_lpm_sum_rx = 0;
		m_phasing_calls_nb = 0 ;
		m_phase_high = m_current_value >= 128 ? true : false;
		m_curr_phase_len = m_curr_phase_high = m_curr_phase_low = 0;
		m_phase_lines = m_num_phase_lines = 0;
	}

	/// Called at init time or when the carrier changes.
	void reset_increments(void) {
		/// This might happen at startup. Not a problem.
		if (m_sample_rate == 0) {
			return;
		}
		m_dbl_sine.set_increment(m_dbl_sine.size()*m_carrier/m_sample_rate);
		m_dbl_cosine.set_increment(m_dbl_cosine.size()*m_carrier/m_sample_rate);
		m_dbl_sine.reset();
		m_dbl_cosine.reset();

		m_short_sine.reset();
	}

public:

	trx_mode wefax_mode;

	fax_implementation(int fax_mode, wefax * ptr_wefax);
	void init_rx(int the_smpl_rate);
	void skip_apt_rx(void);
	void skip_phasing_to_image_save(const std::string & comment);
	void skip_phasing_to_image(bool auto_center);
	void skip_phasing_rx(bool auto_center);
	void end_rx(void);
	void rx_new_samples(const double* audio_ptr, int audio_sz);
        void init_tx(int the_smpl_rate);
	void modulate(const double* buffer, int n);
	void tx_params_set(
		int the_lpm,
		const unsigned char * xmtpic_buffer,
		bool is_color,
		int img_w,
		int img_h);
	bool trx_do_next(void);
	void tx_apt_stop(void);

	double carrier(void) const {
		return m_carrier ;
	}

	/// The trigo tables have an increment which depends on the carrier frequency.
	void set_carrier(double freq) {
		m_carrier = freq ;
		reset_increments();
	}

	int fax_width(void) const {
		return m_img_width ;
	}

	/// When set, starts receiving faxes without interruption other than manual.
	void manual_mode_set(bool manual_flag) {
		m_manual_mode = manual_flag ;
	}

	/// Called by the GUI.
	bool manual_mode_get(void) const {
		return m_manual_mode ;
	}

	double lpm_to_samples(int the_lpm) const { // ABWEICHUNG fldigi (Digidec): double statt int (sonst Schräglauf)
		return m_sample_rate * 60.0 / the_lpm ;
	}

	void set_mode( trx_mode m) { wefax_mode = m; }

	// ABWEICHUNG fldigi (Digidec): für die Anzeige
	int rx_state_num(void) const { return (int)m_rx_state; }
	double lpm_img(void) const { return m_lpm_img; }
	/// wie wefax_cb_pic_rx_save: nur speichern, Empfang läuft weiter
	void save_now(void) { wefax_pic::save_image(generate_filename("gui"), ""); }

	/// Called by the GUI.
	void lpm_set() {
		int index = 0;
		switch(wefax_mode) {
			case MODE_WEFAX_576:
				index = progdefaults.wefax_lpm_576;
				break;
			case MODE_WEFAX_288:
				index = progdefaults.wefax_lpm_288;
				break;
		}
		m_lpm_img = all_lpm_values[index].m_value;;
		m_smpl_per_lin = lpm_to_samples(m_lpm_img);
//std::cout << (wefax_mode == MODE_WEFAX_576 ? "wefax 576" : "wefax 288") << ", LPM: " << m_lpm_img << ", index: " << index << std::endl;
	}

	/// This generates a filename based on the frequency, current time, internal state etc...
	std::string generate_filename(const char *extra_msg) const ;

	const char * state_rx_str(void) const {
		return state_to_str(m_rx_state);
	}

	/// Returns a string telling the state. Informational purpose.
	std::string state_string(void) const {
		std::stringstream result ;
		result	<< "tx:" << state_to_str(m_tx_state)
			<< " "
			<< "rx:" << state_to_str(m_rx_state);
		return result.str();
	};

private:
	/// Centered around the frequency.
	double power_usb_noise(void) const {
		static double avg_pwr = 0.0 ;
		double pwr = wf->powerDensity(m_carrier, 2 * fm_deviation) + 1e-10;
		return decayavg(avg_pwr, pwr, 25);//10);
	}

	/// This evaluates the power signal when APT start frequency. This frequency pattern
	/// can be observed on the waterfall.
	double power_usb_apt_start(void) const {
		static double avg_pwr = 0.0 ;
		/// Value approximated by watching the waterfall.
		double pwr = wf->powerDensity(m_apt_start_freq, 10);
		return decayavg(avg_pwr, pwr, 10);
	}

	/// Estimates the signal power when the phasing signal is received.
	double power_usb_phasing(void) const {
		static double avg_pwr = 0.0 ;
		/// Rough estimate based on waterfall observation.
		static const int bandwidth_phasing = 1 ;
		double pwr = wf->powerDensity(m_carrier - fm_deviation, bandwidth_phasing);
		return decayavg(avg_pwr, pwr, 10);
	}

	/// There is some power at m_carrier + fm_deviation but this is neglictible.
	double power_usb_image(void) const {
		static double avg_pwr = 0.0 ;
		/// This value is obtained by watching the waterfall.
		static const int bandwidth_image = 100 ;
		double pwr = wf->powerDensity(m_carrier + fm_deviation, bandwidth_image);
		return decayavg(avg_pwr, pwr, 10);
	}

	/// Hambourg Radio sends a constant freq which looks like an image.
	/// We eliminate it by comparing with a black signal.
	/// If this is a real image, bith powers will be close.
	/// If not, the image is very important, but not the black.
	/// TODO: Consider removing this, because it is not used.
	double power_usb_black(void) const {
		static double avg_pwr = 0.0 ;
		/// This value is obtained by watching the waterfall.
		static const int bandwidth_black = 20 ;
		double pwr = wf->powerDensity(m_carrier - fm_deviation, bandwidth_black);
		return decayavg(avg_pwr, pwr, 10);
	}

	/// Evaluates the signal power for APT stop frequency.
	double power_usb_apt_stop(void) const {
		static double avg_pwr = 0.0 ;
		/// This value is obtained by watching the waterfall.
		double pwr = wf->powerDensity(m_apt_stop_freq, 10);
		return decayavg(avg_pwr, pwr, 10);
	}

	/// This evaluates the signal/noise ratio for some specific bandwidths.
	class fax_signal {
		const fax_implementation * _ptr_fax ;
		int                        _cnt ; /// The value can be reused a couple of times.

		double                     _apt_start ;
		double                     _phasing ;
		double                     _image ;
		double                     _black ;
		double                     _apt_stop ;

		fax_state                  _state ; /// Deduction made based on signal power.
		const char *               _text;
		const char *               _stop_code;

		/// Finer tests can be added. These are all rule-of-thumb values based
		/// on observation of real signals.
		/// TODO: Adds a learning mode using the Hamfax detector to train the signal-based one.
		void set_state(void) {
			_state = IDLE ;
			_text = _("No signal detected");
			_stop_code = "" ;

			if ((_apt_start   > 20.0) &&
				(_phasing     < 10.0) &&
				(_image       < 10.0) &&
				(_apt_stop    < 10.0)) {
				_state = RXAPTSTART ;
				_text = _("Strong APT start signal: Skip to phasing.");
			}
			if (    /// The image signal may be weak if the others signals are even weaker.
			(	(_apt_start   <  1.0) &&
				(_phasing     <  1.0) &&
				(_image       > 10.0) &&
				(_apt_stop    <  1.0)) ||
			(	(_apt_start   <  1.0) &&
				(_phasing     <  0.5) &&
				(_image       >  8.0) &&
				(_apt_stop    <  0.5)) ||
			(	(_apt_start   <  3.0) &&
				(_phasing     <  1.0) &&
				(_image       > 15.0) &&
				(_apt_stop    <  1.0))) {
				_state = RXIMAGE ;
				_text = _("Strong image signal when getting APT start: Starting phasing.");
			}
			if ((_apt_start   < 10.0) &&
				(_phasing     > 20.0) &&
				(_image       < 10.0) &&
				(_apt_stop    < 10.0)) {
				_state = RXPHASING ;
				_text = _("Strong phasing signal when getting APT start: Starting phasing.");
			}
			/// TODO: Beware that quite often, it cuts image in the middle.
			// Maybe the levels should be amended.
			if ((_apt_start   <  2.0) &
				(_phasing     <  2.0) &&
				(_image       <  2.0) &&
				(_apt_stop    >  20.0)) {
				_state = RXAPTSTOP ;
				_text = _("Strong APT stop signal: Stopping reception.");
				_stop_code = "stop";
			}

			/// Consecutive lines in a wefax image have a strong statistical correlation.
			fax_state state_corr = _ptr_fax->correlation_state(&_stop_code);
			if ((_state == RXIMAGE) || (_state == IDLE)) {
				if (state_corr == RXAPTSTOP) {
					_state = RXAPTSTOP ;
					_text = _("No significant line-to-line correlation: Reception should stop.");
				}
			}

			if ((_state == IDLE) || (_state == RXAPTSTART) || (_state == RXPHASING)) {
				if (state_corr == RXIMAGE) {
					_state = RXIMAGE ;
					_text = _("Significant line-to-line correlation: Reception should start.");
				}
			}
		}

		void recalc(void) {
			/// Adds a small value to avoid division by zero.
			double noise = _ptr_fax->power_usb_noise() + 1e-10 ;

			/// Multiplications are faster than divisions.
			double inv_noise = 1.0 / noise ;

			_apt_start = _ptr_fax->power_usb_apt_start() * inv_noise ;
			_phasing   = _ptr_fax->power_usb_phasing()   * inv_noise ;
			_image     = _ptr_fax->power_usb_image()     * inv_noise ;
			_black     = _ptr_fax->power_usb_black()     * inv_noise ;
			_apt_stop  = _ptr_fax->power_usb_apt_stop()  * inv_noise ;

			set_state();
		}

		public:
		/// This recomputes, if needed, the various signal power ratios.
		void refresh(void) {
			/// Values reevaluated every X input samples. Must be smaller
			/// than the typical audio input frames (512 samples).
			static const int validity = 1000 ;

			/// Calculated at least the first time.
			if ((_cnt % validity) == 0) {
				recalc();
			}
			/// Does not matter if wrapped beyond 2**31.
			++_cnt ;
		}

		fax_signal(const fax_implementation * ptr_fax)
		: _ptr_fax(ptr_fax)
		, _cnt(0)
		, _text(NULL) {}

		fax_state signal_state(void) const { return _state ; }
		const char * signal_text(void) const { return _text; };
		const char * signal_stop_code(void) const { return _stop_code; }

		double image_noise_ratio(void) const { return _image ; }

		/// For debugging only.
		friend std::ostream & operator<<(std::ostream & refO, const fax_signal & ref_sig) {
			refO
				<< " start=" << std::setw(10) << ref_sig._apt_start
				<< " phasing=" << std::setw(10) << ref_sig._phasing
				<< " image=" << std::setw(10) << ref_sig._image
				<< " black=" << std::setw(10) << ref_sig._black
				<< " stop=" << std::setw(10) << ref_sig._apt_stop
				<< " pwr_state=" << state_to_str(ref_sig._state);
			return refO ;
		}

		std::string to_string(void) const {
			std::stringstream tmp_strm ;
			tmp_strm << *this ;
			return tmp_strm.str();
		}
	};

	/// We tolerate a small difference between the frequencies.
	bool is_near_freq(int f1, int f2, int margin) const {
		int delta = f1 - f2 ;
		if (delta < 0) {
			delta = -delta ;
		}
		if (delta < margin) {
			return true ;
		} else {
			return false ;
		}
	}

	void save_automatic(
		const char        * extra_msg,
		const std::string & comment);

	void decode_apt(int x, const fax_signal & the_signal);
	void decode_phasing(int x, const fax_signal & the_signal);
	bool decode_image(int x);

	// ABWEICHUNG fldigi (Digidec): Dateiwarteschlangen für XML-RPC und Senden (syncobj) entfallen

	/// Maybe we could reset this buffer when we change the state so that we could
	/// use the current LPM width.
	struct corr_buffer_t : public std::vector<unsigned char> {
		unsigned char at_mod(size_t i) const {
			return operator[](i % size());
		}
		unsigned char & at_mod(size_t i) {
			return operator[](i % size());
		}
	};

	mutable corr_buffer_t m_correlation_buffer ;
	mutable double m_curr_corr_avg ; // Average line-to-line correlation for the spec'd # sampled lines.
	mutable double m_imag_corr_max ; // Max line-to-line correlation for the current image.
	mutable double m_imag_corr_min ; // Min line-to-line correlation for the current image.
	mutable int m_corr_calls_nb;

	/// Evaluates the correlation between two lines separated by line_offset pixels.
	double correlation_from_index(size_t line_length, size_t line_offset) const {
                /// This is a ring buffer.
		size_t line_length_plus_img_sample = line_length + m_img_sample ;

		int avg_pred = 0, avg_curr = 0 ;
		for(size_t i = m_img_sample ; i < line_length_plus_img_sample ; ++i) {
			int pix_pred = m_correlation_buffer.at_mod(i              );
			int pix_curr = m_correlation_buffer.at_mod(i + line_offset);
			avg_pred += pix_pred;
			avg_curr += pix_curr ;
		}
		avg_pred /= line_length;
		avg_curr /= line_length;

		/// Use integers because it is faster. Samples are chars, so no overflow possible.
		int numerator = 0, denom_pred = 0, denom_curr = 0 ;
		for(size_t i = m_img_sample ; i < line_length_plus_img_sample ; ++i) {
			int pix_pred = m_correlation_buffer.at_mod(i              );
			int pix_curr = m_correlation_buffer.at_mod(i + line_offset);
			int delta_pred = pix_pred - avg_pred ;
			int delta_curr = pix_curr - avg_curr ;
			numerator += delta_pred * delta_curr ;
			denom_pred += delta_pred * delta_pred ;
			denom_curr += delta_curr * delta_curr ;
		}
		double denominator = sqrt((double)denom_pred * (double)denom_curr);
		if (denominator == 0.0) {
			return 0.0 ;
		} else {
			return fabs(numerator / denominator);
		}
	}

	size_t correlation_shift(size_t corr_smpl_lin) const {
		static bool is_init = false ;
		static const size_t max_space_echo = 100 ;

		/// Specific to the antenna and the reception, so no need to clean it up.
		static size_t shift_histogram[max_space_echo];
		static size_t nb_calls = 0 ;

		if (! is_init) {
			for(size_t i = 0; i < max_space_echo; ++i) shift_histogram[i] = 0 ;
			is_init = true ;
		}

		double tmpCorrPrev = correlation_from_index(corr_smpl_lin, 0);
		size_t local_max = 0 ;
		bool is_growing = false ;

		/// We could even start the loop later because we are not interested by small shifts.
		for(size_t i = 1 ; i < max_space_echo; i++) {
			double tmpCorr = correlation_from_index(corr_smpl_lin, i);
			bool is_growing_next = tmpCorr > tmpCorrPrev ;
			if (is_growing && (! is_growing_next )) {
				local_max = i - 1 ;
				break ;
			}
			is_growing = is_growing_next ;
			tmpCorrPrev = tmpCorr ;
		}

		if (local_max != 0) {
			++shift_histogram[local_max];
		}
		++nb_calls ;

		size_t best_shift_idx = 0 ;
		size_t biggest_shift = shift_histogram[best_shift_idx];
		if ((nb_calls > 100) && ((nb_calls % 10) == 0)) {
			for(size_t i = 0; i < max_space_echo; ++i) {
				size_t new_hist = shift_histogram[i];
				if (new_hist > biggest_shift) {
					biggest_shift = new_hist ;
					best_shift_idx = i ;
				}
			}

			LOG_VERBOSE("Shift: i = %d hist = %d", (int)best_shift_idx, (int)biggest_shift);
		}
		return best_shift_idx ;
	}

	static const int min_white_level = 128 ;

	/// Absolute value of statistical correlation between the current line and the previous one.
	/// Called once per maximum sample line.
	void correlation_calc(void) const {
		++m_corr_calls_nb;
		/// We should in fact take the smallest one, 60.
		size_t corr_smpl_lin = lpm_to_samples(m_default_lpm);
		double current_corr = correlation_from_index(corr_smpl_lin, corr_smpl_lin);

		/// This never happened, but who knows (Inaccuracy etc...)?
		if (current_corr > 1.0) {
			LOG_WARN("Inconsistent correlation:%lf", current_corr);
			current_corr = 1.0;
		}

		int crows = progdefaults.wefax_correlation_rows;
		if (m_corr_calls_nb < crows) {
			m_curr_corr_avg = current_corr ;
			/// The max value of the correlation must be significative (Does not take peak values).
			m_imag_corr_max = 0.0;
			m_imag_corr_min = 0.0;
		} else {
			/// Equivalent to decayavg with weight= (min_corr_lin +1)/min_corr_lin
			m_curr_corr_avg = (m_curr_corr_avg * crows + current_corr) / (crows + 1);
			m_imag_corr_max = std::max(m_curr_corr_avg, m_imag_corr_max);
			m_imag_corr_min = std::min(m_curr_corr_avg, m_imag_corr_min);
		}

		/// Debugging purpose only.
		if ((m_corr_calls_nb % 10) == 0) {
			LOG_DEBUG(
"current_corr = %lf m_curr_corr_avg = %lf m_imag_corr_max = %f m_corr_calls_nb = %d state = %s m_lpm_img = %f",
				current_corr, m_curr_corr_avg, m_imag_corr_max,
				m_corr_calls_nb, state_rx_str(), m_lpm_img);
		}
		double metric = m_curr_corr_avg * 100.0 ;
		m_ptr_wefax->display_metric(metric);
		return;
/*
static bool first = true;
if ((m_corr_calls_nb % 10) == 0) {
	if (first) {
		ofstream csv("stats.csv");
		csv << "current_corr,curr_corr_avg,imag_corr_max,corr_calls_nb,state,lpm_img,metric" << std::endl;
		first = false;
	}
	ofstream csv("stats.csv", ios::app);
	csv << 
		current_corr << "," << 
		m_curr_corr_avg << "," << 
		m_imag_corr_max << "," << 
		m_corr_calls_nb << "," << 
		state_rx_str() << "," << 
		m_lpm_img << "," << 
		metric << 
	std::endl;
	csv.close();
}
*/
	}

	/// This is called quite often. It estimates, based on the mobile
	/// average of statistical correlation between consecutive lines, whether this is a wefax
	/// signal or not.
	fax_state correlation_state(const char ** stop_code) const {
		fax_state & stable_state = m_st_stable_state ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		switch(stable_state) {
			case RXAPTSTART : *stop_code = "stable_start"  ; break;
			case RXAPTSTOP  : *stop_code = "stable_stop"   ; break;
			case RXPHASING  : *stop_code = "stable_phasing"; break;
			case RXIMAGE    : *stop_code = "stable_image"  ; break;
			case IDLE       : *stop_code = "stable_idle"   ; break;
			default         : *stop_code = "unexpected"    ; break;
		}

		/// If the mobile average is not computed on enough lines, returns IDLE
		/// which means "Do not know" in this context.
		if (m_corr_calls_nb >= progdefaults.wefax_correlation_rows) {
			int crr_row = m_img_sample / m_smpl_per_lin ;

			/// Sometimes, we detected a Stop just after the header, and we create an image
			/// of 300 lines. This is a rule of thumb. The bad consequence is that the image
			/// would be a bit too high. This an approximate row number.
			/// On the other hand, if we read very few lines, we assume this is just noise.
			double low_corr = progdefaults.wefax_correlation;
			/// If high threshold, we cut images in two.
			/// If low threshold, we go on reading an image after its end if apt stop is not seen,
			/// and might read the beginning of the next image.
			if (m_curr_corr_avg < low_corr) {
				LOG_DEBUG("Setting to stop m_curr_corr_avg = %f low_corr = %f", m_curr_corr_avg, low_corr);
				*stop_code = "nocorr";
				stable_state = RXAPTSTOP ;

			/// TODO: Beware, this is sometimes triggered with cyclic parasites.
			} else if (m_curr_corr_avg > 3 * low_corr / 2) {
				stable_state = RXIMAGE ;
			} else if ((m_imag_corr_max < 0.10) && (crr_row > 200)) {
				// If the correlation was always very low for many lines,
				// this means that we started to read a wrong image, so
				// there might be a wrong tuning or the DWD constant frequency.
				// So we trash the image.
				// TODO: It is done too many times: SOMETIMES THE MESSAGE IS REPEATED HUNDREDTH.
				// crr8row continues to grow although it makes no sense.
				LOG_INFO("Flushing dummy image m_imag_corr_max = %f crr_row = %d 200 lines.",
					m_imag_corr_max, crr_row);
				static const char * garbage_200 = GARBAGE_STR ".200";
				*stop_code = garbage_200;
				reset_afc();
				stable_state = RXAPTSTOP ;
			} else if ((m_imag_corr_max < 0.20) && (crr_row > 500)) {
				// If the max line-to-line correlation still low for a bigger image.
				LOG_INFO("Flushing dummy image m_imag_corr_max = %f crr_row = %d 500 lines.",
					m_imag_corr_max, crr_row);
				static const char * garbage_500 = GARBAGE_STR ".500";
				*stop_code = garbage_500;
				reset_afc();
				stable_state = RXAPTSTOP ;
			} else {
				stable_state = IDLE ;
			}
		}

		/// Message for first detection.
		if ((stable_state == IDLE) && (m_corr_calls_nb == progdefaults.wefax_correlation_rows)) {
			double & last_corr_avg = m_st_last_corr_avg ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
			if (m_curr_corr_avg != last_corr_avg) {
				LOG_INFO("Correlation average %lf m_imag_corr_max = %f: Detected %s",
					m_curr_corr_avg, m_imag_corr_max, state_to_str(stable_state));
				last_corr_avg = m_curr_corr_avg ;
			}
		}

		return stable_state;
	}

	/// We compute about the same when plotting a pixel.
	void correlation_update(int the_sample) {
		size_t corr_smpl_lin = lpm_to_samples(m_default_lpm);
		size_t corr_buff_sz = 2 * corr_smpl_lin ;

		size_t & cnt_upd = m_st_cnt_upd ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		if (m_correlation_buffer.size() != corr_buff_sz) {
			m_correlation_buffer.resize(corr_buff_sz, 0);
			m_curr_corr_avg = 0.0 ;
		}

		if ((cnt_upd % corr_smpl_lin) == 0) {
			correlation_calc();
		}
		++cnt_upd ;

		m_correlation_buffer.at_mod(m_img_sample) = the_sample ;

	} // correlation_update

	/// Clean trick so that we can reset internal variables of process_afc().
	void reset_afc() const {
		process_afc(true);
	}

	/// Called once for each row of input data.
	void process_afc(bool reset_afc = false) const {
		int & prev_row = m_st_prev_row ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		int & total_img_rows = m_st_total_img_rows ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		/// Audio frequency.
		int & stable_carrier = m_st_stable_carrier ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		static const int max_median_freqs = 20 ;
		double (& median_freqs)[ max_median_freqs ] = m_st_median_freqs ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		int & nb_median_freqs = m_st_nb_median_freqs ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static


		/// Rig frequency.
		long long & stable_rfcarrier = m_st_stable_rfcarrier ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		/// TODO: Maybe we could restrict the range of frequencies.
		if (reset_afc) {
			/// Displays the message only once.
			if (prev_row != -1) {
				LOG_DEBUG("Resetting AFC total_img_rows = %d",total_img_rows);
			}
			prev_row = -1 ;
			total_img_rows = 0 ;
			stable_carrier = 0;
			stable_rfcarrier = 0 ;
			nb_median_freqs = 0 ;
			return;
		}

		if (progStatus.afconoff == false) return ;

		/// The LPM might have changed, but this is very improbable.
		/// We do not know the LPM so we assume the default.
		double smpl_per_lin = lpm_to_samples(m_default_lpm);
		int crr_row = m_img_sample / smpl_per_lin ;

		if (crr_row == prev_row)
			return ;

		long long curr_rfcarr = wf->rfcarrier() ;

		/// If the freq changed, reset the number of good lines read.
		if ((m_carrier != stable_carrier)
		||  (curr_rfcarr != stable_rfcarrier)) {
			/// Displays the messages once only.
			if (total_img_rows != 0) {
				LOG_VERBOSE("Setting m_carrier = %d curr_rfcarr = %d total_img_rows = %d",
					m_carrier, static_cast<int>(curr_rfcarr), total_img_rows);
			}
			total_img_rows = 0 ;
			stable_carrier = m_carrier ;
			stable_rfcarrier = curr_rfcarr ;
		}

		/// If we could read a big portion of an image, then no adjustment.
		if (m_rx_state == RXIMAGE) {
			/// Maybe this is a new image so last_img_rows is from the previous image.
			if (prev_row < crr_row) {
				total_img_rows += crr_row - prev_row ;
			} else {
				LOG_DEBUG("prev_crr_row = %d crr_row = %d total_img_rows = %d", prev_row, crr_row, total_img_rows);
			}
		} else {
			LOG_DEBUG("State = %s crr_row = %d", state_rx_str(), crr_row);
		}
		prev_row = crr_row ;

		/// If we could succesfully read this number of lines, it must be the right frequency.
		static const int threshold_rows = 200 ;

		/// Consider than not only we could read many lines, but also other criterias such
		/// as correlation, or if we could read apt start/stop. Otherwise, it may stabilize a useless frequency.
		if ((total_img_rows >= threshold_rows) && (m_curr_corr_avg > 0.10)) {
			if (total_img_rows == threshold_rows) {
				LOG_VERBOSE("Stable total_img_rows = %d m_curr_corr_avg = %f", total_img_rows, m_curr_corr_avg);
			}
			//If the reception is always poor for a long time restart AFC.
			stable_carrier = progdefaults.WEFAX_Center;
			m_ptr_wefax->set_freq(stable_carrier);
			return ;
		}

		/// This centers the carrier where the activity is the strongest.
		const int bw_dual[][2] = { // ABWEICHUNG fldigi (Digidec): nicht static, damit ein geänderter Hub gilt
			{ -fm_deviation - 50, -fm_deviation + 50 },
			{  fm_deviation - 50,  fm_deviation + 50 } };
       		double max_carrier_dual = wf->powerDensityMaximum(2, bw_dual);

		const int bw_right[][2] = { // ABWEICHUNG fldigi (Digidec): nicht static
			{  fm_deviation - 50,  fm_deviation + 50 } };
       		double max_carrier_right = wf->powerDensityMaximum(1, bw_right);

		// This might have to be adjusted because DWD has all the energy on the right
		// band, but Northwood has some on the left.
		double max_carrier = 0.0 ;

		/// Maybe there is not enough room on the left.
		if (max_carrier_dual < 0.0) {
			LOG_DEBUG("Invalid AFC: Dual band = %f, right band = %f. Take right",
			max_carrier_dual, max_carrier_right);
			max_carrier = max_carrier_right - fm_deviation;
		} else
		/// Both mask detect approximately the same frequency: This is the consistent case.
		if (fabs(max_carrier_dual - max_carrier_right) < 20) {
			max_carrier = max_carrier_right - fm_deviation;
		} else
		if (max_carrier_dual < max_carrier_right) {
			LOG_DEBUG("Inconsistent AFC: Dual band = %f, right band = %f. Take right",
			max_carrier_dual, max_carrier_right);
			max_carrier = max_carrier_right - fm_deviation;
		} else
		/// Single-band mask close to the left frequency of the dual-freq mask
		if (fabs(fabs(max_carrier_dual - max_carrier_right) - 2 * fm_deviation) < 20) {
			LOG_DEBUG("Dual band = %f instead of right band = %f. Take dual",
			max_carrier_dual, max_carrier_right);
			max_carrier = max_carrier_dual ;
		} else {
			LOG_DEBUG("Inconsistent AFC: Dual band = %f, right band = %f. Take dual.",
			max_carrier_dual, max_carrier_right);
			max_carrier = max_carrier_dual ;
		}

		/// The max power is unreachable, there might be another reason. Stay where we are.
		bool & prevWasRight = m_st_prevWasRight ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		/// TODO: We might find the next solution, maybe by giving to powerDensityMaximum a smaller range.
		if ((max_carrier <= fm_deviation) || (max_carrier >= IMAGE_WIDTH - fm_deviation)) {
			/// Display this message once only.
			if (prevWasRight) {
				LOG_VERBOSE("Invalid max_carrier = %f", max_carrier);
			}
			prevWasRight = false ;
			return ;
		} else {
			prevWasRight = true ;
		}

		// TODO: If the correlation is below a given threshold, it might be useless to add it.
		median_freqs[ nb_median_freqs % max_median_freqs ] = max_carrier ;
		++nb_median_freqs;
		if (nb_median_freqs >= max_median_freqs) {
			std::sort(median_freqs, median_freqs + max_median_freqs);
			max_carrier = median_freqs[ max_median_freqs / 2 ];
		}

/// Do not change the frequency too quickly if an image is received.
/// Reject large excursions in carrier

		if (fabs(m_carrier - max_carrier) > 10)
			return;
		stable_carrier += 0.10*(max_carrier - stable_carrier);
		if (stable_carrier < (progdefaults.WEFAX_Center - 25))
			stable_carrier = progdefaults.WEFAX_Center;
		if (stable_carrier > (progdefaults.WEFAX_Center + 25))
			stable_carrier = progdefaults.WEFAX_Center;
		m_ptr_wefax->set_freq(stable_carrier);

		LOG_DEBUG("m_carrier = %f max_carrier = %f next_carr = %d", (double)m_carrier, max_carrier, stable_carrier);
	}
private:
	// ABWEICHUNG fldigi (Digidec): Zustände, die fldigi in static-Variablen hält
	mutable fax_state m_st_stable_state = IDLE ;
	mutable double m_st_last_corr_avg = 0.0 ;
	size_t m_st_cnt_upd = 0 ;
	mutable int m_st_prev_row = -1 ;
	mutable int m_st_total_img_rows = 0 ;
	mutable int m_st_stable_carrier = 0 ;
	mutable double m_st_median_freqs[ 20 ] = {} ;
	mutable int m_st_nb_median_freqs = 0 ;
	mutable long long m_st_stable_rfcarrier = 0 ;
	mutable bool m_st_prevWasRight = true ;
	int m_st_curr_freq = 0 ;
	int m_st_cr_1_freq = 0 ;
	int m_st_cr_2_freq = 0 ;
	int m_st_cr_3_freq = 0 ;
	size_t m_st_phasing_count = 0 ;
	int m_st_phasing_history[ 16 ] = {} ;
}; // class fax_implementation

// ABWEICHUNG fldigi (Digidec): Definition des statischen Filtersatzes entfällt (Objektvariable)

fax_implementation::fax_implementation(int fax_mode, wefax * ptr_wefax )
	: m_ptr_wefax(ptr_wefax)
	, m_dbl_sine(8192),m_dbl_cosine(8192),m_dbl_arc_sine(256)
	, m_short_sine(8192)
{
	m_apt_stop_freq  = 450 ;
	m_img_color      = false ;
	m_tx_phasing_lin = 20 ;
	m_carrier        = progdefaults.WEFAX_Center ;
	m_start_duration = 5 ;
	m_stop_duration  = 5 ;
	m_manual_mode    = false ;
	m_rx_state       = IDLE ;
	m_tx_state       = IDLE ;
	m_sample_rate    = 0 ;
	reset_counters();

	int index_of_correlation ;
	/// http://en.wikipedia.org/wiki/Radiofax

	switch(fax_mode) {
		default:
		case MODE_WEFAX_576:
			m_apt_start_freq     = 300 ;
			index_of_correlation = IOC_576 ;
			m_default_lpm        = all_lpm_values[progdefaults.wefax_lpm_576].m_value;
			break;
		case MODE_WEFAX_288:
			m_apt_start_freq     = 675 ;
			index_of_correlation = IOC_288 ;
			m_default_lpm        = all_lpm_values[progdefaults.wefax_lpm_288].m_value;
			break;
	}

	m_img_width = ioc_to_width(index_of_correlation);

	for(size_t i = 0; i<m_dbl_sine.size(); i++) {
		m_dbl_sine[i] = std::sin(2.0*M_PI*i/m_dbl_sine.size());// * 32768.0;
	}
	for(size_t i = 0; i<m_dbl_cosine.size(); i++) {
		m_dbl_cosine[i] = std::cos(2.0*M_PI*i/m_dbl_cosine.size()); // * 32768.0;
	}
	for(size_t i = 0; i<m_dbl_arc_sine.size(); i++) {
		m_dbl_arc_sine[i] = std::asin(2.0*i/m_dbl_arc_sine.size()-1.0)/2.0/M_PI;
	}
	for(size_t i = 0; i<m_short_sine.size(); i++) {
		m_short_sine[i] = static_cast<short>(32767*std::sin(2.0*M_PI*i/m_short_sine.size()));
	}
};

void fax_implementation::init_rx(int the_smpl_rat)
{
	m_sample_rate = the_smpl_rat;
	m_rx_state = RXAPTSTART;
	rx_state_changed = true;
	m_apt_count = m_apt_trans = 0;
	m_apt_high = false;
	/// Centers the carriers on the GUI and reinits the trigonometric tables.
	m_ptr_wefax->set_freq(progdefaults.WEFAX_Center);

	reset_increments();
	m_i_fir_old = m_q_fir_old = 0;
	m_corr_calls_nb = 0;

	deviation_ratio = (m_sample_rate / progdefaults.WEFAX_Shift) / TWOPI;

	lpm_set();
}

/// Values are between zero and 255
void fax_implementation::decode(const int* buf, int nb_samples)
{
	if (nb_samples == 0) {
		LOG_WARN(_("Empty buffer."));
		end_rx();
	}
	fax_signal my_signal(this);
	process_afc();
	lpm_set();

	for(int i = 0; i<nb_samples; i++) {
		int crr_val = buf[i];
		my_signal.refresh();
		m_current_value = crr_val;

		correlation_update(crr_val);

		if (m_manual_mode) {
			m_rx_state = RXIMAGE;
			rx_state_changed = true;
			bool is_max_lines_reached = decode_image(crr_val);
			if (is_max_lines_reached) {
				skip_apt_rx();
				skip_phasing_rx(false);
				LOG_DEBUG(_("Max lines reached in manual mode: Resuming reception."));
				if (m_manual_mode == false) {
					LOG_ERROR(_("Inconsistent manual mode."));
				}
			}
		} else {
			decode_apt(crr_val,my_signal);
			if (m_rx_state == RXPHASING || m_rx_state == RXIMAGE) {
				decode_phasing(crr_val, my_signal);
			}
			if ((m_rx_state == RXIMAGE) && m_lpm_img > 0) {
				/// If the maximum number of lines is reached, we stop the reception.
				decode_image(crr_val);
			}
		}
		m_img_sample++;
	}
	if (rx_state_changed) {
		std::string str_state;
		switch(m_rx_state) {
			case RXAPTSTART : str_state = "APT start"; break;
			case RXAPTSTOP  : str_state = "APT stop"; break;
			case RXPHASING  : str_state = "Rx  Phasing"; break;
			case RXIMAGE    : str_state = "Rx  Image"; break;
			default :
			case IDLE       : str_state = "Idle"; break;
		}
		put_Status2(str_state.c_str());
		rx_state_changed = false;
	}
}

// The number of transitions between black and white is counted. After 1/2
// second, the frequency is calculated. If it matches the APT start frequency,
// the state skips to the detection of phasing lines, if it matches the apt
// stop frequency two times, the reception is ended.
void fax_implementation::decode_apt(int x, const fax_signal & the_signal)
{
	if ((m_img_sample % 10000) == 0) {
		PUT_STATUS(state_rx_str() << " apt_count = " << m_apt_count);
	}

	/// Maybe the thresholds 229 and 25 should be changed if the image is not contrasted enough.
	// if (x>229 && !m_apt_high) {
	if (x>215 && !m_apt_high) {
		m_apt_high = true;
		++m_apt_trans;
	// } else if (x<25 && m_apt_high) {
	} else if (x<40 && m_apt_high) {
		m_apt_high = false;
	}
	++m_apt_count ;

	/// This makes one line if LPM = 120: // samples_per_line = m_sample_rate * 60.0 / the_lpm ;
	 if (m_apt_count >= m_sample_rate/2) {
		int & curr_freq = m_st_curr_freq ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		int & cr_1_freq = m_st_cr_1_freq ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		int & cr_2_freq = m_st_cr_2_freq ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		int & cr_3_freq = m_st_cr_3_freq ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		// For APT start, we have several lines with freq=300 nearly exactly.
		// For APT stop, one or two lines maximum with freq=452, and this is not accurate.
		// On top of that, sometimes lines randomly have 300 or 452 black-white transitions,
		// especially if the signal is very noisy. This is why we check the transitions
		// frequency of two consecutive lines.
		cr_3_freq = cr_2_freq;
		cr_2_freq = cr_1_freq;
		cr_1_freq = curr_freq;
		curr_freq = m_sample_rate*m_apt_trans/m_apt_count;

		/// This writes the S/R level on the status bar.
		double tmp_snr = the_signal.image_noise_ratio();
		char snr_buffer[64];
        	snprintf(snr_buffer, sizeof(snr_buffer), "s/n %3.0f dB", 20.0 * log10(tmp_snr));
		put_Status1(snr_buffer);

		LOG_DEBUG("m_apt_count = %d m_apt_trans = %d curr_freq = %d cr_1_freq = %d cr_2_freq = %d",
				m_apt_count, m_apt_trans, curr_freq, cr_1_freq, cr_2_freq);

		m_apt_count = m_apt_trans = 0;

		if (m_rx_state == RXAPTSTART) {
			if (is_near_freq(curr_freq,m_apt_start_freq, 8)
			&&  is_near_freq(cr_1_freq,m_apt_start_freq, 8)) {
				LOG_VERBOSE(_("Skipping APT freq = %d State = %s"),
						curr_freq, state_rx_str());
				skip_apt_rx();
				PUT_STATUS(state_rx_str() << ", " << _("frequency") << ": "
						<< curr_freq << " Hz. " << _("Skipping."));
				return ;
			}
			if (is_near_freq(curr_freq,m_apt_stop_freq, 2)
			&&  is_near_freq(cr_1_freq,m_apt_stop_freq, 2)) {
				LOG_VERBOSE(_("Spurious APT stop frequency = %d Hz as waiting for APT start. SNR = %f State = %s"),
						curr_freq, tmp_snr, state_rx_str());
				return ;
			}

			PUT_STATUS(state_rx_str() << ", " << _("frequency") << ": " << curr_freq << " Hz.");
		}

		/// If APT start in the middle of an image, maybe the preceding APT Stop was not caught.
		if (m_rx_state == RXIMAGE) {
			/// TODO: We could enhance accuracy by taking into account the number of read lines.
			int crr_row = m_img_sample / m_smpl_per_lin ;

			const char * msg_start = NULL ;
			if (is_near_freq(curr_freq,m_apt_start_freq, 4)
			&&  is_near_freq(cr_1_freq,m_apt_start_freq, 4)
			&&  is_near_freq(cr_2_freq,m_apt_start_freq, 4)) {
				msg_start = "apt";
			} else
			if (is_near_freq(curr_freq,m_apt_start_freq, 5)
			&&  is_near_freq(cr_1_freq,m_apt_start_freq, 5)
			&&  is_near_freq(cr_2_freq,m_apt_start_freq, 5)
			&&  is_near_freq(cr_3_freq,m_apt_start_freq, 5)) {
				msg_start = "apt2";
			}

			if (msg_start != NULL) {
				std::string comment = strformat(
					"APT start: freq = %d cr_1 = %d cr_2 = %d cr_3 = %d crr_row = %d State = %s msg = %s",
					curr_freq, cr_1_freq, cr_2_freq, cr_3_freq, crr_row, state_rx_str(), msg_start);
				LOG_VERBOSE("%s",comment.c_str());
				PUT_STATUS(state_rx_str() << ", " << _("frequency") << ": "
						<< curr_freq << " Hz. " << _("Skipping."));
				save_automatic(msg_start,comment);
				skip_apt_rx();
				return ;
			}
		}

		/// TODO: Check that the correlation is not too high because there are false stops.
		const char * msg_stop = NULL ;
		if (is_near_freq(curr_freq,m_apt_stop_freq, 6)
		&&  is_near_freq(cr_1_freq,m_apt_stop_freq, 6)) {
			msg_stop = "ok" ;
		} else
		if (is_near_freq(curr_freq,m_apt_stop_freq, 7)
		&&  is_near_freq(cr_1_freq,m_apt_stop_freq, 7)
		&&  is_near_freq(cr_2_freq,m_apt_stop_freq, 7)) {
			msg_stop = "ok2" ;
		}

		if (msg_stop != NULL) {
			std::string comment = strformat(
				"APT Stop: curr_freq = %d m_img_sample = %d State = %s_ msg = %s",
				curr_freq, m_img_sample, state_rx_str(), msg_stop);
			LOG_VERBOSE("%s",comment.c_str());
			PUT_STATUS(state_rx_str() << " " << _("Apt stop frequency") << ": "
					<< curr_freq << " Hz. " << _("Stopping."));
			save_automatic(msg_stop,comment);
			return ;
		}

		switch(the_signal.signal_state()) {
		case RXAPTSTART :
			switch(m_rx_state) {
				case RXAPTSTART :
					skip_apt_rx();
					LOG_VERBOSE("Start, start: %s", the_signal.signal_text());
					break ;
				default :
					LOG_DEBUG("Start, %s: %s", state_rx_str(), the_signal.signal_text());
					break ;
			}
			break ;
		case RXPHASING :
			switch(m_rx_state) {
				case RXAPTSTART :
					skip_apt_rx();
					LOG_VERBOSE("Phasing, start: %s", the_signal.signal_text());
					break ;
				default :
					LOG_DEBUG("Phasing, %s: %s", state_rx_str(), the_signal.signal_text());
					break ;
			}
			break ;
		case RXIMAGE :
			switch(m_rx_state) {
				case RXAPTSTART :
					skip_apt_rx();
					/// The phasing step will start receiving the image later. First we try
					/// to phase the image correctly.
					LOG_VERBOSE("Image, start: %s", the_signal.signal_text());
					break ;
				default :
					LOG_DEBUG("Image, %s: %s", state_rx_str(), the_signal.signal_text());
					break ;
			}
			break ;
		case RXAPTSTOP :
			switch(m_rx_state) {
				case RXIMAGE    :
					LOG_VERBOSE("Stop, image: %s", the_signal.signal_text());
					save_automatic(the_signal.signal_stop_code(), the_signal.signal_text());
					break;
				default :
					LOG_DEBUG("Stop, %s: %s", state_rx_str(), the_signal.signal_text());
					break ;
			}
			break ;
		default :
			LOG_DEBUG("%s, %s: %s", state_to_str(the_signal.signal_state()), state_rx_str(), the_signal.signal_text());
			break ;
		}
	}
}

/// This generates a file name with the reception time and the frequency.
std::string fax_implementation::generate_filename(const char *extra_msg) const
{
	time_t tmp_time = time(NULL);
	struct tm tmp_tm ;
	localtime_r(&tmp_time, &tmp_tm);

	char buf_fil_nam[256] ;
	unsigned long long tmp_fl = wf->rfcarrier() ;
	snprintf(buf_fil_nam, sizeof(buf_fil_nam),
		"wefax_%04d%02d%02d_%02d%02d%02d_%llu_%s.png",
		1900 + tmp_tm.tm_year,
		1 + tmp_tm.tm_mon,
		tmp_tm.tm_mday,
		tmp_tm.tm_hour,
		tmp_tm.tm_min,
		tmp_tm.tm_sec,
		tmp_fl,
		extra_msg);

	return buf_fil_nam ;
}

/// This saves an image and adds the right comments.
void fax_implementation::save_automatic(
		const char        * extra_msg,
		const std::string & comment)
{
	std::string new_filnam ;
	std::stringstream extra_comments ;

	/// These criteria used by rules-of-thumb to eliminate blank images.
	m_statistics.calc();
	double avg = m_statistics.average();
	double stddev = m_statistics.stddev();
	int current_row = m_img_sample / m_smpl_per_lin ;

	/* Sometimes the AFC leaves the right frequency (Because no signal) and it produces
	 * images which are plain wrong (Pure periodic parasites). We might find
	 * a criteria to suppress them but maybe it's better to enhance AFC. */

	/// Minimum pixel numbers for a valid image.
	static const int max_fax_pix_num = 150000 ;
	if (m_fax_pix_num < max_fax_pix_num) {
		/// Maybe we should reset AFC ?
		LOG_VERBOSE(_("Do not save small image (%d bytes). Manual = %d"), m_fax_pix_num, m_manual_mode);
		goto cleanup_rx ;
	}

	/// If correlation was always low.
	if (0 == strncmp(extra_msg, GARBAGE_STR, strlen(GARBAGE_STR))) {
		LOG_VERBOSE(_("Do not save garbage file"));
		goto cleanup_rx ;
	}

	static const double min_max_correlation = 0.20 ;
	if (m_imag_corr_max < min_max_correlation) {
		LOG_VERBOSE(_("Do not save image with correlation < less than %f"), min_max_correlation);
		goto cleanup_rx ;
	}

	/// Intermediate blank images, low standard deviation and correlation.
	if (((avg > 220) && (m_imag_corr_max < 0.30) && (stddev < 30))
	 || ((avg > 240) && (m_imag_corr_max < 0.35) && (stddev < 30))
	 || ((avg > 230) && (m_imag_corr_max < 0.25) && (stddev < 35))
	 || ((avg > 220)                               && (stddev < 20))) {
		LOG_VERBOSE(_("Do not save non-significant image, avg = %f, m_imag_corr_max = %f stddev = %f"),
				avg, m_imag_corr_max, stddev);
		goto cleanup_rx ;
	}

	/// Dark images coming from local parasites.
	if ((avg < 100) && (m_imag_corr_max < 0.30)) {
		LOG_VERBOSE(_("Do not save dark parasite image, avg = %f, m_imag_corr_max = %f"), avg, m_imag_corr_max);
		goto cleanup_rx ;
	}

	/// Same: Dark images due to parasites.
	if ((avg < 80) && (m_imag_corr_max < 0.35)) {
		LOG_VERBOSE(_("Do not save dark parasite image (II), avg = %f, m_imag_corr_max = %f"), avg, m_imag_corr_max);
		goto cleanup_rx ;
	}

	if ((avg > 235) && (m_imag_corr_max < 0.65) && (stddev < 40) && (current_row < 100)) {
		LOG_VERBOSE(_("Do not save small white image, avg = %f, m_imag_corr_max = %f stddev = %f current_row = %d"),
				avg, m_imag_corr_max, stddev, current_row);
		goto cleanup_rx ;
	}

	/// Small image cut between APT start and phasing.
	if ((avg < 130) && (m_imag_corr_max < 0.70) && (stddev < 100) && (current_row < 100)) {
		LOG_VERBOSE(_("Do not save small white image, avg = %f, m_imag_corr_max = %f stddev = %f current_row = %d"),
				avg, m_imag_corr_max, stddev, current_row);
		goto cleanup_rx ;
	}


	new_filnam = generate_filename(extra_msg);
	LOG_VERBOSE("Saving %d bytes in %s. m_imag_corr_max = %f", m_fax_pix_num, new_filnam.c_str(), m_imag_corr_max);

	extra_comments << "ControlMode:"                      << (m_manual_mode ? "Manual" : "APT control") << "\n" ;
	extra_comments << "LPM:"                              << m_lpm_img << "\n" ;
	extra_comments << "Carrier:"                          << m_carrier << "\n" ;
	extra_comments << "Inversion:"                        << (m_phase_inverted ? "Inverted" : "Normal") << "\n" ;
	extra_comments << "Color:"                            << (m_img_color ? "Color" : "BW") << "\n" ;
	extra_comments << "SampleRate:"                       << m_sample_rate << "\n" ;
	extra_comments << "Maximum line-to-line correlation:" << m_imag_corr_max << "\n" ;
	extra_comments << "Minimum line-to-line correlation:" << m_imag_corr_min << "\n" ;
	extra_comments << "Average:"                          << avg << "\n" ;
	extra_comments << "Row number:"                       << current_row << "\n" ;
	extra_comments << "Standard deviation:"               << stddev << "\n" ;
	extra_comments << "Comment:"                          << comment << "\n" ;
	extra_comments << "PID:"                              << getpid() << "\n" ;
	wefax_pic::save_image(new_filnam, extra_comments.str());

cleanup_rx:
	/// This clears the current image.
	end_rx();
};

// Phasing lines consist of 2.5% white at the beginning, 95% black and again
// 2.5% white at the end (or inverted). In normal phasing lines we try to
// count the length between the white-black transitions. If the line has
// a reasonable amount of black (4.8%--5.2%) and the length fits in the
// range of 60--360 lpm (plus some tolerance) it is considered a valid
// phasing line. Then the start of a line and the lpm is calculated.
void fax_implementation::decode_phasing(int x, const fax_signal & the_signal)
{
	static const bool filter_phasing = true ;

	if (filter_phasing) {
		// The input is filtered over X columns because the blacks bands are very wide.
		static const size_t phasing_width = 16 ;
		size_t & phasing_count = m_st_phasing_count ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static
		int (& phasing_history)[ phasing_width ] = m_st_phasing_history ; // ABWEICHUNG fldigi (Digidec): Objektvariable statt static

		/// Mobile average filters out parasites.
		phasing_history[ phasing_count % phasing_width ] = x ;
		++phasing_count ;
		if (phasing_count >= phasing_width) {
			x = 0 ;
			for(size_t i = 0; i < phasing_width; ++i) x += phasing_history[ i ];
			x /= phasing_width ;
		}
	}

	/// Number of samples per line.
	m_curr_phase_len++;
	++m_phasing_calls_nb ;

	/// Number of white / black pixels.
	if (x > 188) m_curr_phase_high++;
	else if (x < 68) m_curr_phase_low++;

	/* If the high level is too high (229) we miss some phasing lines.
	 * but if it is too low (200) the center is not at the right place.
	 * We should instead use an histogram and determine what is the highest level in the image. */
	// if ((!m_phase_inverted && x>229 && !m_phase_high) ||
	if ((!m_phase_inverted && x > 200 && !m_phase_high) ||
	   (m_phase_inverted && x < 25  && m_phase_high)) {
		m_phase_high = m_phase_inverted ? false : true;
	}
	else if ((!m_phase_inverted && x < 25 && m_phase_high) ||
		  (m_phase_inverted && x > 200 && !m_phase_high)) {
		m_phase_high = m_phase_inverted ? true : false;

		/// In the phasing line, there is a white segment of 5% of the total length,
		// so it is approximated with 0.048->0.052.
		if (m_curr_phase_high >= (m_phase_inverted ? 0.94 : 0.04) * m_curr_phase_len &&
			m_curr_phase_low  >= (m_phase_inverted ? 0.04 : 0.94) * m_curr_phase_len &&
			m_curr_phase_len >= 0.4 * m_sample_rate) {

			double tmp_lpm = 60.0 * m_sample_rate / m_curr_phase_len;

			m_lpm_sum_rx += tmp_lpm;
			++m_phase_lines;

			PUT_STATUS(state_rx_str()
				<< ". " << _("Decoding phasing line") << ", lpm = " << tmp_lpm
				<< " " << _("count") << "=" << m_phase_lines);

			m_num_phase_lines = 0;
			// This option was selected just once, in the middle of an image,
			// with many vertical lines.
			if (m_phase_lines >= 4 /* Was 4 */) {
				/// The precision cannot really increase because there cannot
				// be more than a couple of loops. This is used for guessing
				// whether the LPM is around 120 or 60.
				lpm_set();
				std::string comment = strformat(
"m_phase_lines = %d, m_num_phase_lines = %d, LPM = %f State = %s, \
 m_img_sample = %d, m_last_col = %d, m_lpm_img = %f, m_smpl_per_lin = %f",
					m_phase_lines, m_num_phase_lines, m_lpm_img, state_rx_str(),
				       	m_img_sample, m_last_col, m_lpm_img, m_smpl_per_lin);
				LOG_VERBOSE("%s", comment.c_str());

				skip_phasing_to_image_save(comment);

				/// reset_counters sets these to zero, so restore right values.
				// But skip_phasing_to_image normalizes the LPM if not accurate.

				/// Half of the band of the phasing line.
				m_img_sample = static_cast<int>(1.025 * m_smpl_per_lin);

				double tmp_pos = std::fmod(m_img_sample,m_smpl_per_lin) / m_smpl_per_lin;
				m_last_col = static_cast<int>(tmp_pos*m_img_width);

				/// Now the image will start at the right column offset.
				m_fax_pix_num = m_last_col * bytes_per_pixel ;

				LOG_VERBOSE("Center set: m_last_col = %d m_img_width = %d m_smpl_per_lin = %f",
					m_last_col, m_img_width, m_smpl_per_lin);

			}
			m_curr_phase_len = 0;
		} else if (m_rx_state == RXPHASING && m_phase_lines > 0 && ++m_num_phase_lines >= 5) {
			/// TODO: Compare with m_tx_phasing_lin which indicates the number of phasing
			/// lines sent when transmitting an image.
			std::string comment = strformat(
				"Missed last phasing line m_phase_lines = %d m_num_phase_lines = %d LPM = %f State = %s",
				m_phase_lines, m_num_phase_lines, m_lpm_img, state_rx_str());
			LOG_VERBOSE("%s", comment.c_str());
			/// Phasing header is finished but could not get the center.
			skip_phasing_to_image(true);
		} else if (m_curr_phase_len > 5*m_sample_rate) {
			m_curr_phase_len = 
			m_curr_phase_high = 
			m_curr_phase_low = 0;
			PUT_STATUS(state_rx_str() << ". " << _("Decoding phasing line, resetting."));
		} else {
			/// Here, if no phasing is detected. Must be very fast.
		}
		PUT_STATUS(state_rx_str() << ". " << _("Decoding phasing line, reset."));
		m_curr_phase_len = 
		m_curr_phase_high = 
		m_curr_phase_low = 0;
	}
	else if (m_rx_state == RXPHASING) {
		/// We do not know the LPM so we assume the default.
		/// TODO: We could take the one given by the GUI. Apparently; problem for Japanese faxes when lpm = 60:
		// http://forums.radioreference.com/digital-signals-decoding/228802-problems-decoding-wefax.html
		double smpl_per_lin = lpm_to_samples(m_default_lpm);
		int smpl_per_lin_int = smpl_per_lin ;
		int nb_tested_phasing_lines = m_phasing_calls_nb / smpl_per_lin ;

		/// If this is too big, we lose the beginning of the fax.
		// If this is too small, we start recording when we should not (But why not starting early ?)
		// Value was: 30
		static const int max_tested_phasing_lines = 20 ;
		if (
			(m_phase_lines == 0) &&
			(m_num_phase_lines == 0) &&
		 	(nb_tested_phasing_lines >= max_tested_phasing_lines) &&
			((m_phasing_calls_nb % smpl_per_lin_int) == 0)) {
			switch(the_signal.signal_state()) {
			case RXIMAGE :
				LOG_VERBOSE(_("Starting reception when phasing:%s"), the_signal.signal_text());
				skip_phasing_to_image(true);
				break ;
			/// If RXPHASING, we stay in phasing mode.
			case RXAPTSTOP :
				/// Do not display the same message over and over.
				LOG_DEBUG(_("Strong APT stop when phasing:%s"), the_signal.signal_text());
				end_rx();
				skip_apt_rx();
			default : break ;
			}
		}
	}
}

bool fax_implementation::decode_image(int x)
{
	double current_row_dbl = m_img_sample / m_smpl_per_lin ;
	int current_row = current_row_dbl ;
	int curr_col = m_img_width * (current_row_dbl - current_row) ;

	if (curr_col == m_last_col) {
		m_pixel_val+=x;
		m_pix_samples_nb++;
	} else {
		if (m_pix_samples_nb>0) {
			m_pixel_val /= m_pix_samples_nb;
			REQ(wefax_pic::update_rx_pic_bw, m_pixel_val, m_fax_pix_num);
			m_statistics.add_bw(m_pixel_val);
			m_fax_pix_num += bytes_per_pixel ;
		}
		m_last_col = curr_col;
		m_pixel_val = x;
		m_pix_samples_nb = 1;
	}

	/// Prints the status from time to time.
	if ((m_img_sample % 10000) == 0) {
		PUT_STATUS(state_rx_str()
			<< ". " << _("Image reception")
			<< ", " << _("sample") << "=" << m_img_sample);
	}

	/// Hard-limit to the number of rows.
	if (current_row >= progdefaults.WEFAX_MaxRows) {
		std::string comment = strformat(_("Maximum number of rows %d reached:%d. m_last_col = %d Manual = %d"),
			progdefaults.WEFAX_MaxRows, current_row, m_last_col, m_manual_mode);
		LOG_VERBOSE("%s", comment.c_str());
		/// The reception might be very poor, so reset AFC.
		reset_afc();
		save_automatic("max",comment);
		return true ;
	} else {
		return false ;
	}
}

/// Called automatically or by the GUI, when clicking "Skip APT"
void fax_implementation::skip_apt_rx(void)
{
	LOG_VERBOSE("state = %s",state_rx_str());
	REQ(wefax_pic::skip_rx_apt);
	if (m_rx_state!= RXAPTSTART) {
		LOG_ERROR(_("Should be in APT state. State = %s. Manual = %d"), state_rx_str(), m_manual_mode);
	}
	lpm_set();
	m_rx_state = RXPHASING;
	rx_state_changed = true;
	reset_phasing_counters();
	m_img_sample = 0; /// Used for correlation between consecutive lines.
	m_imag_corr_max = 0.0 ; // Used for finally deciding whether it is worth saving the image.
	m_imag_corr_min = 1.0 ; // Used for finally deciding whether it is worth saving the image.
	m_statistics.reset();
}

void fax_implementation::skip_phasing_to_image_save(const std::string & comment)
{
	switch(m_rx_state) {
		/// Maybe we were still reading an image when the phasing band was detected.
		case RXIMAGE :
			LOG_VERBOSE("Detected phasing when in image state.");
			save_automatic("phasing",comment);
			skip_apt_rx();
			break ;
		default:
			LOG_ERROR(_("Should be in phasing or image state. State = %s"), state_rx_str());
		case RXPHASING:
			break ;
	}
	/// Because we might find a phasing band when reading an image.
	reset_phasing_counters();
	/// Auto-centering by default. Beware that if an image is saved and
	/// if we lose samples, the alignment is lost.
	skip_phasing_to_image(false);
}

/// Called by the user when skipping phasing,
/// or automatically when phasing is detected.
void fax_implementation::skip_phasing_to_image(bool auto_center)
{
	m_ptr_wefax->qso_rec_init();

	REQ(wefax_pic::skip_rx_phasing, auto_center);
	m_rx_state = RXIMAGE;
	rx_state_changed = true;

	lpm_set();
}

/// Called by the user when clicking button. Never called automatically.
void fax_implementation::skip_phasing_rx(bool auto_center)
{
	if (m_rx_state!= RXPHASING) {
		LOG_ERROR(_("Should be in phasing state. State = %s"), state_rx_str());
	}
	skip_phasing_to_image(auto_center);

	m_img_sample = 0; /// The image start may not be what the phasing would have told.
}

// Here we want to remove the last detected phasing line and the following
// non phasing line from the beginning of the image and one second of apt stop
// from the end
void fax_implementation::end_rx(void)
{
	/// Synchronized otherwise there might be a crash if something tries to access the data.
	REQ(wefax_pic::abort_rx_viewer);
	m_rx_state = RXAPTSTART;
	rx_state_changed = true;
	reset_counters();
}

#define CLIP 0.001
/// Receives data from the soundcard.
void fax_implementation::rx_new_samples(const double* audio_ptr, int audio_sz)
{
	int demod[audio_sz];
	int ix = 0;

	/// The reception filter may have been changed by the GUI.
	if (progdefaults.wefax_filter > 2 || progdefaults.wefax_filter < 0)
		progdefaults.wefax_filter = 0;

	C_FIR_filter & ref_fir_filt_pair = m_rx_filters[ progdefaults.wefax_filter];

	for (int i = 0; i < audio_sz; i++) {
		if (!ref_fir_filt_pair.run(
			cmplx (audio_ptr[i] * m_dbl_cosine.next_value(), audio_ptr[i] * m_dbl_sine.next_value()),
			currz)) continue;

		if (abs(currz) <= CLIP && abs(prevz) <= CLIP)
			demod[i] = 255; // white
		else {
			ix = round (255 * (0.5 - deviation_ratio * arg (conj (prevz) * currz)));
			demod[i] = std::min (std::max (0, ix), 255);
		}
		prevz = currz;

	}

	decode(demod, audio_sz);
}


#undef progdefaults
#undef progStatus
#undef wf
#undef put_Status1
#undef put_Status2

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
