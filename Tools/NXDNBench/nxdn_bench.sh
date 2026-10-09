#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den NXDN-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/NXDNBench/nxdn_bench.sh <aufnahme> [--port /dev/cu.usbserial-0001] [--out ton.wav] [--play]
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${NXDN_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_nxdnbench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/NXDNBench/main.swift $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/FourFSK/AMBEHalfRate.swift $S/Decoders/NXDN/NXDNCore.swift $S/Decoders/NXDN/NXDNFramer.swift Modules/VoiceCore/Sources/VoiceCore/*.swift)
if [[ ! -x "$OUT/nxdn_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/nxdn_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/nxdn_bench" $SRC
fi
"$OUT/nxdn_bench" "$@"
