#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# FT8-Qualitätsnachweis: Digidec (ft8mon) gegen die WSJT-X-Decodes der ft8_lib-Testaufnahmen.
# Voraussetzung: Vendor/_upstream/ft8_lib (git clone https://github.com/kgoba/ft8_lib), siehe Vendor/FT8/UPSTREAM_FT8.md.
# Aufruf: Tools/FT8Reference/run_reference.sh [Rechenzeit in s, Standard 3]
set -euo pipefail
ROOT="${0:A:h:h:h}"
W="$ROOT/Vendor/_upstream/ft8_lib/test/wav"
B="${1:-3}"
[[ -d "$W" ]] || { echo "Testaufnahmen fehlen: $W"; exit 1; }
total=0; hit=0; extra=0; unsure=0
for wav in $W/*.wav; do
    txt="${wav:r}.txt"
    [[ -f "$txt" ]] || continue
    line=$("$ROOT/Tools/DecodeFile/decode_file.sh" "$wav" --ft8 --budget "$B" --wsjtx "$txt" | grep '^FT8VERGLEICH')
    set -- ${=line}
    total=$((total + $2)); hit=$((hit + $3)); extra=$((extra + $4)); unsure=$((unsure + $5))
    printf "%-28s %3d / %3d\n" "${wav:t}" $3 $2
done
printf "Gesamt: %d von %d WSJT-X-Decodes (%.1f %%), zusätzlich %d (davon %d als unsicher markiert)\n" \
    $hit $total $((100.0 * hit / total)) $extra $unsure
