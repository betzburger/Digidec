// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Sendeseite von DRM30 für Tests und Prüfstände: FAC, SDC und MSC zu Zellen, Zellen zu OFDM-Symbolen mit Guard-Intervall. Das Signal liegt
// komplex im Basisband um `centerHz` (Träger 0), die Ausgabe ist für 48 kHz gerechnet.

public struct DRMTransmitConfig: Sendable {
    public var mode = DRMMode.b
    public var occupancy = DRMOccupancy.khz10
    public var mscScheme = DRMScheme.qam16
    public var sdcScheme = DRMScheme.qam16
    public var protectionA = 0
    public var protectionB = 0
    public var longInterleaver = true
    public var serviceID = 0x123456
    public var label = "Digidec"
    public var language = 7
    public var programmeType = 1
    public var audio = DRMAudioParam()
    /// Länge der Teile A und B des einzigen Stroms in Byte (A kann 0 sein)
    public var lengthA = 40
    public var lengthB = 200
    /// Träger 0 liegt bei dieser Frequenz (Vielfaches des Trägerabstands wählen)
    public var centerHz = 12_000.0
    public var amplitude: Float = 0.2
    public init() {}
}

public final class DRMSignalGenerator {
    public let config: DRMTransmitConfig
    public let map: DRMCellMap
    let fft: DRMFFT
    let sdcLayout: DRMBlockLayout
    let mscLayout: DRMBlockLayout
    private var interleaverMemory: [[(Float, Float)]]
    private var interleaverIndex: [Int]
    private let depth: Int
    private let cellInterleaver: [Int]

    public init?(config: DRMTransmitConfig) {
        self.config = config
        map = DRMCellMap(mode: config.mode, occupancy: config.occupancy)
        fft = DRMFFT(size: config.mode.fftSize)
        guard let sl = DRMBlockLayout.sdc(cells: map.sdcCellsPerSuperframe, scheme: config.sdcScheme),
              let ml = DRMBlockLayout.msc(cells: map.mscCellsPerFrame, scheme: config.mscScheme, lengthA: config.lengthA, protectionA: config.protectionA, protectionB: config.protectionB) else { return nil }
        sdcLayout = sl
        mscLayout = ml
        depth = config.longInterleaver ? 5 : 1
        cellInterleaver = DRMCoding.interleaverTable(map.mscCellsPerFrame, 5)
        interleaverMemory = [[(Float, Float)]](repeating: [(Float, Float)](repeating: (0, 0), count: map.mscCellsPerFrame), count: 5)
        interleaverIndex = Array(0..<5)
    }

    public var superframeSamples: Int { config.mode.symbolsPerSuperframe * config.mode.symbolSize }
    /// Nutzbits eines MSC-Rahmens (Teil A, dann Teil B)
    public var mscBitsPerFrame: Int { mscLayout.totalBits }

    // MARK: Teilkanäle

    func facBits(frame: Int) -> [UInt8] {
        var f = DRMFAC()
        f.frameIdentity = frame
        f.occupancy = config.occupancy
        f.longInterleaver = config.longInterleaver
        f.mscMode = config.mscScheme == .qam64 ? 0 : 3
        f.sdcMode = config.sdcScheme == .qam16 ? 0 : 1
        f.audioServices = 1
        f.dataServices = 0
        f.service.id = config.serviceID
        f.service.shortID = 0
        f.service.language = config.language
        f.service.isAudio = true
        f.service.descriptor = config.programmeType
        return f.encoded()
    }

