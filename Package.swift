// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Untranslate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UntranslateCore"),
        .executableTarget(name: "Untranslate", dependencies: ["UntranslateCore"]),
        .executableTarget(name: "untranslate-check", dependencies: ["UntranslateCore"]),
    ]
)
