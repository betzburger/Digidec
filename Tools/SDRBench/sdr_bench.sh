#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Prüft den eingebauten SDR-Empfänger (FM, AM, SSB, CW, WFM) mit Testsignalen und misst Rechenzeit; mit einer Aufnahme (8-Bit-I/Q) schreibt es das Audio als WAV.
# Aufruf:  Tools/SDRBench/sdr_bench.sh selftest
#          Tools/SDRBench/sdr_bench.sh file <aufnahme.cu8> <aus.wav> --rate 2400000 --offset 300000 --mode fm|wfm|am|usb|lsb|cw [--bw 15000]
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.build/sdr_bench"
BIN="$OUT/sdr_bench"
S="$ROOT/Sources"
SRC=($ROOT/Tools/SDRBench/main.swift $S/SDR/SDRDSP.swift $S/SDR/SDRDemodulator.swift $S/SDR/SDRWFM.swift $S/SDR/SDRSignalGenerator.swift $S/SDR/SDRReceiver.swift $S/Audio/SampleRateConverter.swift)
needs_build=0
[[ -x "$BIN" ]] || needs_build=1
for f in $SRC; do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
if (( needs_build )); then
    mkdir -p "$OUT"
    swiftc -O -swift-version 6 -o "$BIN" $SRC
fi
exec "$BIN" "$@"
