#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Erzeugt Testsignale als WAV-Datei (für Schnappschüsse der Oberfläche und Gegenproben ohne Funkgerät).
# Aufruf: Tools/MakeSignal/make_signal.sh <art> <skript.txt> <ausgabe.wav> [Optionen]   (Hilfe: --help)
# Baut das Werkzeug bei Bedarf nach .build/make_signal (nur die Generatoren, ohne Oberfläche und fldigi).
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.build/make_signal"
BIN="$OUT/make_signal"
S="$ROOT/Sources"
SRC=($ROOT/Tools/MakeSignal/main.swift $S/Decoders/ACARS/ACARSCore.swift $S/Decoders/Pager/POCSAGCore.swift $S/Decoders/Pager/POCSAGEqualizer.swift $S/Decoders/Pager/FLEXCore.swift $S/Decoders/Sonde/RS41Core.swift $S/Decoders/Sonde/RS41Signal.swift)
needs_build=0
[[ -x "$BIN" ]] || needs_build=1
for f in $SRC; do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
if (( needs_build )); then
    mkdir -p "$OUT"
    swiftc -O -swift-version 6 -o "$BIN" $SRC
fi
exec "$BIN" "$@"
