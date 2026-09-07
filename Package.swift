// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KubeLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KubeLens", path: "Sources/KubeLens", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
