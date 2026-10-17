// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(AppKit)
import SwiftUI

// Unter macOS steht diese Erweiterung in Sources/UI/Theme.swift
extension Color {
    init(_ c: RGB) { self.init(red: c.r, green: c.g, blue: c.b) }
}
#endif
