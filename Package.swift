// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudePace",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudePace", path: "Sources/ClaudePace")
    ]
)
