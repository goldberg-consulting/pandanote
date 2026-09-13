// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pandanote",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Pandanote", targets: ["Pandanote"])],
    targets: [
        .target(name: "PandanoteCore"),
        .executableTarget(name: "Pandanote", dependencies: ["PandanoteCore"]),
        .testTarget(name: "PandanoteCoreTests", dependencies: ["PandanoteCore"]),
        .testTarget(name: "PandanoteTests", dependencies: ["Pandanote"])
    ],
    swiftLanguageModes: [.v5]
)
