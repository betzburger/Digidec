// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - SSTV Bildanzeige (Hauptfenster)

public struct SSTVImagePanel: View {
    @ObservedObject var controller: SSTVController

    public init(controller: SSTVController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Kopfzeile mit Status, Modus und Aktions-Knöpfen
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor)

                if controller.totalLines > 0 {
                    Text("· Zeile \(controller.currentLine)/\(controller.totalLines) (\(Int(controller.rxProgress * 100))%)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }

                if let err = controller.lastSaveError {
                    Text("· \(err)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.ledYellow)
                        .lineLimit(1)
                }

                Spacer()

                // Auto-Save Toggle
                Button {
                    controller.settings.autoSave.toggle()
                } label: {
                    Label("AUTO-SAVE", systemImage: controller.settings.autoSave ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.settings.autoSave))
                .help("Bilder nach Empfang automatisch als PNG in ~/Documents/Digidec/SSTV ablegen")

                // Manuell speichern
                Button {
                    controller.saveCurrentImage()
                } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(controller.liveImage == nil)
                .help("Aktuelles Bild jetzt manuell als PNG speichern")

                // Bild löschen / Neu
                Button {
                    controller.clearLiveImage()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(controller.liveImage == nil)
                .help("Bildanzeige leeren und Empfänger zurücksetzen")

                // Ordner im Finder öffnen
                Button {
                    controller.openFolderInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("SSTV-Bilderordner im Finder anzeigen")
            }

            // Fortschrittsbalken während des Empfangs
            if controller.isReceiving && controller.totalLines > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(RadioTheme.bgDeep)
                            .frame(height: 3)
                        Rectangle()
                            .fill(RadioTheme.vfdCyan)
                            .frame(width: geo.size.width * CGFloat(controller.rxProgress), height: 3)
                    }
                }
                .frame(height: 3)
            }

            // Bildbereich
            GeometryReader { geo in
                ZStack {
                    RadioTheme.bgDeep

                    if let img = controller.liveImage {
                        ZStack(alignment: .top) {
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(CGFloat(img.width) / CGFloat(max(img.height, 1)), contentMode: .fit)
                                .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)

                            // Horizontale Scanline-Linie bei Live-Empfang
                            if controller.isReceiving && controller.totalLines > 0 {
                                let imgAspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
                                let panelAspect = geo.size.width / geo.size.height
                                let renderedHeight = (imgAspect > panelAspect) ? (geo.size.width / imgAspect) : geo.size.height
                                let scanlineY = renderedHeight * CGFloat(controller.rxProgress)

                                Rectangle()
                                    .fill(RadioTheme.vfdCyan.opacity(0.85))
                                    .frame(height: 1.5)
                                    .offset(y: scanlineY)
                                    .shadow(color: RadioTheme.vfdCyan, radius: 2)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 32))
                                .foregroundColor(RadioTheme.textDim)
                            Text("Warte auf SSTV-Signal")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                            Text("Automatische Erkennung via VIS-Header (1900 Hz) oder Modus manuell wählen")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)
                        }
                    }
                }
                .cornerRadius(6)
            }
        }
    }

    private var statusColor: Color {
        if controller.isReceiving { return RadioTheme.vfdGreen }
        if controller.liveImage != nil { return RadioTheme.vfdCyan }
        return RadioTheme.textDim
    }

    private var statusLabel: String {
        if controller.isReceiving {
            let modeName = (controller.detectedMode ?? controller.settings.manualMode)?.spec.name ?? "SSTV"
            return "EMPFANG · \(modeName.uppercased())"
        }
        if let mode = controller.detectedMode ?? controller.settings.manualMode, controller.liveImage != nil {
            return "BILD · \(mode.spec.name.uppercased())"
        }
        return "BEREIT (VIS-SUCHE)"
    }
}

// MARK: - SSTV Abstimmanzeige

public struct SSTVTuningPanel: View {
    @ObservedObject var controller: SSTVController
    @ObservedObject var settings: SSTVSettingsStore

