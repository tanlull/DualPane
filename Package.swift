// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DualPane",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DualPane", path: "Sources")
    ]
)
