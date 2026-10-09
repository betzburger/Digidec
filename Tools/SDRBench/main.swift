// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Prüfstand für den eingebauten SDR-Empfänger: `selftest` (Testsignale, Messwerte, Rechenzeit) und `file` (Aufnahme → WAV).

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ text: String) {
    print((ok ? "  ok     " : "  FEHLER ") + text)
    if !ok { failures += 1 }
}

func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

/// Amplitude einer Frequenz im Audio (Hann-Fenster, Mitte des Blocks) und Gesamtleistung ohne diese Frequenz
func tone(_ a: [Float], _ f: Double, skip: Double = 0.4, rate: Double = 48_000) -> Double {
    let start = Int(skip * rate)
    guard a.count > start + 4800 else { return 0 }
    let n = a.count - start
    var re = 0.0, im = 0.0, w = 0.0
    for k in 0..<n {
        let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n))
        let ph = 2 * Double.pi * f * Double(k) / rate
        re += Double(a[start + k]) * win * cos(ph)
        im -= Double(a[start + k]) * win * sin(ph)
        w += win
    }
    return 2 * (re * re + im * im).squareRoot() / w
}

func rms(_ a: [Float], skip: Double = 0.4, rate: Double = 48_000) -> Double {
    let start = min(a.count, Int(skip * rate))
    var s = 0.0
    for k in start..<a.count { s += Double(a[k]) * Double(a[k]) }
    return (s / Double(max(1, a.count - start))).squareRoot()
}

func run(_ s: SDRTestSignal, config: SDRChannelConfig, offset: Double, chunkBytes: Int = 262_144) -> [Float] {
    let demod = SDRDemodulator(sampleRate: s.sampleRate, config: config)
    demod.setOffset(offset)
    let bytes = s.quantized()
    var audio = [Float]()
    bytes.withUnsafeBufferPointer { b in
        var i = 0
        while i < b.count {
            let e = min(i + chunkBytes, b.count)
            demod.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &audio)
            i = e
        }
    }
    return audio
}

func writeWAV(_ audio: [Float], to path: String, rate: Int = 48_000) {
    var data = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
    data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + audio.count * 2)); data.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    data.append("data".data(using: .ascii)!); u32(UInt32(audio.count * 2))
    for x in audio { u16(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32000))) }
    try? data.write(to: URL(fileURLWithPath: path))
}

final class AudioBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = [Float]()
    func append(_ b: UnsafeBufferPointer<Float>) { lock.withLock { data.append(contentsOf: b) } }
    func take() -> [Float] { lock.withLock { data } }
}

