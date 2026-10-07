#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut und startet die Logiktests (reine Rechenlogik, ohne Audio, ohne App-Start).
# Aufruf aus beliebigem Verzeichnis:
#   Tools/LogicTests/run_logic_tests.sh [Ausgabeverzeichnis]          alle Prüfungen (Standard)
#   Tools/LogicTests/run_logic_tests.sh --only dab,sdr                nur diese Gruppen (Liste: --groups)
#   Tools/LogicTests/run_logic_tests.sh --parallel [N]                alle Gruppen in N Prozessen zugleich (Standard: Kerne); Fehler werden einzeln nachgeprüft
# Der Build liegt standardmäßig in .build/logic_tests und wird zwischen den Läufen wiederverwendet (inkrementell: nur geänderte Dateien werden neu übersetzt).
# Umgebung: LT_FLAGS überschreibt die Compiler-Optionen (nie -Onone: dann dauern die Prüfungen Stunden statt Minuten).
# Exit-Code 0 = alle Prüfungen bestanden, sonst Fehler (Build oder Test).
set -euo pipefail

ROOT="${0:A:h:h:h}"
cd "$ROOT"

ONLY=""; PARALLEL=0; LIST=0; OUT=""
while (( $# )); do
    case "$1" in
        --only) ONLY="$2"; shift 2 ;;
        --groups) LIST=1; shift ;;
        --parallel) if [[ "${2:-}" == <-> ]]; then PARALLEL="$2"; shift 2; else PARALLEL=$(sysctl -n hw.ncpu); shift; fi ;;
        -h|--help) sed -n 4,12p "$0"; exit 0 ;;
        *) OUT="$1"; shift ;;
    esac
done

# Gruppen der Prüfungen: jeder Block in main.swift beginnt mit if want("gruppe")
GROUPS_LIST=("${(@f)$(grep -o '^if want("[a-z0-9]*")' Tools/LogicTests/main.swift | sed 's/if want("\(.*\)")/\1/' | sort -u)}")
if (( LIST )); then print -l -- $GROUPS_LIST; exit 0; fi

