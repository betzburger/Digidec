// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Faad2DRM

/// AAC-Rahmen von DRM (AAC-LC mit optionalem SBR und parametrischem Stereo im DRM-Format) mit FAAD2 im DRM-Modus decodieren.
/// Jeder Rahmen beginnt mit seinem CRC-Byte (so erwartet es der DRM-Modus von FAAD2).
final class DRMAudioDecoder {
    private var handle: NeAACDecHandle?
    let param: DRMAudioParam
    /// Ausgang: 1 oder 2 Kanäle (der DRM-Modus von FAAD2 liefert immer Stereo; bei Mono sind beide gleich)
    let channels: Int
    let outputRate: Int
    /// Abtastwerte je Kanal und Rahmen am Ausgang: 960 im AAC-Kern (80 ms bei 12 kHz, 40 ms bei 24 kHz), mit SBR doppelt so viele
    var samplesPerFrame: Int { 960 * outputRate / param.sampleRate }

    init?(param: DRMAudioParam) {
        guard param.coding == .aac, param.sampleRate == 12_000 || param.sampleRate == 24_000, let h = faaddrm_NeAACDecOpen() else { return nil }
        self.param = param
        var mode: UInt8
        switch param.mode {
        case 0: mode = param.sbr ? UInt8(DRMCH_SBR_MONO) : UInt8(DRMCH_MONO)
        case 1: mode = UInt8(DRMCH_SBR_PS_STEREO)
        default: mode = param.sbr ? UInt8(DRMCH_SBR_STEREO) : UInt8(DRMCH_STEREO)
        }
        // NeAACDecInitDRM schließt den übergebenen Decoder und legt einen neuen an: `h` ist danach ungültig, es gilt nur noch `hh`.
        // Rückgabe 0 = in Ordnung (der Typ ist `char`, ein Fehler ist 1 und nie negativ).
        var hh: NeAACDecHandle? = h
        let rc = faaddrm_NeAACDecInitDRM(&hh, UInt(param.sampleRate), mode)
        guard rc == 0, let opened = hh else { if let hh { faaddrm_NeAACDecClose(hh) }; return nil }
        handle = opened
        channels = param.mode == 0 ? 1 : 2
        outputRate = param.outputRate
    }

    deinit { if let h = handle { faaddrm_NeAACDecClose(h) } }

    /// Ein Rahmen (CRC-Byte + Daten) → Abtastwerte (Float, bei Stereo verschachtelt); nil bei Fehler (z. B. CRC)
    func decode(_ frame: [UInt8]) -> [Float]? {
        guard let h = handle, frame.count > 1 else { return nil }
        var info = NeAACDecFrameInfo()
        var data = frame
        guard let out = faaddrm_NeAACDecDecode(h, &info, &data, UInt(data.count)), info.error == 0, info.samples > 0 else { return nil }
        let count = Int(info.samples)
        let pcm = out.assumingMemoryBound(to: Int16.self)
        let inChannels = max(1, Int(info.channels))
        let perChannel = count / inChannels
        var result = [Float]()
        result.reserveCapacity(perChannel * channels)
        for i in 0..<perChannel {
            if channels == 1 {
                result.append(Float(pcm[i * inChannels]) / 32768)
            } else {
                result.append(Float(pcm[i * inChannels]) / 32768)
                result.append(Float(pcm[i * inChannels + (inChannels > 1 ? 1 : 0)]) / 32768)
            }
        }
        return result
    }
}
