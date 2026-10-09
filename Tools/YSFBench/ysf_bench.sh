#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den YSF-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/YSFBench/ysf_bench.sh <aufnahme> [--port /dev/cu.usbserial-0001] [--out ton.wav] [--play]
# Ohne --port werden nur Rufzeichen und Zähler ausgegeben; mit --port wandelt der Sprachstick die Rahmen in Ton.
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${YSF_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_ysfbench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/YSFBench/main.swift $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/FourFSK/AMBEHalfRate.swift $S/Decoders/YSF/YSFCore.swift $S/Decoders/YSF/YSFDemod.swift Modules/VoiceCore/Sources/VoiceCore/*.swift)
if [[ ! -x "$OUT/ysf_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/ysf_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/ysf_bench" $SRC
fi
"$OUT/ysf_bench" "$@"
