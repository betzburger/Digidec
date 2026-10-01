#!/usr/bin/env python3
"""Erzeugt den CW-Empfänger für Digidec aus fldigi 4.2.13 (src/cw/cw.cxx, morse.cxx, include/cw.h, morse.h,
filters/filters.cxx, include/filters.h). Die Empfangsfunktionen werden wörtlich herausgezogen; Senden und Tastung
entfallen. fldigis Einstellungen und Anzeigen stellt src/cw/cw_compat.h unter denselben Namen bereit.
Bricht ab, wenn das Original nicht mehr wie erwartet aussieht."""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
UP = os.path.join(HERE, '../_upstream/fldigi-4.2.13/src')
M = 'ABWEICHUNG fldigi (Digidec)'

def read(p): return open(os.path.join(UP, p), encoding='utf-8').read()
def write(p, s):
    full = os.path.join(HERE, p)
    open(full + '.tmp', 'w', encoding='utf-8').write(s)
    os.replace(full + '.tmp', full)

def must(s, old, new, count=1):
    n = s.count(old)
    if n != count: sys.exit(f"Erwartet {count}x, gefunden {n}x: {old[:70]!r}")
    return s.replace(old, new)

def block(src, signature):
    """Funktion oder Definition ab `signature` bis zur passenden schließenden Klammer
    (zählt Klammern, überspringt Zeichenketten, Zeichenkonstanten und Kommentare)"""
    if src.count(signature) != 1: sys.exit(f"Signatur nicht eindeutig: {signature!r}")
    i = src.index(signature)
    k = src.index('{', i)
    depth, n = 0, len(src)
    while k < n:
        ch = src[k]
        if src.startswith('//', k):
            k = src.index('\n', k)
            continue
        if src.startswith('/*', k):
            k = src.index('*/', k) + 2
            continue
        if ch in '"\'':
            q = ch
            k += 1
            while src[k] != q:
                k += 2 if src[k] == '\\' else 1
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = k + 1
                if src[end:end + 1] == ';': end += 1
                return src[i:end] + '\n\n'
        k += 1
    sys.exit(f"Ende nicht gefunden: {signature!r}")

# --- Filter (C_FIR_filter, Cmovavg) unverändert bis auf den Komplex-Header
f_h = must(read('include/filters.h'), '#include "complex.h"', f'#include "fldigi_complex.h" // {M}: umbenannt')
write('src/common/filters.h', f_h)
write('src/common/filters.cpp', read('filters/filters.cxx'))

# --- Morse-Tabelle: progdefaults kommt aus morse_defaults.h
morse_cpp = must(read('cw/morse.cxx'), '#include "configuration.h"',
                 f'#include "morse_defaults.h" // {M}: statt fldigis configuration.h')
write('src/cw/morse.cpp', morse_cpp)
write('src/cw/morse.h', read('include/morse.h'))

# --- Klassenkopf
h = read('include/cw.h')
h = must(h, '#include <config.h>\n', '')
h = must(h, '#include "modem.h"\n', f'#include "cw_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, '#include "mbuffer.h"\n', f'#include "mbuffer.h"\n')
h = must(h, '#include "view_cw.h"\n', '')
h = must(h, 'class cw : public modem {', f'class cw : public cw_modem_base {{ // {M}\n\tfriend struct fldigi_cw; // {M}: C-Hülle ruft sync_parameters()')
h = must(h, '	view_cw	viewcw;', f'	CwViewStub viewcw; // {M}: keine Mehrkanal-Ansicht')
h = must(h, 'extern pthread_mutex_t cwio_ptt_mutex;\n', '')
write('src/cw/cw_rx.h', h)

# --- Empfangsfunktionen
c = read('cw/cw.cxx')
parts = []
parts.append(f'''// ----------------------------------------------------------------------------
// cw_rx.cpp  --  CW-Empfänger aus fldigi 4.2.13 (src/cw/cw.cxx), erzeugt von port_cw.py
//
// Copyright (C) Dave Freese W1HKJ u. a. (siehe Original). GNU GPL v3.
// {M}: Nur die Empfangsfunktionen, wörtlich übernommen. Senden, Tastung (Winkeyer, nanoIO, GPIO, CAT)
// und die Mehrkanal-Ansicht entfallen. Einstellungen/Anzeigen: cw_compat.h.
// Einschränkung: die file-static-Variablen von fldigi (first_time, cw_freq …) erlauben nur einen CW-Decoder.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include "cw_rx.h"

#define FIR_DECIMATE    10 //16
''')
# file-static Variablen aus dem Original
for line in ['static double nano_d2d = 0;', 'static int nano_wpm = 0;', 'static bool first_time = true;',
             'static double cw_freq = 1500;', 'static int FIR_FILTER_LEN = 512;',
             'static int debug_count = 0;', 'static int filnbr = -1;', 'static bool cwprocessing = false;']:
    if c.count(line) != 1: sys.exit(f"fehlt: {line}")
    parts.append(line + '\n')
parts.append('\n')
for sig in ['const cw::SOM_TABLE cw::som_table[] = {',
            'int cw::normalize(float *v, int n, int twodots)',
            'std::string cw::find_winner (float *inbuf, int twodots)',
            'void cw::rx_init()',
            'void cw::init()',
            'cw::cw() : modem()',
            'void cw::reset_rx_filter()',
            'void cw::sync_transmit_parameters()',
            'void cw::sync_parameters()',
            'inline void cw::update_tracking(int dur_1, int dur_2)',
            'void cw::update_Status()',
            'void cw::update_syncscope()',
            'void cw::clear_syncscope()',
            'cmplx cw::mixer(cmplx in)',
            'void cw::decode_stream(double value)',
            'void cw::rx_FFTprocess(const double *buf, int len)',
            'int cw::rx_process(const double *buf, int len)',
            'inline int cw::usec_diff(unsigned int earlier, unsigned int later)',
            'void cw::handle_event(int cw_event, std::string &sc)']:
    parts.append(block(c, sig))
body = ''.join(parts)
body = must(body, 'cw::cw() : modem()', f'cw::cw() : cw_modem_base() // {M}: Basisklasse')
body = must(body, '	start_cwio_thread();\n', f'	// {M}: start_cwio_thread() entfällt (Tastung)\n')
# Destruktor und Sendeseite: nur Aufräumen bzw. leer
body += f'''
// {M}: Destruktor ohne Tastungs-Threads
cw::~cw() {{
	if (cw_filter) delete cw_filter;
	if (bitfilter) delete bitfilter;
	if (trackingfilter) delete trackingfilter;
}}

// {M}: Sende-Hüllkurven werden nicht gebraucht
void cw::create_edges() {{}}

// {M}: fldigi legt den CW-Empfänger einmal je Programmlauf an; first_time bleibt danach false. Digidec legt ihn
// neu an (Moduswechsel, Tests). Ohne Rücksetzen übernähme reset_rx_filter() bei gleicher Trägerfrequenz
// den Filter des neuen Exemplars nicht (Filter bliebe auf der Grundeinstellung 1000 Hz).
void cw_rx_reset_statics() {{
	first_time = true;
	cwprocessing = false;
}}
'''
write('src/cw/cw_rx.cpp', body)
print('ok', len(body.splitlines()), 'Zeilen cw_rx.cpp')