func selftest() {
    let fs = 2_400_000.0
    print("FM")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.4)
        s.addNoise(sigma: 0.003)
        var c = SDRChannelConfig(mode: .nfm); c.bandwidthHz = 12_500
        let a = run(s, config: c, offset: 300_000)
        let amp = tone(a, 1000)
        check(abs(amp - 0.6) < 0.03, String(format: "Ton 1 kHz bei 3 kHz Hub: Amplitude %.3f (erwartet 0,60)", amp))
        let sinad = db(amp / (2).squareRoot()) - db(max(1e-9, (pow(rms(a), 2) - pow(amp / (2).squareRoot(), 2)).squareRoot()))
        check(sinad > 30, String(format: "SINAD %.1f dB (mehr als 30)", sinad))
    }
    do {
        // Nachbarkanal 25 kHz entfernt, 14 dB stärker
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.1)
        s.addFM(offsetHz: 325_000, tone: 2000, deviation: 3000, amplitude: 0.5)
        s.addNoise(sigma: 0.002)
        var c = SDRChannelConfig(mode: .nfm); c.bandwidthHz = 12_500
        let a = run(s, config: c, offset: 300_000)
        let wanted = tone(a, 1000), interferer = tone(a, 2000)
        check(db(interferer / wanted) < -35, String(format: "Nachbarkanal (25 kHz, +14 dB): %.1f dB zum Nutzsignal (unter −35)", db(interferer / wanted)))
    }
    do {
        // Frequenzablage: Träger 2 kHz neben der Mitte; die AFC nimmt den Gleichanteil weg
        var s = SDRTestSignal(sampleRate: fs, seconds: 6)
        s.addFM(offsetHz: -400_000 + 2_000, tone: 1000, deviation: 3000, amplitude: 0.4)
        s.addNoise(sigma: 0.003)
        var c = SDRChannelConfig(mode: .nfm); c.bandwidthHz = 25_000; c.afc = true
        let a = run(s, config: c, offset: -400_000)
        let tail = Array(a[(a.count - 48_000)...])
        let mean = tail.reduce(0, +) / Float(tail.count)
        check(abs(mean) < 0.05, String(format: "Gleichanteil nach AFC %.3f (Ablage 2 kHz = 0,4 ohne AFC)", mean))
        var off = c; off.afc = false
        let b = run(s, config: off, offset: -400_000)
        let m2 = Array(b[(b.count - 48_000)...]).reduce(0, +) / 48_000
        check(abs(m2 - 0.4) < 0.05, String(format: "ohne AFC bleibt der Gleichanteil %.3f (0,40)", m2))
    }
    print("AM")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addAM(offsetHz: -200_000, tone: 1000, depth: 0.5, amplitude: 0.3)
        s.addNoise(sigma: 0.003)
        let a = run(s, config: SDRChannelConfig(mode: .am), offset: -200_000)
        let amp = tone(a, 1000)
        check(abs(amp - 0.5) < 0.04, String(format: "Modulationsgrad 50 %%: Amplitude %.3f (0,50)", amp))
    }
    print("SSB")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addCarrier(offsetHz: 500_000 + 1500, amplitude: 0.1)       // oberes Seitenband
        s.addCarrier(offsetHz: 500_000 - 2000, amplitude: 0.1)       // unteres Seitenband
        s.addNoise(sigma: 0.002)
        var c = SDRChannelConfig(mode: .usb); c.agc = false
        let u = run(s, config: c, offset: 500_000)
        check(tone(u, 1500) > 0.1, String(format: "USB: Ton bei +1,5 kHz hörbar (%.3f)", tone(u, 1500)))
        check(db(tone(u, 2000) / tone(u, 1500)) < -50, String(format: "USB: unteres Seitenband unterdrückt (%.1f dB)", db(tone(u, 2000) / tone(u, 1500))))
        c.mode = .lsb
        let l = run(s, config: c, offset: 500_000)
        check(tone(l, 2000) > 0.1, String(format: "LSB: Ton bei −2 kHz als 2 kHz hörbar (%.3f)", tone(l, 2000)))
        check(db(tone(l, 1500) / tone(l, 2000)) < -50, String(format: "LSB: oberes Seitenband unterdrückt (%.1f dB)", db(tone(l, 1500) / tone(l, 2000))))
        // Durchlassbereich 100 … 3100 Hz: 3,5 kHz fällt heraus, 200 Hz bleibt
        var t = SDRTestSignal(sampleRate: fs, seconds: 2)
        t.addCarrier(offsetHz: 500_000 + 3500, amplitude: 0.1)
        t.addCarrier(offsetHz: 500_000 + 300, amplitude: 0.1)
        t.addNoise(sigma: 0.002)
        var u2 = SDRChannelConfig(mode: .usb); u2.agc = false
        let e = run(t, config: u2, offset: 500_000)
        check(db(tone(e, 3500) / tone(e, 300)) < -40, String(format: "USB: 3,5 kHz außerhalb des Durchlassbereichs (%.1f dB)", db(tone(e, 3500) / tone(e, 300))))
    }
    do {
        // AGC: schwaches und starkes Signal erreichen ähnlichen Pegel
        var weak = SDRTestSignal(sampleRate: fs, seconds: 3), strong = SDRTestSignal(sampleRate: fs, seconds: 3)
        weak.addCarrier(offsetHz: 400_000 + 1000, amplitude: 0.01); weak.addNoise(sigma: 0.002)
        strong.addCarrier(offsetHz: 400_000 + 1000, amplitude: 0.3); strong.addNoise(sigma: 0.002)
        let c = SDRChannelConfig(mode: .usb)
        let a = run(weak, config: c, offset: 400_000), b = run(strong, config: c, offset: 400_000)
        check(abs(db(tone(a, 1000) / tone(b, 1000))) < 8, String(format: "AGC: Pegelunterschied %.1f dB bei 30 dB Eingangsunterschied", db(tone(a, 1000) / tone(b, 1000))))
    }
    print("CW")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addCarrier(offsetHz: -400_000, amplitude: 0.1)              // Träger auf der angezeigten Frequenz
        s.addNoise(sigma: 0.002)
        var c = SDRChannelConfig(mode: .cw); c.agc = false
        let a = run(s, config: c, offset: -400_000)
        check(tone(a, 700) > 0.1, String(format: "CW: Träger als 700-Hz-Ton (%.3f)", tone(a, 700)))
        check(db(tone(a, 1500) / tone(a, 700)) < -40, "CW: nichts bei 1,5 kHz")
        c.mode = .cwr
        let b = run(s, config: c, offset: -400_000)
        check(tone(b, 700) > 0.1, String(format: "CWR: Träger als 700-Hz-Ton (%.3f)", tone(b, 700)))
    }
    print("Rundfunk-FM")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addFM(offsetHz: -300_000, tone: 1000, deviation: 75_000, amplitude: 0.3)
        s.addNoise(sigma: 0.003)
        let a = run(s, config: SDRChannelConfig(mode: .wfm), offset: -300_000)
        let amp = tone(a, 1000)
        check(abs(amp - 1.0) < 0.1, String(format: "WFM: 75 kHz Hub → Amplitude %.3f (1,0)", amp))
        // Pilotton 19 kHz liegt im Signal: ein Ton bei 19 kHz mit 7 kHz Hub wird herausgefiltert
        var p = SDRTestSignal(sampleRate: fs, seconds: 2)
        p.addFM(offsetHz: -300_000, tone: 19_000, deviation: 7_500, amplitude: 0.3)
        let b = run(p, config: SDRChannelConfig(mode: .wfm), offset: -300_000)
        check(tone(b, 19_000) < 0.02, String(format: "WFM: 19-kHz-Pilot unterdrückt (%.4f)", tone(b, 19_000)))
    }
    print("Squelch")
    do {
        var n = SDRTestSignal(sampleRate: fs, seconds: 2)
        n.addNoise(sigma: 0.01)
        var c = SDRChannelConfig(mode: .nfm); c.squelchEnabled = true; c.squelchDB = -50
        let a = run(n, config: c, offset: 300_000)
        check(rms(a) < 1e-6, "Squelch zu bei Rauschen")
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.2)
        s.addNoise(sigma: 0.002)
        let b = run(s, config: c, offset: 300_000)
        check(tone(b, 1000) > 0.4, "Squelch offen bei Signal")
    }
    print("Blockgrenzen")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 1)
        s.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.4)
        s.addNoise(sigma: 0.003)
        for mode in [SDRMode.nfm, .am, .usb, .wfm] {
            let c = SDRChannelConfig(mode: mode)
            let whole = run(s, config: c, offset: 300_000, chunkBytes: 4_800_000)
            let parts = run(s, config: c, offset: 300_000, chunkBytes: 7_000)
            var maxDiff: Float = 0
            let n = min(whole.count, parts.count)
            for k in 0..<n { maxDiff = max(maxDiff, abs(whole[k] - parts[k])) }
            check(whole.count == parts.count && maxDiff < 2e-3, "\(mode.title): Ergebnis unabhängig von der Blockaufteilung (Länge \(whole.count)/\(parts.count), Abweichung \(maxDiff))")
        }
    }
    print("Engine und Spektrum")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 2)
        s.addFM(offsetHz: 500_000, tone: 1000, deviation: 3000, amplitude: 0.3)
        s.addCarrier(offsetHz: -700_000, amplitude: 0.05)
        s.addNoise(sigma: 0.003)
        let engine = SDRReceiverEngine(sampleRate: fs)
        let box = AudioBox()
        engine.setAudioHandler { b in box.append(b) }
        engine.setChannel(SDRChannelConfig(mode: .nfm))
        engine.setOffset(500_000)
        let bytes = s.quantized()
        bytes.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count { let e = min(i + 262_144, b.count); engine.feed(UnsafeBufferPointer(rebasing: b[i..<e]), wait: true); i = e }
        }
        Thread.sleep(forTimeInterval: 1.0)
        let audio = box.take()
        check(abs(tone(audio, 1000) - 0.6) < 0.03, String(format: "Engine: Ton 1 kHz Amplitude %.3f", tone(audio, 1000)))
        let rows = engine.takeSpectrumRows()
        check(rows.count >= 40 && rows.count <= 60, "Spektrum: \(rows.count) Zeilen in 2 s (erwartet 50)")
        if let row = rows.last {
            let binHz = fs / Double(SDRSpectrum.size)
            func peak(near f: Double) -> Double {
                let c = SDRSpectrum.size / 2 + Int((f / binHz).rounded())
                var best = c, v = -200 as Float
                for k in (c - 40)...(c + 40) where row[k] > v { v = row[k]; best = k }
                return Double(best - SDRSpectrum.size / 2) * binHz
            }
            check(abs(peak(near: 500_000) - 500_000) < 20_000, String(format: "Spektrum: FM-Signal bei %.0f Hz (500000)", peak(near: 500_000)))
            check(abs(peak(near: -700_000) + 700_000) < 3_000, String(format: "Spektrum: Träger bei %.0f Hz (-700000)", peak(near: -700_000)))
            let carrierBin = SDRSpectrum.size / 2 + Int((-700_000 / binHz).rounded())
            let level = (carrierBin - 3...carrierBin + 3).map { row[$0] }.max() ?? -200
            check(abs(Double(level) - db(0.05)) < 2.5, String(format: "Spektrum: Träger %.1f dB (erwartet %.1f)", level, db(0.05)))
        }
        let snap = engine.snapshot()
        check(snap.droppedBlocks == 0, "keine verworfenen Blöcke")
    }
    print("Rechenzeit (10 s Signal)")
    do {
        var s = SDRTestSignal(sampleRate: fs, seconds: 10)
        s.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.4)
        s.addNoise(sigma: 0.003)
        for mode in SDRMode.allCases where mode != .cwr {
            let t0 = Date()
            _ = run(s, config: SDRChannelConfig(mode: mode), offset: 300_000)
            let dt = Date().timeIntervalSince(t0)
            check(dt < 5, String(format: "%@: %.2f s (Echtzeit-Faktor %.1f)", mode.title, dt, 10 / dt))
        }
    }
    print(failures == 0 ? "ALLE PRÜFUNGEN BESTANDEN" : "\(failures) FEHLER")
    exit(failures == 0 ? 0 : 1)
}

