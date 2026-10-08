// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI
import Combine

// Mehrkanalbetrieb: zu jedem Kanal der Kanalbank (`SDRChannelBank`) gehört ein eigener Decoder desselben Aufbaus wie im gleichnamigen Modul, mit eigener
// `AudioPipeline`. Der Kanal liefert sein Audio in diese Pipeline (Engine des SDR-Empfängers), der Decoder liest es dort. So laufen APRS auf 144,8 MHz,
// AIS A und B, drei ACARS-Kanäle und eine Sonde gleichzeitig aus einem einzigen HackRF-Fenster. Die Einstellungen der Decoder werden aus den Modulen
// gelesen und nicht verändert; Sprachausgabe der digitalen Sprachverfahren ist in den Kanälen aus (der Stick gehört dem Hauptmodul).

/// Ein laufender Decoder zu einem Kanal der Bank
@MainActor
public final class ChannelInstance: ObservableObject, Identifiable {
    public nonisolated let slotID: Int
    public let module: DecoderModuleInfo
    public let pipeline: AudioPipeline
    /// Der Decoder-Controller dieses Kanals (APRSController, AISController …)
    public let controller: AnyObject
    private let activate: (Bool) -> Void
    private let summaryText: () -> String
    private let makeView: () -> AnyView
    private var running = false
    private var forward: AnyCancellable?

    public nonisolated var id: Int { slotID }

    init(slotID: Int, module: DecoderModuleInfo, pipeline: AudioPipeline, controller: AnyObject, objectWillChange publisher: AnyPublisher<Void, Never>,
         activate: @escaping (Bool) -> Void, summary: @escaping () -> String, view: @escaping () -> AnyView) {
        self.slotID = slotID
        self.module = module
        self.pipeline = pipeline
        self.controller = controller
        self.activate = activate
        summaryText = summary
        makeView = view
        forward = publisher.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Kurze Zusammenfassung des Standes („12 Stationen“)
    public var summary: String { summaryText() }

    public var view: AnyView { makeView() }

    public var isRunning: Bool { running }

    public func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            pipeline.sourceChannels = 1
            pipeline.start(inputRate: SDRDemodulator.audioRate)
            activate(true)
        } else {
            activate(false)
            pipeline.stop()
        }
    }
}

/// Verwaltet die Decoder der Kanäle: legt sie an, wenn ein Kanal entsteht, startet und stoppt sie mit der Bank
@MainActor
public final class ChannelHub: ObservableObject {
    public let bank: SDRChannelBank
    private unowned let state: DigidecState
    @Published public private(set) var instances: [Int: ChannelInstance] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(bank: SDRChannelBank, state: DigidecState) {
        self.bank = bank
        self.state = state
        bank.$slots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        bank.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
    }

    /// Die Controller eines Typs in allen Kanälen (für die Verbindung der Dienste: AIS, ACARS, DSC …)
    func controllers<T>(of type: T.Type) -> [T] {
        instances.values.compactMap { $0.controller as? T }
    }

    /// Audio-Ziel eines Kanals für die Engine des SDR-Empfängers
    func audioHandler(for slotID: Int) -> SDRReceiverEngine.AudioHandler? {
        guard let instance = instances[slotID] else { return nil }
        let ring = instance.pipeline.ring
        return { buf in if let base = buf.baseAddress { ring.write(base, count: buf.count) } }
    }

    /// Decoder zu den Kanälen der Bank anlegen bzw. entfernen und nach Zustand der Bank starten oder anhalten
    func sync() {
        let ids = Set(bank.slots.map(\.id))
        for (id, instance) in instances where !ids.contains(id) {
            instance.setRunning(false)
            instances[id] = nil
            UserDefaults.standard.removePersistentDomain(forName: Self.domain(slotID: id))
        }
        for slot in bank.slots {
            if let existing = instances[slot.id], existing.module.rawValue != slot.moduleID {
                existing.setRunning(false)
                instances[slot.id] = nil
            }
            if instances[slot.id] == nil, let module = DecoderModuleInfo(rawValue: slot.moduleID), let made = make(slot: slot, module: module) {
                instances[slot.id] = made
            }
        }
        for slot in bank.slots {
            instances[slot.id]?.setRunning(bank.isActive && slot.enabled)
        }
        if bank.selectedID == nil || instances[bank.selectedID!] == nil { bank.selectedID = bank.slots.first?.id }
    }

