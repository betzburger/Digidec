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

# 2. Testprogramm mit den getesteten Quellen bauen
swiftc -O -swift-version 6 -o "$OUT/logic_tests" \
    Tools/LogicTests/main.swift \
    $S/Models/DecoderModuleInfo.swift $S/Models/DecodeRequest.swift \
    $S/Audio/AudioInputDevice.swift $S/Audio/RadioCodecLocator.swift $S/Audio/AudioBasics.swift $S/Audio/SampleRateConverter.swift \
    $S/Audio/AudioPipeline.swift $S/Audio/WAVFileSource.swift

# 3. Ausführen
"$OUT/logic_tests"
