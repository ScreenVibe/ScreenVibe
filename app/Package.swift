// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "UandI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "UandI", path: "Sources/UandI")
    ]
)
