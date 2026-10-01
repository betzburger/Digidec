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
                .headerSearchPath("compat")
            ]
        ),
        .executableTarget(
            name: "Digidec",
            dependencies: ["Fldigi"],
            path: "Sources"
        )
    ],
    cxxLanguageStandard: .cxx17
)
