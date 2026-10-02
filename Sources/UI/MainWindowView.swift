import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject public var state: DigidecState
    @State private var showRTTYSettings = false

    public init(state: DigidecState) {
        self.state = state
    }

    /// Hauptbereich des aktiven Moduls ohne Karte (Liste, Text, Bild)
    @ViewBuilder
    private var mainPanel: some View {
        if state.activeModule == .navtex {
                                NavtexReceivePanel(controller: state.navtexController)
                            } else if state.activeModule == .cw {
                                CWReceivePanel(controller: state.cwController)
                            } else if state.activeModule == .olivia {
                                TextModeReceivePanel(controller: state.oliviaController)
                            } else if state.activeModule == .mt63 {
                                TextModeReceivePanel(controller: state.mt63Controller)
                            } else if state.activeModule == .dsc {
                                DSCMessagePanel(controller: state.dscController)
                            } else if state.activeModule == .ale {
                                ALEMessagePanel(controller: state.aleController)
                            } else if state.activeModule == .aprs {
                                APRSMainPanel(controller: state.aprsController, settings: state.aprs, home: state.home)
                            } else if state.activeModule == .psk {
                                PSKReceivePanel(controller: state.pskController)
                            } else if state.activeModule == .wefax {
                                WefaxImagePanel(controller: state.wefaxController, schedule: state.wefaxSchedule, auto: state.autoRecorder, openSchedule: { state.scheduleSheet = .wefax })
                            } else if state.activeModule == .ft8 {
                                FT8ActivityPanel(controller: state.ft8Controller, settings: state.ft8)
                            } else if state.activeModule == .ft4 {
                                FT4ActivityPanel(controller: state.ft4Controller, settings: state.ft4)
                            } else if state.activeModule == .wspr {
                                WSPRActivityPanel(controller: state.wsprController, settings: state.wspr)
                            } else if state.activeModule == .dcf77 {
                                DCF77MainPanel(controller: state.dcf77Controller, settings: state.dcf77)
                            } else if state.activeModule == .efr {
                                EFRMainPanel(controller: state.efrController, settings: state.efr)
                            } else if state.activeModule == .sstv {
                                SSTVImagePanel(controller: state.sstvController)
                            } else {
                                ReceivePanel(controller: state.rttyController, settings: state.rtty)
                            }
    }

    public var body: some View {
        ZStack {
            RadioTheme.bgPanel.ignoresSafeArea()

            VStack(spacing: 10) {
                HeaderBar(state: state)
                ModuleBar(state: state)

                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        Group {
                            if state.activeModule == .navtex {
                                WaterfallView(model: state.waterfall, rtty: state.navtex, audio: state.audio)
                            } else if state.activeModule == .cw {
                                WaterfallView(model: state.waterfall, rtty: state.cw, audio: state.audio)
                            } else if state.activeModule == .olivia {
                                WaterfallView(model: state.waterfall, rtty: state.olivia, audio: state.audio)
                            } else if state.activeModule == .mt63 {
                                WaterfallView(model: state.waterfall, rtty: state.mt63, audio: state.audio)
                            } else if state.activeModule == .dsc {
                                WaterfallView(model: state.waterfall, rtty: state.dsc, audio: state.audio)
                            } else if state.activeModule == .ale {
                                WaterfallView(model: state.waterfall, rtty: state.ale, audio: state.audio)
                            } else if state.activeModule == .aprs {
                                WaterfallView(model: state.waterfall, rtty: state.aprs, audio: state.audio)
                            } else if state.activeModule == .psk {
                                WaterfallView(model: state.waterfall, rtty: state.psk, audio: state.audio)
                            } else if state.activeModule == .wefax {
                                WaterfallView(model: state.waterfall, rtty: state.wefax, audio: state.audio)
                            } else if state.activeModule == .ft8 {
                                WaterfallView(model: state.waterfall, rtty: state.ft8, audio: state.audio)
                            } else if state.activeModule == .ft4 {
                                WaterfallView(model: state.waterfall, rtty: state.ft4, audio: state.audio)
                            } else if state.activeModule == .wspr {
                                WaterfallView(model: state.waterfall, rtty: state.wspr, audio: state.audio)
                            } else if state.activeModule == .dcf77 {
                                WaterfallView(model: state.waterfall, rtty: state.dcf77, audio: state.audio)
                            } else if state.activeModule == .efr {
                                WaterfallView(model: state.waterfall, rtty: state.efr, audio: state.audio)
                            } else if state.activeModule == .sstv {
                                WaterfallView(model: state.waterfall, rtty: state.sstv, audio: state.audio)
                            } else {
                                WaterfallView(model: state.waterfall, rtty: state.rtty, audio: state.audio)
                            }
                        }
                        .frame(height: 260)
                        .radioCard(title: "Wasserfall")

                        Group {
                            switch state.mapLayout(state.activeModule) {
                            case .list:
                                mainPanel
                            case .map:
                                ModuleMapView(state: state)
                            case .split:
                                GeometryReader { geo in
                                    VStack(spacing: 8) {
                                        mainPanel.frame(maxHeight: .infinity)
                                        ModuleMapView(state: state)
                                            .frame(height: max(190, geo.size.height * 0.42))
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .radioCard(title: state.mapLayout(state.activeModule) == .map ? "Karte" : state.activeModule == .aprs ? "APRS Stationen" : state.activeModule == .wefax ? "Wetterfax" : state.activeModule == .sstv ? "SSTV Bild" : (state.activeModule == .ft8 || state.activeModule == .ft4) ? "Bandaktivität" : state.activeModule == .wspr ? "WSPR Spots" : state.activeModule == .dsc ? "DSC Rufe" : state.activeModule == .ale ? "ALE Aussendungen" : state.activeModule == .dcf77 ? "DCF77 Atomzeit" : state.activeModule == .efr ? "EFR Rundsteuerung" : "Empfangstext")
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 10) {
                        if state.activeModule == .navtex {
                            NavtexTuningPanel(controller: state.navtexController, settings: state.navtex)
                                .radioCard(title: "Abstimmanzeige")
                            NavtexSettingsPanel(settings: state.navtex)
                                .radioCard(title: "NAVTEX")
                            NavtexMessageList(controller: state.navtexController)
                                .radioCard(title: "Nachrichten")
                        } else if state.activeModule == .cw {
                            CWTuningPanel(controller: state.cwController, settings: state.cw)
                                .radioCard(title: "Abstimmanzeige")
                            CWSettingsPanel(settings: state.cw)
                                .radioCard(title: "CW")
                        } else if state.activeModule == .olivia {
                            OliviaTuningPanel(controller: state.oliviaController, settings: state.olivia)
                                .radioCard(title: "Abstimmanzeige")
                            OliviaSettingsPanel(settings: state.olivia)
                                .radioCard(title: "OLIVIA · CONTESTIA")
                        } else if state.activeModule == .ale {
                            ALETuningPanel(controller: state.aleController, settings: state.ale)
                                .radioCard(title: "Abstimmanzeige")
                            ALESettingsPanel(settings: state.ale)
                                .radioCard(title: "ALE")
                        } else if state.activeModule == .aprs {
                            APRSTuningPanel(controller: state.aprsController, settings: state.aprs)
                                .radioCard(title: "Abstimmanzeige")
                            APRSSettingsPanel(settings: state.aprs)
                                .radioCard(title: "APRS")
                        } else if state.activeModule == .dsc {
                            DSCTuningPanel(controller: state.dscController, settings: state.dsc)
                                .radioCard(title: "Abstimmanzeige")
                            DSCSettingsPanel(settings: state.dsc)
                                .radioCard(title: "DSC")
                        } else if state.activeModule == .mt63 {
                            MT63TuningPanel(controller: state.mt63Controller, settings: state.mt63)
                                .radioCard(title: "Abstimmanzeige")
                            MT63SettingsPanel(settings: state.mt63)
                                .radioCard(title: "MT63")
                        } else if state.activeModule == .psk {
                            PSKTuningPanel(controller: state.pskController, settings: state.psk)
                                .radioCard(title: "Abstimmanzeige")
                            PSKSettingsPanel(settings: state.psk)
                                .radioCard(title: "PSK")
                        } else if state.activeModule == .wefax {
                            WefaxTuningPanel(controller: state.wefaxController, settings: state.wefax, schedule: state.wefaxSchedule, auto: state.autoRecorder)
                                .radioCard(title: "Abstimmanzeige")
                            WefaxSettingsPanel(settings: state.wefax)
                                .radioCard(title: "WEFAX")
                            WefaxGallery(controller: state.wefaxController)
                                .radioCard(title: "Bilder")
                        } else if state.activeModule == .ft8 {
                            FT8CyclePanel(controller: state.ft8Controller, settings: state.ft8)
                                .radioCard(title: "Zyklus · Rx-Frequenz")
                            FT8SettingsPanel(settings: state.ft8)
                                .radioCard(title: "FT8")
                        } else if state.activeModule == .ft4 {
                            FT4CyclePanel(controller: state.ft4Controller, settings: state.ft4)
                                .radioCard(title: "Zyklus · Rx-Frequenz")
                            FT4SettingsPanel(settings: state.ft4)
                                .radioCard(title: "FT4")
                        } else if state.activeModule == .wspr {
                            WSPRCyclePanel(controller: state.wsprController, settings: state.wspr)
                                .radioCard(title: "Zyklus")
                            WSPRSettingsPanel(settings: state.wspr)
                                .radioCard(title: "WSPR")
                        } else if state.activeModule == .dcf77 {
                            DCF77TuningPanel(controller: state.dcf77Controller, settings: state.dcf77)
                                .radioCard(title: "Signal · Pegel")
                            DCF77SettingsPanel(settings: state.dcf77, controller: state.dcf77Controller)
                                .radioCard(title: "DCF77")
                            DCF77HistoryPanel(controller: state.dcf77Controller)
                                .radioCard(title: "Telegramme")
                        } else if state.activeModule == .efr {
                            EFRTuningPanel(controller: state.efrController, settings: state.efr)
                                .radioCard(title: "Signal · Pegel")
                            EFRSettingsPanel(settings: state.efr, controller: state.efrController)
                                .radioCard(title: "EFR")
                        } else if state.activeModule == .sstv {
                            SSTVTuningPanel(controller: state.sstvController, settings: state.sstv)
                                .radioCard(title: "Abstimmanzeige")
                            SSTVSettingsPanel(settings: state.sstv, controller: state.sstvController)
                                .radioCard(title: "SSTV")
                            SSTVGallery(controller: state.sstvController)
                                .radioCard(title: "Bilder")
                        } else {
                            TuningPanel(controller: state.rttyController, settings: state.rtty)
                                .radioCard(title: "Abstimmanzeige")

                            VStack(spacing: 8) {
                                PresetPanel(rtty: state.rtty)
                                RTTYQuickControls(settings: state.rtty, showSettings: $showRTTYSettings)
                            }
                            .radioCard(title: "Preset")
                        }

                        InputPanelView(audio: state.audio)
                            .radioCard(title: "Eingang")

                        Spacer(minLength: 0)
                    }
                    .frame(width: 330)
                }
                .padding(.horizontal, 14)

                StatusBar(state: state, rtty: state.rtty, navtex: state.navtex, cw: state.cw, wefax: state.wefax, psk: state.psk, olivia: state.olivia, mt63: state.mt63, dsc: state.dsc, ale: state.ale, aprs: state.aprs, ft8: state.ft8, ft4: state.ft4, ft4Controller: state.ft4Controller, wspr: state.wspr, dcf77: state.dcf77, dcf77Controller: state.dcf77Controller, efr: state.efr, efrController: state.efrController, sstv: state.sstv, sstvController: state.sstvController)
            }
            .padding(.bottom, 8)
        }
        .frame(minWidth: 1060, minHeight: 730)
        .sheet(isPresented: $showRTTYSettings) {
            RTTYSettingsSheet(settings: state.rtty)
        }
        .sheet(item: $state.scheduleSheet) { service in
            ScheduleSheet(state: state, tab: service)
        }
    }
}

// MARK: - Kopfzeile

private struct HeaderBar: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(RadioTheme.vfdCyan)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("DIGIDEC")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundColor(RadioTheme.textBright)

                        Text(AppVersion.string)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RadioTheme.bgDeep.opacity(0.8))
                            .cornerRadius(3)
                    }

                    Text("DIGITAL MODE DECODER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                        .tracking(1.0)
                }
            }

            Spacer()

            MapToggleButton(state: state)
            ScheduleButton(state: state, auto: state.autoRecorder)
            RigControlToggle(state: state, rig: state.rig)
            RigBadge(rig: state.rig, audio: state.audio)
            UTCClock()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

