#!/usr/bin/env python3
"""Erzeugt den PSK-Empfänger (BPSK/QPSK) für Digidec aus fldigi 4.2.13 (src/psk/psk.cxx, include/psk.h und
Hilfsteile: pskcoeff, pskvaricode, viterbi, interleave, mfskvaricode). Die Empfangsfunktionen werden wörtlich
herausgezogen (Klammerzählung); Senden, Mehrkanal-Ansicht (viewpsk) und Signalsuche über den Wasserfall
(pskeval, mailserver) entfallen. fldigis Einstellungen und Anzeigen stellt src/psk/psk_compat.h unter denselben
Namen bereit. Bricht ab, wenn das Original nicht mehr wie erwartet aussieht."""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
UP = os.path.join(HERE, '../_upstream/fldigi-4.2.13/src')
M = 'ABWEICHUNG fldigi (Digidec)'

def read(p): return open(os.path.join(UP, p), encoding='utf-8', errors='surrogateescape').read()
def write(p, s):
    full = os.path.join(HERE, p)
    open(full + '.tmp', 'w', encoding='utf-8', errors='surrogateescape').write(s)
    os.replace(full + '.tmp', full)

def must(s, old, new, count=1):
    n = s.count(old)
    if n != count: sys.exit(f"Erwartet {count}x, gefunden {n}x: {old[:70]!r}")
    return s.replace(old, new)

def block(src, signature):
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

# --- Hilfsteile wörtlich (Include-Namen werden von psk_compat.h / compat/config.h bedient)
write('src/psk/pskcoeff.cpp', read('psk/pskcoeff.cxx'))
write('src/psk/pskcoeff.h', read('include/pskcoeff.h'))
write('src/psk/pskvaricode.cpp', read('psk/pskvaricode.cxx'))
write('src/psk/pskvaricode.h', read('include/pskvaricode.h'))
write('src/psk/viterbi.cpp', must(read('filters/viterbi.cxx'), '#include "misc.h"', f'#include "misc_min.h" // {M}: statt fldigis misc.h'))
write('src/psk/viterbi.h', read('include/viterbi.h'))
write('src/psk/interleave.cpp', read('mfsk/interleave.cxx'))
write('src/psk/interleave.h', read('include/interleave.h'))
write('src/psk/mfskvaricode.cpp', read('mfsk/mfskvaricode.cxx'))
write('src/psk/mfskvaricode.h', read('include/mfskvaricode.h'))

# --- Modus-Aufzählung (trx_mode) aus globals.h: die psk-Funktionen vergleichen mit MODE_*-Werten und Bereichen
g = read('include/globals.h')
e_end = g.index('NUM_MODES,')
e_start = g.rindex('enum', 0, e_end)
e_start = g.index('{', e_start) + 1
write('src/psk/psk_modes.inc', f'// Aus fldigi 4.2.13 include/globals.h (enum, Reihenfolge wie im Original, erzeugt von port_psk.py)\n' + g[e_start:e_end] + 'NUM_MODES\n')

