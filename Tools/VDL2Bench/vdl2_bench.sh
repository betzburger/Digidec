#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den Prüfstand für VDL Mode 2 und führt ihn aus.
#   Tools/VDL2Bench/vdl2_bench.sh file <aufnahme.wav|.cu8> [--rate 1050000] [--center 136.975] [--channels 136.725,136.775] [--hex]
#       decodiert eine I/Q-Aufnahme (WAV 8/16 Bit stereo oder 8-Bit-I/Q); ohne --channels ein Kanal in der Mitte (wie dumpvdl2)
#   Tools/VDL2Bench/vdl2_bench.sh synth <aus.cu8|aus.wav> [--text TEXT] [--noise 0.05] [--cfo 300] [--rate 2000000] [--channel 136.925]
#       erzeugt ein Testsignal (ein Burst mit ACARS-Meldung) in einer 2-MS/s-Aufnahme um 136,850 MHz
#   Tools/VDL2Bench/vdl2_bench.sh selftest
#       Rundlauf mit Rauschen und Frequenzablage sowie Rechenzeit je Sekunde Signal bei sechs Kanälen
# Die echte Referenzaufnahme: Vendor/_upstream/vdl2/dumpvdl2/test/vdl2_model_16b_1050kHz.wav (1,05 MS/s, ein Kanal in der Mitte)
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${VDL2_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_vdl2bench}"
mkdir -p "$OUT"
S=Sources/Decoders/VDL2
SRC=(Tools/VDL2Bench/main.swift $S/VDL2Core.swift $S/VDL2Demod.swift $S/VDL2SignalGenerator.swift Sources/Decoders/ACARS/ACARSCore.swift)
if [[ ! -x "$OUT/vdl2_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/vdl2_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/vdl2_bench" $SRC
fi
"$OUT/vdl2_bench" "$@"
