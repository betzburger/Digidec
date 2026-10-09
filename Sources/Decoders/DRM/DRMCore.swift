// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// DRM30 (Digital Radio Mondiale, ETSI ES 201 980): OFDM mit vier Robustheitsmodi (A bis D) und sechs Belegungen (4,5 bis 20 kHz).
// Der Aufbau (Zellenbelegung, Piloten, FAC, SDC, MSC) folgt der Norm; die Zahlen stammen aus den Tabellen von Dream (GPL), siehe
// THIRD_PARTY.md. Abtastrate des Empfängers: 48 kHz (alle FFT-Längen sind dann ganzzahlig).

public enum DRMMode: Int, CaseIterable, Sendable {
    case a = 0, b, c, d

    public var letter: String { ["A", "B", "C", "D"][rawValue] }
    /// FFT-Länge bei 48 kHz (Dauer des nutzbaren Teils: 24; 21,33; 14,67; 9,33 ms)
    public var fftSize: Int { [1152, 1024, 704, 448][rawValue] }
    public var guardNumerator: Int { [1, 1, 4, 11][rawValue] }
    public var guardDenominator: Int { [9, 4, 11, 14][rawValue] }
    public var guardSize: Int { fftSize * guardNumerator / guardDenominator }
    public var symbolSize: Int { fftSize + guardSize }
    public var symbolsPerFrame: Int { [15, 15, 20, 24][rawValue] }
    public var symbolsPerSuperframe: Int { 3 * symbolsPerFrame }
    /// Frequenzabstand der Träger in Hz
    public var carrierSpacing: Double { 48_000.0 / Double(fftSize) }
    /// Pilotraster der gestreuten Piloten: Abstand in Frequenz (x), in der Zeit (y) und erster Träger (k₀)
    var scatX: Int { DRMTables.scatConstFor(self)[0] }
    var scatY: Int { DRMTables.scatConstFor(self)[1] }
    var scatK0: Int { DRMTables.scatConstFor(self)[2] }
}

public enum DRMOccupancy: Int, CaseIterable, Sendable {
    case khz4_5 = 0, khz5, khz9, khz10, khz18, khz20

    public var title: String { ["4,5 kHz", "5 kHz", "9 kHz", "10 kHz", "18 kHz", "20 kHz"][rawValue] }
}

extension DRMTables {
    static func scatConstFor(_ m: DRMMode) -> [Int] { [scatConstA, scatConstB, scatConstC, scatConstD][m.rawValue] }
    static func facFor(_ m: DRMMode) -> [Int] { [facA, facB, facC, facD][m.rawValue] }
    static func freqPilotsFor(_ m: DRMMode) -> [Int] { [freqPilotsA, freqPilotsB, freqPilotsC, freqPilotsD][m.rawValue] }
    static func timePilotsFor(_ m: DRMMode) -> [Int] { [timePilotsA, timePilotsB, timePilotsC, timePilotsD][m.rawValue] }
    static func gainFor(_ m: DRMMode, _ o: DRMOccupancy) -> [Int] {
        let t = [gainA, gainB, gainC, gainD][m.rawValue]
        return Array(t[(o.rawValue * 4)..<(o.rawValue * 4 + 4)])
    }
    static func kmin(_ m: DRMMode, _ o: DRMOccupancy) -> Int { kminTable[o.rawValue * 4 + m.rawValue] }
    static func kmax(_ m: DRMMode, _ o: DRMOccupancy) -> Int { kmaxTable[o.rawValue * 4 + m.rawValue] }
}

/// Zellenbelegung eines Überrahmens (drei Rahmen): Art jeder Zelle und Pilotwerte
public struct DRMCellMap: Sendable {
    public static let dc: UInt8 = 1, msc: UInt8 = 2, sdc: UInt8 = 4, fac: UInt8 = 8, timePilot: UInt8 = 16, freqPilot: UInt8 = 32, scatPilot: UInt8 = 64, boosted: UInt8 = 128

