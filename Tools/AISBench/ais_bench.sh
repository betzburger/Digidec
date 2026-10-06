#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den AIS-Prüfstand und decodiert eine WAV-Aufnahme (FM-Diskriminator-Audio) oder erzeugt Testsignale.
# Aufruf:  Tools/AISBench/ais_bench.sh <aufnahme.wav> [--nmea]   |   fm <iq.wav> <audio.wav>   |   synth <präfix>   |   selftest [--noise s]
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${AIS_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_aisbench}"
mkdir -p "$OUT"
S=Sources
SRC=(Tools/AISBench/main.swift $S/Decoders/AIS/AISCore.swift $S/Decoders/AIS/AISMessage.swift $S/Decoders/AIS/AISBinary.swift $S/Decoders/AIS/AISBinaryMore.swift $S/Decoders/AIS/AISDemod.swift $S/Decoders/AIS/AISSignalGenerator.swift $S/Models/Geo.swift $S/Models/ShipInfoService.swift $S/Audio/SampleRateConverter.swift)
if [[ ! -x "$OUT/ais_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/ais_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/ais_bench" $SRC
fi
"$OUT/ais_bench" "$@"
