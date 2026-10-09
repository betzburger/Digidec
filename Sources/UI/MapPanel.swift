// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import MapKit
import AppKit

/// Farben der Kartenpunkte im RadioTheme
extension MapTone {
    var color: Color {
        switch self {
        case .normal:    return RadioTheme.vfdGreen
        case .info:      return RadioTheme.vfdCyan
        case .highlight: return RadioTheme.vfdAmber
        case .alert:     return RadioTheme.ledRed
        case .dim:       return RadioTheme.textDim
        case .weather:   return Color(red: 0.45, green: 0.72, blue: 1.0)
        }
    }
}

extension GeoPoint {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// Darstellung der Karte (gemerkt)
enum MapAppearance: String, CaseIterable, Identifiable {
    case standard, hybrid, imagery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "KARTE"
        case .hybrid:   return "HYBRID"
        case .imagery:  return "SAT"
        }
    }
    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .hybrid:   return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .imagery:  return .imagery(elevation: .flat)
        }
    }
}

/// Zusätzlicher Knopf in der Auswahl eines Kartenpunkts (z. B. „IM TEXT“: zur Rohmeldung springen)
struct MapDetailAction {
    var title: String
    var help: String
    var systemImage: String
    /// Für welche Punkte der Knopf erscheint
    var applies: (MapMarker) -> Bool
    var perform: (MapMarker) -> Void
}

/// Gemeinsame Karte für alle Module: Punkte, Wege, Großkreislinien, Standort, Auswahl mit Einzelheiten.
/// Das Modul liefert nur `MapContent`; Sicht, Stil und Standort-Eingabe sind hier.
struct MapPanel: View {
    let content: MapContent
    @ObservedObject var home: HomeLocation
    /// Gemeinsame Auswahl mit der Liste (optional)
    @Binding var selection: String?
    var legend: String? = nil
    /// Zusätzliche Bedienelemente neben den Schaltern (z. B. Auswahl der Ansicht)
    var accessory: AnyView? = nil
    var detailAction: MapDetailAction? = nil
    /// Namensteil der Bilddatei („RTTY-TEMP“ → Karte-RTTY-TEMP-20261005-123000.png)
    var snapshotName: String = "Karte"
    /// Bei der Auswahl eines Punktes nur zentrieren, den Zoom aber lassen (dichte Karten wie AIS)
    var keepZoomOnSelect = false

    @State private var camera: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapSize: CGSize = .zero
    @State private var snapshotMessage: String?
    @State private var fitted = false
    @State private var devSelected = false
    @State private var span: Double = 60
    @State private var showHomeEditor = false
    @State private var locatorText = ""
    @AppStorage("mapAppearance") private var appearanceRaw = MapAppearance.standard.rawValue
    /// Wege (Spuren) der Punkte zeichnen
    @AppStorage("mapTracks") private var showTracks = true

    private var appearance: MapAppearance { MapAppearance(rawValue: appearanceRaw) ?? .standard }

