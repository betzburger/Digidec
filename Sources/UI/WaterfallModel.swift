// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI
import CoreGraphics

/// Bild des Wasserfalls und Spektrumkurve für die Anzeige. Holt mit 30 Hz neue Zeilen vom `WaterfallProcessor`.
@MainActor
public final class WaterfallModel: ObservableObject {
    /// Angezeigter Frequenzbereich (Spannweite in Hz); bei < 4000 Hz um die Mittenfrequenz zentriert
    public enum Span: Double, CaseIterable, Identifiable {
        case full = 4000, wide = 2000, narrow = 1000, zoom = 500
        public var id: Double { rawValue }
        public var label: String {
            switch self {
            case .full: return "4 kHz"
            case .wide: return "2 kHz"
            case .narrow: return "1 kHz"
            case .zoom: return "500 Hz"
            }
        }
    }

    public static let historyRows = 360       // ≈ 11,5 s bei 31 Zeilen/s

    @Published public private(set) var image: CGImage?
    @Published public private(set) var spectrum: [Float] = []
    @Published public private(set) var noiseFloor: Float = -100
    @Published public var span: Span {
        didSet { UserDefaults.standard.set(span.rawValue, forKey: "waterfallSpan") }
    }
    /// Dynamikbereich der Farbskala in dB
    @Published public var rangeDB: Float {
        didSet { UserDefaults.standard.set(rangeDB, forKey: "waterfallRangeDB"); needsRedraw = true }
    }

    public let processor: WaterfallProcessor
    public var binCount: Int { processor.binCount }
    public var binWidth: Double { processor.binWidth }
    public var nyquist: Double { processor.sampleRate / 2 }

    private var pixels: [UInt32]
    private var dbRows: [[Float]] = []       // für Neufärbung bei geänderter Dynamik
    private var timer: Timer?
    private var needsRedraw = false
    private var tick = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    public init(pipeline: AudioPipeline) {
        processor = WaterfallProcessor()
        let savedSpan = UserDefaults.standard.double(forKey: "waterfallSpan")
        span = Span(rawValue: savedSpan) ?? .full
        let savedRange = UserDefaults.standard.float(forKey: "waterfallRangeDB")
        rangeDB = (20...90).contains(savedRange) ? savedRange : 50
        pixels = [UInt32](repeating: WaterfallColorMap.lut[0], count: processor.binCount * Self.historyRows)

        let proc = processor
        pipeline.addSink { proc.consume($0) }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// Sichtbarer Frequenzbereich bei gegebener Mittenfrequenz
    public func visibleRange(center: Double) -> ClosedRange<Double> {
        let width = span.rawValue
        guard width < nyquist else { return 0...nyquist }
        let lo = min(max(0, center - width / 2), nyquist - width)
        return lo...(lo + width)
    }

    public func clear() {
        processor.reset()
        dbRows.removeAll()
        for i in pixels.indices { pixels[i] = WaterfallColorMap.lut[0] }
        needsRedraw = true
    }

    private func update() {
        let newRows = processor.takeRows()
        tick += 1
        if tick % 2 == 0 || !newRows.isEmpty {
            let snap = processor.snapshot()
            if tick % 2 == 0 { spectrum = snap.spectrum }
            noiseFloor = snap.noiseFloor
        }
        guard !newRows.isEmpty || needsRedraw else { return }

        let width = binCount
        // Rauschen etwas über Schwarz (dunkelblau wie in fldigi), Signale heben sich darüber ab
        let floorDB = noiseFloor - 8
        if needsRedraw {
            // Dynamik geändert: alle gespeicherten Zeilen neu einfärben
            needsRedraw = false
            for (r, row) in dbRows.enumerated() {
                paint(row: row, at: r, width: width, floorDB: floorDB)
            }
        }
        for row in newRows {
            // Bild um eine Zeile nach unten schieben, neue Zeile oben
            pixels.withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                (base + width).update(from: base, count: width * (Self.historyRows - 1))
            }
            paint(row: row, at: 0, width: width, floorDB: floorDB)
            dbRows.insert(row, at: 0)
            if dbRows.count > Self.historyRows { dbRows.removeLast() }
        }
        image = makeImage(width: width)
    }

    private func paint(row: [Float], at r: Int, width: Int, floorDB: Float) {
        let lut = WaterfallColorMap.lut
        let range = rangeDB
        pixels.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress! + r * width
            for i in 0..<width {
                base[i] = lut[WaterfallColorMap.index(db: row[i], floorDB: floorDB, rangeDB: range)]
            }
        }
    }

    private func makeImage(width: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: Self.historyRows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
