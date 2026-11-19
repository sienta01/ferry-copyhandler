// swift-tools-version:5.9
import PackageDescription

// Built with plain SwiftPM so Xcode isn't required. `scripts/build.sh` wraps the
// release binary into Ferry.app, compiles the Finder extension and signs it all.
let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Ferry", targets: ["Ferry"]),
        .executable(name: "ferry-cli", targets: ["ferry-cli"]),
    ],
    targets: [
        // UI-free copy engine: scanning, queue, pipelined I/O, collisions, verify.
        .target(name: "FerryCore", path: "Sources/FerryCore"),
        // Menu bar app (AppKit + SwiftUI).
        .executableTarget(
            name: "Ferry",
            dependencies: ["FerryCore"],
            path: "Sources/Ferry",
            linkerSettings: [.linkedFramework("FinderSync")]
        ),
        // Headless front end for the same engine (scripting and testing).
        .executableTarget(name: "ferry-cli", dependencies: ["FerryCore"], path: "Sources/ferry-cli"),
        .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore"], path: "Tests/FerryCoreTests"),
    ]
)