    public let mode: DRMMode
    public let occupancy: DRMOccupancy
    public let kmin: Int
    public let kmax: Int
    public var carriers: Int { kmax - kmin + 1 }
    /// [Symbol im Überrahmen][Träger − kmin]
    public private(set) var kind: [UInt8]
    public private(set) var pilotRe: [Float]
    public private(set) var pilotIm: [Float]
    /// Zellen des MSC je Rahmen (N_MUX) und des SDC je Überrahmen
    public private(set) var mscCellsPerFrame = 0
    public private(set) var sdcCellsPerSuperframe = 0
    public private(set) var mscDummyCells = 0
    /// FAC: Zellen eines Rahmens (Symbol im Rahmen, Index im Träger-Feld)
    public private(set) var facCells: [(symbol: Int, index: Int)] = []
    /// SDC: Zellen des Überrahmens in Sendereihenfolge
    public private(set) var sdcCells: [(symbol: Int, index: Int)] = []
    /// MSC: Zellen des Überrahmens in Sendereihenfolge (ohne die Füllzellen am Ende)
    public private(set) var mscCells: [(symbol: Int, index: Int)] = []

    func idx(_ s: Int, _ i: Int) -> Int { s * carriers + i }

    public init(mode: DRMMode, occupancy: DRMOccupancy) {
        self.mode = mode
        self.occupancy = occupancy
        kmin = DRMTables.kmin(mode, occupancy)
        kmax = DRMTables.kmax(mode, occupancy)
        let nCar = kmax - kmin + 1
        let nSym = mode.symbolsPerSuperframe
        let perFrame = mode.symbolsPerFrame
        kind = [UInt8](repeating: 0, count: nSym * nCar)
        pilotRe = [Float](repeating: 0, count: nSym * nCar)
        pilotIm = [Float](repeating: 0, count: nSym * nCar)

        let fac = DRMTables.facFor(mode)
        let time = DRMTables.timePilotsFor(mode)
        let freq = DRMTables.freqPilotsFor(mode)
        let x = mode.scatX, y = mode.scatY, k0 = mode.scatK0
        let wTab = [DRMTables.scatWA, DRMTables.scatWB, DRMTables.scatWC, DRMTables.scatWD][mode.rawValue]
        let zTab = [DRMTables.scatZA, DRMTables.scatZB, DRMTables.scatZC, DRMTables.scatZD][mode.rawValue]
        let qVal = [DRMTables.scatQA, DRMTables.scatQB, DRMTables.scatQC, DRMTables.scatQD][mode.rawValue]
        let cols = [3, 5, 10, 8][mode.rawValue]
        let gain = DRMTables.gainFor(mode, occupancy)
        let timeCount = time.count / 2
        func mod(_ a: Int, _ b: Int) -> Int { a < 0 ? a % b + b : a % b }
        func polar(_ r: Float, _ phase: Int) -> (Float, Float) {
            let a = 2 * Double.pi * Double(phase) / 1024
            return (r * Float(cos(a)), r * Float(sin(a)))
        }

        var freqCounter = 0, timeCounter = 0
        var facCounter = 0
        for sym in 0..<nSym {
            let frameSym = sym % perFrame
            if frameSym == 0 { facCounter = 0 }
            var scatCounter = Int(Double(kmin - Int(Double(x) / 2 + 0.5) - x * mod(frameSym, y)) / Double(x * y))
            for car in kmin...kmax {
                let i = car - kmin
                let at = sym * nCar + i
                var k = DRMCellMap.msc
                // SDC: die ersten zwei (Modus A, B) oder drei (C, D) Symbole des Überrahmens
                if sym < (mode == .a || mode == .b ? 2 : 3) { k = DRMCellMap.sdc }
                // FAC: Lage nach Tabelle
                if facCounter < 65, fac[facCounter * 2] * nCar + fac[facCounter * 2 + 1] == frameSym * nCar + car {
                    facCounter += 1
                    k = DRMCellMap.fac
                }
                // gestreute Piloten
                if car == Int(Double(x) / 2 + 0.5) + x * mod(frameSym, y) + x * y * scatCounter {
                    scatCounter += 1
                    k = DRMCellMap.scatPilot
                    let n = mod(frameSym, y)
                    let m = Int(Double(frameSym) / Double(y))
                    let p = Int(Double(car - k0 - n * x) / Double(x * y))
                    let phase = mod(4 * zTab[n * cols + m] + p * wTab[n * cols + m] + p * p * (1 + frameSym) * qVal, 1024)
                    let boostedHere = gain.contains(car)
                    let value = polar(boostedHere ? 2 : Float(2).squareRoot(), phase)
                    if boostedHere { k |= DRMCellMap.boosted }
                    pilotRe[at] = value.0; pilotIm[at] = value.1
                }
                // Zeit-Referenzpiloten am Anfang jedes Rahmens
                if frameSym == 0, time[timeCounter * 2] == car {
                    k = (k & DRMCellMap.scatPilot) != 0 ? (k | DRMCellMap.timePilot) : DRMCellMap.timePilot
                    let value = polar(Float(2).squareRoot(), time[timeCounter * 2 + 1])
                    pilotRe[at] = value.0; pilotIm[at] = value.1
                    timeCounter = timeCounter == timeCount - 1 ? 0 : timeCounter + 1
                }
                // Frequenz-Referenzpiloten
                if freq[freqCounter * 2] == car {
                    k = (k & (DRMCellMap.timePilot | DRMCellMap.scatPilot)) != 0 ? (k | DRMCellMap.freqPilot) : DRMCellMap.freqPilot
                    var phase = freq[freqCounter * 2 + 1]
                    if mode == .d, freqCounter != 2, frameSym % 2 == 1 { phase = mod(phase + 512, 1024) }
                    let value = polar(Float(2).squareRoot(), phase)
                    pilotRe[at] = value.0; pilotIm[at] = value.1
                    freqCounter = freqCounter == 2 ? 0 : freqCounter + 1
                }
                // Gleichträger (nicht benutzt) und in Modus A die Nachbarn
                if car == 0 { k = DRMCellMap.dc }
                if mode == .a, car == -1 || car == 1 { k = DRMCellMap.dc }
                kind[at] = k
            }
        }
        // Zellen zählen und in Sendereihenfolge ordnen
        var msc = 0
        for sym in 0..<nSym {
            for i in 0..<nCar {
                let k = kind[sym * nCar + i]
                if k & DRMCellMap.msc != 0 { msc += 1 }
                if k & DRMCellMap.sdc != 0 { sdcCells.append((sym, i)) }
            }
        }
        sdcCellsPerSuperframe = sdcCells.count
        mscCellsPerFrame = msc / 3
        mscDummyCells = msc - mscCellsPerFrame * 3
        for sym in 0..<nSym {
            for i in 0..<nCar where kind[sym * nCar + i] & DRMCellMap.msc != 0 { mscCells.append((sym, i)) }
        }
        mscCells.removeLast(mscDummyCells)
        for c in 0..<65 { facCells.append((fac[c * 2], fac[c * 2 + 1] - kmin)) }
    }

