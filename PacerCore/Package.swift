// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacerCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PacerCore", targets: ["PacerCore"]),
        .library(name: "PacerUI", targets: ["PacerUI"]),
    ],
    targets: [
        .target(
            name: "PacerCore",
            resources: [
                .copy("Resources/litellm-pricing.json"),
            ]
        ),
        // Shared SwiftUI views + design primitives. Depends on
        // PacerCore for `PaceBand`, `UsageBand`, etc. so the chart
        // and gauge use the same band classification the app and
        // widget agree on. Imported by the App target and the
        // PacerWidgets extension target — keeps one source of truth
        // for any visual the user sees in more than one place.
        .target(
            name: "PacerUI",
            dependencies: ["PacerCore"]
        ),
        .testTarget(
            name: "PacerCoreTests",
            dependencies: ["PacerCore", "PacerUI"]
        ),
    ]
)
