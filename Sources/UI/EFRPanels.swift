// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Haupt-Anzeigefeld EFR

struct EFRMainPanel: View {
    @ObservedObject var controller: EFRController
    @ObservedObject var settings: EFRSettingsStore
    @State private var showRawHex = false

    var body: some View {
        VStack(spacing: 8) {
            // Kopfleiste
            HStack(spacing: 8) {
                Text("\(controller.filteredTelegrams.count) Telegramme")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)

                Spacer()

                // Filter
                HStack(spacing: 3) {
                    ForEach(EFRController.FilterMode.allCases) { mode in
                        Button(mode.rawValue) {
                            controller.filterMode = mode
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: controller.filterMode == mode))
                    }
                }

                Button {
                    showRawHex.toggle()
                } label: {
                    Label("HEX", systemImage: showRawHex ? "chevron.down.square.fill" : "chevron.down.square")
                }
                .buttonStyle(ModeButtonStyle(isSelected: showRawHex))
                .help("Rohdaten (Hex-Dump) ein-/ausblenden")

                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Telegramm-Protokoll in Tagesdatei schreiben: \(controller.logger.fileURL().path)")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Log-Ordner im Finder anzeigen")

                Button {
                    controller.clearTelegrams()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Liste leeren")
            }

            // Telegramm-Liste
            if controller.filteredTelegrams.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(RadioTheme.textDim.opacity(0.6))
                    Text("WARTE AUF EFR-TELEGRAMME...")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Text("200 Baud FSK · Shift 340 Hz (±170 Hz) · DIN 19244\nDCF49 Mainflingen (129,1 kHz) · DCF39 Burg (139,0 kHz)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(controller.filteredTelegrams) { tel in
                            EFRTelegramRow(telegram: tel, showRawHex: showRawHex)
                        }
                    }
                    .padding(6)
                }
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
            }
        }
        .padding(8)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}

// MARK: - Zeile für ein EFR-Telegramm

private struct EFRTelegramRow: View {
    let telegram: EFRCore.DecodedTelegram
    let showRawHex: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(telegram.formattedTime)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)

                Text(telegram.title)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(titleColor)
                if telegram.repeats > 0 {
                    Text("×\(telegram.repeats + 1)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }

                Spacer()

                Text(telegram.frameType.rawValue)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RadioTheme.bgPanel)
                    .cornerRadius(3)
            }

            Text(telegram.summary)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textBright)

            if showRawHex {
                Text(telegram.rawHex)
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .padding(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.02, green: 0.03, blue: 0.04))
                    .cornerRadius(2)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgPanel)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(telegram.isTimeSync ? RadioTheme.vfdCyan.opacity(0.3) : RadioTheme.borderSubtle, lineWidth: 1)
        )
    }

    private var titleColor: Color {
        if telegram.isTimeSync {
            return RadioTheme.vfdCyan
        } else if telegram.frameType == .variable {
            return RadioTheme.vfdAmber
        } else {
            return RadioTheme.vfdGreen
        }
    }
}

// MARK: - Abstimmanzeige (Seitenleiste)

struct EFRTuningPanel: View {
    @ObservedObject var controller: EFRController
    @ObservedObject var settings: EFRSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("SIGNAL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                if let snr = controller.status?.snrDb {
                    Text(String(format: "%.1f dB SNR", snr))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                }
            }

            SignalBar(metric: (controller.status?.signalLevel ?? 0.0) / 100.0, squelch: nil)

            // FSK-Diskriminator Oszilloskop
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("FSK-DISKRIMINATOR (SPACE / MARK)")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Spacer()
                    Text("200 BD")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                }

                EFRScopeView(scope: controller.status?.scope ?? [])
                    .frame(height: 44)
            }

            // Mark liegt bei der unteren, Space bei der oberen Frequenz; angezeigt werden die nachgeführten Töne
            HStack {
                readout("MARK", "\(Int((controller.status?.markHz ?? settings.centerHz - 170).rounded())) Hz")
                Spacer()
                readout("MITTE", "\(Int(settings.centerHz.rounded())) Hz")
                Spacer()
                readout("SPACE", "\(Int((controller.status?.spaceHz ?? settings.centerHz + 170).rounded())) Hz")
            }
            if let st = controller.status {
                Text(String(format: "AFC %+.0f Hz", st.afcOffsetHz)
                     + (st.polarityInverted == true ? " · Polarität invertiert (LSB?)" : ""))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(st.polarityInverted == true ? RadioTheme.ledYellow : RadioTheme.textDim)
            }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - Diskriminator-Oszilloskop

private struct EFRScopeView: View {
    let scope: [Float]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Color(red: 0.02, green: 0.03, blue: 0.04)))

            guard scope.count > 1 else { return }

            let h = size.height
            let w = size.width
            let step = w / CGFloat(scope.count - 1)
            let midY = h * 0.5

            // Nulllinie gestrichelt
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: 0, y: midY))
            zeroLine.addLine(to: CGPoint(x: w, y: midY))
            ctx.stroke(zeroLine, with: .color(RadioTheme.textDim.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Signalverlauf
            var path = Path()
            for (i, val) in scope.enumerated() {
                let x = CGFloat(i) * step
                // val ist -1.0 .. +1.0
                let y = midY - CGFloat(min(1.0, max(-1.0, val))) * (midY - 3)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            ctx.stroke(path, with: .color(RadioTheme.vfdCyan), lineWidth: 1.2)
        }
    }
}

// MARK: - Einstellungen EFR (Seitenleiste)

struct EFRSettingsPanel: View {
    @ObservedObject var settings: EFRSettingsStore
    @ObservedObject var controller: EFRController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Senderauswahl
            VStack(alignment: .leading, spacing: 3) {
                Text("SENDER")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)

                HStack(spacing: 3) {
                    ForEach([EFRStation.dcf49, .dcf39, .hga22]) { st in
                        Button {
                            settings.station = st
                        } label: {
                            VStack(spacing: 1) {
                                Text(st.rawValue.uppercased())
                                Text(String(format: "%.1f k", Double(st.frequencyHz) / 1000.0))
                                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.station == st))
                    }
                }
            }

            // Abstimmhinweis
            let guidance = settings.tuningGuidance
            HStack(spacing: 6) {
                Circle()
                    .fill(guidance.isCorrect ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
                    .frame(width: 7, height: 7)
                Text(guidance.statusText)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(guidance.isCorrect ? RadioTheme.vfdGreen : RadioTheme.textBright)
                    .lineLimit(2)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)

            // NF-Mittenfrequenz
            HStack(spacing: 6) {
                Text("NF-MITTE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)

                Stepper(value: Binding(
                    get: { settings.centerHz },
                    set: { settings.setCenter($0) }
                ), in: EFRSettingsStore.centerRange, step: 50) {
                    Text("\(Int(settings.centerHz.rounded())) Hz")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }

                Spacer()

                Button("1.500 Hz") {
                    settings.setCenter(1500.0)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.centerHz == 1500.0))
                .help("Standard-Mittenfrequenz: 1.500 Hz")
            }

            Text("EFR: 200 Baud FSK (Hub ±170 Hz), 8E1, DIN 19244. Empfänger in USB 1,5 kHz unter der Sendefrequenz abstimmen.")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
