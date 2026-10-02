#!/usr/bin/env python3
"""Erzeugt den MFSK-Empfänger für Digidec aus fldigi 4.2.13 (src/mfsk/mfsk.cxx, include/mfsk.h). Die Empfangsfunktionen
werden wörtlich herausgezogen (Klammerzählung), ebenso die Sendefunktionen für das Testsignal; Bildfenster, Mailserver-S/N und
die Sendesteuerung (tx_process) entfallen. fldigis Einstellungen und Anzeigen stellt src/mfsk/mfsk_compat.h unter denselben
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


# --- Klassenkopf
h = read('include/mfsk.h')
for inc in ['<FL/Fl_Widget.H>', '<FL/Fl_Double_Window.H>', '<FL/Fl_Button.H>', '<FL/Fl_Shared_Image.H>', '"globals.h"', '"modem.h"', '"picture.h"']:
    h = must(h, f'#include {inc}\n', '')
h = must(h, '#include "mbuffer.h"\n', f'#include "mbuffer.h"\n#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
a = h.index('extern \tint\t\tprint_time_left')
b = h.index('struct rxpipe')
h = h[:a] + h[b:]
a = h.index('friend void updateTxPic')
b = h.index('public:\nenum {')
h = h[:a] + f'friend struct fldigi_mfsk; // {M}: C-Hülle\n\n' + h[b:]
h = must(h, 'class mfsk : public modem {', f'class mfsk : public fam_modem_base {{ // {M}')
h = must(h, 'int symbolbit;\n', f'int symbolbit;\n\n\t// {M}: function-static Zustand von fldigi (softdecode) je Instanz\n\tint CWIcounter_[MAX_SYMBOLS] = {{0}};\n')
h = must(h, '\tvoid	send_color_image(std::string s);\n\tvoid	send_Grey_image(std::string s);\n', '')
write('src/mfsk/mfsk_rx.h', h)

# --- Funktionen
c = read('mfsk/mfsk.cxx')
parts = []
parts.append(f'''// ----------------------------------------------------------------------------
// mfsk_rx.cpp  --  MFSK-Empfänger aus fldigi 4.2.13 (src/mfsk/mfsk.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2006-2009 Dave Freese, W1HKJ; angepasst aus gmfsk (Tomi Manninen OH2BNS). GNU GPL v3.
// {M}: Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen. Bildfenster,
// Mailserver-S/N-Meldung und die Sendesteuerung (tx_process) entfallen. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "mfsk_rx.h"

#define SOFTPROFILE false

''')
i0 = c.index('// MFSKpic receive start delay')
i1 = c.index('#include "mfsk-pic.cxx"')
parts.append(c[i0:i1])
parts.append(block(c, 'void  mfsk::tx_init()'))
parts.append(block(c, 'void  mfsk::rx_init()'))
parts.append(block(c, 'mfsk::mfsk(trx_mode mfsk_mode) : modem()'))
parts.append(block(c, 'void mfsk::s2nreport(void)'))
parts.append(block(c, 'bool mfsk::check_picture_header(char c)'))
parts.append(block(c, 'void mfsk::recvpic(cmplx z)'))
parts.append(block(c, 'void mfsk::recvchar(int c)'))
parts.append(block(c, 'void mfsk::recvbit(int bit)'))
parts.append(block(c, 'void mfsk::decodesymbol(unsigned char symbol)'))
parts.append(block(c, 'void mfsk::softdecode(cmplx *bins)'))
parts.append(block(c, 'cmplx mfsk::mixer(cmplx in, double f)'))
parts.append(block(c, 'int mfsk::harddecode(cmplx *in)'))
parts.append(block(c, 'void mfsk::update_syncscope()'))
parts.append(block(c, 'void mfsk::synchronize()'))
parts.append(block(c, 'void mfsk::reset_afc()'))
parts.append(block(c, 'void mfsk::afc()'))
parts.append(block(c, 'void mfsk::eval_s2n()'))
parts.append(block(c, 'int mfsk::rx_process(const double *buf, int len)'))
parts.append(block(c, 'void mfsk::transmit(double *buf, int len)'))
parts.append(block(c, 'void mfsk::sendsymbol(int sym)'))
parts.append(block(c, 'void mfsk::sendbit(int bit)'))
parts.append(block(c, 'void mfsk::sendchar(unsigned char c)'))
parts.append(block(c, 'void mfsk::sendidle()'))
parts.append(block(c, 'void mfsk::flushtx(int nbits)'))
parts.append(block(c, 'void mfsk::clearbits()'))
body = ''.join(parts)

body = must(body, 'mfsk::mfsk(trx_mode mfsk_mode) : modem()', f'mfsk::mfsk(trx_mode mfsk_mode) : fam_modem_base() // {M}: Basisklasse')
body = must(body, '''// picTxWin and picRxWin are created once to support all instances of mfsk
	if (!picTxWin) createTxViewer();
	if (!picRxWin)
		createRxViewer();
	activate_mfsk_image_item(true);
''', f'\t// {M}: Bildfenster entfallen\n')
body = must(body, '\tvideoText();\n}\n\nvoid  mfsk::rx_init()', f'\tvideoText();\n}}\n\nvoid  mfsk::rx_init()')
# Bildempfang: Pixel und Bildkopf an den Rückruf
body = must(body, '\t\t\tREQ(updateRxPic, byte, pixelnbr);', f'\t\t\tif (on_pixel) on_pixel(on_char_ctx, byte, pixelnbr); // {M}: statt Bildfenster')
body = must(body, '\t\t\t\tREQ(updateRxPic, byte, pixelnbr++);', f'\t\t\t\tif (on_pixel) on_pixel(on_char_ctx, byte, pixelnbr++); // {M}: statt Bildfenster')
body = must(body, '\t\t\t\tREQ( showRxViewer, picW, picH );', f'\t\t\t\tif (on_picture) on_picture(on_char_ctx, picW, picH, color ? 1 : 0); // {M}: statt Bildfenster')
body = must(body, '\tmodem::s2nreport();\n', f'\t// {M}: modem::s2nreport() entfällt (PSKmail)\n')
# function-static CWI-Zähler je Instanz
body = must(body, '\tstatic int CWIcounter[MAX_SYMBOLS] = {0};', f'\tint *CWIcounter = CWIcounter_; // {M}: je Instanz statt function-static')
# init() von Hand (fldigi: modem::init, Bildfenster, Wasserfallträger)
body += f'''// {M}: init() ohne modem::init() und Bildfenster; Trägerfrequenz setzt Digidec
void mfsk::init()
{{
	rx_init();
	set_scope_mode(Digiscope::SCOPE);
	TXspp = 8;
	RXspp = 8;
	set_freq(wf->Carrier());
}}

mfsk::~mfsk()
{{
	if (bpfilt) delete bpfilt;
	if (xmtfilt) delete xmtfilt;
	if (rxinlv) delete rxinlv;
	if (txinlv) delete txinlv;
	if (dec2) delete dec2;
	if (dec1) delete dec1;
	if (enc) delete enc;
	if (pipe) delete [] pipe;
	if (hbfilt) delete hbfilt;
	if (binsfft) delete binsfft;
	for (int i = 0; i < SCOPESIZE; i++) {{
		if (vidfilter[i]) delete vidfilter[i];
	}}
	if (syncfilter) delete syncfilter;
}}

'''
m = read('misc/misc.cxx')
gi = m.index('unsigned char grayencode(unsigned char data)')
gray = m[gi:m.index('\n}\n', m.rindex('unsigned char graydecode(unsigned char data)')) + 3] + '\n'
write('src/mfsk/mfsk_rx.cpp', body.replace('#define SOFTPROFILE false\n\n', '#define SOFTPROFILE false\n\n// ' + M + ': Gray-Code aus misc.cxx\n' + gray, 1))

# ===================================================================== DominoEX
write('src/mfsk/dominovar.cpp', read('dominoex/dominovar.cxx'))
write('src/mfsk/dominovar.h', read('include/dominovar.h'))
h = read('include/dominoex.h')
for inc in ['"complex.h"', '"modem.h"']:
    h = must(h, f'#include {inc}\n', '')
h = must(h, '#include "mbuffer.h"\n', f'#include "mbuffer.h"\n#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, 'class dominoex : public modem {', f'class dominoex : public fam_modem_base {{ // {M}\n\tfriend struct fldigi_mfsk; // {M}: C-Hülle')
write('src/mfsk/dominoex_rx.h', h)

c = read('dominoex/dominoex.cxx')
parts = []
parts.append(f'''// ----------------------------------------------------------------------------
// dominoex_rx.cpp  --  DominoEX-Empfänger aus fldigi 4.2.13 (src/dominoex/dominoex.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2006-2008 Dave Freese, W1HKJ. GNU GPL v3.
// {M}: Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen; die Sendesteuerung
// (tx_process) entfällt. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <map>
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "dominoex_rx.h"

''')
i0 = c.index('static char   dommsg[80];')
i1 = c.index('void dominoex::tx_init()')
parts.append(c[i0:i1])
for sig in ['void dominoex::tx_init()', 'void dominoex::rx_init()', 'void dominoex::reset_filters()', 'void dominoex::restart()',
            'void dominoex::MuPsk_sec2pri_init(void)', 'dominoex::~dominoex()', 'dominoex::dominoex(trx_mode md)',
            'cmplx dominoex::mixer(int n, cmplx in)', 'void dominoex::recvchar(int c)', 'void dominoex::decodeDomino(int c)',
            'void dominoex::decodesymbol()', 'int dominoex::harddecode()', 'void dominoex::update_syncscope()',
            'void dominoex::synchronize()', 'void dominoex::eval_s2n()', 'int dominoex::rx_process(const double *buf, int len)',
            'int dominoex::get_secondary_char()', 'void dominoex::sendtone(int tone, int duration)', 'void dominoex::sendsymbol(int sym)',
            'void dominoex::sendchar(unsigned char c, int secondary)', 'void dominoex::sendidle()', 'void dominoex::sendsecondary()',
            'void dominoex::flushtx()', 'unsigned char dominoex::MuPskSec2Pri(int c)', 'unsigned int dominoex::MuPskPriSecChar(unsigned int c)',
            'void dominoex::decodeMuPskSymbol(unsigned char symbol)', 'void dominoex::decodeMuPskEX(int ch)', 'void dominoex::MuPskFlushTx()',
            'void dominoex::MuPskClearbits()', 'void dominoex::sendMuPskEX(unsigned char c, int secondary)']:
    parts.append(block(c, sig))
body = ''.join(parts)
body = must(body, '\tvideoText();\n}\n', f'\tvideoText();\n}}\n')
body = must(body, '\n\tstrSecXmtText = progdefaults.secText;\n\tif (strSecXmtText.length() == 0)\n\t\tstrSecXmtText = "fldigi " PACKAGE_VERSION " ";\n', '\n\tstrSecXmtText = progdefaults.secText;\n\tif (strSecXmtText.length() == 0)\n\t\tstrSecXmtText = "fldigi 4.2.13 ";\n')
body += f'''// {M}: init() ohne modem::init(); Trägerfrequenz setzt Digidec
void dominoex::init()
{{
	if (mupsksec2pri.empty())
		MuPsk_sec2pri_init();
	rx_init();
	set_freq(wf->Carrier());
	set_scope_mode(Digiscope::DOMDATA);
}}

'''
write('src/mfsk/dominoex_rx.cpp', body)

# ===================================================================== Thor
write('src/mfsk/thorvaricode.cpp', read('thor/thorvaricode.cxx'))
write('src/mfsk/thorvaricode.h', read('include/thorvaricode.h'))
h = read('include/thor.h')
for inc in ['"complex.h"', '"modem.h"', '"globals.h"', '"picture.h"', '<FL/Fl_Shared_Image.H>']:
    h = must(h, f'#include {inc}\n', '')
h = must(h, '#include "mbuffer.h"\n', f'#include "mbuffer.h"\n#include "thorvaricode.h"\n#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, 'extern void init_def_thor_avatar(Fl_Group *w);\n', '')
h = must(h, 'class thor : public modem {', f'class thor : public fam_modem_base {{ // {M}\n\tfriend struct fldigi_mfsk; // {M}: C-Hülle')
write('src/mfsk/thor_rx.h', h)

c = read('thor/thor.cxx')
parts = []
parts.append(f'''// ----------------------------------------------------------------------------
// thor_rx.cpp  --  Thor-Empfänger aus fldigi 4.2.13 (src/thor/thor.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2006-2009 Dave Freese, W1HKJ. GNU GPL v3.
// {M}: Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen. Die Sendesteuerung
// (tx_process), Bild- und Avatar-Senden entfallen; empfangene Bilder werden aus dem Signal genommen, aber nicht
// angezeigt. Einstellungen/Anzeigen: mfsk_compat.h. Die function-static-Variablen von fldigi (Soft-Decoder,
// Preamble-Erkennung) bleiben: nur EIN Thor-Decoder gleichzeitig.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "thor_rx.h"

#define SOFTPROFILE true

// {M}: statische Elemente aus thor-pic.cxx
int thor::IMAGEspp = THOR_IMAGESPP;
std::string thor::imageheader;
std::string thor::avatarheader;

''')
i0 = c.index('static char thormsg[80];')
i1 = c.index('#include "thor-pic.cxx"')
parts.append(c[i0:i1])
for sig in ['void thor::tx_init()', 'void thor::rx_init()', 'void thor::reset_filters()', 'void thor::restart()', 'thor::~thor()',
            'thor::thor(trx_mode md) : hilbert(0), fft(0), filter_reset(false)', 'cmplx thor::mixer(int n, const cmplx& in)',
            'void thor::s2nreport(void)', 'void thor::parse_pic(int ch)', 'void thor::recvchar(int c)', 'void thor::decodePairs(unsigned char symbol)',
            'void thor::decodesymbol()', 'void thor::softdecodesymbol()', 'int thor::harddecode()', 'int thor::softdecode()',
            'bool thor::preambledetect(int c)', 'void thor::softflushrx()', 'void thor::update_syncscope()', 'void thor::synchronize()',
            'void thor::eval_s2n()', 'void thor::recvpic(double smpl)', 'int thor::rx_process(const double *buf, int len)',
            'int thor::get_secondary_char()', 'void thor::sendtone(int tone, int duration)', 'void thor::sendsymbol(int sym)',
            'void thor::sendchar(unsigned char c, int secondary)', 'void thor::sendidle()', 'void thor::sendsecondary()',
            'void thor::Clearbits()', 'void thor::flushtx()']:
    parts.append(block(c, sig))
# struct snpair + Tabelle stehen zwischen synchronize und eval_s2n
body = ''.join(parts)
sn0 = c.index('struct snpair {float val; float s2n;};')
sn1 = c.index('void thor::eval_s2n()')
body = must(body, 'void thor::eval_s2n()', c[sn0:sn1] + 'void thor::eval_s2n()')
body = must(body, '\tmodem::s2nreport();\n', f'\t// {M}: modem::s2nreport() entfällt (PSKmail)\n')
body = must(body, '\tactivate_thor_image_item(false);\n', f'\t// {M}: Bildmenü entfällt\n')
body = must(body, '\tactivate_thor_image_item(true);\n', f'\t// {M}: Bildmenü entfällt\n')
body = must(body, 'thor::thor(trx_mode md) : hilbert(0), fft(0), filter_reset(false)', f'thor::thor(trx_mode md) : fam_modem_base(), hilbert(0), fft(0), filter_reset(false) // {M}: Basisklasse')
body = must(body, '\tstrSecXmtText = progdefaults.THORsecText;\n\tif (strSecXmtText.length() == 0)\n\t\tstrSecXmtText = "fldigi " PACKAGE_VERSION " ";\n', '\tstrSecXmtText = progdefaults.THORsecText;\n\tif (strSecXmtText.length() == 0)\n\t\tstrSecXmtText = "fldigi 4.2.13 ";\n')
body += f'''// {M}: init() ohne modem::init(); Trägerfrequenz setzt Digidec
void thor::init()
{{
	rx_init();
	set_freq(wf->Carrier());
	imageheader.clear();
	avatarheader.clear();
	set_scope_mode(Digiscope::DOMDATA);
}}

'''
write('src/mfsk/thor_rx.cpp', body)
print('ok')
