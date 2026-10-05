#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
"""Übernimmt den WSPR-Decoder wsprd aus WSJT-X (K1JT, K9AN u. a., GPLv3) nach Vendor/Wspr.

Die Algorithmik (Kandidatensuche, Synchronisation, Soft-Symbole, Fano-Decoder, Signalsubtraktion,
Entpacken) wird wortgleich aus lib/wsprd übernommen. Von wsprd.c bleiben alle Funktionen vor main();
main() selbst (Kommandozeile, Dateien) ersetzt inc/wspr_decode.inc. Bricht ab, wenn das Original nicht
mehr wie erwartet aussieht."""
import os, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
UP = os.path.join(HERE, '../_upstream/wsjtx')
WD = os.path.join(UP, 'lib/wsprd')
PF = os.path.join(HERE, '../_upstream/pocketfft')
M = 'ABWEICHUNG wsprd (Digidec)'
SRC = os.path.join(HERE, 'src')

for f in ['fano.c', 'fano.h', 'jelinek.c', 'jelinek.h', 'nhash.c', 'nhash.h', 'tab.c',
          'wsprd_utils.c', 'wsprd_utils.h', 'wsprsim_utils.c', 'wsprsim_utils.h']:
    shutil.copyfile(os.path.join(WD, f), os.path.join(SRC, f))
# Metrik-Tabellen werden in main() eingefügt (#include), dürfen also nicht als eigene Quelle übersetzt werden
shutil.copyfile(os.path.join(WD, 'metric_tables.c'), os.path.join(HERE, "inc", "metric_tables.inc"))
shutil.copyfile(os.path.join(UP, 'COPYING'), os.path.join(HERE, 'LICENSE_wsjtx_GPLv3.txt'))
shutil.copyfile(os.path.join(PF, 'pocketfft_hdronly.h'), os.path.join(HERE, 'compat', 'pocketfft_hdronly.h'))
shutil.copyfile(os.path.join(PF, 'LICENSE.md'), os.path.join(HERE, 'LICENSE_pocketfft.md'))

def must(s, old, new):
    if s.count(old) != 1:
        sys.exit(f"Erwartet 1x: {old[:70]!r}")
    return s.replace(old, new)

w = open(os.path.join(WD, 'wsprd.c'), encoding='utf-8').read()
w = must(w, '#include <fftw3.h>\n', f'#include "wspr_fftw.h"   // {M}: pocketfft statt FFTW\n')
w = must(w, 'extern void osdwspr_ (float [], unsigned char [], int *, unsigned char [], int *, float *);\n',
         f'// {M}: osdwspr_ (Fortran, optionale OSD-Stufe) entfällt\n')
i = w.index('int main(int argc, char *argv[])')
w = w[:i] + f'''// {M}: main() (Kommandozeile, Dateien) ersetzt durch wspr_decode.inc
#include "wspr_decode.inc"
'''
dst = os.path.join(SRC, 'wspr_rx.c')
open(dst + '.tmp', 'w', encoding='utf-8').write(w)
os.replace(dst + '.tmp', dst)
print('ok')
