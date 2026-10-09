// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Umsetzung der 16-Bit-I/Q-Daten der SDRplay-Geräte auf die 8 Bit der Demodulation. Der Spitzenwert wird nachgeführt:
/// schnell nach oben, langsam nach unten, nie unter 2000 (kein Rauschen aufblasen).
struct IQ16Scaler {
    private var peak = 4096.0
    /// Abfall des Spitzenwerts je Block (0,98 = schnell für Burst-Signale; 0,99995 = langsam für Empfänger, die auf die Amplitude achten: AM, SSB)
    var decay = 0.98

    /// Faktor für einen Block mit dem größten Betrag `maxAbs`; der Wert 0 ergibt sich bei 127
    mutating func factor(maxAbs: Int) -> Double {
        peak = max(2000, max(Double(maxAbs), peak * decay))
        return 110.0 / peak
    }

    @inline(__always) static func byte(_ v: Int16, factor: Double) -> UInt8 {
        UInt8(max(0, min(255, (Double(v) * factor + 127).rounded())))
    }
}

/// Abtastrate, Dezimierung, Filter und Notches der SDRplay-Geräte (reine Rechnung, geprüft in den Logiktests).
/// Die API liefert 2 … 10 MS/s; darunter dezimiert sie das 2-MS/s-Signal um 2, 4, 8, 16 oder 32 (bis 62,5 kS/s).
public enum SDRplayPlan {
    /// Wählbare Abtastraten des I/Q-Stroms
    public static let sampleRates = [62_500, 125_000, 250_000, 500_000, 1_000_000, 2_000_000, 2_400_000, 3_000_000, 4_000_000,
                                     4_800_000, 5_000_000, 6_000_000, 8_000_000, 9_600_000, 10_000_000]
    public static let minRate = 62_500, maxRate = 10_000_000
    /// Analoge ZF-Filter der API in kHz
    public static let bandwidthsKHz = [200, 300, 600, 1536, 5000, 6000, 7000, 8000]

    public struct Rate: Equatable, Sendable {
        /// Abtastrate des Geräts (`fsFreq`)
        public var deviceHz: Double
        /// Dezimierung der API (1 = aus, sonst 2, 4, 8, 16, 32)
        public var decimation: Int
        /// Rate der gelieferten Daten
        public var outputHz: Double { deviceHz / Double(decimation) }
    }

    /// Gerätrate und Dezimierung für die gewünschte Ausgaberate (auf die nächste mögliche Rate gerundet)
    public static func rate(for wanted: Int) -> Rate {
        let r = min(max(wanted, minRate), maxRate)
        if r >= 2_000_000 { return Rate(deviceHz: Double(r), decimation: 1) }
        let factors = [2, 4, 8, 16, 32]
        let d = factors.min { abs(2_000_000.0 / Double($0) - Double(r)) < abs(2_000_000.0 / Double($1) - Double(r)) } ?? 2
        return Rate(deviceHz: 2_000_000, decimation: d)
    }

    /// Analoger Filter: Eigene Wahl (nächster erlaubter Wert), sonst nach der Ausgaberate. Ab 2 MS/s der größte Filter, der nicht
    /// breiter ist als die Rate (mindestens 1,536 MHz); darunter der kleinste, der die ganze Rate durchlässt (höchstens 1,536 MHz).
    public static func bandwidthKHz(outputHz: Double, requested: Int) -> Int {
        if requested > 0 { return bandwidthsKHz.min { abs($0 - requested) < abs($1 - requested) } ?? 1536 }
        let khz = outputHz / 1000
        if outputHz >= 2_000_000 { return bandwidthsKHz.last { Double($0) <= khz && $0 >= 1536 } ?? 1536 }
        return bandwidthsKHz.first { Double($0) >= khz && $0 <= 1536 } ?? 1536
    }

    /// Wo die Notch-Schalter in den Strukturen der API liegen (Versätze aus dem Header 3.15, `offsetof`)
    public struct NotchFields: Equatable, Sendable {
        public enum Base: Sendable { case device, channel }
        public var base: Base
        public var rfOffset: Int?
        public var dabOffset: Int?
        /// Flags für `sdrplay_api_Update` (erste Gruppe, zweite Gruppe „Ext1“)
        public var updateRf: (UInt32, UInt32)
        public var updateDab: (UInt32, UInt32)

