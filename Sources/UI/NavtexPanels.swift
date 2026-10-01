import SwiftUI
import AppKit

// MARK: - Empfangstext NAVTEX

struct NavtexReceivePanel: View {
    @ObservedObject var controller: NavtexController
    @ObservedObject var textModel: ReceiveTextModel

    init(controller: NavtexController) {
        self.controller = controller
        textModel = controller.textModel
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ActivityLED(lastChar: controller.lastCharacterDate)
                Text("\(textModel.characterCount) Zeichen · \(controller.entries.count) Nachrichten")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Vollständige Nachrichten in Tagesdatei schreiben: \(controller.logger.fileURL().path)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Log-Datei im Finder zeigen")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.textModel.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Gesamten Empfangstext kopieren")
                Button {
                    controller.clearText()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Anzeige leeren (Log und Nachrichtenliste bleiben)")
            }
            ReceiveTextView(model: controller.textModel)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
        }
    }
}

// MARK: - Abstimmanzeige NAVTEX

struct NavtexTuningPanel: View {
    @ObservedObject var controller: NavtexController
    @ObservedObject var settings: NavtexSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                let state = controller.status?.state ?? .setup
                Circle()
                    .fill(state == .reading ? RadioTheme.vfdGreen : state == .sync ? RadioTheme.vfdAmber : RadioTheme.textDim)
                    .frame(width: 9, height: 9)
                Text(state.label)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundColor(state == .reading ? RadioTheme.vfdGreen : RadioTheme.textMuted)
                Spacer()
                Text("100 Bd · ±85 Hz · SITOR-B")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help("SUCHE: kein Signal · SYNC: Phasing erkannt, Zeichentakt wird gesucht · EMPFANG: Zeichen werden decodiert")
            SignalBar(metric: controller.status?.metric ?? 0, squelch: nil)
            HStack {
                readout("S/N", controller.status.map { String(format: "%.0f dB", $0.snrDB) } ?? "–")
                Spacer()
                readout("AFC", settings.afcOn ? "an" : "aus")
                Spacer()
                readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
            }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - Einstellungen NAVTEX

struct NavtexSettingsPanel: View {
    @ObservedObject var settings: NavtexSettingsStore
    @State private var locatorText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(NavtexFrequency.allCases) { f in
                    Button {
                        settings.frequency = f
                    } label: {
                        VStack(spacing: 2) {
                            Text(f.label)
                            Text(f.note)
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.frequency == f))
                }
            }
            Text(tuningHint)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .help("Empfänger in USB auf diese Dial-Frequenz stellen; dann liegt die NAVTEX-Mitte bei der eingestellten NF-Mitte")
            HStack(spacing: 6) {
                Button("REV") { settings.reverse.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.reverse))
                    .help("Mark auf der tieferen HF (bezogen auf USB). fldigi-Standard: aus")
                Button("AFC") { settings.afcOn.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.afcOn))
                    .help("Automatische Frequenznachführung (fldigi). Zieht wegen 4:3 Mark/Space-Bits einige Hz Richtung Mark")
                Button(sidebandLabel) { settings.cycleSidebandMode() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.sidebandMode != .auto))
                    .help("Seitenband: AUTO (vom Funkgerät per rigctld) → USB → LSB. Bei LSB dreht Digidec Mark/Space um")
                Button("ITA2") { settings.ita2.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.ita2))
                    .help("ITA2-Ziffernsatz (+ =) statt US-TTY (fldigi-Standard)")
                Spacer()
            }
            HStack(spacing: 6) {
                Text("LOCATOR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                TextField("JN49WS", text: $locatorText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit { applyLocator() }
                    .onAppear { locatorText = settings.locator }
                Text("für die Stationssuche")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
        }
    }

    private var tuningHint: String {
        let dial = settings.frequency.usbDial(center: settings.centerHz) / 1000
        let s = String(format: "%.3f", dial).replacingOccurrences(of: ".", with: ",")
        return "USB-Dial \(s) kHz → Mitte \(Int(settings.centerHz.rounded())) Hz"
    }

    private var sidebandLabel: String {
        switch settings.sidebandMode {
        case .auto: return settings.rigIsLSB == nil ? "AUTO" : (settings.effectiveLSB ? "A·LSB" : "A·USB")
        case .usb: return "USB"
        case .lsb: return "LSB"
        }
    }

    private func applyLocator() {
        let l = locatorText.trimmingCharacters(in: .whitespaces).uppercased()
        // Maidenhead: 4 oder 6 Zeichen, z. B. JN49 oder JN49WS
        if l.range(of: "^[A-R]{2}[0-9]{2}([A-X]{2})?$", options: .regularExpression) != nil {
            settings.locator = l
        }
        locatorText = settings.locator
    }
}

// MARK: - Nachrichtenliste

struct NavtexMessageList: View {
    @ObservedObject var controller: NavtexController

    var body: some View {
        if controller.entries.isEmpty {
            Text("Noch keine Nachricht – NAVTEX-Stationen senden zu festen Zeiten (Pinneberg: alle 4 h)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(controller.entries) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(e.message.code)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .foregroundColor(e.message.subject == "B" || e.message.subject == "D" ? RadioTheme.ledRed : RadioTheme.vfdAmber)
                                Text(e.message.hasHeader ? e.message.subjectGerman : "ohne Kopf")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(RadioTheme.textBright)
                                    .lineLimit(1)
                                Spacer()
                                Text(NavtexController.timeFormat.string(from: e.message.receivedAt))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(RadioTheme.textDim)
                            }
                            Text((e.station.map { "\($0.name) (\($0.callsign))" } ?? "Station unbekannt")
                                 + (e.isRepeat ? " · Wiederholung" : "")
                                 + " · " + e.message.text.prefix(40).replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                                .lineLimit(1)
                        }
                        .help(e.message.text)
                        .contextMenu {
                            Button("Nachricht kopieren") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.message.text, forType: .string)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }
}
