// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScreenVibe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ScreenVibe", path: "Sources/ScreenVibe")
    ]
)
