// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacerCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PacerCore", targets: ["PacerCore"]),
    ],
    targets: [
        .target(
            name: "PacerCore",
            resources: [
                .copy("Resources/litellm-pricing.json"),
            ]
        ),
        .testTarget(
            name: "PacerCoreTests",
            dependencies: ["PacerCore"]
        ),
    ]
)
