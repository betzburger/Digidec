// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Gemeinsames

/// Woher die I/Q-Daten für ADS-B kommen
public enum ADSBSourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case hackrf, rtlsdr, sdrplay, sdrconnect, file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hackrf: return "HackRF"
        case .rtlsdr: return "RTL-SDR"
        case .sdrplay: return "SDRplay"
        case .sdrconnect: return "SDRconnect"
        case .file: return "Datei"
        }
    }

    public var detail: String {
        switch self {
        case .hackrf: return "HackRF One über libhackrf (Homebrew). GQRX und andere Programme müssen das Gerät freigeben."
        case .rtlsdr: return "RTL-SDR-Stick über librtlsdr (Homebrew)."
        case .sdrplay: return "SDRplay (RSP1A, RSP1B, RSPdx, RSPduo …) direkt über die SDRplay-API 3.15 (Installer von sdrplay.com/api). SDRconnect und andere Programme müssen das Gerät freigeben."
        case .sdrconnect: return "SDRplay über SDRconnect: dort Server einschalten (WebSocket, Port 5454). Nur nötig, wenn SDRconnect das Gerät behalten soll. Noch nicht am Gerät geprüft."
        case .file: return "Aufnahme: 8-Bit-I/Q (vorzeichenlos, 2 MS/s), wie von dump1090 und rtl_sdr gespeichert."
        }
    }
}

public enum ADSBSourceError: Error, LocalizedError, Sendable {
    case libraryMissing(String)
    case deviceNotFound(String)
    case busy(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .libraryMissing("libsdrplay_api"): return "SDRplay-API nicht gefunden: bitte „Hardware API MacOS“ von https://www.sdrplay.com/api/ installieren"
        case .libraryMissing(let n): return "\(n) nicht gefunden: bitte installieren (brew install \(n == "libhackrf" ? "hackrf" : "librtlsdr"))"
        case .deviceNotFound(let n): return "\(n): kein Gerät gefunden"
        case .busy(let n): return "\(n): Gerät belegt oder Zugriff verweigert (läuft ein anderes Programm, z. B. GQRX?)"
        case .failed(let m): return m
        }
    }
}

/// Eine Quelle für 8-Bit-I/Q-Daten (vorzeichenlos, Mittelpunkt 127) mit 2 Megaabtastungen je Sekunde bei 1090 MHz
public protocol ADSBIQSource: AnyObject, Sendable {
    /// Gerät öffnen und den Datenstrom starten. `onData` kommt von einem Hintergrundfaden und darf nicht blockieren.
    func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws
    func stop()
    var deviceDescription: String { get }
}

/// Einstellungen der Geräte (vom Controller aus den gespeicherten Werten gebildet)
public struct ADSBGainSettings: Equatable, Sendable {
    // HackRF
    public var hackrfLNA = 32
    public var hackrfVGA = 20
    public var hackrfAmp = true
    public var hackrfBias = false
    // RTL-SDR: Verstärkung in dB, nil = Tuner-AGC
    public var rtlGainDB: Double? = 49.6
    public var rtlBias = false
    public var rtlPPM = 0
    // SDRplay: LNA-Stufe gilt für die API und für SDRconnect, der Rest nur für die API
    public var sdrplayLNAState = 0
    /// Tuner des RSPduo: 0 = A, 1 = B
    public var sdrplayTuner = 0
    /// ZF-Verstärkungsminderung in dB (20 … 59; weniger = mehr Verstärkung)
    public var sdrplayIFGainReduction = 40
    public var sdrplayAGC = false
    public var sdrplayBias = false
    public var sdrplayPPM = 0
    // SDRplay über SDRconnect
    public var sdrconnectHost = "127.0.0.1"
    public var sdrconnectPort = 5454

    public init() {}
}

/// dlopen-Hülle: die Gerätebibliotheken werden erst zur Laufzeit gesucht (Homebrew), damit Digidec ohne sie baut und läuft
final class DynamicLibrary: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(names: [String]) {
        for n in names {
            if let h = dlopen(n, RTLD_NOW) {
                handle = h
                return
            }
        }
        return nil
    }

    func symbol<T>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let searchDirectories = ["/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib"]
    static func candidates(_ base: String) -> [String] {
        var out = [base + ".dylib"]
        for d in searchDirectories { out.append("\(d)/\(base).dylib") }
        if let fw = Bundle.main.privateFrameworksPath { out.append("\(fw)/\(base).dylib") }
        return out
    }
}

/// Zeiger auf ein Objekt, das ein C-Rückruf wiederfindet
struct CallbackContext {
    static func pointer(_ object: AnyObject) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(object).toOpaque() }
    static func object<T: AnyObject>(_ p: UnsafeMutableRawPointer?, as: T.Type) -> T? { p.map { Unmanaged<T>.fromOpaque($0).takeUnretainedValue() } }
}

