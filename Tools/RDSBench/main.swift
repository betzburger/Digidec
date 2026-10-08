// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand: Aufnahme (8-Bit I/Q) → WFM-Empfänger → RDS-Demodulator → Decoder; zählt Gruppen und zeigt, was der Decoder liest.
let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]) else { print("Aufruf: rds_bench <aufnahme.cu8> [offset Hz] [sekunden] [bandbreite Hz]"); exit(2) }
let offset = args.count > 2 ? Double(args[2]) ?? -300_000 : -300_000
let seconds = args.count > 3 ? Double(args[3]) ?? 20 : 20
let rate = 2_400_000.0
var cfg = SDRChannelConfig(mode: .wfm)
if args.count > 4, let bw = Double(args[4]) { cfg.bandwidthHz = bw }
let demod = SDRDemodulator(sampleRate: rate, config: cfg)
demod.setOffset(offset)
let rds = RDSDemodulator()
let dec = RDSDecoder()
let framer = rds.streamDecoder
let dump = ProcessInfo.processInfo.environment["RDS_DUMP"]?.split(separator: ",").map(String.init) ?? []
nonisolated(unsafe) var dumped = 0
framer.onGroup = { g in
    dec.handle(g, quality: framer.currentStats.quality)
    if let n = g.name, dump.contains(n), dumped < 12 {
        dumped += 1
        print("  Gruppe \(n):", g.blocks.map { $0.map { String(format: "%04X", $0.data) } ?? "----" }.joined(separator: " "))
    }
}
demod.produceStereo = true
demod.onDiscriminator = { buf, r in rds.process(mpx: buf, sampleRate: r) }
var audio = [Float]()
var stereoAll = [Float]()
let limit = min(data.count, Int(seconds * rate) * 2)
let t0 = Date()
// RDS_NOISE=σ: weißes Rauschen (σ in 8-Bit-Stufen je Achse) auf die Aufnahme legen, um schwachen Empfang nachzubilden
let sigma = Float(ProcessInfo.processInfo.environment["RDS_NOISE"] ?? "") ?? 0
var rng = SDRTestSignal.SplitMix(seed: 42)
data.withUnsafeBytes { raw in
    let b = raw.bindMemory(to: UInt8.self)
    var i = 0
    var scratch = [UInt8](repeating: 0, count: 262_144)
    while i < limit {
        let e = min(i + 262_144, limit)
        if sigma > 0 {
            for k in 0..<(e - i) { scratch[k] = UInt8(max(0, min(255, (Float(b[i + k]) + sigma * rng.gauss()).rounded()))) }
            scratch.withUnsafeBufferPointer { demod.process(UnsafeBufferPointer(rebasing: $0[0..<(e - i)]), audio: &audio) }
        } else {
            demod.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &audio)
        }
        i = e
        stereoAll.append(contentsOf: demod.stereoOut)
        demod.stereoOut.removeAll(keepingCapacity: true)
    }
}
let dt = Date().timeIntervalSince(t0)
let s = framer.currentStats
let info = dec.snapshot
let possible = Int(seconds * 1187.5 / 104)
print(String(format: "Gruppen %d (vollständig %d) von etwa %d möglichen · Blöcke ok %d, Fehler %d, repariert %d, Güte %.0f %% · Sync %@ · Neutakt %d · Rechenzeit %.1f s",
             s.groupsReceived, s.completeGroups, possible, s.blocksReceived, s.blockErrors, s.correctedBlocks, s.quality * 100, s.syncState.rawValue, s.resyncs, dt))
let m = rds.currentMetrics
print(String(format: "RDS-Träger %.2f kHz Hub, S/N %.1f dB, Costas %@", m.carrierDeviationKHz, m.snrDB, m.locked ? "eingerastet" : "offen"))
print("PI", info.piHex ?? "-", "Land", info.country ?? "-", "PS", "[\(info.programService)]", "PTY", info.ptyName ?? "-", "TP", info.tp, "TA", info.ta)
print("RT [\(info.radioText)]", info.radioTextComplete ? "komplett" : "unvollständig")
print("RT+", info.radioTextPlus.map { "\($0.label)=\($0.text)" })
print("AF", info.alternativeFrequencies, "Uhr", info.clockFormatted ?? "-", "Gruppen", info.groupCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
print("ODA", info.applicationNames, "PTYN", info.programTypeName, "Sprache", info.language ?? "-", "DI", info.diStereo as Any)

let met = demod.metrics
var pl = 0.0, pr = 0.0, pm = 0.0, ps2 = 0.0
var kk = 0
let skip = 2 * 48_000
while kk + 1 < stereoAll.count {
    if kk > skip { let l = Double(stereoAll[kk]), r = Double(stereoAll[kk + 1]); pl += l * l; pr += r * r; pm += (l + r) * (l + r) / 4; ps2 += (l - r) * (l - r) / 4 }
    kk += 2
}
print(String(format: "Stereo: Pilot %.2f kHz Hub, %@, Mischung %.2f · L %.4f R %.4f (Effektivwerte) · L−R gegen L+R: %.1f dB · Kanalleistung %.1f dB · Rauschen im L−R %.4f",
             met.pilotKHz, met.stereoLocked ? "eingerastet" : "kein Pilot", met.stereoBlend, (pl / Double(max(1, stereoAll.count / 2))).squareRoot(), (pr / Double(max(1, stereoAll.count / 2))).squareRoot(), 10 * log10(max(ps2, 1e-20) / max(pm, 1e-20)), met.signalDB, met.stereoNoise))
if let path = ProcessInfo.processInfo.environment["STEREO_WAV"] {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + stereoAll.count * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(stereoAll.count * 2))
    for v in stereoAll { u16(UInt16(bitPattern: Int16(max(-32767, min(32767, v * 20_000))))) }
    try? d.write(to: URL(fileURLWithPath: path))
}
