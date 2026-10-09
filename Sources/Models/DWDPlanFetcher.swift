// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import PDFKit

/// Fehler beim Abruf eines Sendeplans (Meldungen für die Anzeige)
public enum PlanFetchError: Error, LocalizedError, Equatable {
    case notPDF
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notPDF: return "Download ist kein PDF"
        case .network(let why): return why
        }
    }
}

/// Holt Seiten und PDFs von dwd.de – nur auf Knopfdruck, mit Zeitlimit und Größenbegrenzung
public enum DWDPlanFetcher {
    public static let maxBytes = 3_000_000

    public static func html(from url: URL) async throws -> String {
        let data = try await download(url)
        guard let text = String(data: data, encoding: .utf8) else { throw PlanFetchError.network("Seite nicht lesbar") }
        return text
    }

    /// Lädt ein PDF und gibt seinen Text zurück (alle Seiten)
    public static func pdfText(from url: URL) async throws -> String {
        let data = try await download(url)
        guard data.starts(with: Array("%PDF".utf8)), let doc = PDFDocument(data: data) else { throw PlanFetchError.notPDF }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Digidec", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PlanFetchError.network("Server antwortet nicht mit „OK“")
            }
            guard data.count <= maxBytes else { throw PlanFetchError.network("Antwort zu groß") }
            return data
        } catch let e as PlanFetchError {
            throw e
        } catch {
            throw PlanFetchError.network(error.localizedDescription)
        }
    }
}
