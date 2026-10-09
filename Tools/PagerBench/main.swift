// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// PagerBench: POCSAG-Empfang unter nachgebildeten Funkbedingungen messen (Digidec gegen multimon-ng).
//
// Aufruf: Tools/PagerBench/pager_bench.sh [Optionen]
//   --trials n        Sendungen je Bedingung (Standard 12)
//   --baud 512|1200|2400
//   --only <muster>   nur Bedingungen, deren Name das Muster enthält
//   --mm <pfad>       multimon-ng als Gegenprobe (Standard: kein Vergleich)
//   --dump <ordner>   die Audiodateien (48 kHz, 16 Bit) der ersten Sendung je Bedingung speichern
//
// Nachbildung: Bitstrom → FM-Modulator (Hub 4,5 kHz) → Rauschen und Zwischenfrequenzfilter (12 kHz) → Diskriminator →
// Hörfunk-NF-Kette (Entzerrung, Hochpass der Kopplung, Sprachband) → Abtastratenwandler wie in Digidec.
import Foundation

let fs = pagerChannelRate

// MARK: - WAV

func writeWAV16(_ samples: [Float], rate: Int, to path: String) {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
    var pcm = [Int16](repeating: 0, count: samples.count)
    for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32_000) }
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    try? d.write(to: URL(fileURLWithPath: path))
}

// MARK: - Empfänger

func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
    guard let c = SampleRateConverter(inputRate: from, outputRate: to) else { return x }
    var out: [Float] = []
    x.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {
            let n = min(4800, buf.count - i)
            c.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)])) { out += Array($0) }
            i += n
        }
    }
    return out
}

func digidecDecode(_ audio48k: [Float], rates: Set<Int>, recordRate: Double = 48_000) -> [PagerTestMessage] {
    // Aufnahme mit anderer Quellrate (z. B. 44,1 kHz): zuerst dorthin wandeln, dann wie die App nach 24 kHz
    let src = recordRate == fs ? audio48k : resample(audio48k, from: fs, to: recordRate)
    let a = resample(src, from: recordRate, to: 24_000)
    let rx = POCSAGReceiver(sampleRate: 24_000)
    rx.enabled = Set(rates.compactMap { POCSAG.rates.firstIndex(of: $0) })
    var out: [PagerTestMessage] = []
    a.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {
            let n = min(2400, buf.count - i)
            rx.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)])) { m in out.append(PagerTestMessage(ric: m.address, function: m.function, text: m.text, corrected: m.corrected, damaged: m.damaged)) }
            i += n
        }
    }
    rx.flush { m in out.append(PagerTestMessage(ric: m.address, function: m.function, text: m.text, corrected: m.corrected, damaged: m.damaged)) }
    return out
}

func multimonDecode(_ audio48k: [Float], baud: Int, path: String, tmp: String) -> [PagerTestMessage] {
    let a = resample(audio48k, from: fs, to: 22_050)
    var pcm = [Int16](repeating: 0, count: a.count)
    for (i, s) in a.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32_000) }
    let raw = tmp + "/mm.raw"
    _ = pcm.withUnsafeBytes { FileManager.default.createFile(atPath: raw, contents: Data($0)) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["-t", "raw", "-a", "POCSAG\(baud)", raw]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var out: [PagerTestMessage] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("POCSAG") {
        // POCSAG1200: Address:  273040  Function: 3  Alpha:   text
        guard let a1 = line.range(of: "Address:"), let f1 = line.range(of: "Function:") else { continue }
        let ric = Int(line[a1.upperBound..<f1.lowerBound].trimmingCharacters(in: .whitespaces)) ?? -1
        let rest = line[f1.upperBound...]
        let fn = Int(rest.prefix(3).trimmingCharacters(in: .whitespaces)) ?? -1
        var text = ""
        if let t = rest.range(of: "Alpha:") { text = String(rest[t.upperBound...]).replacingOccurrences(of: "<NUL>", with: "") }
        else if let t = rest.range(of: "Numeric:") { text = String(rest[t.upperBound...]) }
        out.append(PagerTestMessage(ric: ric, function: fn, text: text.trimmingCharacters(in: .whitespaces)))
    }
    return out
}

// MARK: - Hauptprogramm

