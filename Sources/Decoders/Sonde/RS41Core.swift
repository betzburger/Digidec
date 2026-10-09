// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Reed-Solomon RS(255,231) über GF(2⁸)

/// Reed-Solomon-Code der Vaisala RS41: GF(2⁸) mit dem Polynom x⁸+x⁴+x³+x²+1 (0x11D), 24 Prüfbytes, Nullstellen α⁰ … α²³ (t = 12).
/// Das Codewort `cw` hat die Prüfbytes vorn: `cw[0..<24]` sind die niederen Koeffizienten, die Nutzbytes folgen (verkürzter Code, hohe Koeffizienten null).
enum RS41ReedSolomon {
    static let parity = 24
    private static let tables: (exp: [UInt8], log: [Int]) = {
        var e = [UInt8](repeating: 0, count: 512), l = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            e[i] = UInt8(x)
            l[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { e[i] = e[i - 255] }
        return (e, l)
    }()
    private static var exp: [UInt8] { tables.exp }
    private static var log: [Int] { tables.log }

    @inline(__always) private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }
    @inline(__always) private static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 ? 0 : exp[log[Int(a)] + 255 - log[Int(b)]]
    }

    /// Erzeugerpolynom ∏ (x + αⁱ), i = 0…23; Koeffizient i = niederer Grad zuerst
    private static let generator: [UInt8] = {
        var g: [UInt8] = [1]
        for i in 0..<parity {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            let root = exp[i]
            for (j, c) in g.enumerated() {
                next[j + 1] ^= c                    // x · c
                next[j] ^= mul(c, root)             // root · c
            }
            g = next
        }
        return g
    }()

    /// Prüfbytes zu den Nutzbytes (Nutzbyte j ist der Koeffizient von x^(24+j))
    static func encode(message: [UInt8]) -> [UInt8] {
        var rem = [UInt8](repeating: 0, count: parity)
        // Division von x²⁴·m(x) durch g(x): höchster Koeffizient zuerst
        for m in message.reversed() {
            let feedback = m ^ rem[parity - 1]
            for j in stride(from: parity - 1, to: 0, by: -1) {
                rem[j] = rem[j - 1] ^ mul(feedback, generator[j])
            }
            rem[0] = mul(feedback, generator[0])
        }
        return rem
    }

    /// Fehler im Codewort beheben (bis 12 Bytes). Ergebnis: Zahl der behobenen Bytes, `nil` wenn nicht korrigierbar.
    static func decode(_ cw: inout [UInt8]) -> Int? {
        let n = cw.count
        var s = [UInt8](repeating: 0, count: parity)
        var clean = true
        for j in 0..<parity {
            var acc: UInt8 = 0
            for i in 0..<n where cw[i] != 0 { acc ^= exp[(log[Int(cw[i])] + i * j) % 255] }
            s[j] = acc
            if acc != 0 { clean = false }
        }
        if clean { return 0 }
        // Berlekamp-Massey: Fehlerortungspolynom Λ
        var lambda = [UInt8](repeating: 0, count: parity + 1); lambda[0] = 1
        var b = lambda
        var l = 0, m = 1
        var bb: UInt8 = 1
        for r in 0..<parity {
            var d = s[r]
            for i in stride(from: 1, through: l, by: 1) where i <= r { d ^= mul(lambda[i], s[r - i]) }
            if d == 0 {
                m += 1
            } else if 2 * l <= r {
                let t = lambda
                let coef = div(d, bb)
                for i in 0..<(parity + 1 - m) { lambda[i + m] ^= mul(coef, b[i]) }
                l = r + 1 - l
                b = t
                bb = d
                m = 1
            } else {
                let coef = div(d, bb)
                for i in 0..<(parity + 1 - m) { lambda[i + m] ^= mul(coef, b[i]) }
                m += 1
            }
        }
        guard l > 0, l <= parity / 2 else { return nil }
        // Nullstellen: Λ(α^-i) = 0 für die Fehlerstellen i
        var positions: [Int] = []
        for i in 0..<n {
            var acc: UInt8 = 0
            for k in 0...l where lambda[k] != 0 { acc ^= exp[(log[Int(lambda[k])] + (255 - i) * k) % 255] }
            if acc == 0 { positions.append(i) }
        }
        guard positions.count == l else { return nil }
        // Fehlerbewerter Ω = S·Λ mod x²⁴
        var omega = [UInt8](repeating: 0, count: parity)
        for i in 0..<parity {
            var acc: UInt8 = 0
            for k in 0...min(i, l) { acc ^= mul(lambda[k], s[i - k]) }
            omega[i] = acc
        }
        var fixed = cw
        for pos in positions {
            let xinv = (255 - pos) % 255                        // α^-pos
            var om: UInt8 = 0
            for k in 0..<parity where omega[k] != 0 { om ^= exp[(log[Int(omega[k])] + xinv * k) % 255] }
            // Λ'(x): nur ungerade Potenzen bleiben (Charakteristik 2)
            var der: UInt8 = 0
            for k in stride(from: 1, through: l, by: 2) where lambda[k] != 0 { der ^= exp[(log[Int(lambda[k])] + xinv * (k - 1)) % 255] }
            guard der != 0 else { return nil }
            // e = X^(1−fcr) · Ω(X⁻¹) / Λ'(X⁻¹) mit fcr = 0, X = α^pos
            let value = mul(exp[pos % 255], div(om, der))
            fixed[pos] ^= value
        }
        // Gegenprobe: alle Syndrome null
        for j in 0..<parity {
            var acc: UInt8 = 0
            for i in 0..<n where fixed[i] != 0 { acc ^= exp[(log[Int(fixed[i])] + i * j) % 255] }
            if acc != 0 { return nil }
        }
        cw = fixed
        return positions.count
    }
}

