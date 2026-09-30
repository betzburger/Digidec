import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject public var state: DigidecState

    public init(state: DigidecState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            RadioTheme.bgPanel.ignoresSafeArea()

            VStack(spacing: 10) {
                HeaderBar(state: state)
                ModuleBar(state: state)

                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        PlaceholderPanel(icon: "waveform",
                                         text: "Wasserfall & Spektrum",
                                         detail: "Mark/Space-Marker, Klick setzt die Mittenfrequenz (M3)")
                            .frame(height: 170)
                            .radioCard(title: "Wasserfall")

                        PlaceholderPanel(icon: "text.alignleft",
                                         text: "Decodierter Text",
                                         detail: "Erscheint hier, sobald der RTTY-Kern eingebunden ist (M5)")
                            .frame(maxHeight: .infinity)
                            .radioCard(title: "Empfangstext")
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 10) {
                        PlaceholderPanel(icon: "circle.dashed",
                                         text: "XY-Scope",
                                         detail: "Kreuzellipse Mark/Space (M5)")
                            .frame(height: 170)
                            .radioCard(title: "Abstimmanzeige")

                        PresetPanel(state: state)
                            .radioCard(title: "Preset")

                        PlaceholderPanel(icon: "speaker.wave.2",
                                         text: "Audio-Eingang",
                                         detail: "Standard: VALHost 2ch (M2)")
                            .frame(height: 90)
                            .radioCard(title: "Eingang")

                        Spacer(minLength: 0)
                    }
                    .frame(width: 300)
                }
                .padding(.horizontal, 14)

                StatusBar(state: state)
            }
            .padding(.bottom, 8)
        }
        .frame(minWidth: 980, minHeight: 640)
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

            SourceBadge(request: state.currentRequest)
            UTCClock()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

private struct SourceBadge: View {
    let request: DecodeRequest?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(request == nil ? RadioTheme.textDim : RadioTheme.vfdGreen)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(request == nil ? RadioTheme.textDim : RadioTheme.vfdGreen)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RadioTheme.bgDeep)
        .cornerRadius(4)
        .help("Aufrufendes Hauptprogramm und dessen rigctld-Port")
    }

    private var label: String {
        guard let request else { return "KEINE QUELLE" }
        var text = (request.sourceDisplayName ?? "Unbekannte Quelle").uppercased()
        if let port = request.rigctlPort {
            text += " · RIGCTL \(port)"
        }
        return text
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

// MARK: - Preset (Anzeige; Auswahl und Einstellungen folgen mit M5)

private struct PresetPanel: View {
    @ObservedObject var state: DigidecState

    private let presets: [(id: String, name: String, detail: String)] = [
        ("ham",    "Amateur", "45,45 Bd · 170 Hz"),
        ("dwd-kw", "DWD KW",  "50 Bd · 450 Hz"),
        ("dwd-lw", "DWD LW",  "50 Bd · 85 Hz"),
        ("custom", "Eigene",  "frei")
    ]

    var body: some View {
        let selected = state.currentRequest?.presetID ?? "ham"
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(presets, id: \.id) { preset in
                VStack(spacing: 2) {
                    Text(preset.name)
                    Text(preset.detail)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }
                .frame(maxWidth: .infinity)
                .modifier(ModeLabelLook(isSelected: preset.id == selected))
            }
        }
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

    var body: some View {
        HStack(spacing: 10) {
            if let error = state.lastRequestError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(RadioTheme.ledYellow)
            } else if let request = state.currentRequest {
                Text("Auftrag: \(request.module.displayName) · Preset \(request.presetID)"
                     + (request.centerHz.map { String(format: " · Mitte %.0f Hz", $0) } ?? ""))
                    .foregroundColor(RadioTheme.textMuted)
            } else {
                Text("Bereit – wartet auf Auftrag eines Hauptprogramms (digidec://decode?…)")
                    .foregroundColor(RadioTheme.textDim)
            }
            Spacer()
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
    }
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
