import SwiftUI
import AppKit

// MARK: - Haupt-Anzeigefeld DCF77

struct DCF77MainPanel: View {
    @ObservedObject var controller: DCF77Controller
    @ObservedObject var settings: DCF77SettingsStore

    var body: some View {
        VStack(spacing: 8) {
            // Kopfleiste
            HStack(spacing: 8) {
                SyncBadge(isSynchronized: controller.status?.isSynchronized ?? false,
                          currentSecond: controller.status?.currentSecond ?? -1)

                if let sec = controller.status?.currentSecond, sec >= 0 {
                    Text(String(format: "Sekunde %02d / 59", sec))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }

                if let last = controller.lastTime {
                    DeltaTimeBadge(deltaMs: last.deltaMilliseconds)
                }

                Spacer()

                Button {
                    controller.logEnabled.toggle()
                } label: {
                    Label("LOG", systemImage: controller.logEnabled ? "record.circle.fill" : "record.circle")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.logEnabled))
                .help("Atomzeit-Protokoll in Datei schreiben: \(controller.logger.fileURL().path)")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.logger.fileURL()])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Log-Ordner im Finder anzeigen")

                Button {
                    controller.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Historie leeren")
            }

            // VFD-Atomuhr-Anzeige
            DCF77ClockView(time: controller.lastTime,
                           isSynchronized: controller.status?.isSynchronized ?? false,
                           currentSecond: controller.status?.currentSecond ?? -1)
                .frame(height: 110)

            // 60-Sekunden Bit-Matrix
            DCF77BitMatrixView(minuteBits: controller.status?.minuteBits ?? Array(repeating: .empty, count: 60),
                               currentSecond: controller.status?.currentSecond ?? -1)
                .frame(height: 120)

            // Live-Oszilloskop der Impuls-Hüllkurve
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("AM-HÜLLKURVE · IMPULSBREITEN (100 ms = 0, 200 ms = 1)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Spacer()
                    if let snr = controller.status?.snrDb {
                        Text(String(format: "SNR: %.1f dB", snr))
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdGreen)
                    }
                }

                DCF77ScopeView(scope: controller.status?.scope ?? [])
                    .frame(height: 48)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}

// MARK: - Synchronisations-Badge