// MARK: - Kalibrierdaten

/// Die Sonde schickt in jedem Rahmen ein 16-Byte-Stück ihrer 51 Kalibrierblöcke; mit denen werden aus den Rohmessungen Temperatur, Feuchte und Druck.
struct RS41Calibration {
    var bytes = [UInt8](repeating: 0, count: 51 * 16)
    var have = [Bool](repeating: false, count: 51)

    mutating func store(index: Int, data: ArraySlice<UInt8>) {
        // Block 0x32 enthält den laufenden Abschaltzähler und wird jedes Mal übernommen
        guard index >= 0, index < 51, data.count >= 16, !have[index] || index == 0x32 else { return }
        let start = index * 16
        for (i, b) in data.prefix(16).enumerated() { bytes[start + i] = b }
        have[index] = true
    }

    private func f32(_ pos: Int) -> Double {
        let raw = UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
        return Double(Float(bitPattern: raw))
    }
    private func has(_ indices: Int...) -> Bool { indices.allSatisfy { have[$0] } }

    /// Temperatur des Hauptfühlers (°C): aus den Messungen f, f1, f2 (Zählerstände) und den Kalibrierwerten
    func temperature(f: Double, f1: Double, f2: Double) -> Double? {
        guard has(3, 4, 5, 6), f2 != f1 else { return nil }
        let rf1 = f32(61), rf2 = f32(65)
        guard rf2 != rf1 else { return nil }
        let co = [f32(77), f32(81), f32(85)], cal = [f32(89), f32(93), f32(97)]
        let gain = (f2 - f1) / (rf2 - rf1)
        let rb = (f1 * rf2 - f2 * rf1) / (f2 - f1)
        let rc = f / gain - rb
        let r = rc * cal[0]
        let t = (co[0] + co[1] * r + co[2] * r * r + cal[1]) * (1 + cal[2])
        return t.isFinite && t > -120 && t < 80 ? t : nil
    }

    /// Relative Feuchte (%), empirisch nach dem Zählerstand des Feuchtefühlers und der Temperatur
    func humidity(f: Double, f1: Double, f2: Double, temperature t: Double) -> Double? {
        guard has(7), f2 != f1 else { return nil }
        let calH = f32(117)
        guard calH != 0 else { return nil }
        let a0 = 7.5, a1 = 350.0 / calH
        let fh = (f - f1) / (f2 - f1)
        var rh = 100.0 * (a1 * fh - a0)
        rh += 0.0 - t / 5.5
        if t < -20 { rh *= 1.0 + (-20 - t) / 100.0 }
        if t < -40 { rh *= 1.0 + (-40 - t) / 120.0 }
        return rh.isFinite ? min(max(rh, 0), 100) : nil
    }

