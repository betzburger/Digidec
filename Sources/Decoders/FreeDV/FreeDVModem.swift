// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Codec2

// FreeDV: digitale Sprache für Kurzwelle (und UKW-FM) von David Rowe VK5DGR. Modem und Sprachcodec (Codec2) kommen aus der
// Bibliothek `Codec2` (LGPL-2.1, Vendor/Codec2); hier die Swift-Hülle: Betriebsarten, Empfang in Blöcken, Statistik, Textkanal.

public enum FreeDVMode: Int32, CaseIterable, Identifiable, Sendable {
    case mode700D = 7
    case mode700E = 13
    case mode1600 = 0
    case mode700C = 6

    public var id: Int32 { rawValue }

    public var title: String {
        switch self {
        case .mode700D: return "700D"
        case .mode700E: return "700E"
        case .mode1600: return "1600"
        case .mode700C: return "700C"
        }
    }

    public var detail: String {
        switch self {
        case .mode700D: return "OFDM, LDPC, 1,0 kHz breit: Standard für schwache Kurzwellen-Signale"
        case .mode700E: return "OFDM, LDPC, 1,5 kHz breit: robuster bei Schwund (Mehrwegeausbreitung)"
        case .mode1600: return "FDMDV, 1,1 kHz breit: erste Betriebsart, noch auf manchen Frequenzen"
        case .mode700C: return "COHPSK, 1,5 kHz breit: ältere Betriebsart für schwache Signale"
        }
    }

    /// Voreinstellung der URL-Schnittstelle (`digidec://decode?mode=freedv&preset=700e`)
    public init?(preset id: String) {
        guard let m = FreeDVMode.allCases.first(where: { $0.title.lowercased() == id.lowercased() }) else { return nil }
        self = m
    }

    /// Belegte Bandbreite im NF für die Anzeige im Wasserfall
    public var bandwidthHz: Double {
        switch self {
        case .mode700D: return 1000
        case .mode700E: return 1500
        case .mode1600: return 1100
        case .mode700C: return 1500
        }
    }
}

public struct FreeDVStatus: Equatable, Sendable {
    public var sync = false
    /// Geschätzter Rauschabstand in dB (3 kHz Bandbreite)
    public var snr = 0.0
    /// Frequenzablage in Hz
    public var frequencyOffset = 0.0
    /// Abweichung der Abtasttakte in ppm
    public var clockOffsetPPM = 0.0
}

/// Ein Modem (Empfang und, für Prüfstände, Senden). Nicht für mehrere Threads zugleich.
public final class FreeDVModem: @unchecked Sendable {
    public let mode: FreeDVMode
    private var handle: OpaquePointer?
    private var input: [Int16] = []
    private var speechBuffer: [Int16]
    private var statsRaw: UnsafeMutableRawPointer
    private var textBox: TextBox

    /// Zeichen des Textkanals (Rufzeichen o. Ä., von der Gegenstation mitgesendet)
    public var onText: ((Character) -> Void)? { get { textBox.handler } set { textBox.handler = newValue } }

    private final class TextBox: @unchecked Sendable {
        var handler: ((Character) -> Void)?
        var transmit: [UInt8] = []
        var transmitIndex = 0
    }

