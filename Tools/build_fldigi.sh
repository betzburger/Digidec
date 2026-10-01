#!/bin/zsh
# Übersetzt Vendor/Fldigi (C++ und GNU-Regex in C) außerhalb von SwiftPM für Logiktests und Werkzeuge.
# Aufruf: Tools/build_fldigi.sh <ausgabeordner>
# Ergebnis: <ausgabeordner>/obj/*.o und <ausgabeordner>/module/module.modulemap (Modul „Fldigi“ wie im Package)
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$1"
F="$ROOT/Vendor/Fldigi"
INC=(-I$F/include -I$F/src -I$F/src/common -I$F/src/rtty -I$F/src/synop -I$F/src/misc -I$F/src/navtex -I$F/compat)
mkdir -p "$OUT/obj" "$OUT/module"
cc -O2 -w -I$F/src -c $F/src/compat/regex.c -o "$OUT/obj/regex.o"
for c in $F/src/**/*.cpp; do
    clang++ -std=c++17 -O2 -w $INC -c "$c" -o "$OUT/obj/${c:h:t}_${c:t:r}.o"
done
cat > "$OUT/module/module.modulemap" <<MAP
module Fldigi {
    header "$F/include/fldigi_rtty.h"
    header "$F/include/fldigi_synop.h"
    header "$F/include/fldigi_navtex.h"
    export *
}
MAP
