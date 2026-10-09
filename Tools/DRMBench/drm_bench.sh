#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den DRM-Prüfstand und decodiert eine Aufnahme (48 kHz WAV, I/Q oder reelles Audio).
# Aufruf:  Tools/DRMBench/drm_bench.sh <aufnahme.wav> [--dump aac.bin]
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${DRM_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_drmbench}"
mkdir -p "$OUT"
S=Sources/Decoders/DRM
SRC=(Tools/DRMBench/main.swift $S/DRMTables.swift $S/DRMCore.swift $S/DRMMLC.swift $S/DRMFFT.swift $S/DRMData.swift $S/DRMReceiver.swift)
if [[ ! -x "$OUT/drm_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/drm_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/drm_bench" $SRC
fi
"$OUT/drm_bench" "$@"
