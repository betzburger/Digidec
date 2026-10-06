// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für VDL Mode 2: Aufnahmen decodieren, Testsignale erzeugen, Rundlauf und Rechenzeit messen

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

/// I/Q aus WAV (8 oder 16 Bit, stereo) oder 8-Bit-Rohdaten
func readIQ(_ path: String) -> (i: [Float], q: [Float], rate: Double?) {
    guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { fail("Datei nicht lesbar: \(path)") }
    var offset = 0, bytes = 1
    var rate: Double?
    if path.lowercased().hasSuffix(".wav") {
        var pos = 12
        while pos + 8 <= data.count {
            let id = String(decoding: data[pos..<(pos + 4)], as: UTF8.self)
            let size = Int(data[pos + 4]) | Int(data[pos + 5]) << 8 | Int(data[pos + 6]) << 16 | Int(data[pos + 7]) << 24
            if id == "fmt " {
                bytes = (Int(data[pos + 22]) | Int(data[pos + 23]) << 8) / 8
                rate = Double(Int(data[pos + 12]) | Int(data[pos + 13]) << 8 | Int(data[pos + 14]) << 16 | Int(data[pos + 15]) << 24)
            }
            if id == "data" { offset = pos + 8; break }
            pos += 8 + size + (size & 1)
        }
    }
    let n = (data.count - offset) / (2 * bytes)
    var i = [Float](repeating: 0, count: n), q = [Float](repeating: 0, count: n)
    data.withUnsafeBytes { raw in
        let b = raw.bindMemory(to: UInt8.self)
        for k in 0..<n {
            if bytes == 2 {
                let a = Int16(bitPattern: UInt16(b[offset + 4 * k]) | UInt16(b[offset + 4 * k + 1]) << 8)
                let c = Int16(bitPattern: UInt16(b[offset + 4 * k + 2]) | UInt16(b[offset + 4 * k + 3]) << 8)
                i[k] = Float(a) / 32768; q[k] = Float(c) / 32768
            } else {
                i[k] = (Float(b[offset + 2 * k]) - 127.5) / 127.5; q[k] = (Float(b[offset + 2 * k + 1]) - 127.5) / 127.5
            }
        }
    }
    return (i, q, rate)
}

func nameRate(_ path: String) -> Double? {
    let name = (path as NSString).lastPathComponent
    if let r = name.range(of: #"(\d+(?:\.\d+)?)\s*(?:kHz|kS|k)(?=[._\W]|$)"#, options: .regularExpression) {
        let d = name[r].prefix { $0.isNumber || $0 == "." }
        if let k = Double(d), k >= 105 { return k * 1000 }
    }
    if let r = name.range(of: #"(\d+(?:\.\d+)?)M(?=[._\W]|$)"#, options: .regularExpression) {
        let d = name[r].prefix { $0.isNumber || $0 == "." }
        if let m = Double(d) { return m * 1e6 }
    }
    return nil
}