// MARK: - Datei

/// Aufnahme als Quelle: rohe 8-Bit-I/Q-Daten, in Blöcken, auf Wunsch in Echtzeit (2 MS/s = 4 MB/s)
public final class ADSBFileSource: ADSBIQSource, @unchecked Sendable {
    private let url: URL
    private let realtime: Bool
    private let loop: Bool
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public init(url: URL, realtime: Bool = true, loop: Bool = false) {
        self.url = url
        self.realtime = realtime
        self.loop = loop
    }

    public var deviceDescription: String { url.lastPathComponent }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 4 else {
            throw ADSBSourceError.failed("Datei nicht lesbar: \(url.lastPathComponent)")
        }
        lock.withLock { running = true }
        let t = Thread { [self] in
            let block = 65_536                       // 16 ms bei 2 MS/s
            var offset = 0
            let start = Date()
            var sent = 0.0
            while lock.withLock({ running }) {
                if offset >= data.count {
                    if loop { offset = 0 } else { break }
                }
                let end = min(offset + block, data.count)
                data[offset..<end].withUnsafeBytes { raw in
                    onData(UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self).baseAddress, count: end - offset))
                }
                sent += Double(end - offset) / 4_000_000
                offset = end
                if realtime {
                    let wait = sent - Date().timeIntervalSince(start)
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
            }
            lock.withLock { running = false }
            onStop(nil)
        }
        t.name = "adsb-file"
        thread = t
        t.start()
    }

    public func stop() { lock.withLock { running = false } }
}

// MARK: - RTL-SDR

/// RTL-SDR über librtlsdr. Der Strom läuft in `rtlsdr_read_async` auf einem eigenen Faden.
public final class RTLSDRSource: ADSBIQSource, @unchecked Sendable {
    typealias OpenFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, UInt32) -> Int32
    typealias CloseFn = @convention(c) (OpaquePointer?) -> Int32
    typealias CountFn = @convention(c) () -> UInt32
    typealias NameFn = @convention(c) (UInt32) -> UnsafePointer<CChar>?
    typealias SetU32Fn = @convention(c) (OpaquePointer?, UInt32) -> Int32
    typealias SetI32Fn = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias ResetFn = @convention(c) (OpaquePointer?) -> Int32
    typealias GainsFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias ReadCB = @convention(c) (UnsafeMutablePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Void
    typealias ReadAsyncFn = @convention(c) (OpaquePointer?, ReadCB?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Int32

    private let settings: ADSBGainSettings
    private var lib: DynamicLibrary?
    private var device: OpaquePointer?
    private var thread: Thread?
    private var onData: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private(set) public var deviceDescription = "RTL-SDR"
    private var cancel: (@convention(c) (OpaquePointer?) -> Int32)?

    public init(settings: ADSBGainSettings) { self.settings = settings }

    /// Anzahl angeschlossener RTL-SDR (nil: Bibliothek fehlt)
    public static func deviceCount() -> Int? {
        guard let lib = DynamicLibrary(names: DynamicLibrary.candidates("librtlsdr")),
              let count = lib.symbol("rtlsdr_get_device_count", as: CountFn.self) else { return nil }
        return Int(count())
    }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let lib = DynamicLibrary(names: DynamicLibrary.candidates("librtlsdr")),
              let count = lib.symbol("rtlsdr_get_device_count", as: CountFn.self),
              let nameFn = lib.symbol("rtlsdr_get_device_name", as: NameFn.self),
              let open = lib.symbol("rtlsdr_open", as: OpenFn.self),
              let close = lib.symbol("rtlsdr_close", as: CloseFn.self),
              let setFreq = lib.symbol("rtlsdr_set_center_freq", as: SetU32Fn.self),
              let setRate = lib.symbol("rtlsdr_set_sample_rate", as: SetU32Fn.self),
              let setGainMode = lib.symbol("rtlsdr_set_tuner_gain_mode", as: SetI32Fn.self),
              let setGain = lib.symbol("rtlsdr_set_tuner_gain", as: SetI32Fn.self),
              let getGains = lib.symbol("rtlsdr_get_tuner_gains", as: GainsFn.self),
              let reset = lib.symbol("rtlsdr_reset_buffer", as: ResetFn.self),
              let readAsync = lib.symbol("rtlsdr_read_async", as: ReadAsyncFn.self),
              let cancelFn = lib.symbol("rtlsdr_cancel_async", as: (@convention(c) (OpaquePointer?) -> Int32).self) else {
            throw ADSBSourceError.libraryMissing("librtlsdr")
        }
        self.lib = lib
        cancel = cancelFn
        guard count() > 0 else { throw ADSBSourceError.deviceNotFound("RTL-SDR") }
        var dev: OpaquePointer?
        let r = open(&dev, 0)
        guard r == 0, let dev else { throw ADSBSourceError.busy("RTL-SDR") }
        device = dev
        deviceDescription = nameFn(0).map { String(cString: $0) } ?? "RTL-SDR"

        _ = setRate(dev, 2_000_000)
        guard setFreq(dev, 1_090_000_000) == 0 else {
            _ = close(dev)
            device = nil
            throw ADSBSourceError.failed("RTL-SDR: 1090 MHz nicht einstellbar")
        }
        if let ppm = lib.symbol("rtlsdr_set_freq_correction", as: SetI32Fn.self), settings.rtlPPM != 0 { _ = ppm(dev, Int32(settings.rtlPPM)) }
        if let g = settings.rtlGainDB {
            _ = setGainMode(dev, 1)
            // Die nächstliegende Stufe der Tunerverstärkung (Zehntel dB)
            let n = Int(getGains(dev, nil))
            if n > 0 {
                var gains = [Int32](repeating: 0, count: n)
                _ = getGains(dev, &gains)
                let want = Int32(g * 10)
                if let best = gains.min(by: { abs($0 - want) < abs($1 - want) }) { _ = setGain(dev, best) }
            }
        } else {
            _ = setGainMode(dev, 0)
            if let agc = lib.symbol("rtlsdr_set_agc_mode", as: SetI32Fn.self) { _ = agc(dev, 1) }
        }
        if let bias = lib.symbol("rtlsdr_set_bias_tee", as: SetI32Fn.self) { _ = bias(dev, settings.rtlBias ? 1 : 0) }
        _ = reset(dev)

        self.onData = onData
        nonisolated(unsafe) let handle = dev
        let t = Thread { [self] in
            // Blockt, bis `stop()` den Strom abbricht
            let rc = readAsync(handle, { buffer, length, ctx in
                guard let me = CallbackContext.object(ctx, as: RTLSDRSource.self), let buffer else { return }
                me.onData?(UnsafeBufferPointer(start: buffer, count: Int(length)))
            }, CallbackContext.pointer(self), 0, 262_144)
            _ = close(handle)
            device = nil
            onStop(rc == 0 ? nil : "RTL-SDR: Datenstrom abgebrochen (\(rc))")
        }
        t.name = "adsb-rtlsdr"
        thread = t
        t.start()
    }

    public func stop() {
        if let dev = device { _ = cancel?(dev) }
    }
}

