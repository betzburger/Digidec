// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Testsignale für den RS41-Empfänger (nur für Logiktests und Tools)

/// Baut RS41-Rahmen (Blöcke, CRC, Reed-Solomon, Verwürfelung) und das FSK-Audio dazu, wie es ein FM-Diskriminator liefert.
enum RS41SignalGenerator {
    struct Parameters {
        var serial = "N1234567"
        var frame = 1
        var latitude = 49.79
        var longitude = 9.95
        var altitude = 180.0
        /// Geschwindigkeit nach Norden, Osten, oben (m/s)
        var vNorth = 0.0, vEast = 0.0, vUp = 0.0
        var satellites = 9
        var battery = 2.9
        var gpsWeek = 2380
        var gpsMillis = 300_000_000
        /// Rohzähler der Messungen (12 × 24 Bit) und Druckhilfswert
        var meas = [Double](repeating: 0, count: 12)
        var pressureAux = 0
        /// Kalibrierblock dieses Rahmens (0 … 50) und seine 16 Bytes
        var calibrationIndex = 0
        var calibrationBytes = [UInt8](repeating: 0, count: 16)
    }

    // MARK: Bytes

    private static func crc16(_ data: [UInt8]) -> UInt16 { RS41FrameParser.crc16(data[...]) }

