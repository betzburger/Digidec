// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

/// Zeigt die Karte nur, wenn SDRconnect das gewählte Gerät ist
struct SDRconnectControlHost: View {
    @ObservedObject var rig: RigModel
    var body: some View {
        if rig.customProfile?.dialect == .sdrconnect {
            SDRconnectControlCard(rig: rig).radioCard(title: "SDRconnect")
        }
    }
}

/// Bedienung von SDRconnect (SDRplay) über seine WebSocket-Schnittstelle: Frequenz, Mode, Bandbreite, Verstärkungsstufe, Gerätestrom
struct SDRconnectControlCard: View {
    @ObservedObject var rig: RigModel
    @State private var frequencyText = ""
    @State private var editing = false

    var body: some View {
        let s = rig.sdrconnect
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(s.connected ? RadioTheme.vfdGreen : RadioTheme.ledRed).frame(width: 8, height: 8)
                Text(s.connected ? (s.deviceName ?? "verbunden") : "nicht verbunden (läuft SDRconnect mit eingeschaltetem Server?)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(s.connected ? RadioTheme.textMuted : RadioTheme.ledRed)
                    .lineLimit(2)
                Spacer()
                if s.connected, let started = s.started {
                    Button(started ? "STOPP" : "START") { rig.sdrconnectStream(!started) }
                        .buttonStyle(ModeButtonStyle(isSelected: started))
                        .help("Gerätestrom von SDRconnect ein- oder ausschalten")
                }
            }
            if s.connected {
                HStack(spacing: 6) {
                    TextField("MHz", text: $frequencyText, onEditingChanged: { editing = $0 })
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 110)
                        .onSubmit { apply() }
                    Text("MHz").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
                    Button("SETZEN") { apply() }.buttonStyle(ModeButtonStyle(isSelected: false)).help("Frequenz einstellen (in MHz, z. B. 7,074 oder 145,5)")
                }
                HStack(spacing: 4) {
                    ForEach([("−1M", -1_000_000.0), ("−100k", -100_000), ("−10k", -10_000), ("−1k", -1000), ("+1k", 1000), ("+10k", 10_000), ("+100k", 100_000), ("+1M", 1_000_000)], id: \.0) { step in
                        Button(step.0) { nudge(step.1) }
                            .buttonStyle(ModeButtonStyle(isSelected: false))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(SDRconnectModes.all, id: \.self) { m in
                        Button(m) { rig.sdrconnectSet("demodulator", m) }
                            .buttonStyle(ModeButtonStyle(isSelected: s.demodulator == m))
                    }
                }
                stepper("BANDBREITE", s.bandwidthHz.map { $0 >= 1000 ? String(format: "%.1f kHz", Double($0) / 1000) : "\($0) Hz" } ?? "–",
                        minus: { adjustBandwidth(s, factor: 0.8) }, plus: { adjustBandwidth(s, factor: 1.25) })
                if let l = s.lnaState {
                    stepper("LNA-STUFE", "\(l)", minus: { rig.sdrconnectSet("lna_state", String(max(s.lnaMin ?? 0, l - 1))) },
                            plus: { rig.sdrconnectSet("lna_state", String(min(s.lnaMax ?? 27, l + 1))) })
                }
                HStack(spacing: 10) {
                    if let p = s.signalPowerDB { readout("PEGEL", String(format: "%.0f dB", p)) }
                    if let n = s.snrDB { readout("S/N", String(format: "%.0f dB", n)) }
                    if s.overload == true { Text("ÜBERSTEUERT").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.ledRed) }
                    Spacer()
                }
                if s.canControl == false {
                    Text("SDRconnect lässt keine Steuerung zu (Gerät gehört einem anderen Programm).")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                }
            }
        }
        .onChange(of: s.vfoHz) { _, f in if !editing, let f { frequencyText = Self.mhzText(f) } }
        .onAppear { if let f = s.vfoHz { frequencyText = Self.mhzText(f) } }
    }

    private static func mhzText(_ hz: Double) -> String { String(format: "%.6f", hz / 1e6).replacingOccurrences(of: ".", with: ",") }

    private func apply() {
        let text = frequencyText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let mhz = Double(text), (0.01...10_000).contains(mhz) else { return }
        rig.sdrconnectSet("device_vfo_frequency", String(Int64((mhz * 1e6).rounded())))
        editing = false
    }

    private func nudge(_ delta: Double) {
        guard let f = rig.sdrconnect.vfoHz else { return }
        rig.sdrconnectSet("device_vfo_frequency", String(Int64((f + delta).rounded())))
    }

    private func adjustBandwidth(_ s: SDRconnectStatus, factor: Double) {
        let current = s.bandwidthHz ?? SDRconnectModes.defaultBandwidth(s.demodulator ?? "USB")
        rig.sdrconnectSet("filter_bandwidth", String(max(100, min(1_000_000, Int((Double(current) * factor).rounded())))))
    }

    private func stepper(_ label: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Button("−", action: minus).buttonStyle(ModeButtonStyle(isSelected: false))
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan).frame(minWidth: 60)
            Button("+", action: plus).buttonStyle(ModeButtonStyle(isSelected: false))
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(label)).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.vfdCyan)
        }
    }
}
