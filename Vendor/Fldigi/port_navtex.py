# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
import os, re, sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../_upstream/fldigi-4.2.13/src/navtex/navtex.cxx')
DST = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'src/navtex/navtex_rx.cpp')
s = open(SRC, encoding='utf-8').read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"Erwartet {count}x, gefunden {n}x: {old[:80]!r}")
    s = s.replace(old, new)

def cut(start, end, new, include_end=True):
    """Ersetzt den Text von `start` bis einschließlich `end`"""
    global s
    i = s.index(start)
    j = s.index(end, i) + (len(end) if include_end else 0)
    s = s[:i] + new + s[j:]

M = 'ABWEICHUNG fldigi (Digidec)'

# 1. Includes
cut('#include "config.h"\n#include "configuration.h"', '#include "FL/fl_ask.H"\n',
    '''// §M: fldigi-, FLTK- und Wasserfall-Header durch Digidec-Ersatz ersetzt
#include <climits>
#include <cstring>
#include <iterator>
#include <pthread.h>
#include "misc_min.h"
#include "fldigi_complex.h"
#include "debug.h"
#include "gettext.h"
#include "coordinate.h"
#include "strutil.h"
#include "record_loader.h"
#include "fftfilt.h"
#include "FL/fl_ask.H"
#include "navtex_rx.h"
''')
rep('pthread_mutex_t  navtex_filter_mutex = PTHREAD_MUTEX_INITIALIZER;\n',
    f'// §M: navtex_filter_mutex entfällt (ein Thread je Decoder)\n')

# 2. CCIR476: ITA2 als Mitglied statt progdefaults.ITA2
rep('''	bool m_valid_codes[128];
public:
	CCIR476() {''', '''	bool m_valid_codes[128];
	bool m_ita2; // §M: statt der globalen ITA2-Einstellung
public:
	CCIR476(bool ita2 = false) : m_ita2(ita2) {''')
rep('progdefaults.ITA2', 'm_ita2', count=2)

# 3. ccir_message: Kopf-Kennungen lesbar machen; display() ohne ADIF/KML/Wasserfall
rep('''	char m_origin ;
	char m_subject ;
	int  m_number ;
public:
	const char * msg_type(void) const''', '''	char m_origin ;
	char m_subject ;
	int  m_number ;
public:
	// §M: Kopf-Kennungen für die Anzeige
	char origin() const { return m_origin; }
	char subject() const { return m_subject; }
	int  number() const { return m_number; }

	const char * msg_type(void) const''')
cut('		unsigned long long currFreq = wf->rfcarrier();', '	} // display',
    '''		// §M: ADIF-Logbuch und KML-Karte entfallen (fldigi: nur bei NVTX_AdifLog/NVTX_KmlLog);
		// die Station sucht Digidec bei Bedarf über fldigi_navtex_find_station().
	} // display''')

# 4. navtex_implementation: Wasserfall-Ersatz, Rückrufe, Einstellungen
rep('''	navtex                        * m_ptr_navtex ;
''', '''	navtex                        * m_ptr_navtex ;
	NavtexWaterfall               * wf ; // §M: statt fldigis globalem Wasserfall
''')
rep('''		m_ptr_navtex = ptr_navtex ;
''', '''		m_ptr_navtex = ptr_navtex ;
		wf = ptr_navtex->waterfall();
		m_ccir476 = CCIR476( ptr_navtex->config().ita2 ); // §M
		// §M: früher funktionslokale static-Variablen
		m_last_char = 0; m_sigpwr = 0.0; m_noisepwr = 0.0; m_cnt_upd = 0; m_cnt_read_data = 0;
		m_mark_env = 0; m_space_env = 0; m_mark_noise = 0; m_space_noise = 0;
''')
rep('''	navtex_implementation(int the_sample_rate, bool only_sitor_b, navtex * ptr_navtex ) {''',
    '''	// §M: früher funktionslokale static-Variablen (mehrere Decoder möglich)
	int    m_last_char ;
	double m_sigpwr, m_noisepwr ;
	size_t m_cnt_upd ;
	int    m_cnt_read_data ;
	double m_mark_env, m_space_env, m_mark_noise, m_space_noise ;

	/// §M: Ersatz für fldigis globale Ausgabefunktionen
	void put_rx_char( int c ) {
		const NavtexCallbacks & cb = m_ptr_navtex->callbacks();
		if( cb.on_char ) cb.on_char( cb.ctx, c );
	}
	void put_status( const char * ) const { m_ptr_navtex->m_state = (int)m_state; }

	navtex_implementation(int the_sample_rate, bool only_sitor_b, navtex * ptr_navtex ) {''')
