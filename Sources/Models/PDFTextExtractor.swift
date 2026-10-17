// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Text aller Seiten eines PDF (PDFKit unter macOS, `pdftotext` aus poppler unter Linux)
enum PDFTextExtractor {
    static func text(from data: Data) -> String? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data) else { return nil }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pdftotext", "-enc", "UTF-8", "-", "-"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Eingabe auf eigenem Faden schreiben, damit große Dateien nicht an vollen Rohren hängen bleiben
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // pdftotext trennt Seiten mit Seitenvorschub
        return String(decoding: result, as: UTF8.self).replacingOccurrences(of: "\u{0C}", with: "\n")
        #endif
    }
}
