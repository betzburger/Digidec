// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

public struct RDSPanelView: View {
    @ObservedObject var controller: RDSController
    @ObservedObject var settings: RDSSettingsStore
    @ObservedObject var sdr: SDRController

    @State private var freqText: String = ""
    @FocusState private var freqFocused: Bool

    public init(controller: RDSController, settings: RDSSettingsStore, sdr: SDRController) {
        self.controller = controller
        self.settings = settings
        self.sdr = sdr
    }

    private var info: RDSInfo { controller.info }

    public var body: some View {
        VStack(spacing: 8) {
            // Kopfbereich: Station & Frequenz
            stationHeaderCard

            // Hauptbereich: Radiotext, Details und Alternativfrequenzen
            HStack(alignment: .top, spacing: 8) {
                // Linke Spalte: Radiotext & Historie
                VStack(spacing: 8) {
                    radioTextCard
                    radioTextHistoryCard
                }
                .frame(maxWidth: .infinity)

                // Rechte Spalte: Alternativfrequenzen, Details & Statistik
                VStack(spacing: 8) {
                    detailsCard
                    afCard
                    statsCard
                }
                .frame(width: 280)
            }

            // Unterer Bereich: Schnellauswahl / Presets
            presetsCard
        }
        .padding(8)
        .onAppear {
            freqText = String(format: "%.3f", settings.frequencyHz / 1e6).replacingOccurrences(of: ".", with: ",")
        }
        .onChange(of: settings.frequencyHz) { _, new in
            if !freqFocused {
                freqText = String(format: "%.3f", new / 1e6).replacingOccurrences(of: ".", with: ",")
            }
        }
    }

    // MARK: - Stationskopf

    private var stationHeaderCard: some View {
        RadioBox {
            VStack(spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    // Sendernamen-Anzeige (PS)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PROGRAM SERVICE (PS)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                        Text(info.programService.isEmpty ? "—— —— ——" : info.programService)
                            .font(.system(size: 26, weight: .black, design: .monospaced))
                            .foregroundColor(info.programService.isEmpty ? RadioTheme.textDim : RadioTheme.vfdGreen)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RadioTheme.bgDeep)
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(RadioTheme.borderSubtle, lineWidth: 1))
                    }

