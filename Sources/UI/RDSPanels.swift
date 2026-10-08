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
        // Vertikal scrollbar: Wächst der Inhalt mit den empfangenen Daten (RT+, AF, Warnungen), bleibt das Fenster trotzdem im Bildschirm
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // Kopfbereich: Station & Frequenz
                stationHeaderCard

                // Hauptbereich: Radiotext, Details & Statistik
                HStack(alignment: .top, spacing: 8) {
                    // Linke Spalte: Radiotext & Historie
                    VStack(spacing: 8) {
                        radioTextCard
                        radioTextHistoryCard
                    }
                    .frame(maxWidth: .infinity)

                    // Rechte Spalte: Details & Statistik
                    VStack(spacing: 8) {
                        detailsCard
                        statsCard
                    }
                    .frame(width: 280)
                }

                // Alternativfrequenzen: volle Breite, eine Zeile
                afCard

                // Unterer Bereich: Schnellauswahl / Presets
                presetsCard
            }
            .padding(8)
        }
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
                            badge(text: sdr.snapshot.metrics.stereoLocked && sdr.settings.wfmStereo ? "STEREO" : "MONO", active: sdr.snapshot.metrics.stereoLocked && sdr.settings.wfmStereo, color: RadioTheme.vfdGreen)
                            badge(text: "TP", active: info.tp, color: RadioTheme.vfdCyan)
                            badge(text: "TA", active: info.ta, color: Color.red)
                            if let m = info.music {
                                badge(text: m ? "MUSIK" : "SPRACHE", active: true, color: RadioTheme.vfdAmber)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(controller.stats.syncState.rawValue)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(controller.stats.syncState == .synced ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
                            Text(String(format: "%.0f dB", controller.signalDB))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(RadioTheme.vfdCyan)
                        }
                    }
                }
                Text(diagnosis.text)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(diagnosis.good ? RadioTheme.textMuted : RadioTheme.vfdAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
        }
    }

    /// Kurzdiagnose des Empfangs: was fehlt, wenn kein Text kommt
    private var diagnosis: (text: String, good: Bool) {
        let m = controller.metrics
        let st = controller.stats
        let rf = sdr.snapshot
        if !sdr.isSelected { return ("SDR-Empfänger ist nicht die Eingangsquelle (Eingang → SDR wählen)", false) }
        if rf.clippedFraction > 0.01 { return (String(format: "Übersteuert (%.0f %% der Abtastwerte am Anschlag): LNA oder VGA verringern", rf.clippedFraction * 100), false) }
        if controller.signalDB < -60 { return ("Sehr schwaches Signal: Antenne, Frequenz und Verstärkung prüfen", false) }
        if st.syncState == .synced { return (String(format: "RDS ok · Blockgüte %.0f %%", st.quality * 100), true) }
        if m.locked { return ("RDS-Träger gefunden, Blocktakt wird gesucht (Bitfehler: Empfang zu verrauscht?)", false) }
        if info.pi == nil { return ("Suche den 57-kHz-RDS-Unterträger (der Sender sendet vielleicht kein RDS)", false) }
        return ("RDS-Daten stehen, aktueller Blocktakt fehlt kurz", false)
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
                    .foregroundColor(info.radioText.isEmpty ? RadioTheme.textDim : (info.radioTextComplete ? RadioTheme.textLight : RadioTheme.textMuted))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RadioTheme.bgDeep)
                    .cornerRadius(5)
                    .textSelection(.enabled)
                if !info.radioTextPlus.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(info.radioTextPlus, id: \.label) { tag in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(tag.label.uppercased())
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(RadioTheme.textDim)
                                    .frame(width: 70, alignment: .leading)
                                Text(tag.text)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(RadioTheme.vfdAmber)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
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

                if earlierTexts.isEmpty {
                    Text("Keine früheren Radiotexte")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(earlierTexts, id: \.self) { item in
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
                    detailRow(label: "LAND", value: country + (info.countryIsGuess ? " ?" : ""))
                }
                if let lang = info.language, info.languageCode != 0 {
                    detailRow(label: "SPRACHE", value: lang)
                }
                detailRow(label: "PROGRAMMART", value: info.ptyName ?? "—")
                if !info.programTypeName.isEmpty {
                    detailRow(label: "PTY-NAME", value: info.programTypeName)
                }
                if let ct = info.clockFormatted {
                    detailRow(label: "SENDERUHR (CT)", value: ct)
                }
                if info.diStereo != nil {
                    detailRow(label: "KENNUNG (DI)", value: decoderFlags)
                }
                if !info.applicationNames.isEmpty {
                    detailRow(label: "ZUSATZDIENSTE", value: info.applicationNames.joined(separator: ", "))
                }
            }
            .padding(4)
        }
    }

    /// Verlauf ohne den Text, der gerade angezeigt wird
    private var earlierTexts: [String] { info.radioTextHistory.filter { $0 != info.radioText } }

    private var decoderFlags: String {
        var flags = [info.diStereo == true ? "Stereo" : "Mono"]
        if info.diCompressed == true { flags.append("komprimiert") }
        if info.diArtificialHead == true { flags.append("Kunstkopf") }
        return flags.joined(separator: " · ")
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

    /// Eine Zeile: Titel und Anzahl links, die Frequenzen waagerecht daneben (bei Bedarf scrollbar)
    private var afCard: some View {
        RadioBox {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ALTERNATIVFREQUENZEN (AF)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(0.8)
                    Text("\(info.alternativeFrequencies.count) gemeldet")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }
                .fixedSize()

                if info.alternativeFrequencies.isEmpty {
                    Text("Keine AF gemeldet")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Spacer(minLength: 0)
                } else {
                    // Breite auf den Rest der Karte begrenzen, sonst wächst die Liste über den Rand statt zu scrollen
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(info.alternativeFrequencies, id: \.self) { af in
                                Button(String(format: "%.1f", af).replacingOccurrences(of: ".", with: ",")) {
                                    controller.tune(frequencyHz: af * 1e6)
                                }
                                .buttonStyle(ModeButtonStyle(isSelected: (settings.frequencyHz / 1e6).rounded() == af.rounded()))
                                .scaleEffect(0.85)
                                .help("Auf \(af) MHz abstimmen")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity)
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

                let st = controller.stats
                detailRow(label: "GRUPPEN", value: "\(st.groupsReceived) (\(st.completeGroups) vollständig)")
                detailRow(label: "BLÖCKE", value: "\(st.blocksReceived) ok · \(st.blockErrors) schlecht · \(st.correctedBlocks) rep.")
                detailRow(label: "BLOCKGÜTE (50)", value: String(format: "%.0f %%", st.quality * 100))
                detailRow(label: "RDS-TRÄGER", value: controller.metrics.locked ? String(format: "%.1f kHz Hub · %.0f dB", controller.metrics.carrierDeviationKHz, controller.metrics.snrDB) : "nicht gefunden")
                if !info.groupCounts.isEmpty {
                    Text(info.groupCounts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

                RDSQuickPicks(controller: controller, settings: settings)

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
        let sync = controller.stats.syncState
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(sync == .synced ? RadioTheme.vfdGreen : (sync == .syncing ? RadioTheme.ledYellow : RadioTheme.ledRed))
                    .frame(width: 8, height: 8)
                Text("RDS")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdGreen)
                Text(sync.rawValue)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(sync == .synced ? RadioTheme.vfdGreen : (sync == .syncing ? RadioTheme.ledYellow : RadioTheme.ledRed))
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
                readout("GRUPPEN", "\(controller.stats.groupsReceived)")
                Spacer()
                readout("BLÖCKE", "\(controller.stats.blocksReceived)")
            }
            HStack {
                readout("GÜTE", String(format: "%.0f %%", controller.stats.quality * 100))
                    .foregroundColor(controller.stats.quality > 0.8 ? RadioTheme.vfdCyan : RadioTheme.vfdAmber)
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

            // Die Schnellauswahl steht unten im Hauptbereich (presetsCard) und wird hier nicht doppelt gezeigt

            HStack {
                Button("LEEREN") { controller.clear() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                Spacer()
                Text("WFM · 230 kHz · 57 kHz")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
        }
    }
}

// MARK: - Schnellauswahl (eigene Sender)

/// „★ MERKEN“ legt den eingestellten Sender mit seinem Programmnamen ab; die Leiste zeigt die gemerkten Sender (Rechtsklick: entfernen).
/// Solange nichts gemerkt ist, steht eine Auswahl gängiger Frequenzen da. Eine Zeile, waagerecht scrollbar.
struct RDSQuickPicks: View {
    @ObservedObject var controller: RDSController
    @ObservedObject var settings: RDSSettingsStore

    private var isFavorite: Bool { settings.favorite(at: settings.frequencyHz) != nil }

    var body: some View {
        HStack(spacing: 6) {
            starButton
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) { picks }
            }
        }
    }

    private var starButton: some View {
        Button(isFavorite ? "★ ENTFERNEN" : "★ MERKEN") { controller.toggleFavorite() }
            .buttonStyle(ModeButtonStyle(isSelected: isFavorite))
            .scaleEffect(0.85, anchor: .leading)
            .help(isFavorite ? "Diesen Sender aus der Schnellauswahl nehmen" : "Den eingestellten Sender mit seinem Programmnamen in der Schnellauswahl merken")
    }

    @ViewBuilder
    private var picks: some View {
        if settings.favorites.isEmpty {
            ForEach(RDSSettingsStore.standardPresets, id: \.name) { preset in
                Button(preset.name) { controller.tune(frequencyHz: preset.freqHz) }
                    .buttonStyle(ModeButtonStyle(isSelected: abs(settings.frequencyHz - preset.freqHz) < 50_000))
                    .scaleEffect(0.85)
                    .lineLimit(1)
            }
        } else {
            ForEach(settings.favorites) { fav in
                Button(fav.title) { controller.tune(frequencyHz: fav.frequencyHz) }
                    .buttonStyle(ModeButtonStyle(isSelected: abs(settings.frequencyHz - fav.frequencyHz) < 50_000))
                    .scaleEffect(0.85)
                    .lineLimit(1)
                    .contextMenu { Button("Aus der Schnellauswahl entfernen") { settings.removeFavorite(frequencyHz: fav.frequencyHz) } }
            }
        }
    }
}
