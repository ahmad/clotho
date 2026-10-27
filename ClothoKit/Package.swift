// swift-tools-version:5.9
import PackageDescription

// ClothoKit is shared by the Mac app and the later iOS app, so its core target imports Foundation only.
// ClothoFake is a macOS-only stand-in for clothod that runs local shells.
let package = Package(
    name: "ClothoKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ClothoKit", targets: ["ClothoKit"]),
        .library(name: "ClothoFake", targets: ["ClothoFake"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(name: "ClothoKit"),
        .target(name: "ClothoFake", dependencies: ["ClothoKit", "SwiftTerm"]),
        .testTarget(name: "ClothoKitTests", dependencies: ["ClothoKit", "ClothoFake"]),
    ]
)