// MARK: - HackRF

/// HackRF One über libhackrf. Die Daten kommen vorzeichenbehaftet und werden hier in vorzeichenlose umgesetzt.
public final class HackRFSource: ADSBIQSource, @unchecked Sendable {
    struct Transfer {
        var device: OpaquePointer?
        var buffer: UnsafeMutablePointer<UInt8>?
        var bufferLength: Int32
        var validLength: Int32
        var rxContext: UnsafeMutableRawPointer?
        var txContext: UnsafeMutableRawPointer?
    }
    typealias InitFn = @convention(c) () -> Int32
    typealias OpenFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias DeviceFn = @convention(c) (OpaquePointer?) -> Int32
    typealias SetDoubleFn = @convention(c) (OpaquePointer?, Double) -> Int32
    typealias SetU32Fn = @convention(c) (OpaquePointer?, UInt32) -> Int32
    typealias SetU64Fn = @convention(c) (OpaquePointer?, UInt64) -> Int32
    typealias SetU8Fn = @convention(c) (OpaquePointer?, UInt8) -> Int32
    typealias ExitFn = @convention(c) () -> Int32
    typealias RxCB = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias StartRxFn = @convention(c) (OpaquePointer?, RxCB?, UnsafeMutableRawPointer?) -> Int32
    typealias ErrorNameFn = @convention(c) (Int32) -> UnsafePointer<CChar>?

    private let settings: ADSBGainSettings
    private var lib: DynamicLibrary?
    private var device: OpaquePointer?
    private var onData: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private var convert = [UInt8](repeating: 0, count: 262_144)
    private var stopRx: DeviceFn?
    private var closeFn: DeviceFn?
    private var exitFn: ExitFn?
    private let lock = NSLock()
    private var active = false
    private(set) public var deviceDescription = "HackRF One"

