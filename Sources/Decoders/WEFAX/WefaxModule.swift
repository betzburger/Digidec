import Foundation
import Combine
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - Sender

/// Wetterfax-Sender. Angegeben ist die zugewiesene Frequenz (Mitte des Signals); Empfang in USB, Dial = Frequenz − NF-Mitte.
public enum WefaxStation: String, CaseIterable, Identifiable, Codable, Sendable {
    case dwd3855 = "dwd-3855"
    case dwd7880 = "dwd-7880"
    case dwd13882 = "dwd-13882"
    case custom = "custom"

    public var id: String { rawValue }

    public var frequencyHz: Double? {
        switch self {
        case .dwd3855: return 3_855_000
        case .dwd7880: return 7_880_000
        case .dwd13882: return 13_882_500
        case .custom: return nil
        }
    }

    public var label: String {
        switch self {
        case .dwd3855: return "3855"
        case .dwd7880: return "7880"
        case .dwd13882: return "13882,5"
        case .custom: return "Frei"
        }
    }

    public var note: String {
        switch self {
        case .dwd3855: return "DWD Nacht"
        case .dwd7880: return "DWD"
        case .dwd13882: return "DWD Tag"
        case .custom: return "eigene"
        }
    }

    /// DWD Pinneberg: IOC 576, 120 LPM; Hub 850 Hz laut Kommentar in fldigi (beim ersten Empfang prüfen)
    public var shiftHz: Int? {
        switch self {
        case .dwd3855, .dwd7880, .dwd13882: return 850
        case .custom: return nil
        }
    }

    /// Dial in USB für eine NF-Mitte
    public func usbDial(center: Double) -> Double? { frequencyHz.map { $0 - center } }
}

// MARK: - Einstellungen

@MainActor
public final class WefaxSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 1000...2500

    @Published public var station: WefaxStation { didSet { stationChanged(); save() } }
    @Published public var options: FldigiWefaxCore.Options { didSet { save() } }
    @Published public private(set) var manualCenterRevision = 0
    /// Kehrlage laut Funkgerät (rigctld): WEFAX braucht USB
    @Published public var rigIsLSB: Bool?

    public init() {
        let d = UserDefaults.standard
        station = d.string(forKey: "wefaxStation").flatMap(WefaxStation.init(rawValue:)) ?? .dwd7880
        options = d.data(forKey: "wefaxOptions").flatMap { try? JSONDecoder().decode(FldigiWefaxCore.Options.self, from: $0) }
            ?? Self.defaults(for: .dwd7880)
    }

    public static func defaults(for station: WefaxStation) -> FldigiWefaxCore.Options {
        var o = FldigiWefaxCore.Options()
        if let s = station.shiftHz { o.shiftHz = s }
        return o
    }

    public var centerHz: Double { Double(options.centerHz) }

    public func setCenter(_ hz: Double) {
        options.centerHz = Int(min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded())
        manualCenterRevision += 1
    }

    private func stationChanged() {
        if let s = station.shiftHz, options.shiftHz != s { options.shiftHz = s }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(station.rawValue, forKey: "wefaxStation")
        if let data = try? JSONEncoder().encode(options) { d.set(data, forKey: "wefaxOptions") }
    }
}

extension WefaxSettingsStore: TuningTarget {
    /// „Mark“ = Weiß (Mitte + Hub/2), „Space“ = Schwarz
    public var tones: (mark: Double, space: Double) {
        (centerHz + Double(options.shiftHz) / 2, centerHz - Double(options.shiftHz) / 2)
    }
    public var markerBandwidth: Double { Double(options.shiftHz) + 200 }
}

// MARK: - Decoder

