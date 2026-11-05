// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexLimitsWidget",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexLimitsWidget", targets: ["CodexLimitsWidget"])],
    targets: [
        .target(name: "CodexLimitsCore"),
        .executableTarget(name: "CodexLimitsWidget", dependencies: ["CodexLimitsCore"]),
        .testTarget(name: "CodexLimitsCoreTests", dependencies: ["CodexLimitsCore"])
    ],
    swiftLanguageModes: [.v5]
)