    func sdcBits() -> [UInt8] {
        var entities: [UInt8] = []
        func entity(type: Int, body: [UInt8], lengthBytes: Int) {
            entities += DRMCRC.bits(lengthBytes, 7) + DRMCRC.bits(0, 1) + DRMCRC.bits(type, 4) + body
        }
        // Typ 0: Multiplex mit einem Strom
        entity(type: 0, body: DRMCRC.bits(config.protectionA, 2) + DRMCRC.bits(config.protectionB, 2) + DRMCRC.bits(config.lengthA, 12) + DRMCRC.bits(config.lengthB, 12), lengthBytes: 3)
        // Typ 1: Dienstname
        let label = Array(config.label.utf8.prefix(16))
        entity(type: 1, body: DRMCRC.bits(0, 2) + DRMCRC.bits(0, 2) + label.flatMap { DRMCRC.bits(Int($0), 8) }, lengthBytes: label.count)
        // Typ 9: Audio
        let a = config.audio
        if a.coding == .xheaac {
            let rateCode = [9_600, 12_000, 16_000, 19_200, 24_000, 32_000, 38_400, 48_000].firstIndex(of: a.sampleRate) ?? 7
            entity(type: 9, body: DRMCRC.bits(0, 2) + DRMCRC.bits(a.streamID, 2) + DRMCRC.bits(3, 2) + DRMCRC.bits(0, 1) + DRMCRC.bits(a.mode, 2)
                    + DRMCRC.bits(rateCode, 3) + DRMCRC.bits(a.textMessage ? 1 : 0, 1) + DRMCRC.bits(0, 1) + DRMCRC.bits(a.surroundMode, 3) + DRMCRC.bits(0, 2) + DRMCRC.bits(0, 1)
                    + a.codecConfig.flatMap { DRMCRC.bits(Int($0), 8) }, lengthBytes: 2 + a.codecConfig.count)
        } else {
            let rateCode: Int
            switch a.sampleRate { case 12_000: rateCode = 1; case 24_000: rateCode = 3; default: rateCode = 5 }
            entity(type: 9, body: DRMCRC.bits(0, 2) + DRMCRC.bits(a.streamID, 2) + DRMCRC.bits(a.coding.rawValue, 2) + DRMCRC.bits(a.sbr ? 1 : 0, 1) + DRMCRC.bits(a.mode, 2)
                    + DRMCRC.bits(rateCode, 3) + DRMCRC.bits(a.textMessage ? 1 : 0, 1) + DRMCRC.bits(0, 1) + DRMCRC.bits(0, 3) + DRMCRC.bits(0, 2) + DRMCRC.bits(0, 1), lengthBytes: 2)
        }
        // Typ 8: Datum und Uhrzeit (MJD 61 000 ≈ 2026, 12:34)
        entity(type: 8, body: DRMCRC.bits(61_000, 17) + DRMCRC.bits(12, 5) + DRMCRC.bits(34, 6), lengthBytes: 3)
        let total = sdcLayout.totalBits
        let dataBytes = (total - 20) / 8
        let dataBits = dataBytes * 8
        precondition(entities.count + 7 <= dataBits, "SDC zu klein für die Dateneinheiten")
        var field = entities + [UInt8](repeating: 0, count: dataBits - entities.count)
        let afs = DRMCRC.bits(0, 4)
        let crc = DRMCRC.compute([UInt8](repeating: 0, count: 4)[...] + afs + field, degree: 16)
        field = afs + field + DRMCRC.bits(crc, 16)
        return field + [UInt8](repeating: 0, count: total - field.count)
    }

    // MARK: OFDM