private struct SyncBadge: View {
    let isSynchronized: Bool
    let currentSecond: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isSynchronized ? RadioTheme.vfdGreen : (currentSecond >= 0 ? RadioTheme.ledYellow : RadioTheme.textDim))
                .frame(width: 8, height: 8)

            Text(isSynchronized ? "SYNC OK" : (currentSecond >= 0 ? "ERFASSE SEKUNDEN..." : "WARTE AUF TRÄGER"))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(isSynchronized ? RadioTheme.vfdGreen : (currentSecond >= 0 ? RadioTheme.ledYellow : RadioTheme.textDim))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RadioTheme.bgPanel)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(RadioTheme.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Delta-Zeit-Badge

private struct DeltaTimeBadge: View {
    let deltaMs: Double

    var body: some View {
        let sign = deltaMs >= 0 ? "+" : ""
        let color: Color = abs(deltaMs) < 100.0 ? RadioTheme.vfdGreen : (abs(deltaMs) < 1000.0 ? RadioTheme.ledYellow : RadioTheme.vfdAmber)
        HStack(spacing: 3) {
            Text("Δt System:")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(String(format: "%@%.1f ms", sign, deltaMs))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RadioTheme.bgPanel)
        .cornerRadius(4)
        .help("Abweichung zwischen Mac-Systemuhr und der empfangenen DCF77-Atomzeit")
    }
}

// MARK: - VFD-Atomuhr

private struct DCF77ClockView: View {
    let time: DCF77Core.DecodedTime?
    let isSynchronized: Bool
    let currentSecond: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.03, green: 0.05, blue: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RadioTheme.vfdCyan.opacity(0.3), lineWidth: 1)
                )

            VStack(spacing: 4) {
                // Hauptzeitanzeige HH:mm:ss
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let t = time {
                        let sec = currentSecond >= 0 ? currentSecond : 0
                        Text(String(format: "%02d:%02d:%02d", t.hour, t.minute, sec))
                            .font(.system(size: 34, weight: .black, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdCyan)
                            .shadow(color: RadioTheme.vfdCyan.opacity(0.4), radius: 8)

                        Text(t.timeZoneName)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdAmber)
                            .padding(.leading, 6)
                    } else {
                        Text("--:--:--")
                            .font(.system(size: 34, weight: .black, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim.opacity(0.5))

                        Text("MEZ")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim.opacity(0.5))
                            .padding(.leading, 6)
                    }
                }

                // Datumszeile
                if let t = time {
                    Text(t.formattedDate)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                } else {
                    Text("Warte auf erstes vollständiges 60-Sekunden-Telegramm...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }

                // Sonderanzeigen (Zeitumstellung, Schaltsekunde, Reserveantenne)
                HStack(spacing: 8) {
                    if let t = time {
                        Text(t.isSummerTime ? "SOMMERZEIT (MESZ = UTC+2)" : "NORMALZEIT (MEZ = UTC+1)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdGreen)

                        if t.timeChangeAnnounced {
                            Text("ZEITWECHSEL ANSTEHEND (A1)")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.vfdAmber)
                        }

                        if t.leapSecondAnnounced {
                            Text("SCHALTSEKUNDE ANSTEHEND (A2)")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.vfdAmber)
                        }

                        if t.backupAntenna {
                            Text("RESERVEANTENNE")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.ledYellow)
                        }
                    } else {
                        Text("PTB Braunschweig · Sender Mainflingen (77,5 kHz)")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 60-Sekunden Bit-Matrix

private struct DCF77BitMatrixView: View {
    let minuteBits: [DCF77Core.BitValue]
    let currentSecond: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 15)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TELEGRAMM-BITS (SEKUNDEN 00 .. 59)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<60, id: \.self) { sec in
                    let bit = (sec < minuteBits.count) ? minuteBits[sec] : .empty
                    let isCurrent = (sec == currentSecond)

                    BitCell(second: sec, bit: bit, isCurrent: isCurrent)
                }
            }
        }
        .padding(6)
        .background(RadioTheme.bgPanel)
        .cornerRadius(5)
    }
}

private struct BitCell: View {
    let second: Int
    let bit: DCF77Core.BitValue
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(String(format: "%02d", second))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(isCurrent ? RadioTheme.textBright : RadioTheme.textDim.opacity(0.8))

            Text(bitText)
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .foregroundColor(textColor)
        }
        .frame(maxWidth: .infinity, minHeight: 22)
        .background(bgColor)
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isCurrent ? RadioTheme.vfdCyan : Color.clear, lineWidth: 1.5)
        )
    }

    private var bitText: String {
        switch bit {
        case .zero: return "0"
        case .one:  return "1"
        case .minuteMarker: return "M"
        case .invalid: return "?"
        case .empty:
            if second == 59 { return "M" }
            return "·"
        }
    }

    private var textColor: Color {
        if isCurrent { return RadioTheme.vfdCyan }
        switch bit {
        case .zero: return RadioTheme.textDim
        case .one:  return RadioTheme.vfdGreen
        case .minuteMarker: return RadioTheme.vfdAmber
        case .invalid: return RadioTheme.ledYellow
        case .empty: return RadioTheme.textDim.opacity(0.4)
        }
    }

    private var bgColor: Color {
        if isCurrent { return RadioTheme.vfdCyan.opacity(0.2) }
        switch bit {
        case .zero: return RadioTheme.bgDeep
        case .one:  return RadioTheme.vfdGreen.opacity(0.15)
        case .minuteMarker: return RadioTheme.vfdAmber.opacity(0.15)
        case .invalid: return RadioTheme.ledYellow.opacity(0.2)
        case .empty: return RadioTheme.bgDeep.opacity(0.6)
        }
    }
}

