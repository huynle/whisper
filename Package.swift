// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "whisper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DictationCore"),
        .executableTarget(name: "keyboard-prototype", dependencies: ["DictationCore"], path: "Sources/KeyboardPrototype"),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ]
)