func fileMode(_ args: [String]) {
    var a = args
    func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { i in i + 1 < a.count ? a[i + 1] : nil } }
    guard a.count >= 2, let data = FileManager.default.contents(atPath: a[0]) else { print("Aufruf: file <aufnahme.cu8> <aus.wav> --rate R --offset O --mode M [--bw B]"); exit(2) }
    let out = a[1]
    let rate = Double(opt("--rate") ?? "") ?? 2_400_000
    let offset = Double(opt("--offset") ?? "") ?? 0
    let mode = SDRMode(hamlib: opt("--mode") ?? "FM") ?? .nfm
    var c = SDRChannelConfig(mode: mode)
    if let bw = Double(opt("--bw") ?? "") { c.bandwidthHz = bw }
    let demod = SDRDemodulator(sampleRate: rate, config: c)
    demod.setOffset(offset)
    var audio = [Float]()
    data.withUnsafeBytes { raw in
        let b = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i < b.count { let e = min(i + 262_144, b.count); demod.process(UnsafeBufferPointer(rebasing: b[i..<e]), audio: &audio); i = e }
    }
    writeWAV(audio, to: out)
    print(String(format: "%d Audioabtastwerte, Kanalleistung %.1f dB, Effektivwert %.3f", audio.count, demod.metrics.signalDB, rms(audio, skip: 0)))
    a.removeAll()
}

