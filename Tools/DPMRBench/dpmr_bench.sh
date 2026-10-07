#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den dPMR-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/DPMRBench/dpmr_bench.sh <aufnahme> [--port /dev/cu.usbserial-0001] [--out ton.wav] [--play]
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${DPMR_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_dpmrbench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/DPMRBench/main.swift $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/FourFSK/AMBEHalfRate.swift $S/Decoders/DPMR/DPMRCore.swift $S/Decoders/DPMR/DPMRFramer.swift Modules/VoiceCore/Sources/VoiceCore/*.swift)
if [[ ! -x "$OUT/dpmr_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/dpmr_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/dpmr_bench" $SRC
fi
"$OUT/dpmr_bench" "$@"
