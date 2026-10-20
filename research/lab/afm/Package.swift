// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "afm", platforms: [.macOS(.v26)],
  targets: [.executableTarget(name: "afm", path: "Sources/afm", swiftSettings: [.swiftLanguageMode(.v5)])])
