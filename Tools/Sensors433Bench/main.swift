// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für die Funksensoren: Aufnahme (8-Bit-I/Q, vorzeichenlos) → Telegramme als Zeilen im Stil von rtl_433 (JSON).

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func flag(_ name: String) -> Bool { arguments.firstIndex(of: name).map { arguments.remove(at: $0) } != nil }

let rateOption = option("--rate").flatMap(Int.init)
let band = option("--band").flatMap(SensorBand.init(rawValue:)) ?? .mhz433
let packagesToo = flag("--packages")
guard let path = arguments.first else {
    print("Aufruf: sensors_bench.sh <aufnahme.cu8> [--rate 250000] [--band 433.92|868.3] [--packages]")
    exit(2)
}
guard let data = FileManager.default.contents(atPath: path) else { print("FEHLER: \(path) nicht lesbar"); exit(1) }
let rate = rateOption ?? SensorsController.sampleRate(inFileName: (path as NSString).lastPathComponent)
let receiver = SensorReceiver(sampleRate: rate, devices: SensorCatalog.all, centerFrequency: band.frequencyHz)
var count = 0
receiver.onEvent = { e in
    count += 1
    var parts = ["\"time\" : \"@\(String(format: "%.6f", e.time))s\"", "\"model\" : \"\(e.reading.model)\""]
    for f in e.reading.fields {
        switch f.value {
        case .string(let s): parts.append("\"\(f.key)\" : \"\(s)\"")
        case .int(let v): parts.append("\"\(f.key)\" : \(v)")
        case .double(let v): parts.append("\"\(f.key)\" : \(String(format: "%.3f", v))")
        }
    }
    parts.append("\"rssi\" : \(String(format: "%.1f", e.rssiDB))")
    parts.append("\"snr\" : \(String(format: "%.1f", e.snrDB))")
    print("{" + parts.joined(separator: ", ") + "}")
}
if packagesToo {
    receiver.onPackage = { kind, d in
        print(String(format: "# %@-Paket bei %.3f s: %d Pulse, Pegel %.1f dB, Rauschen %.1f dB", kind == .fsk ? "FSK" : "OOK", Double(d.offset) / Double(rate), d.numPulses, d.rssiDB, d.noiseDB))
    }
}
data.withUnsafeBytes { raw in
    let p = raw.bindMemory(to: UInt8.self)
    var i = 0
    while i < p.count { let e = min(i + 262_144, p.count); receiver.process(UnsafeBufferPointer(rebasing: p[i..<e])); i = e }
}
receiver.flush()
print("# \(count) Telegramme in \(receiver.packages) Paketen (OOK \(receiver.ookPackages), FSK \(receiver.fskPackages)), Abtastrate \(rate)")
