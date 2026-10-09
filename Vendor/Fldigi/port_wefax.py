#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
"""Erzeugt den WEFAX-Empfänger für Digidec aus fldigi 4.2.13 (src/wefax/wefax.cxx).

Übernommen wird wörtlich der Block von den Empfangsfiltern bis vor die Sendefunktionen (Hilfsklassen,
fax_implementation, decode/decode_apt/decode_phasing/decode_image, rx_new_samples). Gezielte Ersetzungen
(je genau einmal, sonst Abbruch) binden fldigis Globale an den Rahmen (src/wefax/wefax_rx.h, wefax_frame.inc).
Ergebnis: src/wefax/wefax_rx.cpp = Kopf + Auszug + wefax_frame.inc."""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '../_upstream/fldigi-4.2.13/src/wefax/wefax.cxx')
M = 'ABWEICHUNG fldigi (Digidec)'

s = open(SRC, encoding='utf-8').read()

def cut(text, start, end):
    i = text.find(start)
    j = text.find(end, i)
    if i < 0 or j < 0 or text.count(start) != 1:
        sys.exit(f"Ausschnitt nicht eindeutig: {start[:60]!r}")
    return text[i:j]

def must(old, new, count=1):
    global b
    n = b.count(old)
    if n != count:
        sys.exit(f"Erwartet {count}x, gefunden {n}x: {old[:80]!r}")
    b = b.replace(old, new)

b = cut(s, '#define PUT_STATUS(A)', '// Init transmission. Called once only.')

# --- Senden/XML-RPC-Dateiwarteschlangen (syncobj, guard_lock) entfallen
i = b.index('private:\n\t/// Each received file has its name pushed in this queue.')
j = b.index('\t/// Maybe we could reset this buffer when we change the state')
if i < 0 or j < i:
    sys.exit('Abschnitt Dateiwarteschlangen nicht gefunden')
b = b[:i] + f'\t// {M}: Dateiwarteschlangen für XML-RPC und Senden (syncobj) entfallen\n\n' + b[j:]

# --- Filtersatz je Objekt (fldigi: static, ein Exemplar je Programm)
must('\tstatic fir_filter_pair_set m_rx_filters ;',
     f'\tfir_filter_pair_set m_rx_filters ; // {M}: je Objekt statt static (Filterzustand)')
must('/// Narrow, middle etc... input filters. Constructed at program startup. Readonly.\n'
     'fir_filter_pair_set fax_implementation::m_rx_filters ;\n',
     f'// {M}: Definition des statischen Filtersatzes entfällt (Objektvariable)\n')

# --- funktionsstatische Zustände → Objektvariablen (per Referenz, Code sonst unverändert)
STATE = []   # (Deklaration in der Klasse)
def member(old, ref, decl):
    must(old, f'{ref} // {M}: Objektvariable statt static')
    STATE.append(decl)

member('\t\tstatic fax_state stable_state = IDLE ;',
       '\t\tfax_state & stable_state = m_st_stable_state ;', 'mutable fax_state m_st_stable_state = IDLE ;')
member('\t\t\tstatic double last_corr_avg = 0.0 ;',
       '\t\t\tdouble & last_corr_avg = m_st_last_corr_avg ;', 'mutable double m_st_last_corr_avg = 0.0 ;')
member('\t\tstatic size_t cnt_upd = 0 ;',
       '\t\tsize_t & cnt_upd = m_st_cnt_upd ;', 'size_t m_st_cnt_upd = 0 ;')
member('\t\tstatic int prev_row = -1 ;',
       '\t\tint & prev_row = m_st_prev_row ;', 'mutable int m_st_prev_row = -1 ;')
member('\t\tstatic int total_img_rows = 0 ;',
       '\t\tint & total_img_rows = m_st_total_img_rows ;', 'mutable int m_st_total_img_rows = 0 ;')
member('\t\tstatic int stable_carrier = 0 ;',
       '\t\tint & stable_carrier = m_st_stable_carrier ;', 'mutable int m_st_stable_carrier = 0 ;')
member('\t\tstatic double median_freqs[ max_median_freqs ];',
       '\t\tdouble (& median_freqs)[ max_median_freqs ] = m_st_median_freqs ;', 'mutable double m_st_median_freqs[ 20 ] = {} ;')
member('\t\tstatic int nb_median_freqs = 0 ;',
       '\t\tint & nb_median_freqs = m_st_nb_median_freqs ;', 'mutable int m_st_nb_median_freqs = 0 ;')
member('\t\tstatic long long stable_rfcarrier = 0 ;',
       '\t\tlong long & stable_rfcarrier = m_st_stable_rfcarrier ;', 'mutable long long m_st_stable_rfcarrier = 0 ;')
member('\t\tstatic bool prevWasRight = true ;',
       '\t\tbool & prevWasRight = m_st_prevWasRight ;', 'mutable bool m_st_prevWasRight = true ;')
