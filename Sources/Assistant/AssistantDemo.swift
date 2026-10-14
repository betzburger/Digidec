// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import CoreGraphics

// Entwicklungshilfe (nur zum Prüfen, wie die anderen DIGIDEC_…-Variablen): `DIGIDEC_ASSISTANT_DEMO=<Basisadresse>` legt ein künstliches
// FSK-Signal (170 Hz Shift, 7 Hz Auflösung nach Wasserfall) vor, sendet die Frage an den Server und schreibt das Gespräch nach
// `DIGIDEC_ASSISTANT_DUMP=<Datei>`. Die Einstellungen des Nutzers bleiben unberührt.
extension AssistantModel {
    func runDemo(baseURL: String, dumpPath: String?) {
        var seed: UInt64 = 7
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Double(seed >> 33) / Double(1 << 31)) - 0.5 }
        let n = 4096, binHz = 20.0, start = 10_000_000.0
        let rows: [[Float]] = (0..<220).map { i in
            var r = (0..<n).map { _ in -95 + 3 * rnd() }
            let b = (i / 3) % 2 == 0 ? 2000 : 2008
            for k in -1...1 { r[b + k] = max(r[b + k], -55 - 10 * Float(abs(k))) }
            return r
        }
        guard let m = SignalMeasure.analyze(rows: rows, startHz: start, binHz: binHz, targetHz: start + 2004 * binHz) else { return }
        let tuning = AssistantTuning(moduleName: "RTTY", frequencyHz: 10_040_000, mode: "USB", source: "SDR", utc: Date(), locator: nil)
        overrideConfig = LLMConfig(baseURL: baseURL, maxTokens: 4000, thinking: false)
        // Wasserfallbild wie im Empfänger: neueste Zeile oben, Farben aus der Wasserfall-Farbtabelle
        var pixels = [UInt32](repeating: 0, count: n * rows.count)
        let lut = WaterfallColorMap.lut
        for (y, row) in rows.enumerated() { for x in 0..<n { pixels[y * n + x] = lut[WaterfallColorMap.index(db: row[x], floorDB: -101, rangeDB: 55)] } }
        let cg = pixels.withUnsafeBufferPointer { buf -> CGImage? in
            guard let provider = CGDataProvider(data: Data(buffer: buf) as CFData) else { return nil }
            return CGImage(width: n, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        let png = cg.flatMap { AssistantWaterfallImage.png(from: $0, startHz: start, binHz: binHz, measurement: m) }
        if let path = ProcessInfo.processInfo.environment["DIGIDEC_ASSISTANT_IMAGE"], let png { try? png.write(to: URL(fileURLWithPath: path)) }
        stage(AssistantContextBuilder.signal(m, tuning: tuning, image: png))
        send()
        guard let dumpPath else { return }
        Task { @MainActor in
            while isBusy { try? await Task.sleep(nanoseconds: 500_000_000) }
            var out = turns.map { ($0.role == .user ? "DU: " : "KI: ") + ($0.role == .user ? $0.sent : $0.text) }.joined(separator: "\n\n")
            if let n = notice { out += "\n\nHINWEIS: " + n }
            try? out.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }
    }
}
