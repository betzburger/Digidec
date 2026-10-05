import Foundation

// MARK: - Messwerte als Fläche: Gitter, Isolinien (Isobaren), Hoch- und Tiefpunkte, Farbflächen
//
// Reine Rechnung ohne Oberfläche. Aus verstreuten Stationswerten (Luftdruck, Temperatur) wird ein regelmäßiges Gitter
// berechnet; daraus entstehen Linien gleichen Werts (Marching Squares), Hochs/Tiefs und Farbflächen.
// Die Parameter (Glättung, Reichweite, Schwellen) wurden an synthetischen Druckfeldern mit Rauschen erprobt:
// Hoch und Tief werden gefunden, Zufallsbeulen in dünn besetzten Gebieten nicht.

/// Ein Messwert an einem Ort
public struct FieldSample: Equatable, Sendable {
    public var point: GeoPoint
    public var value: Double

    public init(point: GeoPoint, value: Double) {
        self.point = point
        self.value = value
    }
}

/// Regelmäßiges Gitter in Grad. Zeilen von Süd nach Nord, Spalten von West nach Ost; `NaN` = zu weit von jeder Station
public struct WeatherGrid: Sendable {
    public let latMin: Double
    public let lonMin: Double
    public let dLat: Double
    public let dLon: Double
    public let rows: Int
    public let cols: Int
    public internal(set) var values: [Double]

    public func value(_ r: Int, _ c: Int) -> Double { values[r * cols + c] }
    public func lat(_ r: Int) -> Double { latMin + Double(r) * dLat }
    public func lon(_ c: Int) -> Double { lonMin + Double(c) * dLon }

    /// Kleinster und größter gültiger Wert
    public var range: (min: Double, max: Double)? {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for v in values where v.isFinite {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return lo <= hi ? (min: lo, max: hi) : nil
    }
}

/// Linie gleichen Werts
public struct ContourLine: Equatable, Sendable {
    public var level: Double
    public var points: [GeoPoint]
    public var isClosed: Bool
}

/// Hoch oder Tief
public struct FieldExtremum: Equatable, Sendable {
    public var isHigh: Bool
    public var point: GeoPoint
    public var value: Double
}

public enum WeatherField {
    static let kmPerDegree = 111.195

    // MARK: Gitter

    /// Verstreute Werte auf ein Gitter bringen (gewichteter Mittelwert mit Gauß-Kern, danach einmal geglättet).
    /// - Die Glättungslänge folgt dem mittleren Abstand der Stationen (0,7 ×, 40 … 250 km).
    /// - Gitterpunkte, die weiter als das Dreifache dieses Abstands (250 … 900 km) von jeder Station entfernt sind, bleiben leer:
    ///   außerhalb der Messwerte wird nichts erfunden.
    /// - Weniger als 5 Werte oder mehr als 180° Breite: kein Gitter.
    public static func grid(samples: [FieldSample], maxCells: Int = 48) -> WeatherGrid? {
        let pts = samples.filter { $0.point.isValid && $0.value.isFinite }
        let n = pts.count
        guard n >= 5, maxCells >= 8 else { return nil }
        let lats = pts.map { $0.point.lat }
        let lons = pts.map { $0.point.lon }
        guard let lat0 = lats.min(), let lat1 = lats.max(), let lon0 = lons.min(), let lon1 = lons.max(), lon1 - lon0 <= 180 else { return nil }

        let midLat = (lat0 + lat1) / 2
        let midLon = (lon0 + lon1) / 2
        let cosMid = max(cos(midLat * .pi / 180), 0.1)
        let xs = pts.map { ($0.point.lon - midLon) * cosMid * kmPerDegree }
        let ys = pts.map { ($0.point.lat - midLat) * kmPerDegree }

        // Mittlerer Abstand zur nächsten Nachbarstation
        var sumNearest = 0.0
        for i in 0..<n {
            var best = Double.greatestFiniteMagnitude
            for j in 0..<n where j != i {
                let dx = xs[i] - xs[j], dy = ys[i] - ys[j]
                best = min(best, dx * dx + dy * dy)
            }
            sumNearest += best.squareRoot()
        }
        let meanNearest = max(sumNearest / Double(n), 20)
        let reach = min(max(3 * meanNearest, 250), 900)
        let sigma = min(max(0.7 * meanNearest, 40), 250)

        // Rand um die Stationen
        let margin = max(reach * 0.25 / kmPerDegree, 0.3)
        let la0 = lat0 - margin, la1 = lat1 + margin
        let lo0 = lon0 - margin / cosMid, lo1 = lon1 + margin / cosMid
        let latSpan = la1 - la0, lonSpan = lo1 - lo0
        let cellDeg = max(latSpan, lonSpan * cosMid) / Double(maxCells)
        let rows = min(max(Int((latSpan / cellDeg).rounded()), 6), maxCells) + 1
        let cols = min(max(Int((lonSpan / (cellDeg / cosMid)).rounded()), 6), maxCells) + 1
        let dLat = latSpan / Double(rows - 1)
        let dLon = lonSpan / Double(cols - 1)

        var values = [Double](repeating: .nan, count: rows * cols)
        var d2 = [Double](repeating: 0, count: n)
        let twoSigma2 = 2 * sigma * sigma
        for r in 0..<rows {
            let y = (la0 + Double(r) * dLat - midLat) * kmPerDegree
            for c in 0..<cols {
                let x = (lo0 + Double(c) * dLon - midLon) * cosMid * kmPerDegree
                var dMin2 = Double.greatestFiniteMagnitude
                for i in 0..<n {
                    let dx = x - xs[i], dy = y - ys[i]
                    let d = dx * dx + dy * dy
                    d2[i] = d
                    if d < dMin2 { dMin2 = d }
                }
                if dMin2.squareRoot() > reach { continue }
                var sw = 0.0, sv = 0.0
                for i in 0..<n {
                    // Abstand zur nächsten Station abziehen: kein Unterlauf zu 0 in dünn besetzten Gebieten
                    let w = exp(-(d2[i] - dMin2) / twoSigma2)
                    sw += w
                    sv += w * pts[i].value
                }
                values[r * cols + c] = sv / sw
            }
        }
        let raw = WeatherGrid(latMin: la0, lonMin: lo0, dLat: dLat, dLon: dLon, rows: rows, cols: cols, values: values)
        return smoothed(raw)
    }

