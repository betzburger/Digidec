// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - KANÄLE: Kanalliste und Decoder des gewählten Kanals

struct ChannelsMainPanel: View {
    @ObservedObject var hub: ChannelHub
    @ObservedObject var bank: SDRChannelBank
    @ObservedObject var controller: SDRController

    @State private var module: DecoderModuleInfo = .aprs
    @State private var presetID = ""
    @State private var frequencyText = ""

    private var presets: [ChannelPreset] { ChannelCatalog.presets(for: module) }

    var body: some View {
        VStack(spacing: 6) {
            addBar
            planLine
            if bank.slots.isEmpty {
                emptyHint
            } else {
                channelList
                if let id = bank.selectedID, let instance = hub.instances[id] {
                    ChannelInstanceDetail(instance: instance)
                        .frame(maxHeight: .infinity)
                        .id(id)
                }
            }
        }
        .onAppear { applyPreset() }
        .onChange(of: bank.pendingFrequencyHz) { _, new in
            if let new { frequencyText = Self.mhz(new); presetID = "" }
        }
    }

    // MARK: Kanal hinzufügen

    private var addBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $module) {
                ForEach(ChannelCatalog.modules) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: module) { _, _ in presetID = presets.first?.id ?? ""; applyPreset() }
            .help("Decoder des neuen Kanals: dasselbe Verfahren wie im gleichnamigen Modul, läuft aber neben den anderen Kanälen")
            if !presets.isEmpty {
                Picker("", selection: $presetID) {
                    ForEach(presets) { Text($0.title).tag($0.id) }
                    Text("Frequenz …").tag("")
                }
                .labelsHidden()
                .frame(maxWidth: 210)
                .onChange(of: presetID) { _, _ in applyPreset() }
            }
            TextField("MHz", text: $frequencyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
                .multilineTextAlignment(.center)
                .frame(width: 100)
                .padding(.vertical, 3)
                .background(RadioTheme.bgDeep)
                .cornerRadius(4)
                .onSubmit { add() }
                .help("Frequenz in MHz; ein Klick in den HF-Wasserfall trägt sie ein")
            Button { add() } label: { Label("KANAL", systemImage: "plus") }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(parsedFrequency == nil || bank.slots.count >= SDRChannelBank.maxSlots)
                .help("Kanal mit diesem Decoder hinzufügen (bis zu \(SDRChannelBank.maxSlots))")
            Spacer(minLength: 0)
        }
    }

    private var parsedFrequency: Double? {
        let t = frequencyText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let mhz = Double(t), mhz > 0.1, mhz < 6000 else { return nil }
        return (mhz * 1e6).rounded()
    }

    private func applyPreset() {
        if let p = presets.first(where: { $0.id == presetID }) { frequencyText = Self.mhz(p.frequencyHz) }
        else if presetID.isEmpty, let p = presets.first, frequencyText.isEmpty { presetID = p.id; frequencyText = Self.mhz(p.frequencyHz) }
    }

    private func add() {
        guard let f = parsedFrequency else { return }
        // Passt die Frequenz zur gewählten Voreinstellung, gelten deren Betriebsart, Breite und Decoder-Einstellung
        let d = ChannelCatalog.defaults(for: module)
        let p = presets.first { $0.id == presetID && abs($0.frequencyHz - f) < 1 }
        let slot = bank.add(moduleID: module.rawValue, frequencyHz: f, mode: p?.mode ?? d.mode, bandwidthHz: p?.bandwidthHz ?? d.bandwidthHz, preset: p?.option)
        bank.pendingFrequencyHz = nil
        if let slot { bank.selectedID = slot.id }
    }

    static func mhz(_ hz: Double) -> String { String(format: "%.4f", hz / 1e6).replacingOccurrences(of: ".", with: ",") }

    // MARK: Planung

    private var planLine: some View {
        HStack(spacing: 8) {
            Text("MITTE \(SDRFormat.frequency(controller.loHz)) MHz · FENSTER \(String(format: "%.1f", controller.sampleRateHz / 1e6).replacingOccurrences(of: ".", with: ",")) MS/s")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
            if !bank.plan.uncovered.isEmpty {
                Text("\(bank.plan.uncovered.count) Kanal außerhalb des Fensters: größere Abtastrate (HackRF) oder Kanäle näher zusammen")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
                    .lineLimit(1)
            }
            Spacer()
            if let m = controller.tuneMessage {
                Text(m).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.ledYellow).lineLimit(1)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Noch keine Kanäle")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
            Text("Decoder und Frequenz wählen und KANAL drücken, oder im HF-Wasserfall klicken. Jeder Kanal bekommt seinen eigenen Decoder; alle laufen zugleich aus dem Fenster des SDR (HackRF: bei 4,8 oder 9,6 MS/s bis zu 7 MHz breit).")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Liste

    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(Array(bank.slots.enumerated()), id: \.element.id) { n, slot in
                    ChannelRow(number: n + 1, slot: slot, bank: bank, instance: hub.instances[slot.id],
                               level: bank.levels[slot.id], covered: bank.plan.covered.contains(slot.id))
                }
            }
        }
        .frame(maxHeight: min(CGFloat(bank.slots.count) * 28 + 4, 190))
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}

