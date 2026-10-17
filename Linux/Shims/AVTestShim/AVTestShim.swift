// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Nur für die Logiktests unter Linux: die Teile von AVFoundation (AVAudioFile, AVAudioPCMBuffer), mit denen die Tests WAV-Dateien lesen und schreiben.
// Bewusst nicht „AVFoundation“ genannt, damit `canImport(AVFoundation)` im Programmcode unter Linux falsch bleibt.
import Foundation
import CSndfile

public typealias AVAudioFrameCount = UInt32
public let AVFormatIDKey = "AVFormatIDKey"
public let AVSampleRateKey = "AVSampleRateKey"
public let AVNumberOfChannelsKey = "AVNumberOfChannelsKey"
public let AVLinearPCMBitDepthKey = "AVLinearPCMBitDepthKey"
public let AVLinearPCMIsFloatKey = "AVLinearPCMIsFloatKey"
public let AVLinearPCMIsBigEndianKey = "AVLinearPCMIsBigEndianKey"
public let kAudioFormatLinearPCM: UInt32 = 0x6C70636D

public final class AVAudioFormat: @unchecked Sendable {
    public enum CommonFormat { case pcmFormatFloat32, pcmFormatInt16 }
    public let sampleRate: Double
    public let channelCount: UInt32
    public init?(commonFormat: CommonFormat, sampleRate: Double, channels: UInt32, interleaved: Bool) {
        self.sampleRate = sampleRate
        channelCount = channels
    }
    public convenience init?(standardFormatWithSampleRate sampleRate: Double, channels: UInt32) {
        self.init(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
    }
}

public final class AVAudioPCMBuffer: @unchecked Sendable {
    public let format: AVAudioFormat
    public let frameCapacity: AVAudioFrameCount
    public var frameLength: AVAudioFrameCount = 0
    private let planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let channels: Int

    public init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        format = pcmFormat
        self.frameCapacity = frameCapacity
        channels = Int(pcmFormat.channelCount)
        planes = .allocate(capacity: max(1, channels))
        for c in 0..<channels {
            planes[c] = .allocate(capacity: max(1, Int(frameCapacity)))
            planes[c].initialize(repeating: 0, count: max(1, Int(frameCapacity)))
        }
    }

    deinit {
        for c in 0..<channels { planes[c].deallocate() }
        planes.deallocate()
    }

    public var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { UnsafePointer(planes) }
}

public struct AVAudioFileError: Error, CustomStringConvertible {
    public let description: String
}

public final class AVAudioFile: @unchecked Sendable {
    public let url: URL
    public let processingFormat: AVAudioFormat
    public var fileFormat: AVAudioFormat { processingFormat }
    private let handle: OpaquePointer
    private let frames: Int64

    public init(forReading url: URL) throws {
        var info = SF_INFO()
        guard let opened = sf_open(url.path, Int32(SFM_READ), &info) else { throw AVAudioFileError(description: String(cString: sf_strerror(nil))) }
        handle = opened
        self.url = url
        frames = Int64(info.frames)
        processingFormat = AVAudioFormat(standardFormatWithSampleRate: Double(info.samplerate), channels: UInt32(info.channels))!
    }

    public convenience init(forReading url: URL, commonFormat: AVAudioFormat.CommonFormat, interleaved: Bool) throws {
        try self.init(forReading: url)
    }

    public init(forWriting url: URL, settings: [String: Any], commonFormat: AVAudioFormat.CommonFormat, interleaved: Bool) throws {
        let rate = (settings[AVSampleRateKey] as? Double) ?? 44_100
        let channels = (settings[AVNumberOfChannelsKey] as? Int) ?? 1
        let bits = (settings[AVLinearPCMBitDepthKey] as? Int) ?? 16
        let isFloat = (settings[AVLinearPCMIsFloatKey] as? Bool) ?? false
        let subformat = isFloat ? Int32(SF_FORMAT_FLOAT) : (bits == 24 ? Int32(SF_FORMAT_PCM_24) : bits == 32 ? Int32(SF_FORMAT_PCM_32) : Int32(SF_FORMAT_PCM_16))
        var info = SF_INFO(frames: 0, samplerate: Int32(rate), channels: Int32(channels), format: Int32(SF_FORMAT_WAV) | subformat, sections: 0, seekable: 0)
        guard let opened = sf_open(url.path, Int32(SFM_WRITE), &info) else { throw AVAudioFileError(description: String(cString: sf_strerror(nil))) }
        handle = opened
        self.url = url
        frames = 0
        processingFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: UInt32(channels))!
    }

    deinit { sf_close(handle) }

    public var length: Int64 { frames }

    public var framePosition: Int64 {
        get { Int64(sf_seek(handle, 0, SEEK_CUR)) }
        set { sf_seek(handle, sf_count_t(newValue), SEEK_SET) }
    }

    public func read(into buffer: AVAudioPCMBuffer) throws { try read(into: buffer, frameCount: buffer.frameCapacity) }

    public func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        let channels = Int(processingFormat.channelCount)
        let want = Int(min(frameCount, buffer.frameCapacity))
        var interleaved = [Float](repeating: 0, count: want * channels)
        let got = Int(sf_readf_float(handle, &interleaved, sf_count_t(want)))
        let planes = buffer.floatChannelData!
        for c in 0..<channels { for i in 0..<got { planes[c][i] = interleaved[i * channels + c] } }
        buffer.frameLength = AVAudioFrameCount(got)
    }

    public func write(from buffer: AVAudioPCMBuffer) throws {
        let channels = Int(processingFormat.channelCount)
        let count = Int(buffer.frameLength)
        var interleaved = [Float](repeating: 0, count: count * channels)
        let planes = buffer.floatChannelData!
        for c in 0..<channels { for i in 0..<count { interleaved[i * channels + c] = planes[c][i] } }
        guard Int(sf_writef_float(handle, &interleaved, sf_count_t(count))) == count else { throw AVAudioFileError(description: "Schreiben fehlgeschlagen") }
    }
}