    private static func block(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let crc = crc16(payload)
        return [type, UInt8(payload.count)] + payload + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    private static func le32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
    }
    private static func le16(_ v: Int) -> [UInt8] {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }
    private static func le24(_ v: Double) -> [UInt8] {
        let u = Int(max(0, min(v, 16_777_215)).rounded())
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF)]
    }

    /// WGS84: Breite, Länge (Grad), Höhe (m) → ECEF (m)
    static func ecef(lat: Double, lon: Double, alt: Double) -> (x: Double, y: Double, z: Double) {
        let a = 6378137.0, b = 6356752.31424518
        let e2 = (a * a - b * b) / (a * a)
        let phi = lat * .pi / 180, lam = lon * .pi / 180
        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        return ((n + alt) * cos(phi) * cos(lam), (n + alt) * cos(phi) * sin(lam), (n * (1 - e2) + alt) * sin(phi))
    }

    /// Ein Rahmen mit 320 Bytes, entwürfelt und mit gültigen Prüfbytes (so, wie der Empfänger ihn nach der Fehlerkorrektur sieht)
    static func frame(_ p: Parameters) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: RS41FrameParser.standardLength)
        for (i, b) in RS41FrameParser.headerBytes.enumerated() { f[i] = b }
        f[RS41FrameParser.typeByte] = 0x0F
        var blocks: [UInt8] = []
        // Status: Rahmennummer, Seriennummer, Batterie, Kalibrierblock
        var status = le16(p.frame)
        status += Array(p.serial.utf8.prefix(8)) + [UInt8](repeating: 0x20, count: max(0, 8 - p.serial.utf8.count))
        status.append(UInt8(max(0, min(255, (p.battery * 10).rounded()))))
        status += [UInt8](repeating: 0, count: 12)
        status.append(UInt8(p.calibrationIndex))
        status += p.calibrationBytes.prefix(16) + [UInt8](repeating: 0, count: max(0, 16 - p.calibrationBytes.count))
        blocks += block(0x79, status)
        // Messungen
        var ptu: [UInt8] = []
        for m in p.meas { ptu += le24(m) }
        ptu += [0, 0] + le16(p.pressureAux) + [0, 0]
        blocks += block(0x7A, ptu)
        // GPS-Zeit
        var time = le16(p.gpsWeek) + le32(Int32(truncatingIfNeeded: p.gpsMillis))
        time += [UInt8](repeating: 0xFF, count: 24)
        blocks += block(0x7C, time)
        blocks += block(0x7D, [UInt8](repeating: 0, count: 89))
        // GPS-Position und -Geschwindigkeit
        let e = ecef(lat: p.latitude, lon: p.longitude, alt: p.altitude)
        let phi = p.latitude * .pi / 180, lam = p.longitude * .pi / 180
        let vx = -p.vNorth * sin(phi) * cos(lam) - p.vEast * sin(lam) + p.vUp * cos(phi) * cos(lam)
        let vy = -p.vNorth * sin(phi) * sin(lam) + p.vEast * cos(lam) + p.vUp * cos(phi) * sin(lam)
        let vz = p.vNorth * cos(phi) + p.vUp * sin(phi)
        var pos = le32(Int32((e.x * 100).rounded())) + le32(Int32((e.y * 100).rounded())) + le32(Int32((e.z * 100).rounded()))
        pos += le16(Int((vx * 100).rounded())) + le16(Int((vy * 100).rounded())) + le16(Int((vz * 100).rounded()))
        pos += [UInt8(p.satellites), 10, 15]
        blocks += block(0x7B, pos)
        blocks += block(0x76, [UInt8](repeating: 0, count: 17))
        for (i, b) in blocks.enumerated() where RS41FrameParser.firstBlock + i < f.count { f[RS41FrameParser.firstBlock + i] = b }
        // Prüfbytes: zwei verschränkte Codewörter (gerade und ungerade Bytes ab 56)
        let msgLen = (f.count - RS41FrameParser.typeByte) / 2
        let m1 = (0..<msgLen).map { f[56 + 2 * $0] }, m2 = (0..<msgLen).map { f[57 + 2 * $0] }
        let p1 = RS41ReedSolomon.encode(message: m1), p2 = RS41ReedSolomon.encode(message: m2)
        for i in 0..<24 {
            f[8 + i] = p1[i]
            f[32 + i] = p2[i]
        }
        return f
    }

    /// Das gesendete (verwürfelte) Bytefeld
    static func scrambled(_ f: [UInt8]) -> [UInt8] {
        f.enumerated().map { $0.element ^ RS41FrameParser.mask[$0.offset % RS41FrameParser.mask.count] }
    }

    // MARK: Kalibrierdaten

    /// Kalibriertabelle (51 × 16 Bytes) mit Werten, aus denen sich Temperatur und Sendefrequenz zurückrechnen lassen
    struct Calibration {
        var bytes = [UInt8](repeating: 0, count: 51 * 16)
        static let rf1 = 750.0, rf2 = 1100.0
        static let f1 = 300_000.0, f2 = 500_000.0
        static let co = [-243.911, 0.187654, 8.2e-06]

        init(frequencyKHz: Int = 403_500, model: String = "RS41-SG") {
            func put(_ v: Double, at pos: Int) {
                let u = Float(v).bitPattern
                for k in 0..<4 { bytes[pos + k] = UInt8((u >> UInt32(8 * k)) & 0xFF) }
            }
            // Block 0: Frequenz (Viertel-Schritte à 10 kHz in den obersten Bits von Byte 2, 40-kHz-Schritte in Byte 3)
            let rest = frequencyKHz - 400_000
            bytes[3] = UInt8(rest / 40)
            bytes[2] = UInt8(((rest % 40) / 10) << 6)
            put(Self.rf1, at: 61)
            put(Self.rf2, at: 65)
            for (i, c) in Self.co.enumerated() { put(c, at: 77 + 4 * i) }
            put(1.0, at: 89)                 // calT1: Faktor 1, Versatz 0, Korrektur 0
            put(0.0, at: 93)
            put(0.0, at: 97)
            put(1000, at: 117)               // Feuchte: Bezugskapazität
            let name = Array(model.utf8.prefix(9))
            for (i, c) in name.prefix(8).enumerated() { bytes[0x21 * 16 + 8 + i] = c }
            if name.count > 8 { bytes[0x22 * 16] = name[8] }
            bytes[0x32 * 16] = 0xFF
            bytes[0x32 * 16 + 1] = 0xFF
        }

        func chunk(_ i: Int) -> [UInt8] { Array(bytes[(i * 16)..<(i * 16 + 16)]) }

        /// Zählerstände (f, f1, f2) des Temperaturfühlers für eine Temperatur in °C
        func measurement(temperature t: Double) -> [Double] {
            // t = co0 + co1·R + co2·R² nach R lösen
            let c = Self.co
            let r = (-c[1] + (c[1] * c[1] - 4 * c[2] * (c[0] - t)).squareRoot()) / (2 * c[2])
            let gain = (Self.f2 - Self.f1) / (Self.rf2 - Self.rf1)
            let rb = (Self.f1 * Self.rf2 - Self.f2 * Self.rf1) / (Self.f2 - Self.f1)
            let f = gain * (r + rb)
            return [f, Self.f1, Self.f2]
        }
    }

    // MARK: Audio

    /// FSK-Audio wie vom FM-Diskriminator: NRZ, 4800 Bd, vorn eine Vorbereitungsfolge aus wechselnden Bits, ein Rahmen je Sekunde.
    /// - Parameters:
    ///   - frames: entwürfelte Rahmen (320 Bytes)
    ///   - sampleRate: Abtastrate des Audios
    ///   - amplitude: Spannung bei ±Hub
    ///   - offset: Gleichanteil (Frequenzablage der Sonde)
    ///   - clockError: Abweichung der Bitrate (relativ, z. B. 2e-4)
    static func audio(frames: [[UInt8]], sampleRate: Double = 48_000, amplitude: Float = 0.25, offset: Float = 0, clockError: Double = 0,
                      leadSeconds: Double = 0.3) -> [Float] {
        let spb = sampleRate / 4800 * (1 + clockError)
        var out = [Float](repeating: offset, count: Int(leadSeconds * sampleRate))
        for (k, f) in frames.enumerated() {
            var bits: [Float] = []
            for i in 0..<96 { bits.append(i % 2 == 0 ? -1 : 1) }              // …0101 und eine 1 als letztes Bit
            for byte in scrambled(f) { for b in 0..<8 { bits.append((byte >> UInt8(b)) & 1 == 1 ? 1 : -1) } }
            let start = Int(leadSeconds * sampleRate) + k * Int(sampleRate)
            if out.count < start + Int(Double(bits.count) * spb) + Int(sampleRate) { out += [Float](repeating: offset, count: start + Int(Double(bits.count) * spb) + Int(sampleRate) - out.count) }
            // Rechteckimpulse, danach ein glättendes Filter (Gauß-Näherung: zwei gleitende Mittel über ein Viertel Bit)
            var seg = [Float](repeating: 0, count: Int(Double(bits.count) * spb) + 8)
            for (j, b) in bits.enumerated() {
                let a = Int((Double(j) * spb).rounded()), z = Int((Double(j + 1) * spb).rounded())
                for n in a..<min(z, seg.count) { seg[n] = b }
            }
            let w = max(1, Int(spb / 4))
            for _ in 0..<2 {
                var sm = seg
                for n in 0..<seg.count {
                    var acc: Float = 0
                    for d in 0..<w { acc += seg[max(0, n - d)] }
                    sm[n] = acc / Float(w)
                }
                seg = sm
            }
            // vor und nach dem Rahmen: Rauschen der Gaps ist null (Träger ohne Modulation)
            for n in 0..<seg.count { out[start + n] = offset + amplitude * seg[n] }
        }
        return out
    }

    // MARK: Flug

    /// Zustand einer simulierten Sonde nach `t` Sekunden: Aufstieg mit `climb` m/s, Wind (nach Norden/Osten, m/s) wächst mit der Höhe,
    /// Platzen in `burst` m, danach Sinkflug mit 1/√Luftdichte.
    static func flightState(t: Double, launch: (lat: Double, lon: Double, alt: Double), climb: Double = 5, burst: Double = 28_000,
                            wind: (n: Double, e: Double) = (2, 8)) -> (lat: Double, lon: Double, alt: Double, vN: Double, vE: Double, vU: Double) {
        let tBurst = (burst - launch.alt) / climb
        var alt = launch.alt, lat = launch.lat, lon = launch.lon
        var vU = 0.0
        let dt = 1.0
        var time = 0.0
        var vN = 0.0, vE = 0.0
        var burstDone = false
        while time < t {
            let scale = 1 + (alt - launch.alt) / 8000
            vN = wind.n * scale
            vE = wind.e * scale
            if !burstDone && time >= tBurst { burstDone = true }
            if burstDone {
                vU = -5.5 * exp(alt / 16_800)
                if alt <= launch.alt + 1 { alt = launch.alt; vU = 0; vN = 0; vE = 0 }
            } else {
                vU = climb
            }
            alt += vU * dt
            if alt < launch.alt { alt = launch.alt }
            lat += vN * dt / 111_320
            lon += vE * dt / (111_320 * cos(lat * .pi / 180))
            time += dt
        }
        return (lat, lon, alt, vN, vE, vU)
    }
}