var trials = 12
var baud = 1200
var only: String?
var mmPath: String?
var dumpDir: String?
var verbose = false
var sessionPath: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--trials": trials = Int(args.removeFirst()) ?? trials
    case "--baud": baud = Int(args.removeFirst()) ?? baud
    case "--only": only = args.removeFirst()
    case "--mm": mmPath = args.removeFirst()
    case "--dump": dumpDir = args.removeFirst()
    case "--verbose": verbose = true
    case "--session": sessionPath = args.removeFirst()
    default: print("Unbekannte Option \(a)"); exit(2)
    }
}

let conditions: [PagerRadioChannel] = [
    PagerRadioChannel(name: "sauber (flach, kein Rauschen)", snrDB: nil),
    PagerRadioChannel(name: "flach, 20 dB", snrDB: 20),
    PagerRadioChannel(name: "flach, 14 dB", snrDB: 14),
    PagerRadioChannel(name: "flach, 10 dB", snrDB: 10),
    PagerRadioChannel(name: "flach, 8 dB", snrDB: 8),
    PagerRadioChannel(name: "flach, 7 dB", snrDB: 7),
    PagerRadioChannel(name: "flach, 6 dB", snrDB: 6),
    PagerRadioChannel(name: "flach, 5 dB", snrDB: 5),
    PagerRadioChannel(name: "flach, 4 dB", snrDB: 4),
    PagerRadioChannel(name: "Ablage +1,5 kHz, 20 dB", snrDB: 20, offsetHz: 1500),
    PagerRadioChannel(name: "Ablage −2 kHz, 20 dB", snrDB: 20, offsetHz: -2000),
    PagerRadioChannel(name: "Entzerrung 2,1 kHz, 20 dB", snrDB: 20, audio: .deemph2k),
    PagerRadioChannel(name: "Entzerrung 300 Hz, 20 dB", snrDB: 20, audio: .deemph300),
    PagerRadioChannel(name: "Kopplung 30 Hz, 20 dB", snrDB: 20, audio: .ac30),
    PagerRadioChannel(name: "Kopplung 150 Hz, 20 dB", snrDB: 20, audio: .ac150),
    PagerRadioChannel(name: "Kopplung 300 Hz, 20 dB", snrDB: 20, audio: .ac300),
    PagerRadioChannel(name: "Entzerrung 300 Hz + Kopplung 300 Hz, 20 dB", snrDB: 20, audio: .deemph300ac300),
    PagerRadioChannel(name: "Sprachband 300–3000 Hz, 20 dB", snrDB: 20, audio: .voiceBand),
    PagerRadioChannel(name: "Sprachband, 12 dB", snrDB: 12, audio: .voiceBand),
    PagerRadioChannel(name: "Sprachband, 10 dB", snrDB: 10, audio: .voiceBand),
    PagerRadioChannel(name: "Sprachband, 8 dB", snrDB: 8, audio: .voiceBand),
    PagerRadioChannel(name: "leise (Pegel 0,02), 20 dB", snrDB: 20, level: 0.02),
    PagerRadioChannel(name: "Takt +0,5 %, 20 dB", snrDB: 20, baudError: 0.005),
    PagerRadioChannel(name: "Hub 3 kHz, 20 dB", snrDB: 20, hubHz: 3000),
    PagerRadioChannel(name: "ZF 9 kHz (FM schmal), 20 dB", snrDB: 20, ifBandwidth: 9000),
    PagerRadioChannel(name: "ZF 6 kHz, 20 dB", snrDB: 20, ifBandwidth: 6000),
    PagerRadioChannel(name: "Rauschsperre zu, 20 s Stille davor", snrDB: 20, squelch: true, leadSeconds: 20),
    PagerRadioChannel(name: "Rauschsperre zu, Sprachband, 12 dB", snrDB: 12, audio: .voiceBand, squelch: true, leadSeconds: 5),
    PagerRadioChannel(name: "20 s Rauschen davor, 12 dB", snrDB: 12, leadSeconds: 20),
    PagerRadioChannel(name: "Drift 1,5 kHz in der Aussendung, 20 dB", snrDB: 20, driftHz: 1500),
    PagerRadioChannel(name: "Knackser 8/s, 20 dB", snrDB: 20, impulsesPerSecond: 8),
    PagerRadioChannel(name: "Knackser 8/s, Sprachband, 14 dB", snrDB: 14, audio: .voiceBand, impulsesPerSecond: 8),
    PagerRadioChannel(name: "Quelle 44,1 kHz, Sprachband, 14 dB", snrDB: 14, audio: .voiceBand, recordRate: 44_100),
    PagerRadioChannel(name: "Sprachband, Ablage 1,5 kHz, 12 dB", snrDB: 12, offsetHz: 1500, audio: .voiceBand),
]

