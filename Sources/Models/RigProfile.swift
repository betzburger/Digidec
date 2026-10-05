import Foundation

// MARK: - Freies Funkgerät: Verbindung zu einem beliebigen Hamlib-rigctld

/// Wohin sich Digidec für Frequenz und Mode verbindet: Rechner (Name oder IP) und TCP-Port eines rigctld.
/// Digidec spricht nur das rigctld-Textprotokoll (`f`, `m`, auf Wunsch `F`, `M`), nie PTT.
public struct RigEndpoint: Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    /// Gültiger Rechnername oder gültige IP-Adresse (IPv4/IPv6) und Port 1 … 65535; sonst nil
    public init?(host: String, port: Int) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard Self.isValid(host: h), (1...65535).contains(port) else { return nil }
        self.host = h
        self.port = UInt16(port)
    }

    private init(trustedHost: String, port: UInt16) {
        host = trustedHost
        self.port = port
    }

    /// Dieser Rechner (127.0.0.1): die Commander und die meisten rigctld-Aufrufe
    public static func loopback(port: UInt16) -> RigEndpoint {
        RigEndpoint(trustedHost: "127.0.0.1", port: port)
    }

    /// Läuft rigctld auf diesem Rechner? (dann bleibt der Verkehr im Gerät)
    public var isLoopback: Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h == "[::1]" || h.hasPrefix("127.")
    }

    /// Erlaubt sind Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich, Doppelpunkt (IPv6) und eckige Klammern;
    /// höchstens 253 Zeichen, keine Leerzeichen. Keine Prüfung, ob der Rechner existiert.
    public static func isValid(host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        return host.unicodeScalars.allSatisfy { s in
            (s.value < 128 && (CharacterSet.alphanumerics.contains(s) || ".-_:[]".unicodeScalars.contains(s)))
        }
    }

    /// „127.0.0.1:4532“ bzw. „[::1]:4532“
    public var text: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// Ein Funkgerät, das über einen rigctld bedient wird, mit Namen und (wahlweise) dem zugehörigen Audio-Eingang.
public struct RigProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Anzeigename in Kopfzeile, Log und Aufnahme-Dateien („IC-7300“, „Elad FDM-DUO“)
    public var name: String
    public var host: String
    public var port: Int
    /// Audio-Eingang, der mit dem Gerät zusammengehört (CoreAudio-UID und Name als Ersatz, wenn sich die UID geändert hat)
    public var audioUID: String?
    public var audioName: String?

    /// Hamlib-Standardport von rigctld
    public static let defaultPort = 4532
    public static let defaultHost = "127.0.0.1"

    public init(id: String = UUID().uuidString, name: String, host: String = RigProfile.defaultHost, port: Int = RigProfile.defaultPort,
                audioUID: String? = nil, audioName: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.audioUID = audioUID
        self.audioName = audioName
    }

    /// Verbindungsziel, nil bei ungültigem Rechnernamen oder Port
    public var endpoint: RigEndpoint? { RigEndpoint(host: host, port: port) }

    /// Name für die Anzeige (leerer Name → Rechner und Port)
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "rigctld \(host):\(port)" : n
    }

    /// Was an den Eingaben falsch ist (für die Anzeige im Dialog); nil = in Ordnung
    public var problem: String? {
        if !RigEndpoint.isValid(host: host.trimmingCharacters(in: .whitespaces)) { return "Rechner: Name oder IP-Adresse ohne Leerzeichen eintragen" }
        if !(1...65535).contains(port) { return "Port: Zahl von 1 bis 65535" }
        return nil
    }
}

/// Alle gespeicherten Funkgeräte und welches davon gilt (nil = Automatik: Commander über den USB-Codec)
public struct RigProfileList: Codable, Equatable, Sendable {
    public var profiles: [RigProfile] = []
    public var activeID: String?

    public init(profiles: [RigProfile] = [], activeID: String? = nil) {
        self.profiles = profiles
        self.activeID = activeID
    }

    /// Das gewählte Gerät; zeigt `activeID` ins Leere, gilt die Automatik
    public var active: RigProfile? {
        activeID.flatMap { id in profiles.first { $0.id == id } }
    }

    public func profile(id: String) -> RigProfile? { profiles.first { $0.id == id } }

    /// Neues Gerät anhängen; ein leerer Name wird „Funkgerät N“
    @discardableResult
    public mutating func add(_ profile: RigProfile) -> RigProfile {
        var p = profile
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = "Funkgerät \(profiles.count + 1)" }
        profiles.append(p)
        return p
    }

    /// Eintrag mit gleicher Kennung ersetzen
    public mutating func update(_ profile: RigProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile }
    }

    /// Eintrag löschen; war er der gewählte, gilt wieder die Automatik
    public mutating func remove(id: String) {
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Aus gespeicherten Daten; Unlesbares ergibt eine leere Liste. Ein Gerät mit unbrauchbarem Port bleibt erhalten (der Dialog zeigt den Fehler).
    public static func decoded(from data: Data?) -> RigProfileList {
        guard let data, let list = try? JSONDecoder().decode(RigProfileList.self, from: data) else { return RigProfileList() }
        return list
    }
}
