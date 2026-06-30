// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Shelf", targets: ["Shelf"])
    ],
    targets: [
        .executableTarget(
            name: "Shelf",
            path: "Sources/Shelf",
            linkerSettings: [
                .linkedFramework("LatentSemanticMapping"),
                .linkedFramework("ScriptingBridge")
            ]
        )
    ]
)