/// Demo-Aufnahme für die App: Mitte 145,800 MHz, FM-Sprechfunk bei 146,100 (+300 kHz), AM-Flugfunk bei 145,300, ein SSB-Träger bei 145,9
func generate(_ path: String) {
    var s = SDRTestSignal(sampleRate: 2_400_000, seconds: 8)
    s.addFM(offsetHz: 300_000, tone: 1000, deviation: 3000, amplitude: 0.25)
    s.addAM(offsetHz: -500_000, tone: 600, depth: 0.6, amplitude: 0.15)
    s.addFM(offsetHz: 100_000, tone: 440, deviation: 3000, amplitude: 0.08)
    s.addCarrier(offsetHz: 703_000, amplitude: 0.1)
    s.addFM(offsetHz: -250_000, tone: 1000, deviation: 75_000, amplitude: 0.06)
    s.addNoise(sigma: 0.01)
    FileManager.default.createFile(atPath: path, contents: Data(s.quantized()))
    print("geschrieben: \(path)")
}

/// Audio-WAV (16 Bit, Mono) als Frequenzmodulation in ein I/Q-Fenster legen: fmmod <audio.wav> <aus.cu8> [--offset Hz] [--dev Hz] [--seconds s] [--noise sigma] [--amp a]
func fmmod(_ a: [String]) {
    func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { i in i + 1 < a.count ? a[i + 1] : nil } }
    guard a.count >= 2, let wav = FileManager.default.contents(atPath: a[0]), wav.count > 44 else { print("Aufruf: fmmod <audio.wav> <aus.cu8> ..."); exit(2) }
    let rateIn = wav.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) }
    let pcm: [Float] = wav.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        return (22..<(raw.count / 2)).map { Float(Int16(littleEndian: p[$0])) / 32768 }
    }
    let seconds = Double(opt("--seconds") ?? "") ?? Double(pcm.count) / rateIn
    let n = min(pcm.count, Int(seconds * rateIn))
    let peak = max(1e-6, pcm.prefix(n).map { abs($0) }.max() ?? 1)
    let offset = Double(opt("--offset") ?? "") ?? 300_000
    let dev = Double(opt("--dev") ?? "") ?? 3_000
    let amp = Float(opt("--amp") ?? "") ?? 0.3
    let sigma = Float(opt("--noise") ?? "") ?? 0.003
    let fs = 2_400_000.0
    let up = Int(fs / rateIn)
    var phase = 0.0
    var out = Data(capacity: n * up * 2)
    var rng = SDRTestSignal.SplitMix(seed: 7)
    var buf = [UInt8](repeating: 0, count: 2 * up)
    for k in 0..<n {
        let x0 = pcm[k] / peak, x1 = k + 1 < n ? pcm[k + 1] / peak : x0
        for j in 0..<up {
            let x = x0 + (x1 - x0) * Float(j) / Float(up)
            phase += 2 * Double.pi * (offset + dev * Double(x)) / fs
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            let i = amp * Float(cos(phase)) + sigma * rng.gauss()
            let q = amp * Float(sin(phase)) + sigma * rng.gauss()
            buf[2 * j] = UInt8(max(0, min(255, (i * 127.5 + 127.5).rounded())))
            buf[2 * j + 1] = UInt8(max(0, min(255, (q * 127.5 + 127.5).rounded())))
        }
        out.append(contentsOf: buf)
    }
    FileManager.default.createFile(atPath: a[1], contents: out)
    print(String(format: "%.1f s Audio (%.0f Hz) → I/Q 2,4 MS/s, Träger %.0f Hz, Hub %.0f Hz, %@", Double(n) / rateIn, rateIn, offset, dev, a[1]))
}

