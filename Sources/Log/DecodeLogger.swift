import Foundation

/// Schreibt decodierten Text in Tagesdateien: `~/Documents/Digidec/Logs/RTTY-2026-09-30.txt` (UTC-Datum).
/// Vor dem ersten Text einer Sitzung oder nach geänderten Einstellungen steht eine Kopfzeile.
public final class DecodeLogger {
    public let directory: URL
    private let mode: String
    private var handle: FileHandle?
    private var openDay: String?
    private var pendingHeader: String?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(mode: String, directory: URL? = nil) {
        self.mode = mode
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/Logs", isDirectory: true)
    }

    deinit {
        try? handle?.close()
    }

    public func fileURL(for date: Date = Date()) -> URL {
        directory.appendingPathComponent("\(mode)-\(Self.dayFormat.string(from: date)).txt")
    }

    /// Kopfzeile, die vor dem nächsten Text geschrieben wird (z. B. „RTTY DWD LW · 50 Bd / 85 Hz · Mitte 1000 Hz“).
    public func markSession(_ description: String) {
        pendingHeader = description
    }

    public func append(_ text: String, now: Date = Date()) {
        guard !text.isEmpty else { return }
        let day = Self.dayFormat.string(from: now)
        if day != openDay {
            try? handle?.close()
            handle = nil
            openDay = nil
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = fileURL(for: now)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
                openDay = day
                if pendingHeader == nil { pendingHeader = "Fortsetzung" }
            } catch {
                return
            }
        }
        var out = ""
        if let header = pendingHeader {
            out += "\n=== \(Self.timeFormat.string(from: now)) UTC · \(header) ===\n"
            pendingHeader = nil
        }
        out += text
        try? handle?.write(contentsOf: Data(out.utf8))
    }

    public func close() {
        try? handle?.close()
        handle = nil
        openDay = nil
    }
}
