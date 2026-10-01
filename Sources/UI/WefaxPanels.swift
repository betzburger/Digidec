import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Empfangsbild

struct WefaxImagePanel: View {
    @ObservedObject var controller: WefaxController
    @ObservedObject var schedule: WefaxScheduleStore
    @ObservedObject var auto: WefaxAutoRecorder
    @State private var showSchedule = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                let state = controller.status?.state ?? .idle
                Circle()
                    .fill(state == .image ? RadioTheme.vfdGreen : state == .phasing ? RadioTheme.vfdAmber : RadioTheme.textDim)
                    .frame(width: 8, height: 8)
                Text(controller.liveRows > 0 ? "\(controller.liveRows) Zeilen" : "Kein Bild")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                if let err = controller.lastSaveError {
                    Text(err)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.ledYellow)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showSchedule = true
                } label: {
                    Label("SENDEPLAN", systemImage: auto.session != nil ? "record.circle.fill" : "calendar")
                }
                .buttonStyle(ModeButtonStyle(isSelected: schedule.autoEnabled && !schedule.selected.isEmpty))
                .foregroundColor(auto.session != nil ? RadioTheme.ledRed : nil)
                .help("DWD-Sendeplan ansehen, aktualisieren und Sendungen zur automatischen Aufnahme wählen")
                Button {
                    controller.autoSave.toggle()
                } label: {
                    Label("AUTO", systemImage: controller.autoSave ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.autoSave))
                .help("Fertige Bilder automatisch als PNG ablegen: \(controller.directory.path)")
                Button {
                    controller.saveNow()
                } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Aktuelles Bild jetzt speichern (Empfang läuft weiter)")
                Button {
                    try? FileManager.default.createDirectory(at: controller.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(controller.directory)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Bildordner im Finder öffnen")
            }
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            if let img = controller.liveImage {
                                Image(decorative: img, scale: 1)
                                    .resizable()
                                    .interpolation(.medium)
                                    .aspectRatio(CGFloat(img.width) / CGFloat(max(img.height, 1)), contentMode: .fit)
                                    .frame(width: geo.size.width)
                            } else {
                                Text("Warten auf Bild – APT-Start oder Phasing-Zeilen starten den Empfang")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(RadioTheme.textDim)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                            Color.clear.frame(height: 1).id("ende")
                        }
                    }
                    .onChange(of: controller.liveRows) { _, _ in
                        proxy.scrollTo("ende", anchor: .bottom)
                    }
                }
            }
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
        .sheet(isPresented: $showSchedule) {
            WefaxScheduleSheet(store: schedule, auto: auto)
        }
    }
}

// MARK: - Abstimmanzeige

