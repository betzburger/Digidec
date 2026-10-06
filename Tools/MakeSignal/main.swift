// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// make_signal: erzeugt Testsignale (WAV, 16 Bit mono) aus Skriptdateien.
//
//   acars <skript> <aus.wav>   Zeilen: <Sekunde>|<Kennzeichen>|<Flug>|<Label>|<Text>   (\n im Text = Zeilenumbruch, # = Kommentar)
//   sonde - <aus.wav>          RS41-Flug als FM-Diskriminator-Audio (48 kHz), ein Telegramm je Sekunde. Optionen:
//                              --serial N1234567 --lat 49.79 --lon 9.95 --alt 180 --climb 5 --burst 28000 --wind 2,8 --seconds 600
//                              --start <s> (Beginn im Flug) --freq 403500 (kHz) --temp 15 (Bodentemperatur °C) --offset <Spannung> --ppm <Taktabweichung>
//   packet - <aus.wav>         Packet-Radio-Demo (12 kHz): Bake, Knotenliste, Digipeater, Mailbox-Verbindung, Winlink-Sitzung mit Nachricht und Anhang
//   adsb - <aus.bin>           ADS-B-Demo: zehn Flugzeuge mit frei gewählten Adressen und Rufzeichen rund um JN49WS (können zufällig echten entsprechen) als 8-Bit-I/Q (2 MS/s, vorzeichenlos), --seconds 24
//   Optionen: --noise <Amplitude>   Rauschen dazu (Standard 0)
import Foundation

func writeWAV(_ samples: [Float], rate: Int, to path: String) throws {
    var pcm = [Int16](repeating: 0, count: samples.count)
    for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32_000) }
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count * 2))
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    try d.write(to: URL(fileURLWithPath: path))
}

func lines(of path: String) -> [String] {
    guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { print("Skript nicht lesbar: \(path)"); exit(2) }
    return t.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
}

var args = Array(CommandLine.arguments.dropFirst())
var noise: Float = 0
if let i = args.firstIndex(of: "--noise"), i + 1 < args.count { noise = Float(args[i + 1]) ?? 0; args.removeSubrange(i...(i + 1)) }
guard args.count >= 3, args[0] != "--help" else {
    print("Aufruf: make_signal.sh acars <skript.txt> <aus.wav> [--noise <Amplitude>]\n        make_signal.sh adsb - <aus.bin> [--seconds 24]\n        make_signal.sh packet - <aus.wav> [--noise <Amplitude>]\n        make_signal.sh sonde - <aus.wav> [--serial …] [--lat …] [--lon …] [--alt …] [--climb …] [--burst …] [--seconds …] (siehe Kopf von main.swift)")
    exit(args.first == "--help" ? 0 : 2)
}

