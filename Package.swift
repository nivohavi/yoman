// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Yoman",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Yoman", path: "Sources/Yoman")
    ]
)