/// Darstellung des unteren Bereichs: Liste (bzw. Bild/Text), Karte oder beides übereinander
private struct MapToggleButton: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        let module = state.activeModule
        let current = state.mapLayout(module)
        HStack(spacing: 2) {
            segment("list.bullet", "LISTE", .list, current, module, help: "Liste, Text oder Bild des Moduls (Wetterfax-Bild, Empfangstext …)")
            segment("map", "KARTE", .map, current, module, help: "Nur die Karte zeigen (Stationen, Sender, Positionen)")
            segment("rectangle.split.1x2", "BEIDE", .split, current, module, help: "Liste bzw. Bild oben, Karte darunter")
        }
        .padding(2)
        .background(RadioTheme.bgDeep)
        .cornerRadius(5)
        .opacity(module.hasMap ? 1 : 0.5)
        .help(module.hasMap ? "Darstellung umschalten" : "\(module.displayName) hat keine Ortsdaten, daher keine Karte")
    }

    private func segment(_ icon: String, _ text: String, _ layout: MapLayout, _ current: MapLayout, _ module: DecoderModuleInfo, help: String) -> some View {
        Button {
            state.setMapLayout(layout, for: module)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(text).font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(current == layout ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(current == layout ? RadioTheme.vfdCyan.opacity(0.18) : .clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!module.hasMap)
        .help(help)
    }
}

/// Öffnet den Sendeplan (Wetterfax, RTTY, NAVTEX); zeigt eine laufende geplante Aufnahme
private struct ScheduleButton: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var auto: ScheduleAutoRecorder

    var body: some View {
        Button {
            let service = BroadcastService.allCases.first { $0.module == state.activeModule } ?? .wefax
            state.scheduleSheet = service
        } label: {
            HStack(spacing: 5) {
                Image(systemName: auto.session != nil ? "record.circle.fill" : "calendar")
                    .font(.system(size: 9, weight: .bold))
                Text("SENDEPLAN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(auto.session != nil ? RadioTheme.ledRed : RadioTheme.textBright)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Sendepläne von Wetterfax, RTTY und NAVTEX ansehen und Sendungen zur automatischen Aufnahme wählen")
    }
}

/// Schalter: Digidec stimmt das Funkgerät über den rigctld des Commanders auf Band/Kanal/Sender des Moduls ab
private struct RigControlToggle: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var rig: RigModel

    var body: some View {
        Button {
            state.rigControlEnabled.toggle()
            if state.rigControlEnabled { state.tuneRigForActiveModule() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                Text(state.rigControlEnabled ? "QSY AUTO" : "QSY MANUELL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(state.rigControlEnabled ? RadioTheme.vfdAmber : RadioTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(rig.radio == nil)
        .help(help)
    }

    private var help: String {
        if rig.radio == nil { return "Kein Funkgerät angeschlossen" }
        var s = state.rigControlEnabled
            ? "Digidec stimmt das Funkgerät über den rigctld des Commanders ab (nur Frequenz F und Mode M, nie PTT), wenn Modul, Band, Kanal oder Sender gewechselt wird. Klicken zum Ausschalten."
            : "Digidec liest nur Frequenz und Mode. Klicken, damit es das Funkgerät auf Band, Kanal oder Sender des Moduls abstimmt."
        if let m = rig.tuneMessage { s += "\n\(m)" }
        return s
    }
}

/// Funkgerät, Frequenz und Mode laut rigctld des Commanders
private struct RigBadge: View {
    @ObservedObject var rig: RigModel
    @ObservedObject var audio: AudioInputManager

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RadioTheme.bgDeep)
        .cornerRadius(4)
        .help(help)
    }

    private var color: Color {
        if rig.radio == nil { return RadioTheme.textDim }
        return rig.state.connected ? RadioTheme.vfdGreen : RadioTheme.ledYellow
    }

    private var label: String {
        if audio.sourceKind == .file { return "DATEI" }
        guard let radio = rig.radio else {
            return (audio.activeInput?.device.name ?? "KEIN EINGANG").uppercased()
        }
        guard rig.state.connected else { return "\(radio.displayName) · RIGCTLD ?" }
        var s = radio.displayName.uppercased()
        if let f = rig.state.frequencyText { s += " · \(f)" }
        if let m = rig.state.mode { s += " · \(m)" }
        return s
    }

    private var help: String {
        guard let radio = rig.radio else { return "Kein Funkgerät – Frequenz und Mode unbekannt" }
        let port = rig.state.port.map { String($0) } ?? "?"
        return rig.state.connected
            ? "\(radio.displayName): Frequenz und Mode vom Commander (rigctld \(port))" + (rig.tuneMessage.map { "\n\($0)" } ?? "")
            : "\(radio.displayName): rigctld \(port) nicht erreichbar – läuft der Commander mit aktivem rigctld-Server?"
    }
}

private struct UTCClock: View {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(Self.formatter.string(from: context.date)) UTC")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RadioTheme.bgDeep)
                .cornerRadius(4)
        }
    }
}

