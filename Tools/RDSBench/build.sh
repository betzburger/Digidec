#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den RDS-Prüfstand (Aufnahme → WFM → RDS) und startet ihn mit den Argumenten.
set -euo pipefail
ROOT="${0:A:h:h:h}"
S="$ROOT/Sources"
OUT="$ROOT/.build/rds_bench"
SRC=($ROOT/Tools/RDSBench/main.swift $S/SDR/SDRDSP.swift $S/SDR/SDRDemodulator.swift $S/SDR/SDRWFM.swift $S/SDR/SDRSignalGenerator.swift $S/Decoders/RDS/RDSCore.swift $S/Decoders/RDS/RDSDemodulator.swift $S/Decoders/RDS/RDSDecoder.swift $S/Decoders/RDS/RDSSignalGenerator.swift $S/Audio/SampleRateConverter.swift)
mkdir -p "$OUT"
needs=0
[[ -x "$OUT/rds_bench" ]] || needs=1
for f in $SRC; do [[ "$f" -nt "$OUT/rds_bench" ]] && needs=1; done
(( needs )) && swiftc -O -swift-version 6 -o "$OUT/rds_bench" $SRC
exec "$OUT/rds_bench" "$@"
