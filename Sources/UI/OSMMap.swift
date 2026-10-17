// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: gemeinsame Karte aller Module auf OpenStreetMap-Kacheln (statt MapKit): Punkte, Wege, Großkreislinien,
// Isobaren, Farbflächen, Standort, Auswahl mit Einzelheiten, Tag-/Nachtdarstellung, Bild speichern.
#if !canImport(MapKit)
import SwiftUI

// MARK: - Projektion (Web-Mercator)

/// Ausschnitt der Karte: Mitte in Weltkoordinaten (0 … 1) und Zoomstufe
struct MapProjection {
    var cx: Double
    var cy: Double
    var zoom: Double
    var size: CGSize

    var scale: Double { 256 * pow(2, zoom) }

    static func worldX(_ lon: Double) -> Double { (lon + 180) / 360 }
    static func worldY(_ lat: Double) -> Double {
        let clamped = min(max(lat, -85.0511), 85.0511) * .pi / 180
        return 0.5 - log(tan(.pi / 4 + clamped / 2)) / (2 * .pi)
    }
    static func lon(_ x: Double) -> Double { x * 360 - 180 }
    static func lat(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi }

    /// Bildschirmpunkt; die Länge wird auf die Weltkopie neben der Bildmitte gelegt
    func point(_ p: GeoPoint) -> CGPoint {
        var dx = Self.worldX(p.lon) - cx
        dx -= (dx).rounded()
        return CGPoint(x: size.width / 2 + dx * scale, y: size.height / 2 + (Self.worldY(p.lat) - cy) * scale)
    }

    /// Wie `point`, aber fortlaufend zu `previous` (Wege über den Datumswechsel)
    func point(_ p: GeoPoint, after previous: CGPoint?) -> CGPoint {
        var pt = point(p)
        if let previous {
            let world = scale
            while pt.x - previous.x > world / 2 { pt.x -= world }
            while previous.x - pt.x > world / 2 { pt.x += world }
        }
        return pt
    }

    func geo(at pt: CGPoint) -> GeoPoint {
        GeoPoint(lat: Self.lat(cy + (pt.y - size.height / 2) / scale), lon: Self.lon(cx + (pt.x - size.width / 2) / scale))
    }

    /// Sichtbare Spanne in Grad Breite (für die Größe der Symbole)
    var spanDegrees: Double {
        let lat = Self.lat(cy)
        return max(size.width, size.height) / scale * 360 * max(cos(lat * .pi / 180), 0.05)
    }

    /// Meter je Bildpunkt auf der Breite `lat`
    func metersPerPoint(at lat: Double) -> Double { 40_075_016.686 * cos(lat * .pi / 180) / scale }
}

// MARK: - Zustand der Kamera

@MainActor
final class OSMController: ObservableObject {
    init() { if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("OSMController init \(ObjectIdentifier(self).hashValue % 10000)\n".utf8)) } }
    var cx = MapProjection.worldX(10), cy = MapProjection.worldY(50), zoom = 4.0
    var size = CGSize.zero
    var hover: CGPoint?
    private var fitRequest: (center: GeoPoint, latSpan: Double, lonSpan: Double)?
    private var dragOrigin: (cx: Double, cy: Double)?

    var projection: MapProjection { MapProjection(cx: cx, cy: cy, zoom: zoom, size: size) }

    func changed() { objectWillChange.send() }

    func updateSize(_ s: CGSize) {
        guard s != size, s.width > 1, s.height > 1 else { return }
        size = s
        if let r = fitRequest { fitRequest = nil; setRegion(center: r.center, latSpan: r.latSpan, lonSpan: r.lonSpan) }
    }

    func setRegion(center: GeoPoint, latSpan: Double, lonSpan: Double) {
        guard size.width > 1, size.height > 1 else { fitRequest = (center, latSpan, lonSpan); return }
        let top = MapProjection.worldY(min(center.lat + latSpan / 2, 85)), bottom = MapProjection.worldY(max(center.lat - latSpan / 2, -85))
        let width = max(lonSpan / 360, 1e-7), height = max(bottom - top, 1e-7)
        zoom = min(max(log2(min(Double(size.width) / (256 * width), Double(size.height) / (256 * height))), 1), 18)
        cx = MapProjection.worldX(center.lon)
        cy = (top + bottom) / 2
        clampCenter()
        changed()
    }

    func center(on p: GeoPoint, zoom z: Double? = nil) {
        cx = MapProjection.worldX(p.lon); cy = MapProjection.worldY(p.lat)
        if let z { zoom = min(max(z, 1), 18) }
        clampCenter()
        changed()
    }

    private func clampCenter() {
        cy = min(max(cy, 0.001), 0.999)
        cx -= floor(cx)
    }

    func zoomBy(_ delta: Double, at point: CGPoint?) {
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("zoomBy obj \(ObjectIdentifier(self).hashValue % 10000) \(delta) at \(String(describing: point)) zoom \(zoom)\n".utf8)) }
        let old = projection
        let anchor = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let before = old.geo(at: anchor)
        zoom = min(max(zoom + delta, 1), 18)
        // Der Punkt unter dem Zeiger bleibt unter dem Zeiger
        let after = projection
        let dx = (anchor.x - size.width / 2) / after.scale, dy = (anchor.y - size.height / 2) / after.scale
        cx = MapProjection.worldX(before.lon) - dx
        cy = MapProjection.worldY(before.lat) - dy
        clampCenter()
        changed()
    }

    func beginDrag() {
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("beginDrag\n".utf8)) }
 if dragOrigin == nil { dragOrigin = (cx, cy) } }
    func drag(_ t: CGSize) {
        guard let o = dragOrigin else { return }
        let s = projection.scale
        cx = o.cx - Double(t.width) / s
        cy = o.cy - Double(t.height) / s
        clampCenter()
        changed()
    }
    func endDrag() { dragOrigin = nil }
}

