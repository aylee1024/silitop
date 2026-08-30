// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "silitop",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SiliTopCore", targets: ["SiliTopCore"]),
        .executable(name: "silitop", targets: ["silitop"]),
    ],
    targets: [
        .target(
            name: "SiliTopCore",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "silitop",
            dependencies: ["SiliTopCore"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(name: "SiliTopCoreTests", dependencies: ["SiliTopCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
