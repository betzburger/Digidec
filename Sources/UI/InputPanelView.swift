import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Karte „Eingang“: Quelle (Live/Datei), Gerät, Kanal, Pegel, Status.
struct InputPanelView: View {
    @ObservedObject var audio: AudioInputManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(AudioSourceKind.allCases) { kind in
                    Button(kind.label) {
                        if kind == .live { audio.switchToLive() } else { chooseFile() }
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: audio.sourceKind == kind))
                    .help(kind == .live ? "Live-Eingang von der virtuellen Soundkarte" : "Audiodatei (WAV, AIFF, CAF) abspielen und decodieren")
                }
                Spacer()
                ForEach(ChannelMode.allCases) { mode in
                    Button(mode.label) { audio.channelMode = mode }
                        .buttonStyle(ModeButtonStyle(isSelected: audio.channelMode == mode))
                        .help("Kanal: \(mode == .left ? "links" : mode == .right ? "rechts" : "Mittelwert beider Kanäle")")
                }
            }

            if audio.sourceKind == .live {
                DevicePicker(audio: audio)
            } else {
                FileControls(audio: audio, chooseFile: chooseFile)
            }

            LevelMeterView(model: audio.levelModel, active: audio.isRunning)

            HStack(spacing: 5) {
                Circle()
                    .fill(audio.statusIsWarning ? RadioTheme.ledYellow : (audio.isRunning ? RadioTheme.vfdGreen : RadioTheme.textDim))
                    .frame(width: 6, height: 6)
                Text(audio.statusText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(audio.statusIsWarning ? RadioTheme.ledYellow : RadioTheme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Audiodatei zum Decodieren wählen"
        panel.allowedContentTypes = [.wav, .aiff, UTType(filenameExtension: "caf") ?? .audio, .audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            audio.openFile(url)
        }
    }
}

private struct DevicePicker: View {
    @ObservedObject var audio: AudioInputManager

    var body: some View {
        Menu {
            Section("Funkgeräte (direkt vom USB-Codec)") {
                ForEach(RadioSource.allCases) { radio in
                    let codec = audio.radioCodecs[radio]
                    Button {
                        audio.select(radio: radio)
                    } label: {
                        Label(radio.displayName + (codec == nil ? "  (nicht angeschlossen)" : "")
                              + (audio.selection == .radio(radio) ? "  ✓" : ""),
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            Section("Weitere Eingänge") {
                ForEach(audio.otherDevices) { device in
                    Button {
                        audio.select(device: device)
                    } label: {
                        Label(device.name + (audio.selection == .device(uid: device.id) ? "  ✓" : ""),
                              systemImage: device.isVirtualCable ? "cable.connector" : "mic")
                    }
                }
            }
            Divider()
            Button("Liste aktualisieren") { audio.refreshDevices() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(audio.activeInput == nil ? RadioTheme.ledYellow : RadioTheme.vfdCyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RadioTheme.bgDeep)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(RadioTheme.borderSubtle, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onAppear { audio.refreshDevices() }
        .help("Eingang – Funkgeräte werden unabhängig vom USB-Port an ihrem eingebauten Hub erkannt")
    }

    private var title: String {
        if let input = audio.activeInput { return input.radio?.displayName ?? input.device.name }
        if case .radio(let r) = audio.selection { return r.displayName }
        return "Kein Gerät"
    }

    private var icon: String {
        if audio.activeInput?.radio != nil { return "antenna.radiowaves.left.and.right" }
        if case .radio = audio.selection { return "antenna.radiowaves.left.and.right" }
        return audio.activeInput?.device.isVirtualCable == true ? "cable.connector" : "mic"
    }
}

private struct FileControls: View {
    @ObservedObject var audio: AudioInputManager
    let chooseFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    if audio.isFilePlaying { audio.stopFile() } else { audio.playFile() }
                } label: {
                    Image(systemName: audio.isFilePlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(ModeButtonStyle(isSelected: audio.isFilePlaying))
                .disabled(audio.fileName == nil)
                .help(audio.isFilePlaying ? "Wiedergabe stoppen" : "Von vorn abspielen")

                Text(audio.fileName ?? "Keine Datei")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Öffnen …", action: chooseFile)
                    .buttonStyle(ModeButtonStyle(isSelected: false))
            }
            ProgressView(value: audio.fileProgress)
                .progressViewStyle(.linear)
                .tint(RadioTheme.vfdCyan)
        }
    }
}

/// Waagerechte Pegelanzeige −60 … 0 dBFS: Balken = Effektivwert, Strich = Spitze mit Haltezeit.
struct LevelMeterView: View {
    @ObservedObject var model: LevelModel
    let active: Bool

    private static let minDB: Float = -60
    private static let segments = 30

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let segW = (w - CGFloat(Self.segments - 1) * 2) / CGFloat(Self.segments)
                let lit = Int((fraction(model.level.rmsDB) * Double(Self.segments)).rounded(.up))
                let peakX = CGFloat(fraction(model.peakHoldDB)) * w
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<Self.segments, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i < lit && active ? color(for: i) : RadioTheme.bgPanel)
                                .frame(width: segW)
                        }
                    }
                    if active && model.peakHoldDB > Self.minDB {
                        Rectangle()
                            .fill(RadioTheme.textBright)
                            .frame(width: 2)
                            .offset(x: max(0, peakX - 2))
                    }
                }
            }
            .frame(height: 10)

            Text(active && model.level.rmsDB > AudioLevel.floorDB ? String(format: "%4.0f dB", model.level.rmsDB) : "  –  dB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(active ? RadioTheme.vfdGreen : RadioTheme.textDim)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(6)
        .background(RadioTheme.bgDeep)
        .cornerRadius(5)
        .help("Eingangspegel in dBFS (Balken: Effektivwert, Strich: Spitze)")
    }

    private func fraction(_ db: Float) -> Double {
        Double(min(1, max(0, (db - Self.minDB) / -Self.minDB)))
    }

    /// Grün bis −12 dBFS, Gelb bis −3 dBFS, darüber Rot (Übersteuerung droht).
    private func color(for segment: Int) -> Color {
        let db = Self.minDB + Float(segment + 1) / Float(Self.segments) * -Self.minDB
        if db > -3 { return RadioTheme.ledRed }
        if db > -12 { return RadioTheme.ledYellow }
        return RadioTheme.vfdGreen
    }
}
