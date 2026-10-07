// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// DAB (Eureka 147, ETSI EN 300 401), Übertragungsmodus I: Konstanten und Tabellen.
// Die Tabellen sind Zahlenwerte der Norm; sie wurden an welle.io (GPL-2.0-or-later, nur gelesen) und dablin (GPL-3.0, nur gelesen) gegengeprüft
// und mit einem Skript aus deren Quellen übernommen (Vendor/_upstream, nicht im Git), um Abschreibfehler auszuschließen.

public enum DABMode1 {
    public static let sampleRate = 2_048_000
    /// Bandbreite des Ensembles
    public static let bandwidth = 1_536_000
    /// Nutzträger (ohne den Träger bei 0)
    public static let carriers = 1536
    /// FFT-Länge = Länge des Nutzteils eines Symbols in Abtastwerten
    public static let fftSize = 2048
    public static let guardLength = 504
    public static let symbolLength = 2552
    public static let nullLength = 2656
    /// Symbole je Übertragungsrahmen einschließlich Phasenbezugssymbol (ohne Nullsymbol)
    public static let symbolsPerFrame = 76
    public static let frameLength = 196_608
    /// Rahmendauer 96 ms; vier Hauptdienstkanal-Rahmen (CIF) zu 24 ms
    public static let cifsPerFrame = 4
    /// Bits je OFDM-Symbol (DQPSK: zwei je Träger)
    public static let bitsPerSymbol = 3072
    public static let carrierSpacingHz = 1000.0
    /// Kapazitätseinheit (CU) in Bits
    public static let cuBits = 64
    /// Bits eines CIF im Hauptdienstkanal (864 CU)
    public static let cifBits = 864 * 64
}

