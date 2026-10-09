// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.firstIndex(of: n).map { args.remove(at: $0) } != nil }
func option(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}

func loadSamples(_ path: String, signed: Bool) -> [UInt8] {
    guard var data = FileManager.default.contents(atPath: path) else { print("FEHLER: \(path) nicht lesbar"); exit(1) }
    if signed { data.withUnsafeMutableBytes { raw in for i in 0..<raw.count { raw[i] ^= 0x80 } } }
    return [UInt8](data)
}

func fic(_ path: String, signed: Bool, invert: Bool, outPath: String?) {
    let bytes = loadSamples(path, signed: signed)
    let rx = DABOFDMReceiver()
    let fic = DABFICDecoder(positiveIsOne: !invert)
    var fibs = Data()
    var syncs = 0
    rx.onSyncChange = { s in if s { syncs += 1 } }
    rx.onSymbol = { k, bits in fic.process(symbol: k, bits: bits) }
    let ensemble = DABEnsemble()
    fic.onFIB = { fib, _ in fibs.append(contentsOf: fib); ensemble.process(fib: fib) }
    let t0 = Date()
    bytes.withUnsafeBufferPointer { b in
        var i = 0
        while i < b.count {
            let e = min(i + 262_144, b.count)
            rx.process(UnsafeBufferPointer(rebasing: b[i..<e]))
            i = e
        }
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "Rahmen %d, Synchronisationen %d, SNR %.1f dB, Grob %.0f Hz, Fein %.0f Hz, Takt %.1f ppm", rx.frameCount, syncs, rx.snrDB, rx.coarseHz, rx.fineHz, rx.clockOffsetPPM))
    let total = fic.fibsGood + fic.fibsBad
    print(String(format: "FIB mit gültiger CRC: %d von %d (%.1f %%), Rechenzeit %.2f s für %.1f s Signal", fic.fibsGood, total, total > 0 ? 100 * Double(fic.fibsGood) / Double(total) : 0, dt, Double(bytes.count / 2) / 2_048_000))
    print(String(format: "Ensemble: \"%@\" (EId %04X), %d Dienste, %d Teilkanäle", ensemble.label, ensemble.ensembleId, ensemble.serviceList.count, ensemble.subchannels.count))
    if let t = ensemble.time { print("Zeit des Senders: \(t)") }
    for s in ensemble.serviceList {
        let sub = ensemble.subchannel(of: s)
        print(String(format: "  %08X  %-18@ %@  Teilkanal %@  %@ kbit/s  %@", s.sid, s.label, s.isDABPlus ? "DAB+" : "DAB ", sub.map { String($0.id) } ?? "–", sub.map { String($0.bitrate) } ?? "–", sub?.protectionText ?? ""))
    }
    if let outPath { try? fibs.write(to: URL(fileURLWithPath: outPath)) }
}

