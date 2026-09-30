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
        .executableTarget(
            name: "Digidec",
            dependencies: ["FldigiRTTY"],
            path: "Sources"
        )
    ],
    cxxLanguageStandard: .cxx17
)
