// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacerCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PacerCore", targets: ["PacerCore"]),
        .library(name: "PacerUI", targets: ["PacerUI"]),
        .library(name: "PacerPace", targets: ["PacerPace"]),
        .library(name: "PacerRelaunch", targets: ["PacerRelaunch"]),
    ],
    targets: [
        .target(
            name: "PacerCore",
            dependencies: ["PacerRelaunch"],
            resources: [
                .copy("Resources/litellm-pricing.json"),
                .copy("Resources/price-history.json"),
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
        // The `pacer` command line's pacing commands (#194): the Swift port of
        // what was `Skills/pacer/pace.sh` (replaced by `pacer`), kept as a
        // library so `swift test` covers it and the CLI target is a thin `main`.
        .target(
            name: "PacerPace",
            dependencies: ["PacerCore"]
        ),
        // Relaunching Pacer after it exits without quitting (#412): the policy,
        // the wire format, and the relauncher that `Relauncher/main.swift`
        // runs. No dependencies, not even Foundation, so the relauncher that
        // links it stays tiny; PacerCore and the app use it from their side.
        .target(name: "PacerRelaunch"),
        .testTarget(
            name: "PacerCoreTests",
            dependencies: ["PacerCore", "PacerUI", "PacerRelaunch"],
            // The forecast arena's port fixtures (`research/arena`,
            // `arena port-fixtures`): synthetic inputs and the Python
            // reference's outputs, which the Swift ports must reproduce.
            resources: [.copy("ArenaFixtures")]
        ),
        .testTarget(
            name: "PacerPaceTests",
            dependencies: ["PacerPace", "PacerCore"],
            // The frozen bash implementation the port is compared against.
            exclude: ["Oracle"]
        ),
        .testTarget(
            name: "PacerRelaunchTests",
            dependencies: ["PacerRelaunch"]
        ),
    ]
)
