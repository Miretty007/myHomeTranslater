// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "myHomeTranslater",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "myHomeTranslater"),
        .testTarget(name: "myHomeTranslaterTests", dependencies: ["myHomeTranslater"])
    ]
)