    @State private var editingChannel: SSTVChannelItem?
    @State private var isNewChannel = false
    @State private var showChannelEditor = false
    @State private var editShortLabel = ""
    @State private var editName = ""
    @State private var editMhzText = ""
    @State private var editModulation = "USB"
    @State private var editNote = ""

    public init(controller: SSTVController, settings: SSTVSettingsStore) {
        self.controller = controller
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Kanal-Schnellauswahl
            channelGrid

            // Frequenz- und Modulationshinweis
            if let f = settings.activeChannelItem.frequencyHz {
                let mhz = String(format: "%.3f", f / 1_000_000).replacingOccurrences(of: ".", with: ",")
                Text("Kanal: \(settings.activeChannelItem.name) · Dial \(mhz) MHz \(settings.activeChannelItem.modulation)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }

            // Frequenz-Töne Anzeige
            HStack {
                readout("SYNC", "1200 Hz")
                Spacer()
                readout("SCHWARZ", "1500 Hz")
                Spacer()
                readout("MITTE", "\(Int(settings.centerHz)) Hz")
                Spacer()
                readout("WEISS", "2300 Hz")
            }

            // Seitenband-Warnung bei Fehlabstimmung
            if settings.activeChannelItem.modulation == "USB" && settings.rigIsLSB == true {
                Label("Funkgerät steht auf LSB – Kanal erfordert USB!", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
            } else if settings.activeChannelItem.modulation == "LSB" && settings.rigIsLSB == false {
                Label("Funkgerät steht auf USB – Kanal erfordert LSB!", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
            }
        }
        .sheet(isPresented: $showChannelEditor) {
            PresetModalSheet(
                title: isNewChannel ? "NEUER SSTV-KANAL" : "SSTV-KANAL BEARBEITEN",
                isValid: !editShortLabel.trimmingCharacters(in: .whitespaces).isEmpty && !editName.trimmingCharacters(in: .whitespaces).isEmpty,
                onSave: saveChannel,
                onCancel: { showChannelEditor = false }
            ) {
                SSTVChannelEditorView(
                    shortLabel: $editShortLabel,
                    name: $editName,
                    mhzText: $editMhzText,
                    modulation: $editModulation,
                    note: $editNote
                )
            }
        }
    }

    private var channelGrid: some View {
        let count = settings.channels.count + 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(count, 5)), spacing: 4) {
            ForEach(settings.channels) { ch in
                Button {
                    settings.selectChannel(id: ch.id)
                } label: {
                    VStack(spacing: 1) {
                        Text(ch.shortLabel)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                        Text(ch.modulation)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.selectedChannelID == ch.id))
                .help(ch.note)
                .presetContextMenu(
                    onEdit: { startEditChannel(ch) },
                    onDelete: settings.channels.count > 1 ? { settings.removeChannel(id: ch.id) } : nil,
                    onReset: { settings.resetChannelsToDefault() }
                )
            }

            Button {
                startAddChannel()
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text("NEU")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
            .help("Neuen SSTV-Kanal hinzufügen")
        }
    }

    private func startAddChannel() {
        isNewChannel = true
        editingChannel = nil
        editShortLabel = ""
        editName = ""
        editMhzText = ""
        editModulation = "USB"
        editNote = ""
        showChannelEditor = true
    }

    private func startEditChannel(_ ch: SSTVChannelItem) {
        isNewChannel = false
        editingChannel = ch
        editShortLabel = ch.shortLabel
        editName = ch.name
        if let f = ch.frequencyHz {
            let mhz = f / 1_000_000
            editMhzText = mhz == mhz.rounded() ? String(format: "%.0f", mhz) : String(format: "%.3f", mhz).replacingOccurrences(of: ".", with: ",")
        } else {
            editMhzText = ""
        }
        editModulation = ch.modulation
        editNote = ch.note
        showChannelEditor = true
    }

    private func saveChannel() {
        let clean = editMhzText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let freqHz = clean.isEmpty ? nil : (Double(clean).map { $0 * 1_000_000 })
        let item = SSTVChannelItem(
            id: editingChannel?.id ?? UUID().uuidString,
            shortLabel: editShortLabel.trimmingCharacters(in: .whitespaces),
            name: editName.trimmingCharacters(in: .whitespaces),
            frequencyHz: freqHz,
            modulation: editModulation,
            note: editNote.trimmingCharacters(in: .whitespaces)
        )
        if isNewChannel {
            settings.addChannel(item)
        } else {
            settings.updateChannel(item)
        }
        showChannelEditor = false
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdCyan)
        }
    }
}