/// Audio-WAV als Amplitudenmodulation in ein I/Q-Fenster legen: amod <audio.wav> <aus.cu8> [--offset Hz] [--depth m] [--amp a] [--noise sigma]
func amod(_ a: [String]) {
    func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { i in i + 1 < a.count ? a[i + 1] : nil } }
    guard a.count >= 2, let wav = FileManager.default.contents(atPath: a[0]), wav.count > 44 else { print("Aufruf: amod <audio.wav> <aus.cu8> ..."); exit(2) }
    let rateIn = wav.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) }
    let pcm: [Float] = wav.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        return (22..<(raw.count / 2)).map { Float(Int16(littleEndian: p[$0])) / 32768 }
    }
    let n = pcm.count
    let peak = max(1e-6, pcm.map { abs($0) }.max() ?? 1)
    let offset = Double(opt("--offset") ?? "") ?? 300_000
    let depth = Float(opt("--depth") ?? "") ?? 0.5
    let amp = Float(opt("--amp") ?? "") ?? 0.3
    let sigma = Float(opt("--noise") ?? "") ?? 0.003
    let fs = 2_400_000.0
    let up = Int(fs / rateIn)
    var phase = 0.0
    var out = Data(capacity: n * up * 2)
    var rng = SDRTestSignal.SplitMix(seed: 11)
    var buf = [UInt8](repeating: 0, count: 2 * up)
    for k in 0..<n {
        let x0 = pcm[k] / peak, x1 = k + 1 < n ? pcm[k + 1] / peak : x0
        for j in 0..<up {
            let x = x0 + (x1 - x0) * Float(j) / Float(up)
            phase += 2 * Double.pi * offset / fs
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            let env = amp * (1 + depth * x)
            let i = env * Float(cos(phase)) + sigma * rng.gauss()
            let q = env * Float(sin(phase)) + sigma * rng.gauss()
            buf[2 * j] = UInt8(max(0, min(255, (i * 127.5 + 127.5).rounded())))
            buf[2 * j + 1] = UInt8(max(0, min(255, (q * 127.5 + 127.5).rounded())))
        }
        out.append(contentsOf: buf)
    }
    FileManager.default.createFile(atPath: a[1], contents: out)
    print(String(format: "%.1f s Audio → AM-I/Q 2,4 MS/s, Träger %.0f Hz, Grad %.2f, %@", Double(n) / rateIn, offset, depth, a[1]))
}

