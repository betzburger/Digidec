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
swiftc ${=LT_FLAGS:--O} -swift-version 6 -o "$OUT/logic_tests" \
    -I "$OUT/fldigi/module" \
    Tools/LogicTests/main.swift \
    $S/Models/DecoderModuleInfo.swift $S/Models/DecodeRequest.swift $S/Models/DXCC.swift \
    $S/Audio/AudioInputDevice.swift $S/Audio/RadioCodecLocator.swift $S/Audio/AudioBasics.swift $S/Audio/SampleRateConverter.swift \
    $S/Audio/AudioPipeline.swift $S/Audio/WAVFileSource.swift \
    $S/Models/RTTYSettings.swift $S/App/RTTYSettingsStore.swift \
    $S/DSP/SpectrumAnalyzer.swift $S/DSP/WaterfallProcessor.swift $S/DSP/WaterfallColorMap.swift \
    $S/Decoders/RTTY/FldigiRTTYCore.swift $S/Decoders/RTTY/RTTYSignalGenerator.swift \
    $S/Decoders/RTTY/RTTYDecoder.swift $S/Decoders/RTTY/RTTYController.swift $S/Log/DecodeLogger.swift \
    $S/Rig/RigctlClient.swift $S/Rig/RigTuning.swift $S/Audio/InputRecorder.swift \
    $S/Decoders/RTTY/SynopDecoder.swift \
    $S/Decoders/NAVTEX/FldigiNavtexCore.swift $S/Decoders/NAVTEX/NavtexSettingsStore.swift \
    $S/Decoders/NAVTEX/NavtexDecoder.swift $S/Decoders/NAVTEX/NavtexController.swift $S/Models/TuningTarget.swift \
    $S/Decoders/CW/FldigiCWCore.swift $S/Decoders/CW/CWModule.swift \
    $S/Models/TextModeController.swift $S/Decoders/PSK/FldigiPSKCore.swift $S/Decoders/PSK/PSKModule.swift \
    $S/Decoders/ALE/ALECore.swift $S/Decoders/ALE/ALEModule.swift \
    $S/Decoders/ACARS/ACARSCore.swift $S/Decoders/ACARS/ACARSPosition.swift $S/Decoders/ACARS/ACARSModule.swift \
    $S/Decoders/Sonde/RS41Core.swift $S/Decoders/Sonde/RS41Demod.swift $S/Decoders/Sonde/RS41Signal.swift $S/Decoders/Sonde/SondeModule.swift \
    $S/Decoders/Skimmer/SkimmerTables.swift $S/Decoders/Skimmer/SkimmerSpectrum.swift $S/Decoders/Skimmer/SkimmerChannels.swift $S/Decoders/Skimmer/SkimmerEngine.swift $S/Decoders/Skimmer/SkimmerSignals.swift $S/Decoders/Skimmer/SkimmerModule.swift \
    $S/Decoders/Pager/POCSAGCore.swift $S/Decoders/Pager/PagerChannelModel.swift $S/Decoders/Pager/FLEXCore.swift $S/Decoders/Pager/ToneCore.swift $S/Decoders/Pager/PagerModule.swift $S/Decoders/Pager/TonesModule.swift \
    $S/Decoders/APRS/APRSPacket.swift $S/Decoders/APRS/AFSKModem.swift $S/Decoders/APRS/APRSModule.swift $S/Models/Geo.swift $S/Models/ModuleMaps.swift $S/Models/SeaWeather.swift \
    $S/Decoders/DSC/DSCCore.swift $S/Decoders/DSC/DSCVHF.swift $S/Decoders/DSC/DSCModule.swift \
    $S/Decoders/Olivia/FldigiOliviaCore.swift $S/Decoders/Olivia/OliviaModule.swift \
    $S/Decoders/MFSK/FldigiMFSKCore.swift $S/Decoders/MFSK/MFSKModule.swift \
    $S/Decoders/Hell/FldigiHellCore.swift $S/Decoders/Hell/HellModule.swift \
    $S/Decoders/MT63/FldigiMT63Core.swift $S/Decoders/MT63/MT63Module.swift \
    $S/Decoders/WEFAX/FldigiWefaxCore.swift $S/Decoders/WEFAX/WefaxModule.swift $S/Decoders/WEFAX/WefaxSchedule.swift $S/Decoders/WEFAX/WefaxImageTools.swift $S/Decoders/WEFAX/WefaxScheduleStore.swift \
    $S/Models/BroadcastSchedule.swift $S/Models/DWDPlanFetcher.swift $S/Decoders/RTTY/RttySchedule.swift $S/Decoders/RTTY/RttyScheduleStore.swift \
    $S/Decoders/NAVTEX/NavtexPlan.swift $S/Decoders/NAVTEX/NavtexPlanStore.swift \
    $S/Decoders/Sonde/SondePlan.swift $S/Decoders/Sonde/SondePlanStore.swift $S/Decoders/Sonde/SondeScanEngine.swift $S/Decoders/Sonde/SondeScanner.swift \
    $S/Decoders/FT8/FT8Core.swift $S/Decoders/FT8/FT8Module.swift \
    $S/Decoders/FT4/FT4Core.swift $S/Decoders/FT4/FT4Module.swift \
    $S/Decoders/WSPR/WSPRCore.swift $S/Decoders/WSPR/WSPRModule.swift \
    $S/Decoders/DCF77/DCF77Core.swift $S/Decoders/DCF77/DCF77SignalGenerator.swift $S/Decoders/DCF77/DCF77Module.swift \
    $S/Decoders/EFR/EFRCore.swift $S/Decoders/EFR/EFRSignalGenerator.swift $S/Decoders/EFR/EFRModule.swift \
    $S/Decoders/SSTV/SSTVMode.swift $S/Decoders/SSTV/SSTVCore.swift $S/Decoders/SSTV/SSTVSignalGenerator.swift $S/Decoders/SSTV/SSTVModule.swift \
    "$OUT"/fldigi/obj/*.o -lc++

# 4. Ausführen
"$OUT/logic_tests"