    /// Erzeugt `count` Überrahmen. `payload(frame)` liefert die Nutzbits des MSC-Rahmens (Länge `mscBitsPerFrame`); Nummerierung ab 0 über alle Rahmen.
    /// Rückgabe: komplexes Signal (Real- und Imaginärteil getrennt), Träger 0 bei `centerHz`.
    public func generate(superframes count: Int, payload: (Int) -> [UInt8]) -> (re: [Float], im: [Float]) {
        let mode = config.mode
        let nCar = map.carriers
        let n = mode.fftSize
        let centerHz = config.centerHz
        var sampleIndex = 0
        var outRe: [Float] = [], outIm: [Float] = []
        outRe.reserveCapacity(count * superframeSamples)
        outIm.reserveCapacity(count * superframeSamples)
        let sdcCells = DRMCoding.encodeBlock(bits: sdcBits(), layout: sdcLayout)
        var frameNumber = 0
        for _ in 0..<count {
            // MSC: drei logische Rahmen, zeitlich verschachtelt
            var mscStream: [(Float, Float)] = []
            for _ in 0..<3 {
                let bits = payload(frameNumber)
                precondition(bits.count == mscLayout.totalBits)
                let cells = DRMCoding.encodeBlock(bits: bits, layout: mscLayout)
                mscStream += interleave(cells)
                frameNumber += 1
            }
            var mscPos = 0, sdcPos = 0
            var facPositions: [Int: Int] = [:]
            for (i, c) in map.facCells.enumerated() { facPositions[c.symbol * nCar + c.index] = i }
            var sdcIndex: [Int: Int] = [:]
            for (i, c) in map.sdcCells.enumerated() { sdcIndex[c.symbol * nCar + c.index] = i }
            var mscIndex: [Int: Int] = [:]
            for (i, c) in map.mscCells.enumerated() { mscIndex[c.symbol * nCar + c.index] = i }
            let facCellsPerFrame: [[(Float, Float)]] = (0..<3).map { DRMCoding.encodeBlock(bits: facBits(frame: $0), layout: DRMBlockLayout.fac()) }
            _ = mscPos; _ = sdcPos
            for sym in 0..<mode.symbolsPerSuperframe {
                let frame = sym / mode.symbolsPerFrame
                let frameSym = sym % mode.symbolsPerFrame
                var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
                for i in 0..<nCar {
                    let k = map.kmin + i
                    let kind = map.kind[sym * nCar + i]
                    var v: (Float, Float) = (0, 0)
                    if kind & (DRMCellMap.timePilot | DRMCellMap.freqPilot | DRMCellMap.scatPilot) != 0 {
                        let p = map.pilot(sym, i); v = (p.re, p.im)
                    } else if kind & DRMCellMap.fac != 0, let f = facPositions[frameSym * nCar + i] {
                        v = facCellsPerFrame[frame][f]
                    } else if kind & DRMCellMap.sdc != 0, let s = sdcIndex[sym * nCar + i] {
                        v = sdcCells[s]
                    } else if kind & DRMCellMap.msc != 0, let m = mscIndex[sym * nCar + i], m < mscStream.count {
                        v = mscStream[m]
                    }
                    let bin = ((k % n) + n) % n
                    re[bin] = v.0; im[bin] = v.1
                }
                let t = fft.inverse(re, im)
                let scale = config.amplitude / Float(n).squareRoot() * 0.5
                let guardStart = n - mode.guardSize
                // Die Träger bleiben im Takt der Rahmen; die Mittenfrequenz kommt als stetige Drehung dazu (wie bei einem Sender mit festem Oszillator)
                func emit(_ r: Float, _ i: Float) {
                    let a = 2 * Double.pi * centerHz * Double(sampleIndex) / 48_000
                    let c = Float(cos(a)), sn = Float(sin(a))
                    outRe.append((r * c - i * sn) * scale); outIm.append((r * sn + i * c) * scale)
                    sampleIndex += 1
                }
                for j in 0..<mode.guardSize { emit(t.re[guardStart + j], t.im[guardStart + j]) }
                for j in 0..<n { emit(t.re[j], t.im[j]) }
            }
        }
        return (outRe, outIm)
    }

    /// Zeitverschachtelung der MSC-Zellen (Tiefe 5 oder 1)
    private func interleave(_ cells: [(Float, Float)]) -> [(Float, Float)] {
        let n = cells.count
        for i in 0..<n { interleaverMemory[interleaverIndex[0]][i] = cells[i] }
        var out = [(Float, Float)](repeating: (0, 0), count: n)
        for i in 0..<n { out[i] = interleaverMemory[interleaverIndex[i % depth]][cellInterleaver[i]] }
        for j in 0..<5 { interleaverIndex[j] -= 1; if interleaverIndex[j] < 0 { interleaverIndex[j] = 4 } }
        return out
    }
}
