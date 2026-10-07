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
        // Codec2 und FreeDV (David Rowe, LGPL-2.1): Sprachcodec und Modems für FreeDV und M17.
        // Herkunft und Abweichungen: Vendor/Codec2/UPSTREAM_CODEC2.md
        .target(
            name: "Codec2",
            path: "Vendor/Codec2",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("include"),
                .define("GIT_HASH", to: "\"310777b\""),          // Commit der Quelle (Vendor/Codec2/UPSTREAM_CODEC2.md)
                // Namen, die auch fldigi oder FT8 liefern: für Codec2 umbenannt, damit der Linker keine doppelten Symbole findet
                .define("kiss_fft", to: "c2_kiss_fft"),
                .define("kiss_fftr", to: "c2_kiss_fftr"),
                .define("kiss_fftri", to: "c2_kiss_fftri"),
                .define("kiss_fft_alloc", to: "c2_kiss_fft_alloc"),
                .define("kiss_fftr_alloc", to: "c2_kiss_fftr_alloc"),
                .define("kiss_fft_stride", to: "c2_kiss_fft_stride"),
                .define("kiss_fft_cleanup", to: "c2_kiss_fft_cleanup"),
                .define("kiss_fft_next_fast_size", to: "c2_kiss_fft_next_fast_size"),
                .define("encode", to: "c2_encode"),
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
        // FAAD2 (Nero/Ahead Software, GPL-2.0-or-later): AAC-Decoder mit SBR und PS für DAB+.
        // Herkunft und Abweichungen: Vendor/Faad2/UPSTREAM_FAAD2.md
        .target(
            name: "Faad2",
            path: "Vendor/Faad2",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("HAVE_INTTYPES_H", to: "1"),
                .define("HAVE_MEMCPY", to: "1"),
                .define("HAVE_STRING_H", to: "1"),
                .define("HAVE_STRINGS_H", to: "1"),
                .define("HAVE_SYS_STAT_H", to: "1"),
                .define("HAVE_SYS_TYPES_H", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
                .define("APPLY_DRC"),
                .define("PACKAGE_VERSION", to: "\"2.11.4\""),
                .unsafeFlags(["-w", "-O3"])
            ]
        ),
        // Gemeinsame Schnittstelle für digitale Sprache (Decoder eintragen, Ton ausgeben)
        .target(
            name: "VoiceCore",
            path: "Modules/VoiceCore/Sources/VoiceCore"
        ),
        // Prüfstand für Sprachdecoder (Stick): Sprache codieren, zurückwandeln, als WAV ausgeben
        .executableTarget(
            name: "voice-selftest",
            dependencies: ["VoiceCore"],
            path: "Tools/VoiceSelfTest"
        ),
        .executableTarget(
            name: "Digidec",
            dependencies: ["Fldigi", "FT8", "Wspr", "Codec2", "Faad2", "VoiceCore"] + (hasLocalVocoder ? ["LocalVocoder"] : []),
            path: "Sources",
            swiftSettings: hasLocalVocoder ? [.define("DIGIDEC_LOCAL_VOCODER")] : []
        )
    ],
    cxxLanguageStandard: .cxx17
)

if hasLocalVocoder {
    // Lokale C-Bausteine (liegen unter Local/Vocoder/Native, nicht im Repository)
    let hasNative = FileManager.default.fileExists(atPath: packageRoot + "/Local/Vocoder/Native")
    if hasNative {
        package.targets.append(.target(name: "LocalNative", path: "Local/Vocoder/Native", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-w", "-O3"])]))
    }
    package.targets.append(.target(name: "LocalVocoder", dependencies: ["VoiceCore"] + (hasNative ? ["LocalNative"] : []), path: "Local/Vocoder/Sources"))
    // Lokale Prüfprogramme: jeder Ordner unter Local/Tools/Exec ist ein Programm
    let execRoot = packageRoot + "/Local/Tools/Exec"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: execRoot)) ?? [] where !name.hasPrefix(".") {
        package.targets.append(.executableTarget(name: name, dependencies: ["VoiceCore", "LocalVocoder"], path: "Local/Tools/Exec/" + name))
    }
}
