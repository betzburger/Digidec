#!/bin/zsh
# Übersetzt Vendor/Fldigi (C++ und GNU-Regex in C) und Vendor/FT8 (ft8mon) und Vendor/Wspr (wsprd) außerhalb von SwiftPM für Logiktests und Werkzeuge.
# Aufruf: Tools/build_fldigi.sh <ausgabeordner>
# Ergebnis: <ausgabeordner>/obj/*.o und <ausgabeordner>/module/module.modulemap (Module „Fldigi“, „FT8“ und „Wspr“ wie im Package)
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$1"
F="$ROOT/Vendor/Fldigi"
INC=(-I$F/include -I$F/src -I$F/src/common -I$F/src/rtty -I$F/src/synop -I$F/src/misc -I$F/src/navtex -I$F/src/cw -I$F/src/wefax -I$F/src/psk -I$F/src/mt63 -I$F/src/olivia -I$F/src/mfsk -I$F/mt63data -I$F/compat)
mkdir -p "$OUT/obj" "$OUT/module"
cc -O2 -w -I$F/src -c $F/src/compat/regex.c -o "$OUT/obj/regex.o"
for c in $F/src/**/*.cpp; do
    clang++ -std=c++17 -O2 -w $INC -c "$c" -o "$OUT/obj/${c:h:t}_${c:t:r}.o"
done
G="$ROOT/Vendor/FT8"
for c in $G/src/*.cc; do
    clang++ -std=c++17 -O3 -w -I$G/include -I$G/src -I$G/compat -c "$c" -o "$OUT/obj/ft8_${c:t:r}.o"
done
for c in $G/src/*.c $G/src/ft8lib/*.c; do
    cc -O2 -w -I$G/include -I$G/src -c "$c" -o "$OUT/obj/ft8c_${c:t:r}.o"
done
W="$ROOT/Vendor/Wspr"
for c in $W/src/*.cc; do
    clang++ -std=c++17 -O3 -w -I$W/include -I$W/src -I$W/compat -c "$c" -o "$OUT/obj/wspr_${c:t:r}.o"
done
for c in $W/src/*.c; do
    cc -O3 -w -ffast-math -I$W/include -I$W/src -I$W/inc -c "$c" -o "$OUT/obj/wsprc_${c:t:r}.o"
done
cat > "$OUT/module/module.modulemap" <<MAP
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
MAP