/// Mehrere I/Q-Dateien (8 Bit) zu einem Fenster überlagern: mix <aus.cu8> <ein1.cu8> <ein2.cu8> … (kürzeste Datei bestimmt die Länge; Rauschen addiert sich)
func mix(_ a: [String]) {
    guard a.count >= 3 else { print("Aufruf: mix <aus.cu8> <ein1.cu8> <ein2.cu8> …"); exit(2) }
    let inputs = a.dropFirst().compactMap { FileManager.default.contents(atPath: $0) }
    guard inputs.count == a.count - 1, let length = inputs.map(\.count).min() else { print("Eingabe nicht lesbar"); exit(1) }
    var out = [UInt8](repeating: 0, count: length)
    for k in 0..<length {
        var sum = 0.0
        for d in inputs { sum += Double(d[d.startIndex + k]) - 127.5 }
        out[k] = UInt8(max(0, min(255, (sum + 127.5).rounded())))
    }
    FileManager.default.createFile(atPath: a[0], contents: Data(out))
    print(String(format: "%d Dateien überlagert, %.1f s → %@", inputs.count, Double(length / 2) / 2_400_000, a[0]))
}

/// Rechenlast der Kanalbank: bank <Kanäle> <Abtastrate> – wie viel schneller als Echtzeit die Engine n Kanäle über ein Fenster rechnet
func bankBench(_ a: [String]) {
    let n = Int(a.first ?? "") ?? 8
    let rate = Double(a.count > 1 ? a[1] : "") ?? 2_400_000
    let seconds = Double(ProcessInfo.processInfo.environment["SDRBENCH_SECONDS"] ?? "") ?? 4.0
    var sig = SDRTestSignal(sampleRate: rate, seconds: seconds)
    let half = rate * 0.35
    for k in 0..<n {
        let off = -half + 2 * half * (Double(k) + 0.5) / Double(n)
        sig.addFM(offsetHz: off, tone: 700 + 150 * Double(k), deviation: 3_000, amplitude: 0.05)
    }
    sig.addNoise(sigma: 0.003)
    let bytes = sig.quantized()
    let engine = SDRReceiverEngine(sampleRate: rate)
    engine.setPrimaryEnabled(false)
    var cfg = SDRChannelConfig(mode: .nfm); cfg.bandwidthHz = 12_500
    for k in 0..<n {
        let off = -half + 2 * half * (Double(k) + 0.5) / Double(n)
        engine.setExtraChannel(id: k, config: cfg, offsetHz: off, handler: { _ in })
    }
    let t0 = Date()
    bytes.withUnsafeBufferPointer { b in
        var i = 0
        while i < b.count { let e = min(i + 262_144, b.count); engine.feed(UnsafeBufferPointer(rebasing: b[i..<e]), wait: true); i = e }
    }
    while engine.extraChannelMetrics().isEmpty || engine.snapshot().droppedBlocks > 0 && false { Thread.sleep(forTimeInterval: 0.01) }
    // warten, bis der Rückstand abgearbeitet ist
    Thread.sleep(forTimeInterval: 0.05)
    while true {
        let before = engine.extraChannelMetrics().count
        Thread.sleep(forTimeInterval: 0.1)
        if before == engine.extraChannelMetrics().count { break }
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "%d Kanäle bei %.1f MS/s: %.1f s Signal in %.2f s gerechnet = %.1f-fach Echtzeit", n, rate / 1e6, seconds, dt, seconds / dt))
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "selftest": selftest()
case "file": fileMode(Array(args.dropFirst()))
case "fmmod": fmmod(Array(args.dropFirst()))
case "amod": amod(Array(args.dropFirst()))
case "mix": mix(Array(args.dropFirst()))
case "bank": bankBench(Array(args.dropFirst()))
case "gen": generate(args.count > 1 ? args[1] : "demo.cu8")
default: print("Aufruf: sdr_bench.sh selftest | file <aufnahme.cu8> <aus.wav> --rate R --offset O --mode M | fmmod | amod | mix"); exit(2)
}
