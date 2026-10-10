// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate
import os

// MARK: - Kanalwahl

/// Welcher Kanal des (meist stereo) Eingangs decodiert wird. Die Commander geben das Empfangsaudio
/// auf beiden Kanälen aus; bei Geräten mit getrennten Kanälen lässt sich hier einer wählen.
public enum ChannelMode: String, CaseIterable, Identifiable, Sendable {
    case left, right, mix

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .left:  return "L"
        case .right: return "R"
        case .mix:   return "L+R"
        }
    }

    /// Interleaved-Frames → Mono. Bei nur einem Kanal wird dieser unverändert übernommen.
    public static func extract(interleaved src: UnsafePointer<Float>, frames: Int, channels: Int,
                               mode: ChannelMode, into dst: UnsafeMutablePointer<Float>) {
        guard frames > 0, channels > 0 else { return }
        if channels == 1 {
            dst.update(from: src, count: frames)
            return
        }
        let stride = vDSP_Stride(channels)
        var one: Float = 1
        switch mode {
        case .left:
            vDSP_vsmul(src, stride, &one, dst, 1, vDSP_Length(frames))
        case .right:
            vDSP_vsmul(src + 1, stride, &one, dst, 1, vDSP_Length(frames))
        case .mix:
            var half: Float = 0.5
            vDSP_vasm(src, stride, src + 1, stride, &half, dst, 1, vDSP_Length(frames))
        }
    }

    /// Nicht verschachtelte Kanäle (z. B. aus AVAudioFile) → Mono.
    public static func extract(planar channelsData: [UnsafePointer<Float>], frames: Int,
                               mode: ChannelMode, into dst: UnsafeMutablePointer<Float>) {
        guard frames > 0, let first = channelsData.first else { return }
        guard channelsData.count > 1 else {
            dst.update(from: first, count: frames)
            return
        }
        switch mode {
        case .left:
            dst.update(from: channelsData[0], count: frames)
        case .right:
            dst.update(from: channelsData[1], count: frames)
        case .mix:
            var half: Float = 0.5
            vDSP_vasm(channelsData[0], 1, channelsData[1], 1, &half, dst, 1, vDSP_Length(frames))
        }
    }
}

// MARK: - Pegel

public struct AudioLevel: Equatable, Sendable {
    public static let floorDB: Float = -120
    public static let silence = AudioLevel(peakDB: floorDB, rmsDB: floorDB)

    public var peakDB: Float
    public var rmsDB: Float

    public init(peakDB: Float, rmsDB: Float) {
        self.peakDB = peakDB
        self.rmsDB = rmsDB
    }

    public static func dB(_ linear: Float) -> Float {
        linear > 1e-6 ? max(floorDB, 20 * log10(linear)) : floorDB
    }
}

/// Sammelt Spitze und Effektivwert zwischen zwei Abfragen der Anzeige (≈ 20 Hz).
public final class LevelAccumulator: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var count: Int = 0

    public init() {}

    public func add(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        var p: Float = 0
        var ms: Float = 0
        vDSP_maxmgv(base, 1, &p, vDSP_Length(samples.count))
        vDSP_measqv(base, 1, &ms, vDSP_Length(samples.count))
        lock.withLockUnchecked {
            peak = max(peak, p)
            sumSquares += Double(ms) * Double(samples.count)
            count += samples.count
        }
    }

    /// Liefert den Pegel seit der letzten Abfrage und setzt zurück.
    public func take() -> AudioLevel {
        lock.withLockUnchecked {
            defer { peak = 0; sumSquares = 0; count = 0 }
            guard count > 0 else { return .silence }
            return AudioLevel(peakDB: AudioLevel.dB(peak), rmsDB: AudioLevel.dB(Float((sumSquares / Double(count)).squareRoot())))
        }
    }
}

// MARK: - Ringpuffer

/// Ringpuffer für Mono-Samples zwischen Audio-Callback (schreibt) und Verarbeitungs-Queue (liest).
/// Keine Allokationen beim Schreiben; der Lock (os_unfair_lock) wird nur für das Kopieren gehalten.
/// Bei Überlauf werden die ältesten Samples verworfen und gezählt.
public final class FloatRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = OSAllocatedUnfairLock()
    private var readIndex = 0
    private var fill = 0
    private var dropped = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    public var available: Int { lock.withLockUnchecked { fill } }
    public var droppedSamples: Int { lock.withLockUnchecked { dropped } }

    public func write(_ src: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        lock.withLockUnchecked {
            // Mehr als die Kapazität: nur die neuesten Samples behalten
            let skip = max(0, n - capacity)
            let toWrite = n - skip
            dropped += skip

            let overflow = max(0, fill + toWrite - capacity)
            if overflow > 0 {
                readIndex = (readIndex + overflow) % capacity
                fill -= overflow
                dropped += overflow
            }

            let writeIndex = (readIndex + fill) % capacity
            let first = min(toWrite, capacity - writeIndex)
            (storage + writeIndex).update(from: src + skip, count: first)
            if toWrite > first {
                storage.update(from: src + skip + first, count: toWrite - first)
            }
            fill += toWrite
        }
    }

    public func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        lock.withLockUnchecked {
            let n = min(maxCount, fill)
            guard n > 0 else { return 0 }
            let first = min(n, capacity - readIndex)
            dst.update(from: storage + readIndex, count: first)
            if n > first {
                (dst + first).update(from: storage, count: n - first)
            }
            readIndex = (readIndex + n) % capacity
            fill -= n
            return n
        }
    }

    public func clear() {
        lock.withLockUnchecked {
            readIndex = 0
            fill = 0
            dropped = 0
        }
    }
}

// MARK: - Abgriff für den Web-Fernzugriff

/// Gibt Audio mit beliebiger Rate und Kanalzahl an einen Mithörer weiter (Web-Fernzugriff), ohne den Erzeuger aufzuhalten:
/// die Weitergabe läuft auf einer eigenen Warteschlange, bei Rückstau werden Blöcke ausgelassen.
/// Der Mithörer liegt in einer gewöhnlichen Variablen unter `NSLock`: in einem generischen `OSAllocatedUnfairLock<Handler?>` würde jeder
/// lesende Zugriff den gespeicherten Abgriff in eine weitere Umwandlungsschicht packen (Stapelüberlauf nach einigen tausend Blöcken).
public final class PCMTap: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafeBufferPointer<Float>, Int, Int) -> Void
    private let lock = NSLock()
    private var handler: Handler?
    private let queue = DispatchQueue(label: "com.peterbetz.digidec.pcmtap", qos: .userInitiated)
    private var backlog = 0

    public init() {}

    public func set(_ new: Handler?) {
        lock.lock(); handler = new; lock.unlock()
    }

    private func take() -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    /// Verschachtelte Abtastwerte; `rate` in Hz
    public func send(_ samples: [Float], channels: Int, rate: Int) {
        guard !samples.isEmpty, take() != nil else { return }
        lock.lock()
        let accept = backlog < 40
        if accept { backlog += 1 }
        lock.unlock()
        guard accept else { return }
        queue.async { [self] in
            if let h = take() { samples.withUnsafeBufferPointer { h($0, rate, channels) } }
            lock.lock(); backlog -= 1; lock.unlock()
        }
    }
}