                    // Frequenzeinstellung
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UKW-FREQUENZ")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                        HStack(spacing: 4) {
                            Button("−") { controller.step(mhz: -0.1) }
                                .buttonStyle(ModeButtonStyle(isSelected: false))
                            TextField("MHz", text: $freqText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.vfdAmber)
                                .multilineTextAlignment(.center)
                                .frame(width: 110)
                                .focused($freqFocused)
                                .onSubmit { commitFrequency() }
                                .padding(.vertical, 4)
                                .background(RadioTheme.bgDeep)
                                .cornerRadius(5)
                            Button("+") { controller.step(mhz: 0.1) }
                                .buttonStyle(ModeButtonStyle(isSelected: false))
                            Text("MHz")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                        }
                    }

                    Spacer()

                    // Signal- & Sync-Badges
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            badge(text: "TP", active: info.tp, color: RadioTheme.vfdCyan)
                            badge(text: "TA", active: info.ta, color: Color.red)
                            if let m = info.music {
                                badge(text: m ? "MUSIK" : "SPRACHE", active: true, color: RadioTheme.vfdAmber)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(info.syncState.rawValue)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(info.syncState == .synced ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
                            Text(String(format: "%.0f dB", controller.signalDB))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(RadioTheme.vfdCyan)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func commitFrequency() {
        let cleaned = freqText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let mhz = Double(cleaned), mhz >= 87.5, mhz <= 108.0 {
            controller.tune(frequencyHz: mhz * 1e6)
        }
        freqText = String(format: "%.3f", settings.frequencyHz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    private func badge(text: String, active: Bool, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundColor(active ? color : RadioTheme.textDim.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((active ? color : Color.gray).opacity(active ? 0.18 : 0.05))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? color.opacity(0.4) : Color.clear, lineWidth: 1))
    }

    // MARK: - Radiotext

    private var radioTextCard: some View {
        RadioBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("RADIOTEXT (RT)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(0.8)
                    Spacer()
                    if !info.radioText.isEmpty {
                        Text("\(info.radioText.count) Z.")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                }
                Text(info.radioText.isEmpty ? "Warte auf Radiotext …" : info.radioText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(info.radioText.isEmpty ? RadioTheme.textDim : RadioTheme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(5)
            }
            .padding(4)
        }
    }

    private var radioTextHistoryCard: some View {
        RadioBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("VERLAUF RADIOTEXT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .tracking(0.8)

                if info.radioTextHistory.isEmpty {
                    Text("Keine früheren Radiotexte")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(info.radioTextHistory, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundColor(RadioTheme.vfdAmber)
                                    Text(item)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(RadioTheme.textMuted)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Details (PI, PTY, CT)

    private var detailsCard: some View {
        RadioBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("PROGRAMMDATEN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .tracking(0.8)

                detailRow(label: "PI-CODE", value: info.piHex.map { "0x\($0)" } ?? "—")
                if let country = info.country {
                    detailRow(label: "LAND", value: country)
                }
                detailRow(label: "PROGRAMMART", value: info.ptyName ?? "—")
                if let ct = info.clockTimeFormatted {
                    detailRow(label: "SENDERUHR (CT)", value: ct)
                }
            }
            .padding(4)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }

    // MARK: - Alternativfrequenzen (AF)

    private var afCard: some View {
        RadioBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("ALTERNATIVFREQUENZEN (AF)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(0.8)
                    Spacer()
                    Text("\(info.alternativeFrequencies.count)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }

                if info.alternativeFrequencies.isEmpty {
                    Text("Keine AF gemeldet")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .padding(.vertical, 4)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 4) {
                        ForEach(info.alternativeFrequencies, id: \.self) { af in
                            Button(String(format: "%.1f", af).replacingOccurrences(of: ".", with: ",")) {
                                controller.tune(frequencyHz: af * 1e6)
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: (settings.frequencyHz / 1e6).rounded() == af.rounded()))
                            .scaleEffect(0.85)
                            .help("Auf \(af) MHz abstimmen")
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Statistik

    private var statsCard: some View {
        RadioBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("RDS-STATISTIK")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .tracking(0.8)

                detailRow(label: "GRUPPEN", value: "\(info.groupsReceived)")
                detailRow(label: "BLÖCKE", value: "\(info.blocksReceived)")
                detailRow(label: "FEHLERRATE", value: String(format: "%.1f %%", 100.0 - info.blockSuccessRate))
            }
            .padding(4)
        }
    }

    // MARK: - Presets

    private var presetsCard: some View {
        RadioBox {
            HStack(spacing: 6) {
                Text("SCHNELLAUSWAHL")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(RDSSettingsStore.standardPresets, id: \.name) { preset in
                            Button(preset.name) {
                                controller.tune(frequencyHz: preset.freqHz)
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: abs(settings.frequencyHz - preset.freqHz) < 50_000))
                            .scaleEffect(0.85)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button("LEEREN") { controller.clear() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .scaleEffect(0.85)
                    .help("Alle empfangenen RDS-Daten zurücksetzen")
            }
            .padding(4)
        }
    }
}

// MARK: - Abstimmanzeige (rechte Spalte)

public struct RDSTuningPanel: View {
    @ObservedObject var controller: RDSController
    @ObservedObject var settings: RDSSettingsStore

    public init(controller: RDSController, settings: RDSSettingsStore) {
        self.controller = controller
        self.settings = settings
    }

    public var body: some View {
        let info = controller.info
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(info.syncState == .synced ? RadioTheme.vfdGreen : (info.syncState == .syncing ? RadioTheme.ledYellow : RadioTheme.ledRed))
                    .frame(width: 8, height: 8)
                Text("RDS")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(info.syncState.rawValue)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(info.syncState == .synced ? RadioTheme.vfdGreen : (info.syncState == .syncing ? RadioTheme.ledYellow : RadioTheme.ledRed))
                Spacer()
                Text(String(format: "%.0f dB", controller.signalDB))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
            }
            HStack {
                readout("PI-CODE", info.piHex.map { "0x\($0)" } ?? "—")
                Spacer()
                readout("LAND", info.country ?? "—")
            }
            HStack {
                readout("PROGRAMM", info.ptyName ?? "—")
            }
            HStack {
                readout("GRUPPEN", "\(info.groupsReceived)")
                Spacer()
                readout("BLÖCKE", "\(info.blocksReceived)")
            }
            HStack {
                readout("FEHLERRATE", String(format: "%.1f %%", 100.0 - info.blockSuccessRate))
                    .foregroundColor(info.blockSuccessRate > 80 ? RadioTheme.vfdCyan : RadioTheme.vfdAmber)
                Spacer()
                HStack(spacing: 3) {
                    badge(text: "TP", active: info.tp, color: RadioTheme.vfdCyan)
                    badge(text: "TA", active: info.ta, color: Color.red)
                    if let m = info.music {
                        badge(text: m ? "MUSIK" : "SPRACHE", active: true, color: RadioTheme.vfdAmber)
                    }
                }
            }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(RadioTheme.vfdCyan)
    }

    private func badge(text: String, active: Bool, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundColor(active ? color : RadioTheme.textDim.opacity(0.4))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background((active ? color : Color.gray).opacity(active ? 0.18 : 0.05))
            .cornerRadius(3)
    }
}

// MARK: - RDS Einstellungen (rechte Spalte)

public struct RDSSettingsPanel: View {
    @ObservedObject var controller: RDSController
    @ObservedObject var settings: RDSSettingsStore
    @ObservedObject var sdr: SDRController

    public init(controller: RDSController, settings: RDSSettingsStore, sdr: SDRController) {
        self.controller = controller
        self.settings = settings
        self.sdr = sdr
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Frequenzeinstellung
            HStack(spacing: 4) {
                Text("FREQUENZ").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                Button("−") { controller.step(mhz: -0.1) }.buttonStyle(ModeButtonStyle(isSelected: false))
                Text(String(format: "%.1f MHz", settings.frequencyHz / 1e6).replacingOccurrences(of: ".", with: ","))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .frame(minWidth: 70, alignment: .center)
                Button("+") { controller.step(mhz: 0.1) }.buttonStyle(ModeButtonStyle(isSelected: false))
            }

            // Schnellauswahl Presets
            VStack(alignment: .leading, spacing: 4) {
                Text("PRESETS").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62))], spacing: 4) {
                    ForEach(RDSSettingsStore.standardPresets, id: \.name) { preset in
                        Button(preset.name) {
                            controller.tune(frequencyHz: preset.freqHz)
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: abs(settings.frequencyHz - preset.freqHz) < 50_000))
                        .scaleEffect(0.85)
                    }
                }
            }

            Divider().overlay(RadioTheme.borderSubtle)

            HStack {
                Button("LEEREN") { controller.clear() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                Spacer()
                Text("WFM · 200 kHz · 57 kHz")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
        }
    }
}
