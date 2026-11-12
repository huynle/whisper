// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "whisper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DictationCore"),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ]
)
