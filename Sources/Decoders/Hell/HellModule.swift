import Foundation
import Combine
import SwiftUI
import AppKit
import os

// MARK: - Raster

/// Der empfangene Hell-Text als Bild: Rasterspalten laufen von links nach rechts, am Zeilenende beginnt eine neue Zeile.
/// Jede Zeile ist 2 · Spaltenlänge Pixel hoch (vorherige und aktuelle Spalte: Hell hat keinen Zeilengleichlauf, die Schrift
/// erscheint je nach Phase in der oberen oder unteren Hälfte).
@MainActor
public final class HellRasterModel: ObservableObject {
    public static let lineWidth = 720
    public static let maxLines = 24

    @Published public private(set) var image: NSImage?
    @Published public private(set) var columnCount = 0

    private var lines: [[UInt8]] = []          // je Zeile: Breite · Höhe Bytes, zeilenweise von oben
    private var rowHeight = 0
    private var column = 0
    private var dirty = false
    private var white: UInt8 = 255

    public init() {}

    public func clear() {
        lines.removeAll()
        column = 0
        columnCount = 0
        image = nil
        dirty = false
    }

    /// Eine Spalte (2 · Spaltenlänge Werte, Wert 0 des Feldes = unterste Zeile) anhängen
    public func append(column values: [UInt8], background: UInt8) {
        guard !values.isEmpty else { return }
        if values.count != rowHeight {
            // Spaltenlänge wurde geändert: Bild neu beginnen
            lines.removeAll()
            column = 0
            rowHeight = values.count
        }
        white = background
        if lines.isEmpty || column >= Self.lineWidth {
            lines.append([UInt8](repeating: background, count: Self.lineWidth * rowHeight))
            if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            column = 0
        }
        let li = lines.count - 1
        for i in 0..<rowHeight {
            lines[li][(rowHeight - 1 - i) * Self.lineWidth + column] = values[i]
        }
        column += 1
        columnCount += 1
        dirty = true
    }

    /// Bild neu zeichnen, wenn sich etwas geändert hat (vom Controller im Takt aufgerufen)
    public func refresh() {
        guard dirty, rowHeight > 0, !lines.isEmpty else { return }
        dirty = false
        let gap = 3
        let w = Self.lineWidth
        let h = lines.count * (rowHeight + gap) - gap
        var pixels = [UInt8](repeating: 128, count: w * h)
        for (n, line) in lines.enumerated() {
            let top = n * (rowHeight + gap)
            for y in 0..<rowHeight {
                let src = y * w, dst = (top + y) * w
                for x in 0..<w { pixels[dst + x] = line[src + x] }
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        image = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// Das Bild als PNG (für „Speichern“)
    public func pngData() -> Data? {
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Einstellungen

/// Einstellungen des Hell-Moduls. Mitte = Mittenfrequenz des Signals im NF.
@MainActor
public final class HellSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 300...3500

    @Published public private(set) var centerHz: Double
    /// Wird bei jedem Setzen von Hand erhöht, damit der Decoder die Mitte übernimmt
    @Published public private(set) var manualCenterRevision = 0
    @Published public var options: FldigiHellCore.Options { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "hellCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1500
        options = d.data(forKey: "hellOptions").flatMap { try? JSONDecoder().decode(FldigiHellCore.Options.self, from: $0) }
            ?? FldigiHellCore.Options()
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "hellCenterHz")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: "hellOptions")
        }
    }
}

extension HellSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    public var markerBandwidth: Double { options.mode.bandwidthHz }
}

// MARK: - Decoder

/// Hell-Kern als 8-kHz-Senke an der Pipeline (Verarbeitungs-Queue)
public final class HellDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var columns: [[UInt8]]
        public var status: FldigiHellCore.Status?
    }

    private let pipeline: AudioPipeline
    private var core: FldigiHellCore?
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [[UInt8]] = []
    private var lastStatus: FldigiHellCore.Status?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    public func configure(options: FldigiHellCore.Options, centerHz: Double) {
        pipeline.perform { [self] in
            if let core {
                if core.options != options { core.configure(options) }
            } else {
                core = FldigiHellCore(options: options, centerHz: centerHz) { [weak self] column in
                    self?.lock.withLockUnchecked {
                        self?.pending.append(column)
                        if (self?.pending.count ?? 0) > 4000 { self?.pending.removeFirst(2000) }
                    }
                }
            }
        }
    }

    public func setCenter(_ hz: Double) {
        pipeline.perform { [self] in core?.setCenter(hz) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in enabled = on }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(columns: pending, status: lastStatus)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let core else { return }
        core.process(samples)
        let status = core.status
        lock.withLockUnchecked { lastStatus = status }
    }
}

// MARK: - Controller

/// Verbindet Hell-Einstellungen, Decoder, Raster und Anzeige
@MainActor
public final class HellController: ObservableObject {
    public let decoder: HellDecoder
    public let raster = HellRasterModel()
    @Published public private(set) var status: FldigiHellCore.Status?
    @Published public private(set) var lastColumnDate: Date?

    private let settings: HellSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appliedOptions: FldigiHellCore.Options?
    private var appliedCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: HellSettingsStore) {
        self.settings = settings
        decoder = HellDecoder(pipeline: pipeline)
        decoder.configure(options: settings.options, centerHz: settings.centerHz)
        appliedOptions = settings.options
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        raster.clear()
    }

    private func settingsChanged() {
        let o = settings.options
        if o != appliedOptions {
            if appliedOptions?.columnHeight != o.columnHeight || appliedOptions?.mode != o.mode { raster.clear() }
            appliedOptions = o
            decoder.configure(options: o, centerHz: settings.centerHz)
        }
        if settings.manualCenterRevision != appliedCenterRevision {
            appliedCenterRevision = settings.manualCenterRevision
            decoder.setCenter(settings.centerHz)
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        if !out.columns.isEmpty {
            // Weiß = 255, bei Umkehrdarstellung (Blackboard) liefert fldigi bereits umgekehrte Werte; Hintergrund wie die erste Zeile
            let background: UInt8 = settings.options.blackboard ? 0 : 255
            for c in out.columns { raster.append(column: c, background: background) }
            lastColumnDate = Date()
        }
        raster.refresh()
        if let s = out.status { status = s }
    }
}
