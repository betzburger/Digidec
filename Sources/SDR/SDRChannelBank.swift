// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine

// Kanalbank: ein breitbandiger SDR (HackRF, 2,4 bis 9,6 MS/s) liefert ein I/Q-Fenster, aus dem mehrere Kanäle zugleich herausgeschnitten werden.
// Jeder Kanal hat einen eigenen Mischer und Demodulator (`SDRReceiverEngine.setExtraChannel`), sein Audio geht in eine eigene `AudioPipeline`,
// an der ein eigener Decoder hängt (APRS auf 144,8 MHz, AIS A und B, drei ACARS-Kanäle, Sonden …). Dies hier ist die Planung und der Zustand:
// welche Kanäle es gibt, wohin die Gerätemitte gehört und welche Kanäle im Fenster liegen.

/// Ein Kanal der Bank
public struct SDRBankSlot: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    /// Rohwert von `DecoderModuleInfo` (aprs, ais, acars …)
    public var moduleID: String
    public var frequencyHz: Double
    public var mode: SDRMode
    public var bandwidthHz: Double
    public var enabled: Bool
    /// Eigene Bezeichnung (leer: Modul und Frequenz)
    public var label: String

    public init(id: Int, moduleID: String, frequencyHz: Double, mode: SDRMode, bandwidthHz: Double, enabled: Bool = true, label: String = "") {
        self.id = id
        self.moduleID = moduleID
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.enabled = enabled
        self.label = label
    }

    public var channelConfig: SDRChannelConfig {
        var c = SDRChannelConfig(mode: mode)
        c.bandwidthHz = bandwidthHz
        // Digitale Verfahren und Datenfunk: keine De-Emphase, kein Squelch (der Decoder braucht das Rauschen zum Einrasten)
        c.deemphasis = false
        c.squelchEnabled = false
        return c
    }
}

/// Planung der Gerätemitte für eine Menge von Kanälen
public enum SDRBankPlanner {
    public struct Plan: Equatable, Sendable {
        /// Mitte des I/Q-Fensters
        public var loHz: Double
        /// Kanäle im Fenster (nach ID)
        public var covered: [Int]
        /// Eingeschaltete Kanäle außerhalb des Fensters
        public var uncovered: [Int]
        /// Breite von der tiefsten bis zur höchsten abgedeckten Frequenz
        public var spanHz: Double
    }

    /// Mindestabstand eines Kanals von der Gerätemitte (dort sitzt die Gleichanteil-Spitze)
    public static let dcGuardHz = 40_000.0

    /// Wählt die Mitte so, dass möglichst viele eingeschaltete Kanäle ins Fenster passen; bei Gleichstand gewinnt das Fenster mit dem ersten Kanal.
    /// `halfWindowHz`: nutzbare halbe Breite des Fensters (Kanäle müssen mit ihrer halben Bandbreite hineinpassen).
    public static func plan(slots: [SDRBankSlot], halfWindowHz: Double, currentLoHz: Double? = nil) -> Plan {
        let active = slots.filter(\.enabled)
        guard !active.isEmpty else { return Plan(loHz: currentLoHz ?? 0, covered: [], uncovered: [], spanHz: 0) }
        func fits(_ s: SDRBankSlot, _ lo: Double) -> Bool { abs(s.frequencyHz - lo) + s.bandwidthHz / 2 <= halfWindowHz }
        // Kandidaten: Fenster, das am tiefsten Rand eines Kanals beginnt
        var best: (covered: [SDRBankSlot], lo: Double)?
        for anchor in active {
            let lo = anchor.frequencyHz - anchor.bandwidthHz / 2 + halfWindowHz       // Fenster beginnt am unteren Rand des Ankers
            let inside = active.filter { fits($0, lo) }
            guard inside.contains(where: { $0.id == anchor.id }) else { continue }
            if best == nil || inside.count > best!.covered.count { best = (inside, lo) }
        }
        // Kein Anker passt (Kanal breiter als das Fenster): Mitte auf den ersten Kanal
        let chosen = best ?? ([], active[0].frequencyHz)
        var covered = chosen.covered
        if covered.isEmpty { covered = active.filter { fits($0, chosen.lo) } }
        let low = covered.map { $0.frequencyHz }.min() ?? chosen.lo
        let high = covered.map { $0.frequencyHz }.max() ?? chosen.lo
        var lo = (low + high) / 2
        // Bleibt die Mitte beim bisherigen Wert, wenn der alle abgedeckten Kanäle trägt? Dann kein Umstimmen des Geräts nötig.
        if let current = currentLoHz, covered.allSatisfy({ fits($0, current) && abs($0.frequencyHz - current) >= dcGuardHz }) {
            lo = current
        } else if covered.contains(where: { abs($0.frequencyHz - lo) < dcGuardHz }) {
            // Gleichanteil-Spitze meiden: Mitte seitlich versetzen, solange alle Kanäle im Fenster bleiben
            for shift in [60_000.0, -60_000, 100_000, -100_000, 150_000, -150_000] {
                let candidate = lo + shift
                if covered.allSatisfy({ fits($0, candidate) && abs($0.frequencyHz - candidate) >= dcGuardHz }) { lo = candidate; break }
            }
        }
        covered = covered.filter { fits($0, lo) }
        let coveredIDs = Set(covered.map(\.id))
        return Plan(loHz: lo.rounded(), covered: covered.map(\.id).sorted(), uncovered: active.map(\.id).filter { !coveredIDs.contains($0) }.sorted(), spanHz: high - low)
    }
}