// MARK: - SSTV Einstellungen (Modus & Slant)

public struct SSTVSettingsPanel: View {
    @ObservedObject var settings: SSTVSettingsStore
    @ObservedObject var controller: SSTVController

    public init(settings: SSTVSettingsStore, controller: SSTVController) {
        self.settings = settings
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Modusauswahl (VIS Auto vs. Manuell)
            HStack(spacing: 6) {
                Text("MODUS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 42, alignment: .leading)

                Button("AUTO (VIS)") {
                    settings.manualMode = nil
                }
                .buttonStyle(ModeButtonStyle(isSelected: settings.manualMode == nil))
                .help("Automatische Erkennung über den 7-Bit VIS-Code")

                Picker("", selection: $settings.manualMode) {
                    Text("– Manuell wählen –").tag(nil as SSTVMode?)
                    ForEach(SSTVMode.allCases) { mode in
                        Text("\(mode.spec.name) (\(mode.spec.width)×\(mode.spec.height))").tag(mode as SSTVMode?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Slant-Korrektur (Schräglauf bei Audio-Clock-Drift)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("SLANT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .frame(width: 42, alignment: .leading)

                    Slider(value: $settings.slantPpm, in: -300...300, step: 1)

                    Text(String(format: "%+.0f ppm", settings.slantPpm))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                        .frame(width: 52, alignment: .trailing)

                    Button("0") {
                        settings.resetSlant()
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Slant auf 0 ppm zurücksetzen")
                }
            }

            // Zeilensynchronisation: jede Zeile auf ihren eigenen Syncimpuls ausrichten
            HStack(spacing: 6) {
                Text("SYNC")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 42, alignment: .leading)
                Toggle("Zeilensync nachführen", isOn: $settings.autoSync)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .help("Aus: nur der erste Syncimpuls zählt, danach laufen die Zeilen frei (mit Slant-Korrektur von Hand)")
            }
        }
    }
}

// MARK: - SSTV Bilder-Galerie

public struct SSTVGallery: View {
    @ObservedObject var controller: SSTVController

    public init(controller: SSTVController) {
        self.controller = controller
    }

    public var body: some View {
        if controller.gallery.isEmpty {
            Text("Noch kein Bild empfangen – Weltweiter Anrufkanal 14,230 MHz USB")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(maxWidth: .infinity, minHeight: 45)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(controller.gallery) { img in
                        HStack(spacing: 8) {
                            if let cg = img.cgImage {
                                Image(decorative: cg, scale: 1)
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 56, height: 42)
                                    .background(Color.black)
                                    .cornerRadius(3)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(img.mode.spec.shortName)
                                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                                        .foregroundColor(RadioTheme.vfdGreen)
                                    Text("· \(img.width)×\(img.height)")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(RadioTheme.textDim)
                                }
                                Text(Self.timeFormatter.string(from: img.timestamp) + " UTC")
                                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(RadioTheme.vfdCyan)
                            }

                            Spacer()

                            if let url = img.fileURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(ModeButtonStyle(isSelected: false))
                                .help("In Bildanzeige öffnen: \(url.lastPathComponent)")
                            }

                            Button {
                                controller.removeFromGallery(img)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: false))
                            .help("Aus Liste und Speicher entfernen")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