        public static func == (a: NotchFields, b: NotchFields) -> Bool {
            a.base == b.base && a.rfOffset == b.rfOffset && a.dabOffset == b.dabOffset
                && a.updateRf == b.updateRf && a.updateDab == b.updateDab
        }
    }

    /// Notches je Gerät: RSP1A/1B (RF und DAB, Gerätestruktur), RSP2 (nur RF, Tunerstruktur), RSPduo (RF und DAB, Tuner 1),
    /// RSPdx/dxR2 (RF und DAB, Gerätestruktur); RSP1 hat keine
    public static func notchFields(hwVer: UInt8) -> NotchFields? {
        switch hwVer {
        case 255, 6: return NotchFields(base: .device, rfOffset: 44, dabOffset: 45, updateRf: (0x20, 0), updateDab: (0x40, 0))
        case 2: return NotchFields(base: .channel, rfOffset: 108 + 12, dabOffset: nil, updateRf: (0x400, 0), updateDab: (0, 0))
        case 3: return NotchFields(base: .channel, rfOffset: 124 + 9, dabOffset: 124 + 10, updateRf: (0x4000_0000, 0), updateDab: (0x8000_0000, 0))
        case 4, 7: return NotchFields(base: .device, rfOffset: 52 + 8, dabOffset: 52 + 9, updateRf: (0, 0x8), updateDab: (0, 0x10))
        default: return nil
        }
    }

    /// Schreibt Rate, PPM, Dezimierung, Filter und Notches in die Strukturen der API (`dev` = DevParamsT, `channel` = RxChannelParamsT des Tuners)
    @discardableResult
    static func apply(settings: ADSBGainSettings, hwVer: UInt8, dev: UnsafeMutableRawPointer, channel: UnsafeMutableRawPointer) -> (rate: Rate, bandwidthKHz: Int) {
        typealias L = SDRplayAPISource.Layout
        let rate = Self.rate(for: settings.sampleRateHz)
        let bandwidth = bandwidthKHz(outputHz: rate.outputHz, requested: settings.sdrplayBandwidthKHz)
        dev.storeBytes(of: rate.deviceHz, toByteOffset: L.fsHz, as: Double.self)
        dev.storeBytes(of: Double(settings.sdrplayPPM), toByteOffset: L.ppm, as: Double.self)
        channel.storeBytes(of: UInt8(rate.decimation > 1 ? 1 : 0), toByteOffset: L.decimationEnable, as: UInt8.self)
        channel.storeBytes(of: UInt8(rate.decimation), toByteOffset: L.decimationFactor, as: UInt8.self)
        channel.storeBytes(of: UInt8(0), toByteOffset: L.decimationWide, as: UInt8.self)
        channel.storeBytes(of: Int32(bandwidth), toByteOffset: L.bwType, as: Int32.self)
        if let notch = notchFields(hwVer: hwVer) {
            let base = notch.base == .device ? dev : channel
            if let o = notch.rfOffset { base.storeBytes(of: UInt8(settings.sdrplayRfNotch ? 1 : 0), toByteOffset: o, as: UInt8.self) }
            if let o = notch.dabOffset { base.storeBytes(of: UInt8(settings.sdrplayDabNotch ? 1 : 0), toByteOffset: o, as: UInt8.self) }
        }
        return (rate, bandwidth)
    }

    /// Welche Notches das Gerät hat (für die Anzeige)
    public static func notches(hwVer: UInt8) -> (rf: Bool, dab: Bool) {
        let f = notchFields(hwVer: hwVer)
        return (f?.rfOffset != nil, f?.dabOffset != nil)
    }