func decode(i: [Float], q: [Float], rate: Double, center: Double, channels: [Double], showHex: Bool) -> Int {
    var total = 0
    for f in channels {
        let ch = VDL2Channel(frequency: f, centerFrequency: center, sampleRate: rate)
        ch.onBurst = { b in
            for fr in b.frames {
                total += 1
                print(String(format: "%.3f MHz  %@ → %@  %@%@  %d Byte  Pegel %.1f dB  Rauschen %.1f dB  %+.1f ppm  RS %d", f / 1e6, fr.source.text, fr.destination.text, fr.command, fr.poll ? "*" : "",
                             fr.length, fr.levelDB, fr.noiseDB, fr.ppm, fr.fecCorrections))
                if let a = fr.acars { print("    ACARS \(a.mode) \(a.registration) \(a.ack) \(a.label) \(a.blockID) \(a.flightID ?? "") \(a.text.debugDescription)") }
                else if !fr.payload.isEmpty { print("    " + String(decoding: fr.payload.prefix(160).map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self)) }
                if showHex { print("    " + hex(fr.payload)) }
            }
        }
        i.withUnsafeBufferPointer { a in q.withUnsafeBufferPointer { b in
            var p = 0
            while p < a.count { let c = min(65_536, a.count - p); ch.process(i: UnsafeBufferPointer(rebasing: a[p..<(p + c)]), q: UnsafeBufferPointer(rebasing: b[p..<(p + c)])); p += c }
        } }
        let s = ch.statistics
        print(String(format: "  Kanal %.3f: Sync %d, Kopf ok %d, Kopf falsch %d, RS-Fehler %d, FCS-Fehler %d, Rahmen %d", f / 1e6, s.syncs, s.headersOK, s.headerErrors, s.fecErrors, s.badFCS, s.frames))
    }
    return total
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Aufruf: file <aufnahme> | synth <aus> | selftest (siehe vdl2_bench.sh)") }

switch command {
case "file":
    guard args.count > 1 else { fail("Aufnahme fehlt") }
    let path = args[1]
    let (i, q, headerRate) = readIQ(path)
    let rate = option("--rate", in: args).flatMap(Double.init) ?? nameRate(path) ?? headerRate ?? 1_050_000
    let center = (option("--center", in: args).flatMap(Double.init) ?? 136.975) * 1e6
    let channels = option("--channels", in: args)?.split(separator: ",").compactMap { Double($0) }.map { $0 * 1e6 } ?? [center]
    print("\(path): \(i.count) Abtastwerte, \(Int(rate)) S/s, Mitte \(center / 1e6) MHz, \(channels.count) Kanäle")
    let n = decode(i: i, q: q, rate: rate, center: center, channels: channels, showHex: args.contains("--hex"))
    print("\(n) Rahmen")
    exit(n > 0 ? 0 : 2)
case "synth":
    guard args.count > 1 else { fail("Ausgabedatei fehlt") }
    let rate = option("--rate", in: args).flatMap(Double.init) ?? 2_000_000
    let noise = option("--noise", in: args).flatMap(Double.init) ?? 0.03
    let cfo = option("--cfo", in: args).flatMap(Double.init) ?? 0
    let channel = (option("--channel", in: args).flatMap(Double.init) ?? 136.925) * 1e6
    let text = option("--text", in: args) ?? "POS N49480E009560 FL360 TEST VDL2"
    let ac = VDL2Address(raw: UInt32(0x3C6444) | (1 << 24)), gs = VDL2Address(raw: UInt32(0x123456) | (4 << 24))
    let payload = VDL2SignalGenerator.acarsPayload(registration: "D-AIXC", label: "H1", blockID: "1", text: text)
    let bits = VDL2SignalGenerator.burstBits(frames: [VDL2SignalGenerator.informationFrame(destination: gs, source: ac, poll: true, payload: payload),
                                                     VDL2SignalGenerator.supervisoryFrame(destination: gs, source: ac, function: 0, recvSeq: 1)])
    let (i, q) = VDL2SignalGenerator.render([VDL2SignalGenerator.Burst(bits: bits, offsetHz: channel - 136_850_000 + cfo)], sampleRate: rate, duration: 0.1 + Double(bits.count) / 31_500, noise: noise)
    var out = Data()
    if args[1].lowercased().hasSuffix(".wav") {
        let n = i.count
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        out.append(contentsOf: Array("RIFF".utf8) + le32(36 + n * 4) + Array("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(Int(rate)) + le32(Int(rate) * 4) + le16(4) + le16(16) + Array("data".utf8) + le32(n * 4))
        for k in 0..<n {
            out.append(contentsOf: le16(Int(Int16(max(-32768, min(32767, i[k] * 32768))))) + le16(Int(Int16(max(-32768, min(32767, q[k] * 32768))))))
        }
    } else {
        for k in 0..<i.count {
            out.append(UInt8(max(0, min(255, Int((i[k] * 127.5 + 127.5).rounded())))))
            out.append(UInt8(max(0, min(255, Int((q[k] * 127.5 + 127.5).rounded())))))
        }
    }
    try! out.write(to: URL(fileURLWithPath: args[1]))
    print("\(args[1]): \(i.count) Abtastwerte, \(Int(rate)) S/s, Kanal \(channel / 1e6) MHz, Ablage \(cfo) Hz, Rauschen \(noise)")
case "selftest":
    var failures = 0
    let ac = VDL2Address(raw: UInt32(0x3C6444) | (1 << 24)), gs = VDL2Address(raw: UInt32(0x123456) | (4 << 24))
    for (rate, noise, cfo, ppm) in [(2_000_000.0, 0.0, 0.0, 0.0), (2_000_000.0, 0.05, 400.0, 20.0), (2_400_000.0, 0.03, -300.0, -15.0), (1_050_000.0, 0.03, 200.0, 0.0)] {
        let text = "SELFTEST \(Int(rate)) \(noise) \(cfo)"
        let bits = VDL2SignalGenerator.burstBits(frames: [VDL2SignalGenerator.informationFrame(destination: gs, source: ac, payload: VDL2SignalGenerator.acarsPayload(registration: "D-AIXC", label: "H1", blockID: "1", text: text))])
        let (i, q) = VDL2SignalGenerator.render([VDL2SignalGenerator.Burst(bits: bits, offsetHz: 136_925_000 - 136_850_000 + cfo, clockPPM: ppm)], sampleRate: rate, duration: 0.1 + Double(bits.count) / 31_500, noise: noise)
        let ch = VDL2Channel(frequency: 136_925_000, centerFrequency: 136_850_000, sampleRate: rate)
        var got = ""
        ch.onBurst = { b in got = b.frames.first?.acars?.text ?? "" }
        i.withUnsafeBufferPointer { a in q.withUnsafeBufferPointer { b in ch.process(i: a, q: b) } }
        let ok = got == text
        if !ok { failures += 1 }
        print("\(ok ? "OK " : "FEHLER") Rate \(Int(rate)) Rauschen \(noise) Ablage \(cfo) Hz Takt \(ppm) ppm")
    }
    // Rechenzeit: sechs Kanäle, 5 s Rauschen bei 2 MS/s
    let (i, q) = VDL2SignalGenerator.render([], sampleRate: 2_000_000, duration: 5, noise: 0.1)
    let chans = VDL2.europeanChannels.map { VDL2Channel(frequency: $0, centerFrequency: 136_850_000, sampleRate: 2_000_000) }
    let start = Date()
    i.withUnsafeBufferPointer { a in q.withUnsafeBufferPointer { b in
        for c in chans { c.process(i: a, q: b) }
    } }
    let t = Date().timeIntervalSince(start)
    print(String(format: "Rechenzeit: 5 s Signal, 6 Kanäle, hintereinander in %.2f s (%.1f× Echtzeit je Kanal im Mittel)", t, 5 * 6 / t))
    exit(failures == 0 ? 0 : 1)
default:
    fail("Unbekannter Befehl \(command)")
}