    init(content: MapContent, home: HomeLocation, selection: Binding<String?> = .constant(nil), legend: String? = nil, accessory: AnyView? = nil,
         detailAction: MapDetailAction? = nil, snapshotName: String = "Karte", keepZoomOnSelect: Bool = false) {
        self.content = content
        self.home = home
        self._selection = selection
        self.legend = legend
        self.accessory = accessory
        self.detailAction = detailAction
        self.snapshotName = snapshotName
        self.keepZoomOnSelect = keepZoomOnSelect
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            map
            controls
            if let m = selected { detail(m) }
            if content.markers.isEmpty {
                Text(content.emptyHint)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RadioTheme.bgDeep.opacity(0.85))
                    .cornerRadius(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
        .onAppear { fit(force: true) }
        .onChange(of: content.markers.isEmpty) { _, empty in if !empty && !fitted { fit(force: true) } }
        .onChange(of: content.markers.reduce(content.markers.count) { $0 &+ $1.track.count }) { _, _ in
            // Entwicklungshilfe: DIGIDEC_MAP_SELECT=<Punkt-ID> wählt den Punkt, sobald er einen Weg hat (für Schnappschüsse)
            if !devSelected, let id = ProcessInfo.processInfo.environment["DIGIDEC_MAP_SELECT"], content.markers.contains(where: { $0.id == id && $0.track.count > 1 }) {
                devSelected = true
                selection = id
            }
        }
        .onChange(of: content.home) { _, _ in if !fitted { fit(force: true) } }
        .onChange(of: selection) { _, id in
            guard let id, let m = content.markers.first(where: { $0.id == id }) else { return }
            if keepZoomOnSelect {
                withAnimation { camera = .region(MKCoordinateRegion(center: m.coordinate.cl, span: MKCoordinateSpan(latitudeDelta: max(span, 0.005), longitudeDelta: max(span, 0.005)))) }
            } else if showTracks, m.track.count > 1, let r = Self.region(of: m.track) {
                // Der Weg der Station soll ganz zu sehen sein
                withAnimation { camera = .region(r) }
            } else {
                withAnimation { camera = .region(MKCoordinateRegion(center: m.coordinate.cl, span: MKCoordinateSpan(latitudeDelta: min(max(span, 2), 40), longitudeDelta: min(max(span, 2), 40)))) }
            }
        }
    }

    private var selected: MapMarker? {
        guard let id = selection else { return nil }
        return content.markers.first { $0.id == id }
    }

    private var showTitles: Bool { span < 25 || content.markers.count < 25 }

    private var map: some View {
        Map(position: $camera, selection: $selection) {
            ForEach(content.patches) { patch in
                MapPolygon(coordinates: patch.corners.map(\.cl))
                    .foregroundStyle(MarkerBadge.scale(patch.level).opacity(0.32))
            }
            ForEach(content.contours) { contour in
                // dunkler Saum für den Kontrast auf hellen und bunten Karten, darüber die weiße Linie
                MapPolyline(coordinates: contour.points.map(\.cl))
                    .stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: contour.points.map(\.cl))
                    .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(content.contours) { contour in
                if let label = contour.label, let at = contour.labelPoint {
                    Annotation("", coordinate: at.cl, anchor: .center) {
                        Text(label)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.white.opacity(0.85)))
                    }
                }
            }
            ForEach(content.lines) { line in
                MapPolyline(coordinates: line.points.map(\.cl), contourStyle: line.geodesic ? .geodesic : .straight)
                    .stroke(line.tone.color.opacity(0.55), lineWidth: 1.2)
            }
            if showTracks {
                ForEach(content.markers) { m in
                    if m.track.count > 1 {
                        let pts = m.track.map(\.cl)
                        let isSelected = m.id == selection
                        // dunkle Kontur für den Kontrast auf der Karte, darüber der Weg; die letzten Abschnitte kräftiger (Fahrtrichtung)
                        MapPolyline(coordinates: pts)
                            .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: isSelected ? 7 : 5, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: pts)
                            .stroke(m.tone.color.opacity(isSelected ? 0.95 : 0.6), style: StrokeStyle(lineWidth: isSelected ? 4 : 3, lineCap: .round, lineJoin: .round))
                        if pts.count > 2 {
                            MapPolyline(coordinates: Array(pts.suffix(4)))
                                .stroke(m.tone.color, style: StrokeStyle(lineWidth: isSelected ? 4 : 3.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                // Gewählter Punkt: jede empfangene Position als Markierung, der Anfang des Wegs weiß
                if let sel = selected, sel.track.count > 1 {
                    ForEach(Array(sel.track.dropLast().enumerated()), id: \.offset) { i, p in
                        Annotation("", coordinate: p.cl, anchor: .center) {
                            Circle()
                                .fill(i == 0 ? Color.white : sel.tone.color)
                                .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                                .frame(width: i == 0 ? 9 : 6, height: i == 0 ? 9 : 6)
                                .help(i == 0 ? "Anfang des Wegs" : "Position \(i + 1) von \(sel.track.count)")
                        }
                    }
                }
            }
            ForEach(content.markers) { m in
                if m.radiusKm > 0 {
                    MapCircle(center: m.coordinate.cl, radius: m.radiusKm * 1000)
                        .foregroundStyle(m.tone.color.opacity(0.07))
                        .stroke(m.tone.color.opacity(0.5), lineWidth: 1)
                }
            }
            if let h = content.home {
                Annotation("", coordinate: h.cl, anchor: .center) {
                    ZStack {
                        Circle().fill(RadioTheme.bgDeep.opacity(0.9)).frame(width: 22, height: 22)
                        Circle().stroke(RadioTheme.vfdAmber, lineWidth: 2).frame(width: 22, height: 22)
                        Image(systemName: "house.fill").font(.system(size: 10, weight: .bold)).foregroundColor(RadioTheme.vfdAmber)
                    }
                    .help("Eigener Standort \(home.locator)")
                }
            }
            ForEach(content.markers) { m in
                Annotation(showTitles ? m.title : "", coordinate: m.coordinate.cl, anchor: .center) {
                    MarkerBadge(marker: m, selected: m.id == selection, span: span)
                }
                .tag(m.id)
            }
        }
        .mapStyle(appearance.style)
        .mapControls {
            MapScaleView()
            MapCompass()
            MapZoomStepper()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            span = max(context.region.span.latitudeDelta, context.region.span.longitudeDelta)
            visibleRegion = context.region
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { mapSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in mapSize = newSize }
            }
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Button("ALLE") { fit(force: true) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Alle Punkte und den Standort ins Bild holen")
                Button {
                    locatorText = home.locator
                    showHomeEditor.toggle()
                } label: {
                    Label("QTH", systemImage: "house")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Eigener Standort (Maidenhead-Locator), gilt für alle Module")
                .popover(isPresented: $showHomeEditor) { homeEditor }
                Picker("", selection: $appearanceRaw) {
                    ForEach(MapAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("Kartendarstellung")
                if content.markers.contains(where: { $0.track.count > 1 }) {
                    Button {
                        showTracks.toggle()
                    } label: {
                        Label("SPUR", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: showTracks))
                    .help("Weg der bewegten Stationen als Linie zeichnen; ein Klick auf einen Punkt zeigt seinen ganzen Weg")
                }
                Button {
                    saveImage()
                } label: {
                    Label("BILD", systemImage: "camera")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Den sichtbaren Kartenausschnitt mit Punkten, Isobaren und Flächen als PNG speichern (~/Documents/Digidec/Maps)")
                Text(content.markers.count == 1 ? "1 Punkt" : "\(content.markers.count) Punkte")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RadioTheme.bgDeep.opacity(0.85))
                    .cornerRadius(4)
                if let accessory { accessory }
                if let legend {
                    Text(LocalizedStringKey(legend))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RadioTheme.bgDeep.opacity(0.85))
                        .cornerRadius(4)
                }
            }
            if let note = snapshotMessage ?? content.note {
                Text(note)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(snapshotMessage != nil ? RadioTheme.vfdCyan : RadioTheme.vfdAmber)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RadioTheme.bgDeep.opacity(0.85))
                    .cornerRadius(4)
            }
        }
        .padding(8)
    }

    /// Meldung unter den Schaltern, verschwindet nach einigen Sekunden
    private func flash(_ text: String, keep: Bool = false) {
        snapshotMessage = text
        guard !keep else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if snapshotMessage == text { snapshotMessage = nil }
        }
    }

    /// Sichtbaren Ausschnitt als PNG ablegen und im Finder zeigen
    private func saveImage() {
        guard let region = visibleRegion, mapSize.width > 50, mapSize.height > 50 else {
            flash("Karte noch nicht bereit")
            return
        }
        flash("Bild wird erstellt …", keep: true)
        let content = self.content, appearance = self.appearance, tracks = showTracks, size = mapSize, name = snapshotName, title = legend
        Task { @MainActor in
            let result = await MapSnapshotExporter.save(content: content, region: region, size: size, appearance: appearance,
                                                        showTracks: tracks, name: name, title: title)
            switch result {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                flash("Gespeichert: " + url.lastPathComponent)
            case .failure(let error):
                flash(error.message)
            }
        }
    }

    private var homeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EIGENER STANDORT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            HStack {
                TextField("JN49WS", text: $locatorText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 100)
                    .onSubmit { applyLocator() }
                Button("ÜBERNEHMEN") { applyLocator() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(Maidenhead.coordinate(locatorText.uppercased()) == nil)
            }
            if let p = Maidenhead.point(locatorText.uppercased()) {
                Text(Geo.format(p))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
            } else {
                Text("4 oder 6 Zeichen, z. B. JN49 oder JN49WS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(RadioTheme.bgCard)
    }

    private func applyLocator() {
        let v = locatorText.uppercased().trimmingCharacters(in: .whitespaces)
        guard Maidenhead.coordinate(v) != nil else { return }
        home.locator = v
        showHomeEditor = false
        fitted = false
    }

    private func detail(_ m: MapMarker) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let s = m.symbol {
                    Image(systemName: s).font(.system(size: 11, weight: .bold)).foregroundColor(m.tone.color)
                } else if let g = m.glyph {
                    Text(g).font(.system(size: 12))
                }
                Text(m.title).font(.system(size: 12, weight: .black, design: .monospaced)).foregroundColor(m.tone.color)
                Spacer()
                Button { selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundColor(RadioTheme.textMuted)
            }
            if let sub = m.subtitle {
                Text(sub).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
            }
            ForEach(Array(m.details.prefix(10).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                    .lineLimit(2)
            }
            if let action = detailAction, action.applies(m) {
                Button {
                    action.perform(m)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help(action.help)
                .padding(.top, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: 360, alignment: .leading)
        .background(RadioTheme.bgDeep.opacity(0.92))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(m.tone.color.opacity(0.7), lineWidth: 1))
        .cornerRadius(6)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// Ausschnitt um einen Weg (mit Rand)
    static func region(of track: [GeoPoint]) -> MKCoordinateRegion? {
        guard let f = track.first else { return nil }
        var minLat = f.lat, maxLat = f.lat, minLon = f.lon, maxLon = f.lon
        for p in track {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: min(max((maxLat - minLat) * 1.8, 0.01), 170),
                                                         longitudeDelta: min(max((maxLon - minLon) * 1.8, 0.01), 350)))
    }

    /// Ausschnitt auf alle Punkte setzen
    private func fit(force: Bool) {
        guard force else { return }
        // Entwicklungshilfe: DIGIDEC_MAP_VIEW="Breite,Länge,Spanne" (Grad) legt den Ausschnitt fest, z. B. für Schnappschüsse
        if let v = ProcessInfo.processInfo.environment["DIGIDEC_MAP_VIEW"] {
            let n = v.split(separator: ",").compactMap { Double($0) }
            if n.count == 3 {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: n[0], longitude: n[1]),
                                                    span: MKCoordinateSpan(latitudeDelta: n[2], longitudeDelta: n[2])))
                fitted = true
                return
            }
        }
        guard let r = content.region() else {
            if let h = content.home ?? home.point {
                camera = .region(MKCoordinateRegion(center: h.cl, span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 12)))
            }
            return
        }
        fitted = !content.markers.isEmpty
        camera = .region(MKCoordinateRegion(center: r.center.cl, span: MKCoordinateSpan(latitudeDelta: max(r.latSpan, 0.05), longitudeDelta: max(r.lonSpan, 0.05))))
    }
}

/// Umriss eines Fahrzeugs (Quadrat −1 … +1 auf die Fläche gespannt)
struct SilhouetteShape: Shape {
    let silhouette: MapSilhouette

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX, cy = rect.midY, hx = rect.width / 2, hy = rect.height / 2
        for contour in silhouette.contours {
            guard let first = contour.first else { continue }
            path.move(to: CGPoint(x: cx + first.x * hx, y: cy + first.y * hy))
            for p in contour.dropFirst() { path.addLine(to: CGPoint(x: cx + p.x * hx, y: cy + p.y * hy)) }
            path.closeSubpath()
        }
        return path
    }
}