    public func isPilot(_ sym: Int, _ i: Int) -> Bool { kind[sym * carriers + i] & (DRMCellMap.timePilot | DRMCellMap.freqPilot | DRMCellMap.scatPilot) != 0 }
    public func pilot(_ sym: Int, _ i: Int) -> (re: Float, im: Float) { (pilotRe[sym * carriers + i], pilotIm[sym * carriers + i]) }
}

// MARK: - CRC

public enum DRMCRC {
    /// CRC über Bits (MSB zuerst) mit Anfangswert „alle Einsen“ und Ergebnis invertiert; 8 Bit: x⁸ + x⁴ + x³ + x² + 1, 16 Bit: x¹⁶ + x¹² + x⁵ + 1
    public static func compute(_ bits: ArraySlice<UInt8>, degree: Int) -> Int {
        let mask: UInt32 = degree == 8 ? (1 << 2) | (1 << 3) | (1 << 4) : (1 << 5) | (1 << 12)
        let outPos: UInt32 = 1 << UInt32(degree)
        var reg = ~UInt32(0)
        for b in bits {
            reg <<= 1
            if reg & outPos != 0 { reg |= 1 }
            if b & 1 != 0 { reg ^= 1 }
            if reg & 1 != 0 { reg ^= mask }
        }
        return Int((~reg) & (outPos - 1))
    }

    public static func bits(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (count - 1 - $0)) & 1) } }
    public static func value(_ bits: ArraySlice<UInt8>) -> Int { bits.reduce(0) { ($0 << 1) | Int($1 & 1) } }
}
