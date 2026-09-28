// swift-tools-version: 6.0
import PackageDescription

#if os(Windows)
let uiDependencies: [Package.Dependency] = [
    .package(path: "Windows/Generated/WinUI"),
    .package(path: "Windows/Generated/WinAppSDK"),
    .package(path: "Windows/Generated/WindowsFoundation"),
    .package(path: "Windows/Generated/UWP"),
    .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
]
let coreDependencies: [Target.Dependency] = [.product(name: "SwiftSoup", package: "SwiftSoup")]
let coreExcludes = ["MessageMarkdown.swift"]
let testExcludes = ["MessageMarkdownTests.swift"]
let desktopTargets: [Target] = [
    .target(name: "WindowsNative", path: "Windows/Native", publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("runtimeobject"), .linkedLibrary("advapi32"), .linkedLibrary("user32"),
                             .linkedLibrary("comdlg32"), .linkedLibrary("comctl32"), .linkedLibrary("imm32")]),
    .executableTarget(name: "KokoroDesktop", dependencies: [
        "KokoroCore", "KokoroWindowsState", "WindowsNative",
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "WinUI", package: "WinUI"),
        .product(name: "WinAppSDK", package: "WinAppSDK"),
        .product(name: "UWP", package: "UWP"),
        .product(name: "WindowsFoundation", package: "WindowsFoundation")
    ], path: "Sources/KokoroWindows", resources: [.process("Resources")], linkerSettings: [
        .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])
    ])
]
#else
let uiDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
    .package(url: "https://github.com/klaaspieter/swift-emoji", from: "0.1.1")
]
let coreDependencies: [Target.Dependency] = [.product(name: "EmojiData", package: "swift-emoji")]
let coreExcludes: [String] = []
let testExcludes: [String] = []
let desktopTargets: [Target] = [
    .executableTarget(name: "KokoroDesktop", dependencies: [
        "KokoroCore", .product(name: "Textual", package: "textual")
    ])
]
#endif

let package = Package(
    name: "KokoroDesktop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KokoroCore", targets: ["KokoroCore"]),
        .executable(name: "KokoroDesktop", targets: ["KokoroDesktop"])
    ],
    dependencies: uiDependencies,
    targets: [
        .target(name: "KokoroCore", dependencies: coreDependencies, exclude: coreExcludes),
        .target(name: "KokoroWindowsState", dependencies: ["KokoroCore"]),
        .testTarget(name: "KokoroCoreTests", dependencies: ["KokoroCore"], exclude: testExcludes),
        .testTarget(name: "KokoroWindowsStateTests", dependencies: ["KokoroWindowsState"])
    ] + desktopTargets,
    swiftLanguageModes: [.v5]
)