rep('		guard_lock filter_guard(&navtex_filter_mutex);\n', '')
rep('		guard_lock g( &navtex_filter_mutex );\n', '')

rep('''	bool process_char(int chr) {
		static int last_char = 0;''', '''	bool process_char(int chr) {
		int & last_char = m_last_char; // §M: war static''')
rep('''		static double sigpwr = 0.0 ;
		static double noisepwr = 0.0;''', '''		double & sigpwr = m_sigpwr ;     // §M: war static
		double & noisepwr = m_noisepwr ;''')
rep('''		snprintf(snrmsg, sizeof(snrmsg), "s/n %3.0f dB", snr);
		put_Status2(snrmsg);''', '''		m_ptr_navtex->m_snr = snr; // §M: statt put_Status2("s/n …")''')
rep('''		if( progStatus.afconoff == false ) return ;
		static size_t cnt_upd = 0 ;''', '''		if( m_ptr_navtex->config().afc_on == false ) return ; // §M: statt progStatus.afconoff
		size_t & cnt_upd = m_cnt_upd ; // §M: war static''')
rep('''		static int cnt_read_data = 0 ;''', '''		int & cnt_read_data = m_cnt_read_data ; // §M: war static''')
rep('''		static double mark_env = 0, space_env = 0;
		static double mark_noise = 0, space_noise = 0;''', '''		double & mark_env = m_mark_env, & space_env = m_space_env;          // §M: war static
		double & mark_noise = m_mark_noise, & space_noise = m_space_noise;''')
# Wasserfall-Ersatz mit den Eingangsdaten füttern; Mittenfrequenz für powerDensityMaximum
rep('''		process_afc();
		process_timeout();''', '''		wf->sig_data( data, nb_samples );          // §M: fldigi füttert den Wasserfall getrennt
		wf->carrierfreq = m_center_frequency_f;
		process_afc();
		process_timeout();''')

# 5. Empfangene Nachrichten: Rückruf statt Warteschlange für XML-RPC
rep('''				ccir_msg.display(alt_string);
				put_received_message( alt_string );''', '''				ccir_msg.display(alt_string);
				put_received_message( ccir_msg ); // §M: mit Kopf-Kennungen''')
rep('progdefaults.NVTX_MinSizLoggedMsg', 'm_ptr_navtex->config().min_msg')
cut('	/// Each received message is pushed in this queue, so it can be read by XML/RPC.',
    '	void display_message(', '''	// §M: XML-RPC-Warteschlange (m_sync_rx, m_received_messages) entfällt

	void display_message(''', include_end=True)
cut('	/// Called by the engine each time a message is saved.\n	void put_received_message( const std::string &message )',
    '		return message ;\n	}\n', '''	/// §M: Nachricht an Digidec übergeben (fldigi: Warteschlange für XML-RPC)
	void put_received_message( const ccir_message & msg )
	{
		const NavtexCallbacks & cb = m_ptr_navtex->callbacks();
		if( cb.on_message ) cb.on_message( cb.ctx, msg.c_str(), msg.origin(), msg.subject(), msg.number(), msg.msg_type() );
	}
''')

# 6. Senden entfernen (encode/create_fec bleiben für den Testsignal-Generator)
cut('	void tx_flush()', '	void set_carrier( double freq )', '''	// §M: Senden (tx_flush … process_tx) entfällt; encode()/create_fec() bleiben für Testsignale

public:
	void set_carrier( double freq )''', include_end=True)

# 7. Kommandozeilen-Testprogramm und fldigi-Modemklasse entfernen
cut('#ifdef NAVTEX_COMMAND_LINE', '	return m_impl->get_received_message(max_seconds);\n}\n', f'// §M: Modem-Klasse `navtex` siehe navtex_frame.cpp\n')
cut('std::string navtex::send_message(const std::string &msg)', '\n}\n', '')


# 8. encode/create_fec öffentlich (Testsignal-Generator)
rep('''	std::string create_fec( const std::string & str ) const''', '''public: // §M: für den Testsignal-Generator
	std::string create_fec( const std::string & str ) const''')

# 9. Digidec-Rahmen anhängen
s += open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'navtex_frame.inc'), encoding='utf-8').read()
s = s.replace('§M', M)
open(DST + '.tmp', 'w', encoding='utf-8').write(s)
os.replace(DST + '.tmp', DST)
print("ok", len(s.splitlines()), "Zeilen")
