// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Eine empfangene Sprach-Aussendung eines Vierpegel-Verfahrens (YSF, DMR): Absender, Ziel, Weg, Dauer und die Sprachrahmen zum Abspielen.
public struct VoiceCall: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var start: Date
    /// Verfahren, z. B. „YSF V/D 2“
    public var mode: String
    public var source = ""
    public var target = ""
    /// Repeater oder Netz (Aufwärts-/Abwärtsstrecke), Zeitschlitz usw.
    public var via = ""
    /// Weitere Angaben (Bemerkungen, Farbcode, Hinweise)
    public var note = ""
    public var frames = 0
    /// Sprachrahmen (9 Byte im Format des Sprachsticks)
    public var ambe: [[UInt8]] = []
    public var lateEntry = false
    /// `nil` = läuft noch
    public var endedBy: Ended?

    public enum Ended: String, Sendable { case end, lost }

    public init(start: Date, mode: String) {
        self.start = start
        self.mode = mode
    }

    public var seconds: Double { Double(frames) * 0.02 }
    public var isLive: Bool { endedBy == nil }
}