    /// Luftdruck (hPa) der Ausführung mit Drucksensor (RS41-SGP)
    func pressure(f: Double, f1: Double, f2: Double, fx: Int) -> Double? {
        guard has(0x21, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A), bytes[0x21F] == UInt8(ascii: "P"), f1 != f2, f1 != f else { return nil }
        // die 25 Beiwerte liegen in einer verschachtelten Reihenfolge
        let offsets = [606, 634, 650, 666, 610, 638, 654, 670, 614, 642, 658, 674, 618, 646, 662, 0, 622, 0, 0, 0, 626, 0, 0, 0, 630]
        var c = [Double](repeating: 0, count: 25)
        // Index j·4+k ← Byte-Position (wie in der Referenz): 0:606 4:610 8:614 12:618 16:622 20:626 24:630 / 1:634 5:638 9:642 13:646 / 2:650 6:654 10:658 14:662 / 3:666 7:670 11:674
        for (idx, off) in offsets.enumerated() where off != 0 { c[idx] = f32(off) }
        let a0 = c[24] / ((f - f1) / (f2 - f1))
        let a1 = Double(fx) * 0.01
        var p = 0.0, a0j = 1.0
        for j in 0..<6 {
            var a1k = 1.0
            for k in 0..<4 {
                p += a0j * a1k * c[j * 4 + k]
                a1k *= a1
            }
            a0j *= a0
        }
        return p.isFinite && p > 0 && p < 1100 ? p : nil
    }

    /// Sendefrequenz in kHz (Block 0)
    var frequencyKHz: Int? {
        guard have[0] else { return nil }
        // Bytes 0x055/0x056 des Rahmens = Block-Bytes 2 und 3 (nach dem Zähler): oberste zwei Bits Viertel, Byte 1 in 40-kHz-Schritten
        let f0 = (Int(bytes[2]) & 0xC0) * 10 / 64
        let f1 = 40 * Int(bytes[3])
        return 400_000 + f1 + f0
    }
}

// MARK: - Rahmen

/// Sucht in einem fehlerfreien (RS-korrigierten, entwürfelten) Rahmen die Blöcke und liest sie
struct RS41FrameParser {
    static let headerBytes: [UInt8] = [0x86, 0x35, 0xF4, 0x40, 0x93, 0xDF, 0x1A, 0x60]       // entwürfelt; gesendet: 10 B6 CA 11 22 96 12 F8
    static let mask: [UInt8] = [
        0x96, 0x83, 0x3E, 0x51, 0xB1, 0x49, 0x08, 0x98, 0x32, 0x05, 0x59, 0x0E, 0xF9, 0x44, 0xC6, 0x26,
        0x21, 0x60, 0xC2, 0xEA, 0x79, 0x5D, 0x6D, 0xA1, 0x54, 0x69, 0x47, 0x0C, 0xDC, 0xE8, 0x5C, 0xF1,
        0xF7, 0x76, 0x82, 0x7F, 0x07, 0x99, 0xA2, 0x2C, 0x93, 0x7C, 0x30, 0x63, 0xF5, 0x10, 0x2E, 0x61,
        0xD0, 0xBC, 0xB4, 0xB6, 0x06, 0xAA, 0xF4, 0x23, 0x78, 0x6E, 0x3B, 0xAE, 0xBF, 0x7B, 0x4C, 0xC1,
    ]
    /// Normale Rahmenlänge (Bytes) und die lange mit Zusatzdaten (Ozon u. ä.)
    static let standardLength = 320
    static let extendedLength = 518
    /// Das Zusatzbyte zwischen Prüfbytes und erstem Block: 0x0F = 320 Bytes, 0xF0 = 518
    static let typeByte = 56
    static let firstBlock = 57

    static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    struct Block { var type: UInt8; var payload: ArraySlice<UInt8>; var valid: Bool }

