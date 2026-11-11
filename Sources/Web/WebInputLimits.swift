// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Prüfung von Werten, die aus dem Browser kommen. Eigene Datei ohne Abhängigkeiten, damit die Logiktests sie ohne den ganzen App-Zustand übersetzen können.
enum WebInputLimits {
    /// Frequenz aus dem Browser als Dial-Wert: gerundet und auf 100 kHz … 100 GHz begrenzt (die Umwandlung kann so nie abbrechen)
    static func dialHz(_ hz: Double) -> Int64 {
        guard hz.isFinite else { return 100_000 }
        return Int64(min(100_000_000_000, max(100_000, hz.rounded())))
    }
}
