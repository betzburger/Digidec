#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den DMR-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/DMRBench/dmr_bench.sh <aufnahme> [--slot 1|2] [--port /dev/cu.usbserial-0001] [--out ton.wav] [--play]
# Ohne --port werden nur Gespräche, IDs und Zähler ausgegeben; mit --port wandelt der Sprachstick die Rahmen des gewählten Zeitschlitzes in Ton.
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${DMR_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_dmrbench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/DMRBench/main.swift $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/FourFSK/AMBEHalfRate.swift $S/Decoders/DMR/DMRCodes.swift $S/Decoders/DMR/DMRCore.swift $S/Decoders/DMR/DMRFramer.swift Modules/VoiceCore/Sources/VoiceCore/*.swift)
if [[ ! -x "$OUT/dmr_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/dmr_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/dmr_bench" $SRC
fi
"$OUT/dmr_bench" "$@"