[[ -n "$OUT" ]] || OUT="$ROOT/.build/logic_tests"
mkdir -p "$OUT"
NCPU=$(sysctl -n hw.ncpu)

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
SRC=(
    Tools/LogicTests/main.swift Tools/LogicTests/FakeRigctld.swift Tools/LogicTests/FakeSDRconnect.swift $S/Rig/SDRconnectRig.swift
    $S/Models/RigProfile.swift $S/Rig/RigModel.swift $S/Models/LicenseDocuments.swift
    $S/Models/DecoderModuleInfo.swift $S/Models/DecodeRequest.swift $S/Models/DXCC.swift
    $S/Audio/AudioInputDevice.swift $S/Audio/RadioCodecLocator.swift $S/Audio/AudioBasics.swift $S/Audio/SampleRateConverter.swift
    $S/Audio/AudioPipeline.swift $S/Audio/WAVFileSource.swift
    $S/Models/RTTYSettings.swift $S/App/RTTYSettingsStore.swift
    $S/DSP/SpectrumAnalyzer.swift $S/DSP/WaterfallProcessor.swift $S/DSP/WaterfallColorMap.swift
    $S/Decoders/RTTY/FldigiRTTYCore.swift $S/Decoders/RTTY/RTTYSignalGenerator.swift
    $S/Decoders/RTTY/RTTYDecoder.swift $S/Decoders/RTTY/RTTYController.swift $S/Log/DecodeLogger.swift
    $S/Rig/RigctlClient.swift $S/Rig/RigTuning.swift $S/Audio/InputRecorder.swift
    $S/Decoders/RTTY/SynopDecoder.swift
    $S/Decoders/NAVTEX/FldigiNavtexCore.swift $S/Decoders/NAVTEX/NavtexSettingsStore.swift
    $S/Decoders/NAVTEX/NavtexDecoder.swift $S/Decoders/NAVTEX/NavtexController.swift $S/Models/TuningTarget.swift
    $S/Decoders/CW/FldigiCWCore.swift $S/Decoders/CW/CWModule.swift
    $S/Models/TextModeController.swift $S/Decoders/PSK/FldigiPSKCore.swift $S/Decoders/PSK/PSKModule.swift
    $S/Decoders/ALE/ALECore.swift $S/Decoders/ALE/ALEModule.swift
    $S/Decoders/ACARS/ACARSCore.swift $S/Decoders/ACARS/ACARSPosition.swift $S/Decoders/ACARS/ACARSModule.swift
    $S/Decoders/AIS/AISCore.swift $S/Decoders/AIS/AISMessage.swift $S/Decoders/AIS/AISBinary.swift $S/Decoders/AIS/AISBinaryMore.swift $S/Decoders/AIS/AISDemod.swift $S/Decoders/AIS/AISSignalGenerator.swift $S/Decoders/AIS/AISModule.swift $S/Models/ShipInfoService.swift
    $S/Decoders/HFDL/HFDLCore.swift $S/Decoders/HFDL/HFDLProtocol.swift $S/Decoders/HFDL/HFDLStations.swift $S/Decoders/HFDL/HFDLSignalGenerator.swift $S/Decoders/HFDL/HFDLModule.swift
    $S/Decoders/Sonde/RS41Core.swift $S/Decoders/Sonde/RS41Demod.swift $S/Decoders/Sonde/RS41Signal.swift $S/Decoders/Sonde/SondeModule.swift
    $S/Decoders/Skimmer/SkimmerTables.swift $S/Decoders/Skimmer/SkimmerSpectrum.swift $S/Decoders/Skimmer/SkimmerChannels.swift $S/Decoders/Skimmer/SkimmerEngine.swift $S/Decoders/Skimmer/SkimmerSignals.swift $S/Decoders/Skimmer/SkimmerModule.swift
    $S/Decoders/Pager/POCSAGCore.swift $S/Decoders/Pager/POCSAGEqualizer.swift $S/Decoders/Pager/PagerChannelModel.swift $S/Decoders/Pager/FLEXCore.swift $S/Decoders/Pager/ToneCore.swift $S/Decoders/Pager/PagerModule.swift $S/Decoders/Pager/TonesModule.swift
    $S/Decoders/APRS/APRSPacket.swift $S/Decoders/APRS/AFSKModem.swift $S/Decoders/APRS/APRSModule.swift $S/Decoders/Packet/PacketFrame.swift $S/Decoders/Packet/LZHUF.swift $S/Decoders/Packet/PacketMail.swift $S/Decoders/Packet/PacketAnalyzer.swift $S/Decoders/Packet/PacketModule.swift $S/Decoders/Packet/PacketSignalGenerator.swift $S/Decoders/ADSB/ModeSDemod.swift $S/Decoders/ADSB/ModeSMessage.swift $S/Decoders/ADSB/ADSBTables.swift $S/Decoders/ADSB/ADSBTracker.swift $S/Decoders/ADSB/ADSBSources.swift $S/Decoders/ADSB/SDRconnectSource.swift $S/Decoders/ADSB/SDRplayAPISource.swift $S/Decoders/ADSB/ADSBModule.swift $S/Decoders/ADSB/ADSBSignalGenerator.swift $S/Models/AircraftInfoService.swift $S/Models/Geo.swift $S/Models/ServiceLinks.swift $S/Models/ModuleMaps.swift $S/Models/SeaWeather.swift
    $S/Models/WeatherField.swift $S/Models/SynopAnalysis.swift $S/Models/SynopExport.swift $S/Models/ReceiveTextFilter.swift $S/Models/SynopRawLocator.swift
    $S/Decoders/DSC/DSCCore.swift $S/Decoders/DSC/DSCVHF.swift $S/Decoders/DSC/DSCModule.swift
    $S/Decoders/Olivia/FldigiOliviaCore.swift $S/Decoders/Olivia/OliviaModule.swift
    $S/Decoders/MFSK/FldigiMFSKCore.swift $S/Decoders/MFSK/MFSKModule.swift
    $S/Decoders/Hell/FldigiHellCore.swift $S/Decoders/Hell/HellModule.swift
    $S/Decoders/MT63/FldigiMT63Core.swift $S/Decoders/MT63/MT63Module.swift
    $S/Decoders/WEFAX/FldigiWefaxCore.swift $S/Decoders/WEFAX/WefaxModule.swift $S/Decoders/WEFAX/WefaxSchedule.swift $S/Decoders/WEFAX/WefaxImageTools.swift $S/Decoders/WEFAX/WefaxScheduleStore.swift
    $S/Models/BroadcastSchedule.swift $S/Models/DWDPlanFetcher.swift $S/Decoders/RTTY/RttySchedule.swift $S/Decoders/RTTY/RttyScheduleStore.swift
    $S/Decoders/NAVTEX/NavtexPlan.swift $S/Decoders/NAVTEX/NavtexPlanStore.swift
    $S/Decoders/Sonde/SondePlan.swift $S/Decoders/Sonde/SondePlanStore.swift $S/Decoders/Sonde/SondeScanEngine.swift $S/Decoders/Sonde/SondeScanner.swift
    $S/Decoders/FT8/FT8Core.swift $S/Decoders/FT8/FT8Module.swift
    $S/Decoders/FT4/FT4Core.swift $S/Decoders/FT4/FT4Module.swift
    $S/Decoders/WSPR/WSPRCore.swift $S/Decoders/WSPR/WSPRModule.swift
    $S/Decoders/DCF77/DCF77Core.swift $S/Decoders/DCF77/DCF77SignalGenerator.swift $S/Decoders/DCF77/DCF77Module.swift
    $S/Decoders/EFR/EFRCore.swift $S/Decoders/EFR/EFRSignalGenerator.swift $S/Decoders/EFR/EFRModule.swift
    $S/Decoders/SSTV/SSTVMode.swift $S/Decoders/SSTV/SSTVCore.swift $S/Decoders/SSTV/SSTVSignalGenerator.swift $S/Decoders/SSTV/SSTVModule.swift
    $S/Decoders/FourFSK/FourFSKSlicer.swift $S/Decoders/FourFSK/VoiceFEC.swift $S/Decoders/FourFSK/AMBEHalfRate.swift $S/Decoders/FourFSK/FourFSKModulator.swift $S/Decoders/YSF/YSFCore.swift $S/Decoders/YSF/YSFDemod.swift $S/Decoders/YSF/YSFSignalGenerator.swift $S/Decoders/DMR/DMRCodes.swift $S/Decoders/DMR/DMRCore.swift $S/Decoders/DMR/DMRFramer.swift $S/Decoders/DMR/DMRSignalGenerator.swift $S/Models/DMRIDDatabase.swift $S/Decoders/Sensors433/SensorPulses.swift $S/Decoders/Sensors433/SensorSlicers.swift $S/Decoders/Sensors433/SensorDevice.swift $S/Decoders/Sensors433/SensorEngine.swift $S/Decoders/Sensors433/SensorCatalog.swift $S/Decoders/Sensors433/SensorAnalyzer.swift $S/Decoders/Sensors433/SensorSignalGenerator.swift $S/Decoders/Sensors433/SensorsModule.swift $S/Decoders/Sensors433/SensorDevicesPPM.swift $S/Decoders/Sensors433/SensorDevicesFineOffset.swift $S/Decoders/Sensors433/SensorDevicesBresser.swift $S/Decoders/Sensors433/SensorDevicesMisc.swift $S/Decoders/Sensors433/SensorDevicesOregon.swift $S/Decoders/Sensors433/SensorDevicesWH1080.swift $S/Decoders/Sensors433/SensorDevicesAcurite.swift $S/Decoders/Sensors433/SensorDevicesTFA.swift $S/Decoders/Sensors433/SensorDevicesEcowitt.swift $S/Decoders/Sensors433/SensorDevicesLaCrosseIT.swift $S/Decoders/Sensors433/SensorDevicesMore.swift $S/Models/VoicePositions.swift $S/Decoders/DPMR/DPMRCore.swift $S/Decoders/DPMR/DPMRFramer.swift $S/Decoders/DPMR/DPMRSignalGenerator.swift $S/Decoders/TETRA/TETRACore.swift $S/Decoders/TETRA/TETRASpeech.swift $S/Decoders/TETRA/TETRAReceiver.swift $S/Decoders/TETRA/TETRAFramer.swift $S/Decoders/TETRA/TETRAMac.swift $S/Decoders/TETRA/TETRAEngine.swift $S/Decoders/TETRA/TETRASignalGenerator.swift $S/Decoders/VOR/VORCore.swift $S/Decoders/VOR/VORModule.swift $S/Decoders/NDB/NDBCore.swift $S/Decoders/NDB/NDBData.swift $S/Decoders/NDB/NDBBuiltinData.swift $S/Decoders/NDB/NDBModule.swift $S/Decoders/VDL2/VDL2Core.swift $S/Decoders/VDL2/VDL2Demod.swift $S/Decoders/VDL2/VDL2SignalGenerator.swift $S/Decoders/VDL2/VDL2Module.swift $S/Decoders/M17/M17Core.swift $S/Decoders/M17/M17Framer.swift $S/Decoders/M17/M17Packet.swift $S/Decoders/M17/M17BERT.swift $S/Decoders/M17/M17Signature.swift $S/Decoders/M17/M17SignalGenerator.swift $S/Decoders/M17/M17Voice.swift $S/Decoders/FreeDV/FreeDVModem.swift
    $S/Decoders/DStar/DStarCore.swift $S/Decoders/DStar/DStarDemod.swift $S/Decoders/DStar/DStarSignalGenerator.swift
    $S/Decoders/DAB/DABTables.swift $S/Decoders/DAB/DABViterbi.swift $S/Decoders/DAB/DABOFDM.swift $S/Decoders/DAB/DABFIC.swift $S/Decoders/DAB/DABEnsemble.swift $S/Decoders/DAB/DABCharset.swift $S/Decoders/DAB/DABMSC.swift $S/Decoders/DAB/DABPAD.swift $S/Decoders/DAB/DABSignalGenerator.swift Tools/DABBench/DABSelfTest.swift $S/SDR/SDRDSP.swift $S/SDR/SDRDemodulator.swift $S/SDR/SDRReceiver.swift $S/SDR/SDRSignalGenerator.swift $S/SDR/SDRChannelBank.swift $S/SDR/SDRModule.swift
    Modules/VoiceCore/Sources/VoiceCore/VoiceDecoder.swift Modules/VoiceCore/Sources/VoiceCore/VoiceAudio.swift
)