// MARK: - Modul-Leiste

private struct ModuleBar: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DecoderModuleInfo.allCases) { module in
                Button(module.displayName) {
                    state.select(module: module)
                }
                .buttonStyle(ModeButtonStyle(isSelected: state.activeModule == module))
                .disabled(!module.isAvailable)
                .opacity(module.isAvailable ? 1.0 : 0.45)
                .help(module.isAvailable ? module.displayName : "\(module.displayName) – geplant")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Preset (Auswahl; weitere Einstellungen folgen mit M5)

private struct PresetPanel: View {
    @ObservedObject var rtty: RTTYSettingsStore

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(RTTYPreset.all) { preset in
                Button {
                    rtty.select(presetID: preset.id)
                } label: {
                    VStack(spacing: 2) {
                        Text(preset.name)
                        Text(detail(for: preset))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .modifier(ModeLabelLook(isSelected: preset.id == rtty.presetID))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.note)
            }
        }
    }

    private func detail(for preset: RTTYPreset) -> String {
        let p = preset.id == "custom" ? rtty.customParameters : preset.parameters
        let b = p.baud == p.baud.rounded() ? String(format: "%.0f", p.baud) : String(format: "%.2f", p.baud).replacingOccurrences(of: ".", with: ",")
        return "\(b) Bd · \(Int(p.shift)) Hz"
    }
}