/// WEFAX-Kern als 11 025-Hz-Senke an der Pipeline (Verarbeitungs-Queue)
public final class WefaxDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var status: FldigiWefaxCore.Status?
        public var saved: [WefaxImage]
        /// neues Bild für die Anzeige, falls es sich geändert hat
        public var live: (pixels: [UInt8], width: Int, rows: Int)?
    }

    private let pipeline: AudioPipeline
    private var core: FldigiWefaxCore?
    private var enabled = false
    private var samplesSinceCopy = 0
    private var copiedRevision: UInt32 = .max

    private let lock = OSAllocatedUnfairLock()
    private var pendingSaved: [WefaxImage] = []
    private var lastStatus: FldigiWefaxCore.Status?
    private var pendingLive: (pixels: [UInt8], width: Int, rows: Int)?

    /// Wie oft das Bild für die Anzeige kopiert wird (Samples bei 11 025 Hz)
    public var copyInterval = 5512

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: FldigiWefaxCore.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(options: FldigiWefaxCore.Options) {
        pipeline.perform { [self] in
            if let core, !FldigiWefaxCore.needsRecreate(core.options, options) {
                if core.options != options { core.configure(options) }
            } else {
                core = nil   // erst das alte Exemplar freigeben (fldigis Hub ist dateiweit)
                core = FldigiWefaxCore(options: options) { [weak self] img in
                    self?.lock.withLockUnchecked { self?.pendingSaved.append(img) }
                }
                copiedRevision = .max
            }
        }
    }

    public func setRF(_ hz: Int64?) {
        pipeline.perform { [self] in core?.setRF(hz ?? 0) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in enabled = on }
    }

    /// Knöpfe: auf der Verarbeitungs-Queue, damit sie nicht mitten in einen Block fallen
    public func perform(_ action: @escaping @Sendable (FldigiWefaxCore) -> Void) {
        pipeline.perform { [self] in
            if let core { action(core) }
            samplesSinceCopy = copyInterval   // Anzeige sofort auffrischen
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer {
                pendingSaved.removeAll()
                pendingLive = nil
            }
            return Output(status: lastStatus, saved: pendingSaved, live: pendingLive)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let core else { return }
        core.process(samples)
        let status = core.status
        samplesSinceCopy += samples.count
        var live: (pixels: [UInt8], width: Int, rows: Int)?
        if samplesSinceCopy >= copyInterval, status.revision != copiedRevision {
            samplesSinceCopy = 0
            copiedRevision = status.revision
            live = core.copyImage()
        }
        lock.withLockUnchecked {
            lastStatus = status
            if let live { pendingLive = live }
        }
    }
}

// MARK: - Controller

/// Verbindet WEFAX-Einstellungen, Decoder, Bildanzeige und Ablage der Bilder
@MainActor
public final class WefaxController: ObservableObject {
    public let decoder: WefaxDecoder
    @Published public private(set) var status: FldigiWefaxCore.Status?
    /// laufendes Bild
    @Published public private(set) var liveImage: CGImage?
    @Published public private(set) var liveRows = 0
    /// zuletzt gespeicherte Bilder, neuestes zuerst
    @Published public private(set) var gallery: [WefaxImage] = []
    @Published public var autoSave: Bool {
        didSet { UserDefaults.standard.set(autoSave, forKey: "wefaxAutoSave") }
    }
    @Published public private(set) var lastSaveError: String?
    /// Titel der gerade aufgenommenen Sendung laut Sendeplan; wird dem Dateinamen und der PNG-Beschreibung angehängt
    public var scheduledLabel: String?

    public static let maxGallery = 30
    public let directory: URL
    private let settings: WefaxSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appliedOptions: FldigiWefaxCore.Options?