    public init(settings: ADSBGainSettings) { self.settings = settings }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let lib = DynamicLibrary(names: DynamicLibrary.candidates("libhackrf")),
              let initFn = lib.symbol("hackrf_init", as: InitFn.self),
              let open = lib.symbol("hackrf_open", as: OpenFn.self),
              let close = lib.symbol("hackrf_close", as: DeviceFn.self),
              let exit = lib.symbol("hackrf_exit", as: ExitFn.self),
              let setRate = lib.symbol("hackrf_set_sample_rate", as: SetDoubleFn.self),
              let setFilter = lib.symbol("hackrf_set_baseband_filter_bandwidth", as: SetU32Fn.self),
              let setFreq = lib.symbol("hackrf_set_freq", as: SetU64Fn.self),
              let setAmp = lib.symbol("hackrf_set_amp_enable", as: SetU8Fn.self),
              let setLNA = lib.symbol("hackrf_set_lna_gain", as: SetU32Fn.self),
              let setVGA = lib.symbol("hackrf_set_vga_gain", as: SetU32Fn.self),
              let startRx = lib.symbol("hackrf_start_rx", as: StartRxFn.self),
              let stopRxFn = lib.symbol("hackrf_stop_rx", as: DeviceFn.self) else {
            throw ADSBSourceError.libraryMissing("libhackrf")
        }
        self.lib = lib
        stopRx = stopRxFn
        closeFn = close
        exitFn = exit
        guard initFn() == 0 else { throw ADSBSourceError.failed("HackRF: Bibliothek lässt sich nicht starten") }
        var dev: OpaquePointer?
        let r = open(&dev)
        guard r == 0, let dev else {
            _ = exit()
            // -5: nicht gefunden; sonst belegt oder Zugriff verweigert
            if r == -5 { throw ADSBSourceError.deviceNotFound("HackRF") }
            throw ADSBSourceError.busy("HackRF")
        }
        device = dev
        func check(_ rc: Int32, _ what: String) throws {
            guard rc == 0 else {
                _ = close(dev)
                _ = exit()
                device = nil
                throw ADSBSourceError.failed("HackRF: \(what) nicht einstellbar (\(rc))")
            }
        }
        try check(setRate(dev, 2_000_000), "Abtastrate")
        try check(setFilter(dev, 1_750_000), "Filterbandbreite")
        try check(setFreq(dev, 1_090_000_000), "Frequenz 1090 MHz")
        try check(setAmp(dev, settings.hackrfAmp ? 1 : 0), "Vorverstärker")
        try check(setLNA(dev, UInt32(max(0, min(40, settings.hackrfLNA / 8 * 8)))), "LNA-Verstärkung")
        try check(setVGA(dev, UInt32(max(0, min(62, settings.hackrfVGA / 2 * 2)))), "VGA-Verstärkung")
        if let ant = lib.symbol("hackrf_set_antenna_enable", as: SetU8Fn.self) { _ = ant(dev, settings.hackrfBias ? 1 : 0) }

        self.onData = onData
        lock.withLock { active = true }
        // Die Rückrufe von libhackrf kommen von einem fremden Faden und finden diese Quelle über einen Zeiger: festhalten, bis der Strom beendet ist
        let context = Unmanaged.passRetained(self)
        contextToRelease = context
        let rc = startRx(dev, { transfer in
            guard let t = transfer?.assumingMemoryBound(to: Transfer.self).pointee, let me = CallbackContext.object(t.rxContext, as: HackRFSource.self),
                  let src = t.buffer else { return 0 }
            let n = Int(t.validLength)
            guard me.lock.withLock({ me.active }), n > 0 else { return 0 }
            if me.convert.count < n { me.convert = [UInt8](repeating: 0, count: n) }
            // Vorzeichenbehaftet (−128 … 127) in vorzeichenlos (0 … 255) mit gleichem Mittelpunkt
            me.convert.withUnsafeMutableBufferPointer { out in
                for i in 0..<n { out[i] = src[i] ^ 0x80 }
                me.onData?(UnsafeBufferPointer(start: out.baseAddress, count: n))
            }
            return 0
        }, context.toOpaque())
        guard rc == 0 else {
            _ = close(dev)
            _ = exit()
            device = nil
            lock.withLock { active = false }
            contextToRelease = nil
            context.release()
            throw ADSBSourceError.failed("HackRF: Empfang lässt sich nicht starten (\(rc))")
        }
        stopped = onStop
    }

    private var stopped: (@Sendable (String?) -> Void)?
    private var contextToRelease: Unmanaged<HackRFSource>?

    public func stop() {
        let wasActive = lock.withLock { () -> Bool in defer { active = false }; return active }
        guard wasActive, let dev = device else { return }
        _ = stopRx?(dev)
        _ = closeFn?(dev)
        _ = exitFn?()
        device = nil
        // Nach dem Schließen kommen keine Rückrufe mehr; kurz warten und dann den festgehaltenen Zeiger freigeben
        if let c = contextToRelease {
            contextToRelease = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.release() }
        }
        let done = stopped
        stopped = nil
        done?(nil)
    }
}
