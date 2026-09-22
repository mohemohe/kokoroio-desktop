// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KokoroDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KokoroCore", targets: ["KokoroCore"]),
        .executable(name: "KokoroDesktop", targets: ["KokoroDesktop"])
    ],
    targets: [
        .target(name: "KokoroCore"),
        .executableTarget(name: "KokoroDesktop", dependencies: ["KokoroCore"]),
        .testTarget(name: "KokoroCoreTests", dependencies: ["KokoroCore"])
    ],
    swiftLanguageModes: [.v5]
)
