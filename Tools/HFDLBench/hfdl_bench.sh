#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den HFDL-Prüfstand und decodiert eine WAV-Aufnahme (USB-Audio, 12 kHz, mono).
# Aufruf:  Tools/HFDLBench/hfdl_bench.sh <aufnahme.wav> [--trace] [--noeq]
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${HFDL_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_hfdlbench}"
mkdir -p "$OUT"
S=Sources
swiftc -O -swift-version 6 -o "$OUT/hfdl_bench" Tools/HFDLBench/main.swift $S/Decoders/HFDL/HFDLCore.swift $S/Decoders/HFDL/HFDLProtocol.swift $S/Decoders/HFDL/HFDLStations.swift $S/Decoders/HFDL/HFDLSignalGenerator.swift \
    $S/Decoders/ACARS/ACARSCore.swift $S/Decoders/ACARS/ACARSPosition.swift $S/Models/Geo.swift
"$OUT/hfdl_bench" "$@"
