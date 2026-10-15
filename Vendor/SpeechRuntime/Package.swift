// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeechRuntime",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "SpeechRuntime", targets: ["SpeechRuntime"]),
               .executable(name: "SpeechProbe", targets: ["SpeechProbe"])],
    targets: [
        .binaryTarget(name: "SherpaMac", path: "Frameworks/SherpaMac.xcframework"),
        .binaryTarget(name: "SherpaIOS", path: "Frameworks/SherpaIOS.xcframework"),
        .binaryTarget(name: "ORTMac", path: "Frameworks/ORTMac.xcframework"),
        .binaryTarget(name: "ORTIOS", path: "Frameworks/ORTIOS.xcframework"),
        .target(name: "SpeechRuntime", dependencies: [
            .target(name: "NativeQwen", condition: .when(platforms: [.macOS])),
            .target(name: "SherpaMac", condition: .when(platforms: [.macOS])),
            .target(name: "SherpaIOS", condition: .when(platforms: [.iOS])),
            .target(name: "ORTMac", condition: .when(platforms: [.macOS])),
            .target(name: "ORTIOS", condition: .when(platforms: [.iOS]))
        ], linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate")]),
        .target(name: "NativeQwen", exclude: ["LICENSE.txt"], linkerSettings: [.linkedFramework("CoreML")]),
        .executableTarget(name: "SpeechProbe", dependencies: ["SpeechRuntime"]),
        .testTarget(name: "SpeechRuntimeTests", dependencies: ["SpeechRuntime"])
    ]
)
