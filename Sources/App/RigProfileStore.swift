import Foundation
import SwiftUI

/// Gespeicherte Funkgeräte (Rechner, Port, Name, Audioquelle) und die Wahl; Ablage in den Benutzereinstellungen
@MainActor
public final class RigProfileStore: ObservableObject {
    private static let key = "rigProfiles"

    @Published public private(set) var list: RigProfileList

    public init() {
        list = RigProfileList.decoded(from: UserDefaults.standard.data(forKey: Self.key))
    }

    /// Das gewählte Gerät (nil = Automatik)
    public var active: RigProfile? { list.active }

    @discardableResult
    public func add(_ profile: RigProfile) -> RigProfile {
        var l = list
        let added = l.add(profile)
        commit(l)
        return added
    }

    public func update(_ profile: RigProfile) {
        var l = list
        l.update(profile)
        commit(l)
    }

    public func remove(id: String) {
        var l = list
        l.remove(id: id)
        commit(l)
    }

    /// Gerät wählen; nil = Automatik
    public func setActive(id: String?) {
        var l = list
        l.activeID = id.flatMap { l.profile(id: $0) != nil ? $0 : nil }
        commit(l)
    }

    private func commit(_ new: RigProfileList) {
        list = new
        if let data = new.encoded() { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
