#!/bin/zsh
# Misst den POCSAG-Empfang unter nachgebildeten Funkbedingungen (siehe main.swift). Baut das Werkzeug bei Bedarf nach .build/pager_bench.
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.build/pager_bench"
BIN="$OUT/pager_bench"
S="$ROOT/Sources"
SRC=($ROOT/Tools/PagerBench/main.swift $S/Decoders/Pager/POCSAGCore.swift $S/Decoders/Pager/PagerChannelModel.swift $S/Audio/SampleRateConverter.swift)
needs_build=0
[[ -x "$BIN" ]] || needs_build=1
for f in $SRC; do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
if (( needs_build )); then
    mkdir -p "$OUT"
    swiftc -O -swift-version 6 -o "$BIN" $SRC
fi
exec "$BIN" "$@"