    /// Alle Blöcke ab dem ersten (Typ, Länge, Nutzdaten, CRC-16 little endian)
    static func blocks(_ f: [UInt8]) -> [Block] {
        var out: [Block] = []
        var pos = firstBlock
        while pos + 4 <= f.count {
            let type = f[pos], len = Int(f[pos + 1])
            let end = pos + 2 + len + 2
            guard end <= f.count else { break }
            let payload = f[(pos + 2)..<(pos + 2 + len)]
            let stored = UInt16(f[pos + 2 + len]) | UInt16(f[pos + 3 + len]) << 8
            out.append(Block(type: type, payload: payload, valid: stored == crc16(payload)))
            pos = end
        }
        return out
    }

    // WGS84
    private static let ea = 6378137.0, eb = 6356752.31424518
    static func geodetic(x: Double, y: Double, z: Double) -> (lat: Double, lon: Double, alt: Double) {
        let a = ea, b = eb
        let e2 = (a * a - b * b) / (a * a), ee2 = (a * a - b * b) / (b * b)
        let lon = atan2(y, x)
        let p = (x * x + y * y).squareRoot()
        let t = atan2(z * a, p * b)
        let lat = atan2(z + ee2 * b * pow(sin(t), 3), p - e2 * a * pow(cos(t), 3))
        let r = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
        return (lat * 180 / .pi, lon * 180 / .pi, p / cos(lat) - r)
    }

