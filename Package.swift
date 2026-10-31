// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IPBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IPBar", path: "Sources/IPBar")
    ]
)
