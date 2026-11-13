// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "whisper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DictationCore"),
        // The menu bar app. Swift 5 language mode: AppKit, AVFoundation and event-tap callbacks predate strict concurrency.
        .executableTarget(
            name: "Whisper", dependencies: ["DictationCore"], path: "Sources/Whisper",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "keyboard-prototype", dependencies: ["DictationCore"], path: "Sources/KeyboardPrototype"),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ]
)
