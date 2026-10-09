#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
"""Übernimmt den FT8-Decoder ft8mon (Robert Morris AB1HL, MIT) und pocketfft (BSD) nach Vendor/FT8.

Die Dateien werden wortgleich kopiert. Einziger Eingriff: in util.cc sind readwav/writewav (libsndfile)
ausgeklammert; der Decoder ruft sie nicht auf. FFTW ersetzt compat/fftw3.h (pocketfft). Bricht ab,
wenn das Original nicht mehr wie erwartet aussieht."""
import os, sys, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
UP = os.path.join(HERE, '../_upstream/ft8mon')
PF = os.path.join(HERE, '../_upstream/pocketfft')
M = 'ABWEICHUNG ft8mon (Digidec)'

for f in ['ft8.cc', 'ft8.h', 'unpack.cc', 'unpack.h', 'osd.cc', 'util.h', 'fft.cc', 'fft.h', 'arrays.h']:
    shutil.copyfile(os.path.join(UP, f), os.path.join(HERE, 'src', f))
# ft8mon übersetzt libldpc.c mit c++ (Makefile); SwiftPM übersetzt .c als C → als .cc übernehmen
shutil.copyfile(os.path.join(UP, 'libldpc.c'), os.path.join(HERE, 'src', 'libldpc.cc'))
shutil.copyfile(os.path.join(UP, 'LICENSE.txt'), os.path.join(HERE, 'LICENSE_ft8mon.txt'))
shutil.copyfile(os.path.join(PF, 'pocketfft_hdronly.h'), os.path.join(HERE, 'compat', 'pocketfft_hdronly.h'))
shutil.copyfile(os.path.join(PF, 'LICENSE.md'), os.path.join(HERE, 'LICENSE_pocketfft.md'))

u = open(os.path.join(UP, 'util.cc'), encoding='utf-8').read()
def must(s, old, new):
    if s.count(old) != 1:
        sys.exit(f"Erwartet 1x: {old[:60]!r}")
    return s.replace(old, new)
u = must(u, '#include <sndfile.h>\n', f'#ifdef DIGIDEC_WITH_SNDFILE // {M}: libsndfile nur für Dateien, im Decoder ungenutzt\n#include <sndfile.h>\n#endif\n')
i = u.index('void\nwritewav(')
j = u.index('void\nwritetxt(')
u = u[:i] + f'#ifdef DIGIDEC_WITH_SNDFILE // {M}\n' + u[i:j] + '#endif\n\n' + u[j:]
dst = os.path.join(HERE, 'src', 'util.cc')
open(dst + '.tmp', 'w', encoding='utf-8').write(u)
os.replace(dst + '.tmp', dst)
# Encoder aus ft8_lib (Kārlis Goba YL3JG, MIT) – nur für Testsignale (Digidec sendet nie)
FL = os.path.join(HERE, '../_upstream/ft8_lib')
os.makedirs(os.path.join(HERE, 'src', 'ft8lib'), exist_ok=True)
for f in ['message.c', 'message.h', 'encode.c', 'encode.h', 'constants.c', 'constants.h', 'crc.c', 'crc.h',
          'text.c', 'text.h', 'debug.h']:
    shutil.copyfile(os.path.join(FL, 'ft8', f), os.path.join(HERE, 'src', 'ft8lib', f))
shutil.copyfile(os.path.join(FL, 'LICENSE'), os.path.join(HERE, 'LICENSE_ft8_lib.txt'))
print('ok')