/// Optik von `ModeButtonStyle` für reine Anzeigen ohne Button.
private struct ModeLabelLook: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isSelected ? RadioTheme.vfdCyan.opacity(0.2) : RadioTheme.bgPanel)
            .foregroundColor(isSelected ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? RadioTheme.vfdCyan : RadioTheme.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
            )
    }
}

// MARK: - Statuszeile

private struct StatusBar: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var rtty: RTTYSettingsStore
    @ObservedObject var navtex: NavtexSettingsStore
    @ObservedObject var cw: CWSettingsStore
    @ObservedObject var wefax: WefaxSettingsStore
    @ObservedObject var psk: PSKSettingsStore
    @ObservedObject var olivia: OliviaSettingsStore
    @ObservedObject var mt63: MT63SettingsStore
    @ObservedObject var dsc: DSCSettingsStore
    @ObservedObject var ale: ALESettingsStore
    @ObservedObject var aprs: APRSSettingsStore
    @ObservedObject var ft8: FT8SettingsStore
    @ObservedObject var ft4: FT4SettingsStore
    @ObservedObject var ft4Controller: FT4Controller
    @ObservedObject var wspr: WSPRSettingsStore
    @ObservedObject var dcf77: DCF77SettingsStore
    @ObservedObject var dcf77Controller: DCF77Controller
    @ObservedObject var efr: EFRSettingsStore
    @ObservedObject var efrController: EFRController
    @ObservedObject var sstv: SSTVSettingsStore
    @ObservedObject var sstvController: SSTVController

    var body: some View {
        HStack(spacing: 10) {
            Text(currentLine)
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
            Spacer()
            if let error = state.lastRequestError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(RadioTheme.ledYellow)
            } else if let request = state.currentRequest, let date = state.lastRequestDate {
                Text((request.sourceDisplayName.map { "Auftrag von \($0)" } ?? "Auftrag ohne Quelle") + " · \(Self.time.string(from: date)) UTC")
                    .foregroundColor(RadioTheme.textDim)
            } else {
                Text("Bereit für Aufträge (digidec://decode?…)")
                    .foregroundColor(RadioTheme.textDim)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
    }

    /// Aktueller Decoder-Stand, z. B. „RTTY · DWD KW · 50 Bd · 450 Hz · 5/1,5 · REV · LSB (auto) · Mitte 1696 Hz“
    private var current: String {
        let p = rtty.parameters
        var s = "\(state.activeModule.displayName) · \(rtty.preset.name) · \(p.summary)"
        if p.reverse { s += " · REV" }
        s += p.ita2 ? " · ITA2" : " · US-TTY"
        s += " · \(rtty.effectiveLSB ? "LSB" : "USB")"
        if rtty.sidebandMode == .auto { s += rtty.rigIsLSB == nil ? " (auto, unbekannt)" : " (auto)" }
        s += " · Mitte \(Int(rtty.centerHz.rounded())) Hz"
        return s
    }

    /// „NAVTEX · 518 kHz · 100 Bd · ±85 Hz · USB (auto) · Mitte 1000 Hz“
    private var navtexCurrent: String {
        var s = "NAVTEX · \(navtex.frequency.label) · 100 Bd · ±85 Hz"
        if navtex.reverse { s += " · REV" }
        s += navtex.ita2 ? " · ITA2" : " · US-TTY"
        s += " · \(navtex.effectiveLSB ? "LSB" : "USB")"
        if navtex.sidebandMode == .auto { s += navtex.rigIsLSB == nil ? " (auto, unbekannt)" : " (auto)" }
        s += " · Mitte \(Int(navtex.centerHz.rounded())) Hz"
        return s
    }

    private var currentLine: String {
        switch state.activeModule {
        case .navtex: return navtexCurrent
        case .cw: return cwCurrent
        case .psk: return pskCurrent
        case .olivia: return "\(olivia.options.familyName.uppercased()) · \(olivia.options.label) · Mitte \(Int(olivia.centerHz.rounded())) Hz" + (olivia.options.reverse ? " · REV" : "") + (olivia.options.squelchOn ? " · SQL \(Int(olivia.options.squelch))" : " · SQL aus")
        case .aprs: return "APRS · \(aprs.channel.label) MHz FM · AFSK 1200 Bd · Töne \(Int(aprs.centerHz - 500)) / \(Int(aprs.centerHz + 500)) Hz" + (aprs.repairBits ? " · Korrektur" : "") + (aprs.emphasis == .auto ? "" : aprs.emphasis == .on ? " · DE-EMPH." : " · FLACH")
        case .ale: return "ALE · 8-FSK 125 Bd · Verstimmung \(Int(ale.offsetHz.rounded())) Hz" + (ale.auto ? " · AUTO" : "") + " · \(ale.sensitivity.rawValue)"
        case .dsc: return "DSC · \(dsc.channel.label) kHz · Mitte \(Int(dsc.centerHz.rounded())) Hz · 100 Bd / 170 Hz" + (dsc.autoCenter ? " · AUTO" : "") + (dsc.reversed ? " · REV" : "")
        case .mt63: return "MT63 · \(mt63.options.label) · Mitte \(Int(mt63.centerHz.rounded())) Hz" + (mt63.options.squelchOn ? " · SQL \(Int(mt63.options.squelch))" : " · SQL aus")
        case .wefax: return wefaxCurrent
        case .ft8: return ft8Current
        case .ft4: return ft4Current
        case .wspr: return wsprCurrent
        case .dcf77: return dcf77Current
        case .efr: return efrCurrent
        case .sstv: return sstvCurrent
        default: return current
        }
    }

    /// „SSTV · 20m · Martin 1 · Ton 1750 Hz · Empfange M1 · Zeile 120/256 (46%)“
    private var sstvCurrent: String {
        let modeName = (sstvController.detectedMode ?? sstv.manualMode)?.spec.name ?? "VIS Auto"
        return "SSTV · \(sstv.channel.name) · \(modeName) · Ton \(Int(sstv.centerHz)) Hz · \(sstvController.statusMessage)"
    }

    /// „FT4 · 20m · Dial 14,080 MHz · 150–3600 Hz · JN49WS“
    private var ft4Current: String {
        let dial = String(format: "%.3f", Double(ft4.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "FT4 · \(ft4.band.rawValue) · Dial \(dial) MHz"
        s += " · \(Int(ft4.core.minHz))–\(Int(ft4.core.maxHz)) Hz"
        s += " · \(ft4.locator)"
        if !ft4.myCall.isEmpty { s += " · \(ft4.myCall)" }
        return s
    }

    /// „PSK · BPSK31 · Mitte 1000 Hz · AFC · SQL 5“
    private var pskCurrent: String {
        var s = "PSK · \(psk.options.mode.displayName) · Mitte \(Int(psk.centerHz.rounded())) Hz"
        s += psk.options.afc ? " · AFC" : " · AFC aus"
        if psk.options.reverse { s += " · REV" }
        s += psk.options.squelchOn ? " · SQL \(Int(psk.options.squelch))" : " · SQL aus"
        if let d = psk.band.dialHz { s += String(format: " · %.3f MHz", Double(d) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        return s
    }

    /// „WSPR · 20m · Dial 14,0956 MHz · 1400–1600 Hz · JN49WS“
    private var wsprCurrent: String {
        let dial = String(format: "%.4f", Double(wspr.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "WSPR · \(wspr.band.rawValue) · Dial \(dial) MHz"
        s += wspr.core.wide ? " · 1350–1650 Hz" : " · 1390–1610 Hz"
        if wspr.core.deep { s += " · tief" }
        s += " · \(wspr.locator)"
        if !wspr.myCall.isEmpty { s += " · \(wspr.myCall)" }
        return s
    }

    /// „EFR · DCF49 Mainflingen · 200 Bd · Shift 340 Hz · DIN 19244 · Ton 1500 Hz“
    private var efrCurrent: String {
        var s = "EFR · \(efr.station.name) · 200 Bd · Shift 340 Hz · DIN 19244 · Ton \(Int(efr.centerHz.rounded())) Hz"
        if let st = efrController.status {
            s += String(format: " · SNR %.1f dB · %d Telegramme", st.snrDb, st.telegramsDecoded)
        }
        return s
    }

    /// „DCF77 · 77,5 kHz · AM 100/200 ms · Ton 1000 Hz · SYNC OK · SNR 24.5 dB“
    private var dcf77Current: String {
        var s = "DCF77 · 77,5 kHz · AM 100/200 ms · Ton \(Int(dcf77.centerHz.rounded())) Hz"
        if let st = dcf77Controller.status {
            s += st.isSynchronized ? " · SYNC OK" : (st.currentSecond >= 0 ? " · Sekunde \(st.currentSecond)" : " · SUCHE...")
            s += String(format: " · SNR %.1f dB", st.snrDb)
        }
        return s
    }

    /// „FT8 · 20m · Dial 14,074 MHz · 150–3600 Hz · 3 s Rechenzeit · JN49WS“
    private var ft8Current: String {
        let dial = String(format: "%.3f", Double(ft8.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "FT8 · \(ft8.band.rawValue) · Dial \(dial) MHz"
        s += " · \(Int(ft8.core.minHz))–\(Int(ft8.core.maxHz)) Hz"
        s += " · " + String(format: "%.1f", ft8.core.budgetSeconds).replacingOccurrences(of: ".", with: ",") + " s Rechenzeit"
        s += " · \(ft8.locator)"
        if !ft8.myCall.isEmpty { s += " · \(ft8.myCall)" }
        return s
    }

    /// „WEFAX · DWD 7880 · IOC 576 · 120 LPM · Hub 850 Hz · Mitte 1900 Hz · AFC“
    private var wefaxCurrent: String {
        let o = wefax.options
        var s = "WEFAX · " + (wefax.station == .custom ? "Frei" : "DWD \(wefax.station.label)")
        s += " · IOC \(o.ioc) · \(o.lpm) LPM · Hub \(o.shiftHz) Hz · Mitte \(o.centerHz) Hz"
        if o.afc { s += " · AFC" }
        if wefax.rigIsLSB == true { s += " · LSB!" }
        return s
    }

    /// „CW · Ton 700 Hz · Filter 150 Hz · Start 18 WpM · Nachführung 8–28“
    private var cwCurrent: String {
        let o = cw.options
        var s = "CW · Ton \(Int(cw.centerHz.rounded())) Hz · Filter \(Int(cw.effectiveBandwidth)) Hz"
        if o.matchedFilter { s += " (MF)" }
        s += " · Start \(o.speedWPM) WpM"
        s += o.track ? " · Nachführung \(max(o.lowerWPM, o.speedWPM - o.rangeWPM))–\(min(o.upperWPM, o.speedWPM + o.rangeWPM))" : " · fest"
        if o.somDecoding { s += " · SOM" }
        return s
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Platzhalter für spätere Meilensteine

private struct PlaceholderPanel: View {
    let icon: String
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(RadioTheme.textDim)
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .tracking(1.0)
            Text(detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}
