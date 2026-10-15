// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InkEngine",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "InkCore", targets: ["InkCore"])],
    targets: [
        .target(name: "InkCore"),
        .testTarget(name: "InkCoreTests", dependencies: ["InkCore"])
    ]
)