    /// Höchste erlaubte LNA-Stufe für das Modell und die Frequenz.
    /// RSP1A / RSP1B / RSPduo: KW/LW (< 60 MHz) 7 Stufen (0…6), L-Band (≥ 1 GHz) 9 Stufen (0…8), sonst 10 Stufen (0…9).
    /// RSP2: KW/LW (< 60 MHz) 5 Stufen (0…4), 420 MHz 6 Stufen (0…5), sonst 9 Stufen (0…8).
    /// RSPdx: je nach Band 19 bis 28 Stufen (0…18 bis 0…27).
    /// RSP1: 4 Stufen (0…3).
    public static func maxLNAState(hwVer: UInt8, frequencyHz: Double) -> Int {
        switch hwVer {
        case 255, 6, 3: // RSP1A, RSP1B, RSPduo
            if frequencyHz < 60_000_000 { return 6 }
            if frequencyHz >= 1_000_000_000 { return 8 }
            return 9
        case 2: // RSP2
            if frequencyHz < 60_000_000 { return 4 }
            if frequencyHz >= 420_000_000 && frequencyHz <= 450_000_000 { return 5 }
            return 8
        case 4, 7: // RSPdx, RSPdx-R2
            if frequencyHz < 12_000_000 { return 18 }
            if frequencyHz < 50_000_000 { return 19 }
            if frequencyHz < 60_000_000 { return 24 }
            if frequencyHz >= 420_000_000 && frequencyHz <= 450_000_000 { return 20 }
            if frequencyHz >= 1_000_000_000 { return 18 }
            return 27
        case 1: // RSP1
            return 3
        default:
            return frequencyHz < 60_000_000 ? 6 : 9
        }
    }

    /// Höchste erlaubte LNA-Stufe vor der Geräteidentifikation (Konservativ nach Frequenz)
    public static func maxLNAState(frequencyHz: Double) -> Int {
        frequencyHz < 60_000_000 ? 6 : 9
    }
}

/// Zustand der Eingangsübersteuerung des SDRplay (Meldungen „Overload detected/corrected“ der API)
public enum SDRplayOverload: Sendable, Equatable {
    /// keine Übersteuerung gemeldet (oder länger her)
    case none
    /// war in den letzten Sekunden übersteuert, jetzt nicht mehr
    case recent
    /// ist gerade übersteuert
    case active

    /// Wie lange eine überstandene Übersteuerung noch angezeigt wird
    public static let holdSeconds = 8.0

    public static func state(active: Bool, lastDetected: Date?, now: Date) -> SDRplayOverload {
        if active { return .active }
        if let last = lastDetected, now.timeIntervalSince(last) < holdSeconds { return .recent }
        return .none
    }
}

