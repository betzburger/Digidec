#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Lädt ausgewählte Aufnahmen (I/Q, 8 Bit, mit der erwarteten Ausgabe als JSON) aus dem Prüfdaten-Repository von rtl_433
# (https://github.com/merbanan/rtl_433_tests) nach TestData/Sensors. Die Logiktests lesen sie von dort; ohne sie werden die Prüfungen übersprungen.
# Aufruf:  Tools/Sensors433Bench/fetch_testdata.sh
set -euo pipefail
ROOT="${0:A:h:h:h}"
DEST="$ROOT/TestData/Sensors"
mkdir -p "$DEST"
LIST="$(mktemp)"
gh api "repos/merbanan/rtl_433_tests/git/trees/HEAD?recursive=1" --jq '.tree[] | select(.type=="blob") | "\(.size) \(.path)"' > "$LIST"
# je Verzeichnis höchstens 8 Aufnahmen bis 1,3 MB, dazu die JSON-Dateien und die Bitfolgen-Tests (codes_test)
PATTERNS=(nexus prologue fineoffset/fineoffset_wh2/ fineoffset/fineoffset_wh24/ fineoffset/fineoffset_wh65b/ fineoffset/fineoffset_wh1080/ fineoffset/fineoffset_wh25/ fineoffset/fineoffset_wh31 \
          bresser_5in1 bresser_6in1 bresser_7in1 hideki lacrosse/tx141 lacrosse/tx29 oregon_scientific eurochron-th acurite/Acurite_592TXR acurite/Acurite_609 acurite/Acurite_606 ecowitt infactory TFA tfa)
for p in $PATTERNS; do
    grep -E " tests/$p" "$LIST" | while read -r size rel; do
        case "$rel" in *.cu8|*.json|*codes_test.txt) ;; *) continue;; esac
        (( size > 1400000 )) && continue
        out="$DEST/${rel#tests/}"
        [[ -f "$out" ]] && continue
        mkdir -p "${out:h}"
        curl -sfL "https://raw.githubusercontent.com/merbanan/rtl_433_tests/master/$rel" -o "$out" || echo "FEHLER: $rel"
    done
done
rm -f "$LIST"
echo "Fertig: $(find "$DEST" -name '*.cu8' | wc -l | tr -d ' ') Aufnahmen in $DEST"
