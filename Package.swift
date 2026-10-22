// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InkEngine",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "InkCore", targets: ["InkCore"])],
    targets: [
        .target(name: "InkCore", resources: [.process("Resources")]),
        .testTarget(name: "InkCoreTests", dependencies: ["InkCore"])
    ]
)
