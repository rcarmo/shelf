// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TypedDecisions",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DecisionCore", targets: ["DecisionCore"]),
        .library(name: "DecisionFoundationModels", targets: ["DecisionFoundationModels"]),
        .executable(name: "decision-replay", targets: ["DecisionReplay"])
    ],
    targets: [
        .target(name: "DecisionCore"),
        .target(name: "DecisionFoundationModels", dependencies: ["DecisionCore"]),
        .executableTarget(name: "DecisionReplay", dependencies: ["DecisionCore", "DecisionFoundationModels"]),
        .testTarget(name: "DecisionCoreTests", dependencies: ["DecisionCore", "DecisionFoundationModels"])
    ]
)
