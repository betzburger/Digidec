// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Umsetzung der 16-Bit-I/Q-Daten der SDRplay-Geräte auf die 8 Bit der Demodulation. Der Spitzenwert wird nachgeführt:
/// schnell nach oben, langsam nach unten, nie unter 2000 (kein Rauschen aufblasen).
struct IQ16Scaler {
    private var peak = 4096.0

    /// Faktor für einen Block mit dem größten Betrag `maxAbs`; der Wert 0 ergibt sich bei 127
    mutating func factor(maxAbs: Int) -> Double {
        peak = max(2000, max(Double(maxAbs), peak * 0.98))
        return 110.0 / peak
    }

    @inline(__always) static func byte(_ v: Int16, factor: Double) -> UInt8 {
        UInt8(max(0, min(255, (Double(v) * factor + 127).rounded())))
    }
}

/// SDRplay-Geräte (RSP1A, RSP1B, RSP2, RSPdx, RSPduo) direkt über die SDRplay-API 3.15 (`libsdrplay_api`, vom Installer unter
/// https://www.sdrplay.com/api/), ohne SDRconnect. Die Bibliothek wird erst zur Laufzeit geladen (dlopen) und ist nicht Teil von Digidec;
/// ihre Lizenz erlaubt keine Weitergabe. Weil Digidec ohne den Header baut, stehen die Lage der Felder in den Strukturen der API hier als
/// Versätze (gemessen mit dem Header der Version 3.15 unter macOS arm64); andere Versionen der API werden abgelehnt.
/// Der RSPduo läuft im Einzeltuner-Betrieb (Tuner A oder B) mit 2 MS/s bei 1090 MHz.
public final class SDRplayAPISource: ADSBIQSource, @unchecked Sendable {
    typealias Fn0 = @convention(c) () -> Int32
    typealias VersionFn = @convention(c) (UnsafeMutablePointer<Float>?) -> Int32
    typealias GetDevicesFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UInt32) -> Int32
    typealias DeviceFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias ErrorStringFn = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias GetParamsFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias InitFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    typealias UpdateFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UInt32) -> Int32
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
        static let callbackSize = 24
        // Werte
        static let bw1536: Int32 = 1536, ifZero: Int32 = 0, loAuto: Int32 = 1
        static let tunerA: Int32 = 1, tunerB: Int32 = 2, duoSingleTuner: Int32 = 1
        static let overloadAck: UInt32 = 0x0400_0000
        static let rspDuoID: UInt8 = 3
    }

    static let apiVersion: Float = 3.15
    /// Die API gilt je Prozess: höchstens eine Quelle gleichzeitig (sonst schließt die zweite der ersten die API)
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active = false
    private var holdsAPI = false

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
    private var retainedSelf: Unmanaged<SDRplayAPISource>?
    private(set) public var deviceDescription = "SDRplay"
    /// Anzahl der Übersteuerungsmeldungen des Geräts seit dem Start (für Diagnose)
    private(set) public var overloadCount = 0

    private var close: Fn0?, uninit: DeviceFn?, release: DeviceFn?, lockApi: Fn0?, unlockApi: Fn0?, update: UpdateFn?

    public init(settings: ADSBGainSettings) { self.settings = settings }

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
        guard Self.activeLock.withLock({ () -> Bool in
            if Self.active { return false }
            Self.active = true
            return true
        }) else { throw ADSBSourceError.busy("SDRplay") }
        holdsAPI = true
        self.lib = lib
        self.close = close
        self.uninit = uninit
        self.release = release
        self.lockApi = lockApi
        self.unlockApi = unlockApi
        self.update = update
        self.onData = onData
        self.onStop = onStop

        func text(_ rc: Int32) -> String { errorString(rc).map { String(cString: $0) } ?? "Fehler \(rc)" }
        func fail(_ message: String) -> ADSBSourceError {
            teardown()
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
        dev.storeBytes(of: 2_000_000.0, toByteOffset: Layout.fsHz, as: Double.self)
        dev.storeBytes(of: Double(settings.sdrplayPPM), toByteOffset: Layout.ppm, as: Double.self)
        channel.storeBytes(of: Layout.bw1536, toByteOffset: Layout.bwType, as: Int32.self)
        channel.storeBytes(of: Layout.ifZero, toByteOffset: Layout.ifType, as: Int32.self)
        channel.storeBytes(of: Layout.loAuto, toByteOffset: Layout.loMode, as: Int32.self)
        channel.storeBytes(of: Int32(max(20, min(59, settings.sdrplayIFGainReduction))), toByteOffset: Layout.gRdB, as: Int32.self)
        channel.storeBytes(of: UInt8(max(0, min(27, settings.sdrplayLNAState))), toByteOffset: Layout.lnaState, as: UInt8.self)
        channel.storeBytes(of: settings.centerFrequencyHz, toByteOffset: Layout.rfHz, as: Double.self)
        // Verstärkungsregelung: aus (feste Stufen) oder 50 Hz mit dem Standardpegel
        channel.storeBytes(of: Int32(settings.sdrplayAGC ? 2 : 0), toByteOffset: Layout.agcEnable, as: Int32.self)
        if isDuo { channel.storeBytes(of: UInt8(settings.sdrplayBias ? 1 : 0), toByteOffset: Layout.duoBiasT, as: UInt8.self) }

        // Rückrufe: der Zeiger auf diese Quelle bleibt festgehalten, bis der Strom beendet ist
        let table = UnsafeMutableRawPointer.allocate(byteCount: Layout.callbackSize, alignment: 8)
        let stream: StreamCB = { xi, xq, _, n, _, ctx in
            guard let me = CallbackContext.object(ctx, as: SDRplayAPISource.self), let xi, let xq else { return }
            me.handle(xi: xi, xq: xq, count: Int(n))
        }
        let event: EventCB = { id, _, _, ctx in
            guard let me = CallbackContext.object(ctx, as: SDRplayAPISource.self) else { return }
            me.handleEvent(id)
        }
        table.storeBytes(of: unsafeBitCast(stream, to: UInt.self), toByteOffset: 0, as: UInt.self)
        table.storeBytes(of: unsafeBitCast(stream, to: UInt.self), toByteOffset: 8, as: UInt.self)
        table.storeBytes(of: unsafeBitCast(event, to: UInt.self), toByteOffset: 16, as: UInt.self)
        callbacks = table
        let me = Unmanaged.passRetained(self)
        retainedSelf = me
        lock.withLock { streaming = true }
        let rcInit = initFn(handle, table, me.toOpaque())
        guard rcInit == 0 else {
            lock.withLock { streaming = false }
            retainedSelf = nil
            me.release()
            throw fail("SDRplay: Empfang lässt sich nicht starten (\(text(rcInit)))")
        }
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
    func handleEvent(_ id: Int32) {
        switch id {
        case 1:                                                    // Übersteuerung geändert (Meldung muss bestätigt werden)
            overloadCount += 1
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
            holdsAPI = false
            Self.activeLock.withLock { Self.active = false }
        }
        // Nach Uninit kommen keine Rückrufe mehr: Speicher freigeben (der Zeiger auf die Quelle mit etwas Nachlauf)
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