    // MARK: Decoder je Modul

    /// Eigener Einstellungsspeicher eines Kanals: die Kurzwellen-Decoder lesen und schreiben ihre Einstellungen dort, nicht in die des Moduls
    static func domain(slotID: Int) -> String { "com.peterbetz.digidec.channel.\(slotID)" }

    private func isolatedDefaults(_ slot: SDRBankSlot) -> UserDefaults {
        UserDefaults(suiteName: Self.domain(slotID: slot.id)) ?? .standard
    }

    private func make(slot: SDRBankSlot, module: DecoderModuleInfo) -> ChannelInstance? {
        let pipeline = AudioPipeline()
        let home = state.home
        let voiceOutput = state.dstarController.output
        func build<C: ObservableObject & AnyObject>(_ controller: C, activate: @escaping (Bool) -> Void, summary: @escaping () -> String, view: @escaping () -> AnyView) -> ChannelInstance {
            ChannelInstance(slotID: slot.id, module: module, pipeline: pipeline, controller: controller, objectWillChange: controller.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                            activate: activate, summary: summary, view: view)
        }
        switch module {
        case .aprs:
            let settings = APRSSettingsStore()
            let c = APRSController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.stations.count) Stationen" }, view: { AnyView(APRSMainPanel(controller: c, settings: settings, home: home)) })
        case .packet:
            let settings = PacketSettingsStore()
            let c = PacketController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.stations.count) Stationen" }, view: { AnyView(PacketMainPanel(controller: c, settings: settings)) })
        case .ais:
            let settings = AISSettingsStore()
            let c = AISController(pipeline: pipeline, settings: settings)
            c.homePoint = home.point
            c.forcedChannel = abs(slot.frequencyHz - AISChannel.frequencyB) < abs(slot.frequencyHz - AISChannel.frequencyA) ? .b : .a
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.ships.count) Schiffe" }, view: { AnyView(AISMainPanel(controller: c, settings: settings, home: home)) })
        case .acars:
            let settings = ACARSSettingsStore()
            let c = ACARSController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.messages.count) Nachrichten" }, view: { AnyView(ACARSMessagePanel(controller: c, settings: settings)) })
        case .pager:
            let settings = PagerSettingsStore()
            let c = PagerController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.messages.count) Meldungen" }, view: { AnyView(PagerMessagePanel(controller: c, settings: settings)) })
        case .sonde:
            let settings = SondeSettingsStore()
            let c = SondeController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.flights.count) Sonden" }, view: { AnyView(SondeMainPanel(controller: c, settings: settings, home: home)) })
        case .dsc:
            let settings = DSCSettingsStore(defaults: isolatedDefaults(slot))
            if let o = slot.preset, let ch = DSCChannel(rawValue: o) { settings.channel = ch }
            settings.setCenter(ChannelCatalog.audioCenter(for: .dsc))
            let c = DSCController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.messages.count) Meldungen" }, view: { AnyView(DSCMessagePanel(controller: c)) })
        case .rtty:
            let settings = RTTYSettingsStore(defaults: isolatedDefaults(slot))
            settings.select(presetID: slot.preset ?? "ham")
            settings.setCenter(ChannelCatalog.audioCenter(for: .rtty))
            // Der SYNOP-Decoder ist ein einziger Zustand im C++-Kern und gehört dem Modul RTTY; die Kanäle zeigen den Text
            var options = settings.options
            options.synopDecoding = false
            settings.options = options
            let c = RTTYController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.decoder.setEnabled($0) }, summary: { "\(c.textModel.characterCount) Zeichen" }, view: { AnyView(ReceivePanel(controller: c, settings: settings)) })
        case .navtex:
            let settings = NavtexSettingsStore(defaults: isolatedDefaults(slot))
            if let o = slot.preset, let f = NavtexFrequency(rawValue: o) { settings.frequency = f }
            settings.setCenter(ChannelCatalog.audioCenter(for: .navtex))
            let c = NavtexController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.entries.count) Meldungen" }, view: { AnyView(NavtexReceivePanel(controller: c)) })
        case .wefax:
            let settings = WefaxSettingsStore(defaults: isolatedDefaults(slot))
            if let o = slot.preset, let st = WefaxStation(rawValue: o) { settings.station = st }
            let c = WefaxController(pipeline: pipeline, settings: settings)
            let state = self.state
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.gallery.count) Bilder" },
                         view: { AnyView(WefaxImagePanel(controller: c, schedule: state.wefaxSchedule, auto: state.autoRecorder, openSchedule: { state.scheduleSheet = .wefax })) })
        case .hfdl:
            let settings = HFDLSettingsStore(defaults: isolatedDefaults(slot))
            if let o = slot.preset, let k = HFDLChannels.kHz(presetID: o) { settings.frequencyKHz = k }
            let c = HFDLController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.aircraft.count) Flugzeuge" }, view: { AnyView(HFDLMessagePanel(controller: c, settings: settings)) })
        case .sstv:
            let settings = SSTVSettingsStore(defaults: isolatedDefaults(slot))
            if let o = slot.preset, let ch = SSTVChannel(rawValue: o) { settings.channel = ch }
            let c = SSTVController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.gallery.count) Bilder" }, view: { AnyView(SSTVImagePanel(controller: c)) })
        case .vor:
            let settings = NavSettingsStore()
            let c = NavController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { c.ident.isEmpty ? "—" : c.ident }, view: { AnyView(NavMainPanel(controller: c, settings: settings)) })
        case .tones:
            let settings = TonesSettingsStore()
            let c = TonesController(pipeline: pipeline, settings: settings)
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.sequences.count) Folgen" }, view: { AnyView(TonesListPanel(controller: c, settings: settings)) })
        case .dmr:
            let settings = DMRSettingsStore()
            let c = DMRController(pipeline: pipeline, settings: settings)
            c.silent = true
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.calls.count) Gespräche" }, view: { AnyView(DMRMainPanel(controller: c, settings: settings, output: voiceOutput)) })
        case .dstar:
            let settings = DStarSettingsStore()
            let c = DStarController(pipeline: pipeline, settings: settings)
            c.silent = true
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.transmissions.count) Aussendungen" }, view: { AnyView(DStarMainPanel(controller: c, settings: settings)) })
        case .ysf:
            let settings = YSFSettingsStore()
            let c = YSFController(pipeline: pipeline, settings: settings)
            c.silent = true
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.calls.count) Gespräche" }, view: { AnyView(YSFMainPanel(controller: c, settings: settings, output: voiceOutput)) })
        case .dpmr:
            let settings = DPMRSettingsStore()
            let c = DPMRController(pipeline: pipeline, settings: settings)
            c.silent = true
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.calls.count) Gespräche" }, view: { AnyView(DPMRMainPanel(controller: c, settings: settings, output: voiceOutput)) })
        case .nxdn:
            let settings = NXDNSettingsStore()
            let c = NXDNController(pipeline: pipeline, settings: settings)
            c.silent = true
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.calls.count) Gespräche" }, view: { AnyView(NXDNMainPanel(controller: c, settings: settings, output: voiceOutput)) })
        case .m17:
            let settings = M17SettingsStore()
            let c = M17Controller(pipeline: pipeline, settings: settings)
            c.silence()
            return build(c, activate: { c.setActive($0) }, summary: { "\(c.calls.count) Gespräche" }, view: { AnyView(M17MainPanel(controller: c, settings: settings)) })
        default:
            return nil
        }
    }
}