    private static func i32(_ p: ArraySlice<UInt8>, _ o: Int) -> Int32 {
        let i = p.startIndex + o
        return Int32(bitPattern: UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24)
    }
    private static func i16(_ p: ArraySlice<UInt8>, _ o: Int) -> Int {
        let i = p.startIndex + o
        return Int(Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8))
    }
    private static func u16(_ p: ArraySlice<UInt8>, _ o: Int) -> Int { Int(p[p.startIndex + o]) | Int(p[p.startIndex + o + 1]) << 8 }
    private static func u24(_ p: ArraySlice<UInt8>, _ o: Int) -> Double {
        let i = p.startIndex + o
        return Double(Int(p[i]) | Int(p[i + 1]) << 8 | Int(p[i + 2]) << 16)
    }

    /// GPS-Beginn 1980-01-06; seit 2017 ist GPS 18 s vor UTC
    static let gpsEpoch = Date(timeIntervalSince1970: 315_964_800)
    static let leapSeconds = 18.0

    /// Position und Geschwindigkeit aus ECEF in Zentimetern und cm/s
    static func applyPosition(_ p: ArraySlice<UInt8>, to t: inout SondeTelemetry) {
        let x = Double(i32(p, 0)) / 100, y = Double(i32(p, 4)) / 100, z = Double(i32(p, 8)) / 100
        let g = geodetic(x: x, y: y, z: z)
        guard g.alt > -1000, g.alt < 80_000, g.lat.isFinite, abs(g.lat) <= 90 else { return }
        t.latitude = g.lat
        t.longitude = g.lon
        t.altitude = g.alt
        let vx = Double(i16(p, 12)) / 100, vy = Double(i16(p, 14)) / 100, vz = Double(i16(p, 16)) / 100
        let phi = g.lat * .pi / 180, lam = g.lon * .pi / 180
        let vn = -vx * sin(phi) * cos(lam) - vy * sin(phi) * sin(lam) + vz * cos(phi)
        let ve = -vx * sin(lam) + vy * cos(lam)
        let vu = vx * cos(phi) * cos(lam) + vy * cos(phi) * sin(lam) + vz * sin(phi)
        t.speed = (vn * vn + ve * ve).squareRoot()
        var dir = atan2(ve, vn) * 180 / .pi
        if dir < 0 { dir += 360 }
        t.heading = dir
        t.climb = vu
    }

    /// Entwürfelter, fehlerkorrigierter Rahmen → Telemetrie (nil, wenn nicht einmal der Statusblock mit Seriennummer gültig ist).
    /// `calibration` wird mit dem 16-Byte-Stück dieses Rahmens ergänzt.
    static func parse(_ f: [UInt8], calibration: inout RS41Calibration, previousSerial: String?) -> SondeTelemetry? {
        var telemetry: SondeTelemetry?
        var meas: [Double] = []
        var pressureAux = 0
        var gpsWeek: Int?, gpsMillis: Int?
        var sgmPosition = false
        var sgmDate: Date?
        for block in blocks(f) where block.valid {
            let p = block.payload
            switch block.type {
            case 0x79 where p.count >= 40:
                let serial = String(decoding: p[(p.startIndex + 2)..<(p.startIndex + 10)].map { $0 >= 0x20 && $0 < 0x7F ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
                if serial != previousSerial { calibration = RS41Calibration() }
                var t = SondeTelemetry(serial: serial, frame: u16(p, 0))
                t.battery = Double(p[p.startIndex + 10]) / 10
                let index = Int(p[p.startIndex + 23])
                calibration.store(index: index, data: p[(p.startIndex + 24)..<(p.startIndex + 40)])
                telemetry = t
            case 0x7A where p.count >= 40:
                meas = (0..<12).map { u24(p, 3 * $0) }
                pressureAux = i16(p, 38)
            case 0x7C where p.count >= 6:
                gpsWeek = u16(p, 0)
                gpsMillis = Int(UInt32(p[p.startIndex + 2]) | UInt32(p[p.startIndex + 3]) << 8 | UInt32(p[p.startIndex + 4]) << 16 | UInt32(p[p.startIndex + 5]) << 24)
            case 0x7B where p.count >= 21:
                if var t = telemetry {
                    applyPosition(p, to: &t)
                    t.satellites = Int(p[p.startIndex + 18])
                    telemetry = t
                }
            case 0x82 where p.count >= 28:          // neuere Firmware (RS41-SGM): Position und UTC im selben Block
                if var t = telemetry {
                    applyPosition(p, to: &t)
                    var c = DateComponents()
                    c.calendar = Calendar(identifier: .gregorian)
                    c.timeZone = TimeZone(identifier: "UTC")
                    c.year = u16(p, 18); c.month = Int(p[p.startIndex + 20]); c.day = Int(p[p.startIndex + 21])
                    c.hour = Int(p[p.startIndex + 22]); c.minute = Int(p[p.startIndex + 23]); c.second = Int(p[p.startIndex + 24])
                    sgmDate = c.date
                    sgmPosition = true
                    telemetry = t
                }
            default:
                break
            }
        }
        guard var t = telemetry else { return nil }
        if let w = gpsWeek, let ms = gpsMillis, w > 0, w < 4000, ms >= 0, ms < 604_800_000 {
            t.time = gpsEpoch.addingTimeInterval(Double(w) * 604_800 + Double(ms) / 1000 - leapSeconds)
        } else if sgmPosition, let d = sgmDate {
            t.time = d
        }
        if meas.count == 12 {
            let temp = calibration.temperature(f: meas[0], f1: meas[1], f2: meas[2])
            t.temperature = temp
            if let temp { t.humidity = calibration.humidity(f: meas[3], f1: meas[4], f2: meas[5], temperature: temp) }
            t.pressure = calibration.pressure(f: meas[9], f1: meas[10], f2: meas[11], fx: pressureAux)
        }
        t.frequencyKHz = calibration.frequencyKHz
        t.model = calibration.modelName
        t.killCountdown = calibration.killCountdown
        return t
    }
}

extension RS41Calibration {
    /// Typbezeichnung aus den Blöcken 0x21 (8 Zeichen) und 0x22 (neuntes Zeichen)
    var modelName: String? {
        guard have[0x21], have[0x22] else { return nil }
        var chars: [UInt8] = []
        // acht Zeichen ab Byte 8 des Blocks 0x21, das neunte steht in Byte 0 des Blocks 0x22
        for i in 0..<8 {
            let b = bytes[0x21 * 16 + 8 + i]
            if b >= 0x20 && b < 0x7F { chars.append(b) } else if b == 0 { break }
        }
        let second = bytes[0x22 * 16 + 0]
        if second >= 0x20 && second < 0x7F { chars.append(second) }
        let s = String(decoding: chars, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// Zähler bis zum Abschalten (Block 0x32, Bytes 0 und 1), Sekunden
    var killCountdown: Int? {
        guard have[0x32] else { return nil }
        let v = Int(bytes[0x32 * 16 + 0]) | Int(bytes[0x32 * 16 + 1]) << 8
        return v == 0xFFFF ? nil : v
    }
}
