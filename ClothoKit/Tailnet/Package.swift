// swift-tools-version:5.9
import PackageDescription

// ClothoTailnet: Clotho's own tailnet node (PLAN.md, "Built-in Tailscale"), a Swift layer over the Go shim
// in go/ (tsnet), which ClothoKit/scripts/build-tailnet.sh builds into build/ClothoTailnet.xcframework. Run
// that first: without the xcframework this package (and only this package) fails to load. It is a package
// of its own, so ClothoKit's core target, the iOS extensions that link it, and every build that doesn't
// need the tailnet never depend on the Go runtime or on the xcframework being there.
//
// - ClothoTailnet: TailnetNode, TailnetTransport (a ClothodTransport) and TailnetProxyServer.
// - TailnetFdPass: passing a file descriptor over a Unix socket (SCM_RIGHTS). Darwin, no Foundation.
// - clotho-tailnet-proxy: ssh's ProxyCommand with ProxyUseFdpass=yes. It asks the app's TailnetProxyServer
//   for a connection and hands ssh the descriptor. No Go and no Foundation, so it starts in milliseconds.
let package = Package(
    name: "Tailnet",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "ClothoTailnet", targets: ["ClothoTailnet"]),
        .executable(name: "clotho-tailnet-proxy", targets: ["clotho-tailnet-proxy"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .binaryTarget(name: "CClothoTailnet", path: "build/ClothoTailnet.xcframework"),
        .target(
            name: "ClothoTailnet",
            dependencies: ["CClothoTailnet", "TailnetFdPass", .product(name: "ClothoKit", package: "ClothoKit")],
            // What the Go runtime and tailscale.com link against on Apple platforms.
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
        .target(name: "TailnetFdPass"),
        .executableTarget(name: "clotho-tailnet-proxy", dependencies: ["TailnetFdPass"]),
        .testTarget(name: "ClothoTailnetTests", dependencies: ["ClothoTailnet", "TailnetFdPass"]),
    ]
)
