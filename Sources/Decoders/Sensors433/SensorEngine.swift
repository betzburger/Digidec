// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Empfangskette der Funksensoren: I/Q (8 Bit) → Hüllkurve und Frequenz → Pulspakete → Slicer → Gerätedecoder.

/// Ein gelesenes Telegramm mit Empfangsdaten
public struct SensorEvent: Sendable {
    public var reading: SensorReading
    public var device: String
    /// Sekunden seit Beginn des Stroms
    public var time: Double
    public var rssiDB: Double
    public var snrDB: Double
    public var noiseDB: Double
    /// Mittenfrequenz-Ablage des Senders in Hz (FSK: Mittel der beiden Töne)
    public var frequencyOffsetHz: Double
    public var isFSK: Bool
}

/// Mittelt je `factor` I/Q-Paare (Tiefpass und Abwärtsmischung der Abtastrate) auf 8 Bit
public final class IQDecimator {
    public let factor: Int
    private var sumI = 0, sumQ = 0, count = 0

    public init(factor: Int) { self.factor = max(1, factor) }

    public func reset() { sumI = 0; sumQ = 0; count = 0 }

    public func process(_ input: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) {
        out.removeAll(keepingCapacity: true)
        if factor == 1 { out.append(contentsOf: input); return }
        let n = input.count / 2
        out.reserveCapacity(n / factor * 2 + 2)
        for k in 0..<n {
            sumI += Int(input[2 * k]); sumQ += Int(input[2 * k + 1]); count += 1
            if count == factor {
                out.append(UInt8((sumI + factor / 2) / factor))
                out.append(UInt8((sumQ + factor / 2) / factor))
                sumI = 0; sumQ = 0; count = 0
            }
        }
    }
}

public final class SensorReceiver {
    public let sampleRate: Int
    public private(set) var devices: [SensorDevice]
    /// Aufgerufen für jedes Telegramm
    public var onEvent: ((SensorEvent) -> Void)?
    /// Pakete (OOK und FSK), auch ohne Treffer: für die Anzeige der Aktivität
    public var onPackage: ((PulsePackage, PulseData) -> Void)?
    /// Pakete, die kein Decoder erkannt hat (mit Pulsanalyse), sofern sie lang genug sind
    public var onUnknown: ((UnknownPackage) -> Void)?
    /// Zählt Pakete und Treffer
    public private(set) var packages = 0
    public private(set) var ookPackages = 0
    public private(set) var fskPackages = 0
    public private(set) var decoded = 0
    public private(set) var unknown = 0

    private let baseband = Baseband433()
    private let detector = PulseDetector433()
    private var envelope: [UInt16] = []
    private var smoothed: [Int16] = []
    private var fm: [Int16] = []
    private var ook = PulseData()
    private var fsk = PulseData()
    private var position = 0
    private var priorities: [Int] = []
    private let centerFrequency: Double

    /// - Parameters:
    ///   - sampleRate: Abtastrate der 8-Bit-I/Q-Daten, die hereinkommen
    ///   - devices: Gerätedecoder (die Reihenfolge innerhalb einer Priorität bleibt erhalten)
    ///   - centerFrequency: Empfangsfrequenz in Hz; über 800 MHz kommt die Min/Max-FSK-Erkennung zum Einsatz
    public init(sampleRate: Int, devices: [SensorDevice], centerFrequency: Double = 433_920_000) {
        self.sampleRate = sampleRate
        self.devices = devices
        self.centerFrequency = centerFrequency
        detector.minMaxFSK = centerFrequency > 800_000_000
        priorities = Array(Set(devices.map(\.priority))).sorted()
    }

    public func reset() {
        baseband.reset()
        detector.reset()
        ook = PulseData(); fsk = PulseData()
        position = 0
    }

    /// Verarbeitet einen Block 8-Bit-I/Q in der Abtastrate des Empfängers
    public func process(_ iq: UnsafeBufferPointer<UInt8>) {
        let n = iq.count / 2
        guard n > 0 else { return }
        _ = baseband.envelope(iq, into: &envelope)
        baseband.lowPass(envelope, count: n, into: &smoothed)
        baseband.demodulateFM(iq, sampleRate: sampleRate, lowPass: detector.minMaxFSK ? 0.2 : 0.1, into: &fm)
        while let package = detector.nextPackage(envelope: smoothed, fm: fm, count: n, sampleRate: sampleRate, offset: position, ook: &ook, fsk: &fsk) {
            handle(package, endOffsetFromBlockStart: n)
        }
        position += n
    }

    /// Am Ende einer Datei: angefangenes Paket abschließen
    public func flush() {
        while let package = detector.nextPackage(envelope: [], fm: [], count: 0, sampleRate: sampleRate, offset: position, ook: &ook, fsk: &fsk, flush: true) {
            handle(package, endOffsetFromBlockStart: 0)
        }
    }

    private func handle(_ package: PulsePackage, endOffsetFromBlockStart: Int) {
        packages += 1
        let data = package == .ook ? ook : fsk
        if package == .ook { ookPackages += 1 } else { fskPackages += 1 }
        onPackage?(package, data)
        if ProcessInfo.processInfo.environment["S433_DEBUG2"] != nil { print("   ook pulses \(ook.numPulses) fsk pulses \(fsk.numPulses) ook: \((0..<min(ook.numPulses, 8)).map { "\(ook.pulse[$0])/\(ook.gap[$0])" })") }
        let time = Double(data.offset) / Double(sampleRate)
        let offsetHz: Double
        if package == .fsk {
            let f1 = Double(data.fskF1Estimate) / Double(Int16.max) * Double(sampleRate) / 2
            let f2 = Double(data.fskF2Estimate) / Double(Int16.max) * Double(sampleRate) / 2
            offsetHz = (f1 + f2) / 2
        } else {
            offsetHz = Double(ook.fskF1Estimate) / Double(Int16.max) * Double(sampleRate) / 2
        }
        var anyHit = false
        for priority in priorities {
            var hits = 0
            for device in devices where device.priority == priority && device.timing.modulation.isFSK == (package == .fsk) {
                PulseSlicer.slice(data, timing: device.timing) { bits in
                    var copy = bits
                    let readings = device.decode(&copy)
                    for r in readings {
                        hits += 1
                        decoded += 1
                        onEvent?(SensorEvent(reading: r, device: device.name, time: time, rssiDB: data.rssiDB, snrDB: data.snrDB, noiseDB: data.noiseDB,
                                             frequencyOffsetHz: offsetHz, isFSK: package == .fsk))
                    }
                }
            }
            if hits > 0 { anyHit = true; break }                     // niedrigere Priorität nur, wenn die höhere nichts fand
        }
        if !anyHit, let analysis = SensorAnalyzer.analyze(data, isFSK: package == .fsk, time: time, rssiDB: data.rssiDB, snrDB: data.snrDB, frequencyOffsetHz: offsetHz) {
            unknown += 1
            onUnknown?(analysis)
        }
    }
}
