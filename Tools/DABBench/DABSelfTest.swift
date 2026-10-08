// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Prüfungen des DAB-Empfängers ohne Aufnahme (gemeinsam für den Prüfstand und die Logiktests)
func dabSelfTests(_ check: (Bool, String) -> Void) {
    // CRC und Feuercode
    let crcTest = DABCRC.crc16(Array("123456789".utf8))
    check(crcTest == ~UInt16(0x29B1), "DAB: CRC-16 (CCITT, invertiert) von „123456789“ = \(String(crcTest, radix: 16))")
    // Faltungscode, Punktierung und Viterbi: FIC-Codewort mit Bitfehlern
    var rng = SystemRandomNumberGenerator()
    let fibs: [[UInt8]] = (0..<3).map { _ in (0..<30).map { _ in UInt8.random(in: 0...255, using: &rng) } }
    let coded = DABTestEncoder.ficCodeword(fibs: fibs)
    check(coded.count == 2304, "DAB: FIC-Codewort hat 2304 Bits (\(coded.count))")
    func ficRun(errors: Int) -> [[UInt8]] {
        var soft = DABTestEncoder.soft(coded)
        // Bitfehler an zufälligen Stellen
        var positions = Set<Int>()
        while positions.count < errors { positions.insert(Int.random(in: 0..<2304, using: &rng)) }
        for p in positions { soft[p] = -soft[p] }
        var got = [[UInt8]]()
        let dec = DABFICDecoder()
        dec.onFIB = { fib, _ in got.append(fib) }
        // Symbole 1 bis 3 tragen vier Codewörter: dasselbe Wort viermal
        let all = soft + soft + soft + soft
        for s in 0..<3 {
            let part = Array(all[(s * 3072)..<((s + 1) * 3072)])
            part.withUnsafeBufferPointer { dec.process(symbol: s + 1, bits: $0) }
        }
        return got
    }
    let clean = ficRun(errors: 0)
    check(clean.count == 12 && clean.prefix(3).elementsEqual(fibs), "DAB: FIC ohne Fehler: zwölf FIB, Inhalt gleich (\(clean.count))")
    let noisy = ficRun(errors: 60)
    check(noisy.count == 12 && noisy.prefix(3).elementsEqual(fibs), "DAB: FIC mit 60 falschen Bits je Codewort (2,6 %) trotzdem fehlerfrei (\(noisy.count) FIB)")
    // Schutzprofile: die entpunktierte Länge muss dem Teilkanal entsprechen (prüft die Tabellen)
    var profileProblems = [String]()
    var rejected = [Int]()
    for ix in 0..<DABTables.uepIndex.count {
        let e = DABTables.uepIndex[ix]
        let sub = DABSubchannel(id: 0, startAddress: 0, length: e.cu, protection: .uep(tableIndex: ix))
        if DABProtectionDecoder(subchannel: sub) == nil { rejected.append(ix) }
    }
    // Vier Tabellenzeilen der Quellen (32 kbit/s Stufe 1, 48/3, 56/2, 64/2) ergeben nicht die Länge des Teilkanals: sie werden abgelehnt
    // Bei 21 der 64 Zeilen der UEP-Tabelle (alte DAB-Dienste mit MPEG Layer II) passt die Entpunktierung nicht auf die Länge des Teilkanals (Abweichung 4 oder 8 Bits,
    // bei Index 23 ein Tippfehler der Quelle): diese Kombinationen werden nicht decodiert. DAB+ nutzt den gleichen Fehlerschutz (EEP) und ist nicht betroffen.
    check(rejected == [4, 7, 13, 17, 18, 22, 23, 26, 32, 35, 37, 46, 48, 52, 54, 56, 57, 58, 59, 62, 63], "DAB: UEP-Tabelle: abgelehnte Zeilen \(rejected)")
    for b in [false, true] {
        for level in 1...4 {
            let n = b ? [32, 64, 96, 128, 192, 256] : [8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 96, 128, 144, 192, 256, 320]
            for rate in n {
                let size: Int
                if b { size = rate / 32 * [27, 21, 18, 15][level - 1] } else { size = rate / 8 * [12, 8, 6, 4][level - 1] }
                let sub = DABSubchannel(id: 0, startAddress: 0, length: size, protection: .eep(profileB: b, level: level))
                if sub.bitrate != rate { profileProblems.append("EEP \(level)-\(b ? "B" : "A") \(rate): Rate \(sub.bitrate)"); continue }
                if DABProtectionDecoder(subchannel: sub) == nil { profileProblems.append("EEP \(level)-\(b ? "B" : "A") \(rate)") }
            }
        }
    }
    check(profileProblems.isEmpty, "DAB: alle Schutzprofile EEP A und B entpunktieren auf genau die Länge des Teilkanals \(profileProblems.prefix(4))")
    // Reed-Solomon
    let rs = DABReedSolomon()
    let payload = (0..<110).map { _ in UInt8.random(in: 0...255, using: &rng) }
    let word = DABTestEncoder.rsEncode(payload)
    var w0 = word
    check(rs.decode(&w0) == 0 && w0 == word, "DAB: Reed-Solomon erkennt ein fehlerfreies Wort")
    var w5 = word
    for p in [3, 19, 44, 100, 118] { w5[p] ^= UInt8.random(in: 1...255, using: &rng) }
    check(rs.decode(&w5) == 5 && w5 == word, "DAB: Reed-Solomon korrigiert fünf Byte (auch in den Prüfbytes)")
    var w6 = word
    for p in [1, 2, 30, 50, 90, 111] { w6[p] ^= 0x55 }
    check(rs.decode(&w6) == -1, "DAB: sechs Fehler sind nicht korrigierbar")
    // Überrahmen: Feuercode, Reed-Solomon, Aufteilung in Zugriffseinheiten
    for bitrate in [72, 96, 144] {
        let auLength = (15 * bitrate / 120 * 110 - 6) / 3 - 2
        let aus: [[UInt8]] = (0..<3).map { _ in (0..<auLength).map { _ in UInt8.random(in: 0...255, using: &rng) } }
        var sf = DABTestEncoder.superframe(bitrate: bitrate, aus: aus)
        // je Reed-Solomon-Block bis zu fünf Bytefehler
        let blocks = sf.count / 120
        for i in 0..<blocks { for _ in 0..<4 { sf[Int.random(in: 0..<120, using: &rng) * blocks + i] ^= UInt8.random(in: 1...255, using: &rng) } }
        let dec = DABSuperframeDecoder()
        var got = [[UInt8]]()
        dec.onAU = { au, _ in got.append(au) }
        let frameLength = sf.count / 5
        for f in 0..<5 { dec.feed(frame: Array(sf[(f * frameLength)..<((f + 1) * frameLength)])) }
        check(got == aus && dec.isSynced && dec.badAUs == 0, "DAB+: Überrahmen mit \(bitrate) kbit/s: drei Zugriffseinheiten nach Fehlerkorrektur (\(got.count), korrigiert \(dec.correctedBytes))")
        if bitrate == 96 {
            // falsch ausgerichtete Rahmen: der Decoder rastet nach dem nächsten Überrahmen ein
            let dec2 = DABSuperframeDecoder()
            var got2 = [[UInt8]]()
            dec2.onAU = { au, _ in got2.append(au) }
            let junk = (0..<frameLength).map { _ in UInt8.random(in: 0...255, using: &rng) }
            for _ in 0..<2 { dec2.feed(frame: junk) }
            for round in 0..<2 { for f in 0..<5 { dec2.feed(frame: Array(sf[(f * frameLength)..<((f + 1) * frameLength)])); _ = round } }
            check(got2.count >= 3 && dec2.isSynced, "DAB+: Überrahmen-Takt nach vorgeschalteten Fremdrahmen gefunden")
        }
    }
    // FIG: Ensemble, Dienst, Teilkanal, Namen
    let ensemble = DABEnsemble()
    let fibs3 = [
        DABTestEncoder.fib(figs: [DABTestEncoder.fig0_1(subchannel: 5, start: 100, profileB: true, level: 1, size: 81), DABTestEncoder.fig0_2(sid: 0xD312, subchannel: 5, audioType: 63)]),
        DABTestEncoder.fib(figs: [DABTestEncoder.fig1(extension: 0, id: 0x10A5, label: "Testgruppe")]),
        DABTestEncoder.fib(figs: [DABTestEncoder.fig1(extension: 1, id: 0xD312, label: "Testsender")]),
    ]
    for _ in 0..<2 { for f in fibs3 { ensemble.process(fib: f) } }           // Dienste zählen erst nach zweimaligem Empfang
    check(ensemble.label == "Testgruppe", "DAB: Ensemble-Name aus FIG 1/0")
    check(ensemble.serviceList.count == 1 && ensemble.serviceList[0].label == "Testsender" && ensemble.serviceList[0].isDABPlus, "DAB: Dienst mit Namen und DAB+-Kennzeichnung")
    let sub = ensemble.serviceList.first.flatMap { ensemble.subchannel(of: $0) }
    check(sub?.id == 5 && sub?.startAddress == 100 && sub?.length == 81 && sub?.bitrate == 96 && sub?.protection == .eep(profileB: true, level: 1), "DAB: Teilkanal aus FIG 0/1 (EEP 1-B, 96 kbit/s)")
    // Zeichensatz EBU Latin
    check(DABCharset.decode([0x57, 0x97, 0x72, 0x7A, 0x62, 0x75, 0x72, 0x67], charset: 0) == "Wörzburg" && DABCharset.decode([0x99, 0x89], charset: 0) == "üù", "DAB: EBU-Latin-Umlaute")
    // Dynamic Label (PAD)
    let text = Array("Hallo DAB".utf8)
    var group: [UInt8] = [0x80 | 0x40 | 0x20 | UInt8(text.count - 1), 0x00] + text
    let gcrc = DABCRC.crc16(group)
    group += [UInt8(gcrc >> 8), UInt8(gcrc & 0xFF)]
    while group.count < 16 { group.append(0) }
    let logical: [UInt8] = [UInt8(4 << 5) | 2, 0x00] + group              // Längenindex 4 = 16 Byte, Typ 2 = Dynamic Label, Endemarke
    let pad = DABPADDecoder()
    var labels = [String]()
    pad.onLabel = { labels.append($0) }
    var au: [UInt8] = [UInt8(4 << 5), UInt8(logical.count + 2)] + Array(logical.reversed()) + [0x20, 0x02]
    au += [0, 0, 0]
    pad.process(accessUnit: au)
    check(labels == ["Hallo DAB"], "DAB+: Dynamic Label aus dem PAD der Zugriffseinheit (\(labels))")
}

