// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

/// Alle RTTY-Einstellungen wie in fldigi (Modem/TTY/Rx), im RadioTheme.
/// Übertragungsparameter eines festen Presets zu ändern legt eine Kopie als „Eigene“ an.
struct RTTYSettingsSheet: View {
    @ObservedObject var settings: RTTYSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var customShiftText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RTTY-EINSTELLUNGEN")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                Spacer()
                Text("Preset: \(settings.preset.name)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
            }

            HStack(alignment: .top, spacing: 12) {
                transmission
                    .radioCard(title: "Übertragung")
                reception
                    .radioCard(title: "Empfang")
            }

            if settings.presetID != "custom" {
                Text("Änderungen unter „Übertragung“ legen eine Kopie des Presets als „Eigene“ an – \(settings.preset.name) bleibt unverändert.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }

            HStack {
                Button("Empfang auf fldigi-Standard") {
                    settings.options = RTTYDecodeOptions()
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("AFC normal, Squelch aus, Mark-Space, K = 1,4, XY-Scope klassisch")
                Spacer()
                Button("Fertig") { dismiss() }
                    .buttonStyle(ModeButtonStyle(isSelected: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640)
        .background(RadioTheme.bgPanel)
        .preferredColorScheme(.dark)
    }

    // MARK: - Übertragung

    private var transmission: some View {
        let p = settings.parameters
        return VStack(alignment: .leading, spacing: 8) {
            row("Shift") {
                Menu(shiftLabel(p.shift)) {
                    ForEach(RTTYParameters.shifts, id: \.self) { s in
                        Button("\(Int(s)) Hz") { set { $0.shift = s } }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 90)
                TextField("eigene", text: $customShiftText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit {
                        if let v = Double(customShiftText.replacingOccurrences(of: ",", with: ".")), (10...1000).contains(v) {
                            set { $0.shift = v.rounded() }
                        }
                        customShiftText = ""
                    }
                    .help("Eigene Shift in Hz (10–1000), mit Enter übernehmen")
            }
            row("Baud") {
                Menu(baudLabel(p.baud)) {
                    ForEach(RTTYParameters.bauds, id: \.self) { b in
                        Button(baudLabel(b)) { set { $0.baud = b } }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 90)
            }
            row("Bits") {
                segmented(RTTYParameters.bitCounts, selected: p.bits, label: { $0 == 5 ? "5 Baudot" : "\($0) ASCII" }) { v in
                    set { $0.bits = v; if v == 5 { $0.parity = .none } }
                }
            }
            row("Parität") {
                segmented(RTTYParity.allCases, selected: p.parity, label: parityLabel) { v in set { $0.parity = v } }
                    .disabled(p.bits == 5)
                    .opacity(p.bits == 5 ? 0.4 : 1)
            }
            row("Stoppbits") {
                segmented(RTTYParameters.stopBitChoices, selected: p.stopBits,
                          label: { $0 == 1.5 ? "1,5" : String(format: "%.0f", $0) }) { v in set { $0.stopBits = v } }
            }
            row("Ziffern") {
                segmented([true, false], selected: p.ita2, label: { $0 ? "ITA2" : "US-TTY" }) { v in set { $0.ita2 = v } }
                    .help("ITA2 (europäisch: + =) oder US-TTY (fldigi-Standard: \" ;)")
            }
            row("Unshift on Space") {
                Toggle("", isOn: Binding(get: { p.unshiftOnSpace }, set: { v in set { $0.unshiftOnSpace = v } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Nach einem Leerzeichen zurück auf Buchstaben. Amateurfunk: an. DWD: aus (Zifferngruppen)")
            }
            row("Reverse") {
                Toggle("", isOn: Binding(get: { settings.isReversed }, set: { _ in settings.toggleReverse() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Mark auf der tieferen HF (bezogen auf USB, wie fldigi „Rev“). DWD: an. Gilt für das gewählte Preset")
            }
            row("Seitenband") {
                segmented(SidebandMode.allCases, selected: settings.sidebandMode, label: { $0.label }) { v in settings.sidebandMode = v }
                    .help("AUTO: Mode vom Funkgerät über rigctld. Bei LSB dreht Digidec Mark/Space automatisch um")
            }
        }
    }

    // MARK: - Empfang

    private var reception: some View {
        let o = settings.options
        return VStack(alignment: .leading, spacing: 8) {
            row("AFC") {
                segmented(RTTYDecodeOptions.AFC.allCases, selected: o.afc, label: { $0.label }) { v in settings.options.afc = v }
            }
            row("Squelch") {
                Toggle("", isOn: $settings.options.squelchOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Slider(value: $settings.options.squelch, in: 0...100, step: 1)
                    .disabled(!o.squelchOn)
                    .frame(width: 110)
                Text("\(Int(o.squelch))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 26)
            }
            row("Decodieren") {
                segmented(RTTYDecodeOptions.Tones.allCases, selected: o.tones, label: { $0.label }) { v in settings.options.tones = v }
                    .help("Nur Mark / nur Space hilft, wenn ein Ton durch Störungen (CWI) überdeckt wird")
            }
            row("Filter K") {
                Stepper(value: $settings.options.filterK, in: RTTYDecodeOptions.filterKRange, step: 0.05) {
                    Text(String(format: "%.2f", o.filterK).replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                .help("Raised-Cosine-Formfaktor. fldigi 4.2.13 verwendet fest 1,4 (der Dialogwert dort ist wirkungslos)")
            }
            row("SYNOP") {
                Toggle("", isOn: $settings.options.synopDecoding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Wettermeldungen (SYNOP/SHIP/BUOY) als Klartext unter den Zifferngruppen – Decoder aus fldigi")
            }
            row("XY-Scope") {
                segmented([true, false], selected: o.trueScope, label: { $0 ? "Klassisch" : "Pseudo" }) { v in settings.options.trueScope = v }
            }
        }
    }

    // MARK: - Bausteine

    private func set(_ change: (inout RTTYParameters) -> Void) {
        var p = settings.parameters
        change(&p)
        settings.update(parameters: p)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 92, alignment: .leading)
            content()
        }
    }

    private func segmented<T: Hashable>(_ values: [T], selected: T, label: @escaping (T) -> String,
                                        action: @escaping (T) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { v in
                Button(label(v)) { action(v) }
                    .buttonStyle(ModeButtonStyle(isSelected: v == selected))
            }
        }
    }

    private func shiftLabel(_ s: Double) -> String { "\(Int(s)) Hz" }

    private func baudLabel(_ b: Double) -> String {
        b == b.rounded() ? String(format: "%.0f", b) : String(format: "%.2f", b).replacingOccurrences(of: ".", with: ",")
    }

    private func parityLabel(_ p: RTTYParity) -> String {
        switch p {
        case .none: return "keine"
        case .even: return "gerade"
        case .odd: return "ungerade"
        case .zero: return "0"
        case .one: return "1"
        }
    }
}
