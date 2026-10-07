#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den TETRA-Prüfstand.
#   Tools/TETRABench/tetra_bench.sh <aufnahme.wav|cu8|cs16> [--rate 2000000] [--center 426.7] [--carrier 426.7] [--frames ausgabe.ser] [--events]
#       decodiert eine I/Q-Aufnahme (ein Träger, Mitte = Träger, wenn --center fehlt) und schreibt auf Wunsch die Sprachrahmen im Format
#       der ETSI-Referenzwerkzeuge (je Rahmen ein Wort BFI und 137 Bits, 16 Bit je Wort) für `sdecoder`
#   Tools/TETRABench/tetra_bench.sh synth <ausgabe.wav> [--rate 48000] [--snr 20] [--offset 400] [--ppm 10] [--speech sprache.ser] [--frames 70]
#       schreibt einen Testsender als I/Q-WAV (16 Bit, stereo)
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${TETRA_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_tetrabench}"
mkdir -p "$OUT"
S=Sources/Decoders/TETRA
SRC=(Tools/TETRABench/main.swift $S/TETRACore.swift $S/TETRASpeech.swift $S/TETRAReceiver.swift $S/TETRAFramer.swift $S/TETRAMac.swift $S/TETRAEngine.swift $S/TETRASignalGenerator.swift)
if [[ ! -x "$OUT/tetra_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/tetra_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/tetra_bench" $SRC
fi
"$OUT/tetra_bench" "$@"
