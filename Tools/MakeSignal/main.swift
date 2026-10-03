// make_signal: erzeugt Testsignale (WAV, 16 Bit mono) aus Skriptdateien.
//
//   acars <skript> <aus.wav>   Zeilen: <Sekunde>|<Kennzeichen>|<Flug>|<Label>|<Text>   (\n im Text = Zeilenumbruch, # = Kommentar)
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
    print("Aufruf: make_signal.sh acars <skript.txt> <aus.wav> [--noise <Amplitude>]")
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
default:
    print("Unbekannte Art: \(args[0])")
    exit(2)
}
