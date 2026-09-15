// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Taction",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TactionKit", targets: ["TactionKit"]),
        .executable(name: "Taction", targets: ["Taction"]),
        .executable(name: "taction-probe", targets: ["taction-probe"]),
        .executable(name: "tactiond", targets: ["tactiond"]),
        .executable(name: "taction-replay", targets: ["taction-replay"]),
    ],
    targets: [
        // Pure logic: parsing, tracking, mapping, gestures, config, fixtures. No IOKit, no event posting.
        .target(name: "TactionKit"),
        // Shared IOHIDManager glue used by the probe and the daemon.
        .target(name: "TactionHID", dependencies: ["TactionKit"]),
        // The daemon proper: device, display, event posting, status. Used by the CLI and the app.
        .target(name: "TactionDaemon", dependencies: ["TactionKit", "TactionHID"]),
        // The menu bar app. scripts/bundle.sh wraps the binary in Taction.app.
        .executableTarget(name: "Taction", dependencies: ["TactionKit", "TactionHID", "TactionDaemon"]),
        // Headless CLI form of the daemon, for development and debugging.
        .executableTarget(name: "tactiond", dependencies: ["TactionKit", "TactionDaemon"]),
        .executableTarget(name: "taction-probe", dependencies: ["TactionKit", "TactionHID"]),
        .executableTarget(name: "taction-replay", dependencies: ["TactionKit"]),
        .testTarget(name: "TactionKitTests", dependencies: ["TactionKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
