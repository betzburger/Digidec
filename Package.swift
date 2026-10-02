// swift-tools-version: 6.0
import PackageDescription

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
        .executableTarget(
            name: "Digidec",
            dependencies: ["Fldigi", "FT8", "Wspr"],
            path: "Sources"
        )
    ],
    cxxLanguageStandard: .cxx17
)