/// Punkt auf der Karte: Kreis in Tonfarbe mit Symbol oder Zeichen, Kursstrich
struct MarkerBadge: View {
    let marker: MapMarker
    let selected: Bool
    var span: Double = 60

    var body: some View {
        let color = marker.valueLevel.map { Self.scale($0) } ?? marker.tone.color
        // Bei starkem Hereinzoomen vergrößern sich die Silhouetten (1,0x bis 2,2x)
        let zoomScale: CGFloat = {
            guard span < 2.0 else { return 1.0 }
            let steps = max(0.0, -log2(span / 2.0))
            return min(2.2, 1.0 + 0.16 * CGFloat(steps))
        }()
        ZStack {
            if let text = marker.valueText {
                // Messwert: Beschriftung auf farbigem Grund, bei Wind mit Pfeil in Windrichtung
                if let h = marker.headingDeg {
                    Image(systemName: "arrow.up")
                        .font(.system(size: selected ? 13 : 11, weight: .black))
                        .foregroundColor(color)
                        .rotationEffect(.degrees(h))
                        .offset(y: selected ? -20 : -17)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
                Text(text)
                    .font(.system(size: selected ? 12 : 10, weight: .black, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(color))
                    .overlay(Capsule().stroke(selected ? Color.white : Color.black.opacity(0.4), lineWidth: selected ? 2 : 1))
                    .shadow(color: color.opacity(selected ? 0.8 : 0.35), radius: selected ? 6 : 2)
            } else if let sil = marker.silhouette {
                // Umriss von oben, um den Kurs gedreht (Höhe oder Tonfarbe), bei Auswahl größer mit weißem Rand und Schein
                let side = sil.size * marker.silhouetteScale * zoomScale * (selected ? 1.3 : 1)
                SilhouetteShape(silhouette: sil)
                    .fill(color)
                    .overlay(SilhouetteShape(silhouette: sil).stroke(selected ? Color.white : Color.black.opacity(0.7), lineWidth: selected ? 1.6 : 0.9))
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(marker.headingDeg ?? 0))
                    .shadow(color: color.opacity(selected ? 0.9 : 0.35), radius: selected ? 6 : 2)
            } else {
            
            if let h = marker.headingDeg {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(color)
                    .rotationEffect(.degrees(h))
                    .offset(y: -14)
                    .rotationEffect(.degrees(0))
            }
            Circle().fill(RadioTheme.bgDeep.opacity(0.92)).frame(width: selected ? 24 : 18, height: selected ? 24 : 18)
            Circle().stroke(color, lineWidth: selected ? 2.5 : 1.5).frame(width: selected ? 24 : 18, height: selected ? 24 : 18)
            if let s = marker.symbol {
                Image(systemName: s).font(.system(size: selected ? 11 : 8.5, weight: .bold)).foregroundColor(color)
            } else if let g = marker.glyph {
                Text(g).font(.system(size: selected ? 13 : 10))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            }
        }
        .shadow(color: marker.valueText == nil && marker.silhouette == nil ? color.opacity(selected ? 0.7 : 0.3) : .clear, radius: selected ? 6 : 2)
    }

    /// Farbskala 0 (blau) … 0,5 (grün/gelb) … 1 (rot)
    static func scale(_ level: Double) -> Color {
        Color(hue: 0.66 * (1 - min(max(level, 0), 1)), saturation: 0.75, brightness: 0.98)
    }
}
