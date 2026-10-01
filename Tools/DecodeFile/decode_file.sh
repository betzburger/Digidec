#!/bin/zsh
# Digidec offline: Aufnahme mit dem RTTY- oder CW-Kern decodieren und auswerten (PLAN.md, Abschnitt 8 / M6).
# Aufruf: Tools/DecodeFile/decode_file.sh <aufnahme.wav> [Optionen]   (Hilfe: --help)
# Baut das Werkzeug bei Bedarf nach .build/decode_file (Quellen wie in den Logiktests).
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.build/decode_file"
BIN="$OUT/decode_file"
S="$ROOT/Sources"
F="$ROOT/Vendor/Fldigi"
SRC=($ROOT/Tools/DecodeFile/main.swift $S/Models/RTTYSettings.swift $S/Audio/SampleRateConverter.swift \
     $S/Audio/AudioPipeline.swift $S/Audio/AudioBasics.swift \
     $S/Decoders/RTTY/FldigiRTTYCore.swift $S/Decoders/RTTY/RTTYDecoder.swift $S/Decoders/RTTY/RTTYController.swift \
     $S/Log/DecodeLogger.swift $S/Audio/InputRecorder.swift $S/App/RTTYSettingsStore.swift \
     $S/Rig/RigctlClient.swift $S/Audio/AudioInputDevice.swift $S/Audio/RadioCodecLocator.swift \
     $S/Decoders/RTTY/SynopDecoder.swift $S/Decoders/CW/FldigiCWCore.swift)
needs_build=0
[[ -x "$BIN" ]] || needs_build=1
for f in $SRC $F/src/**/*(.) $F/include/*(.) $F/compat/**/*(.); do [[ "$f" -nt "$BIN" ]] && needs_build=1; done
if (( needs_build )); then
    "$ROOT/Tools/build_fldigi.sh" "$OUT"
    swiftc -O -swift-version 6 -I "$OUT/module" -o "$BIN" $SRC "$OUT"/obj/*.o -lc++
fi
exec "$BIN" "$@"
