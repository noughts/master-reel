// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "video-enhancer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "video-enhancer", targets: ["VideoEnhancer"]),
    ],
    targets: [
        .executableTarget(name: "VideoEnhancer"),
        .testTarget(
            name: "VideoEnhancerTests",
            dependencies: ["VideoEnhancer"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
