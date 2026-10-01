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

# 2. fldigi-Teile (Vendor/Fldigi) wie im Package.swift übersetzen, Modul-Map für "import Fldigi"
Tools/build_fldigi.sh "$OUT/fldigi"

# 3. Testprogramm mit den getesteten Quellen bauen
swiftc -O -swift-version 6 -o "$OUT/logic_tests" \
    -I "$OUT/fldigi/module" \
    Tools/LogicTests/main.swift \
    $S/Models/DecoderModuleInfo.swift $S/Models/DecodeRequest.swift $S/Models/DXCC.swift \
    $S/Audio/AudioInputDevice.swift $S/Audio/RadioCodecLocator.swift $S/Audio/AudioBasics.swift $S/Audio/SampleRateConverter.swift \
    $S/Audio/AudioPipeline.swift $S/Audio/WAVFileSource.swift \
    $S/Models/RTTYSettings.swift $S/App/RTTYSettingsStore.swift \
    $S/DSP/SpectrumAnalyzer.swift $S/DSP/WaterfallProcessor.swift $S/DSP/WaterfallColorMap.swift \
    $S/Decoders/RTTY/FldigiRTTYCore.swift $S/Decoders/RTTY/RTTYSignalGenerator.swift \
    $S/Decoders/RTTY/RTTYDecoder.swift $S/Decoders/RTTY/RTTYController.swift $S/Log/DecodeLogger.swift \
    $S/Rig/RigctlClient.swift $S/Audio/InputRecorder.swift \
    $S/Decoders/RTTY/SynopDecoder.swift \
    $S/Decoders/NAVTEX/FldigiNavtexCore.swift $S/Decoders/NAVTEX/NavtexSettingsStore.swift \
    $S/Decoders/NAVTEX/NavtexDecoder.swift $S/Decoders/NAVTEX/NavtexController.swift $S/Models/TuningTarget.swift \
    $S/Decoders/CW/FldigiCWCore.swift $S/Decoders/CW/CWModule.swift \
    $S/Decoders/WEFAX/FldigiWefaxCore.swift $S/Decoders/WEFAX/WefaxModule.swift \
    $S/Decoders/FT8/FT8Core.swift $S/Decoders/FT8/FT8Module.swift \
    $S/Decoders/FT4/FT4Core.swift $S/Decoders/FT4/FT4Module.swift \
    $S/Decoders/DCF77/DCF77Core.swift $S/Decoders/DCF77/DCF77SignalGenerator.swift $S/Decoders/DCF77/DCF77Module.swift \
    $S/Decoders/EFR/EFRCore.swift $S/Decoders/EFR/EFRSignalGenerator.swift $S/Decoders/EFR/EFRModule.swift \
    "$OUT"/fldigi/obj/*.o -lc++

# 4. Ausführen
"$OUT/logic_tests"
