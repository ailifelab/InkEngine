// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeechRuntime",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "SpeechRuntime", targets: ["SpeechRuntime"])],
    targets: [
        .binaryTarget(name: "ORTMac", path: "Frameworks/ORTMac.xcframework"),
        .binaryTarget(name: "ORTIOS", path: "Frameworks/ORTIOS.xcframework"),
        .target(name: "SpeechRuntime", dependencies: [
            .target(name: "ORTMac", condition: .when(platforms: [.macOS])),
            .target(name: "ORTIOS", condition: .when(platforms: [.iOS]))
        ], exclude: ["MatchaSynthesizer.swift", "VitsSynthesizer.swift", "QwenSynthesizer.swift"], linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate")]),
        .testTarget(name: "SpeechRuntimeTests", dependencies: ["SpeechRuntime"])
    ]
)
