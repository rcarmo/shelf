// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DecisionConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../Packages/TypedDecisions")],
    targets: [.executableTarget(name: "DecisionConsumer", dependencies: [
        .product(name: "DecisionCore", package: "TypedDecisions"),
        .product(name: "DecisionFoundationModels", package: "TypedDecisions")
    ])]
)