// MARK: - Zeichnen

@MainActor
enum OSMDrawing {
    /// Kachelebenen für Darstellung und Tageszeit
    static func layers(_ appearance: MapAppearance, day: Bool) -> [TileLayer] {
        switch appearance {
        case .standard: return [day ? .osm : .osmNight]
        case .hybrid: return [.esriImagery, .esriLabels]
        case .imagery: return [.esriImagery]
        }
    }

    static func drawTiles(_ g: inout GraphicsContext, size: CGSize, projection p: MapProjection, layers: [TileLayer], store: TileStore, dim: Double) {
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RadioTheme.bgDeep))
        for layer in layers {
            let z = min(max(Int((p.zoom + 0.25).rounded(.down)), 0), layer.maxZoom)
            let n = 1 << z
            let tileSize = p.scale / Double(n)
            let left = Double(size.width) / -2 / tileSize + p.cx * Double(n), top = Double(size.height) / -2 / tileSize + p.cy * Double(n)
            let x0 = Int(floor(left)), x1 = Int(floor(left + Double(size.width) / tileSize))
            let y0 = max(0, Int(floor(top))), y1 = min(n - 1, Int(floor(top + Double(size.height) / tileSize)))
            guard y0 <= y1 else { continue }
            for ty in y0...y1 {
                for tx in x0...x1 {
                    let wrapped = ((tx % n) + n) % n
                    let rect = CGRect(x: (Double(tx) / Double(n) - p.cx) * p.scale + Double(size.width) / 2,
                                      y: (Double(ty) / Double(n) - p.cy) * p.scale + Double(size.height) / 2,
                                      width: tileSize + 0.5, height: tileSize + 0.5)
                    if let tile = store.tile(TileKey(layer: layer, z: z, x: wrapped, y: ty)) {
                        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("tile \(z)/\(wrapped)/\(ty) at \(rect) \(tile.width)x\(tile.height)\n".utf8)) }
                        g.draw(tile: tile, in: rect)
                    } else {
                        // Ersatz: Ausschnitt der Kachel einer niedrigeren Stufe, bis die echte da ist
                        var level = 1
                        while level <= 4, z - level >= 0 {
                            let pz = z - level, f = 1 << level
                            if let parent = store.cached(TileKey(layer: layer, z: pz, x: wrapped / f, y: ty / f)) {
                                let part = Double(parent.width) / Double(f)
                                let src = CGRect(x: Double(wrapped % f) * part, y: Double(ty % f) * part, width: part, height: part)
                                g.draw(tile: parent, in: rect, source: src)
                                break
                            }
                            level += 1
                        }
                    }
                }
            }
        }
        if dim > 0 { g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(dim))) }
    }

    /// Großkreis zwischen zwei Punkten als Folge von Punkten
    static func geodesic(_ a: GeoPoint, _ b: GeoPoint, steps: Int = 48) -> [GeoPoint] {
        let φ1 = a.lat * .pi / 180, λ1 = a.lon * .pi / 180, φ2 = b.lat * .pi / 180, λ2 = b.lon * .pi / 180
        let d = 2 * asin(min(1, sqrt(pow(sin((φ2 - φ1) / 2), 2) + cos(φ1) * cos(φ2) * pow(sin((λ2 - λ1) / 2), 2))))
        guard d > 1e-9 else { return [a, b] }
        return (0...steps).map { i in
            let f = Double(i) / Double(steps)
            let A = sin((1 - f) * d) / sin(d), B = sin(f * d) / sin(d)
            let x = A * cos(φ1) * cos(λ1) + B * cos(φ2) * cos(λ2)
            let y = A * cos(φ1) * sin(λ1) + B * cos(φ2) * sin(λ2)
            let z = A * sin(φ1) + B * sin(φ2)
            return GeoPoint(lat: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, lon: atan2(y, x) * 180 / .pi)
        }
    }

    private static func polyline(_ points: [GeoPoint], _ p: MapProjection) -> Path {
        var path = Path()
        var previous: CGPoint?
        for (i, geo) in points.enumerated() {
            let pt = p.point(geo, after: previous)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            previous = pt
        }
        return path
    }

    /// Flächen, Isobaren, Linien, Wege und Reichweitenkreise (unter den Symbolen)
    static func drawOverlays(_ g: inout GraphicsContext, projection p: MapProjection, content: MapContent, showTracks: Bool, selection: String?) {
        for patch in content.patches {
            var path = Path()
            var previous: CGPoint?
            for (i, c) in patch.corners.enumerated() {
                let pt = p.point(c, after: previous)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                previous = pt
            }
            path.closeSubpath()
            g.fill(path, with: .color(MarkerBadge.scale(patch.level).opacity(0.32)))
        }
        for contour in content.contours {
            let path = polyline(contour.points, p)
            g.stroke(path, with: .color(Color.black.opacity(0.45)), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
            g.stroke(path, with: .color(Color.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        for contour in content.contours {
            guard let label = contour.label, let at = contour.labelPoint else { continue }
            let pt = p.point(at)
            let text = Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black)
            let w = CGFloat(label.count) * 5.6 + 8
            g.fill(Path(roundedRect: CGRect(x: pt.x - w / 2, y: pt.y - 7, width: w, height: 14), cornerRadius: 7), with: .color(Color.white.opacity(0.85)))
            g.draw(text, at: pt, anchor: .center)
        }
        for line in content.lines {
            let points = line.geodesic && line.points.count == 2 ? geodesic(line.points[0], line.points[1]) : line.points
            g.stroke(polyline(points, p), with: .color(line.tone.color.opacity(0.55)), lineWidth: 1.2)
        }
        if showTracks {
            for m in content.markers where m.track.count > 1 {
                let path = polyline(m.track, p)
                let isSelected = m.id == selection
                g.stroke(path, with: .color(Color.black.opacity(0.55)), style: StrokeStyle(lineWidth: isSelected ? 7 : 5, lineCap: .round, lineJoin: .round))
                g.stroke(path, with: .color(m.tone.color.opacity(isSelected ? 0.95 : 0.6)), style: StrokeStyle(lineWidth: isSelected ? 4 : 3, lineCap: .round, lineJoin: .round))
                if m.track.count > 2 {
                    g.stroke(polyline(Array(m.track.suffix(4)), p), with: .color(m.tone.color), style: StrokeStyle(lineWidth: isSelected ? 4 : 3.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        for m in content.markers where m.radiusKm > 0 {
            let center = p.point(m.coordinate)
            let r = CGFloat(m.radiusKm * 1000 / p.metersPerPoint(at: m.coordinate.lat))
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            g.fill(circle, with: .color(m.tone.color.opacity(0.07)))
            g.stroke(circle, with: .color(m.tone.color.opacity(0.5)), lineWidth: 1)
        }
    }

    /// Maßstabsleiste unten links: rundet auf 1, 2 oder 5 × 10ⁿ
    static func drawScale(_ g: inout GraphicsContext, projection p: MapProjection, origin: CGPoint) {
        let lat = MapProjection.lat(p.cy)
        let perPoint = p.metersPerPoint(at: lat)
        guard perPoint > 0 else { return }
        let target = perPoint * 110
        let magnitude = pow(10, floor(log10(target)))
        let step = [1.0, 2, 5, 10].last { $0 * magnitude <= target } ?? 1
        let meters = step * magnitude
        let width = CGFloat(meters / perPoint)
        let label = meters >= 1000 ? "\(Int(meters / 1000)) km" : "\(Int(meters)) m"
        var path = Path()
        path.move(to: CGPoint(x: origin.x, y: origin.y - 4)); path.addLine(to: origin); path.addLine(to: CGPoint(x: origin.x + width, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x + width, y: origin.y - 4))
        g.stroke(path, with: .color(Color.black.opacity(0.7)), lineWidth: 3.5)
        g.stroke(path, with: .color(Color.white.opacity(0.95)), lineWidth: 1.5)
        g.draw(Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: origin.x + width + 6, y: origin.y - 3), anchor: .leading)
    }
}

// MARK: - Die Karte

struct MapPanel: View {
    let content: MapContent
    @ObservedObject var home: HomeLocation
    @Binding var selection: String?
    var legend: String? = nil
    var accessory: AnyView? = nil
    var detailAction: MapDetailAction? = nil
    var snapshotName: String = "Karte"
    var keepZoomOnSelect = false

    @StateObject private var camera = OSMController()
    @ObservedObject private var tiles = TileStore.shared
    @State private var snapshotMessage: String?
    @State private var fitted = false
    @State private var devSelected = false
    @State private var showHomeEditor = false
    @State private var locatorText = ""
    @AppStorage("mapAppearance") private var appearanceRaw = MapAppearance.standard.rawValue
    @AppStorage("mapDayMode") private var dayMode = false
    @AppStorage("mapTracks") private var showTracks = true

    private var appearance: MapAppearance { MapAppearance(rawValue: appearanceRaw) ?? .standard }

    init(content: MapContent, home: HomeLocation, selection: Binding<String?> = .constant(nil), legend: String? = nil, accessory: AnyView? = nil,
         detailAction: MapDetailAction? = nil, snapshotName: String = "Karte", keepZoomOnSelect: Bool = false) {
        self.content = content; self.home = home; self._selection = selection; self.legend = legend; self.accessory = accessory
        self.detailAction = detailAction; self.snapshotName = snapshotName; self.keepZoomOnSelect = keepZoomOnSelect
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            mapLayer
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
        .onAppear { fit() }
        .onChange(of: content.markers.isEmpty) { _, empty in if !empty && !fitted { fit() } }
        .onChange(of: content.markers.reduce(content.markers.count) { $0 &+ $1.track.count }) { _, _ in
            // Entwicklungshilfe: DIGIDEC_MAP_SELECT=<Punkt-ID> wählt den Punkt, sobald er einen Weg hat (für Schnappschüsse)
            if !devSelected, let id = ProcessInfo.processInfo.environment["DIGIDEC_MAP_SELECT"], content.markers.contains(where: { $0.id == id && $0.track.count > 1 }) {
                devSelected = true
                selection = id
            }
        }
        .onChange(of: content.home) { _, _ in if !fitted { fit() } }
        .onChange(of: selection) { _, id in
            guard let id, let m = content.markers.first(where: { $0.id == id }) else { return }
            let span = max(camera.projection.spanDegrees, 0.005)
            if keepZoomOnSelect {
                camera.setRegion(center: m.coordinate, latSpan: span, lonSpan: span)
            } else if showTracks, m.track.count > 1, let r = Self.region(of: m.track) {
                camera.setRegion(center: r.center, latSpan: r.latSpan, lonSpan: r.lonSpan)
            } else {
                let s = min(max(span, 2), 40)
                camera.setRegion(center: m.coordinate, latSpan: s, lonSpan: s)
            }
        }
    }

    private var selected: MapMarker? {
        guard let id = selection else { return nil }
        return content.markers.first { $0.id == id }
    }

    private var layers: [TileLayer] { OSMDrawing.layers(appearance, day: dayMode) }

    private var mapLayer: some View {
        GeometryReader { proxy in
            let _ = camera.updateSize(proxy.size)
            let p = camera.projection
            let showTitles = p.spanDegrees < 25 || content.markers.count < 25
            ZStack(alignment: .topLeading) {
                Canvas { g, size in MainActor.assumeIsolated {
                    let projection = camera.projection
                    OSMDrawing.drawTiles(&g, size: size, projection: projection, layers: layers, store: tiles,
                                         dim: appearance == .standard ? 0 : (dayMode ? 0 : 0.28))
                    OSMDrawing.drawOverlays(&g, projection: projection, content: content, showTracks: showTracks, selection: selection)
                    OSMDrawing.drawScale(&g, projection: projection, origin: CGPoint(x: 12, y: size.height - 28))
                    let note = layers.map(\.attribution).joined(separator: " · ")
                    g.draw(Text(note).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(Color.white.opacity(0.75)),
                           at: CGPoint(x: size.width - 90, y: size.height - 8), anchor: .trailing)
                    if tiles.networkFailures > 12 {
                        g.draw(Text("Keine Verbindung zum Kartenserver").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.vfdAmber),
                               at: CGPoint(x: size.width / 2, y: size.height - 20), anchor: .center)
                    }
                } }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in camera.beginDrag(); camera.drag(value.translation) }
                    .onEnded { value in
                        camera.endDrag()
                        // Ein Klick ohne Ziehen auf freie Fläche hebt die Auswahl auf
                        if hypot(value.translation.width, value.translation.height) < 3 { selection = nil }
                    })
                .onContinuousHover { phase in
                    if case .active(let pt) = phase { camera.hover = pt } else { camera.hover = nil }
                }
                .onScrollWheel { delta, _ in camera.zoomBy(Double(delta) * 0.012, at: camera.hover) }

                ForEach(selectedTrackDots.indices, id: \.self) { i in
                    let d = selectedTrackDots[i]
                    let pt = p.point(d.point)
                    Circle()
                        .fill(d.first ? Color.white : d.tone.color)
                        .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                        .frame(width: d.first ? 9 : 6, height: d.first ? 9 : 6)
                        .position(x: pt.x, y: pt.y)
                }
                if let h = content.home {
                    let pt = p.point(h)
                    ZStack {
                        Circle().fill(RadioTheme.bgDeep.opacity(0.9)).frame(width: 22, height: 22)
                        Circle().stroke(RadioTheme.vfdAmber, lineWidth: 2).frame(width: 22, height: 22)
                        Image(systemName: "house.fill").font(.system(size: 10, weight: .bold)).foregroundColor(RadioTheme.vfdAmber)
                    }
                    .help("Eigener Standort \(home.locator)")
                    .position(x: pt.x, y: pt.y)
                }
                ForEach(content.markers) { m in
                    let pt = p.point(m.coordinate)
                    if pt.x > -40, pt.y > -40, pt.x < proxy.size.width + 40, pt.y < proxy.size.height + 40 {
                        MarkerBadge(marker: m, selected: m.id == selection, span: p.spanDegrees)
                            .overlay(alignment: .top) {
                                if showTitles {
                                    Text(m.title)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .shadow(color: .black, radius: 1.5)
                                        .fixedSize()
                                        .offset(y: 22)
                                }
                            }
                            .onTapGesture { selection = m.id }
                            .position(x: pt.x, y: pt.y)
                    }
                }
                zoomButtons
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            Button { camera.zoomBy(1, at: nil) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 24) }
                .buttonStyle(.plain)
                .help("Hineinzoomen")
            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 26, height: 1)
            Button { camera.zoomBy(-1, at: nil) } label: { Image(systemName: "minus").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 24) }
                .buttonStyle(.plain)
                .help("Herauszoomen")
        }
        .foregroundColor(.white)
        .background(RadioTheme.bgDeep.opacity(0.85))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .cornerRadius(5)
        .padding(10)
    }

    private struct TrackDot { var point: GeoPoint; var first: Bool; var tone: MapTone }

    /// Gewählter Punkt: jede empfangene Position als Markierung, der Anfang des Wegs weiß
    private var selectedTrackDots: [TrackDot] {
        guard showTracks, let sel = selected, sel.track.count > 1 else { return [] }
        return sel.track.dropLast().enumerated().map { TrackDot(point: $1, first: $0 == 0, tone: sel.tone) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ButtonGrid {
                    Button("ALLE") { fitted = false; fit() }
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
                }
                Picker("", selection: $appearanceRaw) {
                    ForEach(MapAppearance.allCases) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .colorScheme(.dark)
                .padding(2)
                .background(RadioTheme.bgDeep.opacity(0.9))
                .cornerRadius(6)
                .help("Kartendarstellung")
                ButtonGrid {
                    Button { dayMode.toggle() } label: {
                        Label(dayMode ? "TAG" : "NACHT", systemImage: dayMode ? "sun.max" : "moon")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: dayMode))
                    .help("Karte in der Tagesdarstellung (hell) oder Nachtdarstellung (dunkel) zeigen")
                }
                ButtonGrid {
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
                }
                Text(content.markers.count == 1 ? String(localized: "1 Punkt") : String(format: String(localized: "%lld Punkte"), content.markers.count))
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
                Text(LocalizedStringKey(note))
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
    private func flash(_ text: String) {
        snapshotMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if snapshotMessage == text { snapshotMessage = nil }
        }
    }

    /// Sichtbaren Ausschnitt als PNG ablegen und im Dateimanager zeigen
    private func saveImage() {
        let size = camera.size
        guard size.width > 50, size.height > 50 else { flash("Karte noch nicht bereit"); return }
        let projection = camera.projection, content = self.content, layers = self.layers, dim = appearance == .standard ? 0 : (dayMode ? 0 : 0.28)
        let tracks = showTracks, selection = self.selection, title = legend
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Digidec/Maps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(snapshotName)-\(stamp.string(from: Date())).png")
        let store = tiles
        let ok = renderPNG(size: size, to: url.path) { g in
            OSMDrawing.drawTiles(&g, size: size, projection: projection, layers: layers, store: store, dim: dim)
            OSMDrawing.drawOverlays(&g, projection: projection, content: content, showTracks: tracks, selection: selection)
            OSMDrawing.drawScale(&g, projection: projection, origin: CGPoint(x: 12, y: size.height - 28))
            for m in content.markers {
                let pt = projection.point(m.coordinate)
                let color = m.valueLevel.map { MarkerBadge.scale($0) } ?? m.tone.color
                g.fill(Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)), with: .color(color))
                g.stroke(Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)), with: .color(Color.black.opacity(0.7)), lineWidth: 1)
                g.draw(Text(m.valueText ?? m.title).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white), at: CGPoint(x: pt.x, y: pt.y + 14), anchor: .center)
            }
            let note = ([title].compactMap { $0 } + layers.map(\.attribution)).joined(separator: " · ")
            g.draw(Text(note).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(Color.white.opacity(0.85)), at: CGPoint(x: size.width - 8, y: size.height - 10), anchor: .trailing)
        }
        if ok {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            flash("Gespeichert: " + url.lastPathComponent)
        } else {
            flash("Bild konnte nicht gespeichert werden")
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
        fit()
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
    static func region(of track: [GeoPoint]) -> (center: GeoPoint, latSpan: Double, lonSpan: Double)? {
        guard let f = track.first else { return nil }
        var minLat = f.lat, maxLat = f.lat, minLon = f.lon, maxLon = f.lon
        for p in track {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        return (GeoPoint(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2),
                min(max((maxLat - minLat) * 1.8, 0.01), 170), min(max((maxLon - minLon) * 1.8, 0.01), 350))
    }

    /// Ausschnitt auf alle Punkte setzen
    private func fit() {
        // Entwicklungshilfe: DIGIDEC_MAP_VIEW="Breite,Länge,Spanne" (Grad) legt den Ausschnitt fest, z. B. für Schnappschüsse
        if let v = ProcessInfo.processInfo.environment["DIGIDEC_MAP_VIEW"] {
            let n = v.split(separator: ",").compactMap { Double($0) }
            if n.count == 3 {
                camera.setRegion(center: GeoPoint(lat: n[0], lon: n[1]), latSpan: n[2], lonSpan: n[2])
                fitted = true
                return
            }
        }
        guard let r = content.region() else {
            if let h = content.home ?? home.point { camera.setRegion(center: h, latSpan: 8, lonSpan: 12) }
            return
        }
        fitted = !content.markers.isEmpty
        camera.setRegion(center: r.center, latSpan: max(r.latSpan, 0.05), lonSpan: max(r.lonSpan, 0.05))
    }
}
#endif
