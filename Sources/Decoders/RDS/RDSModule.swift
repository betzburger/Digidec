// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - RDS Informationen

public struct RDSInfo: Sendable, Equatable {
    public var pi: UInt16?
    public var piHex: String? { pi.map { String(format: "%04X", $0) } }
    public var country: String? { pi.flatMap(RDSCountry.name(for:)) }
    public var programService: String = ""
    public var radioText: String = ""
    public var radioTextHistory: [String] = []
    public var pty: Int?
    public var ptyName: String? { pty.map(RDSPTY.name(for:)) }
    public var tp: Bool = false
    public var ta: Bool = false
    public var music: Bool?
    public var clockTime: Date?
    public var clockTimeFormatted: String? {
        guard let ct = clockTime else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm 'Uhr' (dd.MM.)"
        f.timeZone = TimeZone.current
        return f.string(from: ct)
    }
    public var alternativeFrequencies: [Double] = []
    public var syncState: RDSStreamDecoder.SyncState = .search
    public var groupsReceived: Int = 0
    public var blocksReceived: Int = 0
    public var blockErrors: Int = 0

    public var blockSuccessRate: Double {
        let total = blocksReceived + blockErrors
        guard total > 0 else { return 0.0 }
        return Double(blocksReceived) / Double(total) * 100.0
    }

    public init() {}
}

// MARK: - Einstellungen

@MainActor
public final class RDSSettingsStore: ObservableObject {
    @Published public var frequencyHz: Double {
        didSet {
            UserDefaults.standard.set(frequencyHz, forKey: "rdsFrequencyHz")
        }
    }
    @Published public var selectedPreset: String {
        didSet {
            UserDefaults.standard.set(selectedPreset, forKey: "rdsPreset")
        }
    }

    public init() {
        let savedFreq = UserDefaults.standard.double(forKey: "rdsFrequencyHz")
        frequencyHz = (87_500_000...108_000_000).contains(savedFreq) ? savedFreq : 98_000_000
        selectedPreset = UserDefaults.standard.string(forKey: "rdsPreset") ?? "98.0"
    }

    public static let standardPresets: [(name: String, freqHz: Double)] = [
        ("87,6 MHz", 87_600_000),
        ("89,5 MHz", 89_500_000),
        ("90,9 MHz", 90_900_000),
        ("92,4 MHz", 92_400_000),
        ("94,4 MHz", 94_400_000),
        ("96,0 MHz", 96_000_000),
        ("98,0 MHz", 98_000_000),
        ("99,3 MHz", 99_300_000),
        ("100,6 MHz", 100_600_000),
        ("102,0 MHz", 102_000_000),
        ("104,0 MHz", 104_000_000),
        ("105,7 MHz", 105_700_000),
        ("107,9 MHz", 107_900_000)
    ]
}

extension RDSSettingsStore: TuningTarget {
    public var centerHz: Double { 0 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 200_000 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("RDS · UKW-Rundfunk WFM") }
}

// MARK: - Controller

@MainActor
public final class RDSController: ObservableObject {
    @Published public private(set) var info = RDSInfo()
    @Published public private(set) var signalDB: Float = -90

    public let settings: RDSSettingsStore
    public let demodulator = RDSDemodulator()

    private let lock = OSAllocatedUnfairLock()
    private var psBuffer = [Character](repeating: " ", count: 8)
    private var psReceivedMask: UInt8 = 0
    private var rtBuffer = [Character](repeating: " ", count: 64)
    private var rtReceivedMask: UInt16 = 0
    private var currentTextAB: Bool?
    private var afSet = Set<Double>()
    private var timer: Timer?

    public init(settings: RDSSettingsStore) {
        self.settings = settings
        setupDecoder()
        startTimer()
    }