struct WefaxTuningPanel: View {
    @ObservedObject var controller: WefaxController
    @ObservedObject var settings: WefaxSettingsStore
    @ObservedObject var schedule: WefaxScheduleStore
    @ObservedObject var auto: WefaxAutoRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WefaxNextLine(store: schedule, auto: auto)
            HStack(spacing: 8) {
                let state = controller.status?.state ?? .idle
                Text(state.label)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundColor(state == .image ? RadioTheme.vfdGreen : state == .phasing ? RadioTheme.vfdAmber : RadioTheme.textMuted)
                Spacer()
                Text("IOC \(settings.options.ioc) · \(Int(controller.status?.lpm ?? Double(settings.options.lpm))) LPM")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
            .help("WARTEN AUF APT: Startton (300 Hz) wird gesucht · PHASING: Zeilenanfang wird bestimmt · BILD: Zeilen werden geschrieben")
            SignalBar(metric: controller.status?.metric ?? 0, squelch: nil)
                .help("Zeilenkorrelation (fldigi): hoch, solange ein Bild empfangen wird")
            HStack {
                readout("S/N", controller.status.map { String(format: "%.0f dB", $0.snrDB) } ?? "–")
                Spacer()
                readout("MITTE", "\(Int((controller.status?.centerHz ?? settings.centerHz).rounded())) Hz")
                Spacer()
                readout("HUB", "\(settings.options.shiftHz) Hz")
            }
            if settings.rigIsLSB == true {
                Label("Funkgerät steht auf LSB – WEFAX in USB empfangen (sonst Bild invertiert)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledYellow)
            }
            HStack(spacing: 6) {
                Button { controller.skipAPT() } label: { Label("APT", systemImage: "forward.end.fill") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("APT überspringen: nicht auf den Startton warten, gleich Phasing suchen (fldigi: Skip APT)")
                Button { controller.skipPhasing() } label: { Label("PHASING", systemImage: "forward.end.fill") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Phasing überspringen: sofort Bildzeilen schreiben (fldigi: Skip phasing)")
                Spacer()
                Button { controller.abort() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Abbruch: Bild verwerfen und wieder auf APT warten")
            }
            HStack(spacing: 6) {
                Button("NON-STOP") { controller.setNonStop(!(controller.status?.manual ?? false)) }
                    .buttonStyle(ModeButtonStyle(isSelected: controller.status?.manual ?? false))
                    .help("Ohne APT-Steuerung durchgehend Zeilen schreiben (fldigi: Non-stop)")
                Spacer()
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

// MARK: - Einstellungen

struct WefaxSettingsPanel: View {
    @ObservedObject var settings: WefaxSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(WefaxStation.allCases) { s in
                    Button {
                        settings.station = s
                    } label: {
                        VStack(spacing: 2) {
                            Text(s.label)
                            Text(s.note)
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.station == s))
                }
            }
            if let dial = settings.station.usbDial(center: settings.centerHz) {
                Text(verbatim: "USB-Dial \(String(format: "%.1f", dial / 1000).replacingOccurrences(of: ".", with: ",")) kHz → Mitte \(settings.options.centerHz) Hz")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
            HStack(spacing: 6) {
                label("LPM").frame(width: 40, alignment: .leading)
                ForEach(FldigiWefaxCore.lpmValues, id: \.self) { v in
                    Button("\(v)") { settings.options.lpm = v }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.lpm == v))
                }
                Spacer()
            }
            .help("Zeilen je Minute (DWD: 120)")
            HStack(spacing: 6) {
                label("IOC").frame(width: 40, alignment: .leading)
                ForEach([576, 288], id: \.self) { v in
                    Button("\(v)") { settings.options.ioc = v }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.ioc == v))
                }
                Spacer()
                label("HUB")
                ForEach([800, 850], id: \.self) { v in
                    Button("\(v)") { settings.options.shiftHz = v }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.shiftHz == v))
                }
            }
            HStack(spacing: 6) {
                label("FILTER").frame(width: 40, alignment: .leading)
                ForEach(Array(["SCHMAL", "MITTEL", "BREIT"].enumerated()), id: \.offset) { i, s in
                    Button(s) { settings.options.filter = i }
                        .buttonStyle(ModeButtonStyle(isSelected: settings.options.filter == i))
                        .help("ACfax-Tiefpass aus fldigi")
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Button("AFC") { settings.options.afc.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.afc))
                    .help("Mitte automatisch nachführen (fldigi, höchstens ±25 Hz)")
                Button("ZENTR.") { settings.options.autoCenter.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.autoCenter))
                    .help("Bild horizontal am Rand ausrichten (fldigi Auto-Center, Zeilen 30–500)")
                Button("ENTST.") { settings.options.noiseRemoval.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: settings.options.noiseRemoval))
                    .help("Einzelne Störpixel entfernen (fldigi Noise removal)")
                Spacer()
            }
            HStack(spacing: 6) {
                label("SCHRÄG")
                Slider(value: $settings.options.slant, in: -0.5...0.5)
                Text(String(format: "%+.2f %%", settings.options.slant))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 58, alignment: .trailing)
                    .onTapGesture(count: 2) { settings.options.slant = 0 }
            }
            .help("Schräglauf ausgleichen, falls die Soundkarte nicht genau 48 kHz liefert (Doppelklick: 0)")
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
    }
}

// MARK: - Galerie

struct WefaxGallery: View {
    @ObservedObject var controller: WefaxController
    @State private var editing: WefaxImage?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    controller.autoCorrectSeam.toggle()
                } label: {
                    Label("AUTO-NAHT", systemImage: "arrow.left.and.right")
                }
                .buttonStyle(ModeButtonStyle(isSelected: controller.autoCorrectSeam))
                .help("Karten, deren Zeilenanfang verrutscht ist (weißer Rand in der Bildmitte), zusätzlich korrigiert als „…_korr.png“ ablegen")
                Spacer()
                Button {
                    openFromDisk()
                } label: {
                    Label("BILD ÖFFNEN", systemImage: "folder.badge.plus")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Ein gespeichertes Wetterfax-Bild (PNG) zum Verschieben öffnen")
            }
            content
        }
        .sheet(item: $editing) { img in
            WefaxImageEditor(controller: controller, image: img)
        }
    }

    private func openFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller.directory
        panel.message = "Wetterfax-Bild zum Bearbeiten wählen"
        if panel.runModal() == .OK, let url = panel.url, let img = controller.openImage(url: url) {
            editing = img
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.gallery.isEmpty {
            Text("Noch kein Bild – DWD sendet rund um die Uhr nach Sendeplan")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(maxWidth: .infinity, minHeight: 50)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(controller.gallery) { img in
                        HStack(spacing: 8) {
                            if let cg = WefaxController.cgImage(pixels: img.pixels, width: img.width, height: img.height) {
                                Image(decorative: cg, scale: 1)
                                    .resizable()
                                    .interpolation(.medium)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 56, height: 42)
                                    .background(Color.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.time.string(from: img.receivedAt) + " UTC · \(img.height) Zeilen")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(RadioTheme.vfdCyan)
                                Text(img.endReasonGerman)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(RadioTheme.textDim)
                            }
                            Spacer()
                            Button {
                                editing = img
                            } label: {
                                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: false))
                            .help("Bild verschieben – wenn der linke Rand mitten in der Karte beginnt")
                            if let url = img.fileURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(ModeButtonStyle(isSelected: false))
                                .help("In Vorschau öffnen: \(url.lastPathComponent)")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
