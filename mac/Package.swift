// swift-tools-version:5.9
import Foundation
import PackageDescription

// CLOTHO_TAILNET=1 links Clotho's own tailnet node (../ClothoKit/Tailnet, a Go runtime of about 20 MB) for the
// dev build's Tailnet Test window (Phase 0 of PLAN.md's "Built-in Tailscale"). Only `build-app.sh --dev` passes
// it on; the user's app (plain, --release, --package) never sets it, and build-app.sh checks the result.
// SwiftPM evaluates this manifest again when the environment changes, not when files change.
let tailnet = ProcessInfo.processInfo.environment["CLOTHO_TAILNET"] == "1"

let package = Package(
    name: "Clotho",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "../ClothoKit"),
        // In-app updates. Pinned: scripts/release.sh uses the same version's sign_update.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ] + (tailnet ? [.package(path: "../ClothoKit/Tailnet")] : []),
    targets: [
        .executableTarget(
            name: "Clotho",
            dependencies: [
                "SwiftTerm",
                .product(name: "ClothoKit", package: "ClothoKit"),
                .product(name: "ClothoFake", package: "ClothoKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ] + (tailnet ? [.product(name: "ClothoTailnet", package: "Tailnet")] : []),
            // `#if CLOTHO_TAILNET`, not canImport: a module left in .build by an earlier tailnet build would
            // still be importable.
            swiftSettings: tailnet ? [.define("CLOTHO_TAILNET")] : [],
            // Sparkle.framework ships in Contents/Frameworks (build-app.sh copies it there).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ClothoTests", dependencies: ["Clotho", "SwiftTerm"]),
    ]
)
