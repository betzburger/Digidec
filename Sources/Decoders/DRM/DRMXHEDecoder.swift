// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import AudioToolbox

/// xHE-AAC-Zugriffseinheiten (USAC) mit dem Decoder von macOS (AudioToolbox, Format 'usac') in Töne verwandeln.
/// Die Konfiguration kommt als AudioSpecificConfig (siehe `DRMXHEConfig.audioSpecificConfig`), eingepackt in einen `esds`-Cookie.
final class DRMXHEDecoder {
    private var converter: AudioConverterRef?
    let channels: Int
    let outputRate: Int
    let granule: Int
    /// Nach Start oder Verlust erst ab dem nächsten Rahmen mit gesetztem usacIndependencyFlag wieder decodieren
    private var needIndependent = true
    private(set) var decoded = 0
    private(set) var skipped = 0
    private(set) var failed = 0
    /// Letzter Status des Systemdecoders (für die Fehlersuche)
    private(set) var lastStatus: OSStatus = 0

    private final class Feed { var data: [UInt8] = []; var offered = false; var desc = AudioStreamPacketDescription() }
    private let feed = Feed()

    /// Aus den SDC-Angaben (Typ 9); nil, wenn die Konfiguration nicht lesbar ist oder der Decoder sie nicht annimmt
    convenience init?(param: DRMAudioParam) {
        guard param.coding == .xheaac, param.mode == 0 || param.mode == 2,
              let config = DRMXHEConfig(drm: param.codecConfig, stereo: param.mode == 2) else { return nil }
        self.init(audioSpecificConfig: config.audioSpecificConfig(sampleRate: param.sampleRate), sampleRate: param.sampleRate, channels: param.mode == 2 ? 2 : 1, granule: config.granule)
    }

    init?(audioSpecificConfig asc: [UInt8], sampleRate: Int, channels: Int, granule: Int) {
        guard (1...2).contains(channels), granule > 0, !asc.isEmpty else { return nil }
        self.channels = channels
        self.outputRate = sampleRate
        self.granule = granule
        var input = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEGD_USAC, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(granule),
                                                mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                                 mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &conv) == noErr, let c = conv else { return nil }
        let cookie = Self.esds(asc)
        guard AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), cookie) == noErr else { AudioConverterDispose(c); return nil }
        converter = c
    }

    deinit { if let c = converter { AudioConverterDispose(c) } }

    /// MPEG-4-Cookie (esds-Inhalt) um die AudioSpecificConfig
    static func esds(_ asc: [UInt8]) -> [UInt8] {
        func length(_ n: Int) -> [UInt8] { [0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] }
        let specific: [UInt8] = [0x05] + length(asc.count) + asc
        let decoderConfig: [UInt8] = [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + specific
        let decoder: [UInt8] = [0x04] + length(decoderConfig.count) + decoderConfig
        let sl: [UInt8] = [0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
        let es: [UInt8] = [0x00, 0x01, 0x00] + decoder + sl
        return [0x03] + length(es.count) + es
    }

    /// Verlust (fehlender oder fehlerhafter Rahmen): Zustand zurücksetzen und auf den nächsten unabhängigen Rahmen warten
    func loss() {
        if !needIndependent, let c = converter { AudioConverterReset(c) }
        needIndependent = true
    }

    /// Eine Zugriffseinheit; die Rückgabe ist verschachtelt (bei Stereo L R L R …). Fehlt der Rahmen (leer) oder ist er nicht zu gebrauchen, kommt Stille in Rahmenlänge.
    func decode(_ au: [UInt8]) -> [Float] {
        let silence = [Float](repeating: 0, count: granule * channels)
        guard let conv = converter else { return silence }
        guard !au.isEmpty else { loss(); skipped += 1; return silence }
        if needIndependent {
            guard au[0] & 0x80 != 0 else { skipped += 1; return silence }
            needIndependent = false
        }
        feed.data = au
        feed.offered = false
        feed.desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(au.count))
        var pcm = [Float](repeating: 0, count: granule * channels)
        var frames = UInt32(granule)
        let ch = channels
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(pcm.count * 4), mData: nil))
        let provide: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, user in
            let f = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
            if f.offered { ioPackets.pointee = 0; return 1 }
            f.offered = true
            f.data.withUnsafeMutableBytes { raw in
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = 0
                ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
                ioData.pointee.mBuffers.mData = raw.baseAddress
            }
            withUnsafeMutablePointer(to: &f.desc) { outDesc?.pointee = $0 }
            ioPackets.pointee = 1
            return noErr
        }
        let status: OSStatus = pcm.withUnsafeMutableBytes { out in
            list.mBuffers.mData = out.baseAddress
            return AudioConverterFillComplexBuffer(conv, provide, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
        }
        feed.data = []
        lastStatus = status
        if (status != noErr && status != 1) || frames == 0 { failed += 1; loss(); return silence }
        decoded += 1
        return Array(pcm.prefix(Int(frames) * channels)) + (frames < UInt32(granule) ? [Float](repeating: 0, count: (granule - Int(frames)) * channels) : [])
    }
}
