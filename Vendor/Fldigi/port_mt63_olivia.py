#!/usr/bin/env python3
"""Übernimmt MT63 (Pawel Jalocha SP9VRC, dsp.cxx / mt63base.cxx) und die Olivia/Contestia-Bibliothek
(Pawel Jalocha, include/jalocha/*.h, nur Header) aus fldigi 4.2.13 nach Vendor/Fldigi. Die Bibliotheken werden
wortgleich kopiert; die Empfangslogik der fldigi-Modems (mt63.cxx, olivia.cxx, contestia.cxx) steht in den von
Hand geschriebenen Rahmen src/mt63/mt63_rx.cpp und src/olivia/olivia_rx.cpp. Bricht ab, wenn Dateien fehlen."""
import os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
UP = os.path.join(HERE, '../_upstream/fldigi-4.2.13/src')

def cp(src, dst):
    s = os.path.join(UP, src)
    if not os.path.exists(s): sys.exit(f"fehlt: {src}")
    shutil.copyfile(s, os.path.join(HERE, dst))

cp('mt63/dsp.cxx', 'src/mt63/dsp.cpp')
cp('mt63/mt63base.cxx', 'src/mt63/mt63base.cpp')
cp('include/dsp.h', 'src/mt63/dsp.h')
cp('include/mt63base.h', 'src/mt63/mt63base.h')
for f in ['symbol.dat', 'mt63intl.dat', 'alias_k5.dat', 'alias_1k.dat', 'alias_2k.dat']:
    cp('mt63/' + f, 'mt63data/' + f)
for f in ['pj_cmpx.h', 'pj_fft.h', 'pj_fht.h', 'pj_fifo.h', 'pj_gray.h', 'pj_lowpass3.h', 'pj_mfsk.h', 'pj_struc.h']:
    cp('include/jalocha/' + f, 'src/olivia/jalocha/' + f)
print('ok')