// Sitzung: alle Aussendungen der ersten passenden Bedingung hintereinander in eine WAV-Datei (zum Abspielen in der App)
if let path = sessionPath {
    guard let c = conditions.first(where: { only == nil || $0.name.contains(only!) }) else { print("Keine Bedingung passt"); exit(2) }
    var rng = PagerRNG(seed: 777)
    var all: [Float] = []
    for t in 0..<trials {
        let msgs = [pagerRandomMessage(&rng), pagerRandomMessage(&rng), pagerRandomMessage(&rng, numeric: true)]
        let audio = pagerFMAudio(bits: pagerTransmissionBits(msgs), baud: baud, channel: c, lead: Int(0.8 * fs), tail: Int(1.2 * fs), rng: &rng)
        all += audio
        print("Aussendung \(t + 1): " + msgs.map { "\($0.ric) F\($0.function) \($0.text)" }.joined(separator: " | "))
    }
    writeWAV16(all, rate: 48_000, to: path)
    print("\(String(format: "%.1f", Double(all.count) / fs)) s → \(path)  (\(c.name))")
    exit(0)
}

let tmp = NSTemporaryDirectory() + "pager_bench"
try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
if let d = dumpDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
print("POCSAG \(baud) Bd: je Bedingung \(trials) Aussendungen mit je 3 Meldungen (Wiedergabe in Prozent der gesendeten Meldungen)")
func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, n - s.count))
    return right ? fill + s : s + fill
}
print(pad("Bedingung", 50) + pad("Digidec", 9, right: true) + pad("multimon", 10, right: true) + pad("falsch", 8, right: true))
for c in conditions where only == nil || c.name.contains(only!) {
    var rng = PagerRNG(seed: 12345)
    var sent = 0, got = 0, gotMM = 0, wrong = 0, wrongClean = 0, wrongCorrected = 0, wrongDamaged = 0
    for t in 0..<trials {
        let msgs = [pagerRandomMessage(&rng), pagerRandomMessage(&rng), pagerRandomMessage(&rng, numeric: true)]
        let bits = pagerTransmissionBits(msgs)
        let audio = pagerFMAudio(bits: bits, baud: baud, channel: c, lead: Int(c.leadSeconds * fs), tail: Int(0.4 * fs), rng: &rng)
        if let d = dumpDir, t == 0 {
            let safe = c.name.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            writeWAV16(audio, rate: 48_000, to: "\(d)/pocsag\(baud)_\(safe).wav")
        }
        sent += msgs.count
        let r = digidecDecode(audio, rates: [baud], recordRate: c.recordRate)
        if verbose {
            for m in msgs { print("  gesendet  \(m.ric) F\(m.function) \(m.text)") }
            for m in r {
                let ok = msgs.contains { $0 == m }
                print("  Digidec \(ok ? "✓" : "✗") \(m.ric) F\(m.function) [korr \(m.corrected), defekt \(m.damaged)] \(m.text)")
            }
        }
        for m in msgs where r.contains(where: { $0.ric == m.ric && $0.text == m.text }) { got += 1 }
        let bad = r.filter { x in !msgs.contains { $0.ric == x.ric && $0.text == x.text } }
        wrong += bad.count
        wrongClean += bad.filter { $0.corrected == 0 && $0.damaged == 0 }.count
        wrongCorrected += bad.filter { $0.corrected > 0 && $0.damaged == 0 }.count
        wrongDamaged += bad.filter { $0.damaged > 0 }.count
        if let mm = mmPath {
            let r2 = multimonDecode(audio, baud: baud, path: mm, tmp: tmp)
            for m in msgs where r2.contains(where: { $0.ric == m.ric && $0.text == m.text }) { gotMM += 1 }
        }
    }
    let pct = { (n: Int) in String(format: "%5.0f %%", Double(n) * 100 / Double(max(1, sent))) }
    print(pad(c.name, 50) + pad(pct(got), 9, right: true) + pad(mmPath == nil ? "–" : pct(gotMM), 10, right: true) + pad(String(wrong), 8, right: true) + (wrong > 0 ? "   (davon ohne Korrektur \(wrongClean), korrigiert \(wrongCorrected), mit unlesbaren Wörtern \(wrongDamaged))" : ""))
}