    public init?(mode: FreeDVMode, squelchSNR: Double? = nil) {
        guard let f = freedv_open(mode.rawValue) else { return nil }
        self.mode = mode
        handle = f
        speechBuffer = [Int16](repeating: 0, count: Int(freedv_get_n_max_speech_samples(f)) * 2)
        statsRaw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<MODEM_STATS>.size, alignment: MemoryLayout<MODEM_STATS>.alignment)
        textBox = TextBox()
        if let squelchSNR {
            freedv_set_squelch_en(f, true)
            freedv_set_snr_squelch_thresh(f, Float(squelchSNR))
        } else {
            freedv_set_squelch_en(f, false)
        }
        freedv_set_callback_txt(f, { state, character in
            guard let state else { return }
            let box = Unmanaged<TextBox>.fromOpaque(state).takeUnretainedValue()
            box.handler?(Character(UnicodeScalar(UInt8(bitPattern: character))))
        }, nil, Unmanaged.passUnretained(textBox).toOpaque())
    }

    deinit {
        if let handle { freedv_close(handle) }
        statsRaw.deallocate()
    }

    /// Abtastrate des Modems (8000 Hz für alle HF-Betriebsarten)
    public var modemSampleRate: Int { Int(freedv_get_modem_sample_rate(handle)) }
    public var speechSampleRate: Int { Int(freedv_get_speech_sample_rate(handle)) }
    /// Sprachabtastwerte je Modemrahmen (Senden: Eingabe, Empfang: bis zu dieser Zahl je Aufruf)
    public var speechSamplesPerFrame: Int { Int(freedv_get_n_speech_samples(handle)) }
    public var modemSamplesPerFrame: Int { Int(freedv_get_n_nom_modem_samples(handle)) }
    public var txModemSamplesPerFrame: Int { Int(freedv_get_n_tx_modem_samples(handle)) }

    public var status: FreeDVStatus {
        let p = statsRaw.bindMemory(to: MODEM_STATS.self, capacity: 1)
        freedv_get_modem_extended_stats(handle, p)
        return FreeDVStatus(sync: p.pointee.sync != 0, snr: Double(p.pointee.snr_est), frequencyOffset: Double(p.pointee.foff), clockOffsetPPM: Double(p.pointee.clock_offset))
    }

    // MARK: Empfang

    /// Füttert das Modem mit Abtastwerten (8 kHz, 16 Bit) und liefert die dabei dekodierte Sprache (8 kHz). Das Modem braucht
    /// je Aufruf eine wechselnde Zahl von Abtastwerten (`freedv_nin`); überzählige bleiben bis zum nächsten Aufruf liegen.
    public func receive(_ samples: [Int16]) -> [Int16] {
        input += samples
        var speech: [Int16] = []
        while true {
            let need = Int(freedv_nin(handle))
            guard input.count >= need else { break }
            var block = Array(input[0..<need])
            input.removeFirst(need)
            let produced = speechBuffer.withUnsafeMutableBufferPointer { out in
                block.withUnsafeMutableBufferPointer { inp in Int(freedv_rx(handle, out.baseAddress, inp.baseAddress)) }
            }
            if produced > 0 { speech += speechBuffer[0..<produced] }
        }
        return speech
    }

    public func reset() { input.removeAll() }

    // MARK: Senden (Prüfstände)

    /// Ein Modemrahmen aus `speechSamplesPerFrame` Sprachabtastwerten
    public func transmit(_ speech: [Int16]) -> [Int16] {
        precondition(speech.count == speechSamplesPerFrame)
        var out = [Int16](repeating: 0, count: max(txModemSamplesPerFrame, modemSamplesPerFrame))
        var input = speech
        out.withUnsafeMutableBufferPointer { o in input.withUnsafeMutableBufferPointer { i in freedv_tx(handle, o.baseAddress, i.baseAddress) } }
        return Array(out[0..<modemSamplesPerFrame])      // `freedv_tx` liefert die nominale Rahmenlänge
    }

    /// Text für den Textkanal (Rufzeichen) zum Mitsenden (wiederholt, mit Zeilenende)
    public func setTransmitText(_ text: String) {
        textBox.transmit = Array(text.utf8) + [13]
        textBox.transmitIndex = 0
        freedv_set_callback_txt(handle, { state, character in
            guard let state else { return }
            let box = Unmanaged<TextBox>.fromOpaque(state).takeUnretainedValue()
            box.handler?(Character(UnicodeScalar(UInt8(bitPattern: character))))
        }, { state in
            guard let state else { return 0 }
            let box = Unmanaged<TextBox>.fromOpaque(state).takeUnretainedValue()
            guard !box.transmit.isEmpty else { return 0 }
            defer { box.transmitIndex += 1 }
            return CChar(bitPattern: box.transmit[box.transmitIndex % box.transmit.count])
        }, Unmanaged.passUnretained(textBox).toOpaque())
    }
}
