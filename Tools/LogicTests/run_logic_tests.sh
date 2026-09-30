#!/bin/zsh
# Baut und startet die Logiktests (reine Rechenlogik, ohne Audio, ohne App-Start).
# Aufruf aus beliebigem Verzeichnis:  Tools/LogicTests/run_logic_tests.sh [Ausgabeverzeichnis]
# Ohne Argument landet der Build in einem temporären Verzeichnis, das danach gelöscht wird.
# Exit-Code 0 = alle Prüfungen bestanden, sonst Fehler (Build oder Test).
set -euo pipefail

ROOT="${0:A:h:h:h}"
cd "$ROOT"

if [[ $# -ge 1 ]]; then
    OUT="$1"
    mkdir -p "$OUT"
else
    OUT="$(mktemp -d -t digidec_logictests)"
    trap 'rm -rf "$OUT"' EXIT
fi

S=Sources

# 1. Versionsnummer muss in AppVersion.swift und build_app.sh übereinstimmen (PLAN.md, Abschnitt 13)
APP_VERSION="$(sed -n 's/.*static let short = "\(.*\)".*/\1/p' $S/App/AppVersion.swift)"
for key in CFBundleShortVersionString CFBundleVersion; do
    PLIST_VERSION="$(grep -A1 "<key>$key</key>" build_app.sh | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')"
    if [[ "$APP_VERSION" != "$PLIST_VERSION" ]]; then
        echo "FAIL: Version AppVersion.swift ($APP_VERSION) != build_app.sh $key ($PLIST_VERSION)"
        exit 1
    fi
done

# 2. fldigi-RTTY-Kern (C++) wie im Package.swift übersetzen, Modul-Map für "import FldigiRTTY"
V=Vendor/FldigiRTTY
mkdir -p "$OUT/fldigi/obj" "$OUT/fldigi/module"
for c in $V/src/*.cpp; do
    clang++ -std=c++17 -O2 -I$V/include -I$V/src -c "$c" -o "$OUT/fldigi/obj/${c:t:r}.o"
done
cat > "$OUT/fldigi/module/module.modulemap" <<MAP
module FldigiRTTY {
    header "$ROOT/$V/include/fldigi_rtty.h"
    export *
}
MAP

# 2b. SYNOP-Decoder aus fldigi (C++ und GNU-Regex in C)
Y=Vendor/FldigiSynop
mkdir -p "$OUT/synop/obj" "$OUT/synop/module"
cc -O2 -w -I$Y/src -c $Y/src/compat/regex.c -o "$OUT/synop/obj/regex.o"
for c in $Y/src/*.cpp; do
    clang++ -std=c++17 -O2 -I$Y/include -I$Y/src -I$Y/compat -c "$c" -o "$OUT/synop/obj/${c:t:r}.o"
done
cat > "$OUT/synop/module/module.modulemap" <<MAP
module FldigiSynop {
    header "$ROOT/$Y/include/fldigi_synop.h"
    export *
}
MAP

# 3. Testprogramm mit den getesteten Quellen bauen
swiftc -O -swift-version 6 -o "$OUT/logic_tests" \
    -I "$OUT/fldigi/module" -I "$OUT/synop/module" \
    Tools/LogicTests/main.swift \
    $S/Models/DecoderModuleInfo.swift $S/Models/DecodeRequest.swift \
    $S/Audio/AudioInputDevice.swift $S/Audio/RadioCodecLocator.swift $S/Audio/AudioBasics.swift $S/Audio/SampleRateConverter.swift \
    $S/Audio/AudioPipeline.swift $S/Audio/WAVFileSource.swift \
    $S/Models/RTTYSettings.swift $S/App/RTTYSettingsStore.swift \
    $S/DSP/SpectrumAnalyzer.swift $S/DSP/WaterfallProcessor.swift $S/DSP/WaterfallColorMap.swift \
    $S/Decoders/RTTY/FldigiRTTYCore.swift $S/Decoders/RTTY/RTTYSignalGenerator.swift \
    $S/Decoders/RTTY/RTTYDecoder.swift $S/Decoders/RTTY/RTTYController.swift $S/Log/DecodeLogger.swift \
    $S/Rig/RigctlClient.swift $S/Audio/InputRecorder.swift \
    $S/Decoders/RTTY/SynopDecoder.swift \
    "$OUT"/fldigi/obj/*.o "$OUT"/synop/obj/*.o -lc++

# 4. Ausführen
"$OUT/logic_tests"