public enum DABTables {
    /// Punktierungsmuster PI_1 … PI_24 (je 32 Stellen)
    public static let puncture: [[UInt8]] = [
        [1,1,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0],  // PI 1
        [1,1,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,1,0,0,1,0,0,0,1,0,0,0,1,0,0,0],  // PI 2
        [1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0,1,0,0,0,1,0,0,0],  // PI 3
        [1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0],  // PI 4
        [1,1,0,0,1,1,0,0,1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0,1,1,0,0,1,0,0,0],  // PI 5
        [1,1,0,0,1,1,0,0,1,1,0,0,1,0,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,0,0,0],  // PI 6
        [1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,0,0,0],  // PI 7
        [1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0],  // PI 8
        [1,1,1,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0],  // PI 9
        [1,1,1,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,1,0,1,1,0,0,1,1,0,0,1,1,0,0],  // PI 10
        [1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0,1,1,0,0,1,1,0,0],  // PI 11
        [1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0],  // PI 12
        [1,1,1,0,1,1,1,0,1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0,1,1,1,0,1,1,0,0],  // PI 13
        [1,1,1,0,1,1,1,0,1,1,1,0,1,1,0,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,0,0],  // PI 14
        [1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,0,0],  // PI 15
        [1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0],  // PI 16
        [1,1,1,1,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0],  // PI 17
        [1,1,1,1,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,1,1,1,1,0,1,1,1,0,1,1,1,0],  // PI 18
        [1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0,1,1,1,0,1,1,1,0],  // PI 19
        [1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0],  // PI 20
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,0],  // PI 21
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],  // PI 22
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],  // PI 23
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],  // PI 24
    ]

    /// Zusätzliche Punktierung der 24 Endbits (PI_X)
    public static let punctureTail: [UInt8] = [1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0]

    /// Ungleicher Fehlerschutz (UEP): (Datenrate, Schutzstufe, L1, L2, L3, L4, PI1, PI2, PI3, PI4 oder −1)
    public static let uepProfiles: [(bitrate: Int, level: Int, l1: Int, l2: Int, l3: Int, l4: Int, pi1: Int, pi2: Int, pi3: Int, pi4: Int)] = [
        (32, 5, 3, 4, 17, 0, 5, 3, 2, -1),
        (32, 4, 3, 3, 18, 0, 11, 6, 5, -1),
        (32, 3, 3, 4, 14, 3, 15, 9, 6, 8),
        (32, 2, 3, 4, 14, 3, 22, 13, 8, 13),
        (32, 1, 3, 5, 13, 3, 24, 17, 12, 17),
        (48, 5, 4, 3, 26, 3, 5, 4, 2, 3),
        (48, 4, 3, 4, 26, 3, 9, 6, 4, 6),
        (48, 3, 3, 4, 26, 3, 15, 10, 6, 9),
        (48, 2, 3, 4, 26, 3, 24, 14, 8, 15),
        (48, 1, 3, 5, 25, 3, 24, 18, 13, 18),
        (56, 5, 6, 10, 23, 3, 5, 4, 2, 3),
        (56, 4, 6, 10, 23, 3, 9, 6, 4, 5),
        (56, 3, 6, 12, 21, 3, 16, 7, 6, 9),
        (56, 2, 6, 10, 23, 3, 23, 13, 8, 13),
        (64, 5, 6, 9, 31, 2, 5, 3, 2, 3),
        (64, 4, 6, 9, 33, 0, 11, 6, 5, -1),
        (64, 3, 6, 12, 27, 3, 16, 8, 6, 9),
        (64, 2, 6, 10, 29, 3, 23, 13, 8, 13),
        (64, 1, 6, 11, 28, 3, 24, 18, 12, 18),
        (80, 5, 6, 10, 41, 3, 6, 3, 2, 3),
        (80, 4, 6, 10, 41, 3, 11, 6, 5, 6),
        (80, 3, 6, 11, 40, 3, 16, 8, 6, 7),
        (80, 2, 6, 10, 41, 3, 23, 13, 8, 13),
        (80, 1, 6, 10, 41, 3, 24, 7, 12, 18),
        (96, 5, 7, 9, 53, 3, 5, 4, 2, 4),
        (96, 4, 7, 10, 52, 3, 9, 6, 4, 6),
        (96, 3, 6, 12, 51, 3, 16, 9, 6, 10),
        (96, 2, 6, 10, 53, 3, 22, 12, 9, 12),
        (96, 1, 6, 13, 50, 3, 24, 18, 13, 19),
        (112, 5, 14, 17, 50, 3, 5, 4, 2, 5),
        (112, 4, 11, 21, 49, 3, 9, 6, 4, 8),
        (112, 3, 11, 23, 47, 3, 16, 8, 6, 9),
        (112, 2, 11, 21, 49, 3, 23, 12, 9, 14),
        (128, 5, 12, 19, 62, 3, 5, 3, 2, 4),
        (128, 4, 11, 21, 61, 3, 11, 6, 5, 7),
        (128, 3, 11, 22, 60, 3, 16, 9, 6, 10),
        (128, 2, 11, 21, 61, 3, 22, 12, 9, 14),
        (128, 1, 11, 20, 62, 3, 24, 17, 13, 19),
        (160, 5, 11, 19, 87, 3, 5, 4, 2, 4),
        (160, 4, 11, 23, 83, 3, 11, 6, 5, 9),
        (160, 3, 11, 24, 82, 3, 16, 8, 6, 11),
        (160, 2, 11, 21, 85, 3, 22, 11, 9, 13),
        (160, 1, 11, 22, 84, 3, 24, 18, 12, 19),
        (192, 5, 11, 20, 110, 3, 6, 4, 2, 5),
        (192, 4, 11, 22, 108, 3, 10, 6, 4, 9),
        (192, 3, 11, 24, 106, 3, 16, 10, 6, 11),
        (192, 2, 11, 20, 110, 3, 22, 13, 9, 13),
        (192, 1, 11, 21, 109, 3, 24, 20, 13, 24),
        (224, 5, 12, 22, 131, 3, 8, 6, 2, 6),
        (224, 4, 12, 26, 127, 3, 12, 8, 4, 11),
        (224, 3, 11, 20, 134, 3, 16, 10, 7, 9),
        (224, 2, 11, 22, 132, 3, 24, 16, 10, 15),
        (224, 1, 11, 24, 130, 3, 24, 20, 12, 20),
        (256, 5, 11, 24, 154, 3, 6, 5, 2, 5),
        (256, 4, 11, 24, 154, 3, 12, 9, 5, 10),
        (256, 3, 11, 27, 151, 3, 16, 10, 7, 10),
        (256, 2, 11, 22, 156, 3, 24, 14, 10, 13),
        (256, 1, 11, 26, 152, 3, 24, 19, 14, 18),
        (320, 5, 11, 26, 200, 3, 8, 5, 2, 6),
        (320, 4, 11, 25, 201, 3, 13, 9, 5, 10),
        (320, 2, 11, 26, 200, 3, 24, 17, 9, 17),
        (384, 5, 11, 27, 247, 3, 8, 6, 2, 7),
        (384, 3, 11, 24, 250, 3, 16, 9, 7, 10),
        (384, 1, 12, 28, 245, 3, 24, 20, 14, 23),
    ]

    /// Tabelle der Kurzform (FIG 0/1): (Länge in CU, Schutzstufe, Datenrate in kbit/s) nach Tabellenindex
    public static let uepIndex: [(cu: Int, level: Int, bitrate: Int)] = [(16, 5, 32), (21, 4, 32), (24, 3, 32), (29, 2, 32), (35, 1, 32), (24, 5, 48), (29, 4, 48), (35, 3, 48), (42, 2, 48), (52, 1, 48), (29, 5, 56), (35, 4, 56), (42, 3, 56), (52, 2, 56), (32, 5, 64), (42, 4, 64), (48, 3, 64), (58, 2, 64), (70, 1, 64), (40, 5, 80), (52, 4, 80), (58, 3, 80), (70, 2, 80), (84, 1, 80), (48, 5, 96), (58, 4, 96), (70, 3, 96), (84, 2, 96), (104, 1, 96), (58, 5, 112), (70, 4, 112), (84, 3, 112), (104, 2, 112), (64, 5, 128), (84, 4, 128), (96, 3, 128), (116, 2, 128), (140, 1, 128), (80, 5, 160), (104, 4, 160), (116, 3, 160), (140, 2, 160), (168, 1, 160), (96, 5, 192), (116, 4, 192), (140, 3, 192), (168, 2, 192), (208, 1, 192), (116, 5, 224), (140, 4, 224), (168, 3, 224), (208, 2, 224), (232, 1, 224), (128, 5, 256), (168, 4, 256), (192, 3, 256), (232, 2, 256), (280, 1, 256), (160, 5, 320), (208, 4, 320), (280, 2, 320), (192, 5, 384), (280, 3, 384), (416, 1, 384)]

    /// Phasenbezugssymbol: (kmin, kmax, i, n)
    static let phaseBlocks: [(kmin: Int, kmax: Int, i: Int, n: Int)] = [
        (-768, -737, 0, 1),
        (-736, -705, 1, 2),
        (-704, -673, 2, 0),
        (-672, -641, 3, 1),
        (-640, -609, 0, 3),
        (-608, -577, 1, 2),
        (-576, -545, 2, 2),
        (-544, -513, 3, 3),
        (-512, -481, 0, 2),
        (-480, -449, 1, 1),
        (-448, -417, 2, 2),
        (-416, -385, 3, 3),
        (-384, -353, 0, 1),
        (-352, -321, 1, 2),
        (-320, -289, 2, 3),
        (-288, -257, 3, 3),
        (-256, -225, 0, 2),
        (-224, -193, 1, 2),
        (-192, -161, 2, 2),
        (-160, -129, 3, 1),
        (-128, -97, 0, 1),
        (-96, -65, 1, 3),
        (-64, -33, 2, 1),
        (-32, -1, 3, 2),
        (1, 32, 0, 3),
        (33, 64, 3, 1),
        (65, 96, 2, 1),
        (97, 128, 1, 1),
        (129, 160, 0, 2),
        (161, 192, 3, 2),
        (193, 224, 2, 1),
        (225, 256, 1, 0),
        (257, 288, 0, 2),
        (289, 320, 3, 2),
        (321, 352, 2, 3),
        (353, 384, 1, 3),
        (385, 416, 0, 0),
        (417, 448, 3, 2),
        (449, 480, 2, 1),
        (481, 512, 1, 3),
        (513, 544, 0, 3),
        (545, 576, 3, 3),
        (577, 608, 2, 3),
        (609, 640, 1, 0),
        (641, 672, 0, 3),
        (673, 704, 3, 0),
        (705, 736, 2, 1),
        (737, 768, 1, 1)
    ]

    static let h: [[Int]] = [
        [0, 2, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 2, 2, 1, 1, 0, 2, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 2, 2, 1, 1],
        [0, 3, 2, 3, 0, 1, 3, 0, 2, 1, 2, 3, 2, 3, 3, 0, 0, 3, 2, 3, 0, 1, 3, 0, 2, 1, 2, 3, 2, 3, 3, 0],
        [0, 0, 0, 2, 0, 2, 1, 3, 2, 2, 0, 2, 2, 0, 1, 3, 0, 0, 0, 2, 0, 2, 1, 3, 2, 2, 0, 2, 2, 0, 1, 3],
        [0, 1, 2, 1, 0, 3, 3, 2, 2, 3, 2, 1, 2, 1, 3, 2, 0, 1, 2, 1, 0, 3, 3, 2, 2, 3, 2, 1, 2, 1, 3, 2],
    ]

    /// Phase des Trägers k (−768 … −1, 1 … 768) im Phasenbezugssymbol in Vielfachen von π/2
    static func referencePhase(_ k: Int) -> Int {
        for b in phaseBlocks where b.kmin <= k && k <= b.kmax {
            return h[b.i][k - b.kmin] + b.n
        }
        return 0
    }

    /// Sollwerte des Phasenbezugssymbols im Frequenzbereich (FFT-Anordnung: Träger k bei Bin k bzw. 2048 + k)
    public static let referenceSpectrum: (re: [Float], im: [Float]) = {
        var re = [Float](repeating: 0, count: DABMode1.fftSize)
        var im = [Float](repeating: 0, count: DABMode1.fftSize)
        for k in 1...(DABMode1.carriers / 2) {
            let a = Double.pi / 2 * Double(referencePhase(k))
            re[k] = Float(cos(a)); im[k] = Float(sin(a))
            let b = Double.pi / 2 * Double(referencePhase(-k))
            re[DABMode1.fftSize - k] = Float(cos(b)); im[DABMode1.fftSize - k] = Float(sin(b))
        }
        return (re, im)
    }()

    /// Frequenz-Verschachtelung (Abschnitt 14.6): Träger-Bin (−768 … 768) für den i-ten Datenwert
    public static let frequencyInterleaver: [Int] = {
        let tu = DABMode1.fftSize
        var tmp = [Int](repeating: 0, count: tu)
        for i in 1..<tu { tmp[i] = (13 * tmp[i - 1] + 511) % tu }
        var out = [Int]()
        for i in 0..<tu {
            if tmp[i] == tu / 2 { continue }
            if tmp[i] < 256 || tmp[i] > 256 + DABMode1.carriers { continue }
            out.append(tmp[i] - tu / 2)
        }
        return out
    }()

    /// Pseudozufallsfolge der Energieverwischung (x⁹ + x⁵ + 1, Startwert lauter Einsen)
    public static func energyDispersal(count: Int) -> [UInt8] {
        var sr = [UInt8](repeating: 1, count: 9)
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let b = sr[8] ^ sr[4]
            out[i] = b
            for j in stride(from: 8, to: 0, by: -1) { sr[j] = sr[j - 1] }
            sr[0] = b
        }
        return out
    }

    /// Zeitverschachtelung: Verzögerungsfolge der Bits (16 CIF)
    static let interleaveMap: [Int] = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
}
