import SwiftUI
import MapKit

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

/// Gemeinsame Karte für alle Module: Punkte, Wege, Großkreislinien, Standort, Auswahl mit Einzelheiten.
/// Das Modul liefert nur `MapContent`; Sicht, Stil und Standort-Eingabe sind hier.
struct MapPanel: View {
    let content: MapContent
    @ObservedObject var home: HomeLocation
    /// Gemeinsame Auswahl mit der Liste (optional)
    @Binding var selection: String?
    var legend: String? = nil

    @State private var camera: MapCameraPosition = .automatic
    @State private var fitted = false
    @State private var span: Double = 60
    @State private var showHomeEditor = false
    @State private var locatorText = ""
    @AppStorage("mapAppearance") private var appearanceRaw = MapAppearance.standard.rawValue

    private var appearance: MapAppearance { MapAppearance(rawValue: appearanceRaw) ?? .standard }

    init(content: MapContent, home: HomeLocation, selection: Binding<String?> = .constant(nil), legend: String? = nil) {
        self.content = content
        self.home = home
        self._selection = selection
        self.legend = legend
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
        .onChange(of: content.home) { _, _ in if !fitted { fit(force: true) } }
        .onChange(of: selection) { _, id in
            if let id, let m = content.markers.first(where: { $0.id == id }) {
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
            ForEach(content.lines) { line in
                MapPolyline(coordinates: line.points.map(\.cl), contourStyle: line.geodesic ? .geodesic : .straight)
                    .stroke(line.tone.color.opacity(0.55), lineWidth: 1.2)
            }
            ForEach(content.markers) { m in
                if m.track.count > 1 {
                    MapPolyline(coordinates: m.track.map(\.cl))
                        .stroke(m.tone.color.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
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
                    MarkerBadge(marker: m, selected: m.id == selection)
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
        .onMapCameraChange(frequency: .onEnd) { context in
            span = max(context.region.span.latitudeDelta, context.region.span.longitudeDelta)
        }
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
                Text(content.markers.count == 1 ? "1 Punkt" : "\(content.markers.count) Punkte")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RadioTheme.bgDeep.opacity(0.85))
                    .cornerRadius(4)
                if let legend {
                    Text(legend)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RadioTheme.bgDeep.opacity(0.85))
                        .cornerRadius(4)
                }
            }
        }
        .padding(8)
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
            ForEach(Array(m.details.prefix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                    .lineLimit(2)
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

    /// Ausschnitt auf alle Punkte setzen
    private func fit(force: Bool) {
        guard force else { return }
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

/// Punkt auf der Karte: Kreis in Tonfarbe mit Symbol oder Zeichen, Kursstrich
private struct MarkerBadge: View {
    let marker: MapMarker
    let selected: Bool

    var body: some View {
        let color = marker.tone.color
        ZStack {
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
        .shadow(color: color.opacity(selected ? 0.7 : 0.3), radius: selected ? 6 : 2)
    }
}
