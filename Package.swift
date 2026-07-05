// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Shelf", targets: ["Shelf"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/rcarmo/SwiftIntelligence",
            revision: "2a03f0b01c5486e571ff5753eedf4a76d43a2a8e"
        )
    ],
    targets: [
        .executableTarget(
            name: "Shelf",
            dependencies: [
                .product(name: "SwiftIntelligence", package: "SwiftIntelligence")
            ],
            path: "Sources/Shelf",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("LatentSemanticMapping"),
                .linkedFramework("ScriptingBridge")
            ]
        )
    ]
)
