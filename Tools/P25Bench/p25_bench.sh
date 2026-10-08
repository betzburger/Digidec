#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den P25-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/P25Bench/p25_bench.sh <aufnahme> [--port /dev/cu.usbserial-0001] [--out ton.wav] [--play]
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${P25_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_p25bench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/P25Bench/main.swift $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/FourFSK/AMBEHalfRate.swift $S/Decoders/P25/P25Core.swift $S/Decoders/P25/P25Framer.swift Modules/VoiceCore/Sources/VoiceCore/*.swift)
if [[ ! -x "$OUT/p25_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/p25_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/p25_bench" $SRC
fi
"$OUT/p25_bench" "$@"
