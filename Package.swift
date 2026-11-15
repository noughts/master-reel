// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "master-reel",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "master-reel", targets: ["MasterReel"]),
    ],
    targets: [
        .executableTarget(name: "MasterReel"),
        .testTarget(
            name: "MasterReelTests",
            dependencies: ["MasterReel"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