member('\t\tstatic int curr_freq = 0 ;',
       '\t\tint & curr_freq = m_st_curr_freq ;', 'int m_st_curr_freq = 0 ;')
member('\t\tstatic int cr_1_freq = 0 ;',
       '\t\tint & cr_1_freq = m_st_cr_1_freq ;', 'int m_st_cr_1_freq = 0 ;')
member('\t\tstatic int cr_2_freq = 0 ;',
       '\t\tint & cr_2_freq = m_st_cr_2_freq ;', 'int m_st_cr_2_freq = 0 ;')
member('\t\tstatic int cr_3_freq = 0 ;',
       '\t\tint & cr_3_freq = m_st_cr_3_freq ;', 'int m_st_cr_3_freq = 0 ;')
member('\t\tstatic size_t phasing_count = 0 ;',
       '\t\tsize_t & phasing_count = m_st_phasing_count ;', 'size_t m_st_phasing_count = 0 ;')
member('\t\tstatic int phasing_history[ phasing_width ];',
       '\t\tint (& phasing_history)[ phasing_width ] = m_st_phasing_history ;', 'int m_st_phasing_history[ 16 ] = {} ;')

# AFC-Masken: fldigi legt sie beim ersten Aufruf static an (mit dem dann gültigen Hub)
must('\t\tstatic const int bw_dual[][2] = {',
     f'\t\tconst int bw_dual[][2] = {{ // {M}: nicht static, damit ein geänderter Hub gilt')
must('\t\tstatic const int bw_right[][2] = {',
     f'\t\tconst int bw_right[][2] = {{ // {M}: nicht static')

# Zeilenlänge: fldigi rundet sie auf ganze Samples ab (11025 Hz, 120 LPM: 5512 statt 5512,5).
# Das ergibt 0,166 Pixel Schräglauf je Zeile (≈ 200 Pixel auf 1200 Zeilen).
must('''	int lpm_to_samples(int the_lpm) const {
		return m_sample_rate * 60.0 / the_lpm ;
	}''', f'''	double lpm_to_samples(int the_lpm) const {{ // {M}: double statt int (sonst Schräglauf)
		return m_sample_rate * 60.0 / the_lpm ;
	}}''')

# Zustand für die Anzeige lesbar machen
must('\tvoid set_mode( trx_mode m) { wefax_mode = m; }',
     '\tvoid set_mode( trx_mode m) { wefax_mode = m; }\n\n'
     f'\t// {M}: für die Anzeige\n'
     '\tint rx_state_num(void) const { return (int)m_rx_state; }\n'
     '\tdouble lpm_img(void) const { return m_lpm_img; }\n'
     '\t/// wie wefax_cb_pic_rx_save: nur speichern, Empfang läuft weiter\n'
     '\tvoid save_now(void) { wefax_pic::save_image(generate_filename("gui"), ""); }')

# Objektvariablen am Ende der Klasse einfügen
decls = ''.join(f'\t{d}\n' for d in STATE)
must('}; // class fax_implementation',
     f'private:\n\t// {M}: Zustände, die fldigi in static-Variablen hält\n{decls}'
     '}; // class fax_implementation')

head = f'''// ----------------------------------------------------------------------------
// wefax_rx.cpp  --  WEFAX-Empfänger aus fldigi 4.2.13 (src/wefax/wefax.cxx), erzeugt von port_wefax.py
//
// Copyright (C) Dave Freese W1HKJ, Remi Chateauneu F4ECW u. a. (siehe Original); Kern aus Hamfax/ACfax. GNU GPL v3.
// {M}: Empfangsteil wörtlich; Senden, XML-RPC-Warteschlangen und ADIF-Log entfallen.
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
template <class F, class... A> static inline void wefax_req(F f, A... a) {{ f(a...); }}

// fldigis Globale → Rahmen des Decoders (nur innerhalb von fax_implementation benutzt)
#define progdefaults     (m_ptr_wefax->cfg)
#define progStatus       (m_ptr_wefax->status)
#define wf               (m_ptr_wefax->waterfall())
#define put_Status1(s)   m_ptr_wefax->put_Status1_(s)
#define put_Status2(s)   m_ptr_wefax->put_Status2_(s)

'''
frame = open(os.path.join(HERE, 'wefax_frame.inc'), encoding='utf-8').read()
tail = '''
#undef progdefaults
#undef progStatus
#undef wf
#undef put_Status1
#undef put_Status2

'''
out = head + b + tail + frame
dst = os.path.join(HERE, 'src/wefax/wefax_rx.cpp')
open(dst + '.tmp', 'w', encoding='utf-8').write(out)
os.replace(dst + '.tmp', dst)
print('ok', len(out.splitlines()), 'Zeilen wefax_rx.cpp,', len(STATE), 'static → Objektvariablen')
