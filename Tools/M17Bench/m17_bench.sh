#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den M17-Prüfstand und decodiert eine Aufnahme (FM-Diskriminator-Audio: .dis = rohes 16 Bit, 48 kHz, mono, oder WAV).
# Aufruf:  Tools/M17Bench/m17_bench.sh <aufnahme> [--out sprache.wav]
# Gespräche, LSF (Absender, Ziel, CAN, Text, Position) und Zähler werden ausgegeben; mit --out wird die Sprache (Codec2) als WAV geschrieben.
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${M17_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_m17bench}"
mkdir -p "$OUT"
S=Sources
[[ -d "$OUT/fldigi/module" ]] || Tools/build_fldigi.sh "$OUT/fldigi"
SRC=(Tools/M17Bench/main.swift $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/M17/M17Core.swift $S/Decoders/M17/M17Framer.swift $S/Decoders/M17/M17Voice.swift Modules/VoiceCore/Sources/VoiceCore/VoiceDecoder.swift Modules/VoiceCore/Sources/VoiceCore/VoiceAudio.swift)
if [[ ! -x "$OUT/m17_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/m17_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/m17_bench" -I "$OUT/fldigi/module" -Xcc -I"$ROOT/Vendor/Codec2/include" $SRC "$OUT"/fldigi/obj/*.o -lc++
fi
"$OUT/m17_bench" "$@"
