// swift-tools-version:5.9
// MacCheck — read-only macOS diagnostic app.
//
// Layout (see docs/ARCHITECTURE.md):
//   MacCheckCore  — platform-independent: result model, interpretation, orchestration,
//                   App Doctor parsing, redaction, consent gating, export, history, fakes.
//                   Builds and is unit-tested on Windows, Linux and macOS.
//   MacCheckMac   — native macOS collectors (IOKit, sysctl, libproc, Network, Security).
//                   Every file is wrapped in `#if os(macOS)`; it compiles to an empty module elsewhere.
//   MacCheckApp   — SwiftUI app (macOS 14+). On other platforms it builds a stub that prints a notice.
//   maccheck-cli  — headless runner. `--sample` works everywhere; real scans need macOS.
//
// No third-party dependencies. Toolchain: Swift 5.9+ (tested with 6.4.2 on Windows).
import PackageDescription

let package = Package(
    name: "MacCheck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacCheckCore", targets: ["MacCheckCore"]),
        .executable(name: "MacCheck", targets: ["MacCheckApp"]),
        .executable(name: "maccheck-cli", targets: ["MacCheckCLI"]),
    ],
    targets: [
        .target(name: "MacCheckCore"),
        .target(name: "MacCheckMac", dependencies: ["MacCheckCore"]),
        .executableTarget(name: "MacCheckApp", dependencies: ["MacCheckCore", "MacCheckMac"]),
        .executableTarget(name: "MacCheckCLI", dependencies: ["MacCheckCore", "MacCheckMac"]),
        .testTarget(
            name: "MacCheckCoreTests",
            dependencies: ["MacCheckCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