private struct ChannelRow: View {
    let number: Int
    let slot: SDRBankSlot
    @ObservedObject var bank: SDRChannelBank
    let instance: ChannelInstance?
    let level: Double?
    let covered: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let selected = bank.selectedID == slot.id
        HStack(spacing: 8) {
            Button { bank.setEnabled(id: slot.id, !slot.enabled) } label: {
                Image(systemName: slot.enabled ? "power.circle.fill" : "power.circle")
                    .foregroundColor(slot.enabled ? (covered ? RadioTheme.vfdGreen : RadioTheme.ledYellow) : RadioTheme.textDim)
            }
            .buttonStyle(.plain)
            .help(slot.enabled ? (covered ? "Kanal läuft; ausschalten" : "Kanal liegt außerhalb des Fensters") : "Kanal einschalten")
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(selected ? RadioTheme.vfdAmber : RadioTheme.textDim)
                .frame(width: 16)
            Text(DecoderModuleInfo(rawValue: slot.moduleID)?.displayName ?? slot.moduleID)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
                .frame(width: 64, alignment: .leading)
            TextField("MHz", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
                .frame(width: 84)
                .focused($focused)
                .onSubmit { commit() }
                .help("Frequenz in MHz ändern und Return drücken")
            Text("\(slot.mode.title) \(bandwidthText)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .frame(width: 64, alignment: .leading)
            LevelBar(db: level ?? -120, on: slot.enabled && covered)
                .frame(width: 70, height: 8)
            Text(instance?.summary ?? "")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textBright)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { bank.monitorID = bank.monitorID == slot.id ? nil : slot.id } label: {
                Image(systemName: bank.monitorID == slot.id ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .foregroundColor(bank.monitorID == slot.id ? RadioTheme.vfdAmber : RadioTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Diesen Kanal über den Lautsprecher mithören (Lautstärke im SDR-Feld)")
            Button { bank.remove(id: slot.id) } label: { Image(systemName: "xmark.circle").foregroundColor(RadioTheme.textDim) }
                .buttonStyle(.plain)
                .help("Kanal entfernen")
        }
        .padding(.horizontal, 6)
        .frame(height: 27)
        .background(selected ? RadioTheme.vfdAmber.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { bank.selectedID = slot.id }
        .onAppear { text = ChannelsMainPanel.mhz(slot.frequencyHz) }
        .onChange(of: slot.frequencyHz) { _, new in if !focused { text = ChannelsMainPanel.mhz(new) } }
    }

    private var bandwidthText: String {
        slot.bandwidthHz >= 1000 ? String(format: "%g k", slot.bandwidthHz / 1000).replacingOccurrences(of: ".", with: ",") : String(format: "%g", slot.bandwidthHz)
    }

    private func commit() {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let mhz = Double(t), mhz > 0.1, mhz < 6000 {
            var s = slot
            s.frequencyHz = (mhz * 1e6).rounded()
            bank.update(s)
        }
        text = ChannelsMainPanel.mhz(slot.frequencyHz)
    }
}

private struct LevelBar: View {
    let db: Double
    let on: Bool

    var body: some View {
        GeometryReader { geo in
            let v = CGFloat(max(0, min(1, (db + 100) / 100)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(RadioTheme.bgPanel)
                RoundedRectangle(cornerRadius: 2).fill(on ? RadioTheme.vfdGreen : RadioTheme.textDim).frame(width: geo.size.width * v)
            }
        }
    }
}

/// Der Decoder des gewählten Kanals mit seiner gewohnten Ansicht
private struct ChannelInstanceDetail: View {
    @ObservedObject var instance: ChannelInstance

    var body: some View {
        instance.view
    }
}

// MARK: - KANÄLE: Einstellungen

struct ChannelsSettingsPanel: View {
    @ObservedObject var bank: SDRChannelBank
    @ObservedObject var settings: SDRSettingsStore
    @ObservedObject var controller: SDRController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SDRWindowPicker(settings: settings)
            HStack(spacing: 6) {
                Text("KANÄLE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Text("\(bank.slots.filter(\.enabled).count) von \(SDRChannelBank.maxSlots) · \(bank.plan.covered.count) im Fenster")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                Spacer()
                Button("ALLE ENTFERNEN") { bank.removeAll() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(bank.slots.isEmpty)
                    .scaleEffect(0.9, anchor: .trailing)
            }
            Text("Jeder Kanal hat einen eigenen Decoder mit den Einstellungen des gleichnamigen Moduls. Die Sprachausgabe der digitalen Verfahren (DMR, D-STAR, YSF, dPMR, NXDN, P25, M17) ist in den Kanälen aus. Die Gerätemitte stellt Digidec so ein, dass möglichst viele Kanäle ins Fenster passen. Der Eingang SDR wird mit dem Modul gewählt; Verstärkung und Gerät stehen im SDR-Feld.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