// MARK: - Hüllkurven-Oszilloskop

private struct DCF77ScopeView: View {
    let scope: [Float]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color(red: 0.02, green: 0.04, blue: 0.05)))

            guard scope.count > 1 else { return }

            let h = size.height
            let w = size.width
            let step = w / CGFloat(scope.count - 1)

            var path = Path()
            for (i, val) in scope.enumerated() {
                let x = CGFloat(i) * step
                let y = h - 3 - CGFloat(min(1.0, max(0.0, val))) * (h - 6)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Signalverlauf in Neon-Grün zeichnen
            ctx.stroke(path, with: .color(RadioTheme.vfdGreen), lineWidth: 1.2)

            // Schwellwertlinie bei 55 % gestrichelt in Bernstein zeichnen
            let threshY = h - 3 - 0.55 * (h - 6)
            var threshPath = Path()
            threshPath.move(to: CGPoint(x: 0, y: threshY))
            threshPath.addLine(to: CGPoint(x: w, y: threshY))
            ctx.stroke(threshPath, with: .color(RadioTheme.vfdAmber.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

// MARK: - Abstimmanzeige (Seitenleiste)

struct DCF77TuningPanel: View {
    @ObservedObject var controller: DCF77Controller
    @ObservedObject var settings: DCF77SettingsStore

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

            HStack {
                let secText = (controller.status?.currentSecond ?? -1) >= 0 ? String(format: "%02d s", controller.status!.currentSecond) : "--"
                readout("TRÄGER-PULSE", secText)
                Spacer()
                readout("TON", "\(Int((settings.centerHz + (controller.status?.afcOffsetHz ?? 0)).rounded())) Hz")
                Spacer()
                readout("AFC", String(format: "%+.0f Hz", controller.status?.afcOffsetHz ?? 0))
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

// MARK: - Einstellungen DCF77 (Seitenleiste)

struct DCF77SettingsPanel: View {
    @ObservedObject var settings: DCF77SettingsStore
    @ObservedObject var controller: DCF77Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            // Mittenfrequenz (NF-Trägerton)
            HStack(spacing: 6) {
                Text("NF-MITTE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)

                Stepper(value: Binding(
                    get: { settings.centerHz },
                    set: { settings.setCenter($0) }
                ), in: DCF77SettingsStore.centerRange, step: 50) {
                    Text("\(Int(settings.centerHz.rounded())) Hz")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }

                Spacer()

                Button("1.000 Hz") {
                    settings.setCenter(1000.0)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.centerHz == 1000.0))
                .help("Standard: 1.000 Hz NF-Ton (Dial 76,500 kHz USB)")
            }

            Text("DCF77 sendet auf 77,5 kHz (AM 100/200 ms). Empfänger auf 76,500 kHz USB einstellen.")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Historie der Telegramme (Seitenleiste)

struct DCF77HistoryPanel: View {
    @ObservedObject var controller: DCF77Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("EMPFANGENE MINUTEN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Spacer()
                Text("\(controller.decodedHistory.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
            }

            if controller.decodedHistory.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 18))
                        .foregroundColor(RadioTheme.textDim.opacity(0.6))
                    Text("Noch keine Telegramme")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(RadioTheme.bgDeep)
                .cornerRadius(4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(controller.decodedHistory.enumerated()), id: \.offset) { _, time in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(time.formattedTime)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(RadioTheme.vfdCyan)
                                    Text(String(format: "%02d.%02d.%04d", time.day, time.month, time.year))
                                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                        .foregroundColor(RadioTheme.textDim)
                                }
                                Spacer()
                                let sign = time.deltaMilliseconds >= 0 ? "+" : ""
                                Text(String(format: "%@%.1f ms", sign, time.deltaMilliseconds))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(abs(time.deltaMilliseconds) < 100 ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RadioTheme.bgDeep)
                            .cornerRadius(3)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }
}