/// Teilkanal decodieren (nach Kennung oder Dienstname) und Zugriffseinheiten zählen; mit --au-out <datei> werden sie hintereinander geschrieben (je mit zwei Byte Länge)
func msc(_ path: String, signed: Bool, service: String, auOut: String?) {
    let bytes = loadSamples(path, signed: signed)
    let rx = DABOFDMReceiver()
    let fic = DABFICDecoder()
    let cif = DABCIFAssembler()
    let ensemble = DABEnsemble()
    var decoder: DABSubchannelDecoder?
    let sf = DABSuperframeDecoder()
    var frames = 0, auCount = 0
    var auData = Data()
    var lastFormat: DABAudioFormat?
    sf.onFormat = { f in lastFormat = f; print("Format: \(f.codecName) \(f.channelsText), Kern \(f.coreRate) Hz, Ausgabe \(f.outputRate) Hz") }
    var aac: DABAACDecoder?
    var pcm = [Float]()
    var aacStatus = ""
    let pad = DABPADDecoder()
    pad.onLabel = { t in print("Dynamic Label: \"\(t)\"") }
    sf.onAU = { au, f in
        pad.process(accessUnit: au)
        if aac == nil && aacStatus.isEmpty { do { aac = try DABAACDecoder(format: f); aacStatus = "AudioToolbox-Decoder angelegt" } catch { aacStatus = "AudioToolbox-Fehler: \(error)" } }
        if let a = aac { let out = a.decode(au); pcm.append(contentsOf: out); if auCount < 3 { print("AU \(auCount): \(au.count) Byte → \(out.count) Werte") } }
        auCount += 1
        auData.append(UInt8(au.count >> 8)); auData.append(UInt8(au.count & 255)); auData.append(contentsOf: au)
    }
    fic.onFIB = { fib, _ in ensemble.process(fib: fib) }
    rx.onSymbol = { k, bits in
        if k <= 3 { fic.process(symbol: k, bits: bits) } else { cif.process(symbol: k, bits: bits) }
    }
    cif.onCIF = { c in
        if decoder == nil, let s = ensemble.serviceList.first(where: { $0.label.lowercased().contains(service.lowercased()) }), let sub = ensemble.subchannel(of: s) {
            decoder = DABSubchannelDecoder(subchannel: sub)
            decoder?.onFrame = { f in frames += 1; sf.feed(frame: f) }
            print("Dienst: \(s.label) → Teilkanal \(sub.id), Start \(sub.startAddress), Länge \(sub.length) CU, \(sub.bitrate) kbit/s, \(sub.protectionText)")
        }
        decoder?.process(cif: c)
    }
    bytes.withUnsafeBufferPointer { b in
        var i = 0
        while i < b.count { let e = min(i + 262_144, b.count); rx.process(UnsafeBufferPointer(rebasing: b[i..<e])); i = e }
    }
    print("Teilkanal-Rahmen \(frames), Überrahmen \(sf.superframes) mit Takt, korrigierte Bytes \(sf.correctedBytes), nicht korrigierbar \(sf.uncorrectable), AU mit falscher CRC \(sf.badAUs), gültige AU \(auCount)")
    print(aacStatus, "PCM-Werte:", pcm.count, aac.map { "Kanäle \($0.outputChannels)" } ?? "")
    if let wav = option("--wav"), let a = aac {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let ch = UInt16(a.outputChannels), rate = UInt32(a.format.outputRate)
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count * 2)); data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(ch); u32(rate); u32(rate * UInt32(ch) * 2); u16(ch * 2); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(pcm.count * 2))
        for x in pcm { u16(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32000))) }
        try? data.write(to: URL(fileURLWithPath: wav))
        print("WAV geschrieben: \(wav)")
    }
    if let auOut { try? auData.write(to: URL(fileURLWithPath: auOut)) }
    _ = lastFormat
}

let signed = flag("--signed")
let invert = flag("--invert")
let outPath = option("--out")
guard let mode = args.first else { print("Aufruf: dab_bench.sh fic <aufnahme.raw> [--signed] [--invert] [--out fib.bin]"); exit(2) }
switch mode {
case "selftest":
    setvbuf(stdout, nil, _IONBF, 0)
    var fails = 0
    dabSelfTests { ok, text in print((ok ? "  ok     " : "  FEHLER ") + text); if !ok { fails += 1 } }
    let real = FileManager.default.currentDirectoryPath + "/TestData/DAB/dab_11D_2048k.raw"
    if !dabRecordingTest(path: real, { ok, text in print((ok ? "  ok     " : "  FEHLER ") + text); if !ok { fails += 1 } }) { print("  übersprungen: \(real) liegt nicht lokal vor") }
    print(fails == 0 ? "ALLE PRÜFUNGEN BESTANDEN" : "\(fails) FEHLER")
    exit(fails == 0 ? 0 : 1)
case "msc": msc(args[1], signed: signed, service: args.count > 2 ? args[2] : "", auOut: option("--au-out"))
case "fic": fic(args[1], signed: signed, invert: invert, outPath: outPath)
default: print("unbekannt: \(mode)"); exit(2)
}
