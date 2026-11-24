// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppChecker",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "AppCheckerCore"),
        .executableTarget(
            name: "AppChecker",
            dependencies: ["AppCheckerCore", .product(name: "Sparkle", package: "Sparkle")],
            // The app bundle keeps Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "AppCheckerCoreTests", dependencies: ["AppCheckerCore"]),
    ]
)