    private func setupDecoder() {
        demodulator.streamDecoder.onGroup = { [weak self] group in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleGroup(group)
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleGroup(group)
                    }
                }
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePeriodic()
            }
        }
    }

    private let activeState = OSAllocatedUnfairLock(initialState: false)

    public func setActive(_ active: Bool) {
        activeState.withLock { $0 = active }
        if !active {
            clear()
        }
    }

    nonisolated public func feedDiscriminator(samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard activeState.withLock({ $0 }) else { return }
        demodulator.process(mpx: samples)
    }

    public func updateSignal(db: Float) {
        signalDB = db
    }

    public func tune(frequencyHz: Double) {
        let clamped = max(87_500_000, min(108_000_000, frequencyHz))
        settings.frequencyHz = clamped
        clear()
    }

    public func step(mhz: Double) {
        tune(frequencyHz: settings.frequencyHz + mhz * 1e6)
    }

    public func clear() {
        info = RDSInfo()
        psBuffer = [Character](repeating: " ", count: 8)
        psReceivedMask = 0
        rtBuffer = [Character](repeating: " ", count: 64)
        rtReceivedMask = 0
        currentTextAB = nil
        afSet.removeAll()
        demodulator.reset()
    }

    private func updatePeriodic() {
        let stats = demodulator.streamDecoder.stats
        info.syncState = stats.syncState
        info.groupsReceived = stats.groupsReceived
        info.blocksReceived = stats.blocksReceived
        info.blockErrors = stats.blockErrors
    }

    private func handleGroup(_ group: RDSGroup) {
        // Block A: PI-Code
        info.pi = group.pi

        // Block B: TP und PTY
        info.tp = group.tp
        info.pty = group.pty

        switch (group.groupType, group.isVersionB) {
        case (0, false), (0, true):
            handleGroup0(group)
        case (2, false), (2, true):
            handleGroup2(group)
        case (4, false):
            handleGroup4A(group)
        default:
            break
        }
    }

    private func handleGroup0(_ group: RDSGroup) {
        let bB = group.blockB.data
        info.ta = ((bB >> 4) & 1) == 1
        info.music = ((bB >> 3) & 1) == 1
        let seg = Int(bB & 0x03)

        // Block D: 2 Zeichen des PS-Namens
        let bD = group.blockD.data
        let c0 = Character(UnicodeScalar((bD >> 8) & 0xFF) ?? UnicodeScalar(32))
        let c1 = Character(UnicodeScalar(bD & 0xFF) ?? UnicodeScalar(32))

        if seg * 2 + 1 < psBuffer.count {
            psBuffer[seg * 2] = c0.isASCII ? c0 : " "
            psBuffer[seg * 2 + 1] = c1.isASCII ? c1 : " "
            psReceivedMask |= (1 << seg)
        }

        if psReceivedMask == 0x0F {
            info.programService = String(psBuffer).trimmingCharacters(in: .whitespaces)
        }

        // Gruppe 0A: Alternativfrequenzen in Block C
        if !group.isVersionB {
            let bC = group.blockC.data
            let af1 = Int((bC >> 8) & 0xFF)
            let af2 = Int(bC & 0xFF)
            decodeAF(af1)
            decodeAF(af2)
            info.alternativeFrequencies = Array(afSet).sorted()
        }
    }

    private func decodeAF(_ code: Int) {
        // Code 1..204 = 87.6 .. 107.9 MHz (87.5 + code * 0.1)
        if (1...204).contains(code) {
            let mhz = 87.5 + Double(code) * 0.1
            afSet.insert((mhz * 10).rounded() / 10)
        }
    }

    private func handleGroup2(_ group: RDSGroup) {
        let bB = group.blockB.data
        let textAB = ((bB >> 4) & 1) == 1
        let seg = Int(bB & 0x0F)

        // Text A/B Flag-Wechsel leert den Text
        if let cur = currentTextAB, cur != textAB {
            if !info.radioText.isEmpty && !info.radioTextHistory.contains(info.radioText) {
                info.radioTextHistory.insert(info.radioText, at: 0)
                if info.radioTextHistory.count > 30 { info.radioTextHistory.removeLast() }
            }
            rtBuffer = [Character](repeating: " ", count: 64)
            rtReceivedMask = 0
        }
        currentTextAB = textAB

        if !group.isVersionB {
            // Gruppe 2A: 4 Zeichen je Gruppe (Block C und D)
            let bC = group.blockC.data
            let bD = group.blockD.data
            let c0 = Character(UnicodeScalar((bC >> 8) & 0xFF) ?? UnicodeScalar(32))
            let c1 = Character(UnicodeScalar(bC & 0xFF) ?? UnicodeScalar(32))
            let c2 = Character(UnicodeScalar((bD >> 8) & 0xFF) ?? UnicodeScalar(32))
            let c3 = Character(UnicodeScalar(bD & 0xFF) ?? UnicodeScalar(32))

            let pos = seg * 4
            if pos + 3 < rtBuffer.count {
                rtBuffer[pos] = c0.isASCII ? c0 : " "
                rtBuffer[pos + 1] = c1.isASCII ? c1 : " "
                rtBuffer[pos + 2] = c2.isASCII ? c2 : " "
                rtBuffer[pos + 3] = c3.isASCII ? c3 : " "
                rtReceivedMask |= (1 << seg)
            }
        } else {
            // Gruppe 2B: 2 Zeichen je Gruppe (nur Block D)
            let bD = group.blockD.data
            let c0 = Character(UnicodeScalar((bD >> 8) & 0xFF) ?? UnicodeScalar(32))
            let c1 = Character(UnicodeScalar(bD & 0xFF) ?? UnicodeScalar(32))
            let pos = seg * 2
            if pos + 1 < rtBuffer.count {
                rtBuffer[pos] = c0.isASCII ? c0 : " "
                rtBuffer[pos + 1] = c1.isASCII ? c1 : " "
                rtReceivedMask |= (1 << seg)
            }
        }

        let fullText = String(rtBuffer).trimmingCharacters(in: .whitespaces)
        if !fullText.isEmpty {
            info.radioText = fullText
        }
    }

    private func handleGroup4A(_ group: RDSGroup) {
        let bB = UInt32(group.blockB.data)
        let bC = UInt32(group.blockC.data)
        let bD = UInt32(group.blockD.data)

        // MJD: 2 Bits aus Block B + 15 Bits aus Block C
        let mjd = ((bB & 0x03) << 15) | ((bC >> 1) & 0x7FFF)

        // Stunde: 1 Bit aus Block C + 4 Bits aus Block D
        let hour = Int(((bC & 1) << 4) | ((bD >> 12) & 0x0F))
        let minute = Int((bD >> 6) & 0x3F)

        guard hour < 24, minute < 60, mjd > 40000 else { return }

        // MJD zu Unix-Zeit: Unix-Epoche (1970-01-01) ist MJD 40587
        let days = Double(mjd) - 40587.0
        let seconds = days * 86400.0 + Double(hour * 3600 + minute * 60)

        // Lokaler Versatz (in halben Stunden)
        let offsetSign = ((bD >> 5) & 1) == 1 ? -1.0 : 1.0
        let offsetHalfHours = Double(bD & 0x1F)
        let localSeconds = seconds + offsetSign * offsetHalfHours * 1800.0

        info.clockTime = Date(timeIntervalSince1970: localSeconds)
    }
}
