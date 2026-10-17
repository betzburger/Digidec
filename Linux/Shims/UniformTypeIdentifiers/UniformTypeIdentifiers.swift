// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für UniformTypeIdentifiers (nur Linux): nur die Kennungen, die die Rechenteile brauchen.
public struct UTType: Hashable, Sendable {
    public let identifier: String
    public init(_ identifier: String) { self.identifier = identifier }
    public static let png = UTType("public.png")
    public static let jpeg = UTType("public.jpeg")
    public static let pdf = UTType("com.adobe.pdf")
    public static let json = UTType("public.json")
    public static let plainText = UTType("public.plain-text")
    public static let wav = UTType("com.microsoft.waveform-audio")
}