# Übersetzen: parallel je Datei (ohne Whole-Module-Optimierung) und inkrementell. Ohne Zusatz ist das etwa dreimal schneller als ein einziger Durchlauf.
FLAGS=(${=LT_FLAGS:--O -no-whole-module-optimization -j$NCPU})
mkdir -p "$OUT/obj"
python3 - "$OUT" $SRC <<'PY'
import json, sys, re
out = sys.argv[1]
m = {"": {"swift-dependencies": out + "/obj/master.swiftdeps"}}
for f in sys.argv[2:]:
    k = re.sub(r"[^A-Za-z0-9]", "_", f)
    m[f] = {"object": out + "/obj/" + k + ".o", "swift-dependencies": out + "/obj/" + k + ".swiftdeps"}
json.dump(m, open(out + "/ofm.json", "w"))
PY
swiftc $FLAGS -incremental -output-file-map "$OUT/ofm.json" -module-name LogicTests -swift-version 6 -o "$OUT/logic_tests" \
    -I "$OUT/fldigi/module" -Xcc -I"$ROOT/Vendor/Codec2/include" \
    $SRC "$OUT"/fldigi/obj/*.o -lc++

# 4. Ausführen
if (( PARALLEL > 0 && ${#ONLY} == 0 )); then
    LOGS="$OUT/groups"; mkdir -p "$LOGS"; rm -f -- "$LOGS"/*.log(N) "$LOGS"/*.rc(N)
    print -l -- $GROUPS_LIST | xargs -P "$PARALLEL" -I{} zsh -c 'LT_ONLY={} "$0/logic_tests" > "$1/{}.log" 2>&1; echo $? > "$1/{}.rc"' "$OUT" "$LOGS"
    TOTAL=0; BAD=()
    for g in $GROUPS_LIST; do
        n=$(grep -E '^[0-9]+ Prüfungen' "$LOGS/$g.log" | tail -1 | sed -E 's/^([0-9]+) Prüfungen.*/\1/')
        TOTAL=$(( TOTAL + ${n:-0} ))
        [[ "$(cat "$LOGS/$g.rc")" == 0 ]] || BAD+=($g)
    done
    # Fehler einzeln wiederholen: gleichzeitige Läufe teilen sich die Voreinstellungen (UserDefaults) und können sich stören
    FAILED=()
    for g in $BAD; do
        echo "Gruppe $g schlug beim parallelen Lauf fehl, wiederhole einzeln …"
        if ! LT_ONLY=$g "$OUT/logic_tests" > "$LOGS/$g.retry.log" 2>&1; then FAILED+=($g); grep -E "FAIL" "$LOGS/$g.retry.log" || tail -5 "$LOGS/$g.retry.log"; fi
    done
    echo "$TOTAL Prüfungen in ${#GROUPS_LIST} Gruppen, ${#FAILED} Gruppen mit Fehlern ${FAILED}"
    (( ${#FAILED} == 0 ))
else
    LT_ONLY="$ONLY" "$OUT/logic_tests"
fi