/// Zustand der Kanalbank (Kanäle, Planung, Pegel). Die Anbindung an das Gerät macht `SDRController`.
@MainActor
public final class SDRChannelBank: ObservableObject {
    @Published public private(set) var slots: [SDRBankSlot] {
        didSet { persist() }
    }
    @Published public private(set) var plan = SDRBankPlanner.Plan(loHz: 0, covered: [], uncovered: [], spanHz: 0)
    /// Kanalleistung je Kanal in dB zur Vollaussteuerung
    @Published public private(set) var levels: [Int: Double] = [:]
    /// Kanal, der über den Lautsprecher mitgehört wird
    @Published public var monitorID: Int? {
        didSet { if monitorID != oldValue { onChange?() } }
    }
    /// Der in der Liste gewählte Kanal (im Wasserfall hervorgehoben)
    @Published public var selectedID: Int?
    /// Frequenz, die der Nutzer im Wasserfall angeklickt hat (Vorbelegung für einen neuen Kanal)
    @Published public var pendingFrequencyHz: Double?
    /// Läuft die Bank (Modul KANÄLE ist gewählt)?
    @Published public private(set) var isActive = false

    /// Wird nach jeder Änderung der Kanäle gerufen (Controller: Gerät umstimmen, Kanäle an die Engine geben)
    public var onChange: (() -> Void)?

    private var nextID = 1
    public static let maxSlots = 16
    private static let key = "sdrBankSlots"

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([SDRBankSlot].self, from: data) {
            slots = saved
        } else {
            slots = []
        }
        nextID = (slots.map(\.id).max() ?? 0) + 1
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(slots) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Kanäle

    @discardableResult
    public func add(moduleID: String, frequencyHz: Double, mode: SDRMode, bandwidthHz: Double, label: String = "") -> SDRBankSlot? {
        guard slots.count < Self.maxSlots else { return nil }
        let slot = SDRBankSlot(id: nextID, moduleID: moduleID, frequencyHz: frequencyHz, mode: mode, bandwidthHz: bandwidthHz, label: label)
        nextID += 1
        slots.append(slot)
        onChange?()
        return slot
    }

    public func remove(id: Int) {
        slots.removeAll { $0.id == id }
        levels[id] = nil
        onChange?()
    }

    public func update(_ slot: SDRBankSlot) {
        guard let i = slots.firstIndex(where: { $0.id == slot.id }), slots[i] != slot else { return }
        slots[i] = slot
        onChange?()
    }

    public func setEnabled(id: Int, _ on: Bool) {
        guard var s = slots.first(where: { $0.id == id }) else { return }
        s.enabled = on
        update(s)
    }

    public func removeAll() {
        slots.removeAll()
        levels.removeAll()
        onChange?()
    }

    public func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        onChange?()
    }

    public func slot(id: Int) -> SDRBankSlot? { slots.first { $0.id == id } }

    // MARK: Planung

    /// Neu planen; liefert die Mitte, auf die das Gerät gehört (nil, wenn die Bank nichts zu tun hat)
    @discardableResult
    public func replan(sampleRate: Int, currentLoHz: Double?) -> SDRBankPlanner.Plan {
        let p = SDRBankPlanner.plan(slots: slots, halfWindowHz: SDRSettingsStore.window(forRate: sampleRate), currentLoHz: currentLoHz)
        if p != plan { plan = p }
        return p
    }

    func setLevels(_ new: [Int: Double]) {
        if new != levels { levels = new }
    }
}
