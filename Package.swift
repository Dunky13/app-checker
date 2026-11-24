// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kanarie",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "KanarieCore"),
        .executableTarget(
            name: "Kanarie",
            dependencies: ["KanarieCore", .product(name: "Sparkle", package: "Sparkle")],
            // The app bundle keeps Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "KanarieCoreTests", dependencies: ["KanarieCore"]),
    ]
)
