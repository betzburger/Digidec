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
        // RTTY-Empfänger aus fldigi 4.2.13 (GPLv3), siehe Vendor/FldigiRTTY/UPSTREAM.md
        .target(
            name: "FldigiRTTY",
            path: "Vendor/FldigiRTTY",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src")
            ]
        ),
        // SYNOP/SHIP/BUOY-Decoder aus fldigi 4.2.13 (GPLv3), siehe Vendor/FldigiSynop/UPSTREAM.md
        .target(
            name: "FldigiSynop",
            path: "Vendor/FldigiSynop",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-w"])          // GNU-Regex von 1993: alte C-Warnungen unterdrücken
            ],
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("compat")
            ]
        ),
        .executableTarget(
            name: "Digidec",
            dependencies: ["FldigiRTTY", "FldigiSynop"],
            path: "Sources"
        )
    ],
    cxxLanguageStandard: .cxx17
)
