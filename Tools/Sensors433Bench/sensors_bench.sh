#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut den Prüfstand für Funksensoren und decodiert eine Aufnahme (8-Bit-I/Q, vorzeichenlos; Abtastrate aus dem Dateinamen, sonst 250 kS/s).
# Aufruf:  Tools/Sensors433Bench/sensors_bench.sh <aufnahme.cu8> [--rate 250000] [--band 433.92|868.3] [--packages]
# Aufnahmen zum Üben: Tools/Sensors433Bench/fetch_testdata.sh (lädt sie aus dem Prüfdaten-Repository von rtl_433 nach TestData/Sensors).
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
OUT="${SENSORS_BENCH_DIR:-${TMPDIR:-/tmp}/digidec_sensorsbench}"
mkdir -p "$OUT"
S=Sources/Decoders/Sensors433
SRC=(Tools/Sensors433Bench/main.swift $S/SensorPulses.swift $S/SensorSlicers.swift $S/SensorDevice.swift $S/SensorEngine.swift $S/SensorCatalog.swift $S/SensorDevices*.swift)
# Der Prüfstand braucht auch SensorsController.sampleRate (aus dem Modul): dessen Oberfläche bleibt draußen, darum eine eigene Kurzfassung
cat > "$OUT/rate.swift" <<'SWIFT'
import Foundation
enum SensorsController {
    static func sampleRate(inFileName name: String) -> Int {
        if let r = name.range(of: #"_(\d+)k\."#, options: .regularExpression), let k = Int(name[r].dropFirst().dropLast(2)) { return k * 1000 }
        if let r = name.range(of: #"_(\d+)M\."#, options: .regularExpression), let m = Int(name[r].dropFirst().dropLast(2)) { return m * 1_000_000 }
        return 250_000
    }
}
SWIFT
if [[ ! -x "$OUT/sensors_bench" ]] || [[ -n "$(find $SRC -newer "$OUT/sensors_bench" 2>/dev/null)" ]]; then
    swiftc -O -swift-version 6 -o "$OUT/sensors_bench" $SRC "$OUT/rate.swift"
fi
"$OUT/sensors_bench" "$@"
