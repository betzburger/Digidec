// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - Hilfen

enum DABText {
    /// Programmtypen (ETSI TS 101 756, Tabelle 12)
    static let programTypes = ["", "Nachrichten", "Zeitgeschehen", "Information", "Sport", "Bildung", "Hörspiel", "Kultur", "Wissenschaft", "Varia", "Pop", "Rock",
                               "Unterhaltung", "Leichte Klassik", "Klassik", "Sonstige Musik", "Wetter", "Wirtschaft", "Kinder", "Soziales", "Religion", "Hörerbeteiligung",
                               "Reisen", "Freizeit", "Jazz", "Country", "Nationale Musik", "Oldies", "Volksmusik", "Dokumentation"]

    static func programType(_ n: Int) -> String { n > 0 && n < programTypes.count ? programTypes[n] : "" }

    static func codec(_ s: DABService) -> String {
        guard let t = s.primaryAudio?.audioType else { return s.components.first?.transport == 1 ? "Daten" : "Daten" }
        return t == 63 ? "DAB+" : "DAB"
    }

    static func ensembleTime(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: d) + " UTC"
    }
}

// MARK: - Dienstliste

struct DABMainPanel: View {
    @ObservedObject var controller: DABController
    @ObservedObject var settings: DABSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().overlay(RadioTheme.borderSubtle)
            if controller.snapshot.services.isEmpty {
                Spacer()
                Text(emptyText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                tableHeader
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(controller.snapshot.services) { s in row(s) }
                    }
                }
            }
            if let service = controller.selectedService, controller.snapshot.playing {
                Divider().overlay(RadioTheme.borderSubtle)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(RadioTheme.vfdGreen)
                    Text(service.label).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
                    Text(controller.snapshot.formatText).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
                    Spacer()
                }
                Text(controller.snapshot.dynamicLabel.isEmpty ? " " : controller.snapshot.dynamicLabel)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !controller.snapshot.unsupportedReason.isEmpty {
                Text(controller.snapshot.unsupportedReason)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
            }
        }
    }

    private var emptyText: String {
        switch controller.status {
        case .error(let m): return m
        case .idle: return "Der Empfänger ist aus."
        case .running:
            return controller.snapshot.synced ? "Ensemble wird gelesen …" : "Kein DAB-Signal im Block \(settings.block.name). Anderen Block wählen oder SUCHLAUF."
        }
    }

    private var header: some View {
        let s = controller.snapshot
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.ensembleLabel.isEmpty ? "—" : s.ensembleLabel)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                Text("Block \(settings.block.title)" + (s.ensembleId != 0 ? String(format: " · EId %04X", s.ensembleId) : ""))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(s.services.count) Dienste")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                Text(DABText.ensembleTime(s.ensembleTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            Text("").frame(width: 16)
            Text("DIENST").frame(maxWidth: .infinity, alignment: .leading)
            Text("ART").frame(width: 46, alignment: .leading)
            Text("KBIT/S").frame(width: 52, alignment: .trailing)
            Text("PROGRAMMTYP").frame(width: 110, alignment: .leading)
            Text("SCHUTZ").frame(width: 62, alignment: .leading)
            Text("TK").frame(width: 28, alignment: .trailing)
        }
        .font(.system(size: 8, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.horizontal, 6)
    }

    private func row(_ s: DABService) -> some View {
        let selected = Int(s.sid) == settings.selectedSID
        let sub = controller.subchannel(of: s)
        let playing = selected && controller.snapshot.playing
        return HStack(spacing: 6) {
            Image(systemName: playing ? "speaker.wave.2.fill" : selected ? "speaker.fill" : "play.fill")
                .font(.system(size: 9))
                .foregroundColor(selected ? RadioTheme.vfdGreen : RadioTheme.textDim)
                .frame(width: 16)
            Text(s.label)
                .font(.system(size: 12, weight: selected ? .bold : .semibold, design: .monospaced))
                .foregroundColor(selected ? RadioTheme.vfdGreen : RadioTheme.textBright)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Text(DABText.codec(s)).frame(width: 46, alignment: .leading)
            Text(sub.map { "\($0.bitrate)" } ?? "–").frame(width: 52, alignment: .trailing)
            Text(DABText.programType(s.programType)).frame(width: 110, alignment: .leading).lineLimit(1)
            Text(sub?.protectionText ?? "").frame(width: 62, alignment: .leading)
            Text(sub.map { "\($0.id)" } ?? "").frame(width: 28, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(RadioTheme.textMuted)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(selected ? RadioTheme.vfdGreen.opacity(0.12) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { controller.select(service: selected ? nil : s) }
        .help("Klick spielt den Dienst, nochmal Klick hält ihn an")
    }
}

// MARK: - Abstimmanzeige

struct DABTuningPanel: View {
    @ObservedObject var controller: DABController

    var body: some View {
        let s = controller.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(s.synced ? RadioTheme.vfdGreen : RadioTheme.ledRed).frame(width: 8, height: 8)
                Text("DAB").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
                Text(s.synced ? "SYNCHRON" : "KEIN SIGNAL")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(s.synced ? RadioTheme.vfdGreen : RadioTheme.ledRed)
                Spacer()
                Text(statusText).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted).lineLimit(1)
            }
            HStack {
                readout("SNR", String(format: "%.0f dB", s.snrDB))
                Spacer()
                readout("FIC", String(format: "%.0f %%", s.fibRatio * 100))
                    .foregroundColor(s.fibRatio > 0.9 ? RadioTheme.vfdCyan : RadioTheme.vfdAmber)
            }
            HStack {
                readout("RAHMEN", "\(s.frames)")
                Spacer()
                readout("ABWEICHUNG", String(format: "%+.0f Hz", s.coarseHz + s.fineHz))
            }
            HStack {
                readout("ÜBERRAHMEN", "\(s.superframes)")
                Spacer()
                readout("RS KORR.", "\(s.correctedBytes)")
            }
            HStack {
                readout("RS FEHLER", "\(s.uncorrectable)")
                    .foregroundColor(s.uncorrectable > 0 ? RadioTheme.vfdAmber : RadioTheme.vfdCyan)
                Spacer()
                readout("AU FEHLER", "\(s.badAUs)")
                    .foregroundColor(s.badAUs > 0 ? RadioTheme.vfdAmber : RadioTheme.vfdCyan)
            }
            if !s.formatText.isEmpty {
                Text(s.formatText).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
            }
            if s.clippedFraction > 0.02 {
                Text("Übersteuert: Verstärkung verringern.").hint(RadioTheme.ledRed)
            } else if s.activity > 0 && s.activity < 2.0 {
                Text("Zu schwach ausgesteuert: Verstärkung erhöhen.").hint(RadioTheme.vfdAmber)
            }
            if s.dropped > 0 {
                Text("Rechner zu langsam: \(s.dropped) Datenblöcke verworfen.").hint(RadioTheme.vfdAmber)
            }
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "aus"
        case .running(let d): return d
        case .error(let m): return m
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(RadioTheme.vfdCyan)
    }
}

