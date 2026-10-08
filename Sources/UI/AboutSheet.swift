// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

/// Info-Fenster: Version, Lizenz (GPL-3.0-or-later), Quelltext, Quellen und Drittanbieter-Software, voller Lizenztext.
/// Die Texte kommen aus den mitgelieferten Dateien `THIRD_PARTY.md` und `LICENSE` (siehe `LicenseDocument`).
struct AboutSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case about = "ÜBER"
        case sources = "QUELLEN UND LIZENZEN"
        case license = "LIZENZTEXT"
        var id: String { rawValue }
    }

    static let sourceURL = URL(string: "https://github.com/betzburger/Digidec")!

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .about
    @State private var thirdParty = LicenseDocument.thirdParty.load()
    @State private var license = LicenseDocument.license.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 430)
                Spacer()
                Button("SCHLIESSEN") { dismiss() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .keyboardShortcut(.cancelAction)
            }
            Group {
                switch tab {
                case .about: about
                case .sources: sources
                case .license: licenseText
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(width: 680, height: 600)
        .background(RadioTheme.bgPanel)
    }

    // MARK: Über

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(RadioTheme.vfdCyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DIGIDEC")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .foregroundColor(RadioTheme.textBright)
                        Text("DIGITAL MODE DECODER · \(AppVersion.string)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdAmber)
                    }
                }
                Text("Copyright (C) 2026 Peter Betz und Mitwirkende")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)

                Text("LIZENZ")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .padding(.top, 4)
                Text("Digidec ist freie Software: Du darfst es weitergeben und ändern unter den Bedingungen der GNU General Public License, "
                     + "Version 3 oder (nach deiner Wahl) jeder späteren Version, wie von der Free Software Foundation veröffentlicht. "
                     + "Digidec wird in der Hoffnung verbreitet, nützlich zu sein, aber OHNE JEDE GEWÄHRLEISTUNG; sogar ohne die implizite "
                     + "Gewährleistung der MARKTFÄHIGKEIT oder EIGNUNG FÜR EINEN BESTIMMTEN ZWECK. Einzelheiten stehen im Lizenztext. "
                     + "Den Quelltext bekommst du unter der Adresse unten; wer eine fertige App weitergibt, muss ihn mitgeben oder anbieten.")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(Self.sourceURL)
                    } label: {
                        Label("QUELLTEXT AUF GITHUB", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help(Self.sourceURL.absoluteString)
                    Button("QUELLEN UND LIZENZEN") { tab = .sources }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                    Button("LIZENZTEXT") { tab = .license }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                }

                Text("ENTHÄLT QUELLTEXT UND DATEN VON")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Self.mainComponents, id: \.0) { name, license in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(name)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.textBright)
                                .frame(width: 190, alignment: .leading)
                            Text(license)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                        }
                    }
                }
                Text("Dazu kommen Vorbilder, Daten und Testaufnahmen anderer, jeweils mit Lizenz unter „Quellen und Lizenzen“. "
                     + "fldigi, WSJT-X, Hamlib, Dire Wolf und die übrigen genannten Namen gehören ihren Inhabern.")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 6)
        }
    }

    /// Die wichtigsten Bestandteile mit Lizenz (die vollständige Liste steht in THIRD_PARTY.md)
    private static let mainComponents: [(String, String)] = [
        ("fldigi 4.2.13", "GPL-3.0-or-later (gfft.h LGPL-3.0-or-later, Hamlib-Locator LGPL-2.0-or-later)"),
        ("WSJT-X (wsprd)", "GPL-3.0"),
        ("JS8Call", "GPL-3.0"),
        ("ft8mon, ft8_lib", "MIT"),
        ("pocketfft, KISS FFT", "BSD-3-Clause"),
        ("OurAirports", "gemeinfrei"),
        ("SondeHub Startorte", "CC BY-SA 2.0"),
        ("Länderliste cty.dat (AD1C)", "freie Nutzung durch den Autor"),
        ("Sendepläne", "Quelle: Deutscher Wetterdienst")
    ]

    // MARK: Quellen

    private var sources: some View {
        Group {
            if let thirdParty {
                ScrollView {
                    MarkdownBlocksView(blocks: MarkdownLite.parse(thirdParty))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                }
            } else {
                missing("THIRD_PARTY.md")
            }
        }
    }

    // MARK: Lizenztext

    private var licenseText: some View {
        Group {
            if let license {
                ScrollView {
                    Text(license)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RadioTheme.bgDeep)
                .cornerRadius(6)
            } else {
                missing("LICENSE")
            }
        }
    }

    private func missing(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) ist in dieser Installation nicht enthalten.")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
            Text("Der Text steht im Quelltext unter \(Self.sourceURL.absoluteString).")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }
}

/// Zeigt die Blöcke eines `MarkdownLite`-Texts: Überschriften, Absätze und Listen; fett, `Code` und Links im Text werden gesetzt
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: level == 1 ? 15 : level == 2 ? 12.5 : 11, weight: .black, design: .monospaced))
                .foregroundColor(level == 3 ? RadioTheme.vfdCyan : (level == 2 ? RadioTheme.vfdAmber : RadioTheme.textBright))
                .padding(.top, level == 1 ? 0 : (level == 2 ? 12 : 6))
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .foregroundColor(RadioTheme.textDim)
                Text(Self.inline(text))
                    .foregroundColor(RadioTheme.textBright.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.leading, CGFloat(level) * 16)
        }
    }

    /// Fett, `Code` und Links aus dem Markdown der Zeile; bei Fehlern der reine Text
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