switch args[0] {
case "acars":
    let rate = 12_000
    var out: [Float] = []
    var blockNo = 0
    for l in lines(of: args[1]) {
        let f = l.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, let t = Double(f[0]) else { print("Zeile übersprungen: \(l)"); continue }
        let text = f[4].replacingOccurrences(of: "\\n", with: "\r\n")
        let block = ACARSSignalGenerator.block(registration: f[1], label: f[3], blockID: Character(String(blockNo % 9 + 1)),
                                               messageNumber: String(format: "M%02dA", blockNo % 100), flightID: f[2], text: text)
        let audio = ACARSSignalGenerator.audio(blocks: [block], sampleRate: Double(rate))
        let start = Int(t * Double(rate))
        if out.count < start + audio.count { out += [Float](repeating: 0, count: start + audio.count - out.count) }
        for (i, s) in audio.enumerated() { out[start + i] += s }
        blockNo += 1
    }
    out += [Float](repeating: 0, count: rate)
    if noise > 0 { for i in out.indices { out[i] += noise * Float.random(in: -1...1) } }
    try writeWAV(out, rate: rate, to: args[2])
    print("\(blockNo) Meldungen, \(String(format: "%.1f", Double(out.count) / Double(rate))) s → \(args[2])")
case "sonde":
    func opt(_ name: String, _ fallback: String) -> String {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        return fallback
    }
    let serial = opt("--serial", "T2610001")
    let lat = Double(opt("--lat", "49.79")) ?? 49.79, lon = Double(opt("--lon", "9.95")) ?? 9.95, alt = Double(opt("--alt", "180")) ?? 180
    let climb = Double(opt("--climb", "5")) ?? 5, burst = Double(opt("--burst", "28000")) ?? 28_000
    let w = opt("--wind", "2,8").split(separator: ",").compactMap { Double($0) }
    let seconds = Int(opt("--seconds", "600")) ?? 600, start = Int(opt("--start", "0")) ?? 0
    let freq = Int(opt("--freq", "403500")) ?? 403_500
    let groundTemp = Double(opt("--temp", "15")) ?? 15
    let offset = Float(opt("--offset", "0")) ?? 0, ppm = Double(opt("--ppm", "0")) ?? 0
    let cal = RS41SignalGenerator.Calibration(frequencyKHz: freq, model: "RS41-SG")
    var frames: [[UInt8]] = []
    var last = (lat: lat, lon: lon, alt: alt)
    for k in 0..<seconds {
        var p = RS41SignalGenerator.Parameters()
        p.serial = serial
        p.frame = 200 + start + k
        let st = RS41SignalGenerator.flightState(t: Double(start + k), launch: (lat, lon, alt), climb: climb, burst: burst, wind: (w.first ?? 2, w.last ?? 8))
        last = (st.lat, st.lon, st.alt)
        p.latitude = st.lat; p.longitude = st.lon; p.altitude = st.alt
        p.vNorth = st.vN; p.vEast = st.vE; p.vUp = st.vU
        p.gpsWeek = 2380; p.gpsMillis = 300_000_000 + 1000 * (start + k)
        // Standardatmosphäre: −6,5 K je km bis 11 km, danach −56,5 °C
        let h = st.alt - alt
        let t = h < 11_000 ? groundTemp - 0.0065 * h : groundTemp - 71.5
        p.meas = Array((cal.measurement(temperature: t) + [Double](repeating: 0, count: 9)).prefix(12))
        p.calibrationIndex = (start + k) % 51
        p.calibrationBytes = cal.chunk((start + k) % 51)
        frames.append(RS41SignalGenerator.frame(p))
    }
    var out = RS41SignalGenerator.audio(frames: frames, offset: offset, clockError: ppm * 1e-6)
    if noise > 0 { for i in out.indices { out[i] += noise * Float.random(in: -1...1) } }
    try writeWAV(out, rate: 48_000, to: args[2])
    print("\(frames.count) Telegramme, \(String(format: "%.0f", Double(out.count) / 48_000)) s, letzte Höhe \(Int(last.alt)) m bei \(String(format: "%.4f %.4f", last.lat, last.lon)) → \(args[2])")
case "adsb":
    let secs = Double(args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "24") ?? 24
    let home = Maidenhead.point("JN49WS") ?? GeoPoint(lat: 49.79, lon: 9.95)
    typealias A = ADSBSignalGenerator.SimAircraft
    let fleet: [A] = [
        A(icao: 0x3C6444, callsign: "DLH400", lat: 50.4, lon: 6.0, altitudeFt: 36_000, trackDeg: 290, speedKn: 450),
        A(icao: 0x406A3D, callsign: "EZY81KT", lat: 51.8, lon: 11.5, altitudeFt: 35_000, trackDeg: 250, speedKn: 430, climbFpm: -640),
        A(icao: 0x4CA7B1, callsign: "RYR5XQ", lat: 48.0, lon: 13.0, altitudeFt: 37_000, trackDeg: 300, speedKn: 440),
        A(icao: 0x3944C1, callsign: "AFR1234", lat: 48.5, lon: 5.5, altitudeFt: 33_000, trackDeg: 75, speedKn: 400),
        A(icao: 0x4AC8A1, callsign: "SAS421", lat: 53.5, lon: 10.0, altitudeFt: 34_000, trackDeg: 190, speedKn: 420, climbFpm: -800),
        A(icao: 0x3C65A2, callsign: "TUI12A", lat: 49.9, lon: 9.7, altitudeFt: 9_000, trackDeg: 45, speedKn: 250, climbFpm: 1_200),
        A(icao: 0x3C4A10, callsign: "MEDEVAC1", lat: 49.5, lon: 10.4, altitudeFt: 5_000, trackDeg: 270, speedKn: 180, emergency: true),
        A(icao: 0x300124, callsign: "ITY712", lat: 45.5, lon: 9.5, altitudeFt: 38_000, trackDeg: 20, speedKn: 440),
        A(icao: 0x48A1C3, callsign: "LOT3AB", lat: 50.0, lon: 15.5, altitudeFt: 36_000, trackDeg: 280, speedKn: 450),
        A(icao: 0xA1B2C3, callsign: "UAL988", lat: 52.5, lon: 6.0, altitudeFt: 39_000, trackDeg: 115, speedKn: 480),
    ]
    let (iq, count) = ADSBSignalGenerator.traffic(fleet, receiver: (home.lat, home.lon), seconds: secs)
    try Data(iq).write(to: URL(fileURLWithPath: args[2]))
    print("\(fleet.count) Flugzeuge, \(count) Meldungen, \(String(format: "%.0f", secs)) s, \(iq.count / 1_000_000) MB → \(args[2])")
case "packet":
    let frames = PacketSignalGenerator.demoFrames()
    var out = AFSKModulator.modulate(frames: frames.map { $0.encode() }, sampleRate: 12_000, preambleFlags: 25, gapSeconds: 0.5, amplitude: 0.5)
    out += [Float](repeating: 0, count: 12_000)
    if noise > 0 { for i in out.indices { out[i] += noise * Float.random(in: -1...1) } }
    try writeWAV(out, rate: 12_000, to: args[2])
    print("\(frames.count) Rahmen, \(String(format: "%.0f", Double(out.count) / 12_000)) s → \(args[2])")
default:
    print("Unbekannte Art: \(args[0])")
    exit(2)
}
