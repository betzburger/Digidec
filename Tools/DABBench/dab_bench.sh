#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Prüfstand für den DAB-Empfänger: decodiert eine Aufnahme (8-Bit-I/Q, 2,048 MS/s; HackRF-Rohdaten sind vorzeichenbehaftet, Option --signed).
# Aufruf:  Tools/DABBench/dab_bench.sh fic <aufnahme.raw> [--signed] [--out fib.bin]
#          Tools/DABBench/dab_bench.sh msc <aufnahme.raw> "<Dienstname>" [--signed] [--wav aus.wav] [--au-out aus.au]
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.build/dab_bench"
BIN="$OUT/dab_bench"
S="$ROOT/Sources"
F="$ROOT/Vendor/Faad2"
mkdir -p "$OUT/faad2"
# FAAD2 einmal übersetzen und als Modul bereitstellen
if [[ ! -f "$OUT/faad2/libfaad2.a" ]]; then
    for c in $F/src/*.c; do
        clang -O2 -w -c -I$F/src -I$F/include -DHAVE_INTTYPES_H=1 -DHAVE_MEMCPY=1 -DHAVE_STRING_H=1 -DHAVE_STRINGS_H=1 -DHAVE_SYS_STAT_H=1 -DHAVE_SYS_TYPES_H=1 -DHAVE_LRINTF=1 -DAPPLY_DRC '-DPACKAGE_VERSION="2.11.4"' "$c" -o "$OUT/faad2/$(basename $c .c).o"
    done
    ar rcs "$OUT/faad2/libfaad2.a" "$OUT/faad2"/*.o
    printf 'module Faad2 {\n    header "%s/include/neaacdec.h"\n    export *\n}\n' "$F" > "$OUT/faad2/module.modulemap"
fi
SRC=($ROOT/Tools/DABBench/main.swift $ROOT/Tools/DABBench/DABSelfTest.swift)
for f in $S/Decoders/DAB/*.swift; do [[ "$f" == *DABModule* ]] || SRC+=("$f"); done
needs_build=0
[[ -x "$BIN" ]] || needs_build=1
for f in $SRC; do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
if (( needs_build )); then
    swiftc -O -swift-version 6 -Xcc -fmodule-map-file="$OUT/faad2/module.modulemap" -I "$OUT/faad2" -o "$BIN" $SRC "$OUT/faad2/libfaad2.a"
fi
exec "$BIN" "$@"