/// SDRplay-Geräte (RSP1A, RSP1B, RSP2, RSPdx, RSPduo) direkt über die SDRplay-API 3.15 (`libsdrplay_api`, vom Installer unter
/// https://www.sdrplay.com/api/), ohne SDRconnect. Die Bibliothek wird erst zur Laufzeit geladen (dlopen) und ist nicht Teil von Digidec;
/// ihre Lizenz erlaubt keine Weitergabe. Weil Digidec ohne den Header baut, stehen die Lage der Felder in den Strukturen der API hier als
/// Versätze (gemessen mit dem Header der Version 3.15 unter macOS arm64); andere Versionen der API werden abgelehnt.
/// Der RSPduo läuft im Einzeltuner-Betrieb (Tuner A oder B) mit 2 MS/s bei 1090 MHz.
public final class SDRplayAPISource: SDRTunableSource, @unchecked Sendable {
    typealias Fn0 = @convention(c) () -> Int32
    typealias VersionFn = @convention(c) (UnsafeMutablePointer<Float>?) -> Int32
    typealias GetDevicesFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UInt32) -> Int32
    typealias DeviceFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias ErrorStringFn = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias GetParamsFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias InitFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    typealias UpdateFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UInt32) -> Int32
    typealias GetLastErrorFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias StreamCB = @convention(c) (UnsafeMutablePointer<Int16>?, UnsafeMutablePointer<Int16>?, UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
    typealias EventCB = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    /// Versätze in den Strukturen der API 3.15
    enum Layout {
        static let deviceSize = 96, maxDevices = 16
        static let hwVer = 64, tuner = 68, rspDuoMode = 72, valid = 76, rspDuoSampleFreq = 80, handle = 88, serialLength = 64
        static let paramsDev = 0, paramsA = 8, paramsB = 16
        static let fsHz = 8                          // DevParamsT.fsFreq.fsHz
        static let ppm = 0                           // DevParamsT.ppm
        static let bwType = 0, ifType = 4, loMode = 8, gRdB = 12, lnaState = 16, rfHz = 40   // RxChannelParamsT.tunerParams
        static let agcEnable = 72 + 8, agcSetPoint = 72 + 12                                  // RxChannelParamsT.ctrlParams.agc
        static let duoBiasT = 124                                                              // RxChannelParamsT.rspDuoTunerParams.biasTEnable
        static let decimationEnable = 72 + 2, decimationFactor = 72 + 3, decimationWide = 72 + 4  // RxChannelParamsT.ctrlParams.decimation
        static let callbackSize = 24
        // Werte
        static let bw1536: Int32 = 1536, ifZero: Int32 = 0, loAuto: Int32 = 1
        static let tunerA: Int32 = 1, tunerB: Int32 = 2, duoSingleTuner: Int32 = 1
        static let overloadAck: UInt32 = 0x0400_0000
        static let updateFrf: UInt32 = 0x0002_0000          // sdrplay_api_Update_Tuner_Frf
        static let updateGr: UInt32 = 0x0000_8000           // sdrplay_api_Update_Tuner_Gr
        static let rspDuoID: UInt8 = 3
    }

    static let apiVersion: Float = 3.15
    /// Die API gilt je Prozess: höchstens eine Quelle gleichzeitig (sonst schließt die zweite der ersten die API)
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active = false
    private var holdsAPI = false
    // Übersteuerung (je Prozess höchstens eine Quelle, siehe `active`)
    private static let overloadLock = NSLock()
    nonisolated(unsafe) private static var overloadActive = false
    nonisolated(unsafe) private static var overloadLast: Date?

    /// Übersteuerung des laufenden SDRplay: für die Warnung in den Einstellungen der Module
    public static var overload: SDRplayOverload {
        overloadLock.withLock { SDRplayOverload.state(active: overloadActive, lastDetected: overloadLast, now: Date()) }
    }

    static func noteOverload(detected: Bool, at date: Date = Date()) {
        overloadLock.withLock {
            overloadActive = detected
            if detected { overloadLast = date }
        }
    }

    static func resetOverload() {
        overloadLock.withLock { overloadActive = false; overloadLast = nil }
    }

    private let settings: ADSBGainSettings
    private var lib: DynamicLibrary?
    private let lock = NSLock()
    private var opened = false            // Open() ist erfolgt, Close() steht aus
    private var selected = false          // ein Gerät ist belegt
    private var streaming = false
    private var deviceMemory: UnsafeMutableRawPointer?
    private var callbacks: UnsafeMutableRawPointer?
    private var tuner = Layout.tunerA
    private var onData: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private var onStop: (@Sendable (String?) -> Void)?
    private var out = [UInt8](repeating: 0, count: 16_384)
    private var scaler = IQ16Scaler()
    /// Zeiger auf die Kanalparameter (für das Umstimmen im Betrieb)
    private var channelParams: UnsafeMutableRawPointer?
    private var retainedSelf: Unmanaged<SDRplayAPISource>?
    private(set) public var deviceDescription = "SDRplay"
    /// Anzahl der Übersteuerungsmeldungen des Geräts seit dem Start (für Diagnose)
    private(set) public var overloadCount = 0

    private var close: Fn0?, uninit: DeviceFn?, release: DeviceFn?, lockApi: Fn0?, unlockApi: Fn0?, update: UpdateFn?, getLastError: GetLastErrorFn?

    public init(settings: ADSBGainSettings) {
        self.settings = settings
        scaler.decay = settings.sdrplayFixedScale ? 0.99995 : 0.98
    }

    /// Bibliothek suchen: Standardpfad des Installers, sonst das Verzeichnis der aktuellen Version
    static func candidates() -> [String] {
        var names = ["/usr/local/lib/libsdrplay_api.so", "/usr/local/lib/libsdrplay_api.dylib", "libsdrplay_api.so"]
        let base = "/Library/SDRplayAPI"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for v in versions.sorted(by: >) {
                if let files = try? FileManager.default.contentsOfDirectory(atPath: "\(base)/\(v)/lib") {
                    names += files.filter { $0.hasPrefix("libsdrplay_api") }.map { "\(base)/\(v)/lib/\($0)" }
                }
            }
        }
        return names
    }

    /// Ist die API installiert? (Anzeige in den Einstellungen)
    public static func isInstalled() -> Bool { DynamicLibrary(names: candidates()) != nil }

    private func lastErrorMessage() -> String? {
        guard let getLastError, let mem = deviceMemory, let info = getLastError(mem) else { return nil }
        let msgPtr = info.advanced(by: 516).assumingMemoryBound(to: CChar.self)
        let s = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public func start(onData: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void, onStop: @escaping @Sendable (String?) -> Void) throws {
        guard let lib = DynamicLibrary(names: Self.candidates()),
              let open = lib.symbol("sdrplay_api_Open", as: Fn0.self),
              let close = lib.symbol("sdrplay_api_Close", as: Fn0.self),
              let version = lib.symbol("sdrplay_api_ApiVersion", as: VersionFn.self),
              let lockApi = lib.symbol("sdrplay_api_LockDeviceApi", as: Fn0.self),
              let unlockApi = lib.symbol("sdrplay_api_UnlockDeviceApi", as: Fn0.self),
              let getDevices = lib.symbol("sdrplay_api_GetDevices", as: GetDevicesFn.self),
              let select = lib.symbol("sdrplay_api_SelectDevice", as: DeviceFn.self),
              let release = lib.symbol("sdrplay_api_ReleaseDevice", as: DeviceFn.self),
              let errorString = lib.symbol("sdrplay_api_GetErrorString", as: ErrorStringFn.self),
              let getParams = lib.symbol("sdrplay_api_GetDeviceParams", as: GetParamsFn.self),
              let initFn = lib.symbol("sdrplay_api_Init", as: InitFn.self),
              let uninit = lib.symbol("sdrplay_api_Uninit", as: DeviceFn.self),
              let update = lib.symbol("sdrplay_api_Update", as: UpdateFn.self) else {
            throw ADSBSourceError.libraryMissing("libsdrplay_api")
        }
        let getLastError = lib.symbol("sdrplay_api_GetLastError", as: GetLastErrorFn.self)
        guard Self.activeLock.withLock({ () -> Bool in
            if Self.active { return false }
            Self.active = true
            return true
        }) else { throw ADSBSourceError.busy("SDRplay") }
        holdsAPI = true
        Self.resetOverload()
        self.lib = lib
        self.close = close
        self.uninit = uninit
        self.release = release
        self.lockApi = lockApi
        self.unlockApi = unlockApi
        self.update = update
        self.getLastError = getLastError
        self.onData = onData
        self.onStop = onStop

        func text(_ rc: Int32) -> String { errorString(rc).map { String(cString: $0) } ?? "Fehler \(rc)" }
        func fail(_ message: String) -> ADSBSourceError {
            let detail = lastErrorMessage()
            teardown()
            if let detail, !detail.isEmpty, !message.contains(detail) {
                return .failed("\(message) (\(detail))")
            }
            return .failed(message)
        }

        let rcOpen = open()
        guard rcOpen == 0 else {
            if rcOpen == 14 { teardown(); throw ADSBSourceError.failed("SDRplay: Der Dienst sdrplay_apiService antwortet nicht. Neu starten mit: sudo launchctl kickstart -k system/com.sdrplay.service") }
            teardown()
            throw ADSBSourceError.failed("SDRplay: API lässt sich nicht öffnen (\(text(rcOpen)))")
        }
        lock.withLock { opened = true }
        var v: Float = 0
        _ = version(&v)
        guard abs(v - Self.apiVersion) < 0.005 else {
            throw fail("SDRplay: gefunden ist API \(String(format: "%.2f", v)), Digidec braucht \(String(format: "%.2f", Self.apiVersion)) (Installer unter sdrplay.com/api)")
        }

        // Gerät wählen (während der Wahl ist die API gesperrt)
        _ = lockApi()
        let list = UnsafeMutableRawPointer.allocate(byteCount: Layout.deviceSize * Layout.maxDevices, alignment: 8)
        list.initializeMemory(as: UInt8.self, repeating: 0, count: Layout.deviceSize * Layout.maxDevices)
        defer { list.deallocate() }
        var count: UInt32 = 0
        let rcList = getDevices(list, &count, UInt32(Layout.maxDevices))
        guard rcList == 0 else {
            _ = unlockApi()
            throw fail("SDRplay: Geräteliste nicht lesbar (\(text(rcList)))")
        }
        var chosen: Int?
        for i in 0..<Int(count) where list.load(fromByteOffset: i * Layout.deviceSize + Layout.valid, as: UInt8.self) != 0 {
            chosen = i
            break
        }
        guard let index = chosen else {
            _ = unlockApi()
            throw fail(count == 0 ? "SDRplay: kein freies Gerät gefunden (angeschlossen? Läuft SDRconnect oder ein anderes Programm, das es belegt? Dort beenden)"
                                  : "SDRplay: Gerät belegt (läuft SDRconnect oder ein anderes Programm? Dort beenden oder trennen)")
        }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: Layout.deviceSize, alignment: 8)
        memcpy(mem, list + index * Layout.deviceSize, Layout.deviceSize)
        deviceMemory = mem
        let hwVer = mem.load(fromByteOffset: Layout.hwVer, as: UInt8.self)
        let isDuo = hwVer == Layout.rspDuoID
        tuner = settings.sdrplayTuner == 1 && isDuo ? Layout.tunerB : Layout.tunerA
        mem.storeBytes(of: tuner, toByteOffset: Layout.tuner, as: Int32.self)
        if isDuo {
            mem.storeBytes(of: Layout.duoSingleTuner, toByteOffset: Layout.rspDuoMode, as: Int32.self)
            mem.storeBytes(of: 0.0, toByteOffset: Layout.rspDuoSampleFreq, as: Double.self)
        }
        let rcSelect = select(mem)
        _ = unlockApi()
        guard rcSelect == 0 else {
            throw fail(rcSelect == 1 || rcSelect == 17 ? "SDRplay: Gerät belegt (läuft SDRconnect oder ein anderes Programm?) (\(text(rcSelect)))"
                                                       : "SDRplay: Gerät lässt sich nicht öffnen (\(text(rcSelect)))")
        }
        lock.withLock { selected = true }
        let serial = String(decoding: serialBytes(mem).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        deviceDescription = "\(Self.modelName(hwVer)) \(serial)\(isDuo ? " Tuner \(tuner == Layout.tunerB ? "B" : "A")" : "")"
        let handle = mem.load(fromByteOffset: Layout.handle, as: UnsafeMutableRawPointer?.self)

        // Einstellungen: Frequenz aus den Einstellungen (ADS-B 1090 MHz), 2 MS/s, Nullzwischenfrequenz, Filter 1,536 MHz, Verstärkung
        var paramsPointer: UnsafeMutableRawPointer?
        let rcParams = getParams(handle, &paramsPointer)
        guard rcParams == 0, let params = paramsPointer,
              let dev = params.load(fromByteOffset: Layout.paramsDev, as: UnsafeMutableRawPointer?.self),
              let channel = params.load(fromByteOffset: tuner == Layout.tunerB ? Layout.paramsB : Layout.paramsA, as: UnsafeMutableRawPointer?.self) else {
            throw fail("SDRplay: Geräteparameter nicht lesbar (\(text(rcParams)))")
        }
        // Abtastrate (2 … 10 MS/s direkt, darunter mit Dezimierung der API), analoger Filter und Notch-Filter nach den Einstellungen
        let applied = SDRplayPlan.apply(settings: settings, hwVer: hwVer, dev: dev, channel: channel)
        let bandwidth = Int32(applied.bandwidthKHz)
        let maxLNA = SDRplayPlan.maxLNAState(hwVer: hwVer, frequencyHz: settings.centerFrequencyHz)
        let lnaState = UInt8(max(0, min(maxLNA, settings.sdrplayLNAState)))
        channel.storeBytes(of: Layout.ifZero, toByteOffset: Layout.ifType, as: Int32.self)
        channel.storeBytes(of: Layout.loAuto, toByteOffset: Layout.loMode, as: Int32.self)
        channel.storeBytes(of: Int32(max(20, min(59, settings.sdrplayIFGainReduction))), toByteOffset: Layout.gRdB, as: Int32.self)
        channel.storeBytes(of: lnaState, toByteOffset: Layout.lnaState, as: UInt8.self)
        channel.storeBytes(of: settings.centerFrequencyHz, toByteOffset: Layout.rfHz, as: Double.self)
        channelParams = channel
        // Verstärkungsregelung: aus (feste Stufen) oder 50 Hz mit dem Standardpegel
        channel.storeBytes(of: Int32(settings.sdrplayAGC ? 2 : 0), toByteOffset: Layout.agcEnable, as: Int32.self)
        if isDuo { channel.storeBytes(of: UInt8(settings.sdrplayBias ? 1 : 0), toByteOffset: Layout.duoBiasT, as: UInt8.self) }

        // Rückrufe: der Zeiger auf diese Quelle bleibt festgehalten, bis der Strom beendet ist
        let table = UnsafeMutableRawPointer.allocate(byteCount: Layout.callbackSize, alignment: 8)
        let stream: StreamCB = { xi, xq, _, n, _, ctx in
            guard let me = CallbackContext.object(ctx, as: SDRplayAPISource.self), let xi, let xq else { return }
            me.handle(xi: xi, xq: xq, count: Int(n))
        }
        let event: EventCB = { id, _, params, ctx in
            guard let me = CallbackContext.object(ctx, as: SDRplayAPISource.self) else { return }
            me.handleEvent(id, params: params)
        }
        table.storeBytes(of: unsafeBitCast(stream, to: UInt.self), toByteOffset: 0, as: UInt.self)
        table.storeBytes(of: unsafeBitCast(stream, to: UInt.self), toByteOffset: 8, as: UInt.self)
        table.storeBytes(of: unsafeBitCast(event, to: UInt.self), toByteOffset: 16, as: UInt.self)
        callbacks = table
        let me = Unmanaged.passRetained(self)
        retainedSelf = me
        lock.withLock { streaming = true }
        var rcInit = initFn(handle, table, me.toOpaque())
        // Lehnt die API die Kombination aus Rate und Filter ab, mit dem sicheren Filter von 1,536 MHz noch einmal versuchen
        if rcInit != 0, bandwidth != Layout.bw1536, settings.sdrplayBandwidthKHz == 0 {
            channel.storeBytes(of: Layout.bw1536, toByteOffset: Layout.bwType, as: Int32.self)
            rcInit = initFn(handle, table, me.toOpaque())
        }
        // Schlägt Init immer noch fehl und war LNA > 0, sicherheitshalber mit LNA = 0 versuchen
        if rcInit != 0, lnaState > 0 {
            channel.storeBytes(of: UInt8(0), toByteOffset: Layout.lnaState, as: UInt8.self)
            rcInit = initFn(handle, table, me.toOpaque())
        }
        guard rcInit == 0 else {
            lock.withLock { streaming = false }
            retainedSelf = nil
            me.release()
            throw fail("SDRplay: Empfang lässt sich nicht starten (\(text(rcInit)))")
        }
    }

    /// Mittenfrequenz im Betrieb ändern (Update `Tuner_Frf` der API)
    public func retune(centerHz: Double) -> Bool {
        guard lock.withLock({ streaming }), let channel = channelParams, let update,
              let dev = deviceMemory?.load(fromByteOffset: Layout.handle, as: UnsafeMutableRawPointer?.self), centerHz > 1000, centerHz < 2e9 else { return false }
        channel.storeBytes(of: centerHz, toByteOffset: Layout.rfHz, as: Double.self)
        var updateFlags = Layout.updateFrf
        if let mem = deviceMemory {
            let hwVer = mem.load(fromByteOffset: Layout.hwVer, as: UInt8.self)
            let maxLNA = UInt8(SDRplayPlan.maxLNAState(hwVer: hwVer, frequencyHz: centerHz))
            let currentLNA = channel.load(fromByteOffset: Layout.lnaState, as: UInt8.self)
            if currentLNA > maxLNA {
                channel.storeBytes(of: maxLNA, toByteOffset: Layout.lnaState, as: UInt8.self)
                updateFlags |= Layout.updateGr
            }
        }
        return update(dev, tuner, updateFlags, 0) == 0
    }

    /// Nur für Tests: Empfänger der umgesetzten Daten setzen, ohne ein Gerät zu öffnen
    func setTestHandler(_ h: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) {
        onData = h
        lock.withLock { streaming = true }
    }

    private static func modelName(_ hwVer: UInt8) -> String {
        switch hwVer {
        case 1: return "RSP1"
        case 2: return "RSP2"
        case 3: return "RSPduo"
        case 4: return "RSPdx"
        case 6: return "RSP1B"
        case 7: return "RSPdx-R2"
        case 255: return "RSP1A"
        default: return "SDRplay"
        }
    }

    private func serialBytes(_ mem: UnsafeMutableRawPointer) -> [CChar] {
        var s = [CChar](repeating: 0, count: Layout.serialLength + 1)
        memcpy(&s, mem, Layout.serialLength)
        return s
    }

    // MARK: Rückrufe (fremder Faden)

    func handle(xi: UnsafeMutablePointer<Int16>, xq: UnsafeMutablePointer<Int16>, count: Int) {
        guard count > 0, lock.withLock({ streaming }) else { return }
        if out.count < count * 2 { out = [UInt8](repeating: 0, count: count * 2) }
        var maxAbs = 0
        for i in 0..<count { maxAbs = max(maxAbs, abs(Int(xi[i])), abs(Int(xq[i]))) }
        let factor = scaler.factor(maxAbs: maxAbs)
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<count {
                o[2 * i] = IQ16Scaler.byte(xi[i], factor: factor)
                o[2 * i + 1] = IQ16Scaler.byte(xq[i], factor: factor)
            }
            onData?(UnsafeBufferPointer(start: o.baseAddress, count: count * 2))
        }
    }

    /// Ereignisse des Geräts: Übersteuerung bestätigen, Ausfall melden
    func handleEvent(_ id: Int32, params: UnsafeMutableRawPointer? = nil) {
        switch id {
        case 1:                                                    // Übersteuerung geändert (Meldung muss bestätigt werden)
            overloadCount += 1
            // Parameter: 0 = Übersteuerung erkannt, 1 = behoben (sdrplay_api_PowerOverloadCbEventIdT)
            let detected = (params?.load(as: Int32.self) ?? 0) == 0
            Self.noteOverload(detected: detected)
            if let dev = deviceMemory?.load(fromByteOffset: Layout.handle, as: UnsafeMutableRawPointer?.self) {
                _ = update?(dev, tuner, Layout.overloadAck, 0)
            }
        case 2, 4:                                                 // Gerät entfernt oder ausgefallen
            // Nicht im Rückruf abbauen: das Beenden wartet auf die Rückrufe
            DispatchQueue.global().async { [self] in
                let was = lock.withLock { streaming }
                guard was else { return }
                let done = onStop
                teardown()
                done?(id == 2 ? "SDRplay: Gerät wurde entfernt" : "SDRplay: Gerät ausgefallen")
            }
        default: break
        }
    }

    // MARK: Beenden

    /// Strom anhalten, Gerät freigeben, API schließen (mehrfach aufrufbar)
    private func teardown() {
        let (wasStreaming, wasSelected, wasOpened) = lock.withLock { () -> (Bool, Bool, Bool) in
            defer { streaming = false; selected = false; opened = false }
            return (streaming, selected, opened)
        }
        let handle = deviceMemory?.load(fromByteOffset: Layout.handle, as: UnsafeMutableRawPointer?.self)
        if wasStreaming, let handle { _ = uninit?(handle) }
        if wasSelected, let mem = deviceMemory {
            _ = lockApi?()
            _ = release?(mem)
            _ = unlockApi?()
        }
        if wasOpened { _ = close?() }
        if holdsAPI {
            Self.resetOverload()
            holdsAPI = false
            Self.activeLock.withLock { Self.active = false }
        }
        // Nach Uninit kommen keine Rückrufe mehr: Speicher freigeben (der Zeiger auf die Quelle mit etwas Nachlauf)
        channelParams = nil
        if let mem = deviceMemory { deviceMemory = nil; mem.deallocate() }
        if let table = callbacks { callbacks = nil; table.deallocate() }
        if let r = retainedSelf {
            retainedSelf = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { r.release() }
        }
    }

    public func stop() {
        let was = lock.withLock { opened }
        guard was else { return }
        let done = onStop
        onStop = nil
        teardown()
        done?(nil)
    }
}
