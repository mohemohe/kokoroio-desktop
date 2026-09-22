// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KokoroDesktop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KokoroCore", targets: ["KokoroCore"]),
        .executable(name: "KokoroDesktop", targets: ["KokoroDesktop"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
        .package(url: "https://github.com/klaaspieter/swift-emoji", from: "0.1.1")
    ],
    targets: [
        .target(name: "KokoroCore", dependencies: [
            .product(name: "EmojiData", package: "swift-emoji")
        ]),
        .executableTarget(name: "KokoroDesktop", dependencies: [
            "KokoroCore",
            .product(name: "Textual", package: "textual")
        ]),
        .testTarget(name: "KokoroCoreTests", dependencies: ["KokoroCore"])
    ],
    swiftLanguageModes: [.v5]
)
