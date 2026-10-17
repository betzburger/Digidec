// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftCrossUI
@testable import DigidecCore

// Bausteine der Oberfläche, benannt wie am Mac (RadioCard, ButtonGrid …), damit die Modulansichten ähnlich aufgebaut sein können.

func color(_ c: RGB, _ opacity: Double = 1) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: opacity) }

func mono(_ size: Double, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }

/// Karte mit Titel darüber (wie `.radioCard(title:)`)
struct RadioCard<Content: View>: View {
    let palette: ThemePalette
    var title: String?
    var content: Content

    init(_ title: String? = nil, palette: ThemePalette, @ViewBuilder content: () -> Content) {
        self.title = title
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(mono(10, .bold))
                    .foregroundColor(color(palette.textDim))
                    .padding(.horizontal, 4)
            }
            content
                .padding(10)
                .background(color(palette.bgCard))
                .cornerRadius(8)
        }
    }
}
