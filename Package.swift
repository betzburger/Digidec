// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import PackageDescription

// Optionale lokale Erweiterung für digitale Sprache: liegt unter Local/ (nicht im Repository) und wird nur gebaut, wenn der Ordner existiert.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasLocalVocoder = FileManager.default.fileExists(atPath: packageRoot + "/Local/Vocoder/Sources")

let package = Package(
    name: "Digidec",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Digidec", targets: ["Digidec"])
    ],
    targets: [
        // Empfangsteile aus fldigi 4.2.13 (GPLv3): RTTY-Kern, SYNOP-Decoder, gemeinsame Filter und Hilfen.
        // Herkunft und Abweichungen: Vendor/Fldigi/UPSTREAM_*.md
        .target(
            name: "Fldigi",
            path: "Vendor/Fldigi",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-w"])          // GNU-Regex von 1993: alte C-Warnungen unterdrücken
            ],
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/common"),
                .headerSearchPath("src/rtty"),
                .headerSearchPath("src/synop"),
                .headerSearchPath("src/misc"),
                .headerSearchPath("src/navtex"),
                .headerSearchPath("src/cw"),
                .headerSearchPath("src/wefax"),
                .headerSearchPath("src/psk"),
                .headerSearchPath("src/mt63"),
                .headerSearchPath("src/olivia"),
                .headerSearchPath("src/mfsk"),
                .headerSearchPath("mt63data"),
                .headerSearchPath("compat")
            ]
        ),
        // FT8-Decoder ft8mon (Robert Morris AB1HL, MIT) mit pocketfft (BSD) statt FFTW.
        // Herkunft und Abweichungen: Vendor/FT8/UPSTREAM_FT8.md
        .target(
            name: "FT8",
            path: "Vendor/FT8",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("compat"),
                // Rechenzeit-begrenzter Decoder: auch im Debug-Build optimieren, sonst weniger Durchgänge
                .unsafeFlags(["-w", "-O3"])
            ]
        ),
        // WSPR-Decoder wsprd aus WSJT-X 3.0 (K1JT, K9AN u. a., GPLv3) mit pocketfft (BSD) statt FFTW.
        // Herkunft und Abweichungen: Vendor/Wspr/UPSTREAM_WSPR.md
        .target(
            name: "Wspr",
            path: "Vendor/Wspr",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("inc"),
                .unsafeFlags(["-w", "-O3", "-ffast-math"])      // wsprd baut mit -O3 -ffast-math
            ],
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("compat"),
                .unsafeFlags(["-w", "-O3"])
            ]
        ),
        // Gemeinsame Schnittstelle für digitale Sprache (Decoder eintragen, Ton ausgeben)
        .target(
            name: "VoiceCore",
            path: "Modules/VoiceCore/Sources/VoiceCore"
        ),
        .executableTarget(
            name: "Digidec",
            dependencies: ["Fldigi", "FT8", "Wspr", "VoiceCore"] + (hasLocalVocoder ? ["LocalVocoder"] : []),
            path: "Sources",
            swiftSettings: hasLocalVocoder ? [.define("DIGIDEC_LOCAL_VOCODER")] : []
        )
    ],
    cxxLanguageStandard: .cxx17
)

if hasLocalVocoder {
    package.targets.append(.target(name: "LocalVocoder", dependencies: ["VoiceCore"], path: "Local/Vocoder/Sources"))
    package.targets.append(.executableTarget(name: "voice-selftest", dependencies: ["VoiceCore", "LocalVocoder"], path: "Local/Tools/VoiceSelfTest"))
}
