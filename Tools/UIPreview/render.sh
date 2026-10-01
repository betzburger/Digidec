#!/bin/zsh
# Rendert Digidec-Karten offscreen als PNG (Layout-Prüfung ohne App-Start). Aufruf: Tools/UIPreview/render.sh <ordner>
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="${1:-$ROOT/.build/uipreview}"
mkdir -p "$OUT"
"$ROOT/Tools/build_fldigi.sh" "$OUT/fl" >/dev/null
SRC=(${(f)"$(find $ROOT/Sources -name '*.swift' ! -name DigidecApp.swift)"})
swiftc -O -swift-version 6 -I "$OUT/fl/module" -o "$OUT/uipreview" \
    $ROOT/Tools/UIPreview/main.swift $SRC "$OUT"/fl/obj/*.o -lc++ 2>&1 | grep -E "error" || true
"$OUT/uipreview" "$OUT"
