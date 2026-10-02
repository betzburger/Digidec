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

# ===================================================================== Throb
h = read('include/throb.h')
for inc in ['"modem.h"', '"globals.h"', '"complex.h"']:
    h = must(h, f'#include {inc}\n', '')
h = must(h, '#include "mbuffer.h"\n', f'#include "mbuffer.h"\n#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, 'class throb : public modem {', f'class throb : public fam_modem_base {{ // {M}\n\tfriend struct fldigi_mfsk; // {M}: C-Hülle')
write('src/mfsk/throb_rx.h', h)

c = read('throb/throb.cxx')
parts = [f'''// ----------------------------------------------------------------------------
// throb_rx.cpp  --  Throb-Empfänger aus fldigi 4.2.13 (src/throb/throb.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2006-2009 Dave Freese, W1HKJ, nach gmfsk (Tomi Manninen OH2BNS). GNU GPL v3.
// {M}: Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen; die Sendesteuerung
// (tx_process) entfällt. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "throb_rx.h"

#define MAX_TONES	15

#undef  CLAMP
#define CLAMP(x,low,high)       (((x)>(high))?(high):(((x)<(low))?(low):(x)))

char throbmsg[80];

''']
for sig in ['void  throb::tx_init()', 'void  throb::rx_init()', 'throb::~throb()', 'void throb::flip_syms()', 'void throb::reset_syms()',
            'throb::throb(trx_mode throb_mode) : modem()', 'cmplx *throb::mk_rxtone(double freq, double *pulse, int len)',
            'cmplx throb::mixer(cmplx in)', 'int throb::findtones(cmplx *word, int &tone1, int &tone2)', 'void throb::show_char(int c)',
            'void throb::decodechar(int tone1, int tone2)', 'void throb::rx(cmplx in)', 'void throb::sync(cmplx in)',
            'int throb::rx_process(const double *buf, int len)', 'double *throb::mk_semi_pulse(int len)', 'double *throb::mk_full_pulse(int len)',
            'void throb::send(int symbol)']:
    parts.append(block(c, sig))
t0 = c.index('int throb::ThrobTonePairs[45][2] = {')
parts.append(c[t0:])
body = ''.join(parts)
body = must(body, 'throb::throb(trx_mode throb_mode) : modem()', f'throb::throb(trx_mode throb_mode) : fam_modem_base() // {M}: Basisklasse')
body = must(body, '\tpreamble = 4;\n\treset_syms();\n\tvideoText();\n}', '\tpreamble = 4;\n\treset_syms();\n\tvideoText();\n}')
body += f'''// {M}: init() ohne modem::init(); Trägerfrequenz setzt Digidec
void throb::init()
{{
	rx_init();
	set_scope_mode(Digiscope::SCOPE);
	set_freq(wf->Carrier());
}}

'''
write('src/mfsk/throb_rx.cpp', body)

# ===================================================================== IFKP
write('src/mfsk/ifkp_varicode.inc', read('ifkp/ifkp_varicode.cxx'))
h = read('include/ifkp.h')
for inc in ['"trx.h"', '"modem.h"', '"complex.h"', '"picture.h"', '<FL/Fl_Shared_Image.H>']:
    h = must(h, f'#include {inc}\n', '')
h = must(h, '#include "filters.h"\n', f'#include "filters.h"\n#include <fstream>\n#include "gfft.h"\n#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, 'class ifkp : public modem {', f'class ifkp : public fam_modem_base {{ // {M}\n\tfriend struct fldigi_mfsk; // {M}: C-Hülle')
h = must(h, 'extern void init_def_ifkp_avatar(Fl_Group *w);\n', '')
h = must(h, '\tdouble\t\t\tmetric;\n', f'\t// {M}: metric kommt aus der Basisklasse\n')
h = must(h, 'public:\n\tint\t\t\tsymlen;\n', f'public:\n\t// {M}: symlen kommt aus der Basisklasse\n')
write('src/mfsk/ifkp_rx.h', h)

c = read('ifkp/ifkp.cxx')
parts = [f'''// ----------------------------------------------------------------------------
// ifkp_rx.cpp  --  IFKP-Empfänger aus fldigi 4.2.13 (src/ifkp/ifkp.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2015 Dave Freese, W1HKJ (IFKP: Incremental Frequency Keying Plus, Murray Greenman ZL1BPU). GNU GPL v3.
// {M}: Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen, außer wie unten
// vermerkt. Bild- und Avatar-Senden und -Anzeige, Heard- und Audit-Protokolle, Rufzeichenliste und die Sendesteuerung
// (tx_process) entfallen. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "ifkp_rx.h"

#define IFKP_SR 16000

#include "ifkp_varicode.inc"

static char sz[21];

int ifkp::IMAGEspp = IMAGESPP;
std::string ifkp::imageheader;
std::string ifkp::avatarheader;

int no_signal = 0;

''']
for sig in ['void ifkp::init_nibbles()', 'ifkp::ifkp(trx_mode md) : modem()', 'ifkp::~ifkp()', 'void  ifkp::tx_init()', 'void  ifkp::rx_init()',
            'void ifkp::rx_reset()', 'void ifkp::set_freq(double f)', 'void ifkp::restart()', 'bool ifkp::valid_char(int ch)',
            'void ifkp::parse_pic(int ch)', 'void ifkp::process_tones()', 'void ifkp::recvpic(double smpl)', 'int ifkp::rx_process(const double *buf, int len)',
            'void ifkp::transmit(double *buf, int len)', 'void ifkp::send_tone(int tone)', 'void ifkp::send_symbol(int sym)',
            'void ifkp::send_idle()', 'void ifkp::send_char(int ch)']:
    parts.append(block(c, sig))
body = ''.join(parts)
body = must(body, 'ifkp::ifkp(trx_mode md) : modem()', f'ifkp::ifkp(trx_mode md) : fam_modem_base() // {M}: Basisklasse')
body = must(body, '\tREQ(put_freq, frequency);\n', f'\t// {M}: Frequenzanzeige entfällt\n', count=2)
body = must(body, '\ttoggle_logs();\n\n\tactivate_ifkp_image_item(true);\n', f'\t// {M}: Protokolle und Bildmenü entfallen\n')
body = must(body, '\tifkp_deleteTxViewer();\n\tifkp_deleteRxViewer();\n\theard_log.close();\n\taudit_log.close();\n\n\tactivate_ifkp_image_item(false);\n', f'\t// {M}: Bildfenster, Protokolle und Bildmenü entfallen\n')
body = must(body, '\tmycall = progdefaults.myCall;\n\tif (progdefaults.ifkp_lowercase)\n\t\tfor (size_t n = 0; n < mycall.length(); n++) mycall[n] = tolower(mycall[n]);\n\tvideoText();', '\tvideoText();')
# set_freq: Protokollausgabe (LOG_VERBOSE) entfällt
a = body.index('\tstd::ostringstream it;')
b = body.index('LOG_VERBOSE("%s", it.str().c_str());') + len('LOG_VERBOSE("%s", it.str().c_str());')
body = body[:a] + f'\t// {M}: Protokollausgabe entfällt' + body[b:]
# restart: mycall/show_mode entfallen
body = must(body, '\tmycall = progdefaults.myCall;\n\tif (progdefaults.ifkp_lowercase)\n\t\tfor (size_t n = 0; n < mycall.length(); n++) mycall[n] = tolower(mycall[n]);\n\n\tmovavg_size', '\tmovavg_size')
body = must(body, '\n\tshow_mode();\n', '\n')
# Bild-Anzeige: leer
body = must(body, '\t\tREQ( ifkp_showRxViewer, pic_str[4]);', f'\t\t;   // {M}: Bildanzeige entfällt')
body = must(body, '\t\tREQ( ifkp_clear_avatar );', f'\t\t;   // {M}: Avatar-Anzeige entfällt')
for name in ['ifkp_update_avatar', 'ifkp_updateRxPic']:
    body = body.replace(f'REQ({name}, byte, pixelnbr', f'(void)(byte, pixelnbr')
body = body.replace('REQ(ifkp_enableshift);', '')
# rx_process: Protokoll-Umschalter und Abbruch entfallen
a = body.index('\tif (enable_audit_log != progdefaults.ifkp_enable_audit_log ||')
b = body.index('\tif (bkptr < 0) bkptr = 0;')
body = body[:a] + body[b:]
a = body.index('\tif (progStatus.ifkp_rx_abort) {')
b = body.index('\twhile (len) {')
body = body[:a] + body[b:]
# send_tone: Testsignalfenster entfällt
a = body.index('\tif (test_signal_window && test_signal_window->visible() && btnOffsetOn->value())')
b = body.index('\tphaseincr = 2.0 * M_PI * frequency / samplerate;')
body = body[:a] + body[b:]
# process_symbol von Hand: Zeichen an Rückruf, Rufzeichen/Protokolle entfallen
ps = f'''// {M}: process_symbol ohne Protokolle und Rufzeichenliste (Zeichen gehen an put_rx_char)
void ifkp::process_symbol(int sym)
{{
	int nibble = 0;
	int curr_ch = -1	;

	symbol = sym;

	nibble = symbol - prev_symbol;
	if (nibble < -99 || nibble > 99) {{
		prev_symbol = symbol;
		return;
	}}
	nibble = nibbles[nibble + 99];

	if (nibble >= 0) {{ // process nibble
		curr_nibble = nibble;

// single-nibble characters
		if ((prev_nibble < 29) & (curr_nibble < 29)) {{
			curr_ch = ifkp_varidecode[prev_nibble];

// double-nibble characters
		}} else if ( (prev_nibble < 29) &&
					 (curr_nibble > 28) &&
					 (curr_nibble < 32)) {{
			curr_ch = ifkp_varidecode[prev_nibble * 32 + curr_nibble];
		}}
		if (curr_ch > 0) {{
			if (ch_sqlch_open || metric >= progStatus.sldrSquelchValue) {{
				put_rx_char(curr_ch);
				parse_pic(curr_ch);
			}}
		}}
		prev_nibble = curr_nibble;
	}}

	prev_symbol = symbol;
}}

'''
body = must(body, 'void ifkp::process_tones()', ps + 'void ifkp::process_tones()')
body += f'''// {M}: init() ohne Protokolle; Trägerfrequenz setzt Digidec
void ifkp::init()
{{
	peak_hits = 4;
	movavg_size = 3;
	for (int i = 0; i < IFKP_NUMBINS; i++) binfilt[i]->setLength(movavg_size);
	rx_init();
}}

'''
write('src/mfsk/ifkp_rx.cpp', body)

# ===================================================================== FSQ
write('src/mfsk/fsq_varicode.inc', read('fsq/fsq_varicode.cxx'))
write('src/mfsk/crc8.h', read('include/crc8.h'))
h = read('include/fsq.h')
for inc in ['"trx.h"', '"modem.h"', '"complex.h"', '"picture.h"', '<FL/Fl_Shared_Image.H>']:
    h = must(h, f'#include {inc}\n', '')
h = must(h, '#include "crc8.h"\n', f'#include "crc8.h"\n#include "gfft.h"\n#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, 'class fsq : public modem {', f'class fsq : public fam_modem_base {{ // {M}\n\tfriend struct fldigi_mfsk; // {M}: C-Hülle')
a = h.index('friend void timed_xmt(void *);')
b = h.index('public:\n\nprotected:')
h = h[:a] + f'// {M}: friend-Deklarationen der Sendesteuerung entfallen\n\n' + h[b:]
h = must(h, '\tdouble\t\t\tmetric;\n', f'\t// {M}: metric kommt aus der Basisklasse\n')
write('src/mfsk/fsq_rx.h', h)

c = read('fsq/fsq.cxx')
parts = [f'''// ----------------------------------------------------------------------------
// fsq_rx.cpp  --  FSQ-Empfänger aus fldigi 4.2.13 (src/fsq/fsq.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2015 Dave Freese, W1HKJ (FSQ: Fast Simple QSO, Con Wassilieff ZL1ACN und Murray Greenman ZL1BPU). GNU GPL v3.
// {M}: Empfangsfunktionen wörtlich übernommen, außer wie unten vermerkt; die Sendefunktionen (send_*) sind nur für
// das Testsignal. Die Auswertung gerichteter Befehle (parse_*: Antworten, Weiterleiten, Sounder, Bildübertragung,
// Heard-Liste), Protokolle und die Sendesteuerung entfallen. Die Zeichen gehen wie im fldigi-Monitor (nicht
// „gerichtet“) in den Empfangstext. Einstellungen/Anzeigen: mfsk_compat.h.
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "fsq_rx.h"

#include "fsq_varicode.inc"

#define SQLFILT_SIZE 64

#define NIT std::string::npos
#define txcenterfreq  1500.0

int fsq::symlen = 4096; // nominal symbol length; 3 baud

static const char *FSQBOL = " \\n";
static const char *FSQEOL = "\\n ";
static const char *FSQEOT = "  \\b  ";

''']
for sig in ['void fsq::init_nibbles()', 'fsq::fsq(trx_mode md) : modem()', 'fsq::~fsq()', 'void  fsq::tx_init()', 'void  fsq::rx_init()',
            'void fsq::set_freq(double f)', 'void fsq::adjust_for_speed()', 'void fsq::restart()', 'bool fsq::valid_char(int ch)',
            'bool fsq::fsq_squelch_open()', 'void fsq::lf_check(int ch)', 'void fsq::process_tones()',
            'int fsq::rx_process(const double *buf, int len)', 'void fsq::send_tone(int tone)', 'void fsq::send_symbol(int sym)',
            'void fsq::send_idle()', 'void fsq::send_char(int ch)', 'void fsq::send_string(std::string s)']:
    parts.append(block(c, sig))
body = ''.join(parts)
body = must(body, 'fsq::fsq(trx_mode md) : modem()', f'fsq::fsq(trx_mode md) : fam_modem_base() // {M}: Basisklasse')
body = must(body, '\tmodem::set_freq(1500); // default Rx/Tx center frequency\n', f'\tfrequency = 1500; // default Rx/Tx center frequency ({M}: ohne modem::set_freq)\n')
body = must(body, '\tstart_aging();\n\n\tshow_mode();\n\n\trestart();\n\n\ttoggle_logs();\n', f'\t// {M}: Alterung, Anzeige und Protokolle entfallen\n\trestart();\n')
body = must(body, '\tfsq_tx_image = false;\n\n\tinit_nibbles();', '\tfsq_tx_image = false;\n\n\tinit_nibbles();')
# Destruktor von Hand
a = body.index('fsq::~fsq()')
b = body.index('void  fsq::tx_init()')
body = body[:a] + f'''fsq::~fsq()
{{
	delete fft;
	delete snfilt;
	delete sigfilt;
	delete noisefilt;
	for (int i = 0; i < NUMBINS; i++)
		delete binfilt[i];
	delete picfilt;   // {M}: Fenster, Sounder, Alterung und Protokolle entfallen
}};

'''.replace('picfilt', 'picfilter') + body[b:]
body = must(body, '\tmycall = progdefaults.myCall;\n\tif (progdefaults.fsq_lowercase)\n\t\tfor (size_t n = 0; n < mycall.length(); n++) mycall[n] = tolower(mycall[n]);\n\tvideoText();', '\tvideoText();')
body = must(body, '\tmodem::set_freq(frequency);\n', f'\t// {M}: modem::set_freq entfällt\n')
body = must(body, '\tshow_mode();\n}', '}')
body = must(body, '\tmycall = progdefaults.myCall;\n\tif (progdefaults.fsq_lowercase)\n\t\tfor (size_t n = 0; n < mycall.length(); n++) mycall[n] = tolower(mycall[n]);\n\n\tmovavg_size', '\tmovavg_size')
body = must(body, '\n\tprintit(speed, bandwidth, symlen, SHIFT_SIZE, peak_hits, basetone);\n', '\n')
body = must(body, 'tx_basetone = ceil((get_txfreq() - bandwidth / 2) * FSQ_SYMLEN / samplerate );', 'tx_basetone = ceil((frequency - bandwidth / 2) * FSQ_SYMLEN / samplerate );')
# rx_process: Protokolle, Sounder, Abbruch entfallen
a = body.index('\tif (enable_heard_log != progdefaults.fsq_enable_heard_log ||')
b = body.index('\tif (bkptr < 0) bkptr = 0;')
body = body[:a] + body[b:]
a = body.index('\tif (progStatus.fsq_rx_abort) {')
b = body.index('\twhile (len) {')
body = body[:a] + body[b:]
a = body.index('\t\tif (state == IMAGE) {')
b = body.index('\t\t} else {\n\t\t\trx_stream[BLOCK_SIZE + bkptr] = *buf;')
body = body[:a] + f'\t\tif (false) {{   // {M}: Bildempfang entfällt\n\t\t\tlen--;\n\t\t\tbuf++;\n' + body[b:]
# send_tone: Testsignalfenster entfällt; send_char: Anzeige entfällt; send_string: Bild entfällt
a = body.index('\tif (test_signal_window && test_signal_window->visible() && btnOffsetOn->value())')
b = body.index('\tphaseincr = 2.0 * M_PI * freq / samplerate;')
body = body[:a] + body[b:]
body = must(body, '\tif (valid_char(ch) && !(send_bot || send_eot))\n\t\tput_echo_char(ch);\n\n\twrite_mon_tx_char(ch);\n', '')
body = must(body, '\tif ((s == FSQEOT || s == FSQEOL) && fsq_tx_image) send_image();\n', '')
# process_symbol von Hand
ps = f'''// {M}: process_symbol ohne Protokolle, Monitor-Anzeige und parse_rx_text; die Zeichen gehen wie im fldigi-Monitor
// (nicht „gerichtet“) in den Empfangstext
static void fsq_emit(fam_modem_base *m, int ch)
{{
	if (ch == 10 || ch == 163 || ch == 176 || ch == 177 || ch == 215 || ch == 247 || (ch > 31 && ch < 128))
		m->put_rx_char(ch);
}}

void fsq::process_symbol(int sym)
{{
	int nibble = 0;
	int curr_ch = -1;

	symbol = sym;

	nibble = symbol - prev_symbol;
	if (nibble < -99 || nibble > 99) {{
		prev_symbol = symbol;
		return;
	}}
	nibble = nibbles[nibble + 99];

// -1 is our idle symbol, indicating we already have our symbol
	if (nibble >= 0) {{ // process nibble
		curr_nibble = nibble;

// single-nibble characters
		if ((prev_nibble < 29) & (curr_nibble < 29)) {{
			curr_ch = wsq_varidecode[prev_nibble];

// double-nibble characters
		}} else if ( (prev_nibble < 29) &&
					 (curr_nibble > 28) &&
					 (curr_nibble < 32)) {{
			curr_ch = wsq_varidecode[prev_nibble * 32 + curr_nibble];
		}}
		if (curr_ch > 0) {{
			lf_check(curr_ch);

			if (b_bot) {{
				ch_sqlch_open = true;
				rx_text.clear();
			}}

			if (fsq_squelch_open()) {{
				if (b_bot) fsq_emit(this, 10);
				if (b_eol) {{
					noisefilt->reset();
					noisefilt->run(1);
					sigfilt->reset();
					sigfilt->run(1);
				}}
				if (b_eot) {{
					noisefilt->reset();
					noisefilt->run(1);
					sigfilt->reset();
					sigfilt->run(1);
				}}
				if (!b_bot && !b_eot) fsq_emit(this, curr_ch);
			}}

			if (fsq_squelch_open() && (b_eot || b_eol)) {{
				ch_sqlch_open = false;
				metric = 0;
			}}
		}}
		prev_nibble = curr_nibble;
	}}

	prev_symbol = symbol;
}}

'''
body = must(body, 'void fsq::process_tones()', ps + 'void fsq::process_tones()')
body += f'''// {M}: init() ohne modem::init() und Sounder; Trägerfrequenz setzt Digidec
void fsq::init()
{{
	rx_init();
}}

'''
write('src/mfsk/fsq_rx.cpp', body)

# ===================================================================== Hell (Feld Hell und Verwandte)
write('src/mfsk/feldhell_12.inc', read('feld/FeldHell-12.cxx'))
h = read('include/feld.h')
h = must(h, '#include "modem.h"\n', f'#include "mfsk_compat.h" // {M}: Umgebung statt fldigi-Modem\n')
h = must(h, 'class feld : public modem {', f'class feld : public fam_modem_base {{ // {M}\n\tfriend struct fldigi_hell; // {M}: C-Hülle')
write('src/mfsk/feld_rx.h', h)

c = read('feld/feld.cxx')
parts = [f'''// ----------------------------------------------------------------------------
// feld_rx.cpp  --  Feld-Hell-Empfänger aus fldigi 4.2.13 (src/feld/feld.cxx), erzeugt von port_mfsk.py
//
// Copyright (C) 2006-2008 Dave Freese, W1HKJ (Feld Hell: Rudolf Hell, 1929). GNU GPL v3.
// {M}: Empfangsfunktionen und Sendefunktionen (nur für das Testsignal) wörtlich übernommen, außer wie unten
// vermerkt; die Sendesteuerung (tx_process) entfällt. Rasterspalten gehen an einen Rückruf statt in das
// Raster-Widget. Einstellungen/Anzeigen: mfsk_compat.h. Schriftart: nur „hell 12“ (fldigi-Standard, feldfontnbr 4).
// ----------------------------------------------------------------------------
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include "feld_rx.h"

#include "feldhell_12.inc"

''']
for sig in ['void feld::rx_init()', 'void feld::restart()', 'feld::~feld()', 'feld::feld(trx_mode m)', 'cmplx feld::mixer(cmplx in)',
            'void feld::FSKH_rx(cmplx z)', 'void feld::rx(cmplx z)', 'int feld::rx_process(const double *buf, int len)',
            'int feld::get_font_data(unsigned char c, int col)', 'double feld::nco(double freq)', 'void feld::send_symbol(int currsymb, int nextsymb)',
            'void feld::send_null_column()', 'void feld::tx_char(char c)', 'void feld::initKeyWaveform()']:
    parts.append(block(c, sig))
body = ''.join(parts)
body = must(body, '\tguard_lock raster_lock(&feld_mutex);\n\n\tdouble f;', f'\t// {M}: keine Sperre (ein Thread)\n\n\tdouble f;')
body = must(body, '\tguard_lock raster_lock(&feld_mutex);\n\n\tdouble x, avg;', f'\t// {M}: keine Sperre (ein Thread)\n\n\tdouble x, avg;')
# Rasterspalten an den Rückruf: je Aufruf 2·RxColumnLen Werte (vorherige und aktuelle Spalte)
body = body.replace('REQ(put_rx_data, col_data, 2 * RxColumnLen);', 'put_rx_data(col_data, 2 * RxColumnLen);')
body = must(body, '\tREQ(set_HellBW, filter_bandwidth);\n', f'\t// {M}: Anzeige der Filterbreite entfällt\n')
body = must(body, '\twf->redraw_marker();\n\n\tREQ(&Raster::set_marquee, FHdisp, progdefaults.HellMarquee);\n', f'\t// {M}: Marker und Raster-Widget entfallen\n')
body = must(body, '\tset_bandwidth(hell_bandwidth);', '\tset_bandwidth(hell_bandwidth);')
body = must(body, '\t\twf->redraw_marker();\n', f'\t\t// {M}: Marker entfällt\n')
body = must(body, '\twf->redraw_marker();\n\n\tREQ', '\t// x\n\tREQ') if False else body
# send_symbol: kein Mithören über den Empfänger
body = must(body, '\trx_process(outbuf, outlen);\n', f'\t// {M}: Mithören über den Empfänger entfällt\n')
# Schrift: nur hell 12
a = body.index('\tswitch (progdefaults.feldfontnbr) {')
b = body.index('\t}\n\tfor (int i = 0; i < 14; i++) ordbits')
body = body[:a] + f'\tfont = feldhell_12;   // {M}: nur die Standardschrift\n' + body[b+3:]
body += f'''// {M}: init() ohne modem::init(); Trägerfrequenz setzt Digidec
void feld::init()
{{
	initKeyWaveform();
	set_scope_mode(Digiscope::BLANK);
	rx_init();
}}

void feld::tx_init()
{{
	txcounter = 0.0;
	tx_state = PREAMBLE;
	preamble = 3;
	prevsymb = false;
}}

'''
write('src/mfsk/feld_rx.cpp', body)
print('ok')
