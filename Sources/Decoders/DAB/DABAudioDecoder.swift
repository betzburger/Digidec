// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Faad2

/// Decodiert die AAC-Zugriffseinheiten von DAB+ (AAC-LC, HE-AAC mit SBR, HE-AAC v2 mit PS; Rahmenlänge 960) mit FAAD2 zu PCM
public final class DABAACDecoder: @unchecked Sendable {
    public enum DecodeError: Error { case open, configuration, initialisation(Int) }

    private var handle: NeAACDecHandle?
    public let format: DABAudioFormat
    /// Kanäle der letzten Ausgabe (bei HE-AAC v2 erst nach dem ersten Rahmen sicher)
    public private(set) var outputChannels: Int
    public private(set) var outputRate: Int

    public init(format: DABAudioFormat) throws {
        self.format = format
        outputChannels = (format.stereo || format.ps) ? 2 : 1
        outputRate = format.outputRate
        guard let h = NeAACDecOpen() else { throw DecodeError.open }
        handle = h
        guard let cfg = NeAACDecGetCurrentConfiguration(h) else { throw DecodeError.configuration }
        cfg.pointee.outputFormat = UInt8(FAAD_FMT_FLOAT)
        cfg.pointee.downMatrix = 0
        cfg.pointee.dontUpSampleImplicitSBR = 0
        _ = NeAACDecSetConfiguration(h, cfg)
        var asc = format.audioSpecificConfig
        var rate: UInt = 0
        var channels: UInt8 = 0
        let rc = NeAACDecInit2(h, &asc, UInt(asc.count), &rate, &channels)
        guard rc >= 0 else { throw DecodeError.initialisation(Int(rc)) }
    }

    deinit { if let h = handle { NeAACDecClose(h) } }

    /// Eine Zugriffseinheit decodieren; Rückgabe: Abtastwerte, bei Stereo abwechselnd links und rechts (FAAD2 liefert im Float-Format bereits −1 … 1)
    public func decode(_ au: [UInt8]) -> [Float] {
        guard let h = handle else { return [] }
        var info = NeAACDecFrameInfo()
        var data = au
        guard let out = NeAACDecDecode(h, &info, &data, UInt(data.count)), info.error == 0, info.samples > 0 else { return [] }
        outputChannels = Int(info.channels)
        outputRate = Int(info.samplerate)
        let count = Int(info.samples)
        let p = out.assumingMemoryBound(to: Float.self)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = p[i] }
        return result
    }

    public func reset() {
        if let h = handle { NeAACDecPostSeekReset(h, 0) }
    }
}