private extension Text {
    func hint(_ color: Color) -> some View {
        font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(color).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Einstellungen

struct DABSettingsPanel: View {
    @ObservedObject var controller: DABController
    @ObservedObject var settings: DABSettingsStore
    @State private var showGain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockRow
            scanRow
            soundRow
            Divider().overlay(RadioTheme.borderSubtle)
            deviceRow
            if showGain { gainControls }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
    }

    private var blockRow: some View {
        HStack(spacing: 4) {
            label("BLOCK")
            Button("−") { step(-1) }.buttonStyle(ModeButtonStyle(isSelected: false))
            Menu(settings.block.title) {
                ForEach(DABBlock.all) { b in Button(b.title) { controller.tune(block: b) } }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .fixedSize()
            Button("+") { step(1) }.buttonStyle(ModeButtonStyle(isSelected: false))
            Spacer(minLength: 0)
        }
    }

    private func step(_ d: Int) {
        let all = DABBlock.all
        guard let i = all.firstIndex(where: { $0.name == settings.blockName }) else { return }
        controller.tune(block: all[(i + d + all.count) % all.count])
    }

    private var scanRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(controller.scanning ? "STOPP" : "SUCHLAUF") {
                    if controller.scanning { controller.cancelScan() } else { controller.startScan() }
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.scanning))
                .help("Alle Blöcke des Bandes III abhören und die gefundenen Ensembles auflisten")
                Text(controller.scanText).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted).lineLimit(2)
            }
            ForEach(controller.scanResults) { r in
                Button { if let b = DABBlock.named(r.block) { controller.tune(block: b) } } label: {
                    HStack(spacing: 6) {
                        Text(r.block).frame(width: 34, alignment: .leading)
                        Text(r.label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text("\(r.serviceCount) Dienste").foregroundColor(RadioTheme.textMuted)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(r.block == settings.blockName ? RadioTheme.vfdGreen : RadioTheme.textBright)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var soundRow: some View {
        HStack(spacing: 6) {
            Button(settings.muted ? "STUMM" : "TON") { settings.muted.toggle() }
                .buttonStyle(ModeButtonStyle(isSelected: !settings.muted))
                .scaleEffect(0.9, anchor: .leading)
            Slider(value: $settings.volume, in: 0...1)
            Text("\(controller.snapshot.audioLevel > 0.01 ? "▮" : "▯")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(controller.snapshot.audioLevel > 0.01 ? RadioTheme.vfdGreen : RadioTheme.textDim)
        }
    }

    private var deviceRow: some View {
        HStack(spacing: 4) {
            label("GERÄT")
            ForEach([ADSBSourceKind.hackrf, .rtlsdr, .sdrplay]) { k in
                Button(k.title) { settings.source = k }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.source == k))
                    .lineLimit(1)
                    .scaleEffect(0.9)
                    .help(k.detail)
            }
            Spacer(minLength: 0)
            Button(showGain ? "▾ GAIN" : "▸ GAIN") { showGain.toggle() }
                .buttonStyle(ModeButtonStyle(isSelected: showGain))
                .scaleEffect(0.9, anchor: .trailing)
        }
    }

    @ViewBuilder
    private var gainControls: some View {
        switch settings.source {
        case .hackrf:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button("AMP 14 dB") { settings.hackrfAmp.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.hackrfAmp)).scaleEffect(0.9, anchor: .leading)
                    Button("BIAS-T") { settings.hackrfBias.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.hackrfBias)).scaleEffect(0.9, anchor: .leading)
                }
                stepper("LNA", "\(settings.hackrfLNA) dB", minus: { settings.hackrfLNA = max(0, settings.hackrfLNA - 8) }, plus: { settings.hackrfLNA = min(40, settings.hackrfLNA + 8) })
                stepper("VGA", "\(settings.hackrfVGA) dB", minus: { settings.hackrfVGA = max(0, settings.hackrfVGA - 2) }, plus: { settings.hackrfVGA = min(62, settings.hackrfVGA + 2) })
            }
        case .rtlsdr:
            VStack(alignment: .leading, spacing: 4) {
                stepper("GAIN", settings.rtlGain > 0 ? String(format: "%.1f dB", settings.rtlGain) : "AGC",
                        minus: { settings.rtlGain = settings.rtlGain <= 0 ? 0 : max(0, settings.rtlGain - 4) }, plus: { settings.rtlGain = min(49.6, settings.rtlGain + 4) })
                HStack(spacing: 4) {
                    Button("BIAS-T") { settings.rtlBias.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.rtlBias)).scaleEffect(0.9, anchor: .leading)
                    stepper("PPM", "\(settings.rtlPPM)", minus: { settings.rtlPPM -= 1 }, plus: { settings.rtlPPM += 1 })
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    label("TUNER")
                    Button("A") { settings.sdrplayTuner = 0 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 0))
                    Button("B") { settings.sdrplayTuner = 1 }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayTuner == 1))
                    Button("AGC") { settings.sdrplayAGC.toggle() }.buttonStyle(ModeButtonStyle(isSelected: settings.sdrplayAGC))
                }
                .scaleEffect(0.9, anchor: .leading)
                stepper("LNA", "\(settings.sdrplayLNAState)", minus: { settings.sdrplayLNAState = max(0, settings.sdrplayLNAState - 1) }, plus: { settings.sdrplayLNAState = min(9, settings.sdrplayLNAState + 1) })
                stepper("ZF-MIND.", "\(settings.sdrplayIFGain) dB", minus: { settings.sdrplayIFGain = max(20, settings.sdrplayIFGain - 2) }, plus: { settings.sdrplayIFGain = min(59, settings.sdrplayIFGain + 2) })
            }
        }
    }

    private func stepper(_ title: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            label(title)
            Button("−", action: minus).buttonStyle(ModeButtonStyle(isSelected: false))
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan).frame(minWidth: 52)
            Button("+", action: plus).buttonStyle(ModeButtonStyle(isSelected: false))
        }
    }
}