# --- Klassenkopf
h = read('include/psk.h')
h = must(h, '#include "complex.h"\n', f'#include "psk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
for inc in ['modem.h', 'globals.h', 'viewpsk.h', 'pskeval.h']:
    h = must(h, f'#include "{inc}"\n', '')
h = must(h, 'class psk : public modem {', f'class psk : public psk_modem_base {{ // {M}\n\tfriend struct fldigi_psk; // {M}: C-Hülle')
h = must(h, 'maxamp;\n', 'maxamp;\n' + f'\t// {M}: file-static Zustand von fldigi (rx_symbol, tx_bit, tx_xpsk) je Instanz\n\tdouble\t\t\taverageamp_ = 0;\n\tint\t\t\t\tcounter_ = 0;\n\tint\t\t\t\tdcdOFFcounter_ = 0;\n\tint\t\t\t\tbitcount_ = 0;\n\tint\t\t\t\txpsk_sym_ = 0;\n\tint\t\t\t\tbitcount2_ = 0;\n\tunsigned int\txpsk_sym2_ = 0;\n')
write('src/psk/psk_rx.h', h)

# --- Empfangsfunktionen
c = read('psk/psk.cxx')
parts = []
parts.append(f'''// ----------------------------------------------------------------------------
// psk_rx.cpp  --  PSK-Empfänger (BPSK/QPSK) aus fldigi 4.2.13 (src/psk/psk.cxx), erzeugt von port_psk.py
//
// Copyright (C) 2006-2008 Dave Freese W1HKJ u. a. (siehe Original). GNU GPL v3.
// {M}: Nur die Empfangsfunktionen, wörtlich übernommen. Senden, Mehrkanal-Ansicht (viewpsk), Signalsuche
// über den Wasserfall (pskeval) und PSKmail entfallen. Einstellungen/Anzeigen: psk_compat.h.
// Einschränkung: die file-static-Variablen von fldigi (waitcount, reset_filters, e0…e3) erlauben nur einen PSK-Decoder.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include "psk_rx.h"

''')
# Definitionen und Konstanten bis vor tx_init (SQLCOEFF … graymapped_*, pskmsg)
i0 = c.index('// Change the following for DCD low pass filter adjustment')
i1 = c.index('void psk::tx_init()')
parts.append(c[i0:i1])
def pre(marker):
    # Zeile(n) direkt vor einer Funktion (file-static-Variable) mit übernehmen
    if c.count(marker) != 1: sys.exit(f"Marker nicht eindeutig: {marker!r}")
    return marker + '\n'
parts.append(block(c, 'void psk::rx_init()'))
parts.append(block(c, 'bool psk::viewer_mode()'))
parts.append(block(c, 'void psk::restart()'))
parts.append(block(c, 'void psk::init()'))
parts.append(block(c, 'psk::~psk()'))
parts.append(block(c, 'psk::psk(trx_mode pskmode) : modem()'))
parts.append(block(c, 'void psk::s2nreport(void)'))
parts.append(block(c, 'void psk::rx_bit(int bit)'))
parts.append(block(c, 'void psk::rx_bit2(int bit)'))
parts.append(block(c, 'void psk::rx_qpsk(int bits)'))
parts.append(block(c, 'void psk::rx_pskr(unsigned char symbol)'))
parts.append(pre('int waitcount = 0;'))
parts.append(block(c, 'void psk::findsignal()'))
parts.append(block(c, 'void psk::vestigial_afc()'))
parts.append(block(c, 'void psk::phaseafc()'))
parts.append(block(c, 'void psk::afc()'))
parts.append(block(c, 'void psk::rx_symbol(cmplx symbol, int car)'))
parts.append(pre('static double e0, e1, e2, e3;'))
parts.append(block(c, 'void psk::signalquality()'))
parts.append(block(c, 'void psk::update_syncscope()'))
parts.append(pre('char bitstatus[100];'))
parts.append(block(c, 'int psk::rx_process(const double *buf, int len)'))
parts.append(pre('static bool reset_filters;'))
parts.append(block(c, 'void psk::initSN_IMD()'))
parts.append(block(c, 'void psk::resetSN_IMD()'))
parts.append(block(c, 'void psk::calcSN_IMD(cmplx z)'))
# Sendefunktionen: nur für das Testsignal (Sendesteuerung tx_process und Testfenster entfallen)
parts.append(block(c, 'void psk::tx_init()'))
parts.append(block(c, 'void psk::transmit(double *buf, int len)'))
i_svp = c.index('#define SVP_MASK 0xF')
i_svp_end = c.index('void psk::tx_carriers()')
parts.append(c[i_svp:i_svp_end])
parts.append(block(c, 'void psk::tx_carriers()'))
parts.append(block(c, 'void psk::tx_symbol(int sym)'))
parts.append(block(c, 'void psk::tx_bit(int bit)'))
parts.append(block(c, 'void psk::tx_xpsk(int bit)'))
parts.append('unsigned char ch;\n')
parts.append(block(c, 'void psk::tx_char(unsigned char c)'))
parts.append(block(c, 'void psk::tx_flush()'))
parts.append(block(c, 'void psk::clearbits()'))
body = ''.join(parts)

body = must(body, 'psk::psk(trx_mode pskmode) : modem()', f'psk::psk(trx_mode pskmode) : psk_modem_base() // {M}: Basisklasse')
body = must(body, '\tmodem::init();\n', f'\t// {M}: modem::init() entfällt (Basisklasse ohne Initialisierung)\n')
body = must(body, '\tmodem::s2nreport();\n', f'\t// {M}: modem::s2nreport() entfällt (PSKmail)\n')
# Sendeseite: Testfenster (IMD) entfällt, function-static Zähler je Instanz
i0 = body.index('\t\t\tif (test_signal_window && test_signal_window->visible() && btn_imd_on->value()) {')
i1 = body.index('\t\t\tshapeB = (1.0 - shapeA);')
body = body[:i0] + f'\t\t\t// {M}: Testsignal-Fenster (IMD) entfällt\n\n' + body[i1:]
body = must(body, '\tunsigned int sym;\n\tstatic int bitcount=0;\n\tstatic int xpsk_sym=0;\n', f'\tunsigned int sym;\n\tint &bitcount = bitcount_; // {M}: je Instanz statt function-static\n\tint &xpsk_sym = xpsk_sym_;\n')
body = must(body, '\tstatic int bitcount = 0;\n\tstatic unsigned int xpsk_sym = 0;\n\tint fecbits = 0;', f'\tint &bitcount = bitcount2_; // {M}: je Instanz statt function-static\n\tunsigned int &xpsk_sym = xpsk_sym2_;\n\tint fecbits = 0;')
# file-static Zustand je Instanz (siehe psk_rx.h)
body = must(body, 'static double averageamp;', f'double &averageamp = averageamp_; // {M}: je Instanz statt file-static')
body = must(body, 'static int counter=0;\n\tif (counter++ > dcdbits/4) {', f'int &counter = counter_; // {M}: je Instanz statt file-static\n\tif (counter++ > dcdbits/4) {{')
body = must(body, 'static int dcdOFFcounter=0;', f'int &dcdOFFcounter = dcdOFFcounter_; // {M}: je Instanz statt file-static')
body += f'''
// {M}: fldigi legt jeden Decoder nur einmal je Moduswechsel an; die file-static-Variablen werden hier zurückgesetzt.
void psk_rx_reset_statics() {{
	waitcount = 0;
	reset_filters = true;
	e0 = e1 = e2 = e3 = 0;
}}
'''
write('src/psk/psk_rx.cpp', body)
print('ok', len(body.splitlines()), 'Zeilen psk_rx.cpp')
