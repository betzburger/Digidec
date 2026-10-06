// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine

/// NAVTEX-Stationen, deren Sendefenster automatisch aufgenommen werden sollen. Der Plan wird nach dem IMO-Raster aus der
/// Stationsliste berechnet (`NavtexPlan`) und ändert sich nicht; einen Abruf aus dem Netz gibt es deshalb nicht.
@MainActor
public final class NavtexPlanStore: ObservableObject {
    public let plan: NavtexPlan
    @Published public var selectedStationIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedStationIDs).sorted(), forKey: "navtexSchedStations") }
    }
    @Published public var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "navtexSchedAuto") } }
    @Published public var returnToPreviousModule: Bool { didSet { UserDefaults.standard.set(returnToPreviousModule, forKey: "navtexSchedReturn") } }

    public init(csv: String? = nil) {
        plan = NavtexPlan.parse(csv: csv ?? Self.loadCSV() ?? "")
        let d = UserDefaults.standard
        // erster Start: Pinneberg (DWD); danach gilt die gespeicherte Wahl, auch wenn sie leer ist
        selectedStationIDs = d.object(forKey: "navtexSchedStations") == nil
            ? NavtexPlan.defaultStationIDs : Set(d.stringArray(forKey: "navtexSchedStations") ?? [])
        autoEnabled = d.bool(forKey: "navtexSchedAuto")
        returnToPreviousModule = d.object(forKey: "navtexSchedReturn") as? Bool ?? true
    }

    /// Sendefenster der gewählten Stationen
    public var items: [ScheduledItem] { plan.items(forStationIDs: selectedStationIDs) }
    public var selectedItemIDs: Set<String> { Set(items.map(\.id)) }

    public func toggle(_ s: NavtexStation) {
        if selectedStationIDs.contains(s.id) { selectedStationIDs.remove(s.id) } else { selectedStationIDs.insert(s.id) }
    }

    private static func loadCSV() -> String? {
        let urls = [Bundle.main.url(forResource: "NAVTEX_Stations", withExtension: "csv", subdirectory: "Stations"),
                    Bundle.main.url(forResource: "NAVTEX_Stations", withExtension: "csv"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Stations/NAVTEX_Stations.csv")]
        for u in urls.compactMap({ $0 }) { if let t = try? String(contentsOf: u, encoding: .utf8) { return t } }
        return nil
    }
}
