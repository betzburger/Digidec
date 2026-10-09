#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Übersetzt Vendor/Fldigi (C++ und GNU-Regex in C), Vendor/FT8 (ft8mon), Vendor/Wspr (wsprd), Vendor/JS8 (JS8Call) und Vendor/Codec2 außerhalb von SwiftPM für Logiktests und Werkzeuge.
# Aufruf: Tools/build_fldigi.sh <ausgabeordner>
# Objekte werden nur neu übersetzt, wenn die Quelldatei neuer ist (Änderungen an Headern: Ordner obj löschen); die Modul-Map wird nur bei Änderung neu geschrieben.
# Ergebnis: <ausgabeordner>/obj/*.o und <ausgabeordner>/module/module.modulemap (Module „Fldigi“, „FT8“, „Wspr“, „JS8“ und „Codec2“ wie im Package)
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$1"
F="$ROOT/Vendor/Fldigi"
INC=(-I$F/include -I$F/src -I$F/src/common -I$F/src/rtty -I$F/src/synop -I$F/src/misc -I$F/src/navtex -I$F/src/cw -I$F/src/wefax -I$F/src/psk -I$F/src/mt63 -I$F/src/olivia -I$F/src/mfsk -I$F/mt63data -I$F/compat)
mkdir -p "$OUT/obj" "$OUT/module"
if [[ ! -f "$OUT/obj/regex.o" || $F/src/compat/regex.c -nt "$OUT/obj/regex.o" ]]; then cc -O2 -w -I$F/src -c $F/src/compat/regex.c -o "$OUT/obj/regex.o"; fi
for c in $F/src/**/*.cpp; do
    if [[ ! -f "$OUT/obj/${c:h:t}_${c:t:r}.o" || "$c" -nt "$OUT/obj/${c:h:t}_${c:t:r}.o" ]]; then clang++ -std=c++17 -O2 -w $INC -c "$c" -o "$OUT/obj/${c:h:t}_${c:t:r}.o"; fi
done
G="$ROOT/Vendor/FT8"
for c in $G/src/*.cc; do
    if [[ ! -f "$OUT/obj/ft8_${c:t:r}.o" || "$c" -nt "$OUT/obj/ft8_${c:t:r}.o" ]]; then clang++ -std=c++17 -O3 -w -I$G/include -I$G/src -I$G/compat -c "$c" -o "$OUT/obj/ft8_${c:t:r}.o"; fi
done
for c in $G/src/*.c $G/src/ft8lib/*.c; do
    if [[ ! -f "$OUT/obj/ft8c_${c:t:r}.o" || "$c" -nt "$OUT/obj/ft8c_${c:t:r}.o" ]]; then cc -O2 -w -I$G/include -I$G/src -c "$c" -o "$OUT/obj/ft8c_${c:t:r}.o"; fi
done
W="$ROOT/Vendor/Wspr"
for c in $W/src/*.cc; do
    if [[ ! -f "$OUT/obj/wspr_${c:t:r}.o" || "$c" -nt "$OUT/obj/wspr_${c:t:r}.o" ]]; then clang++ -std=c++17 -O3 -w -I$W/include -I$W/src -I$W/compat -c "$c" -o "$OUT/obj/wspr_${c:t:r}.o"; fi
done
for c in $W/src/*.c; do
    if [[ ! -f "$OUT/obj/wsprc_${c:t:r}.o" || "$c" -nt "$OUT/obj/wsprc_${c:t:r}.o" ]]; then cc -O3 -w -ffast-math -I$W/include -I$W/src -I$W/inc -c "$c" -o "$OUT/obj/wsprc_${c:t:r}.o"; fi
done
J8="$ROOT/Vendor/JS8"
if [[ ! -f "$OUT/obj/js8_core.o" || $J8/src/js8_core.cc -nt "$OUT/obj/js8_core.o" || $J8/inc/js8_api.inc -nt "$OUT/obj/js8_core.o" || $J8/compat/js8_compat.h -nt "$OUT/obj/js8_core.o" ]]; then
    clang++ -std=gnu++20 -O3 -w -I$J8/include -I$J8/src -I$J8/compat -I$J8/inc -c $J8/src/js8_core.cc -o "$OUT/obj/js8_core.o"
fi
for c in $J8/src/*.c; do
    if [[ ! -f "$OUT/obj/js8c_${c:t:r}.o" || "$c" -nt "$OUT/obj/js8c_${c:t:r}.o" ]]; then cc -O2 -w -I$J8/include -c "$c" -o "$OUT/obj/js8c_${c:t:r}.o"; fi
done
C2="$ROOT/Vendor/Codec2"
C2NAMES=(kiss_fft kiss_fftr kiss_fftri kiss_fft_alloc kiss_fftr_alloc kiss_fft_stride kiss_fft_cleanup kiss_fft_next_fast_size encode)
C2DEFS=(-DGIT_HASH=\"310777b\")
for n in $C2NAMES; do C2DEFS+=(-D$n=c2_$n); done
for c in $C2/src/*.c; do
    if [[ ! -f "$OUT/obj/codec2_${c:t:r}.o" || "$c" -nt "$OUT/obj/codec2_${c:t:r}.o" ]]; then cc -O3 -w -I$C2/src -I$C2/include $C2DEFS -c "$c" -o "$OUT/obj/codec2_${c:t:r}.o"; fi
done
cat > "$OUT/module/module.modulemap.new" <<MAP
module Fldigi {
    header "$F/include/fldigi_rtty.h"
    header "$F/include/fldigi_synop.h"
    header "$F/include/fldigi_navtex.h"
    header "$F/include/fldigi_cw.h"
    header "$F/include/fldigi_wefax.h"
    header "$F/include/fldigi_psk.h"
    header "$F/include/fldigi_olivia.h"
    header "$F/include/fldigi_mt63.h"
    header "$F/include/fldigi_mfsk.h"
    header "$F/include/fldigi_hell.h"
    export *
}
module FT8 {
    header "$G/include/ft8_digidec.h"
    export *
}
module Wspr {
    header "$W/include/wspr_digidec.h"
    export *
}
module JS8 {
    header "$J8/include/js8_digidec.h"
    header "$J8/include/jsc_words.h"
    export *
}
module Codec2 {
    header "$C2/include/codec2_digidec.h"
    export *
}
MAP
# Nur ersetzen, wenn sich der Inhalt geändert hat (sonst gelten alle Swift-Dateien als veraltet)
if [[ -f "$OUT/module/module.modulemap" ]] && cmp -s "$OUT/module/module.modulemap" "$OUT/module/module.modulemap.new"; then
    rm -f "$OUT/module/module.modulemap.new"
else
    mv "$OUT/module/module.modulemap.new" "$OUT/module/module.modulemap"
fi