    /// Einmal über die 3×3-Nachbarschaft mitteln (der Mittelpunkt zählt doppelt); leere Punkte bleiben leer
    static func smoothed(_ g: WeatherGrid) -> WeatherGrid {
        var out = g
        for r in 0..<g.rows {
            for c in 0..<g.cols {
                let v = g.value(r, c)
                if v.isNaN { continue }
                var sum = v * 2, weight = 2.0
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let rr = r + dr, cc = c + dc
                        guard rr >= 0, rr < g.rows, cc >= 0, cc < g.cols else { continue }
                        let w = g.value(rr, cc)
                        if w.isNaN { continue }
                        sum += w
                        weight += 1
                    }
                }
                out.values[r * g.cols + c] = sum / weight
            }
        }
        return out
    }

    // MARK: Linien gleichen Werts (Marching Squares)

    /// Alle Linien für einen Wert. Zellen mit einem leeren Eckpunkt werden übersprungen, die Linien enden dort.
    public static func contours(of g: WeatherGrid, level: Double) -> [ContourLine] {
        guard g.rows >= 2, g.cols >= 2 else { return [] }
        // Kanten-Nummern: waagerecht (r,c)–(r,c+1) = (r*cols+c)*2, senkrecht (r,c)–(r+1,c) = (r*cols+c)*2+1
        func horizontal(_ r: Int, _ c: Int) -> Int { (r * g.cols + c) * 2 }
        func vertical(_ r: Int, _ c: Int) -> Int { (r * g.cols + c) * 2 + 1 }

        var segments: [(Int, Int)] = []
        for r in 0..<(g.rows - 1) {
            for c in 0..<(g.cols - 1) {
                let a = g.value(r, c), b = g.value(r, c + 1), cc = g.value(r + 1, c + 1), d = g.value(r + 1, c)
                if a.isNaN || b.isNaN || cc.isNaN || d.isNaN { continue }
                var idx = 0
                if a >= level { idx |= 1 }
                if b >= level { idx |= 2 }
                if cc >= level { idx |= 4 }
                if d >= level { idx |= 8 }
                if idx == 0 || idx == 15 { continue }
                // unten, rechts, oben, links
                let e = [horizontal(r, c), vertical(r, c + 1), horizontal(r + 1, c), vertical(r, c)]
                let centerAbove = (a + b + cc + d) / 4 >= level
                let pairs: [(Int, Int)]
                switch idx {
                case 1, 14: pairs = [(3, 0)]
                case 2, 13: pairs = [(0, 1)]
                case 3, 12: pairs = [(3, 1)]
                case 4, 11: pairs = [(1, 2)]
                case 6, 9: pairs = [(0, 2)]
                case 7, 8: pairs = [(3, 2)]
                case 5: pairs = centerAbove ? [(0, 1), (2, 3)] : [(3, 0), (1, 2)]
                default: pairs = centerAbove ? [(3, 0), (1, 2)] : [(0, 1), (2, 3)]    // 10
                }
                for p in pairs { segments.append((e[p.0], e[p.1])) }
            }
        }
        if segments.isEmpty { return [] }

        func point(_ edge: Int) -> GeoPoint {
            let k = edge / 2
            let r = k / g.cols, c = k % g.cols
            if edge % 2 == 0 {
                let a = g.value(r, c), b = g.value(r, c + 1)
                let t = (level - a) / (b - a)
                return GeoPoint(lat: g.lat(r), lon: g.lonMin + (Double(c) + t) * g.dLon)
            }
            let a = g.value(r, c), b = g.value(r + 1, c)
            let t = (level - a) / (b - a)
            return GeoPoint(lat: g.latMin + (Double(r) + t) * g.dLat, lon: g.lon(c))
        }

        // Stücke zu Linien verketten: jede Kante gehört zu höchstens zwei Stücken
        var adjacent: [Int: [Int]] = [:]
        for (i, s) in segments.enumerated() {
            adjacent[s.0, default: []].append(i)
            adjacent[s.1, default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segments.count)

        func walk(from segment: Int, startEdge: Int) -> [Int] {
            used[segment] = true
            let s = segments[segment]
            var current = s.0 == startEdge ? s.1 : s.0
            var chain = [startEdge, current]
            while let next = adjacent[current]?.first(where: { !used[$0] }) {
                used[next] = true
                let t = segments[next]
                current = t.0 == current ? t.1 : t.0
                chain.append(current)
            }
            return chain
        }

        var chains: [[Int]] = []
        // Offene Linien beginnen an einer Kante mit nur einem Stück (Rand des Gitters oder der Daten)
        for key in adjacent.keys.sorted() {
            if let list = adjacent[key], list.count == 1, !used[list[0]] {
                chains.append(walk(from: list[0], startEdge: key))
            }
        }
        // Rest: geschlossene Linien
        for i in 0..<segments.count where !used[i] {
            chains.append(walk(from: i, startEdge: segments[i].0))
        }
        return chains.map { chain in
            let closed = chain.count > 2 && chain.first == chain.last
            return ContourLine(level: level, points: chain.map(point), isClosed: closed)
        }
    }

    /// Linie einmal nach Chaikin abrunden (Ecken des Gitters verschwinden; Anfang und Ende offener Linien bleiben)
    public static func rounded(_ line: ContourLine) -> ContourLine {
        let p = line.points
        guard p.count > 2 else { return line }
        var out: [GeoPoint] = []
        if !line.isClosed { out.append(p[0]) }
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            out.append(GeoPoint(lat: 0.75 * a.lat + 0.25 * b.lat, lon: 0.75 * a.lon + 0.25 * b.lon))
            out.append(GeoPoint(lat: 0.25 * a.lat + 0.75 * b.lat, lon: 0.25 * a.lon + 0.75 * b.lon))
        }
        if line.isClosed, let first = out.first { out.append(first) } else { out.append(p[p.count - 1]) }
        return ContourLine(level: line.level, points: out, isClosed: line.isClosed)
    }

    /// Linien für alle Vielfachen von `step` im Wertebereich des Gitters (z. B. Isobaren alle 4 hPa)
    public static func contourLines(of g: WeatherGrid, step: Double, smooth: Bool = true) -> [ContourLine] {
        guard step > 0, let range = g.range else { return [] }
        var lines: [ContourLine] = []
        var level = (range.min / step).rounded(.up) * step
        var guardCount = 0
        while level <= range.max, guardCount < 200 {
            for line in contours(of: g, level: level) where line.points.count >= 3 {
                lines.append(smooth ? rounded(line) : line)
            }
            level += step
            guardCount += 1
        }
        return lines
    }

    // MARK: Hoch und Tief

    /// Hochs und Tiefs: Gitterpunkt, der im Fenster (±`radius` Zellen, alles gültig) der größte bzw. kleinste ist und sich
    /// um mindestens `prominence` vom Mittel des Fensterrands abhebt. Dicht beieinander liegende gleicher Art: nur das stärkste.
    public static func extrema(of g: WeatherGrid, radius: Int = 5, prominence: Double = 2.0) -> [FieldExtremum] {
        guard g.rows > 2 * radius, g.cols > 2 * radius else { return [] }
        struct Found { var isHigh: Bool; var r: Int; var c: Int; var value: Double; var prominence: Double }
        var found: [Found] = []
        for r in radius..<(g.rows - radius) {
            for c in radius..<(g.cols - radius) {
                let x = g.value(r, c)
                if x.isNaN { continue }
                var complete = true, isMax = true, isMin = true
                var ringSum = 0.0, ringCount = 0
                scan: for dr in -radius...radius {
                    for dc in -radius...radius where !(dr == 0 && dc == 0) {
                        let y = g.value(r + dr, c + dc)
                        if y.isNaN { complete = false; break scan }
                        if y > x { isMax = false }
                        if y < x { isMin = false }
                        if max(abs(dr), abs(dc)) == radius { ringSum += y; ringCount += 1 }
                    }
                }
                guard complete, isMax || isMin, ringCount > 0 else { continue }
                let mean = ringSum / Double(ringCount)
                if isMax, x - mean >= prominence { found.append(Found(isHigh: true, r: r, c: c, value: x, prominence: x - mean)) }
                else if isMin, mean - x >= prominence { found.append(Found(isHigh: false, r: r, c: c, value: x, prominence: mean - x)) }
            }
        }
        found.sort { $0.prominence > $1.prominence }
        var kept: [Found] = []
        for f in found where !kept.contains(where: { $0.isHigh == f.isHigh && max(abs($0.r - f.r), abs($0.c - f.c)) <= radius }) {
            kept.append(f)
        }
        return kept.map { FieldExtremum(isHigh: $0.isHigh, point: GeoPoint(lat: g.lat($0.r), lon: g.lon($0.c)), value: $0.value) }
    }

    // MARK: Farbflächen

    /// Farbflächen: jeder Gitterpunkt ein Rechteck, in Stufen von `bandWidth` eingefärbt, waagerecht benachbarte Rechtecke
    /// derselben Stufe zu einem zusammengefasst (weniger Flächen für die Karte). `level` ordnet dem Wert der Stufenmitte
    /// einen Farbwert 0 … 1 zu.
    public static func patches(of g: WeatherGrid, bandWidth: Double, level: (Double) -> Double) -> [MapPatch] {
        guard bandWidth > 0 else { return [] }
        var out: [MapPatch] = []
        let halfLat = g.dLat / 2, halfLon = g.dLon / 2
        for r in 0..<g.rows {
            var c = 0
            while c < g.cols {
                let v = g.value(r, c)
                if v.isNaN { c += 1; continue }
                let band = Int((v / bandWidth).rounded(.down))
                var end = c
                while end + 1 < g.cols, !g.value(r, end + 1).isNaN, Int((g.value(r, end + 1) / bandWidth).rounded(.down)) == band { end += 1 }
                let south = g.lat(r) - halfLat, north = g.lat(r) + halfLat
                let west = g.lon(c) - halfLon, east = g.lon(end) + halfLon
                out.append(MapPatch(id: "tf-\(r)-\(c)",
                                    corners: [GeoPoint(lat: south, lon: west), GeoPoint(lat: south, lon: east),
                                              GeoPoint(lat: north, lon: east), GeoPoint(lat: north, lon: west)],
                                    level: min(max(level((Double(band) + 0.5) * bandWidth), 0), 1)))
                c = end + 1
            }
        }
        return out
    }
}

// MARK: - Feuchte

public enum WeatherMath {
    /// Relative Luftfeuchte in % aus Temperatur und Taupunkt (Magnus-Formel); nil, wenn der Taupunkt über der Temperatur liegt
    /// (um mehr als 0,5 K: unplausibel) oder ein Wert fehlt
    public static func relativeHumidity(temperatureC: Double?, dewpointC: Double?) -> Double? {
        guard let t = temperatureC, let td = dewpointC, t.isFinite, td.isFinite, td <= t + 0.5, t > -60, t < 60 else { return nil }
        func saturation(_ x: Double) -> Double { exp(17.625 * x / (243.04 + x)) }
        return min(max(100 * saturation(td) / saturation(t), 0), 100)
    }
}
