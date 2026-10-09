#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Misst den Skimmer (CW, BPSK31/63) an synthetischen Mischungen und Aufnahmen. Baut bei Bedarf nach .build/skim_bench.
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.build/skim_bench"
BIN="$OUT/skim_bench"
S="$ROOT/Sources"
SRC=($ROOT/Tools/SkimBench/main.swift $S/Decoders/Skimmer/SkimmerTables.swift $S/Decoders/Skimmer/SkimmerSpectrum.swift $S/Decoders/Skimmer/SkimmerChannels.swift
     $S/Decoders/Skimmer/SkimmerEngine.swift $S/Decoders/Skimmer/SkimmerSignals.swift $S/Audio/SampleRateConverter.swift)
needs_build=0
[[ -x "$BIN" ]] || needs_build=1
for f in $SRC; do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
if (( needs_build )); then
    mkdir -p "$OUT"
    swiftc -O -swift-version 6 -o "$BIN" $SRC
fi
exec "$BIN" "$@"