struct DABReceiverCard: View {
    var body: some View {
        Text("DAB braucht keinen Audioeingang: Digidec liest die I/Q-Daten (2,048 MS/s) selbst vom Gerät und spielt den gewählten Dienst über den Standard-Ausgang. Solange das Modul offen ist, gehört das Gerät Digidec; beim Wechsel in ein anderes Modul wird es freigegeben.")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(RadioTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Spektrum

/// Das I/Q-Fenster (2,048 MHz) mit dem Ensemble (1,536 MHz Mitte) als Wasserfall
struct DABSpectrumPanel: View {
    @ObservedObject var controller: DABController
    @ObservedObject var settings: DABSettingsStore
    @StateObject private var model: SDRSpectrumModelBox

    init(controller: DABController, settings: DABSettingsStore) {
        self.controller = controller
        self.settings = settings
        _model = StateObject(wrappedValue: SDRSpectrumModelBox(rows: { controller.engine.takeSpectrumRows() }))
    }

    var body: some View {
        let center = settings.block.frequencyHz
        let range = (center - Double(DABMode1.sampleRate) / 2)...(center + Double(DABMode1.sampleRate) / 2)
        VStack(spacing: 6) {
            HStack {
                Text("BLOCK \(settings.block.title)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                Spacer()
                Text("DYN").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                Button { model.value.rangeDB = min(90, model.value.rangeDB + 5) } label: { Image(systemName: "minus") }.buttonStyle(ModeButtonStyle(isSelected: false))
                Text("\(Int(model.value.rangeDB)) dB").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan).frame(width: 44)
                Button { model.value.rangeDB = max(20, model.value.rangeDB - 5) } label: { Image(systemName: "plus") }.buttonStyle(ModeButtonStyle(isSelected: false))
            }
            VStack(spacing: 0) {
                RFAxis(range: range).frame(height: 16)
                ZStack {
                    VStack(spacing: 0) {
                        RFSpectrumGraph(spectrum: model.value.spectrum, floorDB: model.value.floorDB, rangeDB: model.value.rangeDB).frame(height: 54)
                        if let image = model.value.image {
                            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        } else {
                            Rectangle().fill(RadioTheme.bgDeep)
                        }
                    }
                    GeometryReader { geo in
                        let w = geo.size.width * CGFloat(Double(DABMode1.bandwidth) / Double(DABMode1.sampleRate))
                        Rectangle()
                            .fill(RadioTheme.vfdCyan.opacity(0.08))
                            .frame(width: w)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
        .onAppear { model.value.start() }
        .onDisappear { model.value.stop() }
    }
}
