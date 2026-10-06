#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den D-Star-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/DStarBench/dstar_bench.sh <aufnahme> [--port /dev/cu.usbserial-0001] [--out ton.wav] [--play] [--profile dstar|dmr]
#          Tools/DStarBench/dstar_bench.sh synth <aus.wav> [--noise s] [--text "…"] [--port <Anschluss>]
# Ohne --port werden nur Köpfe, Langsamdaten und Zähler ausgegeben; mit --port wandelt der Sprachstick die Rahmen in Ton.
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${DSTAR_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_dstarbench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/DStarBench/main.swift $S/Decoders/DStar/DStarCore.swift $S/Decoders/DStar/DStarDemod.swift $S/Decoders/DStar/DStarSignalGenerator.swift Modules/VoiceCore/Sources/VoiceCore/*.swift)
if [[ ! -x "$OUT/dstar_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/dstar_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/dstar_bench" $SRC
fi
"$OUT/dstar_bench" "$@"