/// Prüfung an einer echten Aufnahme (HackRF, 2,048 MS/s, vorzeichenbehaftete Bytes, 12 s, Block 11D „Bayern“); `nil` = Datei fehlt
func dabRecordingTest(path: String, _ check: (Bool, String) -> Void) -> Bool {
    guard var data = FileManager.default.contents(atPath: path) else { return false }
    data.withUnsafeMutableBytes { raw in for i in 0..<raw.count { raw[i] ^= 0x80 } }
    let rx = DABOFDMReceiver()
    let fic = DABFICDecoder()
    let cif = DABCIFAssembler()
    let ensemble = DABEnsemble()
    var decoder: DABSubchannelDecoder?
    let sf = DABSuperframeDecoder()
    var aus = 0
    var format: DABAudioFormat?
    sf.onFormat = { format = $0 }
    sf.onAU = { _, _ in aus += 1 }
    fic.onFIB = { fib, _ in ensemble.process(fib: fib) }
    rx.onSymbol = { k, bits in if k <= 3 { fic.process(symbol: k, bits: bits) } else { cif.process(symbol: k, bits: bits) } }
    cif.onCIF = { c in
        if decoder == nil, let s = ensemble.serviceList.first(where: { $0.label == "Bayern 2" }), let sub = ensemble.subchannel(of: s) {
            decoder = DABSubchannelDecoder(subchannel: sub)
            decoder?.onFrame = { sf.feed(frame: $0) }
        }
        decoder?.process(cif: c)
    }
    data.withUnsafeBytes { raw in
        let b = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i < b.count { let e = min(i + 262_144, b.count); rx.process(UnsafeBufferPointer(rebasing: b[i..<e])); i = e }
    }
    check(rx.frameCount >= 120 && rx.frameCount <= 125, "DAB echt: 12 s Aufnahme ergeben etwa 125 Rahmen von 96 ms (\(rx.frameCount))")
    check(fic.fibsGood == fic.fibsBad + fic.fibsGood && fic.fibsGood >= 1400, "DAB echt: alle Informationsblöcke des FIC mit gültiger CRC (\(fic.fibsGood) von \(fic.fibsGood + fic.fibsBad))")
    check(ensemble.label == "Bayern" && ensemble.serviceList.count >= 9 && ensemble.serviceList.contains { $0.label == "BR24" && $0.isDABPlus }, "DAB echt: Ensemble „Bayern“ mit \(ensemble.serviceList.count) Diensten")
    check(sf.syncedSuperframes >= 85 && sf.badAUs == 0 && aus >= 255, "DAB echt: Bayern 2 (HE-AAC): \(sf.syncedSuperframes) Überrahmen, \(aus) Zugriffseinheiten, \(sf.badAUs) falsche CRC")
    check(format?.sbr == true && format?.stereo == true && format?.outputRate == 48_000, "DAB echt: Format HE-AAC Stereo 48 kHz")
    return true
}

/// Block-Größen: dieselbe Aufnahme in sehr kleinen, sehr großen und wechselnden Blöcken (SDRplay liefert andere Blöcke als HackRF) darf nie
/// abstürzen und muss ungefähr gleich viele Rahmen ergeben. `nil` = Datei fehlt
func dabChunkingTest(path: String, _ check: (Bool, String) -> Void) -> Bool {
    guard var data = FileManager.default.contents(atPath: path) else { return false }
    data.withUnsafeMutableBytes { raw in for i in 0..<raw.count { raw[i] ^= 0x80 } }
    for (name, sizes) in [("1 MB", [1_048_576]), ("4 kB", [4_096]), ("wechselnd", [2_000, 700_000, 64, 3_000_000, 130_000, 9_000])] {
        let rx = DABOFDMReceiver()
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0, k = 0
            while i < b.count {
                let e = min(i + sizes[k % sizes.count], b.count)
                rx.process(UnsafeBufferPointer(rebasing: b[i..<e]))
                i = e; k += 1
            }
        }
        check(rx.frameCount >= 100 && rx.frameCount <= 125, "DAB echt: Blockgröße \(name): \(rx.frameCount) Rahmen ohne Absturz")
    }
    return true
}