    public init(pipeline: AudioPipeline, settings: WefaxSettingsStore, directory: URL? = nil) {
        self.settings = settings
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/WEFAX", isDirectory: true)
        decoder = WefaxDecoder(pipeline: pipeline)
        autoSave = UserDefaults.standard.object(forKey: "wefaxAutoSave") as? Bool ?? true
        appliedOptions = settings.options
        decoder.configure(options: settings.options)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public var rigFrequencyHz: Int64? {
        didSet { if rigFrequencyHz != oldValue { decoder.setRF(rigFrequencyHz) } }
    }

    // Knöpfe wie in fldigis Empfangsfenster
    public func skipAPT() { decoder.perform { $0.skipAPT() } }
    public func skipPhasing() { decoder.perform { $0.skipPhasing() } }
    public func abort() { decoder.perform { $0.abort() } }
    public func setNonStop(_ on: Bool) { decoder.perform { $0.setManual(on) } }
    public func saveNow() { decoder.perform { $0.save() } }

    public func removeFromGallery(_ img: WefaxImage) {
        gallery.removeAll { $0.id == img.id }
    }

    /// Lädt ein gespeichertes Bild (PNG/JPEG) zum Bearbeiten; wird nicht in die Galerie eingetragen.
    public func openImage(url: URL) -> WefaxImage? {
        guard let g = WefaxImageTools.load(url: url) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return WefaxImage(name: url.lastPathComponent, comments: "", width: g.width, height: g.height, pixels: g.pixels,
                          receivedAt: date, fileURL: url)
    }

    /// Speichert das um `shift` Pixel verschobene Bild (Umlauf).
    /// - Parameter replaceOriginal: `true` ersetzt die Datei (das Original bleibt einmalig als `…_original.png` erhalten),
    ///   `false` legt eine neue Datei `…_korr.png` daneben.
    /// - Returns: das gespeicherte Bild (steht danach vorn in der Galerie)
    @discardableResult
    public func saveEdited(_ img: WefaxImage, shift: Int, replaceOriginal: Bool) throws -> WefaxImage {
        var out = img
        out.pixels = WefaxImageTools.shifted(img.pixels, width: img.width, height: img.height, by: shift)
        out.comments += (img.comments.isEmpty ? "" : "\n") + "Bearbeitet: um \(shift) Pixel horizontal verschoben"
        let dir = img.fileURL?.deletingLastPathComponent() ?? directory
        let base = (img.name as NSString).deletingPathExtension
        if replaceOriginal {
            if let original = img.fileURL, FileManager.default.fileExists(atPath: original.path) {
                let backup = dir.appendingPathComponent(base + "_original.png")
                if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: original, to: backup) }
            }
            out.name = img.name
        } else {
            out.name = base.hasSuffix("_korr") ? img.name : base + "_korr.png"
        }
        out.fileURL = try Self.writePNG(out, to: dir)
        let edited = WefaxImage(name: out.name, comments: out.comments, width: out.width, height: out.height, pixels: out.pixels,
                                receivedAt: img.receivedAt, fileURL: out.fileURL)
        if replaceOriginal, let i = gallery.firstIndex(where: { $0.id == img.id }) {
            gallery[i] = edited
        } else {
            gallery.insert(edited, at: 0)
            if gallery.count > Self.maxGallery { gallery.removeLast(gallery.count - Self.maxGallery) }
        }
        return edited
    }

    /// receive(on:) liefert nach der Änderung (wie bei RTTY/NAVTEX/CW)
    private func settingsChanged() {
        let o = settings.options
        if o != appliedOptions {
            appliedOptions = o
            decoder.configure(options: o)
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        if let s = out.status { status = s }
        if let live = out.live {
            liveRows = live.rows
            liveImage = Self.cgImage(pixels: live.pixels, width: live.width, height: live.rows)
        }
        for var img in out.saved {
            if let label = scheduledLabel {
                let slug = Self.fileSlug(label)
                if let dot = img.name.lastIndex(of: ".") {
                    img.name = String(img.name[img.name.startIndex..<dot]) + "_" + slug + String(img.name[dot...])
                }
                img.comments += "\nSendeplan: \(label)"
            }
            if autoSave {
                do {
                    img.fileURL = try Self.writePNG(img, to: directory)
                    lastSaveError = nil
                } catch {
                    lastSaveError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
                }
            }
            gallery.insert(img, at: 0)
            if gallery.count > Self.maxGallery { gallery.removeLast(gallery.count - Self.maxGallery) }
        }
    }

    // MARK: Bilder

    /// Dateinamenbaustein aus einem Kartentitel: ASCII, Umlaute aufgelöst, höchstens 40 Zeichen
    nonisolated public static func fileSlug(_ title: String) -> String {
        let mapped = title.replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "Ä", with: "Ae")
            .replacingOccurrences(of: "Ö", with: "Oe").replacingOccurrences(of: "Ü", with: "Ue")
            .replacingOccurrences(of: "ß", with: "ss")
        let ascii = mapped.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let collapsed = ascii.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(40))
    }

    nonisolated public static func cgImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        let data = Data(pixels.prefix(width * height)) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG mit fldigis Kommentaren als Beschreibung
    nonisolated public static func writePNG(_ img: WefaxImage, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(img.name)
        guard let cg = cgImage(pixels: img.pixels, width: img.width, height: img.height),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let props: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: img.comments]]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
